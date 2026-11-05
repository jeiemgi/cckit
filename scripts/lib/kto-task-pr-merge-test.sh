#!/usr/bin/env bash
# kto-task-pr-merge-test.sh — kto_task_pr_merge never acts on the base branch (#366), cleans up from
# the PR's own worktree (#371), and merges by squash, merge commit or rebase into develop or an
# effort branch (#376).
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
export GH_LOG="$tmp/gh.log" GH_MERGEABLE="MERGEABLE" GH_BASE="develop" GH_HEAD=""; : > "$GH_LOG"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "pr view")  printf '{"mergeable":"%s","mergeStateStatus":"CLEAN","baseRefName":"%s","headRefName":"%s"}\n' \
                "$GH_MERGEABLE" "${GH_BASE:-develop}" "${GH_HEAD:-}" ;;
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
# #376: a bad flag, or a second PR number, is refused with usage and merges nothing
kto_task_pr_merge 7 --fast >/dev/null 2>"$tmp/errf"; rc=$?
t "an unknown flag is refused (rc 2)"            "$rc" "2"
t "the refusal prints the usage"                 "$(grep -c 'usage: cckit merge \[<pr>\] \[--squash|--merge|--rebase\]' "$tmp/errf")" "1"
kto_task_pr_merge 7 8 >/dev/null 2>&1; rc=$?
t "two PR numbers are refused (rc 2)"            "$rc" "2"
t "nothing was merged on a refused flag"         "$(grep -c 'pr merge' "$GH_LOG")" "0"

: > "$GH_LOG"; GH_HEAD="fix/7-x"
kto_task_pr_merge 7 >/dev/null 2>&1
t "a numeric PR merges"                          "$(grep -c 'pr merge 7' "$GH_LOG")" "1"
t "the default method is still squash"           "$(grep -c 'pr merge 7 --repo o/r --squash' "$GH_LOG")" "1"
# #376: --merge (a merge commit) and --rebase reach gh unchanged
: > "$GH_LOG"; GH_HEAD="fix/10-x"
kto_task_pr_merge 10 --merge >/dev/null 2>&1; rc=$?
t "--merge succeeds"                             "$rc" "0"
t "--merge asks GitHub for a merge commit"       "$(grep -c 'pr merge 10 --repo o/r --merge' "$GH_LOG")" "1"
: > "$GH_LOG"; GH_HEAD="fix/13-x"
kto_task_pr_merge --rebase 13 >/dev/null 2>&1; rc=$?
t "--rebase succeeds (flag before the number)"   "$rc" "0"
t "--rebase asks GitHub for a rebase merge"      "$(grep -c 'pr merge 13 --repo o/r --rebase' "$GH_LOG")" "1"
t "merging from the base branch keeps it"        "$(git branch --list develop | tr -d ' *')" "develop"
t "and keeps it on origin"                       "$(git ls-remote --heads origin develop | wc -l | tr -d ' ')" "1"

: > "$GH_LOG"; GH_MERGEABLE="CONFLICTING"; GH_HEAD="fix/8-x"
before="$(git rev-parse develop)"
kto_task_pr_merge 8 >/dev/null 2>&1; rc=$?
t "a conflicting PR from the base branch is refused" "$rc" "1"
t "the base branch was not rebased"              "$(git rev-parse develop)" "$before"
t "nothing was merged on a conflict refusal"     "$(grep -c 'pr merge' "$GH_LOG")" "0"

# ── #371: merged from the PR's OWN worktree, the cleanup still finishes ─────────────────────────
: > "$GH_LOG"; GH_MERGEABLE="MERGEABLE"; GH_HEAD="fix/9-x"
wt="$tmp/work/.claude/worktrees/fix+9-x"
git worktree add -q -b fix/9-x "$wt" develop
git -C "$wt" commit -q --allow-empty -m "the fix"
git -C "$wt" push -q origin fix/9-x
( cd "$wt" && kto_task_pr_merge 9 ) >/dev/null 2>"$tmp/err9"; rc=$?
t "merge from inside its worktree exits 0"        "$rc" "0"
t "the PR was merged"                             "$(grep -c 'pr merge 9' "$GH_LOG")" "1"
t "its worktree is removed"                       "$([ -d "$wt" ] && echo present || echo gone)" "gone"
t "its local branch is deleted"                   "$(git branch --list fix/9-x | wc -l | tr -d ' ')" "0"
t "its remote branch is deleted"                  "$(git ls-remote --heads origin fix/9-x | wc -l | tr -d ' ')" "0"
t "no 'Unable to read current working directory'" "$(grep -c 'current working directory' "$tmp/err9")" "0"
t "the base branch survives"                      "$(git branch --list develop | tr -d ' *')" "develop"

