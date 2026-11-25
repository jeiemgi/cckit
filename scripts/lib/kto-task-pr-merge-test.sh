#!/usr/bin/env bash
# kto-task-pr-merge-test.sh — kto_task_pr_merge never acts on the base branch (#366), cleans up from
# the PR's own worktree (#371), and merges by squash, merge commit or rebase into develop or an
# effort branch (#376). An effort/* HEAD is refused — its PR merges with `cckit effort close` (#379).
# A flag taken as the PR number used to "merge" (gh pr merge --help exits 0) and then run the branch
# cleanup on the base branch; a conflicting PR merged from the hub would rebase + force-push it.
# Hermetic: the forge shim (REST over a curl stand-in; the merge is PUT repos/o/r/pulls/<n>/merge
# {"merge_method":…}), throwaway repo + bare remote. Run: bash scripts/lib/kto-task-pr-merge-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$LIB/../.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "kto-task-pr-merge-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log" GH_MERGEABLE="true" GH_BASE="develop" GH_HEAD="" GH_CLOSED=""; : > "$GH_LOG"
# shellcheck source=/dev/null
. "$LIB/../../lib/forge/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export GH_TOKEN=test-token CCKIT_FORGE=github
export PATH="$tmp/bin:$PATH" KIT_REPO="o/r" KIT_BASE_BRANCH="develop" KIT_PROJECTS_V2="false"
unset KIT_CONFIG CLAUDE_CODE_REMOTE
# merged <n> — how many times PR <n> was merged (PUT pulls/<n>/merge); merged "" counts every merge.
merged() { grep -c "^PUT repos/o/r/pulls/$1${1:+/}.*merge " "$GH_LOG"; }

git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@t; git config user.name t
git checkout -q -b develop; git commit -q --allow-empty -m init; git push -q origin develop

# shellcheck source=/dev/null
. "$LIB/../../lib/verbs/kit-task-ops.sh"

kto_task_pr_merge --help >/dev/null 2>&1; rc=$?
t "a flag is refused as a PR number (rc 2)"      "$rc" "2"
t "nothing was merged on a refused flag"         "$(merged "")" "0"
t "the dispatcher answers --help with usage"     "$("$ROOT/bin/cckit" merge --help | sed -n 1p | cut -c1-18)" "cckit merge [<pr>]"
# #376: a bad flag, or a second PR number, is refused with usage and merges nothing
kto_task_pr_merge 7 --fast >/dev/null 2>"$tmp/errf"; rc=$?
t "an unknown flag is refused (rc 2)"            "$rc" "2"
t "the refusal prints the usage"                 "$(grep -c 'usage: cckit merge \[<pr>\] \[--squash|--merge|--rebase\]' "$tmp/errf")" "1"
kto_task_pr_merge 7 8 >/dev/null 2>&1; rc=$?
t "two PR numbers are refused (rc 2)"            "$rc" "2"
t "nothing was merged on a refused number"       "$(merged "")" "0"

: > "$GH_LOG"; GH_HEAD="fix/7-x"
kto_task_pr_merge 7 >/dev/null 2>&1
t "a numeric PR merges"                          "$(merged 7)" "1"
t "the default method is still squash"           "$(grep -c '^PUT repos/o/r/pulls/7/merge {"merge_method":"squash"}$' "$GH_LOG")" "1"
# #376: --merge (a merge commit) and --rebase reach the merge_method unchanged
: > "$GH_LOG"; GH_HEAD="fix/10-x"
kto_task_pr_merge 10 --merge >/dev/null 2>&1; rc=$?
t "--merge succeeds"                             "$rc" "0"
t "--merge asks GitHub for a merge commit"       "$(grep -c '^PUT repos/o/r/pulls/10/merge {"merge_method":"merge"}$' "$GH_LOG")" "1"
: > "$GH_LOG"; GH_HEAD="fix/13-x"
kto_task_pr_merge --rebase 13 >/dev/null 2>&1; rc=$?
t "--rebase succeeds (flag before the number)"   "$rc" "0"
t "--rebase asks GitHub for a rebase merge"      "$(grep -c '^PUT repos/o/r/pulls/13/merge {"merge_method":"rebase"}$' "$GH_LOG")" "1"
t "merging from the base branch keeps it"        "$(git branch --list develop | tr -d ' *')" "develop"
t "and keeps it on origin"                       "$(git ls-remote --heads origin develop | wc -l | tr -d ' ')" "1"

