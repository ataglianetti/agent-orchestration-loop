# Known gate issues

Defects in the loop's human gate (the ship guard, the soft and hard run markers, and the review contract), found by independent review of the scripts as they ship in this repo.

**Status:** none open. Add new findings here as a table: ID, severity, location, problem, recommended fix.

## Resolved

| ID  | Severity         | Problem, in one line | Fixed in |
| --- | ---------------- | -------------------- | -------- |
| G1  | CRITICAL (live)  | The ship guard missed implicit `gh api` POSTs, git global flags and aliases, and authenticated `curl`. | #9 (the guard's gap on branch protection: #10) |
| G2  | NOTE             | Under a hard lock, the denial told the human to `rm .loop-active`. | #16 |
| G3  | WARNING (live)   | The soft marker could be removed by `git stash -a`, a late `git clean -x`, or an interpreter rename. | #15 |
| G4  | CRITICAL-ON-FLIP | The hard lock froze `.claude/worktrees/`, making parallel worktrees immutable. | #11 |
| G5  | WARNING          | The hook and the lock scripts keyed the hard marker differently. | #12 |
| G6  | WARNING          | A partial freeze still printed "Locked" and exited 0. | #14 |
| G7  | WARNING          | `chflags` followed symlinks inside `.claude/` and froze their targets. | #14 |
| G8  | WARNING          | `orchestrate.md` said the locked guard "cannot be unwired from any direction". | #16 |
| G9  | WARNING (live)   | The suppressed-only stop ran after `VERDICT == CLEAN`, so it could never fire. | #6 |
| G10 | NOTE             | The review-contract example failed its own checksum. | #16 |
| G11 | WARNING          | A claim-only match reused an existing `F#`, putting one ID in two settled lists. | #17 |
| G12 | WARNING          | Under a hard lock, each worktree's own `.claude/` stayed writable. | #13 |

Not a code fix: branch protection on `main` (pull request required, admins included) was turned on as the backstop for anything the guard's text matching misses.
