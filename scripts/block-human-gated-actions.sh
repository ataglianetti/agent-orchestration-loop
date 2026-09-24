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

# The gate is active if EITHER marker is present:
#   - soft: `$ROOT/.loop-active`, written by the loop itself (default, zero-friction runs). The
#     agent can write it, so the agent can in principle remove it — sections 2/3 below wall the
#     known removal paths, but a soft marker is only ever as strong as that list of paths.
#   - hard: a root-owned file under $LOOP_GUARD_DIR, dropped by `sudo lock-loop.sh` for a run you
#     want categorically gated. It lives outside the repo in a directory the agent's user cannot
#     write to, so NO command the agent runs — string-matched or not — can remove it. Only
#     `sudo unlock-loop.sh` clears it. LOOP_GUARD_DIR is overridable so the suite can test the
#     hard path without root.
LOOP_GUARD_DIR="${LOOP_GUARD_DIR:-/var/run/loop-guard}"
# >>> guard key: keep this block byte-identical in block-human-gated-actions.sh, lock-loop.sh,
# unlock-loop.sh and loop-status.sh. The test suite compares the four copies.
# The hard marker is keyed on the repo's SHARED git directory (--git-common-dir), resolved from the
# project dir, else the current directory. Every worktree of a repo shares that directory, so one
# lock covers them all, and the key does not depend on where these scripts happen to live — a
# symlinked .claude pointing into another repo no longer changes it. safe.directory='*' because
# lock and unlock run git as root inside a repo the human owns; command-line config is honoured.
KEY_BASE="${CLAUDE_PROJECT_DIR:-$PWD}"
GUARD_REPO="$(cd "$KEY_BASE" 2>/dev/null && d="$(git -c safe.directory='*' rev-parse --git-common-dir 2>/dev/null)" && cd "$d" 2>/dev/null && pwd -P || true)"
GUARD_MAIN="$(git -c safe.directory='*' -C "$KEY_BASE" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p' || true)"
GUARD_KEY="$(printf '%s' "$GUARD_REPO" | cksum | cut -d' ' -f1)"
# Before this key existed, the marker was keyed on a checkout's root. Honour and clear that key
# too, so a lock taken before the upgrade is neither ignored nor left behind.
GUARD_LEGACY_KEY="$(printf '%s' "$(git -c safe.directory='*' -C "$KEY_BASE" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$KEY_BASE")" | cksum | cut -d' ' -f1)"
# <<< guard key
[ -n "$GUARD_REPO" ] || GUARD_REPO="$ROOT"   # not a git repo: key on the project dir itself
HARD_MARKER="$LOOP_GUARD_DIR/$(printf '%s' "$GUARD_REPO" | cksum | cut -d' ' -f1)"
LEGACY_MARKER="$LOOP_GUARD_DIR/$GUARD_LEGACY_KEY"
[ -f "$ROOT/.loop-active" ] || [ -f "$HARD_MARKER" ] || [ -f "$LEGACY_MARKER" ] || exit 0   # no active loop → no restriction

deny() {
  printf '%s\n' "$1" >&2
  exit 2
}

OVERRIDE="If you are the human acting deliberately, clear the gate from your own terminal (not through the agent): rm '$ROOT/.loop-active'"

# 1. Human-gated, outward-facing actions the loop must never take on its own.
#    This is text matching, so it is a strong filter, not a wall: a command whose words are built
#    at runtime (a variable holding "push", a base64 blob piped to sh) will pass it. The backstop
#    that does not depend on matching text is branch protection on the remote — see README.
SHIP_MSG="Blocked by the orchestrate loop guard: a workstream loop is active (.loop-active present). Opening/merging PRs and pushing are human-gated — the loop must never perform them on its own (it self-approved a PR once; this guard is why it cannot again). Write the approval card and stop instead. $OVERRIDE"

# git global options that can sit between `git` and the subcommand. The ones that take a
# separate argument are listed; every other option is a single `-x` / `--x` / `--x=y` token.
GIT_OPTS='([[:space:]]+(-[Cc][[:space:]]+[^[:space:]]+|--(git-dir|work-tree|namespace|super-prefix|config-env|exec-path)[[:space:]]+[^[:space:]]+|-[^[:space:]]+))*'
PUSH_VERBS='(push|send-pack|http-push|subtree[[:space:]]+push)'

