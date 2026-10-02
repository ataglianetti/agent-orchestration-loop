#!/usr/bin/env python3
"""Efficiency review for a Claude Code workstream: where the API-rate dollars went,
which levers would have cut them, and by how much.

  python3 workstream_efficiency.py --repo ~/code/my-app \
      --session 1a2b3c4d:"Loop run" --session 5e6f7a8b:"PR follow-ups" \
      --title "My feature" --json efficiency.json --html EFFICIENCY.html

Measures (orchestrator = the main session; subagents = everything it spawned):
  - cost by role (orchestrator / execute / review / verify / explore) and by the tool each
    orchestrator call issued (a call's cost is mostly re-reading its whole context)
  - orchestrator context size per call; cost of calls above the context cap
  - cache rebuilds after idle gaps, and the 1-hour cache-write premium
  - the same token flow re-priced on other model mixes, with and without a context cap
Then derives ranked recommendations with dollar estimates. Estimates overlap; the
combined scenario is the number to quote, never the sum of the levers.
Read-only against transcripts. Writes only --json / --html.
"""
import argparse, collections, datetime as dt, glob, json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from workstream_cost import (RATES, DISPLAY, TOKEN_TYPES, base_model, project_dirs, session_files,
                             parse_ts, read, PRICING, load_rates)

ROLE_RULES = [("review", r"review|audit"), ("verify", r"verif|validat|smoke|live check"),
              ("explore", r"explore|investigat|research|locate|find "), ("execute", r".")]
CHEAP_ORCH, CHEAP_SUB = "claude-opus-5-5", "claude-sonnet-5-5"   # cheapest current Opus / Sonnet
BROWSER = re.compile(r"Browser|chrome|computer-use", re.I)


def role_of(desc):
    return next(r for r, pat in ROLE_RULES if re.search(pat, desc or "", re.I))


def ctx_of(u):
    return u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0) + u.get("cache_creation_input_tokens", 0)


def price(u, model, cap=None):
    """Cost of one response. With cap: cache reads above the cap are dropped proportionally,
    modelling an orchestrator whose context never grew past it."""
    r = RATES.get(model)
    if not r:
        return 0.0
    cc = u.get("cache_creation") or {}
    w5, w1 = cc.get("ephemeral_5m_input_tokens"), cc.get("ephemeral_1h_input_tokens")
    if w5 is None and w1 is None:
        w5, w1 = 0, u.get("cache_creation_input_tokens", 0)
    cr, ctx = u.get("cache_read_input_tokens", 0), ctx_of(u)
    if cap and ctx > cap:
        cr *= 1 - cap / ctx
    return (u.get("input_tokens", 0) * r[0] + (w5 or 0) * r[1] + (w1 or 0) * r[2] + cr * r[3]
            + u.get("output_tokens", 0) * r[4]) / 1e6


def responses(path, seen):
    """One record per API response: merges streamed entries that share a message id."""
    msgs = collections.OrderedDict()
    for d in read(path):
        m = d.get("message")
        if not isinstance(m, dict) or m.get("role") != "assistant" or "usage" not in m:
            continue
        key = (m.get("id"), d.get("requestId"))
        if key in seen and key not in msgs:
            continue
        seen.add(key)
        e = msgs.setdefault(key, {"ts": parse_ts(d["timestamp"]), "model": base_model(m.get("model")), "tools": set()})
        e["usage"] = m["usage"]
        for b in m.get("content") or []:
            if b.get("type") == "tool_use":
                e["tools"].add("browser" if BROWSER.search(b.get("name", "")) else b.get("name"))
    return [e for e in msgs.values() if e["model"] in RATES]


