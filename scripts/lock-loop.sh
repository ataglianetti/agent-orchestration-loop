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
# The hook wiring to freeze — the WHOLE .claude subtree, not one settings file. Overridable for
# tests, same as LOOP_GUARD_DIR.
CLAUDE_DIR="${LOOP_CLAUDE_DIR:-$REPO/.claude}"

# Make a path immutable even against its owner: schg (macOS) / +i (Linux). Both need root to set
# AND to clear, so a non-root agent can neither modify the path nor lift the flag.
freeze() {
  if   command -v chflags >/dev/null 2>&1; then chflags schg "$1"
  elif command -v chattr  >/dev/null 2>&1; then chattr +i "$1"
  else echo "  WARNING: no chflags or chattr found — cannot freeze $1" >&2; return 1; fi
}

# Freeze a directory AND everything in it. Both halves are required, and each blocks something the
# other does not — verified, not assumed:
#
#   immutable DIRECTORY only  → creating a new file is blocked, deleting one is blocked, but
#                               editing an existing file IN PLACE still succeeds.
#   immutable FILE only       → in-place edits are blocked, but a NEW sibling can be created.
#
# So freezing just .claude/settings.json (what this script did before) left two ways through:
# create .claude/settings.local.json, which also accepts `disableAllHooks`, or edit
# .claude/scripts/block-human-gated-actions.sh in place and neuter the hook at the source. The
# subtree freeze closes both, and closes them categorically — it does not enumerate filenames, so
# a settings file this kit has never heard of is covered the day it is invented.
#
# This is safe because .claude/ is written at INSTALL time and only read at run time: the loop's
# own state lives in docs/execution/, and the soft marker lives at the repo root. Nothing the loop
# does during a run writes into .claude/.
#
# Contents first, directory last (-depth): the directory's own flag is set once its children are
# already done, which avoids depending on whether a given kernel lets you re-flag a child inside
# an already-immutable parent.
freeze_tree() {
  local d="$1"
  if   command -v chflags >/dev/null 2>&1; then
    find "$d" -depth -exec chflags schg {} + 2>/dev/null
  elif command -v chattr >/dev/null 2>&1; then
    find "$d" -type f -exec chattr +i {} + 2>/dev/null
    find "$d" -depth -type d -exec chattr +i {} + 2>/dev/null
  else
    echo "  WARNING: no chflags or chattr found — cannot freeze $d" >&2; return 1
  fi
}

# Root-owned directory, not writable by anyone but root. This is what makes the marker inside it
# un-removable by the agent's user — the permission that matters for unlink is on the directory.
install -d -m 755 -o root -g wheel "$GUARD_DIR"

if [ -f "$MARKER" ]; then
  echo "Already locked: a hard run marker is in force for this repo."
  echo "  repo:   $REPO"
  echo "  marker: $MARKER"
else
  : > "$MARKER"
  chmod 644 "$MARKER"
  printf 'repo=%s\nlocked_at=%s\nlocked_by=%s\n' \
    "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-root}" > "$MARKER"
  echo "Locked. The loop is now categorically gated for this repo."
  echo "  repo:   $REPO"
  echo "  marker: $MARKER (root-owned; the agent's user cannot remove it)"
fi

# Freeze the hook wiring too. The marker is only as strong as the hook that reads it, and that hook
# lives entirely inside .claude/ — a directory the agent owns as much as the marker. Unwiring the
# guard from in there is quieter than any rm, and a Bash PreToolUse guard cannot even see an
# Edit-tool change to a file. There are at least three doors, which is why this freezes the
# subtree rather than a filename:
#
#   1. .claude/settings.json          — `disableAllHooks`, or just delete the hooks block.
#   2. .claude/settings.local.json    — accepts `disableAllHooks` too, sits in the same checkout,
#                                       and usually does not exist yet, so the agent can CREATE it.
#   3. .claude/scripts/block-human-gated-actions.sh — edit `exit 0` into the top of the hook and
#                                       no settings file needs touching at all.
#
# Freezing .claude/ and its contents means the agent can neither edit, create, rename, nor delete
# anything in there while the run is locked; only unlock-loop.sh lifts the flags.
if [ -d "$CLAUDE_DIR" ]; then
  if freeze_tree "$CLAUDE_DIR"; then
    echo "  frozen: $CLAUDE_DIR (whole subtree — the agent cannot unwire the guard while locked)"
    echo "          this includes settings.json, settings.local.json, and the hook script itself"
  fi
else
  echo "  NOTE: $CLAUDE_DIR not found — hook wiring not frozen. Is the guard installed in this repo?" >&2
fi

echo
echo "Next:  run /orchestrate <id> as usual. Clear the gate when you act on the card:"
echo "  sudo $(dirname "${BASH_SOURCE[0]}")/unlock-loop.sh"
echo
echo 'While locked, "Allow always" on a permission prompt will fail — Claude Code records that'
echo "grant in .claude/settings.local.json, which is frozen. That is the lock working, not a"
echo "fault: a standing allow rule written mid-run is exactly the thing the freeze exists to stop."
echo "Choose \"Allow once\" for the run, or unlock first if you genuinely want a permanent grant."
