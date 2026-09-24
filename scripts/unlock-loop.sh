#!/usr/bin/env bash
# Clear the HARD run marker for this repo. The counterpart to lock-loop.sh.
#
#   Run:  sudo ./.claude/scripts/unlock-loop.sh   (from inside the repo, or any of its worktrees)
#
# This is the ONE act that has to happen outside the thing being gated. The marker is root-owned,
# so removing it needs root — which the agent never has. Run this after you have read the approval
# card and decided to reopen shipping. It does not touch the soft .loop-active marker; if a run
# also left one of those, clear it with a plain `rm .loop-active`.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "unlock-loop.sh must run as root — the marker is root-owned by design." >&2
  echo "Re-run:  sudo $0" >&2
  exit 1
fi

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
if [ -z "$GUARD_REPO" ] || [ -z "$GUARD_MAIN" ]; then
  echo "$(basename "$0"): $KEY_BASE is not inside a git repository. Run it from inside the repo." >&2
  exit 1
fi
REPO="$(cd "$GUARD_MAIN" && pwd -P)"   # the main checkout: its .claude is the one frozen
KEY="$GUARD_KEY"
MARKER="$GUARD_DIR/$KEY"
CLAUDE_DIR="${LOOP_CLAUDE_DIR:-$REPO/.claude}"

# Resolve a symlinked .claude exactly as lock-loop.sh does, or unlock walks the link instead of
# the real tree and leaves the contents frozen — a lock nobody can lift without chflags by hand.
# No outside-the-repo refusal here: unlock must always be able to undo whatever lock did.
CLAUDE_LINK="$CLAUDE_DIR"
[ -L "$CLAUDE_DIR" ] && CLAUDE_DIR="$(cd "$CLAUDE_DIR" 2>/dev/null && pwd -P || printf '%s' "$CLAUDE_DIR")"

is_frozen() {  # 0 = immutable flag is set
  if   command -v chflags >/dev/null 2>&1; then ls -ldO "$1" 2>/dev/null | grep -qw schg
  elif command -v lsattr  >/dev/null 2>&1; then lsattr "$1" 2>/dev/null | awk '{print $1}' | grep -q i
  else return 1; fi
}
# Lift the flags across the whole subtree, directory FIRST (plain -R, no -depth) so the parent is
# cleared before its children are walked. Mirrors freeze_tree in lock-loop.sh, which goes the
# other way round. Harmless no-op on anything that was not frozen.
unfreeze_tree() {
  local d="$1"
  [ -d "$d" ] || return 0
  if   command -v chflags >/dev/null 2>&1; then chflags -R noschg "$d" 2>/dev/null || true
  elif command -v chattr  >/dev/null 2>&1; then
    find "$d" -type d -exec chattr -i {} + 2>/dev/null || true
    find "$d" -type f -exec chattr -i {} + 2>/dev/null || true
  fi
}

did=0

# Lift the immutable flags first, and unconditionally — a forgotten lock must never leave the
# .claude subtree permanently frozen, which would lock the human out of their own config too.
# Report only if it actually had been frozen. The directory's own flag is the signal: freeze_tree
# sets it last, so if it is set the whole subtree was done.
# Lift the link's own flag FIRST. On macOS an schg symlink cannot be replaced, and leaving it set
# would survive the unlock invisibly — the tree would look released while .claude stayed pinned.
if [ "$CLAUDE_LINK" != "$CLAUDE_DIR" ] && command -v chflags >/dev/null 2>&1; then
  if ls -ldO "$CLAUDE_LINK" 2>/dev/null | grep -qw schg; then
    chflags -h noschg "$CLAUDE_LINK" 2>/dev/null \
      && { echo "  unfroze: $CLAUDE_LINK (the symlink itself)"; did=1; }
  fi
fi

if [ -d "$CLAUDE_DIR" ]; then
  was_frozen=0; is_frozen "$CLAUDE_DIR" && was_frozen=1
  unfreeze_tree "$CLAUDE_DIR"
  [ "$was_frozen" -eq 1 ] && { echo "  unfroze: $CLAUDE_DIR (whole subtree — hook wiring editable again)"; did=1; }
fi

LEGACY="$GUARD_DIR/$GUARD_LEGACY_KEY"
if [ "$LEGACY" != "$MARKER" ] && [ -f "$LEGACY" ]; then
  rm -f "$LEGACY"
  echo "  removed: $LEGACY (a lock taken before the guard key changed)"
  did=1
fi

if [ -f "$MARKER" ]; then
  rm -f "$MARKER"
  echo "Unlocked. The hard gate is cleared for this repo."
  echo "  repo:   $REPO"
  echo "  (If the run also wrote a soft marker, clear it too:  rm '$REPO/.loop-active')"
elif [ "$did" -eq 0 ]; then
  echo "Not locked: no hard run marker for this repo ($REPO). Nothing to clear."
fi
