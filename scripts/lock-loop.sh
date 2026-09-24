#!/usr/bin/env bash
# Drop the HARD run marker for this repo — the opt-in marker the agent cannot remove.
#
#   Run:  sudo ./.claude/scripts/lock-loop.sh   (from inside the repo, or any of its worktrees)
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

# Freeze errors are collected here, not thrown away (G6). A lock that failed to freeze part of the
# hook wiring and still printed "Locked" was worse than no lock: it told the human the guard could
# not be unwired while leaving a file that unwires it editable.
FREEZE_ERR="$(mktemp)"
trap 'rm -f "$FREEZE_ERR"' EXIT

# Make a path immutable even against its owner: schg (macOS) / +i (Linux). Both need root to set
# AND to clear, so a non-root agent can neither modify the path nor lift the flag.
# -h: flag a symlink itself, never its target (G7). Following a link inside .claude froze whatever
# it pointed at — possibly outside the repo — and unlock never lifted it.
freeze() {
  if   command -v chflags >/dev/null 2>&1; then chflags -h schg "$1" 2>>"$FREEZE_ERR"
  elif command -v chattr  >/dev/null 2>&1; then chattr +i "$1" 2>>"$FREEZE_ERR"
  else echo "no chflags or chattr found — cannot freeze $1" >>"$FREEZE_ERR"; return 1; fi
}

is_frozen() {  # 0 = immutable flag is set
  if   command -v chflags >/dev/null 2>&1; then ls -ldO "$1" 2>/dev/null | grep -qw schg
  elif command -v lsattr  >/dev/null 2>&1; then lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q i
  else return 1; fi
}

