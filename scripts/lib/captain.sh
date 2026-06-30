#!/usr/bin/env bash
# captain.sh — the captain loop: gate open PRs, squash-merge the clean ones, advance the board to the
# next unblocked wave, and checkpoint so the loop can stop and resume (Effort 75 · #77).
#
# Autopilot has two halves. `orchestrate`/`autopilot` LAUNCH the per-issue flows; the captain CLOSES
# them — it inspects each PR, decides (CLEAN / CONFLICTING / CHECKS_FAILING / CHECKS_PENDING / DRAFT /
# BLOCKED), merges what is ready, and lets the freshly-merged issues unblock the next wave. This is
# the half that used to be left to the driving agent; now it is a script the agent (or `cckit watch`)
# runs in a loop.
#
#   cckit watch                 one pass: gate every open PR, report (no merge) — safe default
#   cckit watch --merge         gate + squash-merge the CLEAN PRs, then show the next wave
#   cckit watch --effort <N>    scope to PRs for effort #N's sub-issues
#   cckit watch --loop          repeat passes until no CLEAN PR remains (checkpointed), then stop
#   cckit watch --max-passes M  cap the loop at M passes (default 10)
#
# Gate decision is three pure helpers (cap_checks_summary / cap_classify / cap_action) so the policy
# is unit-tested without the network. Requires gh + jq. bash 3.2 / zsh compatible.

CAPTAIN_REPO="${CAPTAIN_REPO:-${KIT_REPO:-}}"
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

# cap_classify <mergeable> <mergeStateStatus> <checksSummary> — pure verdict for one PR.
# mergeable: MERGEABLE|CONFLICTING|UNKNOWN · mss: CLEAN|DIRTY|DRAFT|BLOCKED|BEHIND|UNSTABLE|…
cap_classify() {
  local mergeable="$1" mss="$2" checks="$3"
  case "$mss" in DRAFT) echo DRAFT; return 0 ;; esac
  case "$mergeable" in CONFLICTING) echo CONFLICTING; return 0 ;; esac
  case "$mss" in DIRTY) echo CONFLICTING; return 0 ;; esac
  case "$checks" in
    FAIL)    echo CHECKS_FAILING; return 0 ;;
    PENDING) echo CHECKS_PENDING; return 0 ;;
  esac
  case "$mergeable" in
    MERGEABLE)
      # passing or no required checks, and not draft/dirty/conflicting -> ready.
      case "$mss" in CLEAN|UNSTABLE|HAS_HOOKS|"") echo CLEAN; return 0 ;; esac
      echo BLOCKED; return 0 ;;
  esac
  echo BLOCKED
}

# cap_action <state> — the action the captain takes for a verdict.
cap_action() {
  case "$1" in
    CLEAN)          echo merge ;;
    CONFLICTING)    echo rebase ;;
    CHECKS_FAILING) echo fix ;;
    CHECKS_PENDING) echo wait ;;
    DRAFT)          echo wait ;;
    *)              echo skip ;;
  esac
}

# _cap_issue_of_branch <branch> — issue number a flow branch encodes (task/47-x, fix/9-y, effort/12-z).
_cap_issue_of_branch() {
  printf '%s' "$1" | sed -nE 's#^[a-z]+/([0-9]+)-.*#\1#p'
}

# captain_gate <pr#> — fetch + classify one PR. Echoes "pr<TAB>issue<TAB>state<TAB>action<TAB>title".
captain_gate() {
  local repo="$CAPTAIN_REPO" pr="$1" j mergeable mss checks issue state action title branch
  j="$(gh pr view "$pr" --repo "$repo" --json number,title,headRefName,mergeable,mergeStateStatus,statusCheckRollup 2>/dev/null)" \
    || { echo "captain: cannot read PR #$pr" >&2; return 1; }
  mergeable="$(printf '%s' "$j" | jq -r '.mergeable // "UNKNOWN"')"
  mss="$(printf '%s' "$j" | jq -r '.mergeStateStatus // "UNKNOWN"')"
  checks="$(printf '%s' "$j" | jq -c '.statusCheckRollup // []' | cap_checks_summary)"
  branch="$(printf '%s' "$j" | jq -r '.headRefName // ""')"
  title="$(printf '%s' "$j" | jq -r '.title // ""')"
  issue="$(_cap_issue_of_branch "$branch")"
  state="$(cap_classify "$mergeable" "$mss" "$checks")"
  action="$(cap_action "$state")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$pr" "${issue:-—}" "$state" "$action" "$title"
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

  local prs pr row state action issue title merged_any=0
  prs="$(_cap_open_prs "$effort")"
  [ -n "$prs" ] || { echo "captain: no open PRs in scope"; return 0; }

  : > "$CAPTAIN_STATE" 2>/dev/null || true
  echo "captain: gating $(printf '%s\n' "$prs" | grep -c .) open PR(s)$( [ -n "$effort" ] && echo " for effort #$effort")"
  for pr in $prs; do
    row="$(captain_gate "$pr")" || continue
    state="$(printf '%s' "$row" | cut -f3)"
    action="$(printf '%s' "$row" | cut -f4)"
    issue="$(printf '%s' "$row" | cut -f2)"
    title="$(printf '%s' "$row" | cut -f5)"
    printf '%s\t%s\n' "$pr" "$state" >> "$CAPTAIN_STATE" 2>/dev/null || true
    if [ "$action" = "merge" ] && [ "$do_merge" = "1" ] && [ "$dry" = "0" ]; then
      if gh pr merge "$pr" --repo "$repo" --squash --delete-branch >/dev/null 2>&1; then
        printf '  PR #%-4s %-14s MERGED   (#%s %s)\n' "$pr" "$state" "$issue" "$title"
        merged_any=$((merged_any + 1))
      else
        printf '  PR #%-4s %-14s merge FAILED (re-check)   (#%s %s)\n' "$pr" "$state" "$issue" "$title"
      fi
    else
      printf '  PR #%-4s %-14s -> %-7s (#%s %s)\n' "$pr" "$state" "$action" "$issue" "$title"
    fi
  done
  CAPTAIN_MERGED="$merged_any"

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
