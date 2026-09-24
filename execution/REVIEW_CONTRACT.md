# Adversarial Review Contract

The machine-routable output the adversarial-review phase emits each loop round, and the rules for producing it. `/orchestrate` reads this artifact and routes off it — so the contract is the seam between *assessment* (the reviewers' job) and *routing* (orchestrate's job).

**One hard rule up front: the reviewers assess; orchestrate decides.** A reviewer flags severity, reachability, and whether something looks like a human call. It never authorizes or applies a fix. Routing — fix now / park / pause for a human — is orchestrate's policy (defined in `orchestrate.md`, not here).

---

## 1) The artifact

The review phase writes `REVIEW.md` in the workstream folder (`docs/execution/active/<id>/REVIEW.md`), **append-per-round**: each loop round adds a new `## Round N` block, written once at the close of the round. Orchestrate routes off the **last** block, but it **reads every block** — earlier blocks are not merely an audit trail, they are the **ledger**: replaying their `Carried:` lines reconstructs the seen-set (every `F#` ever raised and its current disposition), which is what stops settled findings from being re-litigated every round.

Two destinations, by audience:

- **`REVIEW.md`** — the structured verdict block (below). Machine-routable, terse. This is what orchestrate parses.
- **`RUN_LOG.md`** — the round narrative + the reviewers' prose (what they looked at, why a finding matters). Human audit trail. **The prose never goes to the PM directly** — it lives here for the record.

Adding `REVIEW.md` is the one schema change to the workstream spine; everything else reuses the existing files.

---

## 2) Verdict block format

Each `## Round N` block has four parts: the verdict line, the carry lines, the findings table, and per-finding detail.

```markdown
## Round N — YYYY-MM-DD

VERDICT: CONCERNS
Personas: adversarial-reviewer, run, code-review (3 independent passes)
Carried: settled — resolved F1, F5 · parked F4 → R-003 · rejected F7
Carried: open — F6
Seen-set: F1–F9 · 9 findings · 5 terminal, 4 open
Progress: 4 settled, 2 new, 1 suppressed re-raise

| ID  | SEVERITY         | reachability       | consensus | FLAG-HUMAN | disposition        | summary                       |
| --- | ---------------- | ------------------ | --------- | ---------- | ------------------ | ----------------------------- |
| F8  | CRITICAL-ON-FLIP | dormant-at-default | 2/3       | no         | open               | unbounded text cache          |
| F9  | NOTE             | live               | 3/3       | no         | open               | inconsistent error-log prefix |
| F2  | WARNING          | live               | 1/3       | no         | re-raised → open   | N+1 fetch — now on the default path (reachability dormant→live) |
| F3  | NOTE             | test-only          | 1/3       | no         | re-raised → parked | settled round 2 (R-002); unchanged severity, symbol untouched this round |

### Detail

**F8 — unbounded text cache** (`src/lib/cache.ts` · `TextCache.put()` · L42)
Cache has no eviction; grows without bound. Dormant today because the caching flag
defaults off. Becomes CRITICAL if `ENABLE_TEXT_CACHE` is ever flipped on in prod.
Raised by: adversarial-reviewer, run.

**F2 — RE-RAISED → open** (`src/lib/enrich.ts` · `enrichTracks()`)
Parked round 2 at `dormant-at-default`. The round-4 wiring put `enrichTracks()` on the
default request path — escape hatch: reachability went live. Routed as a fresh WARNING.

**F3 — RE-RAISED → parked** (`tests/lib/enrich.test.ts` · `describe("enrich")`)
Same claim as round 2 (`NOTE`, `test-only`, R-002). Severity unchanged, reachability
unchanged, and this round's diff did not touch the anchor symbol. Suppressed, not re-routed.
```

