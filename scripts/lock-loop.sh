#!/usr/bin/env bash
# Drop the HARD run marker for this repo — the categorical, opt-in version of the loop gate.
#
#   Run:  sudo ./.claude/scripts/lock-loop.sh
#
# Why sudo. The soft marker (.loop-active) lives inside the repo, so the agent's own user can
# write it and therefore, in principle, remove it — the guard hook walls the known removal paths,
# but that is a list, and a list has holes. The hard marker lives OUTSIDE the repo, in a
# root-owned directory the agent's user cannot write to. Deleting a file needs write permission on
# its containing directory; the agent's user does not have it, so no command the agent runs —
# shell verb, glob, interpreter one-liner, or tree rollback — can clear this marker. Only
# unlock-loop.sh (also sudo) removes it. That password prompt is the security property: it is the
# one thing the agent cannot satisfy.
#
# Use it for runs where a rogue ship would reach something real and you will not be watching
# (solo repos with no downstream human review, unattended/overnight runs, direct-to-main). Skip it
# for supervised runs or org repos whose branch protection already gates merges — there `sudo` is
# friction for no gain, and the default flow (the loop writes .loop-active itself) is enough.

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "lock-loop.sh must run as root so the marker is owned by root, not by the agent's user." >&2
  echo "Re-run:  sudo $0" >&2
  exit 1
fi

# Same key derivation as the guard hook and unlock/status — the git repo root, resolved the one
# way all four agree on regardless of layout. Keep these four in lockstep.
GUARD_DIR="${LOOP_GUARD_DIR:-/var/run/loop-guard}"
REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P))"
KEY="$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)"
MARKER="$GUARD_DIR/$KEY"

# Root-owned directory, not writable by anyone but root. This is what makes the marker inside it
# un-removable by the agent's user — the permission that matters for unlink is on the directory.
install -d -m 755 -o root -g wheel "$GUARD_DIR"

if [ -f "$MARKER" ]; then
  echo "Already locked: a hard run marker is in force for this repo."
  echo "  repo:   $REPO"
  echo "  marker: $MARKER"
  exit 0
fi

: > "$MARKER"
chmod 644 "$MARKER"
printf 'repo=%s\nlocked_at=%s\nlocked_by=%s\n' \
  "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-root}" > "$MARKER"

echo "Locked. The loop is now categorically gated for this repo."
echo "  repo:   $REPO"
echo "  marker: $MARKER (root-owned; the agent's user cannot remove it)"
echo
echo "Next:  run /orchestrate <id> as usual. Clear the gate when you act on the card:"
echo "  sudo $(dirname "${BASH_SOURCE[0]}")/unlock-loop.sh"
