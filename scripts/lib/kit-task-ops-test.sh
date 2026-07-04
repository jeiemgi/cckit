#!/bin/sh
# kit-task-ops-test.sh — self-test for kit-task-ops.sh pure helpers under bash AND zsh.
# Network-free: covers the parsers + body composers only (the gh-calling ops are not exercised).
# Run:  bash scripts/lib/kit-task-ops-test.sh

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KTO_TEST_INNER:-}" ]; then
  # role_signature is a no-op stub so body composers run without sourcing role-identity.
  role_signature() { :; }
  role_display() { :; }
  . "$dir/kit-task-ops.sh"
  fail=0

  eq() { # <label> <got> <want>
    if [ "$2" != "$3" ]; then
      echo "FAIL($KTO_TEST_INNER): $1 -> '[$2]', want '[$3]'"
      fail=1
    fi
  }

  # kto_branch_issue_number
  eq "branch feat/173-x"   "$(kto_branch_issue_number 'feat/173-admin-clerk')" "173"
  eq "branch fix/46-y"     "$(kto_branch_issue_number 'fix/46-roadmap')"       "46"
  eq "branch develop"      "$(kto_branch_issue_number 'develop')"              ""
  eq "branch effort/851-z" "$(kto_branch_issue_number 'effort/851-tail')"      "851"

  # kto_base_branch / kto_board_enabled (portability toggles)
  eq "base default"        "$(unset KIT_BASE_BRANCH; kto_base_branch)"      "main"
  eq "base override"       "$(KIT_BASE_BRANCH=main; kto_base_branch)"       "main"
  if ( unset KIT_PROJECTS_V2; kto_board_enabled ); then eq "board default on" "on" "on"; else eq "board default on" "off" "on"; fi
  ( KIT_PROJECTS_V2=false; if kto_board_enabled; then exit 0; else exit 1; fi ) \
    && eq "board off" "on" "off" || eq "board off" "off" "off"

  # kto_labels_role / kto_labels_kind
  eq "role from labels"  "$(kto_labels_role 'kind:feat,priority:p2,role:tech-lead')" "tech-lead"
  eq "kind from labels"  "$(kto_labels_kind 'kind:feat,priority:p2,role:tech-lead')" "feat"
  eq "role absent"       "$(kto_labels_role 'kind:chore,priority:p3')"               ""

  # kto_pr_title — Conventional Commit PR titles (the squash-merge subject the commit gate reads)
  . "$dir/commitlint.sh"   # the shared validator kto_pr_title reuses to honor a conventional summary
  eq "task→feat + effort prefix stripped" \
     "$(kto_pr_title '[Effort 182] 1 · Enforce Conventional Commits' '' 'kind:task,priority:p1')" \
     "feat: Enforce Conventional Commits"
  eq "double prefix [Effort] N · [Tag]" \
     "$(kto_pr_title '[Effort] 86 · [Core] Plan future work' '' 'kind:task')" \
     "feat: Plan future work"
  eq "plain bug label → fix" \
     "$(kto_pr_title 'mail hook goes silent' '' 'bug')" \
     "fix: mail hook goes silent"
  eq "kind:chore → chore" \
     "$(kto_pr_title '[Effort 75] 7 · rich rendering' '' 'kind:chore')" \
     "chore: rich rendering"
  eq "conventional summary wins over derivation" \
     "$(kto_pr_title '[Effort 182] 2 · Publish to npm' 'ci: publish via OIDC' 'kind:task')" \
     "ci: publish via OIDC"
  eq "non-conventional summary ignored → derive" \
     "$(kto_pr_title 'Benchmark harness' 'ported a harness' 'kind:feat')" \
     "feat: Benchmark harness"

  # kto_compose_pr_body must carry Closes #N and the Summary
  body="$(kto_compose_pr_body 42 'Did the thing.' 'tech-lead')"
  case "$body" in *"Closes #42"*) ;; *) echo "FAIL($KTO_TEST_INNER): pr body missing Closes #42"; fail=1 ;; esac
  case "$body" in *"Did the thing."*) ;; *) echo "FAIL($KTO_TEST_INNER): pr body missing summary"; fail=1 ;; esac

  # kto_compose_issue_body must include the user body, and the Plan + Blocked lines when given
  ib="$(kto_compose_issue_body 'Context here' 'apps/admin/p.mdx' '#9' 'frontend')"
  case "$ib" in *"Context here"*) ;; *) echo "FAIL($KTO_TEST_INNER): issue body missing user body"; fail=1 ;; esac
  case "$ib" in *"**Plan:**"*) ;; *) echo "FAIL($KTO_TEST_INNER): issue body missing Plan line"; fail=1 ;; esac
  case "$ib" in *"**Blocked by:** #9"*) ;; *) echo "FAIL($KTO_TEST_INNER): issue body missing Blocked line"; fail=1 ;; esac
  ib2="$(kto_compose_issue_body 'Only body' '' '' 'frontend')"
  case "$ib2" in *"**Plan:**"*) echo "FAIL($KTO_TEST_INNER): issue body has Plan line when none given"; fail=1 ;; *) ;; esac

  if [ "$fail" -eq 0 ]; then echo "PASS($KTO_TEST_INNER): kit-task-ops helpers"; fi
  exit "$fail"
fi

# Outer: re-run under each available shell.
rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  KTO_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
