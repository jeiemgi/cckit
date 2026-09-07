#!/bin/sh
# captain-test.sh — self-test for captain.sh pure gate policy under bash AND zsh.
# Network-free: covers cap_checks_summary / cap_classify / cap_action and the branch parser only
# (the gh-driven captain_gate/pass/loop are not exercised).
# Run:  bash scripts/lib/captain-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

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

  # cap_classify + KIT_CAPTAIN_REQUIRE_CHECKS — an EMPTY rollup (NONE) is an ABSENCE of evidence, not
  # a pass. Default OFF, so the four cases below are the whole contract.
  #
  # 1. OFF (unset AND explicit 0) — behaviour is UNCHANGED. This is the regression assertion: an
  #    empty rollup still reads CLEAN, exactly as before, so no existing repo's captain moves.
  eq "require unset: NONE still CLEAN"  "$(KIT_CAPTAIN_REQUIRE_CHECKS=  cap_classify MERGEABLE CLEAN NONE)"    "CLEAN"
  eq "require 0: NONE still CLEAN"      "$(KIT_CAPTAIN_REQUIRE_CHECKS=0 cap_classify MERGEABLE CLEAN NONE)"    "CLEAN"
  eq "require 0: unstable NONE CLEAN"   "$(KIT_CAPTAIN_REQUIRE_CHECKS=0 cap_classify MERGEABLE UNSTABLE NONE)" "CLEAN"
  # 2. ON — the empty rollup gets its own verdict, distinct from FAILING and PENDING.
  eq "require 1: NONE is missing"       "$(KIT_CAPTAIN_REQUIRE_CHECKS=1 cap_classify MERGEABLE CLEAN NONE)"    "CHECKS_MISSING"
  eq "require true: NONE is missing"    "$(KIT_CAPTAIN_REQUIRE_CHECKS=true cap_classify MERGEABLE CLEAN NONE)" "CHECKS_MISSING"
  eq "require 1: unstable NONE missing" "$(KIT_CAPTAIN_REQUIRE_CHECKS=1 cap_classify MERGEABLE UNSTABLE NONE)" "CHECKS_MISSING"
  # 3. A real rollup is untouched either way — the setting only speaks about the empty case.
  eq "require 1: PASS still CLEAN"      "$(KIT_CAPTAIN_REQUIRE_CHECKS=1 cap_classify MERGEABLE CLEAN PASS)"       "CLEAN"
  eq "require 1: FAIL unaffected"       "$(KIT_CAPTAIN_REQUIRE_CHECKS=1 cap_classify MERGEABLE UNSTABLE FAIL)"    "CHECKS_FAILING"
  eq "require 1: PENDING unaffected"    "$(KIT_CAPTAIN_REQUIRE_CHECKS=1 cap_classify MERGEABLE UNSTABLE PENDING)" "CHECKS_PENDING"
  eq "require 0: FAIL unaffected"       "$(KIT_CAPTAIN_REQUIRE_CHECKS=0 cap_classify MERGEABLE UNSTABLE FAIL)"    "CHECKS_FAILING"
  eq "require 0: PENDING unaffected"    "$(KIT_CAPTAIN_REQUIRE_CHECKS=0 cap_classify MERGEABLE UNSTABLE PENDING)" "CHECKS_PENDING"
  # 4. Only the would-be-CLEAN verdict can change — draft/conflict/blocked keep their own answers
  #    even with the requirement on, so the rest of the vocabulary provably does not move.
  eq "require 1: draft still draft"     "$(KIT_CAPTAIN_REQUIRE_CHECKS=1 cap_classify MERGEABLE DRAFT NONE)"    "DRAFT"
  eq "require 1: conflict still conf"   "$(KIT_CAPTAIN_REQUIRE_CHECKS=1 cap_classify CONFLICTING BLOCKED NONE)" "CONFLICTING"
  eq "require 1: dirty still conflict"  "$(KIT_CAPTAIN_REQUIRE_CHECKS=1 cap_classify UNKNOWN DIRTY NONE)"      "CONFLICTING"
  eq "require 1: blocked still blocked" "$(KIT_CAPTAIN_REQUIRE_CHECKS=1 cap_classify UNKNOWN BLOCKED NONE)"    "BLOCKED"

  # cap_action — verdict -> action.
  eq "act clean"         "$(cap_action CLEAN)"          "merge"
  eq "act conflicting"   "$(cap_action CONFLICTING)"    "rebase"
  eq "act failing"       "$(cap_action CHECKS_FAILING)" "fix"
  eq "act pending"       "$(cap_action CHECKS_PENDING)" "wait"
  eq "act draft"         "$(cap_action DRAFT)"          "wait"
  eq "act held"          "$(cap_action HELD)"           "hold"
  eq "act blocked"       "$(cap_action BLOCKED)"        "skip"
  # the whole point: an unobserved gate must never resolve to merge.
  eq "act missing"       "$(cap_action CHECKS_MISSING)" "verify"

  # cap_policy_floor — floors that block an unattended auto-merge (default ON). Non-empty = held.
  nl="$(printf '\n')"
  eq "floor: clean PR merges"       "$(KIT_CAPTAIN_FLOORS= KIT_CAPTAIN_EXTRA_GLOBS= cap_policy_floor "src/app.ts${nl}README.md" "")" ""
  neq() { if [ -z "$2" ]; then echo "FAIL($CAP_TEST_INNER): $1 -> empty, want non-empty"; fail=1; fi; }
  neq "floor: workflow file held"   "$(KIT_CAPTAIN_FLOORS= cap_policy_floor ".github/workflows/ci.yml" "")"
  neq "floor: pnpm-lock held"       "$(KIT_CAPTAIN_FLOORS= cap_policy_floor "pnpm-lock.yaml" "")"
  neq "floor: package.json held"    "$(KIT_CAPTAIN_FLOORS= cap_policy_floor "apps/web/package.json" "")"
  neq "floor: workspace yaml held"  "$(KIT_CAPTAIN_FLOORS= cap_policy_floor "pnpm-workspace.yaml" "")"
  neq "floor: turbo.json held"      "$(KIT_CAPTAIN_FLOORS= cap_policy_floor "turbo.json" "")"
  neq "floor: pem held"             "$(KIT_CAPTAIN_FLOORS= cap_policy_floor "certs/server.pem" "")"
  neq "floor: dotenv held"          "$(KIT_CAPTAIN_FLOORS= cap_policy_floor ".env.production" "")"
  neq "floor: secrets path held"    "$(KIT_CAPTAIN_FLOORS= cap_policy_floor "config/secrets/db.yml" "")"
  neq "floor: hold label held"      "$(KIT_CAPTAIN_FLOORS= cap_policy_floor "src/app.ts" "priority:p1 hold")"
  neq "floor: extra glob held"      "$(KIT_CAPTAIN_FLOORS= KIT_CAPTAIN_EXTRA_GLOBS='migrations/*' cap_policy_floor "migrations/001.sql" "")"
  # a disabling override lets even a workflow file through (config/CLI can opt out).
  eq "floor: KIT_CAPTAIN_FLOORS=0 disables" "$(KIT_CAPTAIN_FLOORS=0 cap_policy_floor ".github/workflows/ci.yml" "hold")" ""

  # _cap_load_policy_config — the config bridge for requireChecks, and ENV WINNING over config
  # (same rule as KIT_CAPTAIN_FLOORS). Subshelled so the exports never leak into later assertions.
  if command -v jq >/dev/null 2>&1; then
    bridge() {
      ( KIT_CONFIG="$1"; KIT_CAPTAIN_REQUIRE_CHECKS="$2"
        KIT_CAPTAIN_FLOORS=; KIT_CAPTAIN_EXTRA_GLOBS=
        _cap_load_policy_config
        printf '%s' "${KIT_CAPTAIN_REQUIRE_CHECKS:-unset}" )
    }
    cfgon="$(mktemp)";  printf '{"captain":{"mergePolicy":{"requireChecks":true}}}'  > "$cfgon"
    cfgoff="$(mktemp)"; printf '{"captain":{"mergePolicy":{"requireChecks":false}}}' > "$cfgoff"
    cfgnone="$(mktemp)"; printf '{"project":{"name":"x"}}' > "$cfgnone"
    eq "bridge: config true -> 1"     "$(bridge "$cfgon" "")"   "1"
    eq "bridge: config false -> 0"    "$(bridge "$cfgoff" "")"  "0"
    eq "bridge: key absent -> unset"  "$(bridge "$cfgnone" "")" "unset"
    eq "bridge: env 0 beats config"   "$(bridge "$cfgon" "0")"  "0"
    eq "bridge: env 1 beats config"   "$(bridge "$cfgoff" "1")" "1"
    rm -f "$cfgon" "$cfgoff" "$cfgnone"

    # _cap_cfg_bool must distinguish "set to false" from "not set". jq's `//` does NOT — it treats a
    # literal false as absent — which is why `captain.mergePolicy.floors:false` was documented but
    # inert until this helper replaced it. Locking that here so the opt-out cannot silently rot again.
    cfgf="$(mktemp)"; printf '{"captain":{"mergePolicy":{"floors":false}}}' > "$cfgf"
    eq "cfg_bool: false is not absent" "$(_cap_cfg_bool "$cfgf" floors)" "false"
    eq "cfg_bool: absent is empty"     "$(_cap_cfg_bool "$cfgf" requireChecks)" ""
    floorbridge() {
      ( KIT_CONFIG="$1"; KIT_CAPTAIN_FLOORS="$2"; KIT_CAPTAIN_EXTRA_GLOBS=; KIT_CAPTAIN_REQUIRE_CHECKS=
        _cap_load_policy_config; printf '%s' "${KIT_CAPTAIN_FLOORS:-unset}" )
    }
    eq "bridge: floors:false -> 0"     "$(floorbridge "$cfgf" "")"  "0"
    eq "bridge: env 1 beats floors cfg" "$(floorbridge "$cfgf" "1")" "1"
    rm -f "$cfgf"
  fi

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
