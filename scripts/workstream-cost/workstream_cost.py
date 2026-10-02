#!/usr/bin/env python3
"""Token, API-cost, and time analysis for a Claude Code workstream.

Reads Claude Code session transcripts (~/.claude/projects/<encoded-path>/),
dedupes streamed messages, prices every token at Claude API list rates, and
measures calendar span vs active time. Subagent transcripts are included.

Usage:
  # At close (close-workstream.sh calls this): price the sessions the hook recorded in
  # <workstream>/SESSIONS.log and write COST.html + cost.json into the workstream folder.
  python3 workstream_cost.py record --repo . --workstream docs/execution/done/my-feature

  # By hand: find candidate sessions that mention a workstream, then price a chosen set
  python3 workstream_cost.py find --repo ~/code/my-app --text my-feature
  python3 workstream_cost.py analyze --repo ~/code/my-app \
      --session 1a2b3c4d:"Loop run" --session 5e6f7a8b:"PR follow-ups" \
      --title "My feature" --plan-price 200 --json cost.json --html COST.html

Read-only against transcripts. Writes only the --json / --html paths given (record: the
workstream folder's cost.json and COST.html).
"""
import argparse, collections, datetime as dt, glob, json, os, re, sys

# Claude API list prices, $ per million tokens:
# (input, 5m cache write, 1h cache write, cache read, output)
# load_rates() replaces these with the live pricing page on every run. The table below is
# the last resort when the page is unreachable AND no cached fetch exists; it was checked
# against the page on 2026-10-01.
PRICING_URL = "https://platform.claude.com/docs/en/about-claude/pricing.md"
PRICING_SOURCE = "platform.claude.com/docs/en/about-claude/pricing"
PRICING_DATE = "2026-10-01"
# Outside the repo: a frozen .claude/ (hard lock) can't block it, and it never gets committed.
CACHE_FILE = os.path.expanduser("~/.cache/workstream-cost/rates.json")
# How the rates in this run were obtained; shown on every report. Mutated in place by load_rates().
PRICING = {"source": PRICING_SOURCE, "date": PRICING_DATE, "how": "built-in table", "warning": None}
RATES = {
    "claude-fable-5-1":  (10, 12.50, 20, 0.25, 50),
    "claude-mythos-5-1": (10, 12.50, 20, 0.25, 50),
    "claude-fable-5":    (10, 12.50, 20, 1.00, 50),
    "claude-mythos-5":   (10, 12.50, 20, 1.00, 50),
    "claude-opus-5-5":   (4, 5, 8, 0.20, 20),
    "claude-opus-5":     (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-8":   (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-7":   (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-6":   (5, 6.25, 10, 0.50, 25),
    "claude-opus-4-5":   (5, 6.25, 10, 0.50, 25),
    "claude-sonnet-5-5": (2, 2.50, 4, 0.20, 10),
    "claude-sonnet-5":   (2, 2.50, 4, 0.20, 10),
    "claude-sonnet-4-6": (3, 3.75, 6, 0.30, 15),
    "claude-sonnet-4-5": (3, 3.75, 6, 0.30, 15),
    "claude-haiku-4-5":  (1, 1.25, 2, 0.10, 5),
}
DISPLAY = {
    "claude-fable-5-1": "Fable 5.1", "claude-fable-5": "Fable 5",
    "claude-opus-5-5": "Opus 5.5", "claude-opus-5": "Opus 5", "claude-opus-4-8": "Opus 4.8",
    "claude-opus-4-7": "Opus 4.7", "claude-opus-4-6": "Opus 4.6", "claude-sonnet-5-5": "Sonnet 5.5",
    "claude-sonnet-5": "Sonnet 5", "claude-sonnet-4-6": "Sonnet 4.6", "claude-haiku-4-5": "Haiku 4.5",
}
TOKEN_TYPES = ["input", "cache_write_5m", "cache_write_1h", "cache_read", "output"]
TYPE_LABEL = {"input": "Uncached input", "cache_write_5m": "Cache writes (5-min)",
              "cache_write_1h": "Cache writes (1-hour)", "cache_read": "Cache reads", "output": "Output"}


def parse_pricing(md):
    """Model-pricing rows from the pricing page: '| Claude Opus 5.5 | $4 / MTok | ... |' with
    exactly five dollar columns. Batch and tool tables have other shapes and are skipped."""
    out = {}
    for line in md.splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        m = re.match(r"Claude ([A-Za-z]+) (\d+(?:\.\d+)?)\b", cells[0]) if cells else None
        if not m or len(cells) != 6:
            continue
        prices = [re.match(r"\$([\d.]+)\s*/\s*MTok", c) for c in cells[1:]]
        if not all(prices):
            continue
        mid = f"claude-{m.group(1).lower()}-{m.group(2).replace('.', '-')}"
        out.setdefault(mid, tuple(float(p.group(1)) for p in prices))  # first table wins
    return out


def load_rates(offline=False):
    """Live page -> last successful fetch -> built-in table. Updates RATES and PRICING in place."""
    import urllib.request
    today = dt.date.today().isoformat()
    if not offline:
        try:
            req = urllib.request.Request(PRICING_URL, headers={"User-Agent": "Mozilla/5.0 workstream-cost"})
            live = parse_pricing(urllib.request.urlopen(req, timeout=20).read().decode())
            if len(live) < 5:
                raise ValueError(f"only {len(live)} models parsed; page layout may have changed")
            RATES.update(live)
            PRICING.update(date=today, how="fetched live", warning=None)
            try:
                os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
                with open(CACHE_FILE, "w") as f:
                    json.dump({"date": today, "rates": live}, f, indent=1)
            except OSError:
                pass  # the live rates are in use; only the fallback copy is missed
            return
        except Exception as e:  # network, HTTP, or parse failure: fall through, loudly
            err = str(e)[:120]
    else:
        err = "--offline"
    try:
        cache = json.load(open(CACHE_FILE))
        RATES.update({k: tuple(v) for k, v in cache["rates"].items()})
        PRICING.update(date=cache["date"], how="cached fetch",
                       warning=f"Pricing page not fetched ({err}); used rates fetched {cache['date']}.")
    except (OSError, ValueError, KeyError):
        PRICING.update(how="built-in table",
                       warning=f"Pricing page not fetched ({err}) and no cached fetch; used the built-in table checked {PRICING_DATE}.")


def base_model(m):
    """Strip date suffixes / context tags: claude-opus-4-8-20260101[1m] -> claude-opus-4-8."""
    m = re.sub(r"\[.*?\]$", "", m or "")
    return re.sub(r"-\d{8}$", "", m)


def project_dirs(repo):
    root = os.path.expanduser("~/.claude/projects")
    enc = re.sub(r"[^A-Za-z0-9]", "-", os.path.abspath(os.path.expanduser(repo)))
    # include worktrees created under the repo (encoded with the repo path as prefix)
    return sorted(d for d in glob.glob(os.path.join(root, enc + "*")) if os.path.isdir(d))


def session_files(dirs, prefix):
    for d in dirs:
        for main in glob.glob(os.path.join(d, prefix + "*.jsonl")):
            sid = os.path.basename(main)[:-6]
            subs = glob.glob(os.path.join(d, sid, "**", "*.jsonl"), recursive=True)
            return sid, main, subs
    return None, None, None


def parse_ts(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone()


def read(path):
    with open(path, errors="ignore") as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def cmd_find(a):
    dirs = project_dirs(a.repo)
    if not dirs:
        sys.exit(f"no transcripts for {a.repo}")
    rows = []
    for d in dirs:
        for main in glob.glob(os.path.join(d, "*.jsonl")):
            sid = os.path.basename(main)[:-6]
            files = [main] + glob.glob(os.path.join(d, sid, "**", "*.jsonl"), recursive=True)
            hit, first, last, opener = False, None, None, ""
            for f in files:
                for d_ in read(f):
                    if not hit and a.text in json.dumps(d_):
                        hit = True
                    ts = d_.get("timestamp")
                    if ts:
                        first = min(first or ts, ts); last = max(last or ts, ts)
                    if f == main and not opener and d_.get("type") == "user":
                        c = d_.get("message", {}).get("content")
                        if isinstance(c, str):
                            opener = re.sub(r"\s+", " ", c)[:90]
            if hit and first:
                rows.append((first, last, sid, os.path.basename(d), opener))
    for first, last, sid, d, opener in sorted(rows):
        print(f"{sid[:8]}  {parse_ts(first):%a %Y-%m-%d %H:%M} -> {parse_ts(last):%a %m-%d %H:%M}  [{d}]  {opener}")
    if not rows:
        print("no sessions mention that text")


def cmd_analyze(a):
    dirs = project_dirs(a.repo)
    seen = set()
    load_rates(a.offline)
    sessions, by_model, warnings = [], collections.defaultdict(collections.Counter), []
    if PRICING["warning"]:
        warnings.append(PRICING["warning"])
    all_ts = []
    for spec in a.session:
        prefix, _, label = spec.partition(":")
        sid, main, subs = session_files(dirs, prefix)
        if not sid:  # deleted by cleanupPeriodDays, or recorded on another machine
            warnings.append(f"Session {prefix[:8]} has no transcript on this machine; it is not counted.")
            continue
        events, tok, humans, fast = [], collections.Counter(), 0, 0
        sess_models = collections.defaultdict(collections.Counter)
        final = {}  # one response is logged once per content block; the LAST entry has the final usage
        for f in [main] + subs:
            for d in read(f):
                ts = d.get("timestamp")
                if ts:
                    events.append(parse_ts(ts))
                if f == main and d.get("type") == "user":
                    c = d.get("message", {}).get("content")
                    if isinstance(c, str) and not c.startswith("<"):
                        humans += 1
                m = d.get("message")
                if not isinstance(m, dict) or "usage" not in m:
                    continue
                key = (m.get("id"), d.get("requestId"))
                if key in seen:  # already counted in an earlier session
                    continue
                final[key] = (base_model(m.get("model")), m["usage"])
        seen.update(final)
        for model, u in final.values():
            if model == "<synthetic>":
                continue
            if u.get("speed") == "fast":
                fast += 1
            cc = u.get("cache_creation") or {}
            w5, w1 = cc.get("ephemeral_5m_input_tokens"), cc.get("ephemeral_1h_input_tokens")
            if w5 is None and w1 is None:  # older logs: no TTL split, price conservatively at 1h
                w5, w1 = 0, u.get("cache_creation_input_tokens", 0)
            c = collections.Counter(input=u.get("input_tokens", 0), cache_write_5m=w5 or 0,
                                    cache_write_1h=w1 or 0, cache_read=u.get("cache_read_input_tokens", 0),
                                    output=u.get("output_tokens", 0))
            tok.update(c); by_model[model].update(c); sess_models[model].update(c)
        events.sort(); all_ts += events
        if fast:
            warnings.append(f"{sid[:8]}: {fast} fast-mode responses priced at standard rates (fast mode costs 2x)")
        sessions.append({"id": sid, "label": label or sid[:8], "start": events[0].isoformat(),
                         "end": events[-1].isoformat(), "calendar_s": (events[-1] - events[0]).total_seconds(),
                         "active_s": active_seconds(events, a.gap), "human_messages": humans,
                         "subagents": len([s for s in subs if s.endswith(".jsonl")]),
                         "tokens": dict(tok), "cost": cost_of(sess_models),
                         "models": {DISPLAY.get(k, k): sum(v.values()) for k, v in sess_models.items()}})
    if not sessions:
        print("\n".join(["No transcripts found for any listed session; nothing written."] + warnings))
        sys.exit(1)
    lines, total = [], 0.0
    for model, c in sorted(by_model.items()):
        r = RATES.get(model)
        if not r:
            warnings.append(f"{model}: no list price on file — excluded from cost")
            continue
        for i, t in enumerate(TOKEN_TYPES):
            amt = c[t] * r[i] / 1e6
            lines.append({"model": model, "model_name": DISPLAY.get(model, model), "type": t,
                          "type_label": TYPE_LABEL[t], "tokens": c[t], "rate": r[i], "amount": amt})
            total += amt
    all_ts.sort()
    out = {
        "title": a.title, "subtitle": a.subtitle, "repo": os.path.basename(os.path.abspath(os.path.expanduser(a.repo))),
        "generated": dt.date.today().isoformat(), "pricing_source": PRICING["source"], "pricing_date": PRICING["date"], "pricing_how": PRICING["how"],
        "active_gap_min": a.gap, "plan_name": a.plan_name, "plan_price": a.plan_price,
        "sessions": sessions, "lines": lines, "total_cost": total,
        "totals": {t: sum(c[t] for c in by_model.values()) for t in TOKEN_TYPES},
        "calendar_s": (all_ts[-1] - all_ts[0]).total_seconds(),
        "active_s": sum(s["active_s"] for s in sessions),
        "notes": a.note or [], "warnings": warnings,
    }
    if a.json:
        with open(a.json, "w") as f:
            json.dump(out, f, indent=2)
    if a.html:
        tpl = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "bill.html")).read()
        with open(a.html, "w") as f:
            f.write(tpl.replace("__TITLE__", a.title).replace("__DATA__", json.dumps(out)))
    print(summary(out))


def _text(path):
    try:
        return open(path, errors="ignore").read()
    except OSError:
        return ""


def workstream_facts(ws):
    """Title, subtitle, Loop Config plan settings, and notes read mechanically from the
    workstream files. Every note names the file it came from; nothing is inferred."""
    readme = _text(os.path.join(ws, "README.md"))
    h1 = re.search(r"^#\s+(?:Workstream:\s*)?(.+)$", readme, re.M)
    title = h1.group(1).strip() if h1 else os.path.basename(ws)
    obj = re.search(r"^##\s+Objective\s*\n+(.+?)(?:\n\s*\n|\Z)", readme, re.M | re.S)
    subtitle = ""
    if obj:
        first = re.split(r"(?<=[.!?])\s", " ".join(obj.group(1).split()), maxsplit=1)[0]
        subtitle = first if len(first) <= 240 else first[:237] + "..."
    cfg = dict(re.findall(r"^-\s*(plan_name|plan_price):\s*(.+?)\s*$", readme, re.M))
    notes = []
    rounds = [int(n) for n in re.findall(r"^##\s+Round\s+(\d+)", _text(os.path.join(ws, "RUN_LOG.md")), re.M)]
    if rounds:
        notes.append(f"{max(rounds)} loop rounds (RUN_LOG.md).")
    review = _text(os.path.join(ws, "REVIEW.md"))
    verdicts = []
    for block in re.split(r"^(?=##\s+Round\s+\d+)", review, flags=re.M):
        rn = re.match(r"##\s+Round\s+(\d+)", block)
        v = re.search(r"^\**VERDICT:?\**:?\s*\**\s*([A-Z][A-Z-]+)", block, re.M)
        if rn and v:
            verdicts.append(f"R{rn.group(1)} {v.group(1)}")
    if verdicts:
        notes.append("Review verdicts by round: " + ", ".join(verdicts) + " (REVIEW.md).")
    # Task IDs anywhere on the board. The Done section is often trimmed or freeform by close,
    # so counting only it undercounts; this counts tasks planned, and says so.
    ids = set(re.findall(r"\bT-\d+\b", _text(os.path.join(ws, "WORKBOARD.md"))))
    if ids:
        notes.append(f"{len(ids)} tasks on the workboard (WORKBOARD.md).")
    status = re.search(r"^##\s+Status\s*\n+\s*(.+)", _text(os.path.join(ws, "APPROVAL_CARD.md")), re.M)
    if status:
        line = status.group(1).replace("`", "").strip()
        first = re.split(r"(?<=\.)\s", line, maxsplit=1)[0]
        notes.append(f"Approval card status: {first.rstrip('.')} (APPROVAL_CARD.md).")
    return title, subtitle, cfg, notes


def cmd_record(a):
    """Price the sessions the hook recorded, and write the statement into the workstream."""
    ws = os.path.abspath(os.path.expanduser(a.workstream))
    log = os.path.join(ws, "SESSIONS.log")
    if not os.path.exists(log):
        sys.exit(f"No SESSIONS.log in {ws}. Sessions are recorded by the record-workstream-session hook; "
                 "for a workstream that predates it, use `find` then `analyze`.")
    ids = []
    for line in open(log):
        sid = line.split("\t")[0].strip()
        if re.fullmatch(r"[0-9a-f-]{8,}", sid) and sid not in ids:
            ids.append(sid)
    if not ids:
        sys.exit(f"{log} lists no sessions.")
    title, subtitle, cfg, notes = workstream_facts(ws)
    args = argparse.Namespace(
        repo=a.repo, session=[f"{sid}:Session {i + 1}" for i, sid in enumerate(ids)],
        title=title, subtitle=subtitle, gap=a.gap, note=notes, offline=a.offline,
        plan_name=cfg.get("plan_name", a.plan_name), plan_price=float(cfg.get("plan_price", a.plan_price)),
        json=os.path.join(ws, "cost.json"), html=os.path.join(ws, "COST.html"))
    cmd_analyze(args)
    print(f"Wrote {args.html}")


def cost_of(models):
    return sum(c[t] * RATES[m][i] / 1e6 for m, c in models.items() if m in RATES
               for i, t in enumerate(TOKEN_TYPES))


def active_seconds(events, gap_min):
    gap = dt.timedelta(minutes=gap_min)
    return sum(((b - a).total_seconds() for a, b in zip(events, events[1:]) if b - a <= gap), 0.0)


def hm(s):
    h, m = divmod(int(round(s / 60)), 60)
    d, h = divmod(h, 24)
    return (f"{d}d " if d else "") + f"{h}h {m:02d}m"


def summary(o):
    t = o["totals"]
    out = [f"{o['title']}  —  API cost ${o['total_cost']:,.2f}",
           f"tokens: total {sum(t.values()):,}  output {t['output']:,}  cache reads {t['cache_read']:,}  "
           f"cache writes {t['cache_write_5m'] + t['cache_write_1h']:,}  input {t['input']:,}",
           f"time: calendar {hm(o['calendar_s'])}  active {hm(o['active_s'])} (gaps > {o['active_gap_min']} min = idle)"]
    for s in o["sessions"]:
        out.append(f"  {s['label']}: {s['start'][:16]} -> {s['end'][:16]}  calendar {hm(s['calendar_s'])}  "
                   f"active {hm(s['active_s'])}  subagents {s['subagents']}  your messages {s['human_messages']}")
    if o["plan_price"]:
        out.append(f"vs {o['plan_name']} ${o['plan_price']:,.0f}/mo: {o['total_cost'] / o['plan_price']:.1f}x")
    out += [f"WARNING {w}" for w in o["warnings"]]
    return "\n".join(out)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("find"); f.add_argument("--repo", required=True); f.add_argument("--text", required=True)
    an = sub.add_parser("analyze")
    an.add_argument("--repo", required=True)
    an.add_argument("--session", action="append", required=True, help="ID prefix, optionally :Label")
    an.add_argument("--title", required=True)
    an.add_argument("--subtitle", default="")
    an.add_argument("--gap", type=float, default=15, help="minutes; longer gaps count as idle")
    an.add_argument("--plan-name", default="Claude Max")
    an.add_argument("--plan-price", type=float, default=200)
    an.add_argument("--note", action="append", help="context line shown on the bill (repeatable)")
    an.add_argument("--json"); an.add_argument("--html")
    an.add_argument("--offline", action="store_true", help="skip the live pricing fetch; use the last cached fetch")
    rc = sub.add_parser("record", help="price the sessions in <workstream>/SESSIONS.log; write COST.html + cost.json there")
    rc.add_argument("--repo", required=True, help="repo root the sessions ran in")
    rc.add_argument("--workstream", required=True, help="the workstream folder")
    rc.add_argument("--gap", type=float, default=15)
    rc.add_argument("--plan-name", default="Claude Max", help="overridden by plan_name in the README's Loop Config")
    rc.add_argument("--plan-price", type=float, default=200, help="overridden by plan_price in the README's Loop Config")
    rc.add_argument("--offline", action="store_true")
    a = p.parse_args()
    {"find": cmd_find, "analyze": cmd_analyze, "record": cmd_record}[a.cmd](a)


if __name__ == "__main__":
    main()
