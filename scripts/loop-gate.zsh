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

# A loop running in a git worktree writes its marker at THAT worktree's root, not the main
# checkout's. So ungate looks across every checkout of the repo:
#
#   ungate          clears the marker in the checkout you are in. If there is none here and
#                   exactly one other checkout has one, clears that. If several do, lists
#                   them and clears nothing — each marker gates a different run.
#   ungate --all    clears the marker in every checkout of the repo.
#
# Soft markers only. A hard lock needs:  sudo ./.claude/scripts/unlock-loop.sh
_ungate_rm() { rm -f "$1" && printf 'gate cleared  %s\n' "$1"; }

ungate() {
  local root here checkouts markers others n c m
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  here="$root/.loop-active"
  checkouts=$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
  [ -n "$checkouts" ] || checkouts="$root"
  markers=$(while IFS= read -r c; do
    [ -f "$c/.loop-active" ] && printf '%s\n' "$c/.loop-active"
  done <<< "$checkouts")

  if [ "${1:-}" = "--all" ]; then
    [ -n "$markers" ] || { printf 'no markers in any checkout — already clear\n'; return 0; }
    while IFS= read -r m; do _ungate_rm "$m"; done <<< "$markers"
    return 0
  fi

  if [ -f "$here" ]; then
    _ungate_rm "$here"
    others=$(while IFS= read -r m; do
      [ -f "$m" ] && printf '%s\n' "$m"   # the one just cleared no longer exists
    done <<< "$markers")
    if [ -n "$others" ]; then
      while IFS= read -r m; do printf 'still gated   %s\n' "$m"; done <<< "$others"
      printf '(ungate --all clears every checkout)\n'
    fi
    return 0
  fi

  n=$(printf '%s' "$markers" | grep -c .)
  case "$n" in
    0) printf 'no marker     in any checkout of this repo — already clear\n' ;;
    1) _ungate_rm "$markers" ;;
    *) printf 'several runs are gated; nothing cleared:\n'
       while IFS= read -r m; do printf '  %s\n' "$m"; done <<< "$markers"
       printf 'run ungate inside the checkout you mean, or ungate --all\n' ;;
  esac
}
