# loop-gate.zsh — clear the loop's run marker from your own terminal.
#
# Source it from your shell rc (zsh or bash), pointing at wherever install.sh
# put it:
#
#   source "/path/to/your/repo/.claude/scripts/loop-gate.zsh"
#
# Then, from anywhere inside the repo:
#
#   ungate
#
#
# WHY THIS IS A SHELL FUNCTION AND NOT SOMETHING THE AGENT CAN RUN
# ----------------------------------------------------------------
# block-human-gated-actions.sh is a PreToolUse hook on the Bash tool. It sees
# only commands issued through an agent session, and while .loop-active exists
# it blocks two classes of command: shipping (gh pr create/merge, git push) and
# removing the marker itself.
#
# That second block is the point. The marker is the wall. If the loop could
# delete it, a run that decided to ship could clear its own gate first — the
# same reasoning that produces a self-approved PR. A gate the gated party can
# remove is not a gate.
#
# So clearing the gate is deliberately the one act that has to happen outside
# the thing being gated. Asking the agent to run `ungate` for you will be
# blocked, and should be. Run it in your terminal.
#
# Nothing here writes to your shell config; sourcing it is your call.

ungate() {
  local root marker
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  marker="$root/.loop-active"

  if [ -f "$marker" ]; then
    rm -f "$marker" && printf 'gate cleared  %s\n' "$marker"
  else
    printf 'no marker     %s — already clear\n' "$marker"
  fi
}
