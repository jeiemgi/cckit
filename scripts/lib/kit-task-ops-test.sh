#!/bin/sh
# kit-task-ops-test.sh — self-test for kit-task-ops.sh pure helpers under bash AND zsh.
# Network-free: covers the parsers + body composers only (the gh-calling ops are not exercised).
# Run:  bash scripts/lib/kit-task-ops-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

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
  eq "base explicit wins"  "$(KIT_BASE_BRANCH=develop; kto_base_branch release)" "release"
  eq "base explicit empty" "$(KIT_BASE_BRANCH=develop; kto_base_branch '')"  "develop"
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
  eq "kind:post (content kind) → docs, never feat" \
     "$(kto_pr_title 'Write the spring newsletter' '' 'kind:post,role:editor')" \
     "docs: Write the spring newsletter"
  eq "kind:research (content kind) → docs" \
     "$(kto_pr_title 'Competitor pricing pages' '' 'kind:research')" \
     "docs: Competitor pricing pages"
  eq "kind:fix → fix" \
     "$(kto_pr_title 'broken link' '' 'kind:fix')" \
     "fix: broken link"
  eq "conventional summary wins over derivation" \
     "$(kto_pr_title '[Effort 182] 2 · Publish to npm' 'ci: publish via OIDC' 'kind:task')" \
     "ci: publish via OIDC"
  eq "titleStyle issue-title → the issue title verbatim" \
     "$(KIT_PR_TITLE_STYLE=issue-title kto_pr_title '[Effort 182] 1 · Enforce it' 'ci: x' 'kind:task')" \
     "[Effort 182] 1 · Enforce it"
  eq "titleStyle conventional (explicit) → derive" \
     "$(KIT_PR_TITLE_STYLE=conventional kto_pr_title 'mail hook goes silent' '' 'bug')" \
     "fix: mail hook goes silent"
  eq "non-conventional summary ignored → derive" \
     "$(kto_pr_title 'Benchmark harness' 'ported a harness' 'kind:feat')" \
     "feat: Benchmark harness"

  # pr.orchestratorSection: off by default, a 2-line section first when on
  ob="$(kto_compose_pr_body 42 'S.' 'tech-lead' 'Fix the thing')"
  case "$ob" in *"For the orchestrator"*) echo "FAIL($KTO_TEST_INNER): orchestrator section present by default"; fail=1 ;; *) ;; esac
  ob="$(KIT_PR_ORCHESTRATOR_SECTION=true kto_compose_pr_body 42 'S.' 'tech-lead' 'Fix the thing')"
  eq "orchestrator section opens the body" "$(printf '%s\n' "$ob" | sed -n 1p)" "## For the orchestrator"
  eq "orchestrator line 1 = id + title"   "$(printf '%s\n' "$ob" | sed -n 3p)" "#42 · Fix the thing"
  eq "orchestrator line 2 = what to review" "$(printf '%s\n' "$ob" | sed -n 4p)" "Review: the summary below and the diff."
  case "$ob" in *"Closes #42"*) ;; *) echo "FAIL($KTO_TEST_INNER): Closes line lost with the section on"; fail=1 ;; esac

  # kto_compose_pr_body must carry Closes #N and the Summary
  body="$(kto_compose_pr_body 42 'Did the thing.' 'tech-lead')"
  case "$body" in *"Closes #42"*) ;; *) echo "FAIL($KTO_TEST_INNER): pr body missing Closes #42"; fail=1 ;; esac
  case "$body" in *"Did the thing."*) ;; *) echo "FAIL($KTO_TEST_INNER): pr body missing summary"; fail=1 ;; esac

  # pr.bodyStyle = content (#418): draft-and-review wording, none of the code wording
  eq "body style defaults to code" "$(kto_pr_body_style)" "code"
  eq "body style content"          "$(KIT_PR_BODY_STYLE=content kto_pr_body_style)" "content"
  eq "an unknown body style is code" "$(KIT_PR_BODY_STYLE=fancy kto_pr_body_style)" "code"
  case "$body" in *"Reproduced manually"*"in the diff"*) ;; *) echo "FAIL($KTO_TEST_INNER): the code body lost its Verification wording"; fail=1 ;; esac
  cb="$(KIT_PR_BODY_STYLE=content kto_compose_pr_body 42 'Drafted the post.' 'editor')"
  case "$cb" in *"Closes #42"*) ;; *) echo "FAIL($KTO_TEST_INNER): content body missing Closes #42"; fail=1 ;; esac
  case "$cb" in *"Drafted the post."*) ;; *) echo "FAIL($KTO_TEST_INNER): content body missing summary"; fail=1 ;; esac
  case "$cb" in *"## Review"*"Read the draft from start to finish"*"The voice matches the brand guide"*) ;; *) echo "FAIL($KTO_TEST_INNER): content body missing the review checklist"; fail=1 ;; esac
  for w in "diff" "Reproduced manually" "## Verification" "styles render"; do
    case "$cb" in *"$w"*) echo "FAIL($KTO_TEST_INNER): content body still says '$w'"; fail=1 ;; esac
  done
  cb="$(KIT_PR_BODY_STYLE=content KIT_PR_ORCHESTRATOR_SECTION=true kto_compose_pr_body 42 'S.' 'editor' 'Spring post')"
  eq "content orchestrator line 2" "$(printf '%s\n' "$cb" | sed -n 4p)" "Review: the summary below and the changed files."

  # kto_compose_issue_body must include the user body, and the Plan + Blocked lines when given
  ib="$(kto_compose_issue_body 'Context here' 'apps/admin/p.mdx' '#9' 'frontend')"
  case "$ib" in *"Context here"*) ;; *) echo "FAIL($KTO_TEST_INNER): issue body missing user body"; fail=1 ;; esac
  case "$ib" in *"**Plan:**"*) ;; *) echo "FAIL($KTO_TEST_INNER): issue body missing Plan line"; fail=1 ;; esac
  case "$ib" in *"**Blocked by:** #9"*) ;; *) echo "FAIL($KTO_TEST_INNER): issue body missing Blocked line"; fail=1 ;; esac
  ib2="$(kto_compose_issue_body 'Only body' '' '' 'frontend')"
  case "$ib2" in *"**Plan:**"*) echo "FAIL($KTO_TEST_INNER): issue body has Plan line when none given"; fail=1 ;; *) ;; esac

  # _kto_role_option_for_slug (#378): a slug role_display does not list still reaches the board
  # lookup (role_display is stubbed to print nothing here, so EVERY slug is "unlisted").
  role_option_id() { printf 'opt<%s>' "$1"; }
  eq "role option: unlisted slug falls back to the slug" "$(_kto_role_option_for_slug data-eng)" "opt<data-eng>"
  eq "role option: empty slug asks nothing"              "$(_kto_role_option_for_slug '')"       ""
  role_display() { case "$1" in tech-lead) echo "Tech Lead" ;; esac; }
  eq "role option: listed slug uses its display name"    "$(_kto_role_option_for_slug tech-lead)" "opt<Tech Lead>"
  eq "role option: slug the display map lacks"           "$(_kto_role_option_for_slug backend)"   "opt<backend>"
  role_display() { :; }
  unset -f role_option_id

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
