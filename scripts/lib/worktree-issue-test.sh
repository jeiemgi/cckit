#!/bin/sh
# worktree-issue-test.sh — self-test for worktree-issue.sh under bash AND zsh (#307).
# The lib is sourced into whatever shell the session runs (zsh on macOS), so the
# parsing must behave identically in both. Run:  bash scripts/lib/worktree-issue-test.sh
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
  # wt_issue_state (#330): failed is not empty. A gh that exits non-zero answers `unknown`; a gh
  # that says "no such issue" answers empty; only open/closed pass through.
  tmp=$(mktemp -d)
  mkdir "$tmp/bin" "$tmp/nogh"
  for c in tr grep head; do p_=$(command -v "$c"); [ -n "$p_" ] && ln -sf "$p_" "$tmp/nogh/$c"; done
  state() {   # state <label> <want> <gh script body> [transport]
    printf '#!/bin/sh\n%s\n' "$3" > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
    got=$(PATH="$tmp/bin:$PATH" CCKIT_GH_TRANSPORT="${4:-graphql}" KIT_REPO=o/r wt_issue_state 41 o/r)
    if [ "$got" != "$2" ]; then
      echo "FAIL($WT_TEST_INNER): wt_issue_state $1 -> '[$got]', want '[$2]'"
      fail=1
    fi
  }
  state "open (graphql)"        "open"    'echo OPEN'
  state "closed (rest)"         "closed"  'echo closed' rest
  state "gh fails (graphql)"    "unknown" 'echo "GraphQL: API rate limit exceeded" >&2; exit 1'
  state "gh fails (rest)"       "unknown" 'echo "gh: Server Error (HTTP 502)" >&2; exit 1' rest
  state "no such issue (gql)"   ""        'echo "GraphQL: Could not resolve to an Issue with the number of 41." >&2; exit 1'
  state "no such issue (rest)"  ""        'echo "gh: Not Found (HTTP 404)" >&2; exit 1' rest
  state "empty success"         ""        'exit 0'
  got=$(PATH="$tmp/nogh" wt_issue_state 41 o/r)
  [ "$got" = "unknown" ] || { echo "FAIL($WT_TEST_INNER): wt_issue_state with no gh -> '[$got]', want '[unknown]'"; fail=1; }
  got=$(PATH="$tmp/bin:$PATH" wt_issue_state "" o/r)
  [ -z "$got" ] || { echo "FAIL($WT_TEST_INNER): wt_issue_state with no number -> '[$got]', want '[]'"; fail=1; }
  # An unknown state is not a protection claim — gc reports it as UNKNOWN itself.
  printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/gh"
  got=$(PATH="$tmp/bin:$PATH" CCKIT_GH_TRANSPORT=graphql wt_protected_reason task/41-x o/r)
  [ -z "$got" ] || { echo "FAIL($WT_TEST_INNER): wt_protected_reason on a failed read -> '[$got]', want '[]'"; fail=1; }
  rm -rf "$tmp"
  [ "$fail" -eq 0 ] && echo "OK($WT_TEST_INNER): 31 cases"
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
