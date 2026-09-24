#!/bin/bash
# Hard-marker (opt-in physical gate) suite for the loop guard.
#
# Run: bash scripts/tests/test-hard-marker.sh
#
# The hard marker is a root-owned file outside the repo, dropped by `sudo lock-loop.sh`. Creating
# it for real needs root, so this suite fakes it: it points LOOP_GUARD_DIR at a temp directory and
# derives the marker's key with the same "guard key" block every part of the system runs — cksum of
# the repo's shared git directory. That exercises every code path except the root ownership
# itself, which is an OS property.

GUARD="$(cd "$(dirname "$0")/.." && pwd)/block-human-gated-actions.sh"
LOCK="$(cd "$(dirname "$0")/.." && pwd)/lock-loop.sh"
UNLOCK="$(cd "$(dirname "$0")/.." && pwd)/unlock-loop.sh"
STATUS="$(cd "$(dirname "$0")/.." && pwd)/loop-status.sh"
PASS=0
FAIL=0

REPO="$(git -C "$(dirname "$GUARD")" rev-parse --show-toplevel 2>/dev/null || (cd "$(dirname "$GUARD")/../.." && pwd -P))"
guard_block() { sed -n '/^# >>> guard key/,/^# <<< guard key/p' "$1"; }
# The block ends on a comment line, so anything run after it must start on a new line.
key_for() { # $1 = project dir → the hard-marker key the real block derives for it
  CLAUDE_PROJECT_DIR="$1" bash -c "$(guard_block "$GUARD")
printf '%s' \"\$GUARD_KEY\""
}
KEY="$(key_for "$REPO")"

# A real soft marker in the repo would mask the "remove hard marker → allowed again" case.
if [ -f "$REPO/.loop-active" ]; then
  echo "SKIP: a real .loop-active is present in $REPO — cannot cleanly test the hard path here."
  exit 0
fi

