#!/usr/bin/env bash
# shellcheck shell=bash
# review-stage.sh — run `review` as a real stage of the agent pipeline (#346).
#
# E318 declared `review` in SR_STAGES, let a profile be barred from it, and let a receipt name it as
# next_stage — but nothing dispatched a reviewer and nothing read a verdict. This file is the
# dispatch half; the merge gate that reads the verdict is separate on purpose (#348), so the gate
# stays testable against a receipt that this file never produced.
#
# WHO STARTS THE AGENT. The shared headless launcher (agent-launch.sh, E257.7): cckit pipes a brief
# to the command's stdin, bounds it, and reads the report off its stdout — the same shape sr_record
# already takes. Two ways to name the command, and neither is on by default:
#   review.command        the project's own command line. It wins when set, so a project that
#                         wraps its reviewer keeps doing so.
#   review.headless true  cckit builds the line from the resolved profile's kind and args:
#                         `claude -p` or `codex exec -`. A kind with no headless form is refused.
# With neither set the stage is off.
#
# THE REVIEWER DOES NOT OWN THE BRANCH. A review profile must not write to the branch it reviews:
# ap_profile_writes defaults to false and branch-owner.sh already refuses a second writer. Nothing
# here claims a branch, and rs_dispatch refuses a write-capable profile outright rather than
# relying on the reviewer to behave.
# errors: mixed — the predicates and the brief are pure; rs_dispatch propagates rc 2 from
# ap_resolve_pr (undeclared/ambiguous/stage-barred profile) and from a write-capable profile, rc 3
# when the configured command fails, and rc 4 when no profile resolves at all. The issue mirror
# never changes the rc — sr_mirror is best-effort and a lost mirror does not lose the verdict.

# BASH_SOURCE is bash-only and empty under zsh, the session shell here; `dirname ""` then yields
# "." and the sibling source below silently missed. Same defect and same fix as kit-gc.sh:38 (#219):
# `${BASH_SOURCE[0]:-$0}` covers zsh, CDPATH='' and the redirect stop an interactive zsh echoing the
# directory into the substitution.
_rs_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
command -v ap_resolve_pr >/dev/null 2>&1 || . "$_rs_dir/agent-resolve.sh"
# shellcheck source=/dev/null
command -v sr_record >/dev/null 2>&1 || . "$_rs_dir/stage-receipt.sh"
# shellcheck source=/dev/null
command -v al_run >/dev/null 2>&1 || . "$_rs_dir/agent-launch.sh"

# rs_command <cfg> — the command the project configured to run a reviewer. Empty when unset, which
# is what keeps the stage off in every project that has not opted in.
rs_command() {
  local cfg="${1:-}"
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0
  jq -r '.review.command // ""' "$cfg" 2>/dev/null || true
}

# rs_headless <cfg> — rc 0 when `review.headless` is true: cckit builds the reviewer's command from
# the resolved profile instead of reading one from `review.command`.
rs_headless() {
  local cfg="${1:-}"
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 1
  [ "$(jq -r '.review.headless // false' "$cfg" 2>/dev/null)" = "true" ]
}

# rs_enabled <cfg> — rc 0 when the stage is on: a review command is configured, or review.headless.
rs_enabled() { [ -n "$(rs_command "${1:-}")" ] || rs_headless "${1:-}"; }

# rs_needs_dispatch <state> <action> <have-receipt> — rc 0 when this PR should get a reviewer now.
# Pure.
#
# Only a PR the captain would otherwise MERGE is worth a reviewer: one that conflicts, fails a
# check, or is still a draft will change before anyone should read it, and a review of the version
# that is about to be rewritten is wasted spend. `hold` is excluded for the opposite reason — a
# policy floor already routed it to a human, who does not need a second opinion first.
#
# REVIEW_MISSING is the second way in, and leaving it out DEADLOCKED the feature. Configuring
# review.command turns the requirement on, so the first pass over an unreviewed PR classifies it
# REVIEW_MISSING, whose action is `verify` — not `merge`. With a merge-only predicate the reviewer
# never ran, the receipt never appeared, and the PR sat at `verify` for good. cap_classify only
# returns REVIEW_MISSING where it would otherwise have returned CLEAN, so it names exactly the PR
# that has earned a reviewer; the state is what says so once the gate is on.
rs_needs_dispatch() {
  local state="${1:-}" action="${2:-}" have="${3:-}"
  [ "$have" = "1" ] && return 1
  [ "$state" = "REVIEW_MISSING" ] && return 0
  [ "$action" = "merge" ] || return 1
  return 0
}

