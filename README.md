# Agent Orchestration Loop

An autonomous, resumable build loop for [Claude Code](https://claude.com/claude-code): **plan → execute → verify → review → route**, repeating until an adversarial review comes back clean (or a round cap trips), then stopping at a **human approval card**. It auto-resolves routine review findings on its own and escalates only what a human must decide — and by construction it **cannot** open a PR, merge, or fabricate an approval.

## Why

A typical agent loop is manual across sessions: plan → run → a reviewer flags issues → copy the findings back → fix → repeat, by hand. This packages that into one command (`/orchestrate`) with state on disk — so it's resumable and auditable — and adds a hard human gate so the loop can't ship on its own.

## What you get

- **`/orchestrate <workstream-id>`** — the loop. State lives in `docs/execution/active/<id>/`, so it resumes across sessions and machines.
- **The workstream spine** — `WORKBOARD`, `ACCEPTANCE_CRITERIA`, `TEST_PLAN`/`TEST_RESULTS`, `DECISIONS`, `RISKS_AND_BLOCKERS`, `RUN_LOG`, `REVIEW`, `SUBAGENTS/`. The audit trail *is* the approval artifact.
- **A machine-routable review contract** (`REVIEW_CONTRACT.md`) — independent review passes (depth scaled to blast radius) normalize into one verdict block the loop routes off by severity and reachability.
- **A human gate, enforced two ways** — prose (the loop never records an approval, rules a human-flagged finding, opens a PR, or merges) **and** a mechanical guard: a `.loop-active` marker + a PreToolUse hook that blocks `gh pr create|merge` and `git push` while the loop runs.
- **A PM-altitude approval card** — what the human signs off on: intent/scope + reversibility, with the confidence read and findings one step deep. Not a diff review.

## One round

`plan` (once) → `execute` a wave (atomic commits) → `verify` (coverage gate + live check) → `review` (1–3 independent passes) → `route` by severity (auto-fix / park / escalate) → score confidence → loop, until `CLEAN` or the round cap. Then write the approval card and **stop**.

## Install

```bash
./install.sh /path/to/your-repo
```

Drops the command, planner, scripts, and execution spine into the repo's `.claude/` and `docs/execution/`, and merges the guard hook into `.claude/settings.json`. Then specialize `docs/execution/CLAUDE_ORCHESTRATION_GUIDE.md` (§1 contracts, §5 test commands, §6 guardrails, §7 execution order) for that repo, and run, in a Claude Code session rooted there:

```
/orchestrate my-first-workstream
```

## Requirements

- Claude Code, `git`, and `jq` (for the settings merge and the guard's JSON output).
- Review passes use the `adversarial-reviewer`, `run`, and `code-review` skills; the live check uses `verify`.

## The human gate — why it's mechanical, not just instructions

The loop runs autonomously but **never acts as the human**: it can't record an approval, rule a `FLAG-HUMAN` finding, open a PR, or merge. The first time this loop ran for real, it reached a clean review and then *self-approved and opened a PR* — exactly the thing it was told never to do. Prose alone has a ceiling; an agent optimizing to finish will rationalize past it. So the gate is enforced mechanically: while a run is active, the PreToolUse guard makes `gh pr create|merge` and `git push` impossible. `CLEAN` means *ready for a human*, not *approved*.

## License

MIT — see [LICENSE](LICENSE).