# ── #376: a sub PR whose base is an effort branch ────────────────────────────────────────────────
git checkout -q develop
ewt="$tmp/work/.claude/worktrees/effort+5-e"
git worktree add -q -b effort/5-e "$ewt" develop
git -C "$ewt" commit -q --allow-empty -m "effort start"; git -C "$ewt" push -q origin effort/5-e
swt="$tmp/work/.claude/worktrees/sub+5a-x"
git worktree add -q -b sub/5a-x "$swt" effort/5-e
git -C "$swt" commit -q --allow-empty -m "sub a"; git -C "$swt" push -q origin sub/5a-x
# what GitHub's merge does to the effort branch: a new commit on origin/effort/5-e
git clone -q "$tmp/remote.git" "$tmp/gh-side" 2>/dev/null
git -C "$tmp/gh-side" checkout -q effort/5-e
git -C "$tmp/gh-side" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "Merge pull request #11"
git -C "$tmp/gh-side" push -q origin effort/5-e

: > "$GH_LOG"; GH_BASE="effort/5-e"; GH_HEAD="sub/5a-x"
( cd "$swt" && kto_task_pr_merge 11 --merge ) >/dev/null 2>&1; rc=$?
t "a sub PR into an effort branch merges (rc 0)" "$rc" "0"
t "with a merge commit"                          "$(grep -c 'pr merge 11 --repo o/r --merge' "$GH_LOG")" "1"
t "the sub worktree is removed"                  "$([ -d "$swt" ] && echo present || echo gone)" "gone"
t "the sub branch is deleted"                    "$(git branch --list sub/5a-x | wc -l | tr -d ' ')" "0"
t "the effort branch survives"                   "$(git branch --list effort/5-e | tr -d ' *+')" "effort/5-e"
t "the effort worktree survives"                 "$([ -d "$ewt" ] && echo present || echo gone)" "present"
t "the effort worktree is pulled to the merge"   "$(git -C "$ewt" rev-parse HEAD)" "$(git -C "$tmp/gh-side" rev-parse HEAD)"
t "the main checkout stays on develop"           "$(git rev-parse --abbrev-ref HEAD)" "develop"

# Run from the EFFORT worktree with a sub PR number: the current branch is the PR's base, and it
# must never be treated as the branch to clean up (before #376 this deleted effort/5-e).
git branch -q sub/5b-y effort/5-e; git push -q origin sub/5b-y
: > "$GH_LOG"; GH_HEAD="sub/5b-y"
( cd "$ewt" && kto_task_pr_merge 12 ) >/dev/null 2>&1; rc=$?
t "merging a sub PR from the effort worktree: rc 0" "$rc" "0"
t "the effort branch still survives"             "$(git branch --list effort/5-e | tr -d ' *+')" "effort/5-e"
t "the effort worktree still survives"           "$([ -d "$ewt" ] && echo present || echo gone)" "present"
t "the sub branch (not the cwd branch) is deleted" "$(git branch --list sub/5b-y | wc -l | tr -d ' ')" "0"
t "and on origin"                                "$(git ls-remote --heads origin sub/5b-y | wc -l | tr -d ' ')" "0"
t "effort/5-e is still on origin"                "$(git ls-remote --heads origin effort/5-e | wc -l | tr -d ' ')" "1"

[ "$fail" -eq 0 ] && echo "kto-task-pr-merge: all passed" || echo "kto-task-pr-merge: FAILURES"
exit "$fail"
