#!/bin/bash
# Suite for scripts/loop-gate.zsh — the human's `ungate` function.
#
# Run: bash scripts/tests/test-ungate.sh
#
# A loop running in a git worktree writes .loop-active at that worktree's root, so ungate has to
# find markers across every checkout of the repo. Runs under bash and, when present, zsh — the
# file is sourced from either. The repo path contains a space, as real ones do.

GATE="$(cd "$(dirname "$0")/.." && pwd)/loop-gate.zsh"
PASS=0; FAIL=0
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT

setup() {
  rm -rf "$T/my repo" "$T/wt b"
  git init -q "$T/my repo"
  git -C "$T/my repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$T/my repo" worktree add -q "$T/my repo/.claude/worktrees/a" -b a 2>/dev/null
  git -C "$T/my repo" worktree add -q "$T/wt b" -b b 2>/dev/null
}
# $1 = shell, $2 = directory to run in, $3 = ungate arguments
run_ungate() { ( cd "$2" && "$1" -c "source '$GATE'; ungate $3" 2>&1 ); }
check() { # $1 = label, $2 = condition result (0 = pass)
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "  FAIL [$SH]: $1"; fi
}

for SH in bash zsh; do
  command -v "$SH" >/dev/null 2>&1 || { echo "  SKIP: $SH not installed"; continue; }
  echo "== $SH =="

  setup; : > "$T/wt b/.loop-active"
  run_ungate "$SH" "$T/my repo" "" >/dev/null
  [ ! -f "$T/wt b/.loop-active" ]; check "from the main checkout, clears the only marker (in a worktree)" $?

  setup; : > "$T/my repo/.claude/worktrees/a/.loop-active"
  run_ungate "$SH" "$T/my repo/.claude/worktrees/a" "" >/dev/null
  [ ! -f "$T/my repo/.claude/worktrees/a/.loop-active" ]; check "inside a worktree, clears that worktree's marker" $?

  setup; : > "$T/my repo/.loop-active"; : > "$T/wt b/.loop-active"
  OUT=$(run_ungate "$SH" "$T/my repo" "")
  { [ ! -f "$T/my repo/.loop-active" ] && [ -f "$T/wt b/.loop-active" ]; }; check "clears the current checkout's marker and leaves the other" $?
  printf '%s' "$OUT" | grep -q "still gated   $T/wt b/.loop-active"; check "lists the marker it left, path with a space intact" $?
  printf '%s' "$OUT" | grep -q "still gated   $T/my repo/.loop-active"
  [ $? -ne 0 ]; check "does not list the marker it just cleared as still gated" $?

  setup; : > "$T/my repo/.claude/worktrees/a/.loop-active"; : > "$T/wt b/.loop-active"
  OUT=$(run_ungate "$SH" "$T/my repo" "")
  { [ -f "$T/my repo/.claude/worktrees/a/.loop-active" ] && [ -f "$T/wt b/.loop-active" ]; }; check "with several markers elsewhere, clears nothing" $?
  printf '%s' "$OUT" | grep -q 'several runs are gated'; check "with several markers elsewhere, says so" $?

  run_ungate "$SH" "$T/my repo" "--all" >/dev/null
  { [ ! -f "$T/my repo/.claude/worktrees/a/.loop-active" ] && [ ! -f "$T/wt b/.loop-active" ]; }; check "--all clears every checkout" $?

  setup
  OUT=$(run_ungate "$SH" "$T/my repo" "")
  printf '%s' "$OUT" | grep -q 'already clear'; check "with no markers, reports already clear" $?

  mkdir -p "$T/plain"; : > "$T/plain/.loop-active"
  run_ungate "$SH" "$T/plain" "" >/dev/null
  [ ! -f "$T/plain/.loop-active" ]; check "outside a git repo, clears the marker in the current directory" $?
done

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