# The rollback half of fail-loud. Same walk as unlock-loop.sh's unfreeze_tree: directory first so
# the parent is writable before its children are touched; links cleared with -h.
unfreeze_tree() {
  local d="$1"
  [ -e "$d" ] || [ -L "$d" ] || return 0
  if   command -v chflags >/dev/null 2>&1; then
    chflags -R noschg "$d" 2>/dev/null || true
    find "$d" -type l -exec chflags -h noschg {} + 2>/dev/null || true
  elif command -v chattr  >/dev/null 2>&1; then
    find "$d" -type d -exec chattr -i {} + 2>/dev/null || true
    find "$d" -type f -exec chattr -i {} + 2>/dev/null || true
  fi
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
    find "$d" -depth -exec chflags -h schg {} + 2>>"$FREEZE_ERR"
  elif command -v chattr >/dev/null 2>&1; then
    find "$d" -type f -exec chattr +i {} + 2>>"$FREEZE_ERR" \
      && find "$d" -depth -type d -exec chattr +i {} + 2>>"$FREEZE_ERR"
  else
    echo "no chflags or chattr found — cannot freeze $d" >>"$FREEZE_ERR"; return 1
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

CREATED_MARKER=0
if [ -f "$MARKER" ]; then
  echo "Already locked: a hard run marker is in force for this repo. Re-freezing the hook wiring."
else
  : > "$MARKER"
  chmod 644 "$MARKER"
  printf 'repo=%s\nlocked_at=%s\nlocked_by=%s\n' \
    "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SUDO_USER:-root}" > "$MARKER"
  CREATED_MARKER=1
fi

# Every .claude this run froze that was NOT frozen before it, so a failure undoes exactly this
# run's work. A lock already in force when this ran is left as it was.
NEWLY_FROZEN=()
lock_failed() {
  echo >&2
  echo "LOCK FAILED: could not freeze $1" >&2
  sed 's/^/  /' "$FREEZE_ERR" | head -20 >&2
  local d
  for d in ${NEWLY_FROZEN[@]+"${NEWLY_FROZEN[@]}"}; do
    unfreeze_tree "$d"
    echo "  rolled back: $d" >&2
  done
  if [ "$CREATED_MARKER" -eq 1 ]; then
    rm -f "$MARKER"
    echo "  No lock is in force. Fix the error above and run this again." >&2
  else
    echo "  The lock that was already in force is unchanged; only this run's freezes were undone." >&2
  fi
  exit 1
}

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
# Freeze one .claude directory: resolve a symlink, freeze the real tree, then freeze the link.
# Runs for the main checkout and again for every worktree (G12): one lock covers every worktree's
# sessions, and a session in a worktree reads THAT worktree's .claude, not the main one.
freeze_claude() {
  local CLAUDE_LINK="$1" CLAUDE_DIR="$1" is_main="$2"
  if [ -L "$CLAUDE_DIR" ]; then
    CLAUDE_DIR="$(cd "$CLAUDE_DIR" 2>/dev/null && pwd -P)" || {
      echo "  WARNING: $CLAUDE_LINK is a symlink that does not resolve — not frozen." >&2; return 0; }
  fi
  if [ -d "$CLAUDE_DIR" ]; then
    # worktrees/ has to exist BEFORE the freeze: once .claude is immutable, nothing can create it,
    # and the first parallel worktree of the run would fail. Owned like .claude, not by root.
    if [ "$is_main" = main ] && [ ! -e "$CLAUDE_DIR/worktrees" ]; then
      OWNER="$(stat -f '%u:%g' "$CLAUDE_DIR" 2>/dev/null || stat -c '%u:%g' "$CLAUDE_DIR")"
      mkdir "$CLAUDE_DIR/worktrees" && chown "$OWNER" "$CLAUDE_DIR/worktrees"
    fi
    is_frozen "$CLAUDE_DIR" || NEWLY_FROZEN+=("$CLAUDE_DIR")
    freeze_tree "$CLAUDE_DIR" || lock_failed "$CLAUDE_DIR"
    echo "  frozen: $CLAUDE_DIR (whole subtree except worktrees/ — the agent cannot unwire the guard while locked)"
    echo "          this includes settings.json, settings.local.json, and the hook script itself"
    if [ "$is_main" = main ]; then
      echo "          worktrees/ stays writable so parallel worktrees keep working"
    fi
    printf 'frozen=%s\n' "$CLAUDE_DIR" >> "$MARKER"   # unlock reads these back
    # Freeze the LINK too, or the agent repoints .claude at a directory it does control and the
    # frozen target stops being the one Claude Code reads. -h flags the link, not its target.
    if [ "$CLAUDE_LINK" != "$CLAUDE_DIR" ]; then
      if command -v chflags >/dev/null 2>&1 && chflags -h schg "$CLAUDE_LINK" 2>/dev/null; then
        echo "  frozen: $CLAUDE_LINK (the symlink itself — cannot be repointed while locked)"
        NEWLY_FROZEN+=("$CLAUDE_LINK")
      else
        echo "  WARNING: $CLAUDE_LINK is a symlink and could not be frozen (chattr cannot flag a" >&2
        echo "           symlink on Linux). The target is frozen, but the link could be repointed." >&2
      fi
    fi
  else
    echo "  NOTE: $CLAUDE_DIR not found — hook wiring not frozen. Is the guard installed in this repo?" >&2
  fi
}

freeze_claude "$CLAUDE_LINK" main

# Every other worktree of the repo. A worktree with no .claude has no project hook at all, so its
# sessions are gated only by user-level settings — say so rather than report a freeze that did
# not happen. A worktree added AFTER this runs is not frozen; re-running this script (idempotent)
# picks it up, and loop-status.sh warns about any it finds unfrozen.
while IFS= read -r WT; do
  [ -n "$WT" ] || continue
  if [ -e "$WT/.claude" ] || [ -L "$WT/.claude" ]; then
    freeze_claude "$WT/.claude" worktree
  else
    echo "  NOTE: worktree $WT has no .claude — sessions there have no project hook to freeze." >&2
  fi
done <<EOF
$(git -c safe.directory='*' -C "$REPO" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | tail -n +2 || true)
EOF

echo
echo "Locked. The run marker for this repo cannot be removed by the agent until you unlock."
echo "  The push/PR block is still text matching; branch protection on the remote is the backstop."
echo "  repo:   $REPO"
echo "  marker: $MARKER (root-owned; the agent's user cannot remove it)"
echo "  covers: every worktree of this repo; each worktree's .claude is frozen above"

echo
echo "Next:  run /orchestrate <id> as usual. Clear the gate when you act on the card:"
echo "  sudo $(dirname "${BASH_SOURCE[0]}")/unlock-loop.sh"
echo
echo 'While locked, "Allow always" on a permission prompt will fail — Claude Code records that'
echo "grant in .claude/settings.local.json, which is frozen. That is the lock working, not a"
echo "fault: a standing allow rule written mid-run is exactly the thing the freeze exists to stop."
echo "Choose \"Allow once\" for the run, or unlock first if you genuinely want a permanent grant."
echo
echo "While locked, 'git worktree remove' fails for any worktree whose .claude is frozen. A worktree"
echo "added after this point is not frozen until you re-run this script."
