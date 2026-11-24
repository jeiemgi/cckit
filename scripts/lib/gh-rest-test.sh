#!/usr/bin/env bash
# shellcheck shell=bash
# gh-rest-test.sh — the lifecycle verbs over the forge (E537.3; #396 before it). cckit pr, merge,
# close, new, effort new, effort pr and effort close send only REST requests on repos/… endpoints —
# never a gh subcommand, never GraphQL — and in a cloud session every board step is skipped with
# one notice. Hermetic: the shared forge shim (test-forge-shim.sh) answers like the REST API over a
# curl stand-in and logs `METHOD path {json}`; a throwaway repo and a bare remote.
# Run: bash scripts/lib/gh-rest-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$LIB/test-env.sh" && test_env_seal
unset CLAUDE_CODE_REMOTE CCKIT_GH_TRANSPORT
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
command -v jq  >/dev/null 2>&1 || { echo "gh-rest-test: jq required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "gh-rest-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log" GH_N="$tmp/n" GH_CLOSED="" GH_HEAD="fix/9-x" GH_BASE="develop" GH_MERGEABLE="true"
export GH_TITLE="Fix the thing" GH_LABELS='[{"name":"kind:fix"},{"name":"role:tech-lead"}]'
export GH_REPO_LABELS='[{"name":"kind:task"},{"name":"priority:p2"},{"name":"role:tech-lead"}]'
: > "$GH_LOG"

# rest_only <log> <label> — every request in <log> is REST on a repos/ endpoint; no gh subcommand ran.
rest_only() {
  local bad
  bad="$(grep -vE '^(GET|POST|PATCH|PUT|DELETE) repos/' "$1" | sed -n 1,3p)"
  if [ -n "$bad" ]; then echo "FAIL: $2 — non-REST calls: $bad"; fail=1; else echo "ok: $2"; fi
  if grep -q graphql "$1"; then echo "FAIL: $2 — a graphql call was made"; fail=1; fi
}

# shellcheck source=/dev/null
. "$LIB/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export PATH="$tmp/bin:$PATH" KIT_REPO="o/r" EFFORT_REPO="o/r" KIT_BASE_BRANCH="develop" KIT_WT_INSTALL=0
export GH_TOKEN=test-token CCKIT_FORGE=github
unset KIT_CONFIG

# shellcheck source=/dev/null
. "$LIB/gh-rest.sh"

# ── the transport ─────────────────────────────────────────────────────────────────────────────────
t "REST is the only transport"                      "$(cckit_gh_transport)" "rest"
cckit_gh_rest; t "cckit_gh_rest is always true"     "$?" "0"
tc <(CCKIT_GH_TRANSPORT=graphql bash -c '. "$0/gh-rest.sh"; cckit_gh_rest' "$LIB" 2>&1) "CCKIT_GH_TRANSPORT is ignored" "a transport override warns that it does nothing"
t "the board runs locally"                          "$(cckit_board_skipped 2>/dev/null; echo $?)" "1"
t "the board is skipped in a cloud session"         "$(CLAUDE_CODE_REMOTE=true cckit_board_skipped 2>/dev/null; echo $?)" "0"
t "the board is skipped with no forge"              "$(unset _FORGE_LOADED; CCKIT_FORGE=none cckit_board_skipped 2>/dev/null; echo $?)" "0"
t "CCKIT_GRAPHQL=0 skips the board"                 "$(CCKIT_GRAPHQL=0 cckit_board_skipped 2>/dev/null; echo $?)" "0"

# ── pure helpers ──────────────────────────────────────────────────────────────────────────────────
t "closing refs are read from a PR body" \
  "$(printf 'Closes #42\nfixes #43 and resolves #7\nsee #44\nCloses #42\n' | gh_rest_closing_refs | tr '\n' ' ')" "7 42 43 "

# The PR read carries what `cckit hotfix <pr>` needs (#360): the title, and a merge commit only once
# MERGED — the fixture PR is open, and its merge_commit_sha is GitHub's test merge, not a real one.
t "pr json carries the title"                       "$(gh_rest_pr_json o/r 9 | jq -r .title)" "feat: sub 9"
t "an open PR has no merge commit"                  "$(gh_rest_pr_json o/r 9 | jq -r '.mergeCommit.oid // "none"')" "none"

# ── board steps in a cloud session ────────────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(CLAUDE_CODE_REMOTE=true bash -c '
  . "$1/gh-project.sh"
  load_project_ids; echo "rc=$?"
  project_add_item NODE; echo "rc=$?"
  project_set_single_select I F O; echo "rc=$?"
  project_set_text I F T; echo "rc=$?"
  project_find_item_by_issue 5; echo "rc=$?"
  project_issue_status 5; echo "rc=$?"' _ "$LIB" 2>"$tmp/board.err")"
t "every board function returns 0 in rest mode"     "$(printf '%s' "$out" | grep -c '^rc=0$')" "6"
t "the board functions print nothing on stdout"     "$(printf '%s' "$out" | grep -vc '^rc=')" "0"
t "the notice is printed once"                      "$(grep -c 'board step skipped' "$tmp/board.err")" "1"
tc "$tmp/board.err" "^cckit: board step skipped \(GraphQL unavailable; the project's built-in workflows move the card\)$" "the notice wording"
t "no request is made for the board"               "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

# ── the task verbs ────────────────────────────────────────────────────────────────────────────────
git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@t; git config user.name t
git checkout -q -b develop; git commit -q --allow-empty -m init; git push -q origin develop
# shellcheck source=/dev/null
. "$LIB/gh-project.sh"
# shellcheck source=/dev/null
. "$LIB/kit-task-ops.sh"
export KIT_PROJECTS_V2=true CLAUDE_CODE_REMOTE=true

# cckit pr
git checkout -q -b fix/42-the-thing
echo x > a.txt; git add a.txt; git commit -q -m wip
: > "$GH_LOG"
unset _CCKIT_BOARD_NOTICE_DONE; kto_task_pr 42 "Did the thing." >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "pr: rc 0 over REST"                             "$rc" "0"
rest_only "$GH_LOG" "pr: only REST calls"
tc "$GH_LOG" '^GET repos/o/r/issues/42 '            "pr: reads the issue over REST"
tc "$GH_LOG" '^POST repos/o/r/pulls \{"title":"fix: Fix the thing \[#42\]","head":"fix/42-the-thing","base":"develop"' "pr: opens the PR with POST pulls"
tc "$GH_LOG" '^PATCH repos/o/r/issues/7 \{"labels":\["kind:fix","role:tech-lead"\],"assignees":\["me"\],"milestone":3\}' "pr: labels, assignee and milestone in one PATCH"
tc "$tmp/out" 'https://github.com/o/r/pull/7'       "pr: prints the PR url"
t  "pr: the board notice is printed once"           "$(grep -c 'board step skipped' "$tmp/err")" "1"

: > "$GH_LOG"
kto_task_pr 42 "Did the thing." --base main >/dev/null 2>&1; rc=$?
t  "pr --base: rc 0 over REST"                      "$rc" "0"
tc "$GH_LOG" '^POST repos/o/r/pulls \{.*"head":"fix/42-the-thing","base":"main"' "pr --base: the explicit base is sent in POST pulls"

# cckit new
: > "$GH_LOG"
unset _CCKIT_BOARD_NOTICE_DONE; num="$(kto_task_new "Add a thing" tech-lead task p2 M1 "" "" "Body." 2>"$tmp/err" | tail -1)"; rc=$?
t  "new: rc 0 over REST"                            "$rc" "0"
rest_only "$GH_LOG" "new: only REST calls"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"Add a thing".*"labels":\["kind:task","priority:p2","role:tech-lead"\],"milestone":3\}' "new: POST issues with labels and the milestone number"
tc "$GH_LOG" "^POST repos/o/r/issues/$num/assignees \{\"assignees\":\[\"me\"\]\}" "new: assigns the issue to its author"
t  "new: echoes the new number"                     "$num" "50"
t  "new: no 'NOT added to the board' warning"       "$(grep -c 'NOT added' "$tmp/err")" "0"
t  "new: the board notice is printed once"          "$(grep -c 'board step skipped' "$tmp/err")" "1"

