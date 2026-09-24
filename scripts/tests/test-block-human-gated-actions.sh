#!/bin/bash
# Regression suite for scripts/block-human-gated-actions.sh
#
# Run: bash scripts/tests/test-block-human-gated-actions.sh
# (Invoke via `bash` — the repo is synced to machines that do not preserve the +x bit.)
#
# The guard is fail-closed, so a false positive blocks legitimate work rather than letting a
# hidden action through. That is not free: a guard that cries wolf trains the reflexive
# override, and a reflex-used override means nothing. Every must-pass case below is there
# because blocking it would be a defect, not a nuisance.

GUARD="$(cd "$(dirname "$0")/.." && pwd)/block-human-gated-actions.sh"
PASS=0
FAIL=0

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
mkdir -p "$TMPROOT/marked" "$TMPROOT/clear"
: > "$TMPROOT/marked/.loop-active"
# A real repo, so the guard can resolve aliases that already exist in git config.
git -C "$TMPROOT/marked" init -q
git -C "$TMPROOT/marked" config alias.pp push
git -C "$TMPROOT/marked" config alias.shp '!git push origin HEAD'
git -C "$TMPROOT/marked" config alias.lg 'log --oneline'
# A stub gh on PATH, so the guard's `gh alias list` sees known aliases without touching real config.
mkdir -p "$TMPROOT/bin"
cat > "$TMPROOT/bin/gh" <<'STUB'
#!/bin/bash
[ "$1 $2" = "alias list" ] && printf '%s\n' 'co: pr checkout' 'pc: pr create --fill' 'a: api' 'sh: !gh pr merge --auto'
STUB
chmod +x "$TMPROOT/bin/gh"
export PATH="$TMPROOT/bin:$PATH"

run_guard() { # $1 = repo root, $2 = command
  printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$(printf '%s' "$2" | jq -Rs .)" \
    | CLAUDE_PROJECT_DIR="$1" bash "$GUARD" 2>/dev/null
  return $?
}

