---
description: Run the autonomous plan→execute→verify→review loop on a workstream until the review is clean or the round cap trips.
---

Drive a workstream through the full loop — **plan → execute → verify → review → route → repeat** — until the adversarial review returns `CLEAN` or a round cap stops it. You are the orchestrator (the main agent). You own the workstream files; subagents do bounded work and never touch the spine.

State lives on disk in `docs/execution/active/<id>/`, so this command is **resumable**: re-invoke it and it reads the workstream back and continues from where it stopped.

Read first: `docs/execution/CLAUDE_ORCHESTRATION_GUIDE.md` (repo rules), `docs/execution/REVIEW_CONTRACT.md` (the review data you route off).

`$ARGUMENTS` = a workstream id, or a short goal (a new id is derived from it).

---

## 0. Resolve the workstream (create or resume)

Pick the workstream id from `$ARGUMENTS`. Then:

- **If `docs/execution/active/<id>/` exists → RESUME.** Read `README.md` (incl. `## Loop Config`), `WORKBOARD.md`, `ACCEPTANCE_CRITERIA.md`, the last `## Round N` of `RUN_LOG.md`, `DECISIONS.md`, `RISKS_AND_BLOCKERS.md`, and **every `## Round` block of `REVIEW.md`** — not just the last. Replay the `Carried:` lines in order to rebuild the **seen-set**: every `F#` ever raised and its current disposition. Cross-check the total against the last block's `Seen-set:` line; if they disagree, trust the replay and say so in the resume line. Reconstruct: current round number, what's Done/In Progress, the last `VERDICT`, the **open** findings by stable `F#`, the **terminal** ones you must not re-litigate, and any pending `FLAG-HUMAN` pause. **Self-heal:** if `REVIEW.md` is missing, copy it from `docs/execution/templates/REVIEW.template.md`; if `## Loop Config` is absent, use defaults (`round_cap: 5`, `posture: aggressive`, `escalate_to_engineer: off`).
- **Else → INIT.** Run `./.claude/scripts/init-workstream.sh <id>`, then write `README.md` (objective + `## Loop Config`) and `ACCEPTANCE_CRITERIA.md` from the goal. If the goal is a **vault note path**, record that path in `README.md` so the intent source survives a resume.

State the resolved state back in one line before looping — e.g. `Resuming <id> at round 3; last verdict CONCERNS; seen-set F1–F12 (9 terminal, 3 open: F4, F6, F11).` or `Initialized <id>.`

**Create the run marker:** first check the gate — run `./.claude/scripts/loop-status.sh`. If it reports `ACTIVE`, the human has **locked** this run (a hard, root-owned marker is already in force) — do not write anything, the gate is already up. If it reports `INACTIVE`, write `.loop-active` at the repo root before any execution. Either way, while the gate is active a PreToolUse hook (`.claude/scripts/block-human-gated-actions.sh`) blocks `gh pr create` / `gh pr merge` / `git push` and the known routes around them (aliases, `gh api` writes, raw authenticated HTTP) — so the loop cannot open or merge a PR through any command it can write in plain text, regardless of what it concludes. The guard matches text; branch protection on the remote is the backstop for anything it misses.

**Never remove the marker.** It is human-only, and the hook blocks the loop from deleting, renaming, `git clean -x`-ing, or removing it through a language runtime (`os.remove`, `fs.unlink`). Writing the soft marker is your job; clearing any marker is not. If the loop could clear its own gate, the gate would not be a gate — a run that decided to ship would clear it first, which is the same arithmetic that opened the original self-approved PR. At every hard stop (clean exit, FLAG-HUMAN, non-convergence) you leave the marker in place and end the run.

