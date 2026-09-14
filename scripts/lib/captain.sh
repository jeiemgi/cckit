#!/usr/bin/env bash
# captain.sh — the captain loop: gate open PRs, squash-merge the clean ones, advance the board to the
# next unblocked wave, and checkpoint so the loop can stop and resume (Effort 75 · #77).
#
# Autopilot has two halves. `orchestrate`/`autopilot` LAUNCH the per-issue flows; the captain CLOSES
# them — it inspects each PR, decides (CLEAN / CONFLICTING / CHECKS_FAILING / CHECKS_PENDING /
# CHECKS_MISSING / DRAFT / BLOCKED), merges what is ready, and lets the freshly-merged issues unblock
# the next wave. This is the half that used to be left to the driving agent; now it is a script the
# agent (or `cckit watch`) runs in a loop.
#
#   cckit watch                 one pass: gate every open PR, report (no merge) — safe default
#   cckit watch --merge         gate + squash-merge the CLEAN PRs, then show the next wave
#   cckit watch --effort <N>    scope to PRs for effort #N's sub-issues
#   cckit watch --loop          repeat passes until no CLEAN PR remains (checkpointed), then stop
#   cckit watch --max-passes M  cap the loop at M passes (default 10)
#
# Gate decision is three pure helpers (cap_checks_summary / cap_classify / cap_action) so the policy
# is unit-tested without the network. Requires gh + jq. bash 3.2 / zsh compatible.
# errors: mixed — cap_* are pure; captain_gate/captain_pass propagate a gh failure

CAPTAIN_REPO="${CAPTAIN_REPO:-${KIT_REPO:-}}"

# State lives in the shared .cckit/ (kit-state.sh), never CWD-relative: the captain gates the whole
# repo, so its record must be the same file from the primary checkout and from every worktree.
# Locate the sibling portably — BASH_SOURCE is bash-only and empty in zsh (#313).
if [ -n "${BASH_SOURCE:-}" ]; then
  _cap_self="$BASH_SOURCE"
elif [ -n "${ZSH_VERSION:-}" ]; then
  eval '_cap_self="${(%):-%x}"'
else
  _cap_self="$0"
fi
if [ -f "$(dirname "$_cap_self")/kit-state.sh" ]; then
  # shellcheck source=kit-state.sh
  . "$(dirname "$_cap_self")/kit-state.sh"
fi
# The review stage (#346) is sourced here, not left to a caller: captain_pass guards on
# `command -v rs_needs_dispatch`, so a missing source would switch the stage off silently rather
# than fail. CAPTAIN_CFG is what rs_command reads `review.command` out of — resolved through
# kit_config_path because two config layouts are current and neither path is safe to hard-code.
if [ -f "$(dirname "$_cap_self")/review-stage.sh" ]; then
  # shellcheck source=config-path.sh
  [ -f "$(dirname "$_cap_self")/config-path.sh" ] && . "$(dirname "$_cap_self")/config-path.sh"
  # shellcheck source=review-stage.sh
  . "$(dirname "$_cap_self")/review-stage.sh"
fi
if [ -z "${CAPTAIN_CFG:-}" ] && command -v kit_config_path >/dev/null 2>&1; then
  CAPTAIN_CFG="$(kit_config_path 2>/dev/null || true)"
fi
CAPTAIN_CFG="${CAPTAIN_CFG:-}"
unset _cap_self
if [ -z "${CAPTAIN_STATE:-}" ] && command -v kit_state_file >/dev/null 2>&1; then
  CAPTAIN_STATE="$(kit_state_file captain.state)"
fi
CAPTAIN_STATE="${CAPTAIN_STATE:-.cckit/captain.state}"

