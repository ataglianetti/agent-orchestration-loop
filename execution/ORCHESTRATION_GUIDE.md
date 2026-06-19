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
- `REVIEW.md` — the per-round machine-routable review verdict (see `REVIEW_CONTRACT.md`)
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

`/orchestrate` auto-resolves routine review findings but **never acts as the human**: it never records an approval, never rules a `FLAG-HUMAN`, and never opens a PR or merges. A `.loop-active` marker plus the `block-human-gated-actions.sh` PreToolUse hook enforce this mechanically — the loop *cannot* open/merge a PR or push while it runs. The loop stops at the approval card; a human opens/merges the PR.
