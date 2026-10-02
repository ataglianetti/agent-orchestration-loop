#!/usr/bin/env bash
# Close a workstream: move it from docs/execution/active/<id>/ to docs/execution/done/<id>/
# and write its cost record (COST.html + cost.json) into the folder it lands in.
#
# Usage: ./.claude/scripts/close-workstream.sh <workstream-id> [--no-cost]
#
# This is the PM's step, run after approving and merging. orchestrate.md never runs it: moving
# a workstream to done/ is human-only. The cost record prices the sessions listed in
# SESSIONS.log (written by the record-workstream-session hook) at live Claude API list prices,
# so run it soon after the work ends: Claude Code can delete old session transcripts.
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
    echo "To (re)write its cost record: python3 \"$COST\" record --repo \"$ROOT_DIR\" --workstream \"$DST\""
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
if [ ! -f "$DST/SESSIONS.log" ]; then
  echo "No SESSIONS.log, so no cost record: this workstream predates the session hook, or the hook isn't wired."
  echo "Price it by hand with: python3 \"$COST\" find --repo \"$ROOT_DIR\" --text $ID   (then: analyze)"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1 || [ ! -f "$COST" ]; then
  echo "Cost record skipped: python3 or $COST is missing. Retry with: $retry"
  exit 0
fi
if ! python3 "$COST" record --repo "$ROOT_DIR" --workstream "$DST"; then
  echo "Cost record failed (the workstream is still closed). Retry with: $retry"
fi