# cap_checks_summary — collapse a gh statusCheckRollup JSON array (stdin) to one token:
#   FAIL (any failure/error/cancelled/timed_out) > PENDING (any in-flight) > PASS (any success) > NONE.
# Precedence is worst-first so a single red check is never hidden by green ones.
cap_checks_summary() {
  command -v jq >/dev/null 2>&1 || { echo NONE; return 0; }
  jq -r '
    [ .[]? | (.conclusion // .state // "") | ascii_upcase ] as $c
    | if   ($c | any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE")) then "FAIL"
      elif ($c | any(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "EXPECTED" or . == "WAITING" or . == "")) then "PENDING"
      elif ($c | any(. == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED")) then "PASS"
      else "NONE" end' 2>/dev/null || echo NONE
}

# cap_review_summary — collapse a review receipt (stdin, sr_record's JSON) to one token:
#   FAIL (the reviewer said gate: fail) > PASS (gate: pass) > NONE (no receipt, or no gate line).
# Pure apart from jq. Empty stdin is NONE, which is the state every repo is in until a reviewer runs.
#
# `gate` is read on its FIRST WORD, the same way sr_invalid_fields reads it: a receipt says
# `fail — the retry loop never exits` and the detail after the dash is the useful half, not part of
# the verdict. Matching the whole field would score every annotated verdict as NONE.
#
# <head-sha> BINDS THE VERDICT TO A REVISION. sr_latest returns the newest receipt for an issue and
# knows nothing about commits, so without this a PASS earned on one commit gates every commit
# pushed after it — the reviewer approved code that is no longer there. Given a head, a receipt
# recorded against a different one reads NONE: not a failure, an absence, which is what it is. An
# empty head skips the check, for a caller with no revision to compare (and for every receipt
# written before head_sha existed, whose field is empty and would otherwise never match).
cap_review_summary() {
  local head="${1:-}"
  command -v jq >/dev/null 2>&1 || { echo NONE; return 0; }
  # Empty stdin is the common case — sr_latest echoes nothing when there is no receipt — and jq
  # reads no values from it, printing nothing and exiting 0. So the `|| echo NONE` fallback never
  # fires and the caller gets an empty token instead of a verdict. Substitute an empty object.
  local j; j="$(cat)"
  [ -n "$j" ] || j='{}'
  printf '%s' "$j" | jq -r --arg head "$head" '
      if ($head != "" and ((.head_sha // "") != $head)) then "NONE"
      else (.gate // "") | split(" ")[0] | ascii_upcase
           | if . == "FAIL" then "FAIL" elif . == "PASS" then "PASS" else "NONE" end
      end' 2>/dev/null \
    || echo NONE
}

# cap_classify <mergeable> <mergeStateStatus> <checksSummary> — pure verdict for one PR.
# mergeable: MERGEABLE|CONFLICTING|UNKNOWN · mss: CLEAN|DIRTY|DRAFT|BLOCKED|BEHIND|UNSTABLE|…
#
# CHECKS_MISSING — "the exit criteria could not be observed". An EMPTY statusCheckRollup collapses to
# NONE, and NONE is not a pass: it is the ABSENCE of evidence. Read as green it means a repo with no
# CI is auto-mergeable by construction, which is how an unattended captain lands a change nothing
# ever verified. When evidence is REQUIRED (KIT_CAPTAIN_REQUIRE_CHECKS=1, or
# captain.mergePolicy.requireChecks:true in the kit config — env wins) that case becomes its own
# verdict, distinct from CHECKS_FAILING (something ran and went red) and CHECKS_PENDING (something is
# still running), and its action is `verify`, never `merge`.
#
# DEFAULT OFF. Requiring evidence in every repo would turn a legitimate no-CI, human-reviewed
# workflow into a captain that silently merges nothing and reports steady state, so the default keeps
# today's behaviour and `captain_pass` instead PRINTS the assumption it is making (see the "green was
# assumed" advisory) with the key that closes it. The narrow guard below is deliberate: only the
# verdict that would have been CLEAN can change, so nothing else in the vocabulary moves.
#
# REVIEW_FAILING / REVIEW_MISSING (#348) are the same two shapes for the agent review stage, and
# they split along the same line: a recorded `gate: fail` is EVIDENCE and always blocks, while a
# missing verdict is ABSENCE of evidence and blocks only when review is required. Absence is the
# state of every repo that has not run a reviewer — cckit's own included, which has no receipts at
# all — so requiring it unconditionally would stop every captain on upgrade.
#
# Required when review.command is configured (running a reviewer IS the opt-in) or when
# KIT_CAPTAIN_REQUIRE_REVIEW=1 / captain.mergePolicy.requireReview:true says so; env wins, as it
# does for checks. Off in both, captain_pass prints the advisory naming the key instead.
cap_classify() {
  local mergeable="$1" mss="$2" checks="$3" review="${4:-NONE}" require review_req
  case "$mss" in DRAFT) echo DRAFT; return 0 ;; esac
  case "$mergeable" in CONFLICTING) echo CONFLICTING; return 0 ;; esac
  case "$mss" in DIRTY) echo CONFLICTING; return 0 ;; esac
  case "$checks" in
    FAIL)    echo CHECKS_FAILING; return 0 ;;
    PENDING) echo CHECKS_PENDING; return 0 ;;
  esac
  # A recorded failing review outranks the requirement flag: the reviewer ran and said no. This sits
  # AFTER the check verdicts because a PR with red CI will be rewritten before the review matters.
  case "$review" in FAIL) echo REVIEW_FAILING; return 0 ;; esac
  # Literal case patterns only (a variable in a case pattern matches literally under zsh).
  case "${KIT_CAPTAIN_REQUIRE_CHECKS:-0}" in 1|true|yes|on) require=1 ;; *) require=0 ;; esac
  case "${KIT_CAPTAIN_REQUIRE_REVIEW:-0}" in 1|true|yes|on) review_req=1 ;; *) review_req=0 ;; esac
  case "$mergeable" in
    MERGEABLE)
      # passing or no required checks, and not draft/dirty/conflicting -> ready.
      case "$mss" in
        CLEAN|UNSTABLE|HAS_HOOKS|"")
          if [ "$require" = "1" ] && [ "$checks" = "NONE" ]; then echo CHECKS_MISSING; return 0; fi
          if [ "$review_req" = "1" ] && [ "$review" = "NONE" ]; then echo REVIEW_MISSING; return 0; fi
          echo CLEAN; return 0 ;;
      esac
      echo BLOCKED; return 0 ;;
  esac
  echo BLOCKED
}