# cckit new, a label the repo does not have (#387): a warning, the issue is still created, and the
# label is not sent — POST issues would create it.
: > "$GH_LOG"
unset _CCKIT_BOARD_NOTICE_DONE; kto_task_new "Add a thing" tech-lead feat p2 "" "" "" "Body." >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "new, missing label: rc 0 over REST"             "$rc" "0"
rest_only "$GH_LOG" "new, missing label: only REST calls"
tc "$GH_LOG" '^GET repos/o/r/labels\?per_page=100'        "new, missing label: reads the repo's labels over REST"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"Add a thing".*"labels":\["priority:p2","role:tech-lead"\]' "new, missing label: POST issues with the existing labels only"
t  "new, missing label: kind:feat is not sent"      "$(grep -c 'kind:feat' "$GH_LOG")" "0"
tc "$tmp/out" '^✓ https://github.com/o/r/issues/[0-9]+$' "new, missing label: prints the issue url"
tc "$tmp/err" "label 'kind:feat' not found"         "new, missing label: the warning names kind:feat"
# The label list cannot be read: every label is sent, as before.
: > "$GH_LOG"
GH_FAIL_EP="repos/o/r/labels" kto_task_new "Add a thing" tech-lead feat p2 "" "" "" "Body." >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "new, unreadable label list: rc 0"               "$rc" "0"
tc "$GH_LOG" '^POST repos/o/r/issues \{.*"labels":\["kind:feat","priority:p2","role:tech-lead"\]' "new, unreadable label list: every label is sent"

