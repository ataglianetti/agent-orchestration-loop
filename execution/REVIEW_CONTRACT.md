# Adversarial Review Contract

The machine-routable output the adversarial-review phase emits each loop round, and the rules for producing it. `/orchestrate` reads this artifact and routes off it — so the contract is the seam between *assessment* (the reviewers' job) and *routing* (orchestrate's job).

**One hard rule up front: the reviewers assess; orchestrate decides.** A reviewer flags severity, reachability, and whether something looks like a human call. It never authorizes or applies a fix. Routing — fix now / park / pause for a human — is orchestrate's policy (defined in `orchestrate.md`, not here).

---

## 1) The artifact

The review phase writes `REVIEW.md` in the workstream folder (`docs/execution/active/<id>/REVIEW.md`), **append-per-round**: each loop round adds a new `## Round N` block. Orchestrate reads the **last** block to route the current round; earlier blocks are the audit trail.

Two destinations, by audience:

- **`REVIEW.md`** — the structured verdict block (below). Machine-routable, terse. This is what orchestrate parses.
- **`RUN_LOG.md`** — the round narrative + the reviewers' prose (what they looked at, why a finding matters). Human audit trail. **The prose never goes to the PM directly** — it lives here for the record.

Adding `REVIEW.md` is the one schema change to the workstream spine; everything else reuses the existing files.

---

## 2) Verdict block format

Each `## Round N` block has three parts: the verdict line, the findings table, and per-finding detail.

```markdown
## Round N — YYYY-MM-DD

VERDICT: CONCERNS
Personas: adversarial-reviewer, run, code-review (3 independent passes)

| ID  | SEVERITY         | reachability       | consensus | FLAG-HUMAN | summary                          |
| --- | ---------------- | ------------------ | --------- | ---------- | -------------------------------- |
| F1  | CRITICAL-ON-FLIP | dormant-at-default | 2/3       | no         | unbounded text cache             |
| F2  | WARNING          | live               | 1/3       | no         | N+1 fetch in track enrichment    |
| F3  | NOTE             | live               | 3/3       | no         | inconsistent error-log prefix    |

### Detail

**F1 — unbounded text cache** (`src/lib/cache.ts:42`)
Cache has no eviction; grows without bound. Dormant today because the caching flag
defaults off. Becomes CRITICAL if `ENABLE_TEXT_CACHE` is ever flipped on in prod.
Raised by: adversarial-reviewer, run.

**F2 — N+1 fetch** (`src/lib/enrich.ts:88`) ...
```

- **IDs are stable across rounds** (`F1`, `F2`, …) — decoupled from severity so a finding can be tracked even if its severity changes ("F1 resolved in round 3"). Severity lives in its own column. (This is why we don't use the brief's illustrative `C1`/`W1` prefixes — `C1` becomes `F1` with `SEVERITY: CRITICAL`.)
- A finding that was open in round N−1 and is now fixed appears in round N's detail as `F1 — RESOLVED` (one line), so the trail shows convergence.

---

## 3) Controlled vocabularies

Use these exact tokens — orchestrate's routing keys off them literally.

### SEVERITY — *how bad if the bad path executes*

| Token | Meaning |
| --- | --- |
| `CRITICAL` | Breaks behavior, loses data, or opens a security hole **now**, under current defaults. |
| `CRITICAL-ON-FLIP` | Would be CRITICAL **if** a flag/default/config flips, but is inert under current settings. Pair with `dormant-at-default`. |
| `WARNING` | Logic error, performance issue, or contract drift that degrades but doesn't break. |
| `NOTE` | Style, naming, minor convention, nice-to-have. |

### reachability — *can the bad path execute under current defaults*

| Token | Meaning |
| --- | --- |
| `live` | Executes under the current default config/flags. |
| `dormant-at-default` | Only reachable when a non-default flag/config is enabled. |
| `boundary-only` | Only on specific external/untrusted input at a system boundary. |
| `test-only` | Only in test code paths; ships nothing to runtime. |
| `unreachable` | Guarded or dead; cannot currently execute (a downgrade / "delete it?" signal). |

SEVERITY and reachability are **independent axes**. SEVERITY = how bad if it fires; reachability = whether it can fire now. `CRITICAL-ON-FLIP` + `dormant-at-default` is the common pairing, but `WARNING` + `dormant-at-default` is valid too.

### FLAG-HUMAN — *reviewer's recommendation that this isn't auto-resolvable*

Set `yes` when the finding turns on a judgment a code reviewer (or orchestrate) shouldn't make alone:

- **Product / scope** — "is this what was asked for?", feature-correctness, intent drift.
- **Irreversible / costs money / touches a contract** or external commitment.
- **Security *posture*** — a policy decision (e.g. "should anonymous scope expose X?"), not a code-level bug.

