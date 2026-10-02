#!/usr/bin/env bash
# PostToolUse hook: record which Claude Code sessions worked on which workstream.
#
# When a session writes a file under docs/execution/active/<id>/ (Write / Edit / MultiEdit /
# NotebookEdit), or runs init-workstream.sh <id>, its session id is appended once to
# docs/execution/active/<id>/SESSIONS.log. close-workstream.sh prices exactly those sessions,
# so nobody has to reconstruct afterward which sessions belonged to the run.
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
root="${CLAUDE_PROJECT_DIR:-$cwd}"
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
fi

[ -n "$ws_dir" ] && [ -d "$ws_dir" ] || exit 0
log="$ws_dir/SESSIONS.log"
grep -qs "^$session_id	" "$log" && exit 0
printf '%s\t%s\t%s\n' "$session_id" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$cwd" >> "$log" 2>/dev/null
exit 0