TG=$(mktemp -d)            # fake guard dir (stands in for /var/run/loop-guard)
trap 'rm -rf "$TG"' EXIT

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
OUT=$(LOOP_GUARD_DIR="$TG" CLAUDE_PROJECT_DIR="$REPO" bash "$STATUS" 2>/dev/null); RC=$?
{ [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^ACTIVE'; } && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: status did not report ACTIVE for a hard lock"; }
rm -f "$TG/$KEY"
OUT=$(LOOP_GUARD_DIR="$TG" CLAUDE_PROJECT_DIR="$REPO" bash "$STATUS" 2>/dev/null); RC=$?
{ [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q '^INACTIVE'; } && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: status did not report INACTIVE with no marker"; }

echo "== G5: one key derivation, shared by all four scripts =="
REF="$(guard_block "$GUARD")"
[ -n "$REF" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: the hook has no guard-key block"; }
for f in "$LOCK" "$UNLOCK" "$STATUS"; do
  [ "$(guard_block "$f")" = "$REF" ] \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: $(basename "$f") guard-key block differs from the hook's"; }
done
if grep -q 'dirname "${BASH_SOURCE\[0\]}")" rev-parse --show-toplevel' "$LOCK" "$UNLOCK" "$STATUS"; then
  FAIL=$((FAIL+1)); echo "  FAIL: a script still keys the lock on its own location"
else PASS=$((PASS+1)); fi

echo "== G5: every worktree of a repo gets the same key; another repo does not =="
WT="$TG/wt"; mkdir -p "$WT"
git -C "$WT" init -q main && git -C "$WT/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$WT/main" worktree add -q "$WT/main/.claude/worktrees/w1" -b w1 2>/dev/null
git -C "$WT/main" worktree add -q "$WT/elsewhere" -b w2 2>/dev/null
mkdir -p "$WT/main/src"
K_MAIN="$(key_for "$WT/main")"
[ "$(key_for "$WT/main/src")" = "$K_MAIN" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: a subdirectory keyed differently from its repo"; }
[ "$(key_for "$WT/main/.claude/worktrees/w1")" = "$K_MAIN" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: a worktree under .claude/worktrees keyed differently from its repo"; }
[ "$(key_for "$WT/elsewhere")" = "$K_MAIN" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: a worktree outside the repo keyed differently from its repo"; }
git -C "$WT" init -q other
[ "$(key_for "$WT/other")" != "$K_MAIN" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: two different repos share a key"; }
[ "$(CLAUDE_PROJECT_DIR="$WT/elsewhere" bash -c "$(guard_block "$GUARD")
printf '%s' \"\$GUARD_MAIN\"")" = "$(cd "$WT/main" && pwd -P)" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: GUARD_MAIN did not resolve a worktree to the main checkout"; }

echo "== G5: a hard lock gates a session running in a worktree =="
: > "$TG/$K_MAIN"
printf '{"tool_name":"Bash","tool_input":{"command":"git push"}}' \
  | LOOP_GUARD_DIR="$TG" CLAUDE_PROJECT_DIR="$WT/elsewhere" bash "$GUARD" 2>/dev/null
[ $? -eq 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: a worktree session was not gated by the repo's hard lock"; }
OUT=$(LOOP_GUARD_DIR="$TG" CLAUDE_PROJECT_DIR="$WT/main/.claude/worktrees/w1" bash "$STATUS" 2>/dev/null)
printf '%s' "$OUT" | grep -q '^ACTIVE' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: status in a worktree did not see the repo's hard lock"; }
OUT=$(LOOP_GUARD_DIR="$TG" CLAUDE_PROJECT_DIR="$WT/main" bash "$STATUS" 2>&1)
printf '%s' "$OUT" | grep -q 'WARNING: these scripts live in' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: status did not warn that its own repo differs from the checked repo"; }
rm -f "$TG/$K_MAIN"

echo "== G5: outside a git repo, the block survives set -e so lock/unlock can say why =="
NG="$TG/notgit"; mkdir -p "$NG"
( cd "$NG" && bash -c "set -euo pipefail
$(guard_block "$LOCK")
printf reached" 2>/dev/null ) | grep -q reached \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: the guard-key block aborts under set -e outside a repo"; }
rmdir "$NG"

echo "== G5: a lock taken under the old key is still honoured =="
LEGACY_KEY="$(printf '%s' "$(git -C "$WT/other" rev-parse --show-toplevel)" | cksum | cut -d' ' -f1)"
: > "$TG/$LEGACY_KEY"
printf '{"tool_name":"Bash","tool_input":{"command":"git push"}}' \
  | LOOP_GUARD_DIR="$TG" CLAUDE_PROJECT_DIR="$WT/other" bash "$GUARD" 2>/dev/null
[ $? -eq 2 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: the hook ignored a lock taken under the old key"; }
OUT=$(LOOP_GUARD_DIR="$TG" CLAUDE_PROJECT_DIR="$WT/other" bash "$STATUS" 2>/dev/null)
printf '%s' "$OUT" | grep -q '^ACTIVE' \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: status ignored a lock taken under the old key"; }
grep -q 'GUARD_LEGACY_KEY' "$UNLOCK" \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: unlock-loop does not clear a lock taken under the old key"; }
rm -f "$TG/$LEGACY_KEY"; rm -rf "$WT"

echo "== G12: lock freezes every worktree's .claude, unlock lifts them all =="
# Runs the REAL lock and unlock scripts. Root-only calls are stubbed: `id -u` reports 0, `install`
# and `chown` succeed, and `chflags` logs its arguments instead of setting flags.
H="$TG/g12"; mkdir -p "$H/bin" "$H/guard"
printf '#!/bin/bash\n[ "$1" = "-u" ] && echo 0 || /usr/bin/id "$@"\n' > "$H/bin/id"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/install"
for t in chflags chown chattr; do printf '#!/bin/bash\necho "%s $*" >> "%s/log"\n' "$t" "$H" > "$H/bin/$t"; done
chmod +x "$H/bin/"*
git -C "$H" init -q repo
mkdir -p "$H/repo/.claude/scripts"; : > "$H/repo/.claude/settings.json"
git -C "$H/repo" add -A && git -C "$H/repo" -c user.email=t@t -c user.name=t commit -qm init
git -C "$H/repo" worktree add -q "$H/repo/.claude/worktrees/w1" -b w1 2>/dev/null
git -C "$H/repo" worktree add -q "$H/w2" -b w2 2>/dev/null
git -C "$H/repo" worktree add -q "$H/w3" -b w3 2>/dev/null; rm -rf "$H/w3/.claude"
( cd "$H/repo" && PATH="$H/bin:$PATH" LOOP_GUARD_DIR="$H/guard" bash "$LOCK" >"$H/out" 2>&1 )
[ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock-loop exited non-zero under stubs"; cat "$H/out"; }
for wt in "repo/.claude/worktrees/w1" "w2"; do
  grep -q "schg .*$wt/.claude/settings.json" "$H/log" \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock did not freeze $wt/.claude"; }
  grep -q "^frozen=.*$wt/.claude\$" "$H"/guard/* \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock did not record $wt/.claude in the marker"; }
done
grep -q "w3 has no .claude" "$H/out" \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock did not report a worktree with no .claude"; }
grep -q "worktrees/w1/src\|schg [^ ]*/repo/.claude/worktrees\$" "$H/log" \
  && { FAIL=$((FAIL+1)); echo "  FAIL: the main freeze reached into .claude/worktrees/"; } || PASS=$((PASS+1))
: > "$H/log"
( cd "$H/w2" && PATH="$H/bin:$PATH" LOOP_GUARD_DIR="$H/guard" bash "$UNLOCK" >"$H/out" 2>&1 )
[ $? -eq 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: unlock-loop exited non-zero under stubs"; cat "$H/out"; }
for wt in "repo" "repo/.claude/worktrees/w1" "w2"; do
  grep -q "noschg .*/$wt/.claude\$" "$H/log" \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: unlock (run from a worktree) did not lift $wt/.claude"; }
done
[ -z "$(ls "$H/guard")" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: unlock left the marker behind"; }

echo "== G12: status warns about a worktree whose .claude is not frozen =="
: > "$H/guard/$(key_for "$H/repo")"
OUT=$(LOOP_GUARD_DIR="$H/guard" CLAUDE_PROJECT_DIR="$H/repo" bash "$STATUS" 2>&1)
printf '%s' "$OUT" | grep -q "worktree .*w2 has an unfrozen .claude" \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: status did not warn about an unfrozen worktree .claude"; }
rm -rf "$H"

echo "== lock/unlock refuse to run without root (so a non-root agent cannot self-lock/unlock) =="
LOOP_GUARD_DIR="$TG" bash "$LOCK"   >/dev/null 2>&1; [ $? -ne 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock-loop ran without root"; }
LOOP_GUARD_DIR="$TG" bash "$UNLOCK" >/dev/null 2>&1; [ $? -ne 0 ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: unlock-loop ran without root"; }

# The hook-config freeze uses schg (macOS) / +i (Linux), which need root to set — so, like the
# root-owned marker, the freeze itself is proven by the sudo smoke test, not here. This suite
# verifies the wiring is present: lock freezes the hook config, unlock lifts it, status reports it.
echo "== the hook-config freeze is wired into lock/unlock/status =="
grep -q 'chflags schg\|chattr +i' "$LOCK"        && grep -q 'freeze_tree "\$CLAUDE_DIR"' "$LOCK"     && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock-loop does not freeze the hook config subtree"; }
grep -q 'chflags -R noschg\|chattr -i' "$UNLOCK" && grep -q 'unfreeze_tree "\$CLAUDE_DIR"' "$UNLOCK" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: unlock-loop does not unfreeze the hook config subtree"; }
grep -q 'unconditionally' "$UNLOCK"              && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: unlock-loop must unfreeze unconditionally (a forgotten lock must not leave the config frozen)"; }
grep -q 'is_frozen' "$STATUS"                    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: loop-status does not report the frozen hook config"; }

# The freeze must cover the whole .claude subtree, not one filename. Freezing only
# .claude/settings.json left two doors open: create .claude/settings.local.json (which also
# accepts disableAllHooks and usually does not exist yet), or edit the hook script itself in
# place. An edit that narrows the freeze back to a single file fails here.
echo "== the freeze targets the subtree, not a single settings file =="
grep -q 'LOOP_CLAUDE_DIR' "$LOCK" && grep -q 'LOOP_CLAUDE_DIR' "$UNLOCK" && grep -q 'LOOP_CLAUDE_DIR' "$STATUS" \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock/unlock/status must agree on CLAUDE_DIR (LOOP_CLAUDE_DIR override)"; }
if grep -lq 'LOOP_SETTINGS' "$LOCK" "$UNLOCK" "$STATUS" 2>/dev/null; then
  FAIL=$((FAIL+1)); echo "  FAIL: a single-file LOOP_SETTINGS target is still wired — the subtree freeze replaced it"
else PASS=$((PASS+1)); fi
grep -q 'settings.local.json' "$LOCK" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock-loop must document why settings.local.json is covered"; }
grep -q 'find "\$d" -depth' "$LOCK"   && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: freeze_tree must set contents before the directory (-depth)"; }

# The kernel semantics the whole design rests on, proven without root by using uchg
# (owner-clearable) in place of schg (root-only). The two flags differ in WHO may clear them, not
# in what they block. This is the case that shows why freezing one file was never enough.
echo "== dir-immutable blocks creation; only file-immutable blocks in-place edit =="
if command -v chflags >/dev/null 2>&1; then
  SEM="$TG/sem"; mkdir -p "$SEM/.claude"; printf '{}\n' > "$SEM/.claude/settings.json"
  chflags uchg "$SEM/.claude" 2>/dev/null
  touch "$SEM/.claude/settings.local.json" 2>/dev/null
  if [ -f "$SEM/.claude/settings.local.json" ]; then
    FAIL=$((FAIL+1)); echo "  FAIL: a new file was created inside an immutable directory"
  else PASS=$((PASS+1)); fi
  # Subshell + stderr redirect: a refused `>` is reported by the SHELL, not by printf, so
  # `printf ... 2>/dev/null >file` still leaks "Operation not permitted". That message is the
  # assertion succeeding, and it must not look like a suite error.
  ( printf '{"disableAllHooks":true}\n' > "$SEM/.claude/settings.json" ) 2>/dev/null
  if grep -q disableAllHooks "$SEM/.claude/settings.json" 2>/dev/null; then
    PASS=$((PASS+1))   # premise holds: a dir-only freeze does NOT stop an in-place edit
  else
    FAIL=$((FAIL+1)); echo "  FAIL: premise wrong — a dir-only freeze was expected to still allow in-place edits"
  fi
  chflags uchg "$SEM/.claude/settings.json" 2>/dev/null
  ( printf '{"clobbered":true}\n' > "$SEM/.claude/settings.json" ) 2>/dev/null
  if grep -q clobbered "$SEM/.claude/settings.json" 2>/dev/null; then
    FAIL=$((FAIL+1)); echo "  FAIL: an immutable file was edited in place"
  else PASS=$((PASS+1)); fi
  chflags -R nouchg "$SEM" 2>/dev/null; rm -rf "$SEM"
else
  echo "  SKIP: no chflags on this platform"
fi

# A symlinked .claude is common: people point it at a synced folder so one set of settings
# follows them between machines. The first subtree freeze walked the link instead of the tree and
# reported success anyway. These assertions fail against that version.
echo "== a symlinked .claude is resolved, not walked as a link =="
grep -q 'CLAUDE_LINK' "$LOCK" && grep -q 'CLAUDE_LINK' "$UNLOCK" && grep -q 'CLAUDE_LINK' "$STATUS" \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock/unlock/status must all resolve a symlinked .claude"; }
grep -q 'chflags -h schg' "$LOCK"    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock-loop must freeze the symlink itself so it cannot be repointed"; }
grep -q 'chflags -h noschg' "$UNLOCK" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: unlock-loop must lift the symlink's own flag"; }
# Warn, never refuse. A symlinked project .claude almost always points outside the repo — that is
# why it is a symlink — so refusing would block the very case the symlink handling exists for, and
# a guard that blocks legitimate work trains the reflex to override it.
grep -q 'WARNING: \$CLAUDE_LINK resolves to' "$LOCK" && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock-loop must warn about an out-of-repo target"; }
if grep -q 'LOOP_ALLOW_EXTERNAL_CLAUDE_DIR' "$LOCK"; then
  FAIL=$((FAIL+1)); echo "  FAIL: the out-of-repo override is back — warn and proceed, do not gate on a flag"
else PASS=$((PASS+1)); fi

# The kernel/find behaviour the bug rested on. If any of these three flip, the resolution code
# above is no longer needed — and if they hold, walking an unresolved link is provably useless.
echo "== find does not descend a symlink, and [ -d ] does not notice =="
SL="$TG/sl"; mkdir -p "$SL/real/scripts"; : > "$SL/real/settings.json"; : > "$SL/real/scripts/hook.sh"
ln -s "$SL/real" "$SL/link"
[ "$(find "$SL/link" -depth | wc -l | tr -d ' ')" = "1" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: premise wrong — find descended a symlink"; }
[ -d "$SL/link" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: premise wrong — [ -d ] rejected a symlinked dir"; }
[ "$(cd "$SL/link" && pwd -P)" = "$(cd "$SL/real" && pwd -P)" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: pwd -P did not resolve the link to its target"; }
rm -rf "$SL"

echo "== the freeze skips .claude/worktrees/ and still covers everything else =="
# G4: freezing worktrees/ made every parallel worktree immutable. Run the real freeze functions
# against a stub chflags/chattr that logs its arguments instead of setting flags, so this needs no root.
FW="$TG/fw"; mkdir -p "$FW/bin" "$FW/.claude/scripts" "$FW/.claude/worktrees/wt1/src" "$FW/.claude/.hidden"
: > "$FW/.claude/settings.json"; : > "$FW/.claude/scripts/hook.sh"; : > "$FW/.claude/worktrees/wt1/src/a.ts"
for tool in chflags chattr; do
  printf '#!/bin/bash\nshift; printf "%%s\\n" "$@" >> "%s/log"\n' "$FW" > "$FW/bin/$tool"; chmod +x "$FW/bin/$tool"
done
PATH="$FW/bin:$PATH" bash -c "$(sed -n '/^freeze()/,/^}/p;/^freeze_subtree()/,/^}/p;/^freeze_tree()/,/^}/p' "$LOCK"); freeze_tree \"$FW/.claude\""
grep -q 'worktrees' "$FW/log" \
  && { FAIL=$((FAIL+1)); echo "  FAIL: the freeze touched .claude/worktrees/"; } || PASS=$((PASS+1))
for f in settings.json scripts/hook.sh scripts .hidden; do
  grep -qx "$FW/.claude/$f" "$FW/log" \
    && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: the freeze skipped .claude/$f"; }
done
[ "$(tail -n1 "$FW/log")" = "$FW/.claude" ] \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: .claude itself must be frozen, and frozen last"; }
grep -q 'mkdir "\$CLAUDE_DIR/worktrees"' "$LOCK" \
  && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); echo "  FAIL: lock-loop must create worktrees/ before freezing .claude"; }
rm -rf "$FW"

echo "== is_frozen reports false for an ordinary (unfrozen) file =="
# Pull is_frozen out of loop-status and exercise its negative case without root.
tmpf="$TG/plainfile"; : > "$tmpf"
if bash -c "$(sed -n '/^is_frozen()/,/^}/p' "$STATUS"); is_frozen \"$tmpf\""; then
  FAIL=$((FAIL+1)); echo "  FAIL: is_frozen reported a plain file as frozen"
else PASS=$((PASS+1)); fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
