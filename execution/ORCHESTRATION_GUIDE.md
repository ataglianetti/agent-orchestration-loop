# Claude Code Orchestration Guide

The operating system for multi-step implementation work in this repo — any change spanning multiple files, commits, or sessions. Pairs with `/orchestrate` (the autonomous loop), `REVIEW_CONTRACT.md` (the review data the loop routes off), and the workstream templates in `templates/`.

> **Sections 1, 5 (commands), 6, and 7 are repo-specific — fill them when you deploy this into a repo.** Sections 2–4 are the generic protocol and rarely change.

## 1) Core Engineering Rules  *(FILL PER REPO)*

- The API contracts, layering rules, and performance budgets specific to this repo.

## 2) Main-Agent Orchestrator Protocol

The main agent orchestrates; it doesn't multitask blindly. Own and maintain `WORKBOARD.md`, `ACCEPTANCE_CRITERIA.md`, `TEST_PLAN.md`, `TEST_RESULTS.md`. Keep exactly one source of truth for status. Decompose work into disjoint write scopes before delegation. Don't delegate critical-path design; delegate bounded execution. Integrate sub-agent output, then verify end-to-end. For the autonomous version, run `/orchestrate <workstream-id>`.

## 3) Delegation Rules

Only delegate tasks that are bounded, independently verifiable, and non-overlapping in write scope. Each delegated task must include: objective, allowed file scope, explicit out-of-scope, acceptance checks, required command(s).

### Context Budget (by task size)

- `S`: 1–3 files, one focused patch.
- `M`: 4–8 files in one subsystem.
- `L`: avoid single-task delegation; split into multiple `M` tasks.

Pass minimum required context: target files, relevant contracts, expected output. Avoid full conversation dumps.

## 4) Required Tracking Artifacts

For each workstream under `docs/execution/active/<workstream-id>/` (relocate to `docs/execution/done/<id>/` once its PR merges — `active/` holds in-flight work only):

- `WORKBOARD.md` — now/next/blocked/done
- `ACCEPTANCE_CRITERIA.md` — done conditions per chunk
- `TEST_PLAN.md` / `TEST_RESULTS.md` — what will be validated / what ran
- `DECISIONS.md` — architectural decisions
- `RISKS_AND_BLOCKERS.md` — active risk register
- `RUN_LOG.md` — chronological execution evidence
- `REVIEW.md` — the per-round machine-routable review verdict **and the findings ledger**: every `F#` ever raised, with a `disposition` saying whether it is open or settled, so a settled call is not re-litigated next round (see `REVIEW_CONTRACT.md`)
- `SUBAGENTS/*.md` — delegated task contracts

## 5) Testing Discipline  *(commands FILL PER REPO)*

Before marking a task done: run the repo's unit + type checks for the touched area; run at least one real smoke flow for behavior changes; capture results in `TEST_RESULTS.md`. If you can't run a test, log the gap and why. **Name the exact commands for this repo here** (e.g. `npm test`, `npm run typecheck`, the smoke invocation).

## 6) Repo-Specific Guardrails  *(FILL PER REPO)*

- The traps and invariants unique to this repo (sensitive globals, field-name contracts, stateless constraints, etc.).

## 7) Recommended Execution Order  *(FILL PER REPO)*

1. Entry-point / contract plumbing → core logic → routing/orchestration → UI/wiring → docs → verification & regression hardening.

## 8) Bootstrap

```bash
./.claude/scripts/init-workstream.sh <workstream-id>
```

Or run the full autonomous loop: `/orchestrate <workstream-id>`.

## The human gate (do not weaken)

`/orchestrate` auto-resolves routine review findings but **never acts as the human**: it never records an approval, never rules a `FLAG-HUMAN`, and never opens a PR or merges. A `.loop-active` marker plus the `block-human-gated-actions.sh` PreToolUse hook enforce this mechanically — the loop *cannot* open/merge a PR or push while it runs, **and cannot remove the marker to get around that**. The marker is human-only: the loop writes it at run start and never clears it, because a gate the gated party can delete is not a gate. The loop stops at the approval card with the marker still in place; the human clears it (`rm .loop-active`, from their own terminal) and opens/merges the PR.

## Validation-gate workstreams (the verdict harness)

Most workstreams are *done* when the build passes and you approve the card. Some aren't: their real acceptance criterion is a **human verdict after a period of real use** — a dogfood, a pilot, a bake-in — where the question is "do I reach for it / does it earn trust," which no test can answer. The loop can build the surfaces, but it **cannot render the verdict** (it can't live in the thing for two weeks). For these, carve the verdict out explicitly as a human gate and scaffold a **`VERDICT_HARNESS.md`** (from `templates/VERDICT_HARNESS.template.md`) so the use-period produces *evidence, not vibes*:

- Criteria + running tallies (the gate's real thresholds), an evidence log per criterion that needs instances, a safety/invariant log, a friction list, any from-evidence posture calls, and the keep/kill/extend verdict template.
- On such a workstream the loop's job ends at **built + harness scaffolded + a readiness pass** (drive the core once, confirm it's daily-usable so day 1 isn't spent debugging). The verdict itself is yours to write from the accumulated evidence.
- Pair the harness with a lightweight **capture command** (e.g. a `/dogfood`-style logger) so logging during real use is one action, not a reconstruction at the deadline. A vague UI report should trigger one short clarifying question (which screen · which element · expected vs. actual) so entries stay actionable cold.
- **Keep the friction list capture-only; derive fix-status from git, never hand-maintain it.** The row is append-only (`Sev · Date · Friction`); the lone mutable cell, `Resolved`, holds only a merged-PR link. No "in-progress" state — that's the cell that rots when an agent forgets to update it mid-fix. Instead: a fix PR **names its entry** (`friction: <date> <slug>` in the title/body — a byproduct of describing the fix), and a **`reconcile`** pass (`/dogfood reconcile`) scans merged PRs and back-fills `Resolved → #PR`. The log is a cache rebuilt from git on demand: a forgotten update self-heals with one command; an unreferenced fix is surfaced for a quick manual match, never guessed. The `date + slug` is the join key threading capture → fix → reconcile.
- **Scaffolding a fix workstream from a friction item.** For a 🔴 (or a promoted 🟡 — small stuff is a direct fix, not a workstream): the clarified entry *is* the objective. `init-workstream.sh fix-<slug>`, set the README objective to the friction text, acceptance to "no longer reproduces + a regression test," and record `Source: dogfood friction <date> — <text>` so the fix PR's `friction:` reference closes the loop back to the log. Route severity → action honestly: 🔴 fixed mid-window (a live blocker manufactures a false "kill"); 🟡/⚪ batched into one post-verdict polish workstream, ranked by how often each recurred (frequency promotes severity — a 🟡 logged eight times is a 🔴 eroding "do I reach for it," caught at the day-7/14 triage).

Same rule as the approval gate, one level up: **the loop instruments the judgment; it never makes it.**