expect_block() { # $1 = label, $2 = command
  run_guard "$TMPROOT/marked" "$2"
  if [ $? -eq 2 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "  FAIL (expected BLOCK, got allow): $1 — $2"
  fi
}

expect_pass() { # $1 = label, $2 = command
  run_guard "$TMPROOT/marked" "$2"
  if [ $? -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "  FAIL (expected ALLOW, got block): $1 — $2"
  fi
}

expect_pass_unmarked() { # $1 = label, $2 = command
  run_guard "$TMPROOT/clear" "$2"
  if [ $? -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1)); echo "  FAIL (expected ALLOW with no marker, got block): $1 — $2"
  fi
}

echo "== shipping verbs must block while a run is live =="
expect_block "gh pr create"            'gh pr create --fill'
expect_block "gh pr merge"             'gh pr merge 12 --squash'
expect_block "gh pr ready"             'gh pr ready 12'
expect_block "gh pr review --approve"  'gh pr review 12 --approve'
expect_block "git push"                'git push'
expect_block "git push with remote"    'git push origin feature/x'
expect_block "git -C push"             'git -C /tmp/repo push origin main'
expect_block "push after &&"           'npm test && git push origin main'
expect_block "gh api pulls POST"       'gh api repos/o/r/pulls -X POST -f title=x'
expect_block "gh api POST then pulls"  'gh api -X POST repos/o/r/pulls -f title=x'
expect_block "gh api merge PUT"        'gh api repos/o/r/pulls/1/merge --method PUT'

echo "== G1: the ship guard's known bypasses must block =="
expect_block "gh api implicit POST -f"   'gh api repos/o/r/pulls -f title=x -f head=b -f base=main'
expect_block "gh api implicit POST -F"   'gh api repos/o/r/pulls/1/reviews -F event=APPROVE'
expect_block "gh api --raw-field"        'gh api repos/o/r/pulls --raw-field title=x'
expect_block "gh api --input"            'gh api repos/o/r/pulls --input body.json'
expect_block "gh api --method=POST"      'gh api --method=POST repos/o/r/pulls'
expect_block "gh api lowercase post"     'gh api -X post repos/o/r/pulls'
expect_block "gh api -XPUT merge"        'gh api -XPUT repos/o/r/pulls/1/merge'
expect_block "gh api merges endpoint"    'gh api repos/o/r/merges -f base=main -f head=x'
expect_block "gh api git/refs"           'gh api repos/o/r/git/refs/heads/main -X PATCH -f sha=abc'
expect_block "gh api contents"           'gh api repos/o/r/contents/README.md -X PUT -f message=x'
expect_block "gh api graphql merge"      "gh api graphql -f query='mutation { mergePullRequest(input:{pullRequestId:\"x\"}) { clientMutationId } }'"
expect_block "gh api graphql create"     "gh api graphql -f query='mutation { createPullRequest(input:{}) { clientMutationId } }'"
expect_block "gh api graphql from file"  'gh api graphql -F query=@mutation.graphql'
expect_block "define a gh alias"        "gh alias set pc 'pr create --fill'"
expect_block "import gh aliases"        'gh alias import aliases.yml'
expect_block "delete branch protection"  'gh api -X DELETE repos/o/r/branches/main/protection'
expect_block "drop enforce_admins"       'gh api --method DELETE repos/o/r/branches/main/protection/enforce_admins'
expect_block "rewrite branch protection" 'gh api -X PUT repos/o/r/branches/main/protection --input p.json'
expect_block "loosen required reviews"   'gh api repos/o/r/branches/main/protection/required_pull_request_reviews -X PATCH -F required_approving_review_count=0'
expect_block "delete a ruleset"          'gh api -X DELETE repos/o/r/rulesets/42'
expect_block "edit a ruleset"            'gh api repos/o/r/rulesets/42 -X PUT -f enforcement=disabled'
expect_block "graphql delete protection" "gh api graphql -f query='mutation { deleteBranchProtectionRule(input:{branchProtectionRuleId:\"x\"}) { clientMutationId } }'"
expect_block "graphql delete ref"        "gh api graphql -f query='mutation { deleteRef(input:{refId:\"x\"}) { clientMutationId } }'"
expect_block "delete remote ref by API"  'gh api -X DELETE repos/o/r/git/refs/heads/main'
expect_block "gh pr review -a"           'gh pr review 12 -a'
expect_block "gh repo sync"              'gh repo sync o/r --branch main'
expect_block "git --no-pager push"       'git --no-pager push origin main'
expect_block "git -p push"               'git -p push'
expect_block "git --git-dir push"        'git --git-dir .git --work-tree . push origin main'
expect_block "git --git-dir= push"       'git --git-dir=.git push origin main'
expect_block "git -c then push"          'git -c core.askpass=true push'
expect_block "git send-pack"             'git send-pack origin main'
expect_block "git subtree push"          'git subtree push --prefix dist origin gh-pages'
expect_block "inline alias to push"      'git -c alias.p=push p origin main'
expect_block "inline shell alias"        "git -c 'alias.p=!git push' p"
expect_block "define push alias"         'git config alias.p push'
expect_block "env-injected alias"        'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0=push git p'
expect_block "curl with gh token"        'curl -X POST -H "Authorization: token $(gh auth token)" https://api.github.com/repos/o/r/pulls -d @body.json'
expect_block "curl with GITHUB_TOKEN"    'curl -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/repos/o/r/pulls/1/merge -X PUT'
expect_block "curl basic auth"           'curl -u me:$PAT https://api.github.com/repos/o/r/pulls -d @b.json'
expect_block "python with token"         "python3 -c 'import os,requests; requests.post(\"https://api.github.com/repos/o/r/pulls\", headers={\"Authorization\": os.environ[\"GH_TOKEN\"]})'"
expect_block "read the gh token"         'gh auth token'
expect_block "token into a file"         'gh auth token > /tmp/t'
expect_block "show-token"                'gh auth status --show-token'
expect_block "git credential fill"       'printf "protocol=https\nhost=github.com\n" | git credential fill'
expect_block "keychain lookup"           'security find-internet-password -s github.com -w'

echo "== the marker is human-only =="
expect_block "rm marker"               'rm .loop-active'
expect_block "rm -f marker"            'rm -f .loop-active'
expect_block "rm absolute path"        'rm -f /Users/x/repo/.loop-active'
expect_block "rm quoted marker"        "rm '.loop-active'"
expect_block "mv marker away"          'mv .loop-active .loop-done'
expect_block "unlink marker"           'unlink .loop-active'
expect_block "shred marker"            'shred -u .loop-active'
expect_block "find -delete marker"     'find . -name .loop-active -delete'
expect_block "clear gate then push"    'rm .loop-active && git push origin main'
expect_block "git clean -fdx"          'git clean -fdx'
expect_block "git clean -xf"           'git clean -xf'
expect_block "git -C clean -fdx"       'git -C /tmp/repo clean -fdx'

echo "== G3: the soft marker's other removal paths must block =="
expect_block "clean -x as second flag"  'git clean -f -x'
expect_block "clean -X after long flag" 'git clean -d --force -X'
expect_block "clean -x after path"      'git clean -f . -x'
expect_block "git --no-pager clean -x"  'git --no-pager clean -fdx'
expect_block "stash -a"                 'git stash -a'
expect_block "stash push --all"         'git stash push --all -m wip'
expect_block "stash --include-ignored"  'git stash push --include-ignored'
expect_block "stash save -a"            'git stash save -a wip'
expect_block "stash -ua"                'git stash -ua'
expect_block "python os.rename"         "python3 -c 'import os; os.rename(\".loop-active\", \"x\")'"
expect_block "python os.replace"        "python3 -c 'import os; os.replace(\".loop-active\", \"/tmp/x\")'"
expect_block "python Path.rename"       "python3 -c 'from pathlib import Path; Path(\".loop-active\").rename(\"x\")'"
expect_block "python shutil.move"       "python3 -c 'import shutil; shutil.move(\".loop-active\", \"/tmp\")'"
expect_block "node fs.renameSync"       "node -e 'require(\"fs\").renameSync(\".loop-active\", \"x\")'"
expect_block "node fs.rename"           "node -e 'require(\"fs\").rename(\".loop-active\", \"x\", ()=>{})'"
expect_block "perl rename"              "perl -e 'rename \".loop-active\", \"x\"'"
expect_block "ruby File.rename"         "ruby -e 'File.rename(\".loop-active\", \"x\")'"
expect_block "rename utility"           'rename s/active/done/ .loop-active'
expect_block "PowerShell Move-Item"     'pwsh -c "Move-Item .loop-active x"'

echo "== ordinary work must not be blocked =="
expect_pass "commit"                   'git commit -m "feat: add the thing"'
expect_pass "commit naming push"       'git commit -m "prepare the push branch"'
expect_pass "stage"                    'git add -A'
expect_pass "status"                   'git status --porcelain'
expect_pass "log"                      'git log --oneline -5'
expect_pass "branch"                   'git switch -c feature/x'
expect_pass "tests"                    'npm test'
expect_pass "build"                    'npm run build'
expect_pass "read the marker"          'cat .loop-active'
expect_pass "grep for the marker"      'grep -rn "loop-active" README.md'
expect_pass "ls the marker"            'ls -la .loop-active'
expect_pass "rm unrelated tree"        'rm -rf node_modules'
expect_pass "rm unrelated file"        'rm -f dist/bundle.js'
expect_pass "mv unrelated file"        'mv src/a.ts src/b.ts'
expect_pass "git clean without -x"     'git clean -fd'
expect_pass "clean dry-run, exclude"   'git clean -nd --exclude=build'
expect_pass "clean -fd then ls -x"     'git clean -fd; ls -x'
expect_pass "stash"                    'git stash'
expect_pass "stash -u"                 'git stash -u'
expect_pass "stash push with message"  'git stash push -m "a quick fix"'
expect_pass "stash apply"              'git stash apply'
expect_pass "stash list --date"        'git stash list --date=relative'
expect_pass "rename unrelated file"    "python3 -c 'import os; os.rename(\"a.txt\", \"b.txt\")'"
expect_pass "gitignore append"         'printf "\n.loop-active\n" >> .gitignore'
expect_pass "truncate marker (still exists)" ': > .loop-active'
expect_pass "gh pr list"               'gh pr list'
expect_pass "gh pr view"               'gh pr view 12'
expect_pass "gh pr diff"               'gh pr diff 12'
expect_pass "gh api GET pulls"         'gh api repos/o/r/pulls'
expect_pass "gh issue create"          'gh issue create --title x'
expect_pass "read branch protection"    'gh api repos/o/r/branches/main/protection'
expect_pass "list rulesets"            'gh api repos/o/r/rulesets'
expect_pass "gh api GET with fields"   'gh api -X GET repos/o/r/pulls -f state=open'
expect_pass "gh api issues comment"    'gh api repos/o/r/issues/1/comments -f body=x'
expect_pass "gh api read then jq -f"   'gh api repos/o/r/pulls | jq -f filter.jq'
expect_pass "gh api graphql query"     "gh api graphql -f query='query { viewer { login } }'"
expect_pass "gh auth status"           'gh auth status'
expect_pass "git --no-pager log"       'git --no-pager log --oneline -5'
expect_pass "git -c commit"            'git -c user.name=x commit -m "y"'
expect_pass "list aliases"             'git config --get-regexp alias'
expect_pass "curl public api, no auth" 'curl -s https://api.github.com/repos/o/r'
expect_pass "curl unrelated with token" 'curl -H "Authorization: Bearer $T" https://example.com/api'
expect_pass "configured non-push alias" 'git lg'

echo "== aliases already in git config =="
expect_block "configured push alias"   'git pp origin main'
expect_block "configured shell alias"  'git --no-pager shp'
expect_pass  "configured log alias"    'git lg -5'
expect_block "gh alias to pr create"   'gh pc'
expect_block "gh alias to api"         'gh a repos/o/r/pulls -f title=x'
expect_block "gh shell alias"          'gh sh 12'
expect_pass  "gh alias to checkout"    'gh co 12'

echo "== with no marker, nothing is gated =="
expect_pass_unmarked "push"            'git push origin main'
expect_pass_unmarked "pr create"       'gh pr create --fill'
expect_pass_unmarked "human clears gate" 'rm .loop-active'

echo "== a block must explain itself on stderr =="
ERRTEXT=$(printf '{"tool_name":"Bash","tool_input":{"command":"git push"}}' \
  | CLAUDE_PROJECT_DIR="$TMPROOT/marked" bash "$GUARD" 2>&1 >/dev/null)
if [ -n "$ERRTEXT" ]; then PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); echo "  FAIL: blocked command produced no stderr reason"; fi

echo "== malformed input fails open =="
if printf 'not json' | CLAUDE_PROJECT_DIR="$TMPROOT/marked" bash "$GUARD" >/dev/null 2>&1; then
  PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); echo "  FAIL: malformed stdin should fail open"; fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
