#!/usr/bin/env bash
# Close a workstream: move it from docs/execution/active/<id>/ to docs/execution/done/<id>/
# and write its run record into the folder it lands in.
#
# Usage: ./.claude/scripts/close-workstream.sh <workstream-id> [--no-cost]
#
# This is the PM's step, run after approving and merging. orchestrate.md never runs it: moving
# a workstream to done/ is human-only. The run record covers the sessions the
# record-workstream-session hook logged in .git/loop-sessions/<id>.log, including ones that ran in
# a worktree:
#   - always: a "## Run record" section in the README, with time and tokens and no dollars
#   - with a plan price set (Loop Config plan_price, or $WORKSTREAM_PLAN_PRICE): also COST.html
#     and cost.json, pricing those tokens at live Claude API list prices against the plan
# Run it soon after the work ends: Claude Code can delete old session transcripts.
#
# If the cost step fails, the move still stands and the script prints the command to retry.
set -euo pipefail

ID="${1:-}"
NO_COST="${2:-}"
if [ -z "$ID" ] || { [ -n "$NO_COST" ] && [ "$NO_COST" != "--no-cost" ]; }; then
  echo "Usage: $0 <workstream-id> [--no-cost]"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT_DIR/docs/execution/active/$ID"
DST="$ROOT_DIR/docs/execution/done/$ID"
COST="$ROOT_DIR/.claude/scripts/workstream-cost/workstream_cost.py"

if [ ! -d "$SRC" ]; then
  if [ -d "$DST" ]; then
    echo "Already closed: $DST"
    echo "To (re)write its run record: python3 \"$COST\" record --repo \"$ROOT_DIR\" --workstream \"$DST\""
  else
    echo "No workstream at $SRC"
  fi
  exit 1
fi
if [ -e "$DST" ]; then
  echo "Refusing to overwrite $DST — move or rename it first."
  exit 1
fi

mkdir -p "$ROOT_DIR/docs/execution/done"
mv "$SRC" "$DST"
echo "Closed: docs/execution/done/$ID"

if [ -f "$ROOT_DIR/.loop-active" ]; then
  echo "Note: the run marker is still up. Clear it when you're done: rm .loop-active"
fi

[ "$NO_COST" = "--no-cost" ] && exit 0

retry="python3 \"$COST\" record --repo \"$ROOT_DIR\" --workstream \"$DST\""
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$COST" ]; then
  echo "Run record skipped: python3 or $COST is missing. Retry with: $retry"
  exit 0
fi
rc=0
python3 "$COST" record --repo "$ROOT_DIR" --workstream "$DST" || rc=$?
if [ "$rc" -eq 3 ]; then  # no recorded sessions: the workstream predates the hook, or it isn't wired
  echo "No run record written. Find its sessions by hand with: python3 \"$COST\" find --repo \"$ROOT_DIR\" --text $ID   (then: analyze)"
elif [ "$rc" -ne 0 ]; then
  echo "Run record failed (the workstream is still closed). Retry with: $retry"
fi
exit 0
