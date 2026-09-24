#!/bin/bash
# Live smoke test for the hard lock. The one suite that needs root, because it sets real
# immutable flags — the other suites stub chflags/chattr and so cannot prove the freeze holds.
#
# Run: sudo bash scripts/tests/smoke-hard-lock.sh
#
# Touches nothing outside a throwaway repo under /tmp and a throwaway guard dir: LOOP_GUARD_DIR
# points at a temp directory, so /var/run/loop-guard and your real repos are never involved.
# Always unlocks and deletes the throwaway repo on exit, pass or fail.

set -u
if [ "$(id -u)" -ne 0 ] || [ -z "${SUDO_USER:-}" ]; then
  echo "Run with sudo from your own account:  sudo bash $0" >&2
  exit 1
fi

KIT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok:   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
as_user() { sudo -u "$SUDO_USER" "$@"; }
# Succeeds only if the user can write the path: an edit of an existing file, or a new file.
user_can_write() { as_user bash -c "printf x >> '$1'" 2>/dev/null; }
flagged() {
  if command -v chflags >/dev/null 2>&1; then ls -ldO "$1" 2>/dev/null | grep -qw schg
  else lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q i; fi
}

T="$(as_user mktemp -d /tmp/loop-smoke.XXXXXX)"; T="$(cd "$T" && pwd -P)"
G="$(mktemp -d /tmp/loop-smoke-guard.XXXXXX)"
export LOOP_GUARD_DIR="$G"
cleanup() {
  ( cd "$T/repo" 2>/dev/null && bash .claude/scripts/unlock-loop.sh >/dev/null 2>&1 )
  command -v chflags >/dev/null 2>&1 && chflags -R noschg "$T" 2>/dev/null
  command -v chattr  >/dev/null 2>&1 && chattr -R -i "$T" 2>/dev/null
  rm -rf "$T" "$G"
}
trap cleanup EXIT

echo "== setup: throwaway repo with the kit installed, two worktrees, a symlink out of .claude =="
as_user bash -c "
  set -e
  git init -q '$T/repo'
  mkdir -p '$T/repo/.claude/scripts' '$T/outside'
  cp '$KIT'/scripts/*.sh '$T/repo/.claude/scripts/'
  printf '{}\n' > '$T/repo/.claude/settings.json'
  printf 'secret\n' > '$T/outside/target.txt'
  ln -s '$T/outside/target.txt' '$T/repo/.claude/link-out'
  git -C '$T/repo' add -A
  git -C '$T/repo' -c user.email=t@t -c user.name=t commit -qm init
  git -C '$T/repo' worktree add -q '$T/repo/.claude/worktrees/w1' -b w1
  git -C '$T/repo' worktree add -q '$T/w2' -b w2
" || { echo "setup failed"; exit 1; }

echo "== lock, from inside the repo =="
( cd "$T/repo" && bash .claude/scripts/lock-loop.sh >"$T.lock.out" 2>&1 ) \
  && ok "lock-loop.sh exited 0" || { bad "lock-loop.sh failed"; cat "$T.lock.out"; }
grep -q '^Locked\.' "$T.lock.out" && ok "lock printed Locked" || bad "lock did not print Locked"

echo "== the freeze holds against the user (G4, G12) =="
user_can_write "$T/repo/.claude/settings.json"        && bad "main settings.json is editable"      || ok "main settings.json is frozen"
user_can_write "$T/repo/.claude/settings.local.json"  && bad "main settings.local.json can be created" || ok "main settings.local.json cannot be created"
user_can_write "$T/repo/.claude/scripts/block-human-gated-actions.sh" && bad "the hook script is editable" || ok "the hook script is frozen"
user_can_write "$T/w2/.claude/settings.json"          && bad "worktree w2's settings.json is editable" || ok "worktree w2's .claude is frozen"
user_can_write "$T/repo/.claude/worktrees/w1/.claude/settings.json" && bad "worktree w1's settings.json is editable" || ok "worktree w1's .claude is frozen"
user_can_write "$T/repo/.claude/worktrees/w1/new.txt" && ok "files in a worktree stay writable" || bad "worktree w1 is not writable"
user_can_write "$T/w2/new.txt"                        && ok "files in worktree w2 stay writable" || bad "worktree w2 is not writable"

echo "== symlinks are flagged themselves, never their targets (G7) =="
flagged "$T/outside/target.txt" && bad "the symlink's target outside .claude was frozen" || ok "the symlink's target is untouched"
user_can_write "$T/outside/target.txt" && ok "the symlink's target is still writable" || bad "the symlink's target is not writable"

echo "== one lock gates every worktree (G5) =="
for wt in "$T/repo" "$T/w2" "$T/repo/.claude/worktrees/w1"; do
  printf '{"tool_input":{"command":"git push"}}' \
    | as_user env LOOP_GUARD_DIR="$G" CLAUDE_PROJECT_DIR="$wt" bash "$T/repo/.claude/scripts/block-human-gated-actions.sh" 2>/dev/null
  [ $? -eq 2 ] && ok "push blocked in ${wt#$T/}" || bad "push allowed in ${wt#$T/}"
done
ERR=$(printf '{"tool_input":{"command":"git push"}}' \
  | as_user env LOOP_GUARD_DIR="$G" CLAUDE_PROJECT_DIR="$T/w2" bash "$T/repo/.claude/scripts/block-human-gated-actions.sh" 2>&1 >/dev/null)
printf '%s' "$ERR" | grep -q 'unlock-loop.sh' && ok "the denial names unlock-loop.sh (G2)" || bad "the denial does not name unlock-loop.sh"
( cd "$T/w2" && as_user env LOOP_GUARD_DIR="$G" bash "$T/repo/.claude/scripts/loop-status.sh" 2>/dev/null ) | grep -q '^ACTIVE' \
  && ok "status in a worktree reports ACTIVE" || bad "status in a worktree does not report ACTIVE"

echo "== unlock, from inside a worktree =="
( cd "$T/w2" && bash "$T/repo/.claude/scripts/unlock-loop.sh" >"$T.unlock.out" 2>&1 ) \
  && ok "unlock-loop.sh exited 0" || { bad "unlock-loop.sh failed"; cat "$T.unlock.out"; }
[ -z "$(ls -A "$G")" ] && ok "the marker is gone" || bad "the marker is still present"
user_can_write "$T/repo/.claude/settings.json" && ok "main .claude is writable again" || bad "main .claude is still frozen"
user_can_write "$T/w2/.claude/settings.json"   && ok "worktree w2's .claude is writable again" || bad "worktree w2's .claude is still frozen"
user_can_write "$T/repo/.claude/worktrees/w1/.claude/settings.json" && ok "worktree w1's .claude is writable again" || bad "worktree w1's .claude is still frozen"
flagged "$T/repo/.claude/link-out" && bad "the symlink inside .claude is still flagged" || ok "the symlink inside .claude is unflagged"
as_user git -C "$T/repo" worktree remove --force "$T/w2" 2>/dev/null && ok "a worktree can be removed after unlock" || bad "a worktree cannot be removed after unlock"

rm -f "$T.lock.out" "$T.unlock.out"
echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
