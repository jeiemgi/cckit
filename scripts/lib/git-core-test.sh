#!/usr/bin/env bash
# shellcheck shell=bash
# git-core-test.sh — E537.4: the git core stands alone. With PATH stripped of gh and no token, the
# forge provider is none and start, pr, merge, hotfix and gc each either work through git or say,
# once, what they skipped. Nothing is silent and nothing reaches the network: a curl stub on PATH
# fails loudly, so a leaked request is a red test. Hermetic: a bare origin and a clone under mktemp.
# Run: bash scripts/lib/git-core-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$LIB/test-env.sh" && test_env_seal
unset GH_TOKEN GITHUB_TOKEN CCKIT_FORGE CCKIT_VERB KIT_CONFIG
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tools"
# A PATH stripped of gh wherever it lives (Homebrew here, /usr/bin on Ubuntu): one dir of symlinks
# to every executable on the current PATH except gh and curl, and PATH is that dir alone.
_old_ifs="$IFS"; IFS=:
for d in $PATH; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    case "$n" in gh|curl) continue ;; esac
    [ -x "$f" ] && [ ! -e "$tmp/tools/$n" ] && ln -s "$f" "$tmp/tools/$n"
  done
done
IFS="$_old_ifs"
cat > "$tmp/tools/curl" <<'SH'
#!/bin/sh
echo "curl $*" >> "${CURL_LOG:-/dev/null}"; echo "curl stub: a request leaked: $*" >&2; exit 99
SH
chmod +x "$tmp/tools/curl"
export PATH="$tmp/tools" CURL_LOG="$tmp/curl.log"; : > "$CURL_LOG"
command -v jq >/dev/null 2>&1 || { echo "git-core-test: jq not on the stripped PATH ($PATH) — skipping"; exit 0; }
t "gh is not on PATH"                      "$(command -v gh >/dev/null 2>&1 && echo yes || echo no)" "no"

# ── the fixture: a bare origin with develop and main, a clone with the project config ───────────
git init -q --bare "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@t; git config user.name t; git config commit.gpgsign false
git checkout -q -b develop
printf '{"kitVersion":"9.9.9","project":{"name":"fx","slug":"fx"},"github":{"repo":"o/r","owner":"o","baseBranch":"develop","projectsV2":false}}\n' > cckit.config.json
printf '.claude/worktrees/\n.cckit/\n' > .gitignore
echo one > tracked.txt; git add .gitignore cckit.config.json tracked.txt; git commit -q -m init
git push -q origin develop; git branch -q main; git push -q origin main
export KIT_REPO="o/r" WT_START_REPO="o/r" KIT_BASE_BRANCH="develop" KIT_WT_INSTALL=0 KIT_GC_REPO="o/r" KIT_PROJECTS_V2=false

# shellcheck source=/dev/null
. "$LIB/forge.sh"
t "no token and no gh: the provider is none"  "$(forge_provider)" "none"

# shellcheck source=/dev/null
. "$LIB/worktree-start.sh"
# shellcheck source=/dev/null
. "$LIB/kit-task-ops.sh"

# ── start ──────────────────────────────────────────────────────────────────────────────────────
out="$(wt_start 7 the-thing 2>"$tmp/err")"; rc=$?
t "start without a forge: rc 0"               "$rc" "0"
t "start: the branch is task/<N>-<slug>"      "$(printf '%s' "$out" | cut -d'|' -f2)" "task/7-the-thing"
tc "$tmp/err" '^cckit start: no forge — issue #7 is not read; the branch is task/7-the-thing' "start: the one line says what it skipped"
wt="$(printf '%s' "$out" | cut -d'|' -f1)"
t "start: the worktree exists"                "$([ -d "$wt" ] && echo yes || echo no)" "yes"
out2="$(wt_start 8 2>"$tmp/err2")"
t "start with no slug: issue-<N>"             "$(printf '%s' "$out2" | cut -d'|' -f2)" "task/8-issue-8"

# ── pr: commit + push, the pull request is not opened, said once ───────────────────────────────
echo two > "$wt/tracked.txt"
out="$(cd "$wt" && kto_task_pr 7 "fix: do the thing" 2>"$tmp/err")"; rc=$?
t "pr without a forge: rc 0"                  "$rc" "0"
t "pr: the change is committed"               "$(git -C "$wt" log -1 --format=%s)" "fix: do the thing"
t "pr: the branch is pushed"                  "$(git ls-remote --heads origin task/7-the-thing | wc -l | tr -d ' ')" "1"
tc "$tmp/err" '^cckit pr: no forge — issue #7 is not read and the pull request is not opened' "pr: the one line says what it skipped"
t "pr: says the pull request is to be opened by hand (origin is not on GitHub)" \
  "$(printf '%s' "$out" | grep -c 'pushed task/7-the-thing (no forge: open the pull request on your forge, task/7-the-thing → develop)')" "1"
