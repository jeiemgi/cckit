#!/usr/bin/env bash
# shellcheck shell=bash
# kto-hotfix-test.sh — `cckit hotfix <pr|sha> [--base B]` end to end (#360, E537), over the forge
# shim, a throwaway repo and a bare remote: the worktree is cut from origin/<base>, the branch carries
# exactly the source commit's diff, the push exports KIT_PR_BASE, and the PR targets <base> with
# `Cherry-pick of #N` in its body. Covers a merge-commit source, a re-run, and the
# rebase-merged multi-commit PR (every commit carried), a squash of a multi-commit PR (one commit), a
# refusal reported as `--llm` JSON, and the refusals (unmerged PR, unknown sha, missing base,
# conflict). Every GitHub read and write is a REST request on repos/o/r/pulls…; no gh subcommand runs.
# Run: bash lib/verbs/kto-hotfix-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
CCKIT="$(cd "$LIB/../.." && pwd)/bin/cckit"
# shellcheck source=/dev/null
. "$LIB/../core/test-env.sh" && test_env_seal
unset CLAUDE_CODE_REMOTE CCKIT_GH_TRANSPORT
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
tn() { if grep -qE -- "$2" "$1"; then echo "FAIL: $3 (/$2/ in $1)"; fail=1; else echo "ok: $3"; fi; }
command -v jq >/dev/null 2>&1 || { echo "kto-hotfix-test: jq required" >&2; exit 1; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log" GH_SHA="" GH_STATE="MERGED" GH_OPEN_URL="" GH_SUBJECTS="wip"
: > "$GH_LOG"
# shellcheck source=/dev/null
. "$LIB/../forge/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
# The PR fixtures the shim does not know: the source PR (GH_STATE merged or not, its merge commit
# GH_SHA, its commit subjects GH_SUBJECTS one per line oldest first), the open PR for a head
# (GH_OPEN_URL, empty = none), and the PR this verb opens (#77).
export GH_FIXTURE="$tmp/fixture.sh"
cat > "$GH_FIXTURE" <<'SH'
merged="null"; [ "${GH_STATE:-}" = "MERGED" ] && merged='"2026-10-30T00:00:00Z"'
case "$method $ep" in
  "GET repos/o/r/pulls/"*"/commits")
    out="$(printf '%s\n' "${GH_SUBJECTS:-}" | jq -R -s -c '[split("\n")[] | select(length > 0) | {commit: {message: (. + "\n\nbody text")}}]')" ;;
  "GET repos/o/r/pulls/"*)
    out="{\"title\":\"fix: the thing [#11]\",\"mergeable\":null,\"mergeable_state\":\"unknown\",\"base\":{\"ref\":\"develop\"},\"head\":{\"ref\":\"fix/11-x\"},\"body\":\"\",\"state\":\"closed\",\"merged_at\":$merged,\"merge_commit_sha\":\"${GH_SHA:-}\"}" ;;
  "GET repos/o/r/pulls")
    out="[$( [ -n "${GH_OPEN_URL:-}" ] && printf '{"number":77,"html_url":"%s"}' "$GH_OPEN_URL" )]" ;;
  "POST repos/o/r/pulls")
    out='{"number":77,"html_url":"https://github.com/o/r/pull/77","user":{"login":"me"}}' ;;
esac
SH
export GH_TOKEN=test-token CCKIT_FORGE=github
# The PR this verb opens: ONE POST on repos/o/r/pulls whose JSON body carries title, head, base, body.
PR_POST='^POST repos/o/r/pulls \{'
export PATH="$tmp/bin:$PATH" KIT_WT_INSTALL=0

# The fixture: `main` (the release branch) one commit behind `develop`, which carries the fix as a
# squash commit `… (#12)`, a later unrelated commit, and a true merge commit.
git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@t; git config user.name t
cat > cckit.config.json <<'JSON'
{"kitVersion":"0.0.0","project":{"name":"x","slug":"x","owner":"o","language":"en"},"profile":"p",
 "github":{"repo":"o/r","owner":"o","baseBranch":"develop","projectsV2":false}}
