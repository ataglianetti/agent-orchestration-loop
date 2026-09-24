# Agent Orchestration Loop

An autonomous, resumable build loop for [Claude Code](https://claude.com/claude-code): **plan → execute → verify → review → route**, repeating until an adversarial review comes back clean (or a round cap trips), then stopping at a **human approval card**. It auto-resolves routine review findings on its own and escalates only what a human must decide — and by construction it **cannot** open a PR, merge, or fabricate an approval.

## Why

A typical agent loop is manual across sessions: plan → run → a reviewer flags issues → copy the findings back → fix → repeat, by hand. This packages that into one command (`/orchestrate`) with state on disk — so it's resumable and auditable — and adds a hard human gate so the loop can't ship on its own.

## What you get

- **`/orchestrate <workstream-id>`** — the loop. State lives in `docs/execution/active/<id>/`, so it resumes across sessions and machines.
- **The workstream spine** — `WORKBOARD`, `ACCEPTANCE_CRITERIA`, `TEST_PLAN`/`TEST_RESULTS`, `DECISIONS`, `RISKS_AND_BLOCKERS`, `RUN_LOG`, `REVIEW`, `SUBAGENTS/`. The audit trail *is* the approval artifact.
- **A machine-routable review contract** (`REVIEW_CONTRACT.md`) — independent review passes (depth scaled to blast radius) normalize into one verdict block the loop routes off by severity and reachability.
- **A human gate, enforced two ways** — prose (the loop never records an approval, rules a human-flagged finding, opens a PR, or merges) **and** a mechanical guard: a `.loop-active` marker + a PreToolUse hook that blocks `gh pr create|merge` and `git push` while the loop runs, and blocks the loop from removing the marker to get around that. The marker is human-only — you clear it from your own terminal when you act on the card, and `scripts/loop-gate.zsh` gives you `ungate` for exactly that. Source it from your shell rc if you want it; the installer only places the file, it never touches your shell config.
- **A PM-altitude approval card** — what the human signs off on: intent/scope + reversibility, with the confidence read and findings one step deep. Not a diff review.
- **A validation-gate layer** — for workstreams whose *done* is a human keep/kill/extend verdict after real use: a `VERDICT_HARNESS` template that turns the use-period into evidence, and a `/dogfood` capture command with git-derived fix reconciliation.

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

## Using it

You ideate and judge; the loop plans, builds, verifies, and reviews. It can't ship without you.

1. **Hand off a goal.** In a Claude Code session rooted at the repo, run `/orchestrate <workstream-id>` — give the goal inline, or point it at a spec/notes file.
2. **Walk away.** It plans, makes atomic commits, runs your tests + a live check, runs 1–3 independent reviews (depth scales to the change's blast radius), auto-resolves routine findings, and loops.
3. **It stops at one of three places** and tells you:
   - **CLEAN — awaiting approval:** verification passed; read the approval card and, if it's good, open the PR yourself.
   - **FLAG-HUMAN:** a decision only a human should make (scope, money, a contract, a security posture). Record your ruling in `DECISIONS.md`, then re-run `/orchestrate <id>` to continue.
   - **NON-CONVERGENT:** it hit the round cap without going clean; read `RISKS_AND_BLOCKERS.md` and decide whether to retry, narrow scope, or hand off.
4. **You approve two things — only two:** _intent/scope_ (is this what you asked for?) and _reversibility_ (if it's wrong, how bad and how recoverable?). You are **not** certifying correctness — that's what the verification stack is for. Read the **approval card**, not the diff.

The audit trail lives in `docs/execution/active/<id>/`: `APPROVAL_CARD.md` is the front page; `REVIEW.md`, `DECISIONS.md`, `TEST_RESULTS.md`, and `RUN_LOG.md` are the depth.

## Validation-gate workstreams

Some workstreams aren't done when the build passes — their real acceptance criterion is a **human verdict after real use** (a dogfood, a pilot): "do I reach for it, does it earn trust?" No test answers that, and the loop can't live in the thing for two weeks. For these, the loop's job ends at *built + harness scaffolded + a readiness pass*; the verdict is yours.

- **`VERDICT_HARNESS.md`** (from `templates/VERDICT_HARNESS.template.md`) turns the use-period into evidence, not vibes: criteria tallies, per-criterion evidence logs, a safety/invariant log, a friction list, and the keep/kill/extend verdict you write at the deadline.
- **`/dogfood`** is the one-action capture command: log friction as you hit it (with one clarifying question when a report is too vague to fix cold), and `/dogfood reconcile` back-fills fix status from merged PRs — the log derives from git, never from memory.

Same rule as the approval gate, one level up: **the loop instruments the judgment; it never makes it.** Details in the guide's "Validation-gate workstreams" section.

## Requirements

- Claude Code, `git`, and `jq` (for the settings merge and the guard's JSON output).
- Review passes and the live check use the `adversarial-reviewer`, `run`, and `code-review` skills.
  These are not shipped here — they come with Claude Code (bundled on most builds) or from a plugin.
  `install.sh` runs a non-fatal preflight and names any it can't find on disk; bundled skills leave
  nothing on disk to find, so confirm with `/plugin` in a session before treating a miss as real.
  Without them the loop still plans and executes, but stalls at the review step.

## The human gate — why it's mechanical, not just instructions

The loop runs autonomously but **never acts as the human**: it can't record an approval, rule a `FLAG-HUMAN` finding, open a PR, or merge. The first time this loop ran for real, it reached a clean review and then *self-approved and opened a PR* — exactly the thing it was told never to do. Prose alone has a ceiling; an agent optimizing to finish will rationalize past it. So the gate is enforced mechanically: while a run is active, a PreToolUse guard blocks `gh pr create|merge|ready`, approving reviews, `git push`, and the routes around them — git global flags, git and gh aliases, `gh api` writes to PR, merge, ref and contents endpoints, changes to branch protection and rulesets, the GraphQL equivalents, authenticated raw HTTP to the GitHub API, and reading the GitHub token. `CLEAN` means *ready for a human*, not *approved*.

**The guard matches text, so it is a filter, not a wall.** A command that builds its words at runtime (a variable holding `push`, an encoded script piped to a shell) will pass it. The backstop that does not depend on matching text is on the remote: branch protection or a ruleset on your default branch that requires a pull request and an approving review from someone other than the author. With that in place, the worst a guard miss can do is push a branch; it cannot land on `main`. Set it on any repo where an unattended run could reach something real.

### The marker the gate reads — soft by default, hard when it matters

The gate is a marker file the guard checks. There are two, and the difference is who can remove it.

- **Soft (default, zero friction).** The loop writes `.loop-active` at the repo root and never removes it; the guard walls every removal path it knows — `rm`, `mv`, `unlink`, `shred`, `rename`, `-delete`, `git clean -x` (in any flag position), `git stash -a` / `--include-ignored`, and interpreter deletes and renames like `os.remove`, `os.rename`, `shutil.move`, `fs.unlink` and `fs.renameSync`. Strong, but it's a *list*, and a novel deletion path is a hole until the list catches up. A marker name built at runtime (a variable, an encoded string, a glob) never appears in the command, so no list can catch it; that is what the hard lock is for. You clear it yourself with `rm .loop-active` (or the `ungate` helper) when you act on the card. A loop running in a git worktree writes its marker at that worktree's root: `ungate` finds it from anywhere in the repo, clears the one in your current checkout (or the only one there is), lists the rest, and `ungate --all` clears every checkout. The guard blocks the agent from calling `ungate`, since the agent's shell loads the same rc files you do.

- **Hard (opt-in, one `sudo` at each end).** A marker the agent's user physically cannot remove — root-owned, in a directory outside the repo the agent can't write to. No command the loop runs (shell, glob, symlink, interpreter, tree rollback) can clear it; only you can, with `sudo`. This is the categorical version: it stops relying on a list of blocked commands and makes the gate un-clearable by the thing being gated.

  A marker is only as strong as the hook that reads it, and that hook lives entirely inside `.claude/` — a directory the agent owns as much as the marker. Unwiring the guard from in there is quieter than any rm, and a Bash guard can't even see an Edit-tool change to a file. There are at least three doors: `disableAllHooks` in `.claude/settings.json`; the same key in `.claude/settings.local.json`, which Claude Code honours too and which usually doesn't exist yet, so the agent can simply *create* it; or editing `exit 0` into the top of the hook script itself, touching no settings file at all.

  So the hard lock **freezes the whole `.claude/` subtree except `.claude/worktrees/`** (`chflags schg` on macOS, `chattr +i` on Linux) while the run is locked. Worktrees stay writable because Claude Code keeps parallel worktrees there, and a frozen worktree can't be edited, committed in or removed. Nothing in `worktrees/` wires this repo's hook, and `.claude/` itself stays frozen, so `worktrees/` can't be renamed or swapped for a link. Both halves of that are load-bearing, because each blocks something the other doesn't:

  | Immutable | Create new file | Delete file | Edit existing file in place |
  |---|---|---|---|
  | directory only | blocked | blocked | **allowed** |
  | file only | — | — | blocked |

  Freezing the directory is what stops `settings.local.json` from being created; freezing the files is what stops the existing ones being edited. Neither alone closes it, which is why an earlier version that froze only `.claude/settings.json` left two ways through. The subtree freeze also means there is no filename list to maintain — a settings file this kit has never heard of is covered the day it is invented. The agent can't lift any of it, because that needs root; unlock lifts all of it. If any part of the freeze fails, the lock prints the error, undoes what it froze, removes the marker it just wrote, and exits non-zero. A partial freeze never reports `Locked`. Symlinks inside `.claude/` are flagged themselves, never followed, so the lock can't reach a file outside the tree. This is safe because `.claude/` is written at install time and only *read* during a run: the loop's state lives in `docs/execution/`, and the soft marker at the repo root.

  One consequence worth knowing before it surprises you mid-run: while locked, **"Allow always" on a permission prompt will fail**, because Claude Code records that grant in `.claude/settings.local.json`. That is the lock working rather than a fault — a standing allow rule written during an unattended run is exactly the thing being prevented. Choose "Allow once", or unlock first if you genuinely want a permanent grant.

  **If your project's `.claude` is a symlink**, the lock resolves it and freezes the real target, and freezes the link itself so it cannot be repointed at a directory the agent does control. (Symlinking the *user-level* `~/.claude` into a dotfiles repo is the common practice, and the hard lock does not touch it — see the gap noted below. A *project* `.claude` is a link less often, usually because something like Obsidian Sync will not carry dotfolders, so the real directory has to sit at a visible path.) If that target sits **outside the repo**, the lock warns and proceeds:

  ```
  WARNING: .claude resolves to /path/outside/repo, outside this repo.
           If that is a synced folder (Obsidian, Dropbox, a dotfiles repo), freezing it
           makes it immutable everywhere it syncs — not just for this run — and a sync
           client writing into a frozen folder can fail on every machine at once.
           Untested against a live sync client. Locking anyway; unlock-loop.sh reverses it.
  ```

  It warns rather than refuses on purpose. A symlinked project `.claude` points outside the repo almost by definition — that is why it is a symlink — so refusing would block the exact case the symlink handling exists for, and send a legitimate user hunting for an override flag. A guard whose false positives block real work teaches you to reach past it, and an override you reach for by reflex is not a control. You typed `sudo`; the consequence is stated and `unlock-loop.sh` reverses all of it.

  **What the hard lock does not cover.** Two things, both deliberate:

  - **`~/.claude/settings.json`.** Claude Code reads user-level settings too, and `disableAllHooks` works there. It runs as the same user as the agent, so it is reachable — but freezing it would make it immutable for every Claude Code session on the machine, not just the locked run. Out of scope for a repo-scoped lock.
  - **Freezing a genuinely synced folder is untested.** If your `.claude` resolves into one, the lock warns and proceeds. Nobody has checked how a sync client reacts to its directory becoming immutable mid-session — whether it fails loudly, retries quietly, or leaves the other machine inconsistent. The warning says so; heed it rather than the fact that the command succeeded.

  The route that ends this class rather than extending it is [`/etc/claude-code/managed-settings.json`](https://code.claude.com/docs/en/settings) with `allowManagedHooksOnly: true` — root-owned, above user and project settings, and per the docs only managed settings can disable managed hooks. No freezing, and no list of filenames to keep current.

  ```bash
  sudo ./.claude/scripts/lock-loop.sh     # before /orchestrate, from inside the repo — drops the hard marker
  # ... run /orchestrate <id> as usual; planner and executors need no sudo ...
  sudo ./.claude/scripts/unlock-loop.sh   # after you act on the card — clears it
  ```

  The lock is keyed on the repo you run it from, not on where the scripts live, and one lock covers every git worktree of that repo: a session in any of them is gated. A session inside a worktree reads that worktree's own `.claude/`, so the lock freezes each worktree's `.claude/` as well as the main one, and unlock lifts them all. Two consequences: `git worktree remove` fails while locked, and a worktree added after the lock is not frozen until you re-run `sudo lock-loop.sh` (safe to repeat). `loop-status.sh` warns about any worktree it finds unfrozen. A worktree with no `.claude/` has no project hook at all, and the lock says so.

  `./.claude/scripts/loop-status.sh` reports which marker (if any) holds the gate. **Lock when a rogue ship would reach something real and you won't be watching** — solo repos with no downstream review, unattended or overnight runs, direct-to-main. **Skip it** for supervised runs, throwaway branches, or repos whose own branch protection already gates merges; there the `sudo` is friction for nothing and the soft default is enough.

## Acknowledgements

The gate is harder than it was because people took it apart in public.

[u/northbridgedev](https://www.reddit.com/user/northbridgedev/) reviewed the guard in [the r/ClaudeCode thread](https://www.reddit.com/r/ClaudeCode/comments/1wgjq3j/my_agent_deleted_the_file_that_was_stopping_it/) on the original marker-deletion post, and four things here came out of that:

- **The hinge.** A marker the agent cannot delete is worth little while the hook that *reads* it sits in a file the agent owns. That is why the hard lock freezes the hook wiring and not just the marker.
- **`.claude/settings.local.json`.** Claude Code honours `disableAllHooks` there too, and the file usually does not exist yet — so the agent can create it rather than edit anything. That is why the freeze covers the subtree instead of one filename.
- **Unlink is a permission on the directory, not on the file.** `chmod 000` a file you own and `rm -f` still removes it. The marker lives in a root-owned *directory* for this reason.
- **`scripts/tests/test-denial-suggestions.sh`** exists because they proposed it: feed every command a denial message suggests back through the hook, and assert each one passes *and* leaves the marker standing. A block message that hands over a working bypass is its own class of bug, and this repo had one.

They also withdrew one of their own reported cases when it did not reproduce, which is the part of code review nobody writes blog posts about.

## License

MIT — see [LICENSE](LICENSE).
