#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <workstream-id>"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKSTREAM_ID="$1"
BASE_DIR="$ROOT_DIR/docs/execution/active/$WORKSTREAM_ID"
TEMPLATE_DIR="$ROOT_DIR/docs/execution/templates"

if [ -d "$BASE_DIR" ]; then
  echo "Workstream already exists: $BASE_DIR"
  exit 1
fi

mkdir -p "$BASE_DIR/SUBAGENTS"

cp "$TEMPLATE_DIR/WORKBOARD.template.md" "$BASE_DIR/WORKBOARD.md"
cp "$TEMPLATE_DIR/ACCEPTANCE_CRITERIA.template.md" "$BASE_DIR/ACCEPTANCE_CRITERIA.md"
cp "$TEMPLATE_DIR/TEST_PLAN.template.md" "$BASE_DIR/TEST_PLAN.md"
cp "$TEMPLATE_DIR/TEST_RESULTS.template.md" "$BASE_DIR/TEST_RESULTS.md"
cp "$TEMPLATE_DIR/DECISIONS.template.md" "$BASE_DIR/DECISIONS.md"
cp "$TEMPLATE_DIR/RISKS_AND_BLOCKERS.template.md" "$BASE_DIR/RISKS_AND_BLOCKERS.md"
cp "$TEMPLATE_DIR/RUN_LOG.template.md" "$BASE_DIR/RUN_LOG.md"
cp "$TEMPLATE_DIR/REVIEW.template.md" "$BASE_DIR/REVIEW.md"
cp "$TEMPLATE_DIR/SUBAGENT_TASK.template.md" "$BASE_DIR/SUBAGENTS/T-000.template.md"

cat > "$BASE_DIR/README.md" <<README
# $WORKSTREAM_ID

## Purpose

- Define objective and business outcome.

## Files

- [WORKBOARD](./WORKBOARD.md)
- [ACCEPTANCE_CRITERIA](./ACCEPTANCE_CRITERIA.md)
- [TEST_PLAN](./TEST_PLAN.md)
- [TEST_RESULTS](./TEST_RESULTS.md)
- [DECISIONS](./DECISIONS.md)
- [RISKS_AND_BLOCKERS](./RISKS_AND_BLOCKERS.md)
- [RUN_LOG](./RUN_LOG.md)
- [REVIEW](./REVIEW.md)
- [SUBAGENTS](./SUBAGENTS/)

## Loop Config

<!-- Read by /orchestrate. round_cap = max rounds before a non-convergence stop. -->

- round_cap: 5
- posture: aggressive
- escalate_to_engineer: off
README

echo "Created workstream scaffold: $BASE_DIR"