JSON
printf 'a\nb\nc\n' > app.txt
git add -A; git commit -q -m init; git branch -M main; git push -q origin main
git checkout -q -b develop
printf 'a\nB\nc\n' > app.txt; git commit -q -am "fix: the thing (#12)"; SRC="$(git rev-parse HEAD)"
echo other > other.txt; git add other.txt; git commit -q -m "feat: unrelated (#13)"
git checkout -q -b side HEAD~1; echo side > side.txt; git add side.txt; git commit -q -m "side work"
git checkout -q develop; git merge -q --no-ff side -m "Merge pull request #14 from o/side"
MERGE="$(git rev-parse HEAD)"
printf 'a\nB\nc\nd\n' > app.txt; git commit -q -am "feat: conflicts with a main-only edit (#15)"; CONF="$(git rev-parse HEAD)"
# PR 20 as a REBASE merge leaves it: its two commits on develop, subjects unchanged, no merge commit.
echo one > r1.txt; git add r1.txt; git commit -q -m "fix: rebased part one"
echo two > r2.txt; git add r2.txt; git commit -q -m "fix: rebased part two"; REB="$(git rev-parse HEAD)"
git push -q origin develop
cat > .git/hooks/pre-push <<SH
#!/usr/bin/env bash
echo "KIT_PR_BASE=\${KIT_PR_BASE:-}" >> "$tmp/prepush.log"
SH
chmod +x .git/hooks/pre-push
: > "$tmp/prepush.log"

# Drop the hotfix branch everywhere, so the next case starts from nothing.
reset_hotfix() {
  git worktree remove --force "$wt"; git branch -q -D fix/12-hotfix-main
  git push -q origin :fix/12-hotfix-main 2>/dev/null; : > "$tmp/prepush.log"
}

# ── <sha> --base main ────────────────────────────────────────────────────────────────────────────
out="$("$CCKIT" hotfix "$SRC" --base main 2>"$tmp/err")"; rc=$?
t  "hotfix <sha> --base main succeeds"            "$rc" "0"
wt="$tmp/work/.claude/worktrees/fix+12-hotfix-main"
t  "the worktree exists"                          "$([ -d "$wt" ] && echo yes || echo no)" "yes"
t  "its branch is fix/12-hotfix-main"             "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" "fix/12-hotfix-main"
t  "the branch is cut from origin/main"           "$(git merge-base origin/main fix/12-hotfix-main)" "$(git rev-parse origin/main)"
t  "one commit on top of origin/main"             "$(git rev-list --count origin/main..fix/12-hotfix-main)" "1"
t  "the branch diff equals the source commit's"   "$(git diff origin/main fix/12-hotfix-main)" "$(git diff "$SRC~1" "$SRC")"
t  "the unrelated develop commit is not carried"  "$(git ls-tree --name-only fix/12-hotfix-main | grep -c '^other.txt$')" "0"
tc <(git log -1 --format=%B fix/12-hotfix-main) "cherry picked from commit $SRC" "cherry-pick -x records the source"
t  "the branch reached the remote"                "$(git -C "$tmp/remote.git" rev-parse fix/12-hotfix-main 2>/dev/null)" "$(git rev-parse fix/12-hotfix-main)"
t  "the pre-push hook sees KIT_PR_BASE=main"      "$(cat "$tmp/prepush.log")" "KIT_PR_BASE=main"
tc "$GH_LOG" "${PR_POST}.*\"head\":\"fix/12-hotfix-main\",\"base\":\"main\"," "the PR targets main from the hotfix branch"
tc "$GH_LOG" "${PR_POST}\"title\":\"fix: the thing\",\"head\"" "titled after the source, squash suffix dropped"
tc "$GH_LOG" 'Cherry-pick of #12'                  "the body says Cherry-pick of #12"
tn "$GH_LOG" 'Closes #'                            "the body closes no issue"
t  "stdout ends with the PR url"                  "$(printf '%s\n' "$out" | tail -1)" "✓ https://github.com/o/r/pull/77"

# ── re-run: nothing is picked twice, and an open PR is reported, not re-created ──────────────────
: > "$GH_LOG"
out="$(GH_OPEN_URL="https://github.com/o/r/pull/77" "$CCKIT" hotfix "$SRC" --base main 2>/dev/null)"; rc=$?
t  "a re-run succeeds"                            "$rc" "0"
t  "…and does not pick the commit twice"          "$(git rev-list --count origin/main..fix/12-hotfix-main)" "1"
tn "$GH_LOG" '^POST repos/o/r/pulls '              "…and opens no second PR"
tc "$GH_LOG" '^GET repos/o/r/pulls\?head=o%3Afix%2F12-hotfix-main&state=open' "…having asked for the open PR of the branch"
t  "…and still reports the url"                   "$(printf '%s\n' "$out" | tail -1)" "✓ https://github.com/o/r/pull/77"

