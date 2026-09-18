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
SETTINGS="${LOOP_SETTINGS:-$REPO/.claude/settings.json}"

is_frozen() {  # 0 = immutable flag is set
  if   command -v chflags >/dev/null 2>&1; then ls -ldO "$1" 2>/dev/null | grep -qw schg
  elif command -v lsattr  >/dev/null 2>&1; then lsattr "$1" 2>/dev/null | awk '{print $1}' | grep -q i
  else return 1; fi
}
unfreeze() {  # harmless no-op if the file is not frozen
  if   command -v chflags >/dev/null 2>&1; then chflags noschg "$1" 2>/dev/null || true
  elif command -v chattr  >/dev/null 2>&1; then chattr -i "$1" 2>/dev/null || true; fi
}

did=0

# Lift the immutable flag first, and unconditionally — a forgotten lock must never leave
# settings.json permanently frozen. Report only if it actually had been frozen.
if [ -e "$SETTINGS" ]; then
  was_frozen=0; is_frozen "$SETTINGS" && was_frozen=1
  unfreeze "$SETTINGS"
  [ "$was_frozen" -eq 1 ] && { echo "  unfroze: $SETTINGS (hook wiring editable again)"; did=1; }
fi

if [ -f "$MARKER" ]; then
  rm -f "$MARKER"
  echo "Unlocked. The hard gate is cleared for this repo."
  echo "  repo:   $REPO"
  echo "  (If the run also wrote a soft marker, clear it too:  rm '$REPO/.loop-active')"
elif [ "$did" -eq 0 ]; then
  echo "Not locked: no hard run marker for this repo ($REPO). Nothing to clear."
fi
