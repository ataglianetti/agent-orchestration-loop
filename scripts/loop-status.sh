#!/usr/bin/env bash
# Report whether the loop gate is active for this repo, and which marker holds it. Read-only, no
# sudo. Used by /orchestrate to decide whether to write its own soft marker, and by you to check
# state before locking or unlocking.
#
#   Run:  ./.claude/scripts/loop-status.sh
#
# Exit 0 = ACTIVE (a soft or hard marker is present), exit 1 = INACTIVE.

GUARD_DIR="${LOOP_GUARD_DIR:-/var/run/loop-guard}"
# >>> guard key: keep this block byte-identical in block-human-gated-actions.sh, lock-loop.sh,
# unlock-loop.sh and loop-status.sh. The test suite compares the four copies.
# The hard marker is keyed on the repo's SHARED git directory (--git-common-dir), resolved from the
# project dir, else the current directory. Every worktree of a repo shares that directory, so one
# lock covers them all, and the key does not depend on where these scripts happen to live — a
# symlinked .claude pointing into another repo no longer changes it. safe.directory='*' because
# lock and unlock run git as root inside a repo the human owns; command-line config is honoured.
KEY_BASE="${CLAUDE_PROJECT_DIR:-$PWD}"
GUARD_REPO="$(cd "$KEY_BASE" 2>/dev/null && d="$(git -c safe.directory='*' rev-parse --git-common-dir 2>/dev/null)" && cd "$d" 2>/dev/null && pwd -P || true)"
GUARD_MAIN="$(git -c safe.directory='*' -C "$KEY_BASE" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' || true)"
GUARD_KEY="$(printf '%s' "$GUARD_REPO" | cksum | cut -d' ' -f1)"
# Before this key existed, the marker was keyed on a checkout's root. Honour and clear that key
# too, so a lock taken before the upgrade is neither ignored nor left behind.
GUARD_LEGACY_KEY="$(printf '%s' "$(git -c safe.directory='*' -C "$KEY_BASE" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$KEY_BASE")" | cksum | cut -d' ' -f1)"
# <<< guard key
if [ -z "$GUARD_REPO" ]; then
  echo "INACTIVE"
  echo "  $KEY_BASE is not inside a git repository — no hard lock can apply"
  exit 1
fi
REPO="$(cd "${GUARD_MAIN:-$KEY_BASE}" && pwd -P)"
HARD="$GUARD_DIR/$GUARD_KEY"
LEGACY="$GUARD_DIR/$GUARD_LEGACY_KEY"
# The soft marker is per checkout: the loop writes it at the root of the project it runs in.
SOFT="${CLAUDE_PROJECT_DIR:-$(git -C "$KEY_BASE" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$KEY_BASE")}/.loop-active"
CLAUDE_DIR="${LOOP_CLAUDE_DIR:-$REPO/.claude}"

# Resolve a symlinked .claude the same way lock/unlock do. Checking the link instead of its
# target would report "not frozen" for a tree that is frozen, which is the wrong answer in the
# more dangerous direction — it invites a second lock, or hides a stuck one.
CLAUDE_LINK="$CLAUDE_DIR"
[ -L "$CLAUDE_DIR" ] && CLAUDE_DIR="$(cd "$CLAUDE_DIR" 2>/dev/null && pwd -P || printf '%s' "$CLAUDE_DIR")"

is_frozen() {  # 0 = immutable flag is set on the path
  if   command -v chflags >/dev/null 2>&1; then ls -ldO "$1" 2>/dev/null | grep -qw schg
  elif command -v lsattr  >/dev/null 2>&1; then lsattr "$1" 2>/dev/null | awk '{print $1}' | grep -q i
  else return 1; fi
}

soft_present=0; hard_present=0; frozen=0
[ -f "$SOFT" ] && soft_present=1
[ -f "$HARD" ] && hard_present=1
[ "$LEGACY" != "$HARD" ] && [ -f "$LEGACY" ] && { hard_present=1; HARD="$LEGACY"; }
# The .claude DIRECTORY's own flag is the signal: freeze_tree sets it last, so if it carries the
# flag the whole subtree was frozen. Checking one settings file would miss a partial freeze and,
# worse, would report "not frozen" for a tree that is.
[ -d "$CLAUDE_DIR" ] && is_frozen "$CLAUDE_DIR" && frozen=1

# These scripts may belong to a different repo than the one being checked (a .claude symlinked
# into a dotfiles repo, or a copy run by path). The lock follows the repo you are IN, not the
# script's home — say so when the two differ, because that was the old behaviour.
SCRIPT_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && d="$(git -c safe.directory='*' rev-parse --git-common-dir 2>/dev/null)" && cd "$d" 2>/dev/null && pwd -P)"
if [ -n "$SCRIPT_REPO" ] && [ "$SCRIPT_REPO" != "$GUARD_REPO" ]; then
  echo "WARNING: these scripts live in $SCRIPT_REPO, but the lock is keyed on the repo you are in ($GUARD_REPO)." >&2
fi

if [ "$soft_present" -eq 1 ] || [ "$hard_present" -eq 1 ]; then
  echo "ACTIVE"
  [ "$hard_present" -eq 1 ] && echo "  hard: $HARD (root-owned; clear with: sudo ./.claude/scripts/unlock-loop.sh)"
  [ "$soft_present" -eq 1 ] && echo "  soft: $SOFT (clear with: rm '$SOFT')"
  if [ "$frozen" -eq 1 ]; then
    echo "  hook wiring frozen: $CLAUDE_DIR (whole subtree except worktrees/; unlock lifts it)"
    [ "$CLAUDE_LINK" != "$CLAUDE_DIR" ] && echo "    via symlink: $CLAUDE_LINK"
  fi
  exit 0
fi

echo "INACTIVE"
echo "  no run marker for this repo ($REPO)"
# A frozen subtree with no marker is a stuck state — a lock whose unlock never ran.
[ "$frozen" -eq 1 ] && echo "  WARNING: $CLAUDE_DIR is still frozen — run: sudo ./.claude/scripts/unlock-loop.sh"
exit 1
