#!/bin/bash
# Regression suite for scripts/block-human-gated-actions.sh
#
# Run: bash scripts/tests/test-block-human-gated-actions.sh
# (Invoke via `bash` — the repo is synced to machines that do not preserve the +x bit.)
#
# The guard is fail-closed, so a false positive blocks legitimate work rather than letting a
# hidden action through. That is not free: a guard that cries wolf trains the reflexive
# override, and a reflex-used override means nothing. Every must-pass case below is there
# because blocking it would be a defect, not a nuisance.

GUARD="$(cd "$(dirname "$0")/.." && pwd)/block-human-gated-actions.sh"
PASS=0
FAIL=0

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/marked" "$TMPROOT/clear"
: > "$TMPROOT/marked/.loop-active"

run_guard() { # $1 = repo root, $2 = command
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$2" | jq -Rs .)" \
    | CLAUDE_PROJECT_DIR="$1" bash "$GUARD" 2>/dev/null
  return $?
}

expect_block() { # $1 = label, $2 = command
  run_guard "$TMPROOT/marked" "$2"
  if [ $? -eq 2 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "  FAIL (expected BLOCK, got allow): $1 — $2"
  fi
}

expect_pass() { # $1 = label, $2 = command
  run_guard "$TMPROOT/marked" "$2"
  if [ $? -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "  FAIL (expected ALLOW, got block): $1 — $2"
  fi
}

expect_pass_unmarked() { # $1 = label, $2 = command
  run_guard "$TMPROOT/clear" "$2"
  if [ $? -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "  FAIL (expected ALLOW with no marker, got block): $1 — $2"
  fi
}

echo "== shipping verbs must block while a run is live =="
expect_block "gh pr create"            'gh pr create --fill'
expect_block "gh pr merge"             'gh pr merge 12 --squash'
expect_block "gh pr ready"             'gh pr ready 12'
expect_block "gh pr review --approve"  'gh pr review 12 --approve'
expect_block "git push"                'git push'
expect_block "git push with remote"    'git push origin feature/x'
expect_block "git -C push"             'git -C /tmp/repo push origin main'
expect_block "push after &&"           'npm test && git push origin main'
expect_block "gh api pulls POST"       'gh api repos/o/r/pulls -X POST -f title=x'
expect_block "gh api POST then pulls"  'gh api -X POST repos/o/r/pulls -f title=x'
expect_block "gh api merge PUT"        'gh api repos/o/r/pulls/1/merge --method PUT'

echo "== the marker is human-only =="
expect_block "rm marker"               'rm .loop-active'
expect_block "rm -f marker"            'rm -f .loop-active'
expect_block "rm absolute path"        'rm -f /Users/x/repo/.loop-active'
expect_block "rm quoted marker"        "rm '.loop-active'"
expect_block "mv marker away"          'mv .loop-active .loop-done'
expect_block "unlink marker"           'unlink .loop-active'
expect_block "shred marker"            'shred -u .loop-active'
expect_block "find -delete marker"     'find . -name .loop-active -delete'
expect_block "clear gate then push"    'rm .loop-active && git push origin main'
expect_block "git clean -fdx"          'git clean -fdx'
expect_block "git clean -xf"           'git clean -xf'
expect_block "git -C clean -fdx"       'git -C /tmp/repo clean -fdx'

echo "== ordinary work must not be blocked =="
expect_pass "commit"                   'git commit -m "feat: add the thing"'
expect_pass "commit naming push"       'git commit -m "prepare the push branch"'
expect_pass "stage"                    'git add -A'
expect_pass "status"                   'git status --porcelain'
expect_pass "log"                      'git log --oneline -5'
expect_pass "branch"                   'git switch -c feature/x'
expect_pass "tests"                    'npm test'
expect_pass "build"                    'npm run build'
expect_pass "read the marker"          'cat .loop-active'
expect_pass "grep for the marker"      'grep -rn "loop-active" README.md'
expect_pass "ls the marker"            'ls -la .loop-active'
expect_pass "rm unrelated tree"        'rm -rf node_modules'
expect_pass "rm unrelated file"        'rm -f dist/bundle.js'
expect_pass "mv unrelated file"        'mv src/a.ts src/b.ts'
expect_pass "git clean without -x"     'git clean -fd'
expect_pass "gitignore append"         'printf "\n.loop-active\n" >> .gitignore'
expect_pass "truncate marker (still exists)" ': > .loop-active'
expect_pass "gh pr list"               'gh pr list'
expect_pass "gh pr view"               'gh pr view 12'
expect_pass "gh pr diff"               'gh pr diff 12'
expect_pass "gh api GET pulls"         'gh api repos/o/r/pulls'
expect_pass "gh issue create"          'gh issue create --title x'

echo "== with no marker, nothing is gated =="
expect_pass_unmarked "push"            'git push origin main'
expect_pass_unmarked "pr create"       'gh pr create --fill'
expect_pass_unmarked "human clears gate" 'rm .loop-active'

echo "== a block must explain itself on stderr =="
ERRTEXT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"}}' \
  | CLAUDE_PROJECT_DIR="$TMPROOT/marked" bash "$GUARD" 2>&1 >/dev/null)
if [ -n "$ERRTEXT" ]; then PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); echo "  FAIL: blocked command produced no stderr reason"; fi

echo "== malformed input fails open =="
if printf 'not json' | CLAUDE_PROJECT_DIR="$TMPROOT/marked" bash "$GUARD" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); echo "  FAIL: malformed stdin should fail open"; fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
