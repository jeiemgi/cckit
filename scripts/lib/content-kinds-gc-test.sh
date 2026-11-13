#!/usr/bin/env bash
# shellcheck shell=bash
# content-kinds-gc-test.sh — a live branch of every content kind keeps its gc protection (#417).
#
# A content kind (post, campaign, brand, research) is a `kind:` label value that maps onto a branch
# prefix of the closed set. This test follows one issue of each kind from the label to the gc
# report: the branch `cckit start` would cut parses to the issue number, and while that issue is
# OPEN `cckit gc` reports the branch PROTECTED — even when the branch's own PR has MERGED, the case
# in which an unprotected branch is offered as SAFE to delete.
# Hermetic: a throwaway git repo under mktemp, gh stubbed on PATH, no network.
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
n=41; branches=""; pr_rows=""
for k in $KIT_CONTENT_KINDS; do
  prefix="$(_wt_kind_prefix "$k" 2>/dev/null)"
  kit_kind_valid "$prefix"; t "kind:$k starts on a prefix of the closed set ($prefix/)" "$?" "0"
  b="$prefix/$n-$k-piece"
  t "branch $b parses to issue $n" "$(wt_issue_number "$b")" "$n"
  git branch "$b" >/dev/null 2>&1
  branches="$branches $b"
  pr_rows="$pr_rows$b	PR#$((n + 100)) MERGED
"
  n=$((n + 1))
done
t "four content kinds were exercised" "$(printf '%s\n' $branches | grep -c .)" "4"
git branch task/45-closed-piece >/dev/null 2>&1
pr_rows="${pr_rows}task/45-closed-piece	PR#145 MERGED
"

stub="$tmp/ghbin"; mkdir -p "$stub"
printf '%s' "$pr_rows" > "$tmp/pr-rows"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") cat "$PR_ROWS" ;;
  "issue view") case "$3" in 45) echo "closed" ;; *) echo "open" ;; esac ;;
  *) : ;;
esac
SH
chmod +x "$stub/gh"
export PR_ROWS="$tmp/pr-rows"

for b in $branches; do
  reason="$(PATH="$stub:$PATH" wt_protected_reason "$b" "o/r")"
  t "wt_protected_reason keeps $b" "$reason" "issue #$(wt_issue_number "$b") still OPEN"
done
t "the closed issue's branch is not protected" "$(PATH="$stub:$PATH" wt_protected_reason task/45-closed-piece "o/r")" ""

# The gc report itself: each live content branch is in the protected bucket, none in the safe one.
# shellcheck source=/dev/null
source "$LIB/kit-gc.sh"
analysis="$(PATH="$stub:$PATH" KIT_GC_REPO="o/r" kit_gc_analyze 2>/dev/null)"
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