# 1a. gh porcelain. `gh repo sync` writes to a remote branch, so it is a push by another name.
SHIP_RE='(gh[[:space:]]+pr[[:space:]]+(create|merge|ready))'
SHIP_RE="$SHIP_RE"'|(gh[[:space:]]+pr[[:space:]]+review[^|]*(--approve|[[:space:]]-a([[:space:]]|$)))'
SHIP_RE="$SHIP_RE"'|(gh[[:space:]]+repo[[:space:]]+sync)'
# 1b. git push, with any global options in front of it (`git --no-pager push`, `git -c x=y push`).
SHIP_RE="$SHIP_RE"'|(git'"$GIT_OPTS"'[[:space:]]+'"$PUSH_VERBS"'([^[:alnum:]_]|$))'

if printf '%s' "$CMD" | grep -Eq "$SHIP_RE"; then
  deny "$SHIP_MSG"
fi

# 1c. git aliases. `git -c alias.p=push p`, `git config alias.p push`, and GIT_CONFIG_KEY_n=alias.p
#     all put the words "alias." and "push" in the same command. A command that mentions both is
#     blocked, which also stops the agent defining a push alias for a later command to use.
if printf '%s' "$CMD" | grep -Eq 'alias\.' \
  && printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_-])'"$PUSH_VERBS"'([^[:alnum:]_-]|$)'; then
  deny "$SHIP_MSG"
fi
#     An alias that already exists in git config (defined before the run, or with its value built
#     at runtime) never shows "push" in the command. Resolve the configured aliases and block any
#     whose value pushes.
PUSH_ALIASES=$(git -C "$ROOT" config --get-regexp '^alias\.' 2>/dev/null \
  | awk '{ n = $1; sub(/^alias\./, "", n); $1 = ""; print n "\t" $0 }' \
  | grep -E $'\t''.*(^|[^[:alnum:]_-])'"$PUSH_VERBS"'([^[:alnum:]_-]|$)' \
  | cut -f1 | grep -E '^[A-Za-z0-9_-]+$' | paste -sd'|' -)
if [ -n "$PUSH_ALIASES" ] \
  && printf '%s' "$CMD" | grep -Eq 'git'"$GIT_OPTS"'[[:space:]]+('"$PUSH_ALIASES"')([^[:alnum:]_-]|$)'; then
  deny "$SHIP_MSG"
fi

#     gh has aliases too (`gh alias set pc 'pr create'`, then `gh pc`). Defining one mid-run is
#     blocked outright; existing ones are resolved and blocked when they expand to a ship command,
#     to `api` (whose arguments follow the alias, out of sight of 1d), or to a shell expression.
if printf '%s' "$CMD" | grep -Eq 'gh[[:space:]]+alias[[:space:]]+(set|import)'; then
  deny "Blocked by the orchestrate loop guard: defining a gh alias while a loop is active can hide a PR or push command from this guard. $OVERRIDE"
fi
GH_SHIP_ALIASES=$(gh alias list 2>/dev/null \
  | grep -E '^[A-Za-z0-9_-]+:[[:space:]]*(!|api([[:space:]]|$)|pr[[:space:]]+(create|merge|ready|review)|repo[[:space:]]+sync|.*(^|[^[:alnum:]_-])'"$PUSH_VERBS"'([^[:alnum:]_-]|$))' \
  | cut -d: -f1 | paste -sd'|' -)
if [ -n "$GH_SHIP_ALIASES" ] \
  && printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_-])gh[[:space:]]+('"$GH_SHIP_ALIASES"')([^[:alnum:]_-]|$)'; then
  deny "$SHIP_MSG"
fi

# 1d. The raw API path to the same endpoints. Checked per command segment, so a `-f` in one
#     command and a `pulls` in the next do not combine. A write is an explicit POST/PUT/PATCH, or
#     a field flag with no explicit GET — gh api sends a POST whenever fields are given.
#     Endpoints: pulls (open, review, merge), merges (branch merge), git/refs (a push by API),
#     contents (a commit by API), branch protection and rulesets, and the GraphQL equivalents.
#     Branch protection is the backstop for everything this guard misses, so switching it off is
#     the first step of shipping around it: the loop runs on the human's token, which is an admin.
API_TARGET='(pulls|/merges?([^[:alnum:]_]|$)|git/refs|/contents/|branches/[^[:space:]]*/protection|rulesets)'
GQL_WRITE='(createPullRequest|mergePullRequest|markPullRequestReadyForReview|enablePullRequestAutoMerge|addPullRequestReview|submitPullRequestReview|createRef|updateRef|deleteRef|createCommitOnBranch|mergeBranch|(create|update|delete)BranchProtectionRule|(create|update|delete)RepositoryRuleset)'
while IFS= read -r SEG; do
  printf '%s' "$SEG" | grep -Eq 'gh[[:space:]]+api([[:space:]]|$)' || continue
  if printf '%s' "$SEG" | grep -Eq "$GQL_WRITE"; then deny "$SHIP_MSG"; fi
  # A GraphQL query read from a file (`-F query=@m.graphql`, `--input`) hides the mutation name.
  if printf '%s' "$SEG" | grep -Eq 'graphql' \
    && printf '%s' "$SEG" | grep -Eq '=@|--input'; then deny "$SHIP_MSG"; fi
  printf '%s' "$SEG" | grep -Eq "$API_TARGET" || continue
  if printf '%s' "$SEG" | grep -Eiq '(-X|--method)[[:space:]=]*(POST|PUT|PATCH|DELETE)'; then deny "$SHIP_MSG"; fi
  if printf '%s' "$SEG" | grep -Eq '[[:space:]](-[fF]|--field|--raw-field|--input)([[:space:]=]|$)' \
    && ! printf '%s' "$SEG" | grep -Eiq '(-X|--method)[[:space:]=]*GET'; then
    deny "$SHIP_MSG"
  fi
