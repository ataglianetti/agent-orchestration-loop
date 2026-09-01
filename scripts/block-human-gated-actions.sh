#!/bin/bash
# PreToolUse(Bash) guard for the orchestrate loop.
#
# While a workstream loop is active (a `.loop-active` marker at the repo root), block:
#   1. the outward-facing, human-gated actions the loop must never perform on its own —
#      opening/merging PRs and pushing; and
#   2. removal of the marker itself.
#
# Why (2) matters: the marker IS the wall. If the agent can delete it, the wall is a
# suggestion — a run that decided to ship could clear the gate first and then ship, which is
# the same reasoning that produced the original self-approved PR. Any state the agent is
# allowed to remove cannot gate the agent. So the marker is human-only: the loop writes it at
# run start and NEVER removes it. It is cleared by the human, or overwritten by the next run.
#
# Manual override (you are the human, acting deliberately): run `rm .loop-active` in your OWN
# terminal. This hook only ever sees commands issued through the agent's Bash tool, so a human
# clearing the gate outside the agent is never blocked by it. That asymmetry is the point —
# clearing the gate is the one act that has to happen outside the thing being gated.
#
# Reads hook JSON from stdin (tool_input.command). Allows everything when no marker is present.
#
# Blocks by exiting 2, not by returning a JSON permissionDecision. Per the permissions docs, a
# hook that exits 2 "stops the tool call before permission rules are evaluated, so the block
# applies even when an allow rule would otherwise let the call proceed." A JSON
# `permissionDecision: "deny"` carries no such documented guarantee against a standing allow
# rule (e.g. `Bash(git push:*)`), so exit 2 is the only form of this guard that holds.
#
# Fails open on any internal hiccup — the prose gate in orchestrate.md still applies.

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -z "$CMD" ] && exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$ROOT/.loop-active" ] || exit 0   # no active loop → no restriction

deny() {
  printf '%s\n' "$1" >&2
  exit 2
}

OVERRIDE="If you are the human acting deliberately, clear the gate from your own terminal (not through the agent): rm '$ROOT/.loop-active'"

# 1. Human-gated, outward-facing actions the loop must never take on its own.
#    Covers the gh porcelain, the raw API path to the same endpoints, and push.
SHIP_RE='(gh[[:space:]]+pr[[:space:]]+(create|merge|ready))'
SHIP_RE="$SHIP_RE"'|(gh[[:space:]]+pr[[:space:]]+review[^|]*--approve)'
SHIP_RE="$SHIP_RE"'|(git[[:space:]]+((-C|-c)[[:space:]]+[^[:space:]]+[[:space:]]+)*push([^[:alnum:]_]|$))'
SHIP_RE="$SHIP_RE"'|(gh[[:space:]]+api[^|]*(pulls|/merge)[^|]*(-X|--method)[[:space:]]*(POST|PUT|PATCH))'
SHIP_RE="$SHIP_RE"'|(gh[[:space:]]+api[^|]*(-X|--method)[[:space:]]*(POST|PUT|PATCH)[^|]*(pulls|/merge))'

if printf '%s' "$CMD" | grep -Eq "$SHIP_RE"; then
  deny "Blocked by the orchestrate loop guard: a workstream loop is active (.loop-active present). Opening/merging PRs and pushing are human-gated — the loop must never perform them on its own (it self-approved a PR once; this guard is why it cannot again). Write the approval card and stop instead. $OVERRIDE"
fi

# 2. The marker is human-only. Removing or renaming it is the escape hatch, so it is walled
#    the same way shipping is. Truncating it is not blocked — an empty marker file still
#    exists, so the gate still holds.
if printf '%s' "$CMD" | grep -Fq '.loop-active'; then
  if printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_.-])(rm|unlink|shred|mv)([[:space:]]|$)' \
    || printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_-])-delete([[:space:]]|$)'; then
    deny "Blocked by the orchestrate loop guard: the .loop-active marker is human-only. The loop writes it at run start and never removes it — if the loop could clear its own gate, the gate would not be a gate. Reach a hard stop (clean exit, FLAG-HUMAN, or non-convergence), write the approval card, and end the run with the marker in place. $OVERRIDE"
  fi
fi

# 3. `git clean` with -x/-X reaches ignored files, and the marker is gitignored — so this is
#    marker removal by another name.
if printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+((-C|-c)[[:space:]]+[^[:space:]]+[[:space:]]+)*clean([[:space:]]+-[^[:space:]]*[xX])'; then
  deny "Blocked by the orchestrate loop guard: 'git clean' with -x/-X removes ignored files, and .loop-active is gitignored — that clears the human gate. Use 'git clean -fd' (which leaves ignored files alone) if you need to clean the tree mid-run. $OVERRIDE"
fi

exit 0
