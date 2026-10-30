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

[ "$fail" -eq 0 ] && echo "kto-task-pr: all passed" || echo "kto-task-pr: FAILURES"
exit "$fail"