# rs_issue_num <field> — the issue number out of captain_gate's DISPLAY field, empty when it is not
# one. That field carries `—` for a PR whose branch encodes no issue, so the printed rows read
# well; everything that keys STORAGE off it must see empty instead. sr_path would otherwise build a
# receipt filename containing `—`, one file shared by every unlinked PR in the repo, and one PR
# would read another's verdict as its own.
rs_issue_num() {
  case "${1:-}" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$1" ;; esac
}

# rs_have_receipt <issue> [<head-sha>] — rc 0 when a review verdict already covers that revision.
#
# With a head, a receipt recorded against a DIFFERENT commit does not count: the reviewer read code
# that is no longer there, so the PR has earned a fresh review, not a skip. Without one the check
# is by issue alone, which is what a caller with no revision to compare can ask.
rs_have_receipt() {
  local n="${1:-}" head="${2:-}" got
  [ -n "$n" ] || return 1
  got="$(sr_latest "$n" review 2>/dev/null)" || return 1
  [ -n "$got" ] || return 1
  [ -n "$head" ] || return 0
  [ "$(printf '%s' "$got" | jq -r '.head_sha // ""' 2>/dev/null)" = "$head" ]
}

# rs_brief <repo> <pr> <issue> — the prompt handed to the reviewer on stdin.
#
# Three things it must carry and never lose: that no human will answer a question, that the reviewer
# may not write, and the exact shape sr_parse reads back. The last is why the closing block is
# spelled out rather than summarized — a report in any other shape records `outcome:` as empty, and
# sr_record refuses it.
#
# The words in that block are SR_OUTCOMES and SR_GATES, not a description of them. A reviewer told
# to say `shipped` writes a receipt sr_invalid_fields flags, because `shipped` is not in the
# vocabulary — the receipt is still recorded (that is deliberate, see sr_invalid_fields) but it
# carries a flag no captain should have to interpret. `pr-open` and `blocked` are the two states a
# review can leave a PR in: it does not merge and it does not close.
rs_brief() {
  local repo="${1:-?}" pr="${2:-?}" num="${3:-?}"
  cat <<EOF
You are reviewing pull request #$pr in $repo. You are running HEADLESS: there is no human in this
session to answer a question, so decide within what the diff shows and finish.

READ ONLY. Do not commit, push, amend, rebase, or edit any file. You do not own this branch and a
second writer on it is refused. Read the diff and say what you found.

Review PR #$pr (issue #$num). Report defects you can point at in the diff: a wrong result for a
stated input, an unhandled case the code claims to handle, a check that cannot fail, a test that
asserts nothing. Say the file and line. Do not report style preferences, and do not restate what
the diff does.

## Finish like this
outcome: <pr-open|blocked>
url: https://github.com/$repo/pull/$pr
gate: <pass|fail> — <what you read>
blocker: <the defect that stops this merging, or none>
next stage: <none if it may merge, build if it goes back to the author>
EOF
}

# rs_timeout <cfg> — seconds a reviewer may run, from `review.timeoutSeconds`. Default 900.
# A non-numeric or non-positive value is ignored with a warning rather than disabling the bound:
# `timeoutSeconds: "none"` reads like a request for no limit, and honouring that would hand an
# unattended captain the hang this exists to prevent.
rs_timeout() {
  local cfg="${1:-}" v
  v="$(jq -r '.review.timeoutSeconds // ""' "$cfg" 2>/dev/null)" || v=""
  case "$v" in
    ''|*[!0-9]*) [ -n "$v" ] && echo "review: review.timeoutSeconds '$v' is not a positive integer — using 900" >&2
                 printf '900\n' ;;
    0)           echo "review: review.timeoutSeconds 0 is not a positive integer — using 900" >&2
                 printf '900\n' ;;
    *)           printf '%s\n' "$v" ;;
  esac
}