def analyze(dirs, spec, seen, cap):
    prefix, _, label = spec.partition(":")
    sid, main, subs = session_files(dirs, prefix)
    orch = responses(main, seen)
    subagents = []
    for f in subs:
        mp = f[:-6] + ".meta.json"
        meta = json.load(open(mp)) if os.path.exists(mp) else {}
        rs = responses(f, seen)
        if rs:
            desc = meta.get("description", os.path.basename(f))
            subagents.append({"name": desc, "role": role_of(desc), "responses": rs})
    by_tool = collections.defaultdict(lambda: [0, 0.0])
    over_cap, rebuild, rebuild_n, premium, prev = 0.0, 0.0, 0, 0.0, None
    for e in orch:
        c = price(e["usage"], e["model"])
        k = "+".join(sorted(e["tools"])) or "reply only"
        by_tool[k][0] += 1; by_tool[k][1] += c
        if ctx_of(e["usage"]) > cap:
            over_cap += c
        cc = e["usage"].get("cache_creation") or {}
        r = RATES[e["model"]]
        premium += (cc.get("ephemeral_1h_input_tokens") or 0) * (r[2] - r[1]) / 1e6
        written = e["usage"].get("cache_creation_input_tokens", 0)
        if written > 50_000 and prev and (e["ts"] - prev).total_seconds() > 300:
            rebuild_n += 1
            rebuild += ((cc.get("ephemeral_5m_input_tokens") or 0) * r[1] + (cc.get("ephemeral_1h_input_tokens") or 0) * r[2]) / 1e6
        prev = e["ts"]
    ctxs = sorted(ctx_of(e["usage"]) for e in orch)
    roles = collections.defaultdict(lambda: {"actors": 0, "calls": 0, "cost": 0.0, "models": collections.Counter()})
    roles["orchestrator"].update(actors=1, calls=len(orch), cost=sum(price(e["usage"], e["model"]) for e in orch))
    roles["orchestrator"]["models"].update(DISPLAY.get(e["model"], e["model"]) for e in orch)
    for s in subagents:
        r = roles[s["role"]]
        r["actors"] += 1; r["calls"] += len(s["responses"])
        r["cost"] += sum(price(e["usage"], e["model"]) for e in s["responses"])
        r["models"].update(DISPLAY.get(e["model"], e["model"]) for e in s["responses"])
    sub_calls = [e for s in subagents for e in s["responses"]]
    return {
        "id": sid, "label": label or sid[:8], "orch": orch, "sub_calls": sub_calls,
        "roles": {k: {**v, "models": dict(v["models"])} for k, v in roles.items()},
        "by_tool": {k: {"calls": v[0], "cost": v[1]} for k, v in by_tool.items()},
        "context": {"median": ctxs[len(ctxs) // 2], "p90": ctxs[int(len(ctxs) * .9)], "max": ctxs[-1],
                    "start": ctx_of(orch[0]["usage"])},
        "over_cap_cost": over_cap, "idle_rebuilds": rebuild_n, "idle_rebuild_cost": rebuild, "premium_1h": premium,
        "compactions": sum(1 for d in read(main) if d.get("subtype") == "compact_boundary"),
        "subagents": sorted(({"name": s["name"], "role": s["role"], "calls": len(s["responses"]),
                              "cost": sum(price(e["usage"], e["model"]) for e in s["responses"])} for s in subagents),
                            key=lambda x: -x["cost"]),
    }


def scenario(sessions, orch_model=None, sub_model=None, cap=None):
    tot = 0.0
    for s in sessions:
        tot += sum(price(e["usage"], orch_model or e["model"], cap) for e in s["orch"])
        tot += sum(price(e["usage"], sub_model or e["model"]) for e in s["sub_calls"])
    return tot


def recommend(sessions, as_run, cap):
    k = cap // 1000
    orch = [e for s in sessions for e in s["orch"]]
    sub = [e for s in sessions for e in s["sub_calls"]]
    recs = []
    # 1. model mix
    mix = collections.Counter(DISPLAY.get(e["model"], e["model"]) for e in orch + sub)
    used = collections.Counter(e["model"] for e in orch + sub)
    cheap = scenario(sessions, CHEAP_ORCH, CHEAP_ORCH)
    cheap_name = DISPLAY.get(CHEAP_ORCH, CHEAP_ORCH)
    reads = ", ".join(f"{DISPLAY.get(m, m)} ${RATES[m][3]:.2f}" for m, _ in used.most_common() if m in RATES)
    if as_run - cheap > 0.1 * as_run:
        recs.append({"lever": f"Run the loop on {cheap_name}", "saves": as_run - cheap,
                     "evidence": "Model mix by API call: " + ", ".join(f"{n} {v}" for n, v in mix.most_common())
                                 + f". The same tokens on {cheap_name} cost ${cheap:,.0f} instead of ${as_run:,.0f}.",
                     "how": f"Route the orchestrator and executors to {cheap_name} for the next run (Loop Config "
                            f"model_* keys; the session's own model for the orchestrator). Cache reads, the bulk of "
                            f"any agent run, cost ${RATES[CHEAP_ORCH][3]:.2f} per million on {cheap_name} versus "
                            f"{reads} here. Keep the review gate unchanged; it is the quality check on the switch.",
                     "risk": "Quality on this kind of work is untested on Opus 5.5. Trial it on one workstream and "
                             "compare review verdicts and rounds to converge."})
    # 2. context cap
    capped = scenario(sessions, cap=cap)
    med = max(s["context"]["median"] for s in sessions)
    if as_run - capped > 0.1 * as_run:
        over = sum(s["over_cap_cost"] for s in sessions)
        orch_cost = sum(s["roles"]["orchestrator"]["cost"] for s in sessions)
        recs.append({"lever": f"Keep the orchestrator under {k}K tokens of context", "saves": as_run - capped,
                     "evidence": f"Orchestrator context ran at a median of {med/1e3:.0f}K tokens and peaked at "
                                 f"{max(s['context']['max'] for s in sessions)/1e3:.0f}K, with "
                                 f"{sum(s['compactions'] for s in sessions)} compactions. Every call re-reads the whole "
                                 f"context, so calls above {k}K cost ${over:,.0f} of the orchestrator's ${orch_cost:,.0f}.",
                     "how": "Start a fresh orchestrator session at round boundaries (re-invoke /orchestrate <id>; the "
                            "loop resumes from the workstream files) instead of carrying one session across every "
                            "round, or compact at the boundary.",
                     "risk": "A fresh session re-reads the workstream files (a few cents per round) and can lose nuance "
                             "the handoff file doesn't capture. The estimate trims cache reads above the cap and doesn't "
                             "price that re-read."})
    # 3. delegate hands-on work
    tools = collections.defaultdict(lambda: [0, 0.0])
    for s in sessions:
        for t, v in s["by_tool"].items():
            for name in ("browser", "Bash"):
                if name in t.split("+"):
                    tools[name][0] += v["calls"]; tools[name][1] += v["cost"]
    sub_avg = sum(price(e["usage"], e["model"]) for e in sub) / max(1, len(sub))
    hands = sum(v[1] for v in tools.values())
    if hands > 0.15 * as_run:
        n = sum(v[0] for v in tools.values())
        recs.append({"lever": "Move browser checks and shell work out of the orchestrator", "saves": max(0, hands - n * sub_avg),
                     "evidence": f"The orchestrator made {tools['browser'][0]} browser calls (${tools['browser'][1]:,.0f}) and "
                                 f"{tools['Bash'][0]} shell calls (${tools['Bash'][1]:,.0f}) itself, averaging "
                                 f"${hands/max(1,n):.2f} a call. A subagent call in this run averaged ${sub_avg:.2f}.",
                     "how": "Send live verification and investigations to a verify subagent that returns only the "
                            "finding: pass/fail, the repro and one screenshot. Then 50 clicks cost a subagent's small "
                            "context, not the orchestrator's large one. When you drive a live check yourself, do it in "
                            "a separate short session.",
                     "risk": "This overlaps with the context cap; both work by keeping the expensive context small. "
                             "Don't add the two estimates together."})
    # 4. idle cache expiry
    idle = sum(s["idle_rebuild_cost"] for s in sessions) + sum(s["premium_1h"] for s in sessions)
    if idle > 0.03 * as_run:
        recs.append({"lever": "Close the session before stepping away", "saves": sum(s["idle_rebuild_cost"] for s in sessions),
                     "evidence": f"{sum(s['idle_rebuilds'] for s in sessions)} times the cache expired while the session sat "
                                 f"idle, and rebuilding a large context cost ${sum(s['idle_rebuild_cost'] for s in sessions):,.0f}. "
                                 f"Writing the cache at the 1-hour rate added ${sum(s['premium_1h'] for s in sessions):,.0f} "
                                 f"over the 5-minute rate.",
                     "how": "If you will be away more than an hour (overnight, a meeting, waiting on an approval card), "
                            "end at a handoff and resume in a fresh session. Answer approval cards in one batch, so the "
                            "loop isn't waiting idle more than once.",
                     "risk": "This is small next to the levers above, and it falls on its own once the context is kept small."})
    # what to keep
    review = sum(s["roles"].get("review", {}).get("cost", 0) for s in sessions)
    keep = {"lever": "Keep the review passes", "cost": review,
            "evidence": f"Review subagents cost ${review:,.0f}, {review/as_run:.0%} of the total. They are the one part of the "
                        f"loop that catches what tests miss. Cutting them saves little and removes the quality gate the "
                        f"cheaper-model trial depends on."}
    return sorted(recs, key=lambda r: -r["saves"]), keep


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--repo", required=True)
    p.add_argument("--session", action="append", required=True, help="ID prefix, optionally :Label")
    p.add_argument("--title", required=True)
    p.add_argument("--cap", type=int, default=200_000, help="orchestrator context cap to model, tokens")
    p.add_argument("--json"); p.add_argument("--html")
    p.add_argument("--offline", action="store_true", help="skip the live pricing fetch; use the last cached fetch")
    a = p.parse_args()
    load_rates(a.offline)
    if PRICING["warning"]:
        print("WARNING " + PRICING["warning"])
    dirs, seen = project_dirs(a.repo), set()
    sessions = [analyze(dirs, s, seen, a.cap) for s in a.session]
    as_run = scenario(sessions)
    scen = [
        ("As run", as_run),
        (f"Context capped at {a.cap//1000}K", scenario(sessions, cap=a.cap)),
        ("All Opus 5.5", scenario(sessions, CHEAP_ORCH, CHEAP_ORCH)),
        (f"All Opus 5.5, context capped at {a.cap//1000}K", scenario(sessions, CHEAP_ORCH, CHEAP_ORCH, a.cap)),
        (f"Opus 5.5 orchestrator, Sonnet 5.5 subagents, capped at {a.cap//1000}K", scenario(sessions, CHEAP_ORCH, CHEAP_SUB, a.cap)),
    ]
    recs, keep = recommend(sessions, as_run, a.cap)
    out = {"title": a.title, "generated": dt.date.today().isoformat(), "cap": a.cap,
           "pricing_source": PRICING["source"], "pricing_date": PRICING["date"], "pricing_how": PRICING["how"],
           "pricing_warning": PRICING["warning"], "as_run": as_run,
           "scenarios": [{"name": n, "cost": c} for n, c in scen], "recommendations": recs, "keep": keep,
           "sessions": [{k: v for k, v in s.items() if k not in ("orch", "sub_calls")} for s in sessions]}
    for s in out["sessions"]:
        s["subagents"] = s["subagents"][:8]
        s["by_tool"] = dict(sorted(s["by_tool"].items(), key=lambda kv: -kv[1]["cost"])[:8])
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=2, default=str)
    if a.html:
        tpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "efficiency.html")).read()
        with open(a.html, "w") as f:
            f.write(tpl.replace("__TITLE__", a.title).replace("__DATA__", json.dumps(out, default=str)))
    print(f"{a.title}: as run ${as_run:,.2f}")
    for n, c in scen:
        print(f"  {n:58s} ${c:8.2f}  ({(c - as_run) / as_run:+.0%})")
    for r in recs:
        print(f"  - {r['lever']}: saves ~${r['saves']:,.0f}")
    print(f"  keep: {keep['lever']} (${keep['cost']:,.0f})")


if __name__ == "__main__":
    main()
