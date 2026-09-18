#!/usr/bin/env bash
set -euo pipefail

# Install the agent orchestration loop into a target repo.
# Usage: ./install.sh /path/to/target-repo

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"

if [ -z "$TARGET" ] || [ ! -d "$TARGET" ]; then
  echo "Usage: $0 /path/to/target-repo"
  exit 1
fi
TARGET="$(cd "$TARGET" && pwd)"
echo "Installing agent-orchestration-loop into $TARGET"

# 1. directories
mkdir -p "$TARGET/.claude/commands" "$TARGET/.claude/agents" "$TARGET/.claude/scripts" \
         "$TARGET/docs/execution/templates" "$TARGET/docs/execution/active" "$TARGET/docs/execution/done"

# 2. commands + planner agent
cp "$KIT_DIR/commands/orchestrate.md" "$TARGET/.claude/commands/orchestrate.md"
cp "$KIT_DIR/commands/dogfood.md"     "$TARGET/.claude/commands/dogfood.md"
cp "$KIT_DIR/agents/planner.md"       "$TARGET/.claude/agents/planner.md"

# 3. scripts: workstream init + the human-gate guard + the human's gate-clearing helper
cp "$KIT_DIR/scripts/init-workstream.sh"           "$TARGET/.claude/scripts/init-workstream.sh"
cp "$KIT_DIR/scripts/block-human-gated-actions.sh" "$TARGET/.claude/scripts/block-human-gated-actions.sh"
# Placed, never wired: sourcing loop-gate.zsh into your shell rc is your call, not the installer's.
cp "$KIT_DIR/scripts/loop-gate.zsh"                "$TARGET/.claude/scripts/loop-gate.zsh"
# Opt-in hard gate: a root-owned marker the agent's user cannot remove. lock/unlock need sudo;
# status is read-only. See README "The marker the gate reads".
cp "$KIT_DIR/scripts/lock-loop.sh"                 "$TARGET/.claude/scripts/lock-loop.sh"
cp "$KIT_DIR/scripts/unlock-loop.sh"               "$TARGET/.claude/scripts/unlock-loop.sh"
cp "$KIT_DIR/scripts/loop-status.sh"               "$TARGET/.claude/scripts/loop-status.sh"

# 4. execution spine
cp "$KIT_DIR/execution/REVIEW_CONTRACT.md" "$TARGET/docs/execution/REVIEW_CONTRACT.md"
cp "$KIT_DIR"/execution/templates/*.md     "$TARGET/docs/execution/templates/"
# Don't clobber an existing (repo-specialized) guide.
if [ ! -f "$TARGET/docs/execution/CLAUDE_ORCHESTRATION_GUIDE.md" ]; then
  cp "$KIT_DIR/execution/ORCHESTRATION_GUIDE.md" "$TARGET/docs/execution/CLAUDE_ORCHESTRATION_GUIDE.md"
  echo "  • guide installed — specialize §1 / §5 / §6 / §7 for this repo"
else
  echo "  • guide already exists — left as-is"
fi

# 5. .gitignore: ensure the run marker is ignored
GI="$TARGET/.gitignore"
if ! grep -qxF ".loop-active" "$GI" 2>/dev/null; then
  printf '\n# agent orchestration loop run marker\n.loop-active\n' >> "$GI"
fi

# 6. settings.json: wire the PreToolUse(Bash) guard hook (merge, never clobber)
SETTINGS="$TARGET/.claude/settings.json"
HOOK_CMD='bash "$CLAUDE_PROJECT_DIR/.claude/scripts/block-human-gated-actions.sh"'
if [ ! -f "$SETTINGS" ]; then
  cat > "$SETTINGS" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/block-human-gated-actions.sh\"" }
      ] }
    ]
  }
}
JSON
  echo "  • settings.json created with the guard hook"
elif grep -q "block-human-gated-actions.sh" "$SETTINGS"; then
  echo "  • guard hook already wired in settings.json"
elif command -v jq >/dev/null 2>&1; then
  TMP="$(mktemp)"
  jq --arg cmd "$HOOK_CMD" '
    .hooks //= {} |
    .hooks.PreToolUse //= [] |
    (.hooks.PreToolUse | map(.matcher) | index("Bash")) as $i |
    if $i == null
    then .hooks.PreToolUse += [ { matcher: "Bash", hooks: [ { type: "command", command: $cmd } ] } ]
    else .hooks.PreToolUse[$i].hooks += [ { type: "command", command: $cmd } ]
    end
  ' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
  echo "  • guard hook merged into settings.json"
else
  echo "  ⚠ settings.json exists but jq is unavailable — add this PreToolUse(Bash) hook by hand:"
  echo "      command: $HOOK_CMD"
fi

# 7. preflight: the review stage calls skills this kit does not ship
# §2c of orchestrate.md spawns these by name. They ride along with Claude Code
# on most builds, in which case nothing is on disk to find — so this NEVER fails
# the install, it only tells you what could not be seen.
REVIEW_SKILLS="code-review adversarial-reviewer run"
PLUGIN_LIST=""
command -v claude >/dev/null 2>&1 && PLUGIN_LIST="$(claude plugin list 2>/dev/null || true)"

undetected=""
for skill in $REVIEW_SKILLS; do
  found=""
  for dir in "$HOME/.claude/skills/$skill" "$TARGET/.claude/skills/$skill"; do
    [ -f "$dir/SKILL.md" ] && found=1
  done
  [ -z "$found" ] && [ -d "$HOME/.claude/plugins/marketplaces" ] &&
    find "$HOME/.claude/plugins/marketplaces" -maxdepth 4 -type d -name "$skill" 2>/dev/null |
    grep -q . && found=1
  [ -z "$found" ] && printf '%s' "$PLUGIN_LIST" | grep -q "$skill" && found=1
  [ -z "$found" ] && undetected="$undetected $skill"
done

echo
if [ -z "$undetected" ]; then
  echo "Review skills: all found on disk ($REVIEW_SKILLS)"
else
  echo "Review skills not found on disk:$undetected"
  echo "  These ship bundled with many Claude Code builds, so this is often a false alarm."
  echo "  Confirm in a session at the repo: /plugin  (or just type / and look for them)"
  echo "  If they are genuinely absent, /orchestrate plans and executes but stalls at"
  echo "  step 2c — swap the missing pass for one you do have, or drop review depth a tier."
fi

echo
echo "Done. In a Claude Code session rooted at the repo, run:  /orchestrate <workstream-id>"