# rs_dispatch <cfg> <repo> <pr> <issue> [<head-sha>] — resolve a reviewer, run it, record its
# verdict. <head-sha> is the PR head the review applies to; it is stored on the receipt so a
# later commit cannot inherit this verdict (#351 review).
# Echoes the receipt path. The command receives the brief on stdin; its stdout is the report
# sr_record parses. The command is `review.command`, or the profile's headless form under
# `review.headless`; al_run (agent-launch.sh) bounds either.
rs_dispatch() {
  local cfg="${1:-}" repo="${2:-}" pr="${3:-}" num="${4:-}" head="${5:-}"
  local cmd prof tier src kind args ctx il pl report attempt path secs rc_=0
  [ -n "$num" ] || { echo "review: PR #${pr:-?} has no linked issue — nothing to record a receipt against" >&2; return 2; }
  cmd="$(rs_command "$cfg")"
  [ -n "$cmd" ] || rs_headless "$cfg" || return 4

  # ONE context fetch, not two. ap_resolve_pr fetches it internally and a second call for
  # ap_resolve_source would fetch again — two round trips whose answers can disagree, since every
  # fetch is best-effort and a label can change between them. profile_source would then describe a
  # different selection than profile. Resolve from the fields directly instead.
  ctx="$(ap_pr_context "$repo" "$pr")"
  il="$(printf '%s' "$ctx" | cut -f2)"
  pl="$(printf '%s' "$ctx" | cut -f3)"
  prof="$(ap_resolve "$cfg" review '' "$il" "$pl")" || { rc_=$?; return "$rc_"; }
  src="$(ap_resolve_source "$cfg" '' "$il" "$pl")" || src=""
  tier="$(ap_profile_tier "$cfg" "$prof")"

  # A write-capable profile is refused here rather than trusted to stay read-only. The brief says
  # read-only and branch-owner.sh refuses a second writer, but both are downstream of a profile the
  # project already declared able to write — and a reviewer that commits to the branch it reviews
  # is the one failure this stage must not have.
  if ap_profile_writes "$cfg" "$prof"; then
    echo "review: profile '$prof' declares write:true — a reviewer must not own the branch it reviews" >&2
    return 2
  fi

  # The resolved profile reaches the command as environment, because cckit cannot build the argv
  # itself (see the header). Without this, an `agent:<profile>` label selected a profile that only
  # labelled the receipt while a fixed command ran something else — resolution the receipt claimed
  # and the run did not honour. A review.command that ignores these still works; one that reads
  # CCKIT_REVIEW_KIND / CCKIT_REVIEW_ARGS can dispatch the agent the label actually asked for.
  kind="$(ap_profile_field "$cfg" "$prof" kind)"
  args="$(ap_profile_args "$cfg" "$prof")"

  # No review.command: build the reviewer's line from the profile. Text mode, because the reply IS
  # the report sr_record parses. A kind with no headless form is refused here — a receipt recorded
  # from a command cckit guessed at would be a verdict nobody asked that agent for.
  if [ -z "$cmd" ]; then
    cmd="$(al_headless_cmd "$kind" text "$args")" || {
      echo "review: review.headless is on but profile '$prof' is kind '${kind:-?}' — set review.command for it" >&2
      return 2
    }
  fi

  # Bound the run. The captain is unattended and single-threaded: a reviewer that never returns
  # blocks the whole pass, every other PR in it included, with no human to notice. al_run needs no
  # timeout(1), so the bound holds on macOS too.
  secs="$(rs_timeout "$cfg")"
  report="$(rs_brief "$repo" "$pr" "$num" \
    | CCKIT_REVIEW_PROFILE="$prof" CCKIT_REVIEW_KIND="$kind" CCKIT_REVIEW_ARGS="$args" \
      CCKIT_REVIEW_PR="$pr" CCKIT_REVIEW_ISSUE="$num" CCKIT_REVIEW_REPO="$repo" \
      al_run "$secs" "$cmd" 2>/dev/null)" || {
    rc_=$?
    if [ "$rc_" = "124" ]; then
      echo "review: the reviewer exceeded ${secs}s for PR #$pr — killed, no receipt written" >&2
    else
      echo "review: the reviewer command failed for PR #$pr — no receipt written" >&2
    fi
    return 3
  }

  attempt="$(sr_next_attempt "$num" review)"
  path="$(printf '%s\n' "$report" | sr_record "$num" review "$attempt" "$prof" "$tier" "$src" "read-only" "$head")" || return $?

  # Mirror onto the issue so the verdict is readable on GitHub, not only in local .cckit/ state.
  # BEST-EFFORT by sr_mirror's own contract (always rc 0, outcome in SR_MIRROR_LAST_RESULT): an
  # unmirrored verdict is still a verdict. The receipt on disk is what the merge gate reads, so
  # failing the dispatch on an offline or rate-limited mirror would stall every PR at `verify` over
  # a visibility problem.
  #
  # A caller that wants to know WHETHER it posted must not wrap this call in `$(…)`:
  # SR_MIRROR_LAST_RESULT would then be set in a subshell that immediately exits. Redirect the
  # receipt path to a file instead. captain_pass does exactly that (`>/dev/null`).
  SR_REPO="$repo" sr_mirror "$num" review "$attempt" "$path"

  printf '%s\n' "$path"
}