# cckit close
: > "$GH_LOG"
unset _CCKIT_BOARD_NOTICE_DONE; kto_task_close 5 "Shipped." >/dev/null 2>"$tmp/err"; rc=$?
t  "close: rc 0 over REST"                          "$rc" "0"
rest_only "$GH_LOG" "close: only REST calls"
tc "$GH_LOG" '^POST repos/o/r/issues/5/comments \{"body":"Shipped\."\}$' "close: posts the summary"
tc "$GH_LOG" '^PATCH repos/o/r/issues/5 \{"state":"closed","state_reason":"completed"\}$' "close: state_reason completed"
: > "$GH_LOG"
kto_task_close 6 "Not worth it." --reason not-planned >/dev/null 2>&1
tc "$GH_LOG" '^PATCH repos/o/r/issues/6 \{"state":"closed","state_reason":"not_planned"\}$' "close: not-planned maps to not_planned"
: > "$GH_LOG"
kto_task_close 7 "Same work." --duplicate-of 4 >/dev/null 2>&1
tc "$GH_LOG" '^PATCH repos/o/r/issues/7 \{"state":"closed","state_reason":"duplicate"\}$' "close: duplicate maps to state_reason duplicate"
tc "$GH_LOG" '^POST repos/o/r/issues/7/comments \{"body":"Same work\..*Duplicate of #4\."\}$' "close: the comment links the original"
: > "$GH_LOG"; GH_CLOSED="8"
kto_task_close 8 "x" >/dev/null 2>&1; rc=$?
t  "close: an already-closed issue is fine"         "$rc" "0"
t  "close: it is not closed again"                  "$(grep -c 'PATCH' "$GH_LOG")" "0"
GH_CLOSED=""

# cckit merge — from the PR's worktree, as in the default-mode suite
git checkout -q develop
wt="$tmp/work/.claude/worktrees/fix+9-x"
git worktree add -q -b fix/9-x "$wt" develop
git -C "$wt" commit -q --allow-empty -m "the fix"
git -C "$wt" push -q origin fix/9-x
: > "$GH_LOG"; GH_CLOSED="43"
unset _CCKIT_BOARD_NOTICE_DONE; ( cd "$wt" && kto_task_pr_merge ) >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "merge: rc 0 over REST"                          "$rc" "0"
rest_only "$GH_LOG" "merge: only REST calls"
tc "$GH_LOG" '^GET repos/o/r/pulls\?head=o%3Afix%2F9-x&state=open' "merge: finds the open PR for the branch"
tc "$GH_LOG" '^PUT repos/o/r/pulls/9/merge \{"merge_method":"squash"\}$' "merge: squash-merges with PUT pulls/9/merge"
tc "$GH_LOG" '^PATCH repos/o/r/issues/42 \{"state":"closed","state_reason":"completed"\}$' "merge: closes the linked open issue"
t  "merge: an already-closed linked issue is left"  "$(grep -c 'PATCH repos/o/r/issues/43 ' "$GH_LOG")" "0"
t  "merge: a bare mention is not a closing ref"     "$(grep -c 'issues/44' "$GH_LOG")" "0"
t  "merge: the worktree is removed"                 "$([ -d "$wt" ] && echo present || echo gone)" "gone"
t  "merge: the local branch is deleted"             "$(git branch --list fix/9-x | wc -l | tr -d ' ')" "0"
t  "merge: the remote branch is kept"               "$(git ls-remote --heads origin fix/9-x | wc -l | tr -d ' ')" "1"
tc "$tmp/out" 'remote branch fix/9-x kept'           "merge: says why the remote branch stays"
: > "$GH_LOG"; GH_HEAD="fix/10-x"
kto_task_pr_merge 10 --rebase >/dev/null 2>&1
tc "$GH_LOG" '^PUT repos/o/r/pulls/10/merge \{"merge_method":"rebase"\}$' "merge: --rebase reaches merge_method"
: > "$GH_LOG"; GH_MERGEABLE="false"; GH_HEAD="fix/11-x"
kto_task_pr_merge 11 >/dev/null 2>&1; rc=$?
t  "merge: a conflicting PR from the base is refused" "$rc" "1"
t  "merge: nothing merged on a conflict"            "$(grep -c '/merge' "$GH_LOG")" "0"
GH_MERGEABLE="true"; GH_CLOSED=""; GH_HEAD="fix/9-x"

