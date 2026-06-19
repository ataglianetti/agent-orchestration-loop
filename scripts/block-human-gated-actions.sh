#!/bin/bash
# PreToolUse(Bash) guard for the orchestrate loop.
#
# While a workstream loop is active (a `.loop-active` marker at the repo root), block the
# outward-facing, human-gated actions the loop must never perform on its own: opening or
# merging PRs and pushing. The loop writes the marker at run start and removes it at its
# hard stop, so the human — who has no marker present — is never blocked.
#
# Manual override (you are the human, acting deliberately): rm .loop-active
#
# Reads hook JSON from stdin (tool_input.command). Allows everything when no marker is
# present. Fails open on any internal hiccup — the prose gate in orchestrate.md still applies.

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$CMD" ] && exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ROOT/.loop-active" ] || exit 0   # no active loop → no restriction

# Human-gated, outward-facing actions the loop must never take on its own.
if printf '%s' "$CMD" | grep -Eq '(gh[[:space:]]+pr[[:space:]]+(create|merge|ready))|(gh[[:space:]]+pr[[:space:]]+review[^|]*--approve)|(git[[:space:]]+((-C|-c)[[:space:]]+[^[:space:]]+[[:space:]]+)*push([^[:alnum:]_]|$))'; then
  REASON="Blocked by the orchestrate loop guard: a workstream loop is active (.loop-active present). Opening/merging PRs and pushing are human-gated — the loop must never perform them on its own (it self-approved a PR once; this guard makes that impossible). If you are the human acting deliberately, clear the gate first: rm '$ROOT/.loop-active'"
  jq -n --arg r "$REASON" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' 2>/dev/null
  exit 0
fi
exit 0