- **IDs are stable across rounds** (`F1`, `F2`, …) — decoupled from severity so a finding can be tracked even if its severity changes. Severity lives in its own column; lifecycle lives in `disposition`. (This is why we don't use the brief's illustrative `C1`/`W1` prefixes — `C1` becomes `F1` with `SEVERITY: CRITICAL`.)
- **The findings table lists findings raised *this* round.** Earlier findings are not re-listed — their state lives in the `Carried:` lines. The single exception is a **re-raise**, which carries an existing `F#` back into the table because a re-raise is new evidence about an old finding.
- **A finding related to an earlier one by claim only** (same invariant, different anchor) is a new `F#`. Its Detail entry adds one line, `Related: F4 (same invariant, different anchor)`, and nothing else about it differs from any other new finding.
- **Every finding's Detail entry carries an anchor**: `` (`path/to/file.ts` · `symbolName()` · L42-58) ``. The symbol is the cross-round identity; the line range is a reading hint and is **not** part of any matching key — a fix moves every line below it, and a fix that *is* an extraction moves the code to another file.
- **The `Carried:` / `Seen-set:` / `Progress:` lines are mandatory in every block**, including round 1 (`Carried: settled — none`). `Carried: settled` lists only *transitions since the previous block*, so each `F#` appears in one settled list each time it settles — once, unless an anchor-match re-raise reopened it (orchestrate 2d's escape hatch), in which case the replay keeps the latest. Growth is O(findings), not O(rounds × findings). `Seen-set:` is the **checksum**: `terminal + open` must equal the finding count, and the count must equal the highest `F#`. A hand-maintained ledger with no checksum is a cell that rots.

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

### disposition — *where the finding is in its lifecycle*

| Token | Terminal | Meaning |
| --- | --- | --- |
| `open` | no | Raised and not settled — a fix is queued, or a `FLAG-HUMAN` awaits a ruling. The only state that counts toward `VERDICT`. |
| `resolved` | yes | Fix landed **and** a later round's review over the fix diff did not re-raise it. Never assertable in the round the fix lands. |
| `parked` | yes | Real, accepted, deferred — with an `R-###` row in `RISKS_AND_BLOCKERS.md`. Name it: `parked F4 → R-003`. |
| `rejected` | yes | Not a bug — false positive, misread, or a deliberate design the reviewer didn't know about. |
| `duplicate` | yes | Real, but the same issue as an existing finding. Name it: `duplicate F31 → F26`. Distinct from `rejected`: a duplicate of an **open** finding is still an open problem. |
| `re-raised → <outcome>` | depends | Normalization matched this round's raw finding to an `F#` that already held a terminal disposition. `<outcome>` is either that same terminal token (**suppressed** — the call stands) or `open` (**reopened** — orchestrate's escape hatch fired, see `orchestrate.md` 2d). |

There are exactly two cell forms: a bare token, or `re-raised → <token>`. Nothing else parses.

A terminal disposition is a **commitment**, not a summary: it is what lets the next round skip re-routing. Don't write one you're not prepared to have the loop act on for the rest of the run.

### VERDICT — *the round's overall gate*

