#!/bin/bash
# Hard-marker (opt-in physical gate) suite for the loop guard.
#
# Run: bash scripts/tests/test-hard-marker.sh
#
# The hard marker is a root-owned file outside the repo, dropped by `sudo lock-loop.sh`. Creating
# it for real needs root, so this suite fakes it: it points LOOP_GUARD_DIR at a temp directory and
# derives the marker's key exactly as every part of the system does — cksum of the git repo root.
# That exercises every code path except the root ownership itself, which is an OS property.
#
# In production CLAUDE_PROJECT_DIR IS the git repo root, so the hook (which keys on
# CLAUDE_PROJECT_DIR) and the lock/unlock/status scripts (which key on their own repo) resolve the
# same key. This suite mirrors that: it uses the real repo root as the project dir.

GUARD="$(cd "$(dirname "$0")/.." && pwd)/block-human-gated-actions.sh"
LOCK="$(cd "$(dirname "$0")/.." && pwd)/lock-loop.sh"
UNLOCK="$(cd "$(dirname "$0")/.." && pwd)/unlock-loop.sh"
STATUS="$(cd "$(dirname "$0")/.." && pwd)/loop-status.sh"
PASS=0
FAIL=0

REPO="$(git -C "$(dirname "$GUARD")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$GUARD")/../.." && pwd -P))"
KEY="$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)"

# A real soft marker in the repo would mask the "remove hard marker → allowed again" case.
if [ -f "$REPO/.loop-active" ]; then
  echo "SKIP: a real .loop-active is present in $REPO — cannot cleanly test the hard path here."
  exit 0
fi

TG=$(mktemp -d)            # fake guard dir (stands in for /var/run/loop-guard)
trap 'rm -f "$TG/$KEY"; rmdir "$TG" 2>/dev/null' EXIT

run() { # $1 = command  (project dir is always the real repo root, as in production)
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$1" | jq -Rs .)" \
    | LOOP_GUARD_DIR="$TG" CLAUDE_PROJECT_DIR="$REPO" bash "$GUARD" 2>/dev/null
  return $?
}

echo "== with the hard marker present and NO soft marker, shipping is gated =="
: > "$TG/$KEY"   # the fake hard lock
run 'git push origin main';   [ $? -eq 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: push not blocked by hard marker"; }
run 'gh pr create --fill';    [ $? -eq 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: pr create not blocked by hard marker"; }
run 'gh pr merge 3 --squash'; [ $? -eq 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: pr merge not blocked by hard marker"; }

echo "== ordinary work is still allowed under a hard lock =="
run 'git status --porcelain'; [ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: git status blocked under hard lock"; }
run 'npm test';               [ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: npm test blocked under hard lock"; }
run 'git commit -m x';        [ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: commit blocked under hard lock"; }

echo "== remove the hard marker and the same push is allowed again =="
rm -f "$TG/$KEY"
run 'git push origin main';   [ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: push blocked with no marker present"; }

echo "== loop-status.sh reports the hard lock (read-only, no root) =="
: > "$TG/$KEY"
OUT=$(LOOP_GUARD_DIR="$TG" bash "$STATUS" 2>/dev/null); RC=$?
{ [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^ACTIVE'; } && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: status did not report ACTIVE for a hard lock"; }
rm -f "$TG/$KEY"
OUT=$(LOOP_GUARD_DIR="$TG" bash "$STATUS" 2>/dev/null); RC=$?
{ [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q '^INACTIVE'; } && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: status did not report INACTIVE with no marker"; }

echo "== lock/unlock refuse to run without root (so a non-root agent cannot self-lock/unlock) =="
LOOP_GUARD_DIR="$TG" bash "$LOCK"   >/dev/null 2>&1; [ $? -ne 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock-loop ran without root"; }
LOOP_GUARD_DIR="$TG" bash "$UNLOCK" >/dev/null 2>&1; [ $? -ne 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: unlock-loop ran without root"; }

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