: > "$GH_LOG"; GH_MERGEABLE="false"; GH_HEAD="fix/8-x"
before="$(git rev-parse develop)"
kto_task_pr_merge 8 >/dev/null 2>&1; rc=$?
t "a conflicting PR from the base branch is refused" "$rc" "1"
t "the base branch was not rebased"              "$(git rev-parse develop)" "$before"
t "nothing was merged on a conflict refusal"     "$(merged "")" "0"

# ── #371: merged from the PR's OWN worktree, the cleanup still finishes ─────────────────────────
: > "$GH_LOG"; GH_MERGEABLE="true"; GH_HEAD="fix/9-x"
wt="$tmp/work/.claude/worktrees/fix+9-x"
git worktree add -q -b fix/9-x "$wt" develop
git -C "$wt" commit -q --allow-empty -m "the fix"
git -C "$wt" push -q origin fix/9-x
( cd "$wt" && kto_task_pr_merge 9 ) >/dev/null 2>"$tmp/err9"; rc=$?
t "merge from inside its worktree exits 0"        "$rc" "0"
t "the PR was merged"                             "$(merged 9)" "1"
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
t "with a merge commit"                          "$(grep -c '^PUT repos/o/r/pulls/11/merge {"merge_method":"merge"}$' "$GH_LOG")" "1"
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

# ── #379: the linked-issue loop does not depend on IFS ───────────────────────────────────────────
# The effort worktree lives under the main checkout here; keep it out of `git status` so the main
# checkout reads clean.
echo ".claude/" >> "$tmp/work/.git/info/exclude"
# A caller that left IFS NUL-polluted made `for n in $issues` pass "42\n43" as ONE issue number.
# The shim's PR body reads `Closes #42 / Fixes #43 / see #44`; both are open (GH_CLOSED is empty).
: > "$GH_LOG"; GH_BASE="develop"; GH_HEAD="fix/20-x"
( IFS=$'\0'; kto_task_pr_merge 20 ) >/dev/null 2>&1; rc=$?
t "merge under IFS=\$'\\0' exits 0"                "$rc" "0"
t "issue 42 is closed on its own"                "$(grep -c '^PATCH repos/o/r/issues/42 {"state":"closed"' "$GH_LOG")" "1"
t "issue 43 is closed on its own"                "$(grep -c '^PATCH repos/o/r/issues/43 {"state":"closed"' "$GH_LOG")" "1"
t "exactly two issue close calls"                "$(grep -c '^PATCH repos/o/r/issues/[0-9]* {"state":"closed"' "$GH_LOG")" "2"
t "a bare mention (#44) is not closed"           "$(grep -c 'issues/44' "$GH_LOG")" "0"

# ── #379: an effort/* head is refused — the squash would destroy the per-sub trace ───────────────
: > "$GH_LOG"; GH_BASE="develop"; GH_HEAD="effort/5-e"
kto_task_pr_merge 14 >/dev/null 2>"$tmp/err14"; rc=$?
t "an effort head is refused (rc 1)"             "$rc" "1"
t "the refusal names cckit effort close 5"       "$(grep -c 'cckit effort close 5' "$tmp/err14")" "1"
t "nothing was merged on the effort refusal"     "$(merged "")" "0"
t "the refused effort branch survives"           "$(git branch --list effort/5-e | tr -d ' *+')" "effort/5-e"
( cd "$ewt" && kto_task_pr_merge ) >/dev/null 2>&1; rc=$?
t "refused from the effort worktree too (rc 1)"  "$rc" "1"
t "still nothing merged"                         "$(merged "")" "0"
: > "$GH_LOG"
KIT_FORCE=1 kto_task_pr_merge 14 >/dev/null 2>"$tmp/err14f"; rc=$?
t "KIT_FORCE=1 merges the effort head (rc 0)"    "$rc" "0"
t "KIT_FORCE=1 warns about the lost trace"       "$(grep -c 'KIT_FORCE=1' "$tmp/err14f")" "1"
t "KIT_FORCE=1 reaches the merge"                "$(merged 14)" "1"
t "no gh subcommand ran"                         "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"