| Token | When | 
| --- | --- |
| `CLEAN` | Nothing above `NOTE` has disposition `open`. The loop may exit (pending orchestrate's approval card). |
| `CONCERNS` | `open` findings exist, but none are `live` `CRITICAL` and none are `FLAG-HUMAN`. Orchestrate auto-resolves/parks per policy, then re-reviews. |
| `BLOCK` | At least one **`open`** `CRITICAL` at `live` reachability, **or** at least one **`open`** `FLAG-HUMAN`. Must be addressed before the round can reach `CLEAN`. |

**`VERDICT` is derived from the open set, not from the round's table.** A finding with a terminal disposition is not open — *including one re-raised and suppressed this round*. A suppressed `re-raised → parked` CRITICAL does not force `BLOCK`; if it did, one parked finding the reviewer keeps rediscovering would hold the loop at `BLOCK` forever, which is the failure this ledger exists to prevent. A `re-raised → open` finding (escape hatch fired) counts exactly as a new finding of that severity would.

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

A normalize step (orchestrate, or a thin sub-agent it spawns) merges the passes into the single block. **This step runs downstream of assessment and never feeds anything back into it** — the passes have already returned, and they saw only the diff.

0. **Build the seen-set first.** Read **every** prior `## Round` block and replay its `Carried:` lines into a map of `F# → (disposition, severity-at-settlement, reachability-at-settlement, anchor, claim)`. Verify the total against the last block's `Seen-set:` line. This happens **before any `F#` is assigned** — the seen-set is what a new raw finding is matched against.
1. **Translate** each pass's findings into the contract vocab (assign `SEVERITY` + `reachability` per the tables above; assess `FLAG-HUMAN`; record the **anchor** — file + enclosing symbol — and a one-sentence **claim**, the invariant being violated).
2. **Dedup, in two directions.**
	- *Within the round*, across the concurrent passes: by `(file, approximate line, issue class)`. The same underlying issue raised by multiple passes is one finding.
	- *Across rounds*, against the whole seen-set: match on **anchor + issue class** (file + enclosing symbol, same issue class). Never match across differing issue classes — a `test-only` coverage gap and a `live` correctness bug at one symbol are two findings. Line numbers are **not** a cross-round key.
	- **A claim-only match is a new finding.** When two findings share an invariant at *different* anchors (same crowd-out, different retrieval arm; same race, different call site), issue the next free `F#` with disposition `open`, and record the relationship in its Detail entry as `Related: F4 (same invariant, different anchor)`. Different code is different code: the earlier ruling was about a symbol this finding does not touch, so it cannot settle it, and reusing its ID would put one `F#` in two settled lists. The note keeps the ledger coherent; it never suppresses and never skips work.
	- **When unsure, issue a new `F#`.** Bias toward a false miss. A false miss costs one round of re-routing and is recovered next round with `duplicate`; a false match can bury a real new bug inside a settled finding.
3. **Severity = the max** any pass assigned it. Don't let one lenient pass mask a critical. (When in doubt between two tiers, take the higher.)
4. **consensus = M/N** — how many of the N passes independently surfaced it. `1/3` is thin (could be a false positive, could be a real blind-spot catch); `3/3` is strong. Consensus is computed over **this round's** passes, whatever the finding's history.
5. **FLAG-HUMAN = yes if any** pass flagged it. Conservative — a human call surfaced by one reviewer is still a human call.
6. **Assign dispositions.** A match to an `F#` holding a terminal disposition is written `re-raised → …`; orchestrate's 2d decides the outcome. Unmatched findings get the next free `F#` and disposition `open`.
7. **Derive VERDICT** per §3's table **from the open set**.
8. **Write the `Carried:` / `Seen-set:` / `Progress:` lines** from the seen-set as updated by this round.

Stable IDs carry across rounds by the matching procedure in step 2 — that procedure, not good intentions, is what makes "stable" true. A finding open last round keeps its ID; a settled finding that resurfaces keeps its ID *and* its disposition.

**Matching is one judgment with no consensus behind it, so it is capped.** A re-raise at full consensus (`N/N` of the passes actually run) is never suppressed on a match alone — orchestrate routes it or stops (2d). The ledger may overrule one reviewer's memory; it may never overrule all of them at once.

---

## 6) Handoff to orchestrate

Orchestrate reads the latest `## Round N` block and applies its own **severity→action policy** (owned in `orchestrate.md`). For reference, the routing it will key off these tokens looks like:

- `CRITICAL` + `live` → executor fixes → re-review.
- `CRITICAL-ON-FLIP` / `dormant-at-default` → fix if cheap+safe, else park on the flip-gate in `RISKS_AND_BLOCKERS.md`.
- `WARNING` → fix if cheap, else park.
- `NOTE` → auto-fix trivial, log the rest.
- Any `FLAG-HUMAN: yes` → pause the loop, surface on the approval card.
- `re-raised` with a terminal outcome → **not routed**; the call stands.
- `re-raised → open` (severity rose, reachability went live, the round's diff touched the anchor symbol, or the re-raise is at full consensus) → routed by its severity row, exactly as a new finding.
- A new `F#` with a `Related:` note (a claim-only match, §5) → an ordinary new finding, routed by its severity row.

Orchestrate reads the **latest** block to route, and **every** block to build the seen-set. The contract's job is to make those tokens trustworthy and uniform. It does **not** define the actions — that's orchestrate. Where work is reversible (SaaS, flags, dark-launch, one-commit reverts), orchestrate auto-resolves aggressively; the human gates are reserved for the irreversible calls (money, contracts, scope, security posture), not routine engineering.

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
