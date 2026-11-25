#!/bin/sh
# worktree-issue-test.sh — self-test for worktree-issue.sh under bash AND zsh (#307).
# The lib is sourced into whatever shell the session runs (zsh on macOS), so the
# parsing must behave identically in both. Run:  bash lib/core/worktree-issue-test.sh
#
# Without args: re-runs itself under every available shell. With WT_TEST_INNER set:
# runs the assertions in the current interpreter.
# errors: strict — a test runner: rc 1 on any failed assertion

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
  check "sub/1604a-parser"                         "1604"  # effort sub form <N><letter>
  check "sub/1283m-x"                              "1283"  # effort sub, later letter
  check "sub+1604a-parser"                         "1604"  # effort sub worktree dirname
  check "sub/1604a4-x"                             ""      # letter not trailing
  check "sub/16a04-x"                              ""      # letter embedded mid-number
  check "sub/1604A-x"                              ""      # uppercase suffix is not the sub form
  check "sub/a-x"                                  ""      # letter with no number
  # The <N><letter> suffix is accepted for EVERY lowercase kind, not just `sub`. Deliberate: a
  # spurious association can only ever ADD issue-open protection (an unrelated #N is either open
  # → keep, or closed/absent → no claim), never remove it. Narrowing this to `sub` would make gc
  # willing to delete a misnamed live branch — the failure mode this whole lib exists to prevent.
  check "feat/1604a-parser"                        "1604"  # non-sub kind, suffix still protects
  check "feat+1604a-parser"                        "1604"  # same, worktree dirname form
  # wt_issue_state (#330): failed is not empty. The forge (test-forge-shim.sh) answers the REST read
  # of repos/<r>/issues/<n>: an HTTP error answers `unknown`; a 404 ("no such issue") answers empty;
  # only open/closed pass through. With no forge configured the state is `unknown`.
  tmp=$(mktemp -d)
  . "$dir/../forge/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
  GH_LOG="$tmp/gh.log"; export GH_LOG; : > "$GH_LOG"
  export GH_TOKEN=test-token CCKIT_FORGE=github
  state() {   # state <label> <want> <fixture snippet: sets out/code for the shim> [GH_CLOSED] [GH_FAIL_EP]
    printf '%s\n' "$3" > "$tmp/fixture"
    got=$(PATH="$tmp/bin:$PATH" GH_FIXTURE="$tmp/fixture" GH_CLOSED="${4:-}" GH_FAIL_EP="${5:-}" KIT_REPO=o/r wt_issue_state 41 o/r)
    if [ "$got" != "$2" ]; then
      echo "FAIL($WT_TEST_INNER): wt_issue_state $1 -> '[$got]', want '[$2]'"
      fail=1
    fi
  }
  state "open"                  "open"    ':'
  state "closed"                "closed"  ':' 41
  state "rate limit (403)"      "unknown" 'out='"'"'{"message":"API rate limit exceeded"}'"'"'; code=403'
  state "server error (502)"    "unknown" 'out='"'"'{"message":"Server Error"}'"'"'; code=502'
  state "no such issue (404)"   ""        ':' "" "repos/o/r/issues/41"
  state "empty success"         ""        'out=""'
  t_=$(grep -c '^GET repos/o/r/issues/41 ' "$GH_LOG")
  [ "$t_" = "6" ] || { echo "FAIL($WT_TEST_INNER): every state read is GET repos/o/r/issues/41 -> '[$t_]', want '[6]'"; fail=1; }
  t_=$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")
  [ "$t_" = "0" ] || { echo "FAIL($WT_TEST_INNER): no gh subcommand ran -> '[$t_]', want '[0]'"; fail=1; }
  got=$(PATH="$tmp/bin:$PATH" CCKIT_FORGE=none wt_issue_state 41 o/r)
  [ "$got" = "unknown" ] || { echo "FAIL($WT_TEST_INNER): wt_issue_state with no forge -> '[$got]', want '[unknown]'"; fail=1; }
  got=$(PATH="$tmp/bin:$PATH" wt_issue_state "" o/r)
  [ -z "$got" ] || { echo "FAIL($WT_TEST_INNER): wt_issue_state with no number -> '[$got]', want '[]'"; fail=1; }
  # An unknown state is not a protection claim — gc reports it as UNKNOWN itself.
  printf '%s\n' 'out='"'"'{"message":"Server Error"}'"'"'; code=502' > "$tmp/fixture"
  got=$(PATH="$tmp/bin:$PATH" GH_FIXTURE="$tmp/fixture" wt_protected_reason task/41-x o/r)
  [ -z "$got" ] || { echo "FAIL($WT_TEST_INNER): wt_protected_reason on a failed read -> '[$got]', want '[]'"; fail=1; }
  rm -rf "$tmp"
  [ "$fail" -eq 0 ] && echo "OK($WT_TEST_INNER): 33 cases"
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
