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

if [ ! -f "$MARKER" ]; then
  echo "Not locked: no hard run marker for this repo ($REPO). Nothing to clear."
  exit 0
fi

rm -f "$MARKER"
echo "Unlocked. The hard gate is cleared for this repo."
echo "  repo:   $REPO"
echo "  (If the run also wrote a soft marker, clear it too:  rm '$REPO/.loop-active')"