# ── no gh subcommand, anywhere ────────────────────────────────────────────────────────────────────
t "no gh subcommand ran in the task verbs"          "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"

# ── the effort verbs ──────────────────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$LIB/effort.sh" 2>/dev/null
# shellcheck source=/dev/null
. "$LIB/effort-ops.sh"
GH_TITLE="[Effort] 99 · demo effort"; GH_LABELS='[{"name":"role:tech-lead"},{"name":"kind:task"}]'
export KIT_BASE_BRANCH="main"
# The parent body effort close re-reads (E546.5): a Spec, so the close goes past its check. JSON-escaped.
export GH_BODY='## Goal\nship it\n\n## Spec\n- it ships'


# cckit effort new
: > "$GH_LOG"
unset _CCKIT_BOARD_NOTICE_DONE; parent="$(effort_new --flow Core --spec "it ships" "demo effort" "first sub" "second sub" 2>"$tmp/err")"; rc=$?
t  "effort new: rc 0 over REST"                     "$rc" "0"
rest_only "$GH_LOG" "effort new: only REST calls"
tc "$GH_LOG" '^POST repos/o/r/labels \{"name":"effort",'            "effort new: ensures labels over REST"
tc "$GH_LOG" "^POST repos/o/r/issues \{\"title\":\"demo effort\".*\"labels\":\[\"effort\"" "effort new: POST issues for the parent"
tc "$GH_LOG" "^PATCH repos/o/r/issues/$parent \{\"title\":\"\[E$parent\] demo effort\"\}$" "effort new: renames the parent with its number"
tc "$GH_LOG" "^POST repos/o/r/issues/$parent/labels \{\"labels\":\[\"slug:demo-effort\"\]\}$" "effort new: adds the slug label"
t  "effort new: parent + 2 subs created"            "$(grep -c '^POST repos/o/r/issues ' "$GH_LOG")" "3"
t  "effort new: 2 sub-issues linked"                "$(grep -c 'sub_issues' "$GH_LOG")" "2"

# cckit effort pr + effort close
git checkout -q -b main; git push -q origin main
cd "$tmp/work" || exit 1
effort_start 99 demo >/dev/null 2>&1
ewt="$tmp/work/.claude/worktrees/effort+99-demo"
cd "$ewt" || exit 1
echo work > file.txt; git add file.txt; git commit -q -m "feat: do the thing (#101)"
: > "$GH_LOG"
unset _CCKIT_BOARD_NOTICE_DONE; effort_pr 99 --summary "SUMMARY" >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "effort pr: rc 0 over REST"                      "$rc" "0"
rest_only "$GH_LOG" "effort pr: only REST calls"
tc "$GH_LOG" '^POST repos/o/r/pulls \{"title":"feat: demo effort \[E99\]","head":"effort/99-demo","base":"main"' "effort pr: POST pulls effort/99 → main"
tc "$GH_LOG" '^PATCH repos/o/r/issues/7 \{"labels":\["role:tech-lead","kind:task".*"milestone":3' "effort pr: inherits labels + milestone"
t  "effort pr: the board notice is printed once"    "$(grep -c 'board step skipped' "$tmp/err")" "1"

