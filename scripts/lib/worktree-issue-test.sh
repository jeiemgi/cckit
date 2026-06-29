#!/bin/sh
# worktree-issue-test.sh — self-test for worktree-issue.sh under bash AND zsh (#307).
# The lib is sourced into whatever shell the session runs (zsh on macOS), so the
# parsing must behave identically in both. Run:  bash scripts/lib/worktree-issue-test.sh
#
# Without args: re-runs itself under every available shell. With WT_TEST_INNER set:
# runs the assertions in the current interpreter.

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${WT_TEST_INNER:-}" ]; then
  . "$dir/worktree-issue.sh"
  fail=0
  check() {
    got=$(wt_issue_number "$1")
    if [ "$got" != "$2" ]; then
      echo "FAIL($WT_TEST_INNER): wt_issue_number '$1' -> '[$got]', want '[$2]'"
      fail=1
    fi
  }
  check "task/293-mobbin"                          "293"   # branch
  check "feat/46-roadmap-view"                     "46"    # branch
  check "fix/305-session-registry-phantom"         "305"   # branch
  check ".claude/worktrees/task+293-mobbin"        "293"   # worktree path
  check "task+293-mobbin"                          "293"   # worktree dirname
  check "/abs/path/.claude/worktrees/plan+266-ui"  "266"   # absolute worktree path
  check "agent/foo"                                ""      # bot branch — no number
  check "claude/issue-42"                          ""      # bot branch — slug not kind/N-
  check "develop"                                  ""      # base branch
  check "main"                                     ""      # base branch
  check "task/29a3-x"                              ""      # malformed number
  check "task/293mobbin"                           ""      # missing dash
  [ "$fail" -eq 0 ] && echo "OK($WT_TEST_INNER): 12 cases"
  exit "$fail"
fi

rc=0
ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=1
  WT_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
[ "$ran" -eq 1 ] || { echo "no bash/zsh found"; exit 1; }
exit "$rc"