# ── <pr>: the merge commit and title come from GitHub; main is the default base ─────────────────
reset_hotfix
: > "$GH_LOG"
out="$(GH_SHA="$SRC" "$CCKIT" hotfix 12 2>"$tmp/err")"; rc=$?
t  "hotfix <pr> succeeds (default base main)"     "$rc" "0"
tc "$GH_LOG" '^GET repos/o/r/pulls/12 $'           "the source PR is read from GitHub"
t  "the branch diff equals the source commit's"   "$(git diff origin/main fix/12-hotfix-main)" "$(git diff "$SRC~1" "$SRC")"
tc "$GH_LOG" "${PR_POST}\"title\":\"fix: the thing \[#11\]\",\"head\":\"fix/12-hotfix-main\",\"base\":\"main\"," "titled after the source PR"
tc "$GH_LOG" 'Cherry-pick of #12'                  "the body says Cherry-pick of #12"

# --llm: one JSON object carrying the url and the worktree
reset_hotfix
js="$(GH_SHA="$SRC" "$CCKIT" hotfix '#12' --llm 2>/dev/null)"
t  "--llm: ok + url"                              "$(printf '%s' "$js" | jq -r '"\(.ok) \(.url)"' 2>/dev/null)" "true https://github.com/o/r/pull/77"
t  "--llm: the worktree path"                     "$(printf '%s' "$js" | jq -r .worktree 2>/dev/null)" "$wt"

# --llm on a refusal: still one JSON object, ok false, the reason in `detail`
js="$(GH_STATE="OPEN" "$CCKIT" hotfix 99 --llm 2>/dev/null)"; rc=$?
t  "--llm: a refusal exits 1"                     "$rc" "1"
t  "--llm: a refusal reports ok false"            "$(printf '%s' "$js" | jq -r '"\(.verb) \(.ok)"' 2>/dev/null)" "hotfix false"
t  "--llm: …and carries the reason"               "$(printf '%s' "$js" | jq -r .detail 2>/dev/null | grep -c 'not merged')" "1"

# ── the forge is the only transport: REST on repos/…, no gh subcommand, no graphql ───────────────
reset_hotfix
: > "$GH_LOG"
GH_SHA="$SRC" "$CCKIT" hotfix 12 >/dev/null 2>"$tmp/err"; rc=$?
t  "forge: hotfix <pr> succeeds"                  "$rc" "0"
tn "$GH_LOG" '^GH-SUBCOMMAND |graphql'             "forge: no gh subcommand, no graphql call"
t  "forge: every request is REST on repos/"       "$(grep -vE "^(GET|POST|PATCH) repos/o/r/" "$GH_LOG" | sed -n 1p)" ""
tc "$GH_LOG" "${PR_POST}.*\"base\":\"main\","   "forge: the PR is created against main"
tc "$GH_LOG" 'Cherry-pick of #12'                  "forge: the body says Cherry-pick of #12"
t  "forge: the branch diff equals the source's"   "$(git diff origin/main fix/12-hotfix-main)" "$(git diff "$SRC~1" "$SRC")"

# ── a merge commit is picked against its first parent ────────────────────────────────────────────
: > "$GH_LOG"
"$CCKIT" hotfix "$MERGE" --base main >/dev/null 2>"$tmp/err"; rc=$?
t  "a merge-commit source succeeds"               "$rc" "0"
t  "…carrying the merged side's diff"             "$(git diff origin/main fix/14-hotfix-main)" "$(git diff "$MERGE~1" "$MERGE")"
tc "$GH_LOG" 'Cherry-pick of #14'                  "…and the PR number from the merge subject"

# ── a rebase-merged PR: GitHub names only its LAST commit, every one of its commits is carried ───
: > "$GH_LOG"
GH_SHA="$REB" GH_SUBJECTS="$(printf 'fix: rebased part one\nfix: rebased part two')" \
  "$CCKIT" hotfix 20 >/dev/null 2>"$tmp/err"; rc=$?
t  "a rebase-merged PR succeeds"                  "$rc" "0"
tc "$GH_LOG" '^GET repos/o/r/pulls/20/commits\?per_page=100' "…its commits are read over REST"
t  "…carrying both of its commits"                "$(git rev-list --count origin/main..fix/20-hotfix-main 2>/dev/null)" "2"
t  "…whose diff is the whole PR's"                "$(git diff origin/main fix/20-hotfix-main)" "$(git diff "$REB~2" "$REB")"
tc "$tmp/err" 'rebase-merged: carrying its 2 commits' "…and says so"
tc "$GH_LOG" "Source commits.*$(git rev-parse "$REB~1").*$REB" "the body lists both source commits"
git worktree remove --force "$tmp/work/.claude/worktrees/fix+20-hotfix-main"; git branch -q -D fix/20-hotfix-main
git push -q origin :fix/20-hotfix-main 2>/dev/null
# A SQUASH of a multi-commit PR is one commit carrying all of it: the subjects under it are not the PR's.
reset_hotfix
: > "$GH_LOG"
GH_SHA="$SRC" GH_SUBJECTS="$(printf 'wip one\nwip two')" "$CCKIT" hotfix 12 >/dev/null 2>"$tmp/err"; rc=$?
t  "a squashed two-commit PR succeeds"            "$rc" "0"
t  "…as the one squash commit"                    "$(git rev-list --count origin/main..fix/12-hotfix-main)" "1"
tn "$tmp/err" 'rebase-merged'                      "…and is not taken for a rebase merge"
# A PR whose commits cannot be read is refused, not guessed at.
GH_SHA="$SRC" GH_SUBJECTS="" "$CCKIT" hotfix 12 >/dev/null 2>"$tmp/err"; rc=$?
t  "unreadable PR commits are refused"            "$rc" "1"
tc "$tmp/err" 'cannot read the commits'            "…and says why"