Do **not** set it for ordinary engineering correctness — that's orchestrate + executor's job to resolve. `FLAG-HUMAN` is a *recommendation to escalate*; orchestrate still owns the decision to pause.

### VERDICT — *the round's overall gate*

| Token | When | 
| --- | --- |
| `CLEAN` | Nothing above `NOTE` remains open. The loop may exit (pending orchestrate's approval card). |
| `CONCERNS` | Findings exist, but none are `live` `CRITICAL` and none are `FLAG-HUMAN`. Orchestrate auto-resolves/parks per policy, then re-reviews. |
| `BLOCK` | At least one `CRITICAL` at `live` reachability, **or** at least one `FLAG-HUMAN`. Must be addressed before the round can reach `CLEAN`. |

---

## 4) The review phase — independent personas, not one pass

Run **1–3 independent review passes** over the round's diff, depth scaled to blast radius (orchestrate's 2c ladder: minimal → 1, standard → 2, deep / guardrail-touch → 3), each via a distinct skill, **without sharing findings between them**. Correlated blind spots are the failure mode; agreement across independent passes is the signal that earns the blind sign-off — so a lighter tier escalates a pass on any borderline or critical finding.

| Pass | Skill | Lens |
| --- | --- | --- |
| A | `adversarial-reviewer` | Hostile personas; blind-spot and assumption breaking. |
| B | `run` | Multi-model Optimizer/Skeptic; mechanical checks first, then scaled agents. |
| C | `code-review` | Correctness bugs + reuse/simplification/efficiency on the diff. |

`verify` is **not** a review persona — it's a verification gate (live reality-check + coverage), run separately by orchestrate. Keep it out of the consensus count.

Each pass produces raw findings in its own format. They are reconciled in the next step.

---

## 5) Normalization (raw passes → one verdict block)

A normalize step (orchestrate, or a thin sub-agent it spawns) merges the three passes into the single block:

1. **Translate** each pass's findings into the contract vocab (assign `SEVERITY` + `reachability` per the tables above; assess `FLAG-HUMAN`).
2. **Dedup** by `(file, approximate line, issue class)`. The same underlying issue raised by multiple passes is one finding.
3. **Severity = the max** any pass assigned it. Don't let one lenient pass mask a critical. (When in doubt between two tiers, take the higher.)
4. **consensus = M/N** — how many of the N passes independently surfaced it. `1/3` is thin (could be a false positive, could be a real blind-spot catch); `3/3` is strong.
5. **FLAG-HUMAN = yes if any** pass flagged it. Conservative — a human call surfaced by one reviewer is still a human call.
6. **Derive VERDICT** per §3's table from the merged set.

Stable IDs carry across rounds: a finding open last round keeps its ID; new findings get the next free `F#`.

---

## 6) Handoff to orchestrate

Orchestrate reads the latest `## Round N` block and applies its own **severity→action policy** (owned in `orchestrate.md`). For reference, the routing it will key off these tokens looks like:

- `CRITICAL` + `live` → executor fixes → re-review.
- `CRITICAL-ON-FLIP` / `dormant-at-default` → fix if cheap+safe, else park on the flip-gate in `RISKS_AND_BLOCKERS.md`.
- `WARNING` → fix if cheap, else park.
- `NOTE` → auto-fix trivial, log the rest.
- Any `FLAG-HUMAN: yes` → pause the loop, surface on the approval card.

The contract's job is to make those tokens trustworthy and uniform. It does **not** define the actions — that's orchestrate. Where work is reversible (SaaS, flags, dark-launch, one-commit reverts), orchestrate auto-resolves aggressively; the human gates are reserved for the irreversible calls (money, contracts, scope, security posture), not routine engineering.

---

## 7) Confidence (inputs only; orchestrate synthesizes)

"How confident" on the approval card is a cross-signal read orchestrate computes. This contract supplies the **review-side** inputs:

- per-finding `consensus` (M/N),
- the set of personas actually run,
- the round `VERDICT`.

Orchestrate combines these with the **verification-side** inputs (coverage gate + live-check from `TEST_RESULTS.md`) to score round confidence — e.g. "verified three ways, all agree" vs. "thin — one reviewer, no live test." Low confidence + reversible → another round; low confidence + consequential → escalate. (Synthesized by orchestrate.)

---

## 8) Per-repo instantiation

Kept separate so the contract above stays portable. Each repo fills these from its own `CLAUDE_ORCHESTRATION_GUIDE.md`:

- The diff under review is the working-tree change for the round's tasks (`git diff`).
- The verification gate (`verify`) runs the repo's real test + smoke commands (guide §5).
- Reachability assessment accounts for the repo's guardrails (guide §6) — e.g. a silently-ignored param that *looks* like it works is `live`, not inert.
- Reversibility posture comes from the guide. A SaaS repo with dark-launchable changes and one-commit reverts can be **aggressive** (auto-resolve freely; hard human gates only on the irreversible calls: money, contracts, scope, security posture).