done <<EOF
$(printf '%s' "$CMD" | tr ';|&' '\n\n\n')
EOF

# 1e. Authenticated raw HTTP to the GitHub API (curl, wget, a Python or Node one-liner) and
#     extracting the token that would make it work. An unauthenticated call cannot write, so the
#     token is the part worth walling. Reads go through `gh api`, which 1d already filters.
if printf '%s' "$CMD" | grep -Eiq '(api|uploads)\.github\.com' \
  && printf '%s' "$CMD" | grep -Eiq 'authorization|token|bearer|[[:space:]](-u|--user|-n|--netrc)([[:space:]=]|$)'; then
  deny "Blocked by the orchestrate loop guard: authenticated raw HTTP to the GitHub API can open, approve or merge a PR and push, which are human-gated while a loop is active. Use 'gh api' for reads. $OVERRIDE"
fi
if printf '%s' "$CMD" | grep -Eq 'gh[[:space:]]+auth[[:space:]]+(token|status[^|]*--show-token)|git'"$GIT_OPTS"'[[:space:]]+credential([[:space:]]+fill|-[[:alnum:]]+[[:space:]]+get)|security[[:space:]]+find-(internet|generic)-password[^|]*github'; then
  deny "Blocked by the orchestrate loop guard: reading the GitHub token while a loop is active is the first step of shipping around the guard. The loop does not need the raw token; gh and git use it on their own. $OVERRIDE"
fi

# 2. The marker is human-only. Removing or renaming it is the escape hatch, so it is walled
#    the same way shipping is. Truncating it is not blocked — an empty marker file still
#    exists, so the gate still holds.
if printf '%s' "$CMD" | grep -Fq '.loop-active'; then
  # A removal aimed at the marker, whether it names a shell verb (rm/unlink/shred/mv/-delete) or
  # reaches the same syscall through a language runtime (python os.remove, node fs.unlink, perl/
  # ruby unlink, PowerShell Remove-Item). The interpreter path names no shell verb — that is the
  # hole a pure verb match leaves open, and the categorical fix is the hard marker, not this list.
  if printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_.-])(rm|unlink|shred|mv)([[:space:]]|$)' \
    || printf '%s' "$CMD" | grep -Eq '(^|[^[:alnum:]_-])-delete([[:space:]]|$)' \
    || printf '%s' "$CMD" | grep -Eq 'os\.(remove|unlink)|shutil\.rmtree|\.unlink\(|(^|[^[:alnum:]_])unlink[[:space:](]|fs\.(unlink|rm)|rmSync|File\.(delete|unlink)|Remove-Item'; then
    deny "Blocked by the orchestrate loop guard: the .loop-active marker is human-only. The loop writes it at run start and never removes it — if the loop could clear its own gate, the gate would not be a gate. This includes deleting it through a language runtime (os.remove, fs.unlink, unlink), not only shell rm. Reach a hard stop (clean exit, FLAG-HUMAN, or non-convergence), write the approval card, and end the run with the marker in place. $OVERRIDE"
  fi
fi

# 3. `git clean` with -x/-X reaches ignored files, and the marker is gitignored — so this is
#    marker removal by another name.
if printf '%s' "$CMD" | grep -Eq 'git[[:space:]]+((-C|-c)[[:space:]]+[^[:space:]]+[[:space:]]+)*clean([[:space:]]+-[^[:space:]]*[xX])'; then
  deny "Blocked by the orchestrate loop guard: 'git clean' with -x/-X removes ignored files, and .loop-active is gitignored — that clears the human gate. Use 'git clean -fd' (which leaves ignored files alone) if you need to clean the tree mid-run. $OVERRIDE"
fi

exit 0
