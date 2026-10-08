#!/usr/bin/env bash
# PostToolUse hook: record which Claude Code sessions worked on which workstream.
#
# When a session writes a file under docs/execution/active/<id>/ (Write / Edit / MultiEdit /
# NotebookEdit), or runs init-workstream.sh <id>, its session id is appended once to the
# workstream's session log. close-workstream.sh covers exactly those sessions, so nobody has to
# reconstruct afterward which sessions belonged to the run.
#
# Where the log lives: <git common dir>/loop-sessions/<id>.log, i.e. inside .git/. Every worktree
# of a repo shares that directory and git never commits it, so a run in a worktree is still on
# record when the PM closes the workstream from the main checkout, and after the worktree is
# removed. Outside a git repo the log falls back to docs/execution/active/<id>/SESSIONS.log.
#
# Membership is "wrote to the workstream", not "mentioned it": a session that only reads the
# files (a status question, a Slack catch-up) is not recorded.
#
# Line format (tab-separated): <session_id>  <first-seen UTC>  <cwd>
#
# Never blocks and never fails the tool call: every path exits 0.

input="$(cat 2>/dev/null)" || exit 0

field() {  # first "key": "value" string in the hook input
  printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -n 1
}

session_id="$(field session_id)"
[ -n "$session_id" ] || exit 0
cwd="$(field cwd)"
# The checkout the session works in is the git top level of its `cwd`, not $CLAUDE_PROJECT_DIR:
# in a session inside a git worktree that variable can name a different checkout (the main one),
# where the worktree's new workstream folder does not exist yet, so nothing was recorded.
root=""
[ -n "$cwd" ] && root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"
[ -n "$root" ] || root="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -n "$root" ] || exit 0

ws_dir=""
path="$(field file_path)"
[ -n "$path" ] || path="$(field notebook_path)"
if [ -n "$path" ]; then
  case "$path" in /*) ;; *) path="$cwd/$path" ;; esac
  # everything up to and including docs/execution/active/<id>
  ws_dir="$(printf '%s' "$path" | sed -n 's|^\(.*/docs/execution/active/[^/][^/]*\)/.*|\1|p')"
else
  command="$(field command)"
  id="$(printf '%s' "$command" | sed -n 's|.*init-workstream\.sh[[:space:]][[:space:]]*\([A-Za-z0-9._-][A-Za-z0-9._-]*\).*|\1|p' | head -n 1)"
  [ -n "$id" ] && ws_dir="$root/docs/execution/active/$id"
  # Still try the project dir when the cwd checkout has no such folder, so a case that recorded
  # before (cwd outside the project) keeps recording.
  if [ -n "$id" ] && [ ! -d "$ws_dir" ] && [ -n "$CLAUDE_PROJECT_DIR" ]; then
    ws_dir="$CLAUDE_PROJECT_DIR/docs/execution/active/$id"
  fi
fi

[ -n "$ws_dir" ] && [ -d "$ws_dir" ] || exit 0
id="$(basename "$ws_dir")"
common="$(git -C "$ws_dir" rev-parse --git-common-dir 2>/dev/null)"
if [ -n "$common" ]; then
  case "$common" in /*) ;; *) common="$ws_dir/$common" ;; esac
  mkdir -p "$common/loop-sessions" 2>/dev/null || exit 0
  log="$common/loop-sessions/$id.log"
else
  log="$ws_dir/SESSIONS.log"
fi
grep -qs "^$session_id	" "$log" && exit 0
printf '%s\t%s\t%s\n' "$session_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cwd" >> "$log" 2>/dev/null
exit 0
