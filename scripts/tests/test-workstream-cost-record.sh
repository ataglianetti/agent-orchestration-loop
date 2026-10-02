#!/bin/bash
# Suite for the cost record: scripts/record-workstream-session.sh (the PostToolUse hook that
# notes which sessions worked a workstream) and scripts/close-workstream.sh (the PM's close
# step that moves it to done/ and writes COST.html).
#
# Run: bash scripts/tests/test-workstream-cost-record.sh
#
# The repo path contains a space, as real ones do. No network and no real transcripts: the
# close step is exercised with --no-cost, plus one run that must fail soft when no
# transcript exists for a recorded session.

KIT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$KIT/scripts/record-workstream-session.sh"
PASS=0; FAIL=0
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
R="$T/my repo"

check() { # $1 = label, $2 = condition result (0 = pass)
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL: $1"; fi
}
setup() {
  rm -rf "$R"
  mkdir -p "$R/docs/execution/active/feat-a" "$R/docs/execution/active/feat-b" "$R/src" "$R/.claude/scripts/workstream-cost"
  cp "$KIT/scripts/close-workstream.sh" "$R/.claude/scripts/"
  cp "$KIT"/scripts/workstream-cost/*.py "$KIT"/scripts/workstream-cost/*.html "$R/.claude/scripts/workstream-cost/"
}
hook() { # $1 = session id, $2 = JSON tool_input body; returns the hook's exit code
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{%s}}' \
    "$1" "$R" "$2" | CLAUDE_PROJECT_DIR="$R" bash "$HOOK" >/dev/null 2>&1
}
LOG_A="$R/docs/execution/active/feat-a/SESSIONS.log"

echo "== record-workstream-session.sh =="
setup
hook "aaaa1111-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/RUN_LOG.md\""
check "hook exits 0 on a workstream write" $?
grep -q "^aaaa1111-0000	" "$LOG_A"; check "records the session on a write inside the workstream" $?

hook "aaaa1111-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/WORKBOARD.md\""
[ "$(grep -c . "$LOG_A")" -eq 1 ]; check "records each session once, however many writes" $?

hook "bbbb2222-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/REVIEW.md\""
[ "$(grep -c . "$LOG_A")" -eq 2 ]; check "a second session gets its own line" $?

hook "cccc3333-0000" "\"file_path\":\"$R/src/app.ts\""
! grep -rqs "cccc3333" "$R/docs/execution/active"; check "a write outside any workstream records nothing" $?

hook "dddd4444-0000" "\"file_path\":\"docs/execution/active/feat-b/README.md\""
grep -qs "^dddd4444-0000	" "$R/docs/execution/active/feat-b/SESSIONS.log"; check "relative paths resolve against cwd" $?

hook "eeee5555-0000" "\"file_path\":\"$R/docs/execution/active/ghost/README.md\""
[ ! -e "$R/docs/execution/active/ghost" ]; check "never creates a workstream folder that doesn't exist" $?

hook "ffff6666-0000" "\"command\":\"./.claude/scripts/init-workstream.sh feat-b\""
grep -qs "^ffff6666-0000	" "$R/docs/execution/active/feat-b/SESSIONS.log"; check "init-workstream.sh <id> records the creating session" $?

hook "gggg7777-0000" "\"command\":\"cat docs/execution/active/feat-a/RUN_LOG.md\""
! grep -qs "gggg7777" "$LOG_A"; check "a read-only command records nothing" $?

printf 'not json at all' | CLAUDE_PROJECT_DIR="$R" bash "$HOOK" >/dev/null 2>&1
check "garbage input still exits 0" $?
printf '' | bash "$HOOK" >/dev/null 2>&1
check "empty input still exits 0" $?

chmod a-w "$R/docs/execution/active/feat-a"; rm -f "$LOG_A" 2>/dev/null
hook "hhhh8888-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/RUN_LOG.md\""
check "an unwritable workstream folder still exits 0" $?
chmod u+w "$R/docs/execution/active/feat-a"

echo "== close-workstream.sh =="
setup
hook "aaaa1111-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/RUN_LOG.md\""
OUT=$(bash "$R/.claude/scripts/close-workstream.sh" feat-a --no-cost 2>&1)
[ -d "$R/docs/execution/done/feat-a" ] && [ ! -e "$R/docs/execution/active/feat-a" ]; check "moves active/<id> to done/<id>" $?
[ -f "$R/docs/execution/done/feat-a/SESSIONS.log" ]; check "SESSIONS.log travels with the folder" $?

bash "$R/.claude/scripts/close-workstream.sh" feat-a --no-cost >/dev/null 2>&1
[ $? -ne 0 ]; check "closing an already-closed workstream exits non-zero" $?

mkdir -p "$R/docs/execution/active/feat-a"
bash "$R/.claude/scripts/close-workstream.sh" feat-a --no-cost >/dev/null 2>&1; RC=$?
[ $RC -ne 0 ] && [ -d "$R/docs/execution/active/feat-a" ]; check "refuses to overwrite an existing done/<id>" $?

bash "$R/.claude/scripts/close-workstream.sh" nope --no-cost >/dev/null 2>&1
[ $? -ne 0 ]; check "an unknown id exits non-zero" $?

bash "$R/.claude/scripts/close-workstream.sh" feat-b --bogus >/dev/null 2>&1
[ $? -ne 0 ] && [ -d "$R/docs/execution/active/feat-b" ]; check "an unknown flag exits non-zero and moves nothing" $?

: > "$R/.loop-active"
OUT=$(bash "$R/.claude/scripts/close-workstream.sh" feat-b 2>&1); RC=$?
[ -d "$R/docs/execution/done/feat-b" ]; check "closes without SESSIONS.log" $?
printf '%s' "$OUT" | grep -q "No SESSIONS.log"; check "says why there is no cost record" $?
printf '%s' "$OUT" | grep -q "rm .loop-active"; check "reminds the PM the run marker is still up" $?
[ -f "$R/.loop-active" ]; check "never removes the run marker itself" $?

mkdir -p "$R/docs/execution/active/feat-c"
printf 'zzzz9999-not-a-real-session\t2026-01-01T00:00:00Z\t%s\n' "$R" > "$R/docs/execution/active/feat-c/SESSIONS.log"
OUT=$(HOME="$T/home" bash "$R/.claude/scripts/close-workstream.sh" feat-c 2>&1); RC=$?
[ $RC -eq 0 ] && [ -d "$R/docs/execution/done/feat-c" ]; check "a failed cost step leaves the workstream closed and exits 0" $?
printf '%s' "$OUT" | grep -q "Retry with"; check "a failed cost step prints the retry command" $?
[ ! -f "$R/docs/execution/done/feat-c/COST.html" ]; check "writes no COST.html when nothing could be priced" $?

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
