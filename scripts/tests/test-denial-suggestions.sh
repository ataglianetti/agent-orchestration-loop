#!/bin/bash
# Denial-suggestion safety suite for scripts/block-human-gated-actions.sh
#
# Run: bash scripts/tests/test-denial-suggestions.sh
# (Invoke via `bash` — the repo is synced to machines that do not preserve the +x bit.)
#
# Why this suite exists, separate from the main guard suite:
#
# A block message that hands the agent an alternative command is itself a surface. If a denial
# ever suggests a command that clears the gate, the guard has politely walked the agent through
# its own bypass. The main suite proves the guard blocks the bad verbs; this suite proves the
# guard's own advice is safe — every command a denial message suggests must either
#   (a) pass the hook AND leave the .loop-active marker in place when actually executed, or
#   (b) be a human-terminal-only override that the hook itself blocks through the agent.
# It must never be a command that passes the hook and removes the marker.
#
# The hook currently suggests exactly two commands in its denial messages:
#   - `git clean -fd`            — an in-agent alternative to `git clean -x/-X` (must be safe)
#   - `rm '<root>/.loop-active>` — the human override, framed "your own terminal, not through
#                                  the agent" (must be blocked when issued through the agent)
# If a future edit adds a new suggestion, the drift check below fails until it is covered here.

GUARD="$(cd "$(dirname "$0")/.." && pwd)/block-human-gated-actions.sh"
HOOK_SRC="$GUARD"
PASS=0
FAIL=0

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/marked"
: > "$TMPROOT/marked/.loop-active"

run_guard() { # $1 = repo root, $2 = command
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$2" | jq -Rs .)" \
    | CLAUDE_PROJECT_DIR="$1" bash "$GUARD" 2>/dev/null
  return $?
}

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# --- A. Behavioral proof: the suggested alternative leaves the marker; the walled variant does not.
# Build a real git repo whose .loop-active is ignored via .git/info/exclude (how the machinery is
# actually kept local, per README), then run the commands for real and inspect the marker.
build_repo() { # $1 = dir
  local d="$1"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  echo ".loop-active" > "$d/.git/info/exclude"
  : > "$d/.loop-active"
  echo "tracked" > "$d/kept.txt"
  git -C "$d" add kept.txt >/dev/null 2>&1
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm base >/dev/null 2>&1
  : > "$d/scratch-untracked.txt"   # an untracked, non-ignored file, so -fd has something to do
}

echo "== the suggested alternative (git clean -fd) must spare the marker =="
build_repo "$TMPROOT/beh"
( cd "$TMPROOT/beh" && git clean -fd >/dev/null 2>&1 )
if [ -f "$TMPROOT/beh/.loop-active" ]; then ok; else
  bad "git clean -fd removed .loop-active — the denial must not suggest it"; fi
if [ ! -f "$TMPROOT/beh/scratch-untracked.txt" ]; then ok; else
  bad "git clean -fd did not remove the untracked file — suite setup is wrong"; fi

echo "== the walled variant (git clean -fdx) really would clear the gate =="
build_repo "$TMPROOT/beh2"
( cd "$TMPROOT/beh2" && git clean -fdx >/dev/null 2>&1 )
if [ ! -f "$TMPROOT/beh2/.loop-active" ]; then ok; else
  bad "git clean -fdx left .loop-active — the premise of walling it is wrong"; fi

echo "== the hook agrees: allow the safe suggestion, block the dangerous variant =="
run_guard "$TMPROOT/marked" 'git clean -fd'
[ $? -eq 0 ] && ok || bad "hook blocked its own suggested alternative 'git clean -fd'"
run_guard "$TMPROOT/marked" 'git clean -fdx'
[ $? -eq 2 ] && ok || bad "hook allowed 'git clean -fdx', which clears the gitignored marker"

echo "== the human override, issued through the agent, must block =="
run_guard "$TMPROOT/marked" "rm '$TMPROOT/marked/.loop-active'"
[ $? -eq 2 ] && ok || bad "hook allowed the 'rm .loop-active' override through the agent"

echo "== the hard-lock override (sudo unlock-loop.sh), issued through the agent, must block =="
run_guard "$TMPROOT/marked" "sudo ./.claude/scripts/unlock-loop.sh"
[ $? -eq 2 ] && ok || bad "hook allowed the 'sudo unlock-loop.sh' override through the agent"

# --- B. Drift guard: the hook's denials must never suggest a gate-clearing command.
echo "== no denial message suggests a marker-clearing command =="
# Pull the text of every deny() call argument (the reason strings shown to the agent).
DENY_TEXT=$(grep -nE 'deny "|OVERRIDE=|REASON=' "$HOOK_SRC")

# B1. No suggested `git clean` may carry -x/-X (that reaches ignored files → clears the marker).
if printf '%s' "$DENY_TEXT" | grep -Eq "git clean[^\"']*[xX]"; then
  bad "a denial message suggests a 'git clean' variant with x/X — that hands over the bypass"
else ok; fi

# B2. The safe in-agent alternative that IS suggested must be exactly 'git clean -fd'.
if printf '%s' "$DENY_TEXT" | grep -Fq 'git clean -fd'; then ok; else
  bad "the 'git clean -fd' suggestion changed or vanished — recheck it is still gate-safe and covered"; fi

# B3. The only rm the denials suggest is the .loop-active override (which the hook blocks in-agent,
#     tested above). Fail if a denial suggests rm-ing anything else, which would be untested advice.
# Anchor on a word boundary before rm and a real target after it (quote, path, or flag), so
# prose like "perform them" is not read as an `rm` suggestion.
STRAY_RM=$(printf '%s' "$DENY_TEXT" | grep -oE "[^[:alnum:]]rm ['/-][^\"']*" | grep -v '\.loop-active' || true)
if [ -z "$STRAY_RM" ]; then ok; else
  bad "a denial suggests an rm other than the .loop-active override: $STRAY_RM"; fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
