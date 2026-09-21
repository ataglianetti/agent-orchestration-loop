#!/usr/bin/env bash
# Clear the HARD run marker for this repo. The counterpart to lock-loop.sh.
#
#   Run:  sudo ./.claude/scripts/unlock-loop.sh
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
REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P))"
KEY="$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)"
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

if [ -f "$MARKER" ]; then
  rm -f "$MARKER"
  echo "Unlocked. The hard gate is cleared for this repo."
  echo "  repo:   $REPO"
  echo "  (If the run also wrote a soft marker, clear it too:  rm '$REPO/.loop-active')"
elif [ "$did" -eq 0 ]; then
  echo "Not locked: no hard run marker for this repo ($REPO). Nothing to clear."
fi