: > "$GH_LOG"; GH_HEAD="effort/99-demo"; GH_BASE="main"
unset _CCKIT_BOARD_NOTICE_DONE; close_out="$(effort_close 99 2>&1)"; rc=$?
cd "$tmp/work" || exit 1
t  "effort close: rc 0 over REST"                   "$rc" "0"
rest_only "$GH_LOG" "effort close: only REST calls"
tc "$GH_LOG" '^PUT repos/o/r/pulls/9/merge \{"merge_method":"squash"\}$' "effort close: squash-merges over REST"
tc "$GH_LOG" '^PATCH repos/o/r/issues/101 \{"state":"closed","state_reason":"completed"\}$' "effort close: closes sub #101"
tc "$GH_LOG" '^PATCH repos/o/r/issues/99 \{"state":"closed","state_reason":"completed"\}$'  "effort close: closes the parent"
case "$close_out" in *"remote branch effort/99-demo kept"*) echo "ok: effort close: says why the remote branch stays" ;; *) echo "FAIL: effort close: no remote-branch notice: $close_out"; fail=1 ;; esac
t  "effort close: the board notice is printed once" "$(printf '%s\n' "$close_out" | grep -c 'board step skipped')" "1"
t  "effort close: the local branch is deleted"      "$(git branch --list effort/99-demo | wc -l | tr -d ' ')" "0"

# wave-style close: no effort branch, the subs shipped as their own merged PRs
: > "$GH_LOG"
unset _CCKIT_BOARD_NOTICE_DONE; close_out="$(effort_close 77 2>&1)"; rc=$?
t  "wave close: rc 0 over REST"                     "$rc" "0"
rest_only "$GH_LOG" "wave close: only REST calls"
tc "$GH_LOG" '^GET repos/o/r/issues/101/timeline'  "wave close: finds the closing PR in the sub's timeline"
tc "$GH_LOG" '^GET repos/o/r/pulls/5101 $' "wave close: snapshots the closing PR's diff (not the mention)"
tc "$GH_LOG" '^PATCH repos/o/r/issues/77 \{"state":"closed","state_reason":"completed"\}$' "wave close: closes the parent"
t  "wave close: rows match the graphql shape" \
   "$(gh_rest_wave_rows o/r 77 | sed -n 1p)" "101|CLOSED|5101|abc1234def|feat: sub 5101"

# ── a failed REST read is no data, never the error body ───────────────────────────────────────────
export GH_FAIL_EP="repos/o/r/issues/404"
t  "failed read: issue state is empty"              "$(gh_rest_issue_state o/r 404 2>/dev/null)" ""
gh_rest_issue_state o/r 404 >/dev/null 2>&1; rc=$?
t  "failed read: issue state returns non-zero"      "$rc" "1"
t  "failed read: issue json is empty"               "$(gh_rest_issue_json o/r 404 2>/dev/null)" ""
export GH_FAIL_EP="repos/o/r/issues/404/timeline"
t  "failed read: closing PRs are empty"             "$(gh_rest_issue_closing_prs o/r 404 2>/dev/null)" ""
export GH_FAIL_EP="repos/o/r/pulls"
t  "failed read: no PR for the head"                "$(gh_rest_pr_for_head o/r fix/1-x 2>/dev/null)" ""
export GH_FAIL_EP="repos/o/r/issues/*/sub_issues"
t  "failed read: no sub-issue numbers"              "$(gh_rest_sub_issue_numbers o/r 1 2>/dev/null)" ""
export GH_FAIL_EP="repos/o/r/issues/102/timeline"
t  "failed read: a sub whose timeline fails has no PR" \
   "$(gh_rest_wave_rows o/r 77 2>/dev/null | sed -n 2p)" "102|CLOSED|||"
: > "$GH_LOG"
effort_close 77 >/dev/null 2>&1; rc=$?
t  "failed read: wave close refuses"                "$rc" "1"
t  "failed read: wave close leaves the parent open" "$(grep -c 'PATCH repos/o/r/issues/77 ' "$GH_LOG")" "0"
export GH_FAIL_EP="repos/o/r/issues/88"
effort_start 88 >/dev/null 2>&1
t  "failed read: effort start falls back to the effort slug" \
   "$(git branch --list 'effort/88-*' | tr -d ' *+')" "effort/88-effort"
unset GH_FAIL_EP

[ "$fail" -eq 0 ] && echo "gh-rest: all passed" || echo "gh-rest: FAILURES"
exit "$fail"