# ── #592: a CONFLICTING PR is brought onto its base by merge and pushed plain, never rebased ─────
git checkout -q develop
GH_BASE="develop"; GH_MERGEABLE="false"; GH_HEAD="fix/30-x"
cwt="$tmp/work/.claude/worktrees/fix+30-x"
git worktree add -q -b fix/30-x "$cwt" develop
git -C "$cwt" commit -q --allow-empty -m "branch work"
git -C "$cwt" push -q origin fix/30-x
own="$(git -C "$cwt" rev-parse HEAD)"
git clone -q "$tmp/remote.git" "$tmp/gh-side2" 2>/dev/null
git -C "$tmp/gh-side2" checkout -q develop
git -C "$tmp/gh-side2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "base moved"
git -C "$tmp/gh-side2" push -q origin develop
basetip="$(git -C "$tmp/gh-side2" rev-parse HEAD)"
# a fake git on PATH records every push so the test can assert none carries --force*
mkdir -p "$tmp/gitwrap"; real_git="$(command -v git)"
printf '#!/usr/bin/env bash\ncase "$*" in *push*--delete*) ;; *push*) echo "$*" >> "%s/git-pushes.log"; "%s" rev-parse HEAD > "%s/pushed-head" ;; esac\nexec "%s" "$@"\n' "$tmp" "$real_git" "$tmp" "$real_git" > "$tmp/gitwrap/git"
chmod +x "$tmp/gitwrap/git"; : > "$tmp/git-pushes.log"
: > "$GH_LOG"
( cd "$cwt" && PATH="$tmp/gitwrap:$PATH" kto_task_pr_merge 30 ) >/dev/null 2>"$tmp/err30"; rc=$?
t "a conflicting PR from its own worktree merges (rc 0)" "$rc" "0"
t "the PR was merged"                                    "$(merged 30)" "1"
t "origin/develop was merged into the branch, then pushed" "$(git -C "$tmp/remote.git" merge-base --is-ancestor "$basetip" "$(cat "$tmp/pushed-head")" 2>/dev/null && echo yes || echo no)" "yes"
t "the branch's own commit was kept, not rewritten"      "$(git -C "$tmp/remote.git" merge-base --is-ancestor "$own" "$(cat "$tmp/pushed-head")" 2>/dev/null && echo yes || echo no)" "yes"
t "the push was plain"                                   "$(grep -c 'push origin fix/30-x$' "$tmp/git-pushes.log")" "1"
t "no push carried --force or --force-with-lease"        "$(grep -cE -- '--force|[[:space:]]-f([[:space:]]|$)' "$tmp/git-pushes.log")" "0"

# a merge that conflicts is aborted and the user is told to resolve it with a merge
git checkout -q develop
git pull -q origin develop 2>/dev/null
cwt2="$tmp/work/.claude/worktrees/fix+31-x"
git worktree add -q -b fix/31-x "$cwt2" develop
echo mine > "$cwt2/clash.txt"; git -C "$cwt2" add clash.txt; git -C "$cwt2" commit -q -m "mine"
git -C "$cwt2" push -q origin fix/31-x
echo theirs > "$tmp/gh-side2/clash.txt"; git -C "$tmp/gh-side2" pull -q origin develop 2>/dev/null
git -C "$tmp/gh-side2" add clash.txt; git -C "$tmp/gh-side2" -c user.email=t@t -c user.name=t commit -q -m "theirs"
git -C "$tmp/gh-side2" push -q origin develop
: > "$GH_LOG"; GH_HEAD="fix/31-x"
( cd "$cwt2" && kto_task_pr_merge 31 ) >/dev/null 2>"$tmp/err31"; rc=$?
t "a textual conflict is refused (rc 1)"                 "$rc" "1"
t "nothing was merged"                                   "$(merged "")" "0"
t "the merge was aborted (no MERGE_HEAD)"                "$(git -C "$cwt2" rev-parse -q --verify MERGE_HEAD >/dev/null && echo present || echo gone)" "gone"
t "the user is told to merge the base in"                "$(grep -c 'git merge origin/develop' "$tmp/err31")" "1"
t "the branch on origin was not rewritten"               "$(git ls-remote origin fix/31-x | cut -f1)" "$(git -C "$cwt2" rev-parse HEAD)"

[ "$fail" -eq 0 ] && echo "kto-task-pr-merge: all passed" || echo "kto-task-pr-merge: FAILURES"
exit "$fail"
