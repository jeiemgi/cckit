#!/usr/bin/env bash
# shellcheck shell=bash
# review-stage.sh — run `review` as a real stage of the agent pipeline (#346).
#
# E318 declared `review` in SR_STAGES, let a profile be barred from it, and let a receipt name it as
# next_stage — but nothing dispatched a reviewer and nothing read a verdict. This file is the
# dispatch half; the merge gate that reads the verdict is separate on purpose (#348), so the gate
# stays testable against a receipt that this file never produced.
#
# WHO STARTS THE AGENT. cckit does not know. Every launcher it has is interactive —
# `or_herdr_launch` focuses a pane, `or_tmux_agent_cmd` writes a line into a pane's shell — and the
# captain runs with no pane and nobody watching. Non-interactive execution is an open gap owned by
# #257 (agent-compatibility.mdx, scenario A07), so this file does not invent one: the project names
# the command in `review.command` and cckit pipes a brief to its stdin and reads the report off its
# stdout. That is the same shape sr_record already takes, and it means cckit asserts nothing about
# any agent's flags. No `review.command` configured is the off switch, and it is the default.
#
# THE REVIEWER DOES NOT OWN THE BRANCH. A review profile must not write to the branch it reviews:
# ap_profile_writes defaults to false and branch-owner.sh already refuses a second writer. Nothing
# here claims a branch, and rs_dispatch refuses a write-capable profile outright rather than
# relying on the reviewer to behave.
# errors: mixed — the predicates and the brief are pure; rs_dispatch propagates rc 2 from
# ap_resolve_pr (undeclared/ambiguous/stage-barred profile) and from a write-capable profile, rc 3
# when the configured command fails, and rc 4 when no profile resolves at all.

# BASH_SOURCE is bash-only and empty under zsh, the session shell here; `dirname ""` then yields
# "." and the sibling source below silently missed. Same defect and same fix as kit-gc.sh:38 (#219):
# `${BASH_SOURCE[0]:-$0}` covers zsh, CDPATH='' and the redirect stop an interactive zsh echoing the
# directory into the substitution.
_rs_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
command -v ap_resolve_pr >/dev/null 2>&1 || . "$_rs_dir/agent-resolve.sh"
# shellcheck source=/dev/null
command -v sr_record >/dev/null 2>&1 || . "$_rs_dir/stage-receipt.sh"

# rs_command <cfg> — the command the project configured to run a reviewer. Empty when unset, which
# is what keeps the stage off in every project that has not opted in.
rs_command() {
  local cfg="${1:-}"
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0
  jq -r '.review.command // ""' "$cfg" 2>/dev/null || true
}

# rs_enabled <cfg> — rc 0 when a review command is configured.
rs_enabled() { [ -n "$(rs_command "${1:-}")" ]; }

# rs_needs_dispatch <action> <have-receipt> — rc 0 when this PR should get a reviewer now. Pure.
#
# Only a PR the captain would otherwise MERGE is worth a reviewer: one that conflicts, fails a
# check, or is still a draft will change before anyone should read it, and a review of the version
# that is about to be rewritten is wasted spend. `hold` is excluded for the opposite reason — a
# policy floor already routed it to a human, who does not need a second opinion first.
rs_needs_dispatch() {
  local action="${1:-}" have="${2:-}"
  [ "$action" = "merge" ] || return 1
  [ "$have" = "1" ] && return 1
  return 0
}

# rs_have_receipt <issue> — rc 0 when a review receipt already exists for that issue.
rs_have_receipt() {
  local n="${1:-}"
  [ -n "$n" ] || return 1
  sr_latest "$n" review >/dev/null 2>&1
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

# rs_dispatch <cfg> <repo> <pr> <issue> — resolve a reviewer, run it, record its verdict.
# Echoes the receipt path. The configured command receives the brief on stdin; its stdout is the
# report sr_record parses.
rs_dispatch() {
  local cfg="${1:-}" repo="${2:-}" pr="${3:-}" num="${4:-}"
  local cmd prof tier src ctx report rc_=0
  [ -n "$num" ] || { echo "review: PR #${pr:-?} has no linked issue — nothing to record a receipt against" >&2; return 2; }
  cmd="$(rs_command "$cfg")"
  [ -n "$cmd" ] || return 4

  prof="$(ap_resolve_pr "$cfg" "$repo" "$pr" review)" || { rc_=$?; return "$rc_"; }

  # A write-capable profile is refused here rather than trusted to stay read-only. The brief says
  # read-only and branch-owner.sh refuses a second writer, but both are downstream of a profile the
  # project already declared able to write — and a reviewer that commits to the branch it reviews
  # is the one failure this stage must not have.
  if ap_profile_writes "$cfg" "$prof"; then
    echo "review: profile '$prof' declares write:true — a reviewer must not own the branch it reviews" >&2
    return 2
  fi

  ctx="$(ap_pr_context "$repo" "$pr")"
  src="$(ap_resolve_source "$cfg" '' "$(printf '%s' "$ctx" | cut -f2)" "$(printf '%s' "$ctx" | cut -f3)")" || src=""
  tier="$(ap_profile_tier "$cfg" "$prof")"

  # The command runs with the brief on stdin. Its stdout is captured whole: a report that arrives
  # with no `outcome:` line is sr_record's refusal to make, not this function's to guess at.
  report="$(rs_brief "$repo" "$pr" "$num" | sh -c "$cmd" 2>/dev/null)" || {
    echo "review: the configured review.command failed for PR #$pr — no receipt written" >&2
    return 3
  }

  printf '%s\n' "$report" | sr_record "$num" review "$(sr_next_attempt "$num" review)" \
    "$prof" "$tier" "$src" "read-only"
}
