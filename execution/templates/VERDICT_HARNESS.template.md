# Verdict Harness — `<workstream>` · `<gate name>`

The living evidence log for a **validation-gate workstream**: one whose *done* is a **human keep/kill/extend verdict after real use**, not a passing build. The loop builds the surfaces + scaffolds this harness; **you** live in it and write the verdict — the loop can't render it (it can't dogfood). See `CLAUDE_ORCHESTRATION_GUIDE.md` → "Validation-gate workstreams."

**How to use it:** log as you go, not at the deadline. One line the day it happens beats a reconstruction two weeks later.

- **Window:** started ______ → +`<N days/weeks>` ______ → verdict by `<deadline>`.
- **How you actually run it daily:** `<the daily-driver command / real-use surface>`.

---

## Gate criteria at a glance — running tallies

*The real acceptance bar — the thresholds this gate turns on. Fill from the workstream's acceptance criteria; a tally updated daily is the evidence.*

| # | Criterion | Target | Running | Met? |
|---|-----------|--------|---------|------|
| 1 | `<criterion>` | `<threshold>` | | ◻ |
| 2 | `<criterion>` | `<threshold>` | | ◻ |
| … | `<written verdict + any handoff deliverable>` | by `<deadline>` | | ◻ |

---

## Usage log

*Did I reach for it, and for what? The single most important signal — a tool is validated by living in it. A day you didn't reach for it is data too (why not?).*

| Date | Used it? | For what | Notes |
|------|----------|----------|-------|
|      |          |          |       |

---

## Evidence logs

*One table per criterion that needs concrete **instances**, not just a count (e.g. "3 times X happened", "5 Y accepted"). Real instances, not hypotheticals — this is what makes the verdict defensible.*

### `<Evidence criterion A — e.g. trust events (≥N)>`

| # | Date | Context | What happened |
|---|------|---------|---------------|
| 1 |      |         |               |

### `<Evidence criterion B>`

| # | Date | Context | What happened |
|---|------|---------|---------------|
| 1 |      |         |               |

---

## Safety / invariant log — this section staying EMPTY is the pass condition

*Any violation of the workstream's core invariant (unintended writes, data loss, a regression the gate forbids). An entry here is a **gate failure to investigate**, not just a bug.*

| Date | What happened | Severity | Resolution |
|------|---------------|----------|------------|
|      | *(none — good)* |        |            |

---

## Friction list

*Every rough edge that made you hesitate, wait, or reach for the old tool instead. Sev: 🔴 blocks use · 🟡 annoys · ⚪ nit. The honest risk to the verdict: a 🔴 that makes you stop reaching for it produces a false "kill" — so 🔴s get fixed **mid-window**; 🟡/⚪ are logged and batched (fixing them mid-stream turns the gate back into a build sprint). Capture via a lightweight command so logging is one action.*

**Capture-only — status is derived, not hand-maintained.** The row is append-only (`Sev · Date · Friction`); `Resolved` holds ONLY a merged-PR link, filled by **reconcile**, not by remembering. Blank = open. There is deliberately no "in-progress" state — that's the cell that rots and lies.

| Sev | Date | Friction | Resolved |
|-----|------|----------|----------|
|     |      |          | *(blank = open; `#PR` once a fix merges)* |

**Self-healing chain** (join key = the entry's `date + short slug`): (1) **log** it — append-only, never stale; (2) **fix** it later on a branch → PR whose title/body names the entry (`friction: <date> <slug>`) — a byproduct of describing the fix, not a chore; (3) **reconcile** (`<capture-command> reconcile`) scans merged PRs, follows those references, and fills `Resolved → #PR`. The log is a cache rebuilt from git, so a forgotten update self-heals with one command; an unreferenced fix is surfaced for a quick manual match, never guessed. Turning a 🔴 (or promoted 🟡) into a fix workstream — the clarified entry IS the objective — see `CLAUDE_ORCHESTRATION_GUIDE.md` → "Validation-gate workstreams."

---

## Open posture calls — rule these FROM the evidence, not up front

*Any "we'll decide this from real use" question the workstream deferred. Rule each from the log at verdict time.*

- **`<question>`** — `<the from-evidence rule>` → ruling: ____

---

## `<Handoff deliverable, if any — e.g. the next-phase gate list>`

*Grow it as real use surfaces needs.*

- `<seed items>`
- *(add from use: ____)*

---

## The verdict — write by `<deadline>`

**Framework:** *keep* = earns real use + the criteria are met → proceed. *extend* = close, but named gaps must land first (list them). *kill* = the core claim didn't hold in real use — say why, from the evidence above.

- **Verdict:** ____ (keep / kill / extend)
- **Evidence basis:** `<criterion tallies>` · reached-for-it ___/`<window>`
- **If extend — what must land first:** ____
- **Handoff deliverable:** see above
- **Written:** ____ (date)