# the compare page, when origin is on GitHub
git init -q "$tmp/ghrepo"; git -C "$tmp/ghrepo" remote add origin https://github.com/o/r.git
t "the compare page for a GitHub origin"      "$(forge_compare_url develop fix/1-x "$tmp/ghrepo")" "https://github.com/o/r/compare/develop...fix/1-x"
t "no compare page for a local origin"        "$(forge_compare_url develop fix/1-x "$tmp/work" 2>/dev/null; echo "rc=$?")" "rc=1"

# ── merge: through git onto the base, pushed, cleaned up ──────────────────────────────────────
out="$(cd "$wt" && kto_task_pr_merge 2>"$tmp/err")"; rc=$?
t "merge without a forge: rc 0"               "$rc" "0"
tc "$tmp/err" '^cckit merge: no forge — the branch lands on develop through git; no pull request is merged and no issue is closed' "merge: the one line says what it skipped"
t "merge: develop on origin carries the squash commit" "$(git -C "$tmp/work" log -1 --format=%s origin/develop)" "fix: do the thing"
t "merge: one commit landed (a squash)"       "$(git -C "$tmp/work" rev-list --count origin/develop)" "2"
t "merge: the worktree is removed"            "$([ -d "$wt" ] && echo present || echo gone)" "gone"
t "merge: the local branch is deleted"        "$(git -C "$tmp/work" branch --list task/7-the-thing | wc -l | tr -d ' ')" "0"
t "merge: the remote branch is deleted"       "$(git ls-remote --heads origin task/7-the-thing | wc -l | tr -d ' ')" "0"
t "merge: the main checkout is on develop, current" "$(git -C "$tmp/work" rev-parse --abbrev-ref HEAD) $(git -C "$tmp/work" rev-parse HEAD | cut -c1-7)" "develop $(git -C "$tmp/work" rev-parse origin/develop | cut -c1-7)"
tc <(printf '%s' "$out") 'merged into develop \(squash\) and pushed' "merge: says what it did"
( cd "$tmp/work" && kto_task_pr_merge 12 ) >/dev/null 2>"$tmp/err"; rc=$?
t "merge <pr> without a forge is refused"     "$rc" "1"
tc "$tmp/err" 'a pull request number cannot be read' "merge <pr>: the refusal names the reason"
( cd "$tmp/work" && kto_task_pr_merge ) >/dev/null 2>"$tmp/err"; rc=$?
t "merge from the base branch is refused"     "$rc" "1"

# ── hotfix: the cherry-pick lands on main and is pushed; no pull request ──────────────────────
# shellcheck source=/dev/null
. "$LIB/kit-hotfix.sh"
sha="$(git -C "$tmp/work" rev-parse origin/develop)"
out="$(cd "$tmp/work" && kto_hotfix "$sha" --base main 2>"$tmp/err")"; rc=$?
t "hotfix without a forge: rc 0"              "$rc" "0"
tc "$tmp/err" '^cckit hotfix: no forge — the pull request is not opened; fix/hotfix-[0-9a-f]{7}-main is pushed' "hotfix: the one line says what it skipped"
t "hotfix: the branch is on origin"           "$(git ls-remote --heads origin 'fix/hotfix-*-main' | wc -l | tr -d ' ')" "1"
tc <(printf '%s' "$out") '^✓ pushed fix/hotfix-[0-9a-f]{7}-main \(no forge: open the pull request on your forge' "hotfix: says the pull request is to be opened by hand"
( cd "$tmp/work" && kto_hotfix 12 --base main ) >/dev/null 2>"$tmp/err"; rc=$?
t "hotfix <pr> without a forge is refused"    "$rc" "1"
tc "$tmp/err" 'PR #12 cannot be read; pass the merge commit' "hotfix <pr>: the refusal names the alternative"

# ── gc: every row UNKNOWN and kept; the note is printed once ──────────────────────────────────
# shellcheck source=/dev/null
. "$LIB/kit-gc.sh"
out="$(cd "$tmp/work" && unset _FORGE_NONE_SAID && kit_gc_analyze 2>"$tmp/err")"
t "gc: the leftover issue branch is UNKNOWN, kept" "$(printf '%s\n' "$out" | grep -c 'task/8-issue-8 .*UNKNOWN')" "1"
t "gc: nothing is SAFE or LANDED"             "$(printf '%s\n' "$out" | grep -cE 'task/8-issue-8 .*(SAFE|LANDED)')" "0"
t "gc: the no-forge note is printed once"     "$(grep -c '^cckit gc: no forge — ' "$tmp/err")" "1"

# ── nothing reached the network ───────────────────────────────────────────────────────────────
t "no request left the machine"               "$(wc -l < "$CURL_LOG" | tr -d ' ')" "0"

[ "$fail" -eq 0 ] && echo "ALL OK (git-core)"
exit "$fail"
