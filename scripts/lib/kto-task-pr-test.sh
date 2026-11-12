#!/usr/bin/env bash
# kto-task-pr-test.sh — kto_task_pr end to end against a stubbed gh and a bare remote (#361):
# it commits tracked changes only (never an untracked .env.local), and it honours
# pr.titleStyle + pr.orchestratorSection when it opens the PR.
# Run: bash scripts/lib/kto-task-pr-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in gh log)"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "kto-task-pr-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "issue view") echo '{"title":"Fix the thing","labels":[{"name":"kind:fix"},{"name":"role:tech-lead"}],"milestone":null}' ;;
  "pr create")  echo "https://github.com/o/r/pull/7" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" KIT_REPO="o/r" KIT_BASE_BRANCH="main" KIT_PROJECTS_V2="false"
unset KIT_CONFIG

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
tc "$GH_LOG" 'pr create .*--title Fix the thing( |$)' "issue-title: the PR title is the issue title"
tc "$GH_LOG" '[-]-body ## For the orchestrator$'     "orchestratorSection: the body opens with the section"
tc "$GH_LOG" '^#42 · Fix the thing$'                  "orchestratorSection: id + title line"

: > "$GH_LOG"; git checkout -q -b fix/43-other
KIT_PR_TITLE_STYLE=conventional kto_task_pr 43 "Other." >/dev/null 2>&1
tc "$GH_LOG" 'pr create .*--title fix: Fix the thing' "conventional (default): a Conventional Commits title"
grep -q 'For the orchestrator' "$GH_LOG" && { echo "FAIL: section present with the switch off"; fail=1; } || echo "ok: no section with the switch off"

# --base (#391): an explicit base wins over the configured one; the flag is never a positional.
: > "$GH_LOG"; git checkout -q -b task/44-release
echo three > tracked.txt
kto_task_pr 44 "Release." --base release >/dev/null 2>&1
t  "--base: rc 0"                            "$?" "0"
tc "$GH_LOG" 'pr create .*--base release --head task/44-release' "--base: the PR targets the given base"
t  "--base is not taken as the commit message" "$(git log -1 --format=%s)" "fix: Fix the thing"
: > "$GH_LOG"
kto_task_pr 44 "Release." >/dev/null 2>&1
tc "$GH_LOG" 'pr create .*--base main --head task/44-release' "no --base: the PR targets the configured base"
: > "$GH_LOG"
kto_task_pr --base=release 44 "Release." >/dev/null 2>&1
tc "$GH_LOG" 'pr create .*--base release --head task/44-release' "--base=<branch> before the positionals"
: > "$GH_LOG"
kto_task_pr 44 "Release." "custom subject" --base release >/dev/null 2>&1
tc "$GH_LOG" 'pr create .*--base release ' "--base after an explicit commit message"

: > "$GH_LOG"; git checkout -q -b task/45-no-value
echo four > tracked.txt
kto_task_pr 45 "No value." --base >/dev/null 2>"$tmp/err"
t  "--base with no value: rc 2"              "$?" "2"
tc "$tmp/err" '[-]-base needs a branch'      "--base with no value: says what is missing"
t  "--base with no value: no gh call"        "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
t  "--base with no value: nothing pushed"    "$(git ls-remote --heads origin task/45-no-value | wc -l | tr -d ' ')" "0"
t  "--base with no value: nothing committed" "$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')" "1"
kto_task_pr 45 "No value." --base= >/dev/null 2>&1
t  "--base= (empty): rc 2"                   "$?" "2"

# the dispatcher: `cckit pr --help` prints the usage and reaches neither gh nor the remote.
: > "$GH_LOG"
out="$("$LIB/../../bin/cckit" pr --help 2>/dev/null)"
t  "cckit pr --help: rc 0"                   "$?" "0"
case "$out" in *'[--base <branch>]'*) echo "ok: cckit pr --help shows --base" ;; *) echo "FAIL: cckit pr --help -> '$out'"; fail=1 ;; esac
t  "cckit pr --help: no gh call"             "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
grep -qE '^#   cckit pr <issue> <summary> \[--base <branch>\]' "$LIB/../../bin/cckit" \
  && echo "ok: the usage header shows --base" || { echo "FAIL: usage header lacks --base"; fail=1; }

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
tc "$GH_LOG" 'pr create .*--base main( |$)'  "--base main: the PR targets main, not the configured develop"
t  "--base main: the pre-push hook sees it"  "$(cat "$tmp/prepush.log")" "KIT_PR_BASE=main"
t  "--base is not taken as the commit msg"   "$(git log -1 --format=%s)" "fix: Fix the thing"

: > "$GH_LOG"; : > "$tmp/prepush.log"; git checkout -q -b fix/45-eq
echo four > tracked.txt
kto_task_pr --base=main 45 "Eq." "fix: custom msg" >/dev/null 2>&1
tc "$GH_LOG" 'pr create .*--base main( |$)'  "--base=main before the positionals works too"
t  "the commit message positional survives"  "$(git log -1 --format=%s)" "fix: custom msg"

: > "$GH_LOG"; : > "$tmp/prepush.log"; git checkout -q -b fix/46-default
echo five > tracked.txt
kto_task_pr 46 "Default." >/dev/null 2>&1
tc "$GH_LOG" 'pr create .*--base develop( |$)' "no --base: the configured integration branch"
t  "no --base: the hook gets the integration branch" "$(cat "$tmp/prepush.log")" "KIT_PR_BASE=develop"

: > "$GH_LOG"; git checkout -q -b fix/47-bad
kto_task_pr 47 "Bad." --base >/dev/null 2>"$tmp/err"
t  "--base with no value is refused"         "$?" "2"
t  "…before any gh call"                     "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

[ "$fail" -eq 0 ] && echo "kto-task-pr: all passed" || echo "kto-task-pr: FAILURES"
exit "$fail"
