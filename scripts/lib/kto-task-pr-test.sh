#!/usr/bin/env bash
# kto-task-pr-test.sh — kto_task_pr end to end against the forge shim and a bare remote (#361, E537):
# it commits tracked changes only (never an untracked .env.local), and it honours
# pr.titleStyle + pr.orchestratorSection when it opens the PR over REST (POST repos/o/r/pulls).
# Run: bash scripts/lib/kto-task-pr-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "kto-task-pr-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"
# shellcheck source=/dev/null
. "$LIB/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export PATH="$tmp/bin:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github
export KIT_REPO="o/r" KIT_BASE_BRANCH="main" KIT_PROJECTS_V2="false"
export GH_TITLE="Fix the thing" GH_LABELS='[{"name":"kind:fix"},{"name":"role:tech-lead"}]'
unset KIT_CONFIG
# The PR is opened with ONE POST on repos/o/r/pulls; its JSON body is the log line's third field.
PR_POST='^POST repos/o/r/pulls \{'

git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@t; git config user.name t
echo one > tracked.txt; git add tracked.txt; git commit -q -m init; git push -q origin HEAD:main
git checkout -q -b fix/42-the-thing
echo two > tracked.txt                      # a tracked change: must be committed
echo SECRET=x > .env.local                  # untracked, not ignored: must NOT be committed

# shellcheck source=/dev/null
. "$LIB/kit-task-ops.sh"
KIT_PR_TITLE_STYLE=issue-title KIT_PR_ORCHESTRATOR_SECTION=true \
  kto_task_pr 42 "Did the thing." >/dev/null 2>"$tmp/err"
t  "kto_task_pr succeeds under set -u"      "$?" "0"

t  "the tracked change is committed"        "$(git show --name-only --format= HEAD)" "tracked.txt"
t  "the untracked .env.local is not"        "$(git ls-files .env.local)" ""
t  ".env.local is still on disk"            "$(cat .env.local)" "SECRET=x"
grep -q '.env.local' "$tmp/err" && echo "ok: the untracked file is reported" || { echo "FAIL: untracked file not reported"; fail=1; }
tc "$GH_LOG" "${PR_POST}\"title\":\"Fix the thing\"," "issue-title: the PR title is the issue title"
tc "$GH_LOG" "${PR_POST}.*\"body\":\"## For the orchestrator\\\\n" "orchestratorSection: the body opens with the section"
tc "$GH_LOG" "${PR_POST}.*## For the orchestrator\\\\n\\\\n#42 · Fix the thing\\\\n" "orchestratorSection: id + title line"
t  "no gh subcommand ran"                   "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"

: > "$GH_LOG"; git checkout -q -b fix/43-other
KIT_PR_TITLE_STYLE=conventional kto_task_pr 43 "Other." >/dev/null 2>&1
tc "$GH_LOG" "${PR_POST}\"title\":\"fix: Fix the thing \\[#43\\]\"," "conventional (default): a Conventional Commits title + the [#N] token"
grep -q 'For the orchestrator' "$GH_LOG" && { echo "FAIL: section present with the switch off"; fail=1; } || echo "ok: no section with the switch off"

# --base (#391): an explicit base wins over the configured one; the flag is never a positional.
: > "$GH_LOG"; git checkout -q -b task/44-release
echo three > tracked.txt
kto_task_pr 44 "Release." --base release >/dev/null 2>&1
t  "--base: rc 0"                            "$?" "0"
tc "$GH_LOG" "${PR_POST}.*\"head\":\"task/44-release\",\"base\":\"release\"," "--base: the PR targets the given base"
t  "--base is not taken as the commit message" "$(git log -1 --format=%s)" "fix: Fix the thing [#44]"
: > "$GH_LOG"
kto_task_pr 44 "Release." >/dev/null 2>&1
tc "$GH_LOG" "${PR_POST}.*\"head\":\"task/44-release\",\"base\":\"main\"," "no --base: the PR targets the configured base"
: > "$GH_LOG"
kto_task_pr --base=release 44 "Release." >/dev/null 2>&1
tc "$GH_LOG" "${PR_POST}.*\"head\":\"task/44-release\",\"base\":\"release\"," "--base=<branch> before the positionals"
: > "$GH_LOG"
kto_task_pr 44 "Release." "custom subject" --base release >/dev/null 2>&1
tc "$GH_LOG" "${PR_POST}.*\"base\":\"release\"," "--base after an explicit commit message"