# ── a commit with no PR in its subject: named by sha ─────────────────────────────────────────────
: > "$GH_LOG"
SIDE="$(git rev-parse side)"
"$CCKIT" hotfix "$SIDE" --base main >/dev/null 2>"$tmp/err"; rc=$?
t  "a commit with no (#N) succeeds"               "$rc" "0"
short="$(git rev-parse --short=7 "$SIDE")"
t  "…on a branch named by sha"                    "$(git rev-parse --verify --quiet "fix/hotfix-$short-main" >/dev/null && echo yes || echo no)" "yes"
tc "$GH_LOG" "Cherry-pick of $SIDE"                "…and the body names the commit"

# ── refusals: nothing is created ─────────────────────────────────────────────────────────────────
: > "$GH_LOG"
GH_STATE="OPEN" "$CCKIT" hotfix 99 >/dev/null 2>"$tmp/err"; rc=$?
t  "an unmerged PR is refused"                    "$rc" "1"
tc "$tmp/err" 'not merged'                         "…and says why"
t  "…with no branch made"                         "$(git branch --list 'fix/99-*' | wc -l | tr -d ' ')" "0"
"$CCKIT" hotfix deadbeefdeadbeef --base main >/dev/null 2>"$tmp/err"; rc=$?
t  "an unknown sha is refused"                    "$rc" "1"
tc "$tmp/err" 'is not a commit'                    "…and says why"
"$CCKIT" hotfix "$SRC" --base nope >/dev/null 2>"$tmp/err"; rc=$?
t  "a base missing on origin is refused"          "$rc" "1"
tc "$tmp/err" "origin has no branch 'nope'"        "…and says why"
t  "…with no branch made"                         "$(git branch --list 'fix/12-hotfix-nope' | wc -l | tr -d ' ')" "0"
"$CCKIT" hotfix >/dev/null 2>"$tmp/err"; rc=$?
t  "no source is a usage error"                   "$rc" "2"
"$CCKIT" hotfix "$SRC" --base >/dev/null 2>"$tmp/err"; rc=$?
t  "--base with no value is a usage error"        "$rc" "2"
tn "$GH_LOG" '^POST '                              "no refusal opened a PR"

# ── a conflict stops before the push and says how to continue ────────────────────────────────────
git checkout -q -b rel-edit origin/main; printf 'a\nb\nc\nZ\n' > app.txt; git commit -q -am "main-only edit"
git push -q origin rel-edit:rel; git checkout -q develop
: > "$GH_LOG"; : > "$tmp/prepush.log"
"$CCKIT" hotfix "$CONF" --base rel >/dev/null 2>"$tmp/err"; rc=$?
t  "a conflicting pick fails"                     "$rc" "1"
tc "$tmp/err" 'cherry-pick --continue'             "…telling you how to continue"
t  "…without pushing"                             "$(wc -l < "$tmp/prepush.log" | tr -d ' ')" "0"
tn "$GH_LOG" '^POST '                              "…and without opening a PR"
"$CCKIT" hotfix "$CONF" --base rel >/dev/null 2>"$tmp/err"; rc=$?
t  "a re-run mid-conflict is refused"             "$rc" "1"
cwt="$tmp/work/.claude/worktrees/fix+15-hotfix-rel"
printf 'a\nB\nc\nZ\nd\n' > "$cwt/app.txt"; git -C "$cwt" add app.txt
GIT_EDITOR=true git -C "$cwt" cherry-pick --continue >/dev/null 2>&1
"$CCKIT" hotfix "$CONF" --base rel >/dev/null 2>"$tmp/err"; rc=$?
t  "after --continue the re-run finishes"         "$rc" "0"
tc "$GH_LOG" "${PR_POST}.*\"base\":\"rel\","    "…opening the PR against the chosen base"
t  "no gh subcommand ran in the whole run"        "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"

[ "$fail" -eq 0 ] && echo "kto-hotfix: all passed" || echo "kto-hotfix: FAILURES"
exit "$fail"
