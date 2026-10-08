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
  git init -q "$R"
  cp -p "$KIT/scripts/close-workstream.sh" "$R/.claude/scripts/"
  cp -p "$KIT"/scripts/workstream-cost/*.py "$KIT"/scripts/workstream-cost/*.html "$R/.claude/scripts/workstream-cost/"
}
hook() { # $1 = session id, $2 = JSON tool_input body, $3 = project dir (default $R); returns the hook's exit code
  local root="${3:-$R}"
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Edit","tool_input":{%s}}' \
    "$1" "$root" "$2" | CLAUDE_PROJECT_DIR="$root" bash "$HOOK" >/dev/null 2>&1
}
LOG_A="$R/.git/loop-sessions/feat-a.log"

echo "== file modes =="
for s in close-workstream.sh record-workstream-session.sh workstream-cost/workstream_cost.py; do
  [ -x "$KIT/scripts/$s" ]; check "$s is executable in the kit" $?
done

echo "== record-workstream-session.sh =="
setup
hook "aaaa1111-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/RUN_LOG.md\""
check "hook exits 0 on a workstream write" $?
grep -q "^aaaa1111-0000	" "$LOG_A"; check "records the session in .git/loop-sessions/<id>.log" $?
[ ! -e "$R/docs/execution/active/feat-a/SESSIONS.log" ]; check "writes nothing into the workstream folder in a git repo" $?

hook "aaaa1111-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/WORKBOARD.md\""
[ "$(grep -c . "$LOG_A")" -eq 1 ]; check "records each session once, however many writes" $?

hook "bbbb2222-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/REVIEW.md\""
[ "$(grep -c . "$LOG_A")" -eq 2 ]; check "a second session gets its own line" $?

hook "cccc3333-0000" "\"file_path\":\"$R/src/app.ts\""
! grep -rqs "cccc3333" "$R/.git/loop-sessions" "$R/docs"; check "a write outside any workstream records nothing" $?

hook "dddd4444-0000" "\"file_path\":\"docs/execution/active/feat-b/README.md\""
grep -qs "^dddd4444-0000	" "$R/.git/loop-sessions/feat-b.log"; check "relative paths resolve against cwd" $?

hook "eeee5555-0000" "\"file_path\":\"$R/docs/execution/active/ghost/README.md\""
[ ! -e "$R/docs/execution/active/ghost" ] && [ ! -e "$R/.git/loop-sessions/ghost.log" ]; check "never records a workstream folder that doesn't exist" $?

hook "ffff6666-0000" "\"command\":\"./.claude/scripts/init-workstream.sh feat-b\""
grep -qs "^ffff6666-0000	" "$R/.git/loop-sessions/feat-b.log"; check "init-workstream.sh <id> records the creating session" $?

hook "gggg7777-0000" "\"command\":\"cat docs/execution/active/feat-a/RUN_LOG.md\""
! grep -qs "gggg7777" "$LOG_A"; check "a read-only command records nothing" $?

printf 'not json at all' | CLAUDE_PROJECT_DIR="$R" bash "$HOOK" >/dev/null 2>&1
check "garbage input still exits 0" $?
printf '' | bash "$HOOK" >/dev/null 2>&1
check "empty input still exits 0" $?

chmod a-w "$R/.git"; rm -rf "$R/.git/loop-sessions" 2>/dev/null
hook "hhhh8888-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/RUN_LOG.md\""
check "an unwritable .git still exits 0" $?
chmod u+w "$R/.git"

NG="$T/no git"; mkdir -p "$NG/docs/execution/active/feat-n"
hook "nnnn0000-0000" "\"file_path\":\"$NG/docs/execution/active/feat-n/RUN_LOG.md\"" "$NG"
grep -qs "^nnnn0000-0000	" "$NG/docs/execution/active/feat-n/SESSIONS.log"; check "outside git, falls back to SESSIONS.log in the folder" $?

echo "== worktree run, closed from the main checkout =="
M="$T/main repo"; rm -rf "$M"; mkdir -p "$M/docs/execution/active/feat-w"; git init -q "$M"
printf '# Workstream: feat-w\n' > "$M/docs/execution/active/feat-w/README.md"
git -C "$M" add -A && git -C "$M" -c user.email=t@t -c user.name=t commit -qm init
git -C "$M" worktree add -q "$M/.claude/worktrees/w1" -b w1 2>/dev/null
hook "wwww1111-0000" "\"file_path\":\"$M/.claude/worktrees/w1/docs/execution/active/feat-w/RUN_LOG.md\"" "$M/.claude/worktrees/w1"
grep -qs "^wwww1111-0000	" "$M/.git/loop-sessions/feat-w.log"; check "a worktree session lands in the shared .git/loop-sessions" $?
git -C "$M" worktree remove --force "$M/.claude/worktrees/w1" 2>/dev/null
grep -qs "^wwww1111-0000	" "$M/.git/loop-sessions/feat-w.log"; check "the record survives removing the worktree" $?
python3 - "$KIT/scripts/workstream-cost" "$M" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import workstream_cost as w
logs = w.session_logs(sys.argv[2], sys.argv[2] + "/docs/execution/done/feat-w")
sys.exit(0 if logs and logs[0].endswith(".git/loop-sessions/feat-w.log") else 1)
PY
check "record finds the worktree's sessions from the main checkout" $?

echo "== G13: init-workstream.sh in a worktree, with CLAUDE_PROJECT_DIR on the main checkout =="
# Claude Code can set CLAUDE_PROJECT_DIR to the main checkout while the session works in a git
# worktree, where the new workstream folder exists only in the worktree.
git -C "$M" worktree add -q "$M/.claude/worktrees/w2" -b w2 2>/dev/null
W2="$M/.claude/worktrees/w2"
mkdir -p "$W2/docs/execution/active/demo" "$W2/src"
[ ! -e "$M/docs/execution/active/demo" ]; check "suite setup: demo exists only in the worktree" $?
hook_split() { # $1 = session id, $2 = cwd, $3 = command; CLAUDE_PROJECT_DIR is the main checkout
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' \
    "$1" "$2" "$3" | CLAUDE_PROJECT_DIR="$M" bash "$HOOK" >/dev/null 2>&1
}
hook_split "iiii9999-0000" "$W2" "./.claude/scripts/init-workstream.sh demo"
check "hook exits 0" $?
grep -qs "^iiii9999-0000	" "$M/.git/loop-sessions/demo.log"; check "init in a worktree records the session in the shared log" $?
hook_split "jjjj0000-0000" "$W2/src" "../.claude/scripts/init-workstream.sh demo"
grep -qs "^jjjj0000-0000	" "$M/.git/loop-sessions/demo.log"; check "init from a worktree subdir records too" $?
hook_split "kkkk1111-0000" "$W2" "./.claude/scripts/init-workstream.sh ghost"
[ ! -e "$M/.git/loop-sessions/ghost.log" ]; check "init for a folder that exists nowhere records nothing" $?
git -C "$M" worktree remove --force "$W2" 2>/dev/null

echo "== close-workstream.sh =="
setup
hook "aaaa1111-0000" "\"file_path\":\"$R/docs/execution/active/feat-a/RUN_LOG.md\""
OUT=$(bash "$R/.claude/scripts/close-workstream.sh" feat-a --no-cost 2>&1)
[ -d "$R/docs/execution/done/feat-a" ] && [ ! -e "$R/docs/execution/active/feat-a" ]; check "moves active/<id> to done/<id>" $?
[ -x "$R/.claude/scripts/close-workstream.sh" ]; check "an installed copy keeps the execute bit" $?

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
[ -d "$R/docs/execution/done/feat-b" ]; check "closes a workstream with no recorded sessions" $?
printf '%s' "$OUT" | grep -q "No recorded sessions"; check "says why there is no run record" $?
! printf '%s' "$OUT" | grep -q "Retry with"; check "no recorded sessions is not reported as a failure" $?
printf '%s' "$OUT" | grep -q "rm .loop-active"; check "reminds the PM the run marker is still up" $?
[ -f "$R/.loop-active" ]; check "never removes the run marker itself" $?

mkdir -p "$R/docs/execution/active/feat-c" "$R/.git/loop-sessions"
printf 'deadbeef-0000-4000-8000-000000000000\t2026-01-01T00:00:00Z\t%s\n' "$R" > "$R/.git/loop-sessions/feat-c.log"  # well-formed, but no transcript exists
OUT=$(HOME="$T/home" bash "$R/.claude/scripts/close-workstream.sh" feat-c 2>&1); RC=$?
[ $RC -eq 0 ] && [ -d "$R/docs/execution/done/feat-c" ]; check "a failed cost step leaves the workstream closed and exits 0" $?
printf '%s' "$OUT" | grep -q "Retry with"; check "a failed cost step prints the retry command" $?
[ ! -f "$R/docs/execution/done/feat-c/COST.html" ]; check "writes no COST.html when nothing could be priced" $?

echo "== README run record =="
WS="$T/rr"; mkdir -p "$WS"
printf '# Workstream: rr\n\n## Objective\n\nShip it.\n\n## Loop Config\n\n- round_cap: 5\n' > "$WS/README.md"
rr() { python3 - "$KIT/scripts/workstream-cost" "$WS" "$1" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import workstream_cost as w
o = {"totals": {"input": 1, "cache_write_5m": 2, "cache_write_1h": 3, "cache_read": 4_000_000, "output": int(sys.argv[3])},
     "sessions": [{"start": "2026-01-01T10:00:00+00:00", "end": "2026-01-02T10:00:00+00:00", "subagents": 3,
                   "human_messages": 5, "models": {"Opus 5": 10}}],
     "calendar_s": 86400, "active_s": 3600, "attended_s": 1800, "active_gap_min": 15, "attend_window_min": 10,
     "ticket": "ABC-123", "notes": ["3 loop rounds (RUN_LOG.md)."], "warnings": []}
w.write_run_record(sys.argv[2], o)
PY
}
rr 500000
grep -q "^## Run record" "$WS/README.md" && grep -q "Ship it." "$WS/README.md" && grep -q "round_cap: 5" "$WS/README.md"
check "appends a Run record section and keeps the rest of the README" $?
! grep -q '\$' "$WS/README.md"; check "the README record carries no dollar figures" $?
grep -q "^- \*\*Attended:\*\* 0h 30m (main-session activity within 10 min" "$WS/README.md"; check "writes the Attended line" $?
grep -q "^- \*\*Ticket:\*\* ABC-123$" "$WS/README.md"; check "writes the Ticket line" $?
grep -q "^- \*\*Closed:\*\* $(date +%F)$" "$WS/README.md"; check "stamps the close date on the first write" $?
python3 - "$WS/README.md" <<'PY'
import re, sys; p = sys.argv[1]; s = open(p).read()
open(p, "w").write(re.sub(r"(\*\*Closed:\*\* )\S+", r"\g<1>2020-01-31", s))
PY
rr 900000
[ "$(grep -c '^## Run record' "$WS/README.md")" -eq 1 ] && grep -q "(0.9M output)" "$WS/README.md"
check "a re-run replaces the section instead of adding a second one" $?
grep -q "^- \*\*Closed:\*\* 2020-01-31$" "$WS/README.md"; check "a re-run keeps the original close date" $?

echo "== attended time =="
python3 - "$KIT/scripts/workstream-cost" <<'PY'
import sys, datetime as dt; sys.path.insert(0, sys.argv[1]); import workstream_cost as w
t = lambda m: dt.datetime(2026, 1, 1, tzinfo=dt.timezone.utc) + dt.timedelta(minutes=m)
ev = [t(m) for m in range(0, 121, 5)]          # main session busy for two hours, a log line every 5 min
assert w.attended_seconds(ev, [t(60)], 15, 10) == 20 * 60, "one message: 10 min either side"
assert w.attended_seconds(ev, [t(60), t(65)], 15, 10) == 25 * 60, "overlapping windows merge, no double count"
assert w.attended_seconds(ev, [], 15, 10) == 0, "no messages, no attended time"
gap = [t(0), t(5), t(40), t(45)]               # a 35-min silence is idle even inside a window
assert w.attended_seconds(gap, [t(5), t(40)], 15, 30) == 10 * 60, "idle gaps never count"
human = lambda c, **k: dict(type="user", message={"content": c}, **k)
assert w.is_human(human("fix the bug"))
assert w.is_human(human("<command-message>orchestrate</command-message>"))
assert not w.is_human(human("<system-reminder>x</system-reminder>"))
assert not w.is_human(human([{"type": "tool_result", "content": "ok"}]))
assert not w.is_human(human("hi", isMeta=True))
PY
check "attended_seconds and is_human behave as documented" $?

echo "== install.sh .gitignore =="
if [ -f "$KIT/install.sh" ]; then  # absent where the suite runs from an installed copy
  IR="$T/install target"; mkdir -p "$IR"; git init -q "$IR"
  printf 'node_modules/\n' > "$IR/.gitignore"
  bash "$KIT/install.sh" "$IR" >/dev/null 2>&1
  for p in docs/execution/active/a/SESSIONS.log docs/execution/done/a/COST.html docs/execution/done/a/cost.json; do
    git -C "$IR" check-ignore -q "$p"; check "install ignores $p" $?
  done
  ! git -C "$IR" check-ignore -q docs/execution/done/a/README.md; check "install keeps the workstream README tracked" $?
  grep -qxF "node_modules/" "$IR/.gitignore"; check "install keeps the repo's existing ignore rules" $?
  bash "$KIT/install.sh" "$IR" >/dev/null 2>&1
  [ "$(grep -cxF 'docs/execution/**/SESSIONS.log' "$IR/.gitignore")" -eq 1 ] && [ "$(grep -cxF '.loop-active' "$IR/.gitignore")" -eq 1 ]
  check "a second install adds no duplicate ignore lines" $?
else
  echo "  SKIP: no install.sh beside this suite (installed copy)"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