# cap_action <state> — the action the captain takes for a verdict.
# CHECKS_MISSING -> `verify`, not `wait` (nothing is coming — no check exists to finish) and not
# `hold` (that is the policy-floor action, reported as "policy floor: <reason>"). Someone must go
# produce or point at the evidence.
cap_action() {
  case "$1" in
    CLEAN)          echo merge ;;
    CONFLICTING)    echo rebase ;;
    CHECKS_FAILING) echo fix ;;
    CHECKS_PENDING) echo wait ;;
    CHECKS_MISSING) echo verify ;;
    REVIEW_FAILING) echo fix ;;
    REVIEW_MISSING) echo verify ;;
    DRAFT)          echo wait ;;
    HELD)           echo hold ;;
    *)              echo skip ;;
  esac
}

# cap_policy_floor <files-newline> <labels-space> — echo a non-empty REASON when a PR must NOT be
# auto-merged by the captain (a policy floor tripped), else empty. Floors are DEFAULT ON so an
# unattended captain never lands a change a human must sign off on. They trip on:
#   • a `hold` label (an explicit human stop)
#   • any changed file under .github/workflows/**  (CI/CD — a supply-chain surface)
#   • lockfile / dependency-graph files: pnpm-lock.yaml, package.json, package-lock.json, yarn.lock,
#     turbo.json, *-workspace.yaml/.yml
#   • security-sensitive paths: *.pem, *.key, .env / .env.*, any secret(s) path segment
# Disable entirely with KIT_CAPTAIN_FLOORS=0 (or captain.mergePolicy.floors:false in config). Extend
# the protected set with KIT_CAPTAIN_EXTRA_GLOBS (space-separated case-globs). Draft state is honored
# separately by cap_classify (DRAFT -> wait). Pure — no gh; unit-tested. bash 3.2 / zsh safe.
#
# A floor is about WHAT THE PR TOUCHES, so it needs the file list and labels and it downgrades a
# would-be merge to HELD. Missing check evidence is about WHAT IS KNOWN about the PR — decidable from
# the rollup token alone — so it is a cap_classify verdict (CHECKS_MISSING) instead. Keeping them
# apart keeps both reasons legible: "a human must sign off on this path" is not the same finding as
# "nothing ever verified this", and HELD's report line names a floor that would not exist.
cap_policy_floor() {
  local files="$1" labels="$2" f g extra hit
  [ "${KIT_CAPTAIN_FLOORS:-1}" = "0" ] && return 0
  case " $labels " in *" hold "*) printf 'hold label'; return 0 ;; esac
  extra="${KIT_CAPTAIN_EXTRA_GLOBS:-}"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      .github/workflows/*) printf 'workflow file (%s)' "$f"; return 0 ;;
    esac
    case "${f##*/}" in
      pnpm-lock.yaml|package.json|package-lock.json|yarn.lock|turbo.json)
        printf 'lockfile/graph (%s)' "$f"; return 0 ;;
      *-workspace.yaml|*-workspace.yml)
        printf 'workspace graph (%s)' "$f"; return 0 ;;
      *.pem|*.key) printf 'security-sensitive (%s)' "$f"; return 0 ;;
      .env|.env.*) printf 'security-sensitive (%s)' "$f"; return 0 ;;
    esac
    case "/$f/" in */secret/*|*/secrets/*) printf 'security-sensitive (%s)' "$f"; return 0 ;; esac
    # Extra protected globs from config (space-separated). Split on spaces via a here-string (no
    # subshell, so `return` still exits the function), and inline each glob into an eval'd case so it
    # is a LITERAL pattern — matching identically under bash and zsh (a variable in a case pattern is
    # treated literally by zsh, so `case $f in $g` would silently never match there).
    if [ -n "$extra" ]; then
      hit=""
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        eval "case \"\$f\" in ($g) hit=1 ;; esac"
        [ -n "$hit" ] && break
      done <<EOF2
$(printf '%s' "$extra" | tr ' ' '\n')
EOF2
      [ -n "$hit" ] && { printf 'protected by config (%s)' "$f"; return 0; }
    fi
  done <<EOF
$files
EOF
  return 0
}

# _cap_cfg_bool <cfg> <key> — echo "true"/"false" for captain.mergePolicy.<key>, or NOTHING when the
# key is absent. Deliberately NOT `// empty`: jq's `//` treats a literal `false` as absent, so
# `.foo // empty` silently swallows an explicit opt-out — which is exactly how
# `captain.mergePolicy.floors:false` came to be documented but inert. `has()` distinguishes
# "set to false" from "not set", which is the whole distinction a tri-state override needs.
_cap_cfg_bool() {
  jq -r --arg k "$2" '
    .captain.mergePolicy
    | if type == "object" and has($k) and (.[$k] | type == "boolean")
      then (.[$k] | tostring) else empty end' "$1" 2>/dev/null
}

# _cap_load_policy_config — bridge captain.mergePolicy from the kit config into the env the pure
# helpers read, so a project can set the merge policy declaratively. Env always wins (a value already
# set is left untouched). Best-effort: no config / no jq -> defaults (floors ON, requireChecks OFF).
_cap_load_policy_config() {
  command -v jq >/dev/null 2>&1 || return 0
  local cfg="${KIT_CONFIG:-}"
  [ -n "$cfg" ] || { [ -f cckit.config.json ] && cfg=cckit.config.json || cfg=.claude/kit.config.json; }
  [ -f "$cfg" ] || return 0
  if [ -z "${KIT_CAPTAIN_FLOORS:-}" ]; then
    case "$(_cap_cfg_bool "$cfg" floors)" in
      false) KIT_CAPTAIN_FLOORS=0 ;; true) KIT_CAPTAIN_FLOORS=1 ;;
    esac
  fi
  if [ -z "${KIT_CAPTAIN_EXTRA_GLOBS:-}" ]; then
    KIT_CAPTAIN_EXTRA_GLOBS="$(jq -r '(.captain.mergePolicy.protectedGlobs // []) | join(" ")' "$cfg" 2>/dev/null || echo "")"
  fi
  if [ -z "${KIT_CAPTAIN_REQUIRE_CHECKS:-}" ]; then
    case "$(_cap_cfg_bool "$cfg" requireChecks)" in
      true) KIT_CAPTAIN_REQUIRE_CHECKS=1 ;; false) KIT_CAPTAIN_REQUIRE_CHECKS=0 ;;
    esac
  fi
  # Review requirement (#348). Configuring review.command IS the opt-in — a project that runs a
  # reviewer on every mergeable PR and then merges the ones the reviewer never got to has gained
  # nothing. requireReview:false turns that implication off without giving up the reviewer, and an
  # explicit requireReview:true requires a verdict with no review.command (a reviewer run by hand
  # or by CI, recorded through `cckit receipt`).
  if [ -z "${KIT_CAPTAIN_REQUIRE_REVIEW:-}" ]; then
    case "$(_cap_cfg_bool "$cfg" requireReview)" in
      true)  KIT_CAPTAIN_REQUIRE_REVIEW=1 ;;
      false) KIT_CAPTAIN_REQUIRE_REVIEW=0 ;;
      *)     if command -v rs_enabled >/dev/null 2>&1 && rs_enabled "$cfg"; then
               KIT_CAPTAIN_REQUIRE_REVIEW=1
             else
               KIT_CAPTAIN_REQUIRE_REVIEW=0
             fi ;;
    esac
  fi
  export KIT_CAPTAIN_FLOORS KIT_CAPTAIN_EXTRA_GLOBS KIT_CAPTAIN_REQUIRE_CHECKS KIT_CAPTAIN_REQUIRE_REVIEW
}

# _cap_issue_of_branch <branch> — issue number a flow branch encodes (task/47-x, fix/9-y, effort/12-z).
#
# wt_issue_number when it is loaded, because the local regex requires a "-" immediately after the
# digits and so does NOT match the effort sub form `sub/<N><letter>-<slug>`. That was cosmetic while
# the number was only printed; it is not now — the review verdict is looked up BY issue (#348), so a
# sub-branch PR parsing to no issue would silently have no verdict to gate on and read CLEAN.
_cap_issue_of_branch() {
  if command -v wt_issue_number >/dev/null 2>&1; then
    wt_issue_number "$1"; return 0
  fi
  printf '%s' "$1" | sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p'
}

# captain_gate <pr#> — fetch + classify one PR. Echoes
# "pr<TAB>issue<TAB>state<TAB>action<TAB>title<TAB>reason<TAB>checks". A CLEAN PR that trips a policy
# floor (cap_policy_floor) is downgraded to HELD/hold so the captain never auto-merges it; `reason`
# carries the floor that tripped (empty otherwise). `checks` is the raw rollup token (FAIL/PENDING/
# PASS/NONE) — REPORTED, not re-decided, so captain_pass can say when a merge rests on NONE.
captain_gate() {
  local repo="$CAPTAIN_REPO" pr="$1" j mergeable mss checks review head issue state action title branch files labels reason
  j="$(gh pr view "$pr" --repo "$repo" --json number,title,headRefName,headRefOid,mergeable,mergeStateStatus,statusCheckRollup,files,labels 2>/dev/null)" \
    || { echo "captain: cannot read PR #$pr" >&2; return 1; }
  mergeable="$(printf '%s' "$j" | jq -r '.mergeable // "UNKNOWN"')"
  mss="$(printf '%s' "$j" | jq -r '.mergeStateStatus // "UNKNOWN"')"
  checks="$(printf '%s' "$j" | jq -c '.statusCheckRollup // []' | cap_checks_summary)"
  branch="$(printf '%s' "$j" | jq -r '.headRefName // ""')"
  title="$(printf '%s' "$j" | jq -r '.title // ""')"
  files="$(printf '%s' "$j" | jq -r '.files[]?.path // empty')"
  labels="$(printf '%s' "$j" | jq -r '[.labels[]?.name] | join(" ")')"
  issue="$(_cap_issue_of_branch "$branch")"
  # The review verdict is local state, not a GitHub field: sr_latest reads the receipt this repo's
  # reviewer wrote. No receipt, no issue, or no stage-receipt lib all collapse to NONE — absence,
  # which cap_classify gates on only when review is required.
  head="$(printf '%s' "$j" | jq -r '.headRefOid // ""')"
  review=NONE
  if [ -n "$issue" ] && command -v sr_latest >/dev/null 2>&1; then
    review="$(sr_latest "$issue" review 2>/dev/null | cap_review_summary "$head")"
    [ -n "$review" ] || review=NONE
  fi
  state="$(cap_classify "$mergeable" "$mss" "$checks" "$review")"
  action="$(cap_action "$state")"
  reason=""
  # Policy floor: only a would-be merge is at risk, so gate only the CLEAN/merge verdict.
  if [ "$action" = "merge" ]; then
    reason="$(cap_policy_floor "$files" "$labels")"
    [ -n "$reason" ] && { state="HELD"; action="hold"; }
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pr" "${issue:-—}" "$state" "$action" "$title" "$reason" "$checks" "$head"
}

# _cap_open_prs [effort] — open PR numbers, optionally only those whose branch-issue is a sub of <effort>.
_cap_open_prs() {
  local repo="$CAPTAIN_REPO" effort="${1:-}"
  if [ -n "$effort" ]; then
    local subs; subs="$(gh api "repos/$repo/issues/$effort/sub_issues" --paginate --jq '.[].number' 2>/dev/null | tr '\n' ' ')"
    local pr br iss
    gh pr list --repo "$repo" --state open --json number,headRefName \
      --jq '.[] | "\(.number)\t\(.headRefName)"' 2>/dev/null | while IFS="$(printf '\t')" read -r pr br; do
        iss="$(_cap_issue_of_branch "$br")"
        case " $subs " in *" $iss "*) printf '%s\n' "$pr" ;; esac
      done
  else
    gh pr list --repo "$repo" --state open --json number --jq '.[].number' 2>/dev/null
  fi
}

# captain_pass [--merge] [--effort N] — gate every open PR (in scope); merge the CLEAN ones if asked.
# Returns the count of PRs merged this pass via the CAPTAIN_MERGED global (for the loop to detect progress).
CAPTAIN_MERGED=0
captain_pass() {
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "captain: needs gh + jq" >&2; return 1; }
  local repo="$CAPTAIN_REPO" do_merge=0 effort="" dry=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --merge) do_merge=1; shift ;;
      --dry-run) dry=1; shift ;;
      --effort) effort="$2"; shift 2 ;;
      --effort=*) effort="${1#*=}"; shift ;;
      *) echo "captain_pass: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$repo" ] || { echo "captain: no repo (set KIT_REPO / CAPTAIN_REPO)" >&2; return 1; }
  CAPTAIN_MERGED=0
  _cap_load_policy_config   # bridge captain.mergePolicy from config into the floor env (env wins)

  local prs pr row state action issue issue_num title reason checks head merged_any=0 unproven=0 unreviewed=0
  prs="$(_cap_open_prs "$effort")"
  [ -n "$prs" ] || { echo "captain: no open PRs in scope"; return 0; }

  # The braces matter: redirections are processed left to right, so `: > "$f" 2>/dev/null` attempts
  # the redirect BEFORE the suppression applies and the shell reports the failure anyway. Wrapping
  # the whole group is what actually silences it. Ensure the dir first so it normally succeeds.
  command -v kit_state_ensure >/dev/null 2>&1 && kit_state_ensure || true
  { : > "$CAPTAIN_STATE"; } 2>/dev/null || true
  echo "captain: gating $(printf '%s\n' "$prs" | grep -c .) open PR(s)$( [ -n "$effort" ] && echo " for effort #$effort")"
  for pr in $prs; do
    row="$(captain_gate "$pr")" || continue
    state="$(printf '%s' "$row" | cut -f3)"
    action="$(printf '%s' "$row" | cut -f4)"
    issue="$(printf '%s' "$row" | cut -f2)"
    title="$(printf '%s' "$row" | cut -f5)"
    reason="$(printf '%s' "$row" | cut -f6)"
    checks="$(printf '%s' "$row" | cut -f7)"
    head="$(printf '%s' "$row" | cut -f8)"
    # Field 2 is a DISPLAY field carrying `—` for a PR whose branch encodes no issue. rs_issue_num
    # is what everything keying storage off it goes through — see its comment for why.
    issue_num="$issue"
    command -v rs_issue_num >/dev/null 2>&1 && issue_num="$(rs_issue_num "$issue")"
    { printf '%s\t%s\n' "$pr" "$state" >> "$CAPTAIN_STATE"; } 2>/dev/null || true
    # A merge resting on an EMPTY rollup: green was assumed, never observed. Counted here and named
    # once at the end of the pass, so the assumption is on screen even with the requirement OFF.
    if [ "$action" = "merge" ] && [ "$checks" = "NONE" ]; then unproven=$((unproven + 1)); fi
    # Same shape for the review stage: a PR the captain will merge with NO recorded verdict. Counted
    # only while review is NOT required, because once it is those PRs read REVIEW_MISSING -> verify
    # and never reach `merge` — so the advisory self-silences exactly like the checks one.
    if [ "$action" = "merge" ] && [ "${KIT_CAPTAIN_REQUIRE_REVIEW:-0}" != "1" ]; then
      local rv=NONE
      [ -n "$issue_num" ] && command -v sr_latest >/dev/null 2>&1 \
        && rv="$(sr_latest "$issue_num" review 2>/dev/null | cap_review_summary "$head")"
      [ "${rv:-NONE}" = "NONE" ] && unreviewed=$((unreviewed + 1))
    fi
    # Review stage (#346). Dispatch runs INSIDE this pass, before the merge decision is acted on,
    # so a PR the captain would merge gets a reviewer first. A fresh dispatch never unblocks the
    # same pass: the receipt it writes is read by the gate on the NEXT pass, which is correct —
    # a verdict must be recorded before it can be gated on, not assumed while the agent is running.
    # Off unless review.command is configured; rs_dispatch echoes rc 4 and does nothing then.
    if command -v rs_needs_dispatch >/dev/null 2>&1 && rs_enabled "$CAPTAIN_CFG"; then
      local have=0; rs_have_receipt "$issue_num" "$head" && have=1
      if rs_needs_dispatch "$state" "$action" "$have"; then
        if rs_dispatch "$CAPTAIN_CFG" "$repo" "$pr" "$issue_num" "$head" >/dev/null; then
          printf '  PR #%-4s %-14s -> reviewed (#%s %s)\n' "$pr" "$state" "$issue" "$title"
        fi
        # Held whether or not the reviewer succeeded. A failed dispatch leaves no receipt, and
        # no receipt is missing evidence, not a pass — the same rule the empty-rollup advisory
        # below states for checks.
        action=verify
      fi
    fi
    if [ "$action" = "merge" ] && [ "$do_merge" = "1" ] && [ "$dry" = "0" ]; then
      if gh pr merge "$pr" --repo "$repo" --squash --delete-branch >/dev/null 2>&1; then
        printf '  PR #%-4s %-14s MERGED   (#%s %s)\n' "$pr" "$state" "$issue" "$title"
        merged_any=$((merged_any + 1))
      else
        printf '  PR #%-4s %-14s merge FAILED (re-check)   (#%s %s)\n' "$pr" "$state" "$issue" "$title"
      fi
    elif [ "$action" = "hold" ]; then
      printf '  PR #%-4s %-14s -> HELD    (#%s %s) — policy floor: %s [human review; C overrides]\n' \
        "$pr" "$state" "$issue" "$title" "${reason:-protected}"
    else
      printf '  PR #%-4s %-14s -> %-7s (#%s %s)\n' "$pr" "$state" "$action" "$issue" "$title"
    fi
  done
  CAPTAIN_MERGED="$merged_any"

  # Say the assumption out loud. `requireChecks` is default-off, so this advisory is what keeps it
  # from being a safety feature nobody knows about: it fires at exactly the moment the risk is real
  # (a PR the captain will merge whose rollup was EMPTY), names the key that closes it, and
  # self-silences once the key is on — those PRs then read CHECKS_MISSING, so `unproven` stays 0.
  if [ "$unproven" -gt 0 ]; then
    printf 'captain: %s PR(s) read CLEAN with NO checks observed (empty rollup) — %s\n' \
      "$unproven" "green was ASSUMED, not proved."
    printf '         require evidence instead: captain.mergePolicy.requireChecks:true in your kit\n'
    printf '         config (or KIT_CAPTAIN_REQUIRE_CHECKS=1). Those PRs then read CHECKS_MISSING\n'
    printf '         -> verify, and the captain will not merge them.\n'
  fi

  # The review stage's counterpart advisory. It fires only when a reviewer could have run and did
  # not, names the two keys that close it, and goes quiet the moment either is on.
  if [ "$unreviewed" -gt 0 ]; then
    printf 'captain: %s PR(s) read CLEAN with NO agent review recorded.\n' "$unreviewed"
    printf '         run one: set review.command in your kit config (the captain then dispatches a\n'
    printf '         reviewer and requires its verdict). To require a verdict WITHOUT cckit running\n'
    printf '         the reviewer, set captain.mergePolicy.requireReview:true. Those PRs then read\n'
    printf '         REVIEW_MISSING -> verify, and the captain will not merge them.\n'
  fi

  # advance: after merges, the newly-unblocked work shows up as the next wave.
  if [ "$merged_any" -gt 0 ]; then
    echo "captain: merged $merged_any — next unblocked wave:"
    local here; here="$(dirname "${BASH_SOURCE[0]}")"
    if [ -f "$here/plan-machine.sh" ]; then
      # shellcheck source=/dev/null
      . "$here/plan-machine.sh"
      if [ -n "$effort" ]; then CCKIT_OUTPUT=human plan_machine --effort "$effort" 2>/dev/null || true
      else CCKIT_OUTPUT=human plan_machine 2>/dev/null || true; fi
    fi
  fi
}

# captain_loop — repeat passes until a pass merges nothing (steady state) or --max-passes is hit.
# Checkpointed: each pass overwrites CAPTAIN_STATE so a fresh invocation resumes from the live board.
captain_loop() {
  local max=10 pass=0
  local -a clean=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max-passes)   max="$2"; shift 2 ;;
      --max-passes=*) max="${1#*=}"; shift ;;
      *)              clean+=("$1"); shift ;;
    esac
  done
  case "$max" in ''|*[!0-9]*) max=10 ;; esac
  while [ "$pass" -lt "$max" ]; do
    pass=$((pass + 1))
    echo "── captain pass $pass/$max ──"
    captain_pass "${clean[@]+"${clean[@]}"}" || return 1
    [ "$CAPTAIN_MERGED" -gt 0 ] || { echo "captain: steady state (no CLEAN PR merged) — stopping at pass $pass"; break; }
  done
}
