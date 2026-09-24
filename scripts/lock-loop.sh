#!/usr/bin/env bash
# Drop the HARD run marker for this repo — the opt-in marker the agent cannot remove.
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

# .claude is very often a SYMLINK. People point it at a synced folder (Obsidian, Dropbox, a
# dotfiles repo) so one set of Claude settings follows them between machines. That breaks a naive
# subtree freeze in a way that fails LOUD-looking and silent-acting, which is worse than failing:
#
#   find <symlink> -depth   returns ONLY the link. It does not descend, so nothing inside is
#                           frozen, while the command still exits 0.
#   [ -d <symlink> ]        is TRUE, so a guard clause on it passes and the script cheerfully
#                           reports a subtree freeze that never happened.
#   chflags <symlink>       follows the link and flags the TARGET directory. So new files are
#                           blocked, but in-place edits to settings.json and to the hook script
#                           are not — exactly the two holes the subtree freeze exists to close.
#
# So resolve the link and operate on the real path. CLAUDE_LINK keeps the original so the link
# itself can be frozen too (chflags -h), which stops the agent repointing .claude at a directory
# it controls — freezing a target does nothing about swapping which target is named.
CLAUDE_LINK="$CLAUDE_DIR"
if [ -L "$CLAUDE_DIR" ]; then
  CLAUDE_DIR="$(cd "$CLAUDE_DIR" 2>/dev/null && pwd -P)" || {
    echo "lock-loop.sh: $CLAUDE_LINK is a symlink that does not resolve. Refusing to lock." >&2
    exit 1
  }
fi

# A resolved target OUTSIDE the repo is usually the synced-settings case, and freezing it reaches
# further than the run: the same directory may be live on another machine, and a sync client
# writing into an immutable folder fails confusingly on every device at once.
#
# WARN, do not refuse. An earlier version refused unless an env var was set, and that was the
# wrong shape. If a project's .claude is a symlink at all, it almost certainly points outside the
# repo — that is the entire reason to symlink it — so the refusal fired for essentially every
# real instance of the case it was written for, and sent a legitimate user hunting for a flag. A
# guard whose false positives block real work trains the reflex to override it, and a reflexive
# override is worth nothing. Say the consequence plainly and let the person who typed sudo decide;
# unlock reverses all of it.
if [ -n "${CLAUDE_DIR:-}" ]; then
  REPO_REAL="$(cd "$REPO" 2>/dev/null && pwd -P || printf '%s' "$REPO")"
  case "$CLAUDE_DIR/" in
    "$REPO_REAL"/*) : ;;
    *)
      echo "  WARNING: $CLAUDE_LINK resolves to $CLAUDE_DIR, outside this repo." >&2
      echo "           If that is a synced folder (Obsidian, Dropbox, a dotfiles repo), freezing it" >&2
      echo "           makes it immutable everywhere it syncs — not just for this run — and a sync" >&2
      echo "           client writing into a frozen folder can fail on every machine at once." >&2
      echo "           Untested against a live sync client. Locking anyway; unlock-loop.sh reverses it." >&2
      ;;
  esac
fi

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
# One exception: .claude/worktrees/. Claude Code puts parallel worktrees there, each a full
# checkout, and a frozen worktree cannot be edited, committed in, or removed — the lock would stop
# every parallel session in the repo. Nothing in there wires this repo's hook: Claude Code reads
# settings from the project's own .claude/, not from a worktree nested inside it. The .claude
# directory itself is still frozen, so worktrees/ cannot be renamed, replaced, or swapped for a
# link; only what is inside it stays writable.
#
# Contents first, directory last (-depth): the directory's own flag is set once its children are
# already done, which avoids depending on whether a given kernel lets you re-flag a child inside
# an already-immutable parent.
freeze_subtree() {
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

freeze_tree() {
  local root="$1" entry
  for entry in "$root"/* "$root"/.[!.]* "$root"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue   # unmatched glob
    [ "$entry" = "$root/worktrees" ] && continue
    freeze_subtree "$entry" || return 1
  done
  freeze "$root"   # the directory itself, last
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
  echo "Locked. The run marker for this repo cannot be removed by the agent until you unlock."
  echo "  The push/PR block is still text matching; branch protection on the remote is the backstop."
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
# -d (not -L -a -d): CLAUDE_DIR is the RESOLVED path by now, so this can no longer pass on a
# symlink whose contents were never walked.
if [ -d "$CLAUDE_DIR" ]; then
  # worktrees/ has to exist BEFORE the freeze: once .claude is immutable, nothing can create it,
  # and the first parallel worktree of the run would fail. Owned like .claude, not by root.
  if [ ! -e "$CLAUDE_DIR/worktrees" ]; then
    OWNER="$(stat -f '%u:%g' "$CLAUDE_DIR" 2>/dev/null || stat -c '%u:%g' "$CLAUDE_DIR")"
    mkdir "$CLAUDE_DIR/worktrees" && chown "$OWNER" "$CLAUDE_DIR/worktrees"
  fi
  if freeze_tree "$CLAUDE_DIR"; then
    echo "  frozen: $CLAUDE_DIR (whole subtree except worktrees/ — the agent cannot unwire the guard while locked)"
    echo "          this includes settings.json, settings.local.json, and the hook script itself"
    echo "          worktrees/ stays writable so parallel worktrees keep working"
    # Freeze the LINK too, or the agent repoints .claude at a directory it does control and the
    # frozen target stops being the one Claude Code reads. -h flags the link, not its target.
    if [ "$CLAUDE_LINK" != "$CLAUDE_DIR" ]; then
      if command -v chflags >/dev/null 2>&1 && chflags -h schg "$CLAUDE_LINK" 2>/dev/null; then
        echo "  frozen: $CLAUDE_LINK (the symlink itself — cannot be repointed while locked)"
      else
        echo "  WARNING: $CLAUDE_LINK is a symlink and could not be frozen (chattr cannot flag a" >&2
        echo "           symlink on Linux). The target is frozen, but the link could be repointed." >&2
      fi
    fi
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
