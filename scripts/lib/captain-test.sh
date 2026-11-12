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
  # The effort sub form. The local regex needs a "-" straight after the digits and so returns
  # nothing here; wt_issue_number is what parses it. A sub-branch PR with no issue has no review
  # verdict to look up and would read CLEAN (#348).
  if command -v wt_issue_number >/dev/null 2>&1; then
    eq "branch effort sub" "$(_cap_issue_of_branch 'sub/1604a-parser')"   "1604"
  fi

  # ── the agent review gate (#348) ─────────────────────────────────────────────────────────────
  # cap_review_summary: one token out of a receipt, the same shape cap_checks_summary has.
  if command -v jq >/dev/null 2>&1; then
    eq "review: gate pass"          "$(printf '{"gate":"pass"}'            | cap_review_summary)" "PASS"
    eq "review: gate fail"          "$(printf '{"gate":"fail"}'            | cap_review_summary)" "FAIL"
    # The detail after the dash is the useful half of a real verdict; matching the whole field
    # would score every annotated receipt as NONE.
    eq "review: annotated fail"     "$(printf '{"gate":"fail — the retry loop never exits"}' | cap_review_summary)" "FAIL"
    eq "review: annotated pass"     "$(printf '{"gate":"pass — read the whole diff"}'        | cap_review_summary)" "PASS"
    eq "review: no gate field"      "$(printf '{"outcome":"pr-open"}'      | cap_review_summary)" "NONE"
    eq "review: empty stdin"        "$(printf ''                          | cap_review_summary)" "NONE"
    eq "review: unknown word"       "$(printf '{"gate":"maybe"}'          | cap_review_summary)" "NONE"
  fi

  # A recorded FAIL always blocks — it is evidence, not absence of it, so no flag gates it.
  ( KIT_CAPTAIN_REQUIRE_REVIEW=0
    eq "review FAIL blocks even unrequired" "$(cap_classify MERGEABLE CLEAN PASS FAIL)" "REVIEW_FAILING" ) || fail=1
  eq "REVIEW_FAILING -> fix"  "$(cap_action REVIEW_FAILING)" "fix"

  # A MISSING verdict is gated on the requirement, exactly like CHECKS_MISSING.
  ( KIT_CAPTAIN_REQUIRE_REVIEW=0
    eq "no verdict merges when not required" "$(cap_classify MERGEABLE CLEAN PASS NONE)" "CLEAN" ) || fail=1
  ( KIT_CAPTAIN_REQUIRE_REVIEW=1
    eq "no verdict blocks when required"     "$(cap_classify MERGEABLE CLEAN PASS NONE)" "REVIEW_MISSING" ) || fail=1
  eq "REVIEW_MISSING -> verify" "$(cap_action REVIEW_MISSING)" "verify"

  # A passing verdict never blocks, required or not.
  ( KIT_CAPTAIN_REQUIRE_REVIEW=1
    eq "a passing verdict merges" "$(cap_classify MERGEABLE CLEAN PASS PASS)" "CLEAN" ) || fail=1

  # Red CI outranks the review: the PR will be rewritten before the review matters.
  ( KIT_CAPTAIN_REQUIRE_REVIEW=1
    eq "failing checks outrank a missing review" "$(cap_classify MERGEABLE CLEAN FAIL NONE)" "CHECKS_FAILING"
    eq "a conflict outranks a failing review"    "$(cap_classify CONFLICTING DIRTY PASS FAIL)" "CONFLICTING"
    eq "a draft outranks a failing review"       "$(cap_classify MERGEABLE DRAFT PASS FAIL)"   "DRAFT" ) || fail=1

  # Omitting the argument must not change any existing verdict — every caller predating #348 passes
  # three arguments, and a default of anything but NONE would re-decide them.
  eq "a 3-arg call still reads CLEAN" "$(cap_classify MERGEABLE CLEAN PASS)" "CLEAN"
  ( KIT_CAPTAIN_REQUIRE_REVIEW=1
    eq "a 3-arg call defaults to NONE" "$(cap_classify MERGEABLE CLEAN PASS)" "REVIEW_MISSING" ) || fail=1

  # head_sha binds a verdict to a revision (#351 review). Without it a PASS earned on one commit
  # gates every commit pushed after it — sr_latest is newest-by-issue and knows nothing about SHAs.
  if command -v jq >/dev/null 2>&1; then
    eq "review: a matching head still passes" \
      "$(printf '{"gate":"pass","head_sha":"abc"}' | cap_review_summary abc)" "PASS"
    eq "review: a stale verdict reads NONE, not PASS" \
      "$(printf '{"gate":"pass","head_sha":"abc"}' | cap_review_summary def)" "NONE"
    # A stale FAIL is also absence: the reviewer read code that is no longer there, so it is neither
    # a finding against this revision nor a pass for it.
    eq "review: a stale fail reads NONE too" \
      "$(printf '{"gate":"fail","head_sha":"abc"}' | cap_review_summary def)" "NONE"
    # No head asked: the check is skipped. This is also what keeps a receipt written before head_sha
    # existed (empty field) readable instead of permanently stale.
    eq "review: no head asked skips the check" \
      "$(printf '{"gate":"pass","head_sha":"abc"}' | cap_review_summary)" "PASS"
    eq "review: a head-less receipt does not match a head" \
      "$(printf '{"gate":"pass"}' | cap_review_summary abc)" "NONE"
  fi

  # The config bridge: review.command implies the requirement; requireReview:false opts back out.
  if command -v jq >/dev/null 2>&1; then
    revbridge() {
      ( KIT_CONFIG="$1"; KIT_CAPTAIN_FLOORS=; KIT_CAPTAIN_EXTRA_GLOBS=; KIT_CAPTAIN_REQUIRE_CHECKS=
        KIT_CAPTAIN_REQUIRE_REVIEW="$2"
        _cap_load_policy_config; printf '%s' "${KIT_CAPTAIN_REQUIRE_REVIEW:-unset}" )
    }
    rc1="$(mktemp)"; printf '{"review":{"command":"true"}}' > "$rc1"
    rc2="$(mktemp)"; printf '{"review":{"command":"true"},"captain":{"mergePolicy":{"requireReview":false}}}' > "$rc2"
    rc3="$(mktemp)"; printf '{"captain":{"mergePolicy":{"requireReview":true}}}' > "$rc3"
    rc4="$(mktemp)"; printf '{}' > "$rc4"
    eq "bridge: review.command implies required" "$(revbridge "$rc1" "")"  "1"
    eq "bridge: requireReview:false opts out"    "$(revbridge "$rc2" "")"  "0"
    eq "bridge: requireReview:true with no cmd"  "$(revbridge "$rc3" "")"  "1"
    eq "bridge: neither is off"                  "$(revbridge "$rc4" "")"  "0"
    eq "bridge: env 0 beats review.command"      "$(revbridge "$rc1" "0")" "0"
    rm -f "$rc1" "$rc2" "$rc3" "$rc4"
  fi

  # ── the QA gate (#300) ───────────────────────────────────────────────────────────────────────
  # cap_classify <mergeable> <mss> <checks> <review> <qa> <qa-required>. Requirement OFF: no existing
  # verdict moves, whatever the qa token says short of a recorded fail.
  ( KIT_CAPTAIN_REQUIRE_QA=; KIT_CAPTAIN_QA_LABELS=; KIT_CAPTAIN_REQUIRE_REVIEW=0; KIT_CAPTAIN_REQUIRE_CHECKS=0
    eq "qa off: no verdict still CLEAN"      "$(cap_classify MERGEABLE CLEAN PASS NONE NONE)"    "CLEAN"
    eq "qa off (explicit 0): still CLEAN"    "$(cap_classify MERGEABLE CLEAN PASS NONE NONE 0)"  "CLEAN"
    eq "qa off: a pass is still CLEAN"       "$(cap_classify MERGEABLE CLEAN PASS PASS PASS 0)"  "CLEAN"
    eq "qa off: failing checks unchanged"    "$(cap_classify MERGEABLE CLEAN FAIL NONE NONE 0)"  "CHECKS_FAILING"
    eq "qa off: draft unchanged"             "$(cap_classify MERGEABLE DRAFT PASS NONE NONE 0)"  "DRAFT"
    eq "qa off: conflict unchanged"          "$(cap_classify CONFLICTING DIRTY PASS NONE NONE 0)" "CONFLICTING"
    eq "qa off: blocked unchanged"           "$(cap_classify UNKNOWN BLOCKED PASS NONE NONE 0)"  "BLOCKED"
    eq "qa off: review fail unchanged"       "$(cap_classify MERGEABLE CLEAN PASS FAIL NONE 0)"  "REVIEW_FAILING" ) || fail=1
  # Requirement ON: a MERGEABLE/CLEAN PR with no qa receipt for its head is QA_MISSING -> verify.
  eq "qa on: no verdict is QA_MISSING"       "$(cap_classify MERGEABLE CLEAN PASS PASS NONE 1)"  "QA_MISSING"
  eq "qa on: unstable is QA_MISSING too"     "$(cap_classify MERGEABLE UNSTABLE PASS PASS NONE 1)" "QA_MISSING"
  eq "qa on: a pass merges"                  "$(cap_classify MERGEABLE CLEAN PASS PASS PASS 1)"  "CLEAN"
  eq "QA_MISSING -> verify"                  "$(cap_action QA_MISSING)" "verify"
  eq "QA_FAILING -> fix"                     "$(cap_action QA_FAILING)" "fix"
  # The flag argument is what decides; omitted, the env stands in for it.
  ( KIT_CAPTAIN_REQUIRE_QA=1
    eq "qa on by env, 5-arg call"            "$(cap_classify MERGEABLE CLEAN PASS PASS NONE)"    "QA_MISSING"
    eq "an explicit 0 beats the env"         "$(cap_classify MERGEABLE CLEAN PASS PASS NONE 0)"  "CLEAN" ) || fail=1
  # A recorded fail is evidence: it blocks with the requirement off as well as on.
  eq "qa fail blocks when not required"      "$(cap_classify MERGEABLE CLEAN PASS PASS FAIL 0)"  "QA_FAILING"
  eq "qa fail blocks when required"          "$(cap_classify MERGEABLE CLEAN PASS PASS FAIL 1)"  "QA_FAILING"
  # Only the would-be-CLEAN verdict changes; red CI, a conflict and a draft keep their own answers.
  eq "qa on: failing checks outrank"         "$(cap_classify MERGEABLE CLEAN FAIL PASS NONE 1)"  "CHECKS_FAILING"
  eq "qa on: pending checks outrank"         "$(cap_classify MERGEABLE CLEAN PENDING PASS NONE 1)" "CHECKS_PENDING"
  eq "qa on: a conflict outranks a qa fail"  "$(cap_classify CONFLICTING DIRTY PASS PASS FAIL 1)" "CONFLICTING"
  eq "qa on: a draft outranks"               "$(cap_classify MERGEABLE DRAFT PASS PASS NONE 1)"  "DRAFT"
  # Order against the review gate. rs_needs_dispatch keys the reviewer on REVIEW_MISSING, so a PR
  # that is both unreviewed and un-QA'd must read REVIEW_MISSING or its reviewer never runs.
  ( KIT_CAPTAIN_REQUIRE_REVIEW=1
    eq "unreviewed + un-QA'd reads REVIEW_MISSING" "$(cap_classify MERGEABLE CLEAN PASS NONE NONE 1)" "REVIEW_MISSING"
    eq "reviewed + un-QA'd reads QA_MISSING"       "$(cap_classify MERGEABLE CLEAN PASS PASS NONE 1)" "QA_MISSING" ) || fail=1
  ( KIT_CAPTAIN_REQUIRE_CHECKS=1
    eq "no checks + un-QA'd reads CHECKS_MISSING"  "$(cap_classify MERGEABLE CLEAN NONE PASS NONE 1)" "CHECKS_MISSING" ) || fail=1

  # cap_qa_summary: the qa receipt read against the PR's head. A pass recorded on an older head is
  # NONE, which the classifier above turns into QA_MISSING.
  if command -v jq >/dev/null 2>&1; then
    eq "qa: pass on this head"          "$(printf '{"gate":"pass","head_sha":"abc"}' | cap_qa_summary abc)" "PASS"
    eq "qa: annotated fail on this head" "$(printf '{"gate":"fail — the save button is dead","head_sha":"abc"}' | cap_qa_summary abc)" "FAIL"
    eq "qa: a pass on an older head"    "$(printf '{"gate":"pass","head_sha":"abc"}' | cap_qa_summary def)" "NONE"
    eq "qa: a fail on an older head"    "$(printf '{"gate":"fail","head_sha":"abc"}' | cap_qa_summary def)" "NONE"
    eq "qa: no receipt"                 "$(printf '' | cap_qa_summary abc)" "NONE"
    # Unlike the review summary, no head to compare is NONE: an uncheckable verdict is not fresh.
    eq "qa: no head to compare"         "$(printf '{"gate":"pass","head_sha":"abc"}' | cap_qa_summary)" "NONE"
    eq "an older-head pass still reads QA_MISSING" \
      "$(cap_classify MERGEABLE CLEAN PASS PASS "$(printf '{"gate":"pass","head_sha":"abc"}' | cap_qa_summary def)" 1)" "QA_MISSING"
  fi

  # The same reading over a receipt written the way `cckit qa verdict` writes one (sr_record, stage
  # qa, head_sha last), so the token is proved against the stored shape and not a hand-built object.
  if command -v jq >/dev/null 2>&1 && command -v sr_record >/dev/null 2>&1; then
    qst="$(mktemp -d)"
    ( KIT_STATE_DIR="$qst"; CCKIT_RECEIPT_REMOTE=0; export KIT_STATE_DIR CCKIT_RECEIPT_REMOTE
      eq "stored qa: nothing recorded" "$(sr_latest 4242 qa 2>/dev/null | cap_qa_summary abc)" "NONE"
      printf 'outcome: pr-open\nurl: -\ngate: pass\nblocker: none\nnext stage: none\n' \
        | sr_record 4242 qa 1 "" "" "cckit qa verdict" "read-only" abc >/dev/null 2>&1
      eq "stored qa: pass on its head"  "$(sr_latest 4242 qa 2>/dev/null | cap_qa_summary abc)" "PASS"
      eq "stored qa: stale after a push" "$(sr_latest 4242 qa 2>/dev/null | cap_qa_summary def)" "NONE"
      printf 'outcome: blocked\nurl: -\ngate: fail — the save button is dead\nblocker: the save button is dead\nnext stage: build\n' \
        | sr_record 4242 qa 2 "" "" "cckit qa verdict" "read-only" def >/dev/null 2>&1
      eq "stored qa: a later fail wins" "$(sr_latest 4242 qa 2>/dev/null | cap_qa_summary def)" "FAIL"
      exit "$fail" ) || fail=1
    rm -rf "$qst"
  fi

  # cap_qa_required: every PR, or only the PRs carrying a listed label.
  ( KIT_CAPTAIN_REQUIRE_QA=; KIT_CAPTAIN_QA_LABELS=
    eq "qa required: off by default"    "$(cap_qa_required "flow:ui kind:task")" "0" ) || fail=1
  ( KIT_CAPTAIN_REQUIRE_QA=1; KIT_CAPTAIN_QA_LABELS=
    eq "qa required: on for every PR"   "$(cap_qa_required "")" "1" ) || fail=1
  ( KIT_CAPTAIN_REQUIRE_QA=; KIT_CAPTAIN_QA_LABELS="flow:ui needs-qa"
    eq "qa required: a listed label"    "$(cap_qa_required "kind:task flow:ui")" "1"
    eq "qa required: the second label"  "$(cap_qa_required "needs-qa")" "1"
    eq "qa required: no listed label"   "$(cap_qa_required "kind:task flow:core")" "0"
    eq "qa required: no partial match"  "$(cap_qa_required "flow:ui-kit")" "0"
    eq "qa required: no labels at all"  "$(cap_qa_required "")" "0" ) || fail=1

  # The config bridge: requireQa is true, false or a list of labels; env wins.
  if command -v jq >/dev/null 2>&1; then
    qabridge() {
      ( KIT_CONFIG="$1"; KIT_CAPTAIN_FLOORS=; KIT_CAPTAIN_EXTRA_GLOBS=; KIT_CAPTAIN_REQUIRE_CHECKS=
        KIT_CAPTAIN_REQUIRE_REVIEW=; KIT_CAPTAIN_REQUIRE_QA="$2"; KIT_CAPTAIN_QA_LABELS="$3"
        _cap_load_policy_config
        printf '%s|%s|%s' "${KIT_CAPTAIN_REQUIRE_QA:-unset}" "${KIT_CAPTAIN_QA_LABELS:-none}" "$(cap_qa_required "flow:ui")" )
    }
    q1="$(mktemp)"; printf '{"captain":{"mergePolicy":{"requireQa":true}}}'  > "$q1"
    q2="$(mktemp)"; printf '{"captain":{"mergePolicy":{"requireQa":false}}}' > "$q2"
    q3="$(mktemp)"; printf '{"captain":{"mergePolicy":{"requireQa":["flow:ui","needs-qa"]}}}' > "$q3"
    q4="$(mktemp)"; printf '{"qa":{"command":"pnpm dev"}}' > "$q4"
    eq "bridge: requireQa true"             "$(qabridge "$q1" "" "")"  "1|none|1"
    eq "bridge: requireQa false"            "$(qabridge "$q2" "" "")"  "0|none|0"
    eq "bridge: requireQa label list"       "$(qabridge "$q3" "" "")"  "unset|flow:ui needs-qa|1"
    # Declaring a QA stack is not the opt-in: the gate stays off until requireQa says otherwise.
    eq "bridge: qa.command alone is off"    "$(qabridge "$q4" "" "")"  "unset|none|0"
    eq "bridge: env 0 beats config true"    "$(qabridge "$q1" "0" "")" "0|none|0"
    eq "bridge: env 0 beats a label list"   "$(qabridge "$q3" "0" "")" "0|none|0"
    eq "bridge: env 1 beats config false"   "$(qabridge "$q2" "1" "")" "1|none|1"
    eq "bridge: env labels beat config"     "$(qabridge "$q1" "" "kind:bug")" "unset|kind:bug|0"
    rm -f "$q1" "$q2" "$q3" "$q4"
  fi

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
