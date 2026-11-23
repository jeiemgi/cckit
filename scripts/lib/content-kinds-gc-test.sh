#!/usr/bin/env bash
# shellcheck shell=bash
# content-kinds-gc-test.sh — a live branch of every content kind keeps its gc protection (#417).
#
# A content kind (post, campaign, brand, research) is a `kind:` label value that maps onto a branch
# prefix of the closed set. This test follows one issue of each kind from the label to the gc
# report: the branch `cckit start` would cut parses to the issue number, and while that issue is
# OPEN `cckit gc` reports the branch PROTECTED — even when the branch's own PR has MERGED, the case
# in which an unprotected branch is offered as SAFE to delete.
# Hermetic: a throwaway git repo under mktemp, the forge shim (test-forge-shim.sh) on PATH, no network.
# Run:  bash scripts/lib/content-kinds-gc-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v git >/dev/null 2>&1 || { echo "content-kinds-gc-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# shellcheck source=/dev/null
source "$LIB/kinds.sh"
# shellcheck source=/dev/null
source "$LIB/worktree-issue.sh"
# shellcheck source=/dev/null
source "$LIB/worktree-start.sh"

cd "$tmp" || exit 1
git init -q repo
cd repo || exit 1
git config user.email t@t; git config user.name t
echo base > base.txt; git add base.txt; git commit -q -m init

# One issue per content kind: 41 post · 42 campaign · 43 brand · 44 research. Issue 45 is CLOSED,
# the control: its branch must NOT be protected, or the assertions below prove nothing.
n=41; branches=""; pr_json=""
for k in $KIT_CONTENT_KINDS; do
  prefix="$(_wt_kind_prefix "$k" 2>/dev/null)"
  kit_kind_valid "$prefix"; t "kind:$k starts on a prefix of the closed set ($prefix/)" "$?" "0"
  b="$prefix/$n-$k-piece"
  t "branch $b parses to issue $n" "$(wt_issue_number "$b")" "$n"
  git branch "$b" >/dev/null 2>&1
  branches="$branches $b"
  pr_json="$pr_json${pr_json:+,}{\"number\":$((n + 100)),\"head\":{\"ref\":\"$b\"},\"state\":\"closed\",\"merged_at\":\"2026-01-01T00:00:00Z\"}"
  n=$((n + 1))
done
t "four content kinds were exercised" "$(printf '%s\n' $branches | grep -c .)" "4"
git branch task/45-closed-piece >/dev/null 2>&1
pr_json="$pr_json,{\"number\":145,\"head\":{\"ref\":\"task/45-closed-piece\"},\"state\":\"closed\",\"merged_at\":\"2026-01-01T00:00:00Z\"}"

# The forge shim (test-forge-shim.sh) stands in for GitHub: issue 45 is closed, every other issue
# open; the PR list (GET repos/o/r/pulls) carries one MERGED PR per branch, from a fixture.
# shellcheck source=/dev/null
. "$LIB/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export PATH="$tmp/bin:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github
export GH_LOG="$tmp/gh.log" GH_CLOSED="45" GH_FIXTURE="$tmp/fixture"
: > "$GH_LOG"
printf '[%s]' "$pr_json" > "$tmp/pulls.json"
cat > "$GH_FIXTURE" <<FIX
case "\$method \$ep" in "GET repos/o/r/pulls") out="\$(cat '$tmp/pulls.json')" ;; esac
FIX

for b in $branches; do
  reason="$(wt_protected_reason "$b" "o/r")"
  t "wt_protected_reason keeps $b" "$reason" "issue #$(wt_issue_number "$b") still OPEN"
done
t "the closed issue's branch is not protected" "$(wt_protected_reason task/45-closed-piece "o/r")" ""
t "each protection read is GET repos/o/r/issues/<n>" "$(grep -c '^GET repos/o/r/issues/4[1-5] ' "$GH_LOG")" "5"

# The gc report itself: each live content branch is in the protected bucket, none in the safe one.
# shellcheck source=/dev/null
source "$LIB/kit-gc.sh"
: > "$GH_LOG"
analysis="$(KIT_GC_REPO="o/r" kit_gc_analyze 2>/dev/null)"
t "gc reads the PR list once, over REST" "$(grep -c '^GET repos/o/r/pulls?state=all&per_page=100 ' "$GH_LOG")" "1"
t "no gh subcommand ran" "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"
for b in $branches; do
  row="$(printf '%s\n' "$analysis" | grep -F "$b" | sed -n 1p)"
  case "$row" in
    *PROTECTED*|*"still OPEN"*) echo "ok: gc reports $b as protected" ;;
    *) echo "FAIL: gc does not protect $b -> '$row'"; fail=1 ;;
  esac
  case "$row" in *SAFE*) echo "FAIL: gc offers $b as SAFE -> '$row'"; fail=1 ;; esac
done
row="$(printf '%s\n' "$analysis" | grep -F "task/45-closed-piece" | sed -n 1p)"
case "$row" in *SAFE*) echo "ok: the control branch (closed issue, merged PR) is SAFE" ;; *) echo "FAIL: control branch not SAFE -> '$row'"; fail=1 ;; esac

[ "$fail" -eq 0 ] && echo "ALL OK (content kinds gc)" || echo "content kinds gc: FAILURES"
exit "$fail"
