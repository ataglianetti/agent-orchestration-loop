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

soft_present=0; hard_present=0
[ -f "$SOFT" ] && soft_present=1
[ -f "$HARD" ] && hard_present=1

if [ "$soft_present" -eq 1 ] || [ "$hard_present" -eq 1 ]; then
  echo "ACTIVE"
  [ "$hard_present" -eq 1 ] && echo "  hard: $HARD (root-owned; clear with: sudo ./.claude/scripts/unlock-loop.sh)"
  [ "$soft_present" -eq 1 ] && echo "  soft: $SOFT (clear with: rm '$SOFT')"
  exit 0
fi

echo "INACTIVE"
echo "  no run marker for this repo ($REPO)"
exit 1
