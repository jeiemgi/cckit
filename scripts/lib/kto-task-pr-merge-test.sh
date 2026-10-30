#!/usr/bin/env bash
# kto-task-pr-merge-test.sh — kto_task_pr_merge never acts on the base branch (#366).
# A flag taken as the PR number used to "merge" (gh pr merge --help exits 0) and then run the branch
# cleanup on the base branch; a conflicting PR merged from the hub would rebase + force-push it.
# Hermetic: stubbed gh, throwaway repo + bare remote. Run: bash scripts/lib/kto-task-pr-merge-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$LIB/../.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "kto-task-pr-merge-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log" GH_MERGEABLE="MERGEABLE"; : > "$GH_LOG"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")  echo "{\"mergeable\":\"$GH_MERGEABLE\",\"status\":\"CLEAN\"}" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" KIT_REPO="o/r" KIT_BASE_BRANCH="develop" KIT_PROJECTS_V2="false"
unset KIT_CONFIG

git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@t; git config user.name t
git checkout -q -b develop; git commit -q --allow-empty -m init; git push -q origin develop

# shellcheck source=/dev/null
. "$LIB/kit-task-ops.sh"

kto_task_pr_merge --help >/dev/null 2>&1; rc=$?
t "a flag is refused as a PR number (rc 2)"      "$rc" "2"
t "nothing was merged on a refused flag"         "$(grep -c 'pr merge' "$GH_LOG")" "0"
t "the dispatcher answers --help with usage"     "$("$ROOT/bin/cckit" merge --help | cut -c1-18)" "cckit merge [<pr>]"

: > "$GH_LOG"
kto_task_pr_merge 7 >/dev/null 2>&1
t "a numeric PR merges"                          "$(grep -c 'pr merge 7' "$GH_LOG")" "1"
t "merging from the base branch keeps it"        "$(git branch --list develop | tr -d ' *')" "develop"
t "and keeps it on origin"                       "$(git ls-remote --heads origin develop | wc -l | tr -d ' ')" "1"

: > "$GH_LOG"; GH_MERGEABLE="CONFLICTING"
before="$(git rev-parse develop)"
kto_task_pr_merge 8 >/dev/null 2>&1; rc=$?
t "a conflicting PR from the base branch is refused" "$rc" "1"
t "the base branch was not rebased"              "$(git rev-parse develop)" "$before"
t "nothing was merged on a conflict refusal"     "$(grep -c 'pr merge' "$GH_LOG")" "0"

[ "$fail" -eq 0 ] && echo "kto-task-pr-merge: all passed" || echo "kto-task-pr-merge: FAILURES"
exit "$fail"
