#!/bin/sh
# copilot-test.sh — self-test for copilot.sh pure helper under bash AND zsh.
# Network-free: covers the subagent seed composer only (the gh/plan-driven copilot_brief is not
# exercised). Run:  bash scripts/lib/copilot-test.sh

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${CP_TEST_INNER:-}" ]; then
  . "$dir/copilot.sh"
  fail=0
  has() { case "$2" in *"$3"*) ;; *) echo "FAIL($CP_TEST_INNER): $1 missing '[$3]'"; fail=1 ;; esac; }

  seed="$(_copilot_seed 42 'wire the thing')"
  has "seed has issue view"   "$seed" 'gh issue view 42'
  has "seed has title"        "$seed" 'implement "wire the thing"'
  has "seed has pr verb"      "$seed" 'cckit pr 42'
  has "seed has close verb"   "$seed" 'cckit close 42'
  has "seed has check gate"   "$seed" 'bash scripts/check.sh'
  has "seed forbids asking"   "$seed" 'never ask'

  if [ "$fail" -eq 0 ]; then echo "PASS($CP_TEST_INNER): copilot seed composer"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  CP_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
