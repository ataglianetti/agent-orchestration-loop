# Known gate issues

Open defects in the loop's human gate (the ship guard, the soft and hard run markers, and the review contract). Each was found by independent review of the scripts as they ship in this repo.

**Status:** open. Each row names a recommended fix; none has been decided yet.

## Ship guard

| ID  | Severity         | Where                                                                    | Problem | Recommended fix |
| --- | ---------------- | ------------------------------------------------------------------------ | ------- | --------------- |
| G2  | NOTE             | `scripts/block-human-gated-actions.sh` — section 1 deny message          | Under a hard lock with no soft marker, the deny message still tells the user to `rm .loop-active`, which does nothing. | Name `sudo unlock-loop.sh` when the hard marker is what holds the gate. |

## Soft marker

| ID  | Severity         | Where                                                        | Problem | Recommended fix |
| --- | ---------------- | ------------------------------------------------------------ | ------- | --------------- |
| G3  | WARNING (live)   | `scripts/block-human-gated-actions.sh` — sections 2–3        | The soft marker can still be removed: `git stash -a` / `git stash --include-ignored`, a `-x` flag that is not the first flag after `git clean`, an interpreter `rename` (Python `os.rename`, Node `fs.renameSync`, `shutil.move`, Perl `rename`), or a filename built at runtime so the literal `.loop-active` never appears. The same matcher also false-positives on text that merely mentions the marker near the word "unlink". | Add the stash, clean-flag and rename forms. Document runtime-built names as a limit of the soft marker, which is what the hard lock is for. Accept the false positives: the gate fails closed. |

## Hard lock

| ID  | Severity         | Where                                                        | Problem | Recommended fix |
| --- | ---------------- | ------------------------------------------------------------ | ------- | --------------- |
| G5  | WARNING          | `scripts/block-human-gated-actions.sh` — `HARD_MARKER`; `lock-loop.sh`, `unlock-loop.sh`, `loop-status.sh` — `REPO=` | The hook keys the hard marker on the git root of `CLAUDE_PROJECT_DIR`; the three scripts key it on the git root of their own location. The two diverge in a worktree outside `.claude/`, or when `.claude` is a symlink into another repository. The lock then reports "Locked" while the hook sees no marker. | One key derivation everywhere (`CLAUDE_PROJECT_DIR`, else the current repo root). `loop-status.sh` warns when the two disagree. |
| G6  | WARNING          | `scripts/lock-loop.sh` — `freeze_tree` error path            | Freeze errors go to `/dev/null`; the script still prints "Locked" and exits 0 after a partial freeze, leaving the hook editable. | Fail loud: undo whatever was frozen and exit non-zero. |
| G7  | WARNING          | `scripts/lock-loop.sh` — `freeze_tree`                       | `chflags schg` runs without `-h`, so a symlink inside `.claude` freezes its target; `unlock-loop.sh` never unfreezes that target. | Use `-h` so links, not their targets, are frozen. |
| G8  | WARNING          | `commands/orchestrate.md` — hard-mode bullet under "Two gate modes" | The text says the hard-locked guard "cannot be unwired from any direction". User-level `~/.claude/settings.json` stays writable and can disable hooks for newly started sessions (not verified live). | Reword to state that user-level configuration is not covered by the freeze. |

## Review contract

| ID  | Severity | Where                                                   | Problem | Recommended fix |
| --- | -------- | ------------------------------------------------------- | ------- | --------------- |
| G10 | NOTE     | `execution/REVIEW_CONTRACT.md` — §2 example block       | The example block fails its own checksum rule: `Carried: settled` lists four IDs while `Progress` says three. | Fix the example's counts. |
| G11 | WARNING  | `execution/REVIEW_CONTRACT.md` — §5 claim-only rule     | Reusing an existing `F#` on a claim-only match conflicts with the rule that each `F#` appears in exactly one settled list. | Issue a new `F#` with a `related: F#` note instead of reusing the ID. |
