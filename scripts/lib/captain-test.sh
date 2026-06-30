#!/bin/sh
# captain-test.sh — self-test for captain.sh pure gate policy under bash AND zsh.
# Network-free: covers cap_checks_summary / cap_classify / cap_action and the branch parser only
# (the gh-driven captain_gate/pass/loop are not exercised).
# Run:  bash scripts/lib/captain-test.sh

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${CAP_TEST_INNER:-}" ]; then
  . "$dir/captain.sh"
  fail=0
  eq() { if [ "$2" != "$3" ]; then echo "FAIL($CAP_TEST_INNER): $1 -> '[$2]', want '[$3]'"; fail=1; fi; }

  # cap_checks_summary — worst-first precedence over a rollup JSON array.
  eq "checks fail wins"  "$(printf '[{"conclusion":"SUCCESS"},{"conclusion":"FAILURE"}]' | cap_checks_summary)" "FAIL"
  eq "checks pending"    "$(printf '[{"conclusion":"SUCCESS"},{"status":"IN_PROGRESS","conclusion":null}]' | cap_checks_summary)" "PENDING"
  eq "checks pass"       "$(printf '[{"conclusion":"SUCCESS"},{"conclusion":"SKIPPED"}]' | cap_checks_summary)" "PASS"
  eq "checks none"       "$(printf '[]' | cap_checks_summary)" "NONE"
  eq "checks empty-concl pending" "$(printf '[{"conclusion":""}]' | cap_checks_summary)" "PENDING"

  # cap_classify — the verdict matrix.
  eq "clean"             "$(cap_classify MERGEABLE CLEAN PASS)"        "CLEAN"
  eq "clean no checks"   "$(cap_classify MERGEABLE CLEAN NONE)"        "CLEAN"
  eq "unstable+pass"     "$(cap_classify MERGEABLE UNSTABLE PASS)"     "CLEAN"
  eq "conflicting flag"  "$(cap_classify CONFLICTING BLOCKED PASS)"    "CONFLICTING"
  eq "dirty is conflict" "$(cap_classify UNKNOWN DIRTY PASS)"          "CONFLICTING"
  eq "checks failing"    "$(cap_classify MERGEABLE UNSTABLE FAIL)"     "CHECKS_FAILING"
  eq "checks pending"    "$(cap_classify MERGEABLE UNSTABLE PENDING)"  "CHECKS_PENDING"
  eq "draft first"       "$(cap_classify MERGEABLE DRAFT PASS)"        "DRAFT"
  eq "blocked fallback"  "$(cap_classify UNKNOWN BLOCKED PASS)"        "BLOCKED"
  # failing checks must not be hidden even when mergeable says MERGEABLE.
  eq "fail beats mergeable" "$(cap_classify MERGEABLE CLEAN FAIL)"     "CHECKS_FAILING"

  # cap_action — verdict -> action.
  eq "act clean"         "$(cap_action CLEAN)"          "merge"
  eq "act conflicting"   "$(cap_action CONFLICTING)"    "rebase"
  eq "act failing"       "$(cap_action CHECKS_FAILING)" "fix"
  eq "act pending"       "$(cap_action CHECKS_PENDING)" "wait"
  eq "act draft"         "$(cap_action DRAFT)"          "wait"
  eq "act blocked"       "$(cap_action BLOCKED)"        "skip"

  # _cap_issue_of_branch — pull the issue number out of a flow branch.
  eq "branch task"       "$(_cap_issue_of_branch 'task/47-admin-clerk')" "47"
  eq "branch fix"        "$(_cap_issue_of_branch 'fix/9-roadmap')"        "9"
  eq "branch effort"     "$(_cap_issue_of_branch 'effort/123-copilot')"   "123"
  eq "branch plain"      "$(_cap_issue_of_branch 'main')"                 ""

  if [ "$fail" -eq 0 ]; then echo "PASS($CAP_TEST_INNER): captain gate policy"; fi
  exit "$fail"
fi

# Outer: re-run under each available shell.
rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  CAP_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
