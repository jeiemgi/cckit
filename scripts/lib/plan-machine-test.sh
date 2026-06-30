#!/bin/sh
# plan-machine-test.sh — self-test for plan-machine.sh pure helpers under bash AND zsh.
# Network-free: covers the wave layering, session/file packer, and file-hint parser only
# (the gh-calling plan_machine orchestration is not exercised).
# Run:  bash scripts/lib/plan-machine-test.sh

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
TAB=$(printf '\t')

if [ -n "${PM_TEST_INNER:-}" ]; then
  . "$dir/plan-machine.sh"
  fail=0
  eq() { # <label> <got> <want>
    if [ "$2" != "$3" ]; then echo "FAIL($PM_TEST_INNER): $1 -> '[$2]', want '[$3]'"; fail=1; fi
  }

  # _pm_weight
  eq "weight S"  "$(_pm_weight S)"  "1"
  eq "weight XL" "$(_pm_weight XL)" "8"
  eq "weight ?"  "$(_pm_weight '')" "2"

  # pm_waves: linear chain 3<-2<-1 (1 blocks 2 blocks 3) -> waves 0,1,2.
  chain="$(printf '1\t\n2\t1\n3\t2\n' | pm_waves)"
  eq "chain wave of 1" "$(printf '%s\n' "$chain" | awk -F"$TAB" '$1==1{print $2}')" "0"
  eq "chain wave of 2" "$(printf '%s\n' "$chain" | awk -F"$TAB" '$1==2{print $2}')" "1"
  eq "chain wave of 3" "$(printf '%s\n' "$chain" | awk -F"$TAB" '$1==3{print $2}')" "2"

  # pm_waves: diamond 1 -> {2,3} -> 4. 2 and 3 share wave 1; 4 in wave 2.
  dia="$(printf '1\t\n2\t1\n3\t1\n4\t2,3\n' | pm_waves)"
  eq "diamond 2==3 wave" \
    "$(printf '%s\n' "$dia" | awk -F"$TAB" '$1==2{print $2}')$(printf '%s\n' "$dia" | awk -F"$TAB" '$1==3{print $2}')" "11"
  eq "diamond wave of 4" "$(printf '%s\n' "$dia" | awk -F"$TAB" '$1==4{print $2}')" "2"

  # pm_waves: out-of-set blocker (99 absent) is ignored -> node 5 still wave 0.
  oos="$(printf '5\t99\n' | pm_waves)"
  eq "out-of-set blocker ignored" "$(printf '%s\n' "$oos" | awk -F"$TAB" '$1==5{print $2}')" "0"

  # pm_waves: cycle (1<-2, 2<-1) must terminate, both land in the final wave (no hang, no drop).
  cyc="$(printf '1\t2\n2\t1\n' | pm_waves | wc -l | tr -d ' ')"
  eq "cycle emits both rows" "$cyc" "2"

  # pm_batches: budget 4, three M(=2) issues with no file hints -> 2,2 then overflow -> batches 0,0,1.
  pk="$(printf '1\tM\t\n2\tM\t\n3\tM\t\n' | pm_batches 4)"
  eq "pack 1 batch0" "$(printf '%s\n' "$pk" | awk -F"$TAB" '$1==1{print $2}')" "0"
  eq "pack 2 batch0" "$(printf '%s\n' "$pk" | awk -F"$TAB" '$1==2{print $2}')" "0"
  eq "pack 3 batch1" "$(printf '%s\n' "$pk" | awk -F"$TAB" '$1==3{print $2}')" "1"

  # pm_batches: file overlap forces a new batch even under budget.
  fo="$(printf '1\tS\ta.sh\n2\tS\ta.sh\n' | pm_batches 8)"
  eq "overlap splits batch" "$(printf '%s\n' "$fo" | awk -F"$TAB" '$1==2{print $2}')" "1"
  # disjoint files stay in one batch under budget.
  dj="$(printf '1\tS\ta.sh\n2\tS\tb.sh\n' | pm_batches 8)"
  eq "disjoint same batch" "$(printf '%s\n' "$dj" | awk -F"$TAB" '$1==2{print $2}')" "0"

  # _pm_files: pulls a Files:/Touches: line, normalizes separators.
  eq "files hint comma" "$(_pm_files 'intro
Files: a.sh, b.sh
tail')" "a.sh b.sh"
  eq "touches hint"      "$(_pm_files 'Touches:  x/y.ts')" "x/y.ts"
  eq "no hint"           "$(_pm_files 'just prose, no files')" ""

  if [ "$fail" -eq 0 ]; then echo "PASS($PM_TEST_INNER): plan-machine helpers"; fi
  exit "$fail"
fi

# Outer: re-run under each available shell.
rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  PM_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