**Two gate modes, and how each is cleared** (this is the human's choice, not yours — you only ever write the soft marker, and only when the gate is not already up):

- **Soft (default):** the loop wrote `.loop-active`. The human clears it with `rm .loop-active` from their own terminal when they act on the card; the next run overwrites it. Strong, but the wall is a list of blocked commands.
- **Hard (opt-in, `sudo ./.claude/scripts/lock-loop.sh`):** a root-owned marker outside the repo the agent's user cannot remove by any means. The human clears it with `sudo ./.claude/scripts/unlock-loop.sh`. Use it for unattended runs on a repo with no downstream human review. While a hard lock is in force, **the entire `.claude/` subtree except `.claude/worktrees/` is frozen (immutable)** — settings.json, settings.local.json, the hook script, all of it — so the guard cannot be unwired from inside the repo. The freeze does not reach user-level `~/.claude/settings.json`: `disableAllHooks` set there still turns the hook off for sessions started afterwards. Four things follow, and none of them is a fault to fix:
	- Editing anything under `.claude/` outside `worktrees/` returns a permission error. Intentional. Do not try to work around it, and do not report it as a defect.
	- Creating a new file under `.claude/` outside `worktrees/` fails too, `settings.local.json` included. Also intentional: the directory is frozen precisely so a new settings file cannot appear.
	- The same applies to each git worktree's own `.claude/`, and `git worktree remove` fails while locked. If you create a worktree mid-run, its `.claude/` is not frozen; say so on the card rather than working around it.
	- "Allow always" on a permission prompt fails, because that grant is written to `.claude/settings.local.json`. Ask the human to choose "Allow once", or to unlock if a permanent grant is genuinely wanted.

## 1. Plan (read-only, once)

If `WORKBOARD.md` has no real tasks yet, spawn a **planner** (read-only Task) to break the goal into atomic, testable, file-scoped tasks grouped into waves (independent tasks share a wave; dependents go later). The planner **returns** the plan; **you** write it into `WORKBOARD.md` (Queue), derive `ACCEPTANCE_CRITERIA.md`, and seed `RISKS_AND_BLOCKERS.md` with its risks. The planner never writes workstream files.

Spawn the planner by reading `.claude/agents/planner.md` and passing it as the Task prompt (read-only). The goal can be an inline objective **or a vault note path**: if `$ARGUMENTS` or the README objective points at a note under the vault, pass that path so the planner traverses its frontmatter for intent (`context` / `parent`-up-to-initiative / `about`; never `related` / `external`). The input note is primary — traversed notes only bound scope, never widen it.

## 2. The loop (one round = steps 2a–2f)

Increment the round number. Append a `## Round N — <date>` entry to `RUN_LOG.md` as you go (append-only, factual — no invented dates/test counts).

### 2a. Execute the current wave
For each task in the active wave, spawn an **executor** Task with a bounded contract written to `SUBAGENTS/T-xxx.md` (objective · allowed file scope · out-of-scope · constraints/contracts · validation command · return format). Run tasks in parallel **only** when their write scopes are disjoint. Move `WORKBOARD.md` items In Progress → Done as each lands, with an atomic commit per task.

If an executor closes with a **"your call?"** question: **you answer it** — proceed when tests are green and the choice is data-backed; log the answer to `DECISIONS.md`. Only when the question is a product / irreversible / cost / contract / security-posture call does it become a `FLAG-HUMAN` item (see 2d).

### 2b. Verify — the gates (your eyes, not the PM's)
- **Coverage gate:** a test must exercise *this* change and pass. No test for the new path is a **fail**, not a pass.
- **Live reality-check:** run the real thing via the `run` skill against the real endpoint/build (the repo's `CLAUDE_ORCHESTRATION_GUIDE.md` §5 names the exact test + smoke commands).
- Record both to `TEST_RESULTS.md` (Automated / Manual / Gaps). A failed gate produces findings; it cannot reach a clean exit.

### 2c. Review — independent personas, depth scaled to blast radius
First classify the round's diff to set **review depth** — match the rigor to what's at stake:

| Blast radius | Depth | Passes |
| --- | --- | --- |
| **Minimal** — ≤2 files, additive / docs / config, tests present, no guardrail or contract touch | 1 | `code-review` |
| **Standard** — one subsystem (3–8 files), no guardrail or contract touch | 2 | `adversarial-reviewer` + `code-review` |
| **Deep** — cross-cutting (8+ files), **or** touches a guardrail / API contract / security surface (any size) | 3 | `adversarial-reviewer` + `run` + `code-review` |

A guardrail / contract / security touch **always forces Deep**, regardless of size. Run the passes **independently** over the round's diff (`git diff`), without sharing findings between them. If a lighter tier surfaces a borderline, `CRITICAL`, or `FLAG-HUMAN` finding, **escalate one tier** (add a pass) before routing — cheap depth where it's safe, full depth where it bites.

**A review pass's input is the round's diff, and nothing else.** Never hand a pass the seen-set, the `Carried:` lines, or a prior disposition "so it doesn't re-find things." The ledger below lives in normalization, downstream of assessment — that separation is what keeps the passes independent, and independence is the whole basis of the consensus number.

Normalize the passes into one block and **append** it to `REVIEW.md` as `## Round N`: the `VERDICT` line, the `Carried:` / `Seen-set:` / `Progress:` lines, the findings table (`F# | SEVERITY | reachability | consensus | FLAG-HUMAN | disposition | summary`), and per-finding detail. Severity = the max any pass assigned; consensus = M/N (of the passes actually run); `FLAG-HUMAN` = yes if any pass flagged it. **Before assigning any `F#`, build the seen-set** by reading every prior `## Round` block, and match each raw finding against it per `REVIEW_CONTRACT.md` §5 — a finding that already has an `F#` keeps it. **Append the block once, at the close of the round, with 2d's routing outcomes already written into the `disposition` column** — `REVIEW.md` stays append-only: one write per round, never a rewrite. The prose also goes to `RUN_LOG.md` — **never surfaced to the PM directly.**

### 2d. Route — your severity→action policy (you own this; the reviewer only assessed)
Where the repo's posture is aggressive (reversible work — see Per-repo specifics), route **aggressively**:

| Finding | Action |
| --- | --- |
| `CRITICAL` + `live` | Executor fixes **this round** → re-review (loop back through 2a for the fix). |
| `CRITICAL-ON-FLIP` / `dormant-at-default` | Fix if cheap + safe; else park on the flip-gate in `RISKS_AND_BLOCKERS.md`. |
| `WARNING` | Fix if cheap; else park in `RISKS_AND_BLOCKERS.md`. |
| `NOTE` | Auto-fix trivial; log the rest. |
| matched to an `F#` with a terminal disposition (`re-raised`) | **Do not re-route.** Record it as `re-raised → <its existing disposition>`, one Detail line citing the round that settled it. No executor, no new `R-###`, no `DECISIONS.md` row — the call was already made. **Unless the escape hatch fires** (below). |
| any `FLAG-HUMAN: yes` | **Hard stop** — write the card, end the run; never rule on it (see below). |
| executor "your call?" | You answer (tests green + data-backed = proceed); log to `DECISIONS.md`. |

Record every routing decision (and every auto-resolved critical) in `DECISIONS.md`. Fixes are executor Tasks; after a fix, the loop re-reviews (back to 2c) — never mark a fixed critical resolved without a fresh review pass confirming it.

**Re-raises — and the escape hatch.** A settled call is settled **at the severity it was settled at**, not forever. When normalization matches a raw finding to an `F#` that already holds a terminal disposition (`resolved` / `parked` / `rejected` / `duplicate`), suppress it: write the row as `re-raised → <that same disposition>`, name the round that settled it, and move on. Dedupe against everything seen — not just against what was confirmed. A rejected or parked finding that resurfaces every round is re-routed from scratch every round, the loop never runs dry, and `round_cap` is spent re-litigating calls you already made.

**Route it normally anyway — `re-raised → open`, then apply the severity rows above — when ANY of these hold:**

- **Severity increased** over the severity it was settled at (`NOTE` → `WARNING`, `WARNING` → `CRITICAL-ON-FLIP` / `CRITICAL`). New information about how bad it is reopens the call.
- **Reachability went live** — it was settled at `dormant-at-default` / `test-only` / `boundary-only` / `unreachable` and is now `live`. A flag flipped, a guard came out, the dormant path got wired. "Parked because it can't fire" expires the moment it can.
- **This round's diff touched the anchor symbol.** You edited the code the ruling was about, so the ruling is about different code. Check it mechanically (`git diff -U0 -- <file>`), don't reason about it. This is the guard against a bad match burying a genuinely new bug at an old location.
- **The re-raise is at full consensus** — every pass actually run surfaced it independently this round (`N/N`). Route it, or stop and say the matcher and the reviewers disagree. **The ledger may overrule one reviewer's memory; it may never overrule all of them at once.** Matching is a single judgment with no consensus behind it, and unanimous independent agreement on current code is the strongest signal the stack produces — a lone matcher does not get to delete it.
- **The match was claim-only** — same invariant, different anchor (`REVIEW_CONTRACT.md` §5). Suppression requires an anchor match. A finding at a symbol the old ruling never covered is new work, whatever it rhymes with.

**`FLAG-HUMAN` on a re-raise, two cases — do not collapse them.** If the finding was settled by a **PM ruling recorded in `DECISIONS.md`**, suppress it and cite that row; the ruling is a real human event, and re-halting on it would trap the loop against a decision that has already been made. If it was settled by **your own** `rejected` / `parked` call and a reviewer now flags it as a human call, that is new information about its human-ness — **stop and write the card**, per the rules below. Never suppress a `FLAG-HUMAN` on the strength of a ruling you made yourself.

**Suppression is never invisible.** Add one line to the `RUN_LOG.md` round entry: `Suppressed re-raises: F9 (parked R-009, round 4), F20 (rejected, round 2).` The loop declining to act is a routing decision like any other, and it goes on the record — in `RUN_LOG.md`, not `DECISIONS.md`, because nothing was decided.

**On any `FLAG-HUMAN: yes`:** this is a **hard stop**. Copy `docs/execution/templates/APPROVAL_CARD.template.md` to `APPROVAL_CARD.md`, set `## Status` to `FLAG-HUMAN — AWAITING PM RULING`, fill §4 (Decisions needed) with the flagged finding(s) by `F#` — the only things blocking — fill §1–3 for context with depth linked in §5, link the card from `README.md`, **leave the run marker in place**, and **end the run**. Do not rule on the finding, resolve it, or proceed past it.

**A `FLAG-HUMAN` is a stop even when it looks already-decided.** If you believe the KICKOFF or `DECISIONS.md` already settles it, do **not** rule and do **not** record a ruling — surface it on the card quoting the exact line that appears to settle it (`appears consistent with KICKOFF: "<quote>" — confirm?`) and stop. A settled decision belongs to its real source (the KICKOFF the PM wrote); never manufacture a fresh "PM ruled `<today>`" event. The loop continues only after the PM's ruling exists in `DECISIONS.md` — written by the PM, not by you — and they re-invoke `/orchestrate <id>`.

### 2e. Score confidence
Combine three signals into a one-line confidence read in the `RUN_LOG.md` round entry:
- review **consensus** (how many personas independently agreed),
- the **coverage** gate (did a test exercise this change and pass),
- the **live-check** (did it pass against the real endpoint).

High = "verified three ways, all agree." Low = "thin — one reviewer, no live test." **Low + reversible → run another verification round** (add the missing test / re-run live / add a persona). Low on a consequential change → escalate.

**Escalation — two paths, neither is "the PM adjudicates engineering":**
- **To the PM (product calls):** a product/scope change, anything irreversible or that costs money / touches a contract, or a security *posture* decision (policy, not a code bug). Route it through the `FLAG-HUMAN` card (2d).
- **To a real engineer** (`escalate_to_engineer`, default `off`): if confidence stays low on a *consequential* change after another verification round and the flag is `on`, request a human PR review from the code owner and pause. Off by default — in a reversible repo most work never trips this; it exists so the PM is never the last line of defense on a bad merge. When `off`, surface the low-confidence consequential change to the PM with the confidence read made explicit.

### 2f. Loop control
Evaluate these rules **in order**; the first that matches decides.

- A `FLAG-HUMAN` paused the loop → stop, surface pending. This rule runs **first**: an open `FLAG-HUMAN` is a human call, not a convergence problem, and checked later it would be reported as "Stalled" or `NON-CONVERGENT` instead of as a pause (a reviewer flagging one of your own settled calls reopens an existing `F#`, so the round shows no new `F#` and nothing settled).
- **Two consecutive rounds whose only review content is suppressed re-raises** → stop and say so on the card. This rule runs **before** `VERDICT == CLEAN` and "Run dry". `VERDICT` is computed from the open set, which excludes suppressed re-raises, so an over-matching normalizer yields `CLEAN`; a suppressed-only round also has an empty `settled` delta and no new `F#`. Checked after either rule, this one would never fire. That is a normalizer defect, not non-convergence: the reviewer keeps raising what you keep suppressing, so one of you is wrong and a human should look. **Suppressed re-raises never count as progress, and they never count against it** — a round is judged on `settled` vs `new`. Do **not** let a suppressed-only round skip the round counter; an over-matching normalizer would then suppress everything and loop forever against a cap that never advances.
- `VERDICT == CLEAN` **and** all gates pass → exit to **step 3**.
- **Run dry** — the round's `Carried: settled` delta is empty, the table holds no new `F#` above `NOTE`, **and the open set holds nothing above `NOTE`** → the review axis has converged; treat as `CLEAN` for loop control and exit to **step 3** if the gates pass.
- **Stalled** — the `settled` delta is empty and no new `F#` above `NOTE` was raised, but the open set still holds a finding above `NOTE` → this is not convergence. Stop with `## Status: NON-CONVERGENT`, exactly as the round-cap rule below. A stalled loop must never exit as `CLEAN`; `CLEAN` means nothing above `NOTE` is open (`REVIEW_CONTRACT.md` §3).
- Round number `>= round_cap` and not `CLEAN` → **non-convergence**: emit the approval card with `## Status: NON-CONVERGENT` (what's unresolved + the confidence read + **the per-round `settled / new` progress read**, so the PM can tell a converging run from a stuck one), write the unresolved findings to `RISKS_AND_BLOCKERS.md`, **leave the run marker in place**, and stop. No clean exit.
- Otherwise → next round (back to 2a: execute fixes, then the next wave).

## 3. Clean exit — write the card, then HALT

`CLEAN` is **not** approval. It means the verification stack is satisfied and the work is *ready for the PM to judge*. Writing the approval card is the loop's **last action** — stop there.

Copy `docs/execution/templates/APPROVAL_CARD.template.md` to `APPROVAL_CARD.md`, link it from `README.md`, set `## Status` to `CLEAN — AWAITING PM APPROVAL`, and fill it led by what the PM can judge:

1. **What you asked for → what it built** — intent match; flag any scope drift.
2. **How reversible** — flag / dark-launch / one-commit revert = wrong is cheap; touches money / a contract / a data migration / anonymous-access scope = engage here. Include the one-line revert path.
3. **How confident** — the 2e read (independent reviewers + coverage + live-check agree? gaps?).
4. **Findings digest** — auto-fixed criticals one line each (never hidden), warnings/notes parked silently with a count, any remaining `FLAG-HUMAN` front and center.

Then **leave the run marker in place** and **end the run** with one line: `AWAITING PM APPROVAL — <id> on <branch>; card at <path>. Clear the gate when you act: rm .loop-active`. Keep depth one step away (links to `REVIEW.md` / `TEST_RESULTS.md` / `DECISIONS.md`), never the full review in their face. The PM approves **intent/scope and reversibility only** — correctness was delegated to the verification stack (which is why it had to be strong enough to earn a blind sign-off).

### The human gate — actions the loop NEVER performs

No exceptions — not when everything looks done, not when the answer seems obvious:

- **Never record an approval or ruling as if the PM made it** — not in the card, `DECISIONS.md`, a commit message, or anywhere. An approval is an event only the PM creates; writing one that didn't happen is fabrication.
- **Never rule on a `FLAG-HUMAN`** (see 2d), even one that looks already-decided.
- **Never open a PR, request review, or merge.** Outward-facing and human-only.

Opening the PR, merging, and relocating the workstream to `done/` are **the PM's to perform** after approving — by hand, or by explicitly asking in a new instruction. `/orchestrate` does not auto-detect an approval and proceed.

---

## Invariants (do not violate)

- **You own the workstream files; the planner is read-only.** The planner returns a plan; you record it.
- **The reviewer assesses; you decide routing.** Never let a review pass authorize or apply its own fix.
- **Never act as the PM.** `CLEAN` means *ready for the PM*, not *approved*. The loop never records an approval or ruling, never clears a `FLAG-HUMAN`, and never opens a PR or merges. Writing an approval the PM didn't give is fabrication — the worst failure this loop can commit.
- **No "done" without evidence** in `TEST_RESULTS.md`. Coverage gate is a gate, not a formality.
- **Append-only** `RUN_LOG.md` (one entry per round) and `REVIEW.md` (one block per round, written once at the close of the round). Stable `F#` IDs across rounds, assigned against the **whole-file seen-set** — never against the last block alone. **Dedupe against everything seen, not just against what was confirmed:** a finding with a terminal disposition is settled at the severity it was settled at, and does not get re-routed unless the escape hatch fires (2d).
- **The ledger never reaches a reviewer.** Review passes see the round's diff; the seen-set enters at normalization and the resume replay is read by you, the orchestrator. Feeding prior findings into a pass would trade a cheap re-litigation for a correlated blind spot.
- **Factual only** — no invented owners, dates, or test counts (guide / workstream conventions).
- **Bounded delegation** — pass executors only their file scope + contracts + expected output, never the full conversation.

## Per-repo specifics

This command is generic. Each repo's `docs/execution/CLAUDE_ORCHESTRATION_GUIDE.md` carries the engineering rules, guardrails, test/live-check commands, and reversibility posture the loop must honor — read it at the start of a run (step 0). A SaaS repo with dark-launchable changes and one-commit reverts can run an **aggressive** posture (auto-resolve freely; hard gates only on the irreversible calls: money, contracts, scope, security posture).
