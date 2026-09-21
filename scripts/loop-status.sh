#!/usr/bin/env bash
# Report whether the loop gate is active for this repo, and which marker holds it. Read-only, no
# sudo. Used by /orchestrate to decide whether to write its own soft marker, and by you to check
# state before locking or unlocking.
#
#   Run:  ./.claude/scripts/loop-status.sh
#
# Exit 0 = ACTIVE (a soft or hard marker is present), exit 1 = INACTIVE.

GUARD_DIR="${LOOP_GUARD_DIR:-/var/run/loop-guard}"
REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P))"
KEY="$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)"
HARD="$GUARD_DIR/$KEY"
SOFT="$REPO/.loop-active"
CLAUDE_DIR="${LOOP_CLAUDE_DIR:-$REPO/.claude}"

is_frozen() {  # 0 = immutable flag is set on the path
  if   command -v chflags >/dev/null 2>&1; then ls -ldO "$1" 2>/dev/null | grep -qw schg
  elif command -v lsattr  >/dev/null 2>&1; then lsattr "$1" 2>/dev/null | awk '{print $1}' | grep -q i
  else return 1; fi
}

soft_present=0; hard_present=0; frozen=0
[ -f "$SOFT" ] && soft_present=1
[ -f "$HARD" ] && hard_present=1
# The .claude DIRECTORY's own flag is the signal: freeze_tree sets it last, so if it carries the
# flag the whole subtree was frozen. Checking one settings file would miss a partial freeze and,
# worse, would report "not frozen" for a tree that is.
[ -d "$CLAUDE_DIR" ] && is_frozen "$CLAUDE_DIR" && frozen=1

if [ "$soft_present" -eq 1 ] || [ "$hard_present" -eq 1 ]; then
  echo "ACTIVE"
  [ "$hard_present" -eq 1 ] && echo "  hard: $HARD (root-owned; clear with: sudo ./.claude/scripts/unlock-loop.sh)"
  [ "$soft_present" -eq 1 ] && echo "  soft: $SOFT (clear with: rm '$SOFT')"
  [ "$frozen" -eq 1 ]       && echo "  hook wiring frozen: $CLAUDE_DIR (whole subtree; unlock lifts it)"
  exit 0
fi

echo "INACTIVE"
echo "  no run marker for this repo ($REPO)"
# A frozen subtree with no marker is a stuck state — a lock whose unlock never ran.
[ "$frozen" -eq 1 ] && echo "  WARNING: $CLAUDE_DIR is still frozen — run: sudo ./.claude/scripts/unlock-loop.sh"
exit 1