: > "$GH_LOG"; git checkout -q -b task/45-no-value
echo four > tracked.txt
kto_task_pr 45 "No value." --base >/dev/null 2>"$tmp/err"
t  "--base with no value: rc 2"              "$?" "2"
tc "$tmp/err" '[-]-base needs a branch'      "--base with no value: says what is missing"
t  "--base with no value: no forge request"  "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
t  "--base with no value: nothing pushed"    "$(git ls-remote --heads origin task/45-no-value | wc -l | tr -d ' ')" "0"
t  "--base with no value: nothing committed" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "1"
kto_task_pr 45 "No value." --base= >/dev/null 2>&1
t  "--base= (empty): rc 2"                   "$?" "2"

# the dispatcher: `cckit pr --help` prints the usage and reaches neither the forge nor the remote.
: > "$GH_LOG"
out="$("$LIB/../../bin/cckit" pr --help 2>/dev/null)"
t  "cckit pr --help: rc 0"                   "$?" "0"
case "$out" in *'[--base <branch>]'*) echo "ok: cckit pr --help shows --base" ;; *) echo "FAIL: cckit pr --help -> '$out'"; fail=1 ;; esac
t  "cckit pr --help: no forge request"       "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
grep -qE '^pr	.*	cckit pr <issue> "<summary>" .*\[--base <branch>\]' "$LIB/verbs.tsv" \
  && echo "ok: the verb table's pr usage shows --base" || { echo "FAIL: the verb table's pr usage lacks --base"; fail=1; }

# --base (#360): the flag wins over the configured integration branch, and the PR's target reaches a
# git pre-push hook as KIT_PR_BASE.
cat > .git/hooks/pre-push <<SH
#!/usr/bin/env bash
echo "KIT_PR_BASE=\${KIT_PR_BASE:-}" >> "$tmp/prepush.log"
SH
chmod +x .git/hooks/pre-push
export KIT_BASE_BRANCH="develop"            # what load_kit_config exported from the config
: > "$GH_LOG"; : > "$tmp/prepush.log"; git checkout -q -b fix/44-hot
echo three > tracked.txt
kto_task_pr 44 "Hot." --base main >/dev/null 2>&1
t  "--base: kto_task_pr succeeds"            "$?" "0"
tc "$GH_LOG" "${PR_POST}.*\"base\":\"main\"," "--base main: the PR targets main, not the configured develop"
t  "--base main: the pre-push hook sees it"  "$(cat "$tmp/prepush.log")" "KIT_PR_BASE=main"
t  "--base is not taken as the commit msg"   "$(git log -1 --format=%s)" "fix: Fix the thing [#44]"

: > "$GH_LOG"; : > "$tmp/prepush.log"; git checkout -q -b fix/45-eq
echo four > tracked.txt
kto_task_pr --base=main 45 "Eq." "fix: custom msg" >/dev/null 2>&1
tc "$GH_LOG" "${PR_POST}.*\"base\":\"main\"," "--base=main before the positionals works too"
t  "the commit message positional survives"  "$(git log -1 --format=%s)" "fix: custom msg"

: > "$GH_LOG"; : > "$tmp/prepush.log"; git checkout -q -b fix/46-default
echo five > tracked.txt
kto_task_pr 46 "Default." >/dev/null 2>&1
tc "$GH_LOG" "${PR_POST}.*\"base\":\"develop\"," "no --base: the configured integration branch"
t  "no --base: the hook gets the integration branch" "$(cat "$tmp/prepush.log")" "KIT_PR_BASE=develop"

: > "$GH_LOG"; git checkout -q -b fix/47-bad
kto_task_pr 47 "Bad." --base >/dev/null 2>"$tmp/err"
t  "--base with no value is refused"         "$?" "2"
t  "…before any forge request"               "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

[ "$fail" -eq 0 ] && echo "kto-task-pr: all passed" || echo "kto-task-pr: FAILURES"
exit "$fail"
