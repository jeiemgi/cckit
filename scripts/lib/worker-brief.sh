#!/usr/bin/env bash
# shellcheck shell=bash
# worker-brief.sh — compose the ONE prompt a headless worker receives, bounded (#321).
#
# `cckit brief` (kit-brief.sh) answers "what does this issue involve". This file answers a different
# question: what may a worker be TOLD, and how much of it fits. Three constraints, none of which the
# brief itself can enforce because it does not know the profile:
#
#   1. BOUNDED. A profile's `contextBudget` was declared in the schema and read by nothing. An
#      unbounded brief spends the worker's window before it has read a line of code.
#   2. NAMED OMISSIONS. Truncating mid-sentence hands the worker a brief it believes is complete.
#      Whole sections are dropped from the END and the cut is stated, with the command that
#      recovers them, so a partial brief reads as partial.
#   3. INVARIANTS SURVIVE. The headless framing and the receipt contract are never cut. A worker
#      that loses the framing asks a human who is not there; one that loses the contract reports in
#      whatever shape it likes and the receipt (#322) has nothing to parse.
#
# What is NOT here, deliberately: the board, other issues, and prior conversations. The worker gets
# its own issue and nothing else — `wb_has_board` is the check that keeps it that way.
# errors: strict — wb_fit returns 2 when the budget cannot hold the invariants; the rest are pure.

# wb_preamble <num> <branch> — the headless framing. Never truncated.
wb_preamble() {
  local num="${1:-?}" branch="${2:-?}"
  cat <<EOF
You are running HEADLESS inside a cckit orchestration. There is no human in this worker session:
decide within the issue's scope and proceed. Do not read the board, do not open another issue, and
do not act on work that is not issue #$num. Work only on issue #$num in branch $branch.
EOF
}

# wb_receipt_contract <num> — the shape the worker must report back in. Never truncated.
#
# The five fields are #318's acceptance, in that order. `outcome` and `next stage` were missing from
# the seed's closing line, so a receipt could not say whether the work landed or what follows it —
# the two things a captain needs to decide the next wave without reading the transcript.
wb_receipt_contract() {
  local num="${1:-?}"
  cat <<EOF
## Finish like this

Run the gate above until it is green, then open the PR:

    cckit pr $num "<summary>"

If no change is needed, close the issue yourself with the reason:

    cckit close $num "<reason>"

Report ONLY this receipt — no transcript, no summary of your reasoning:

    outcome:    merged | pr-open | closed-no-op | blocked
    url:        <PR or issue URL>
    gate:       pass | fail — <the failing check, if any>
    blocker:    <what stopped you, or: none>
    next stage: build | review | design | docs | none
EOF
}

# wb_profile_budget <cfg> <profile> — echo the profile's contextBudget in bytes, empty when unset
# or when it is not a positive integer. An unparseable budget is treated as absent rather than as
# zero: refusing to brief a worker because a config value was misspelled is the worse failure.
wb_profile_budget() {
  local cfg="${1:-}" name="${2:-}" v
  [ -n "$cfg" ] && [ -f "$cfg" ] && [ -n "$name" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  v="$(jq -r --arg n "$name" '(.agents.profiles[$n].contextBudget) // "" | tostring' "$cfg" 2>/dev/null)"
  case "$v" in
    ''|*[!0-9]*) return 0 ;;
    0) return 0 ;;
    *) printf '%s\n' "$v" ;;
  esac
}

# wb_has_board — rc 0 when stdin looks like it carries board state rather than one issue. The test
# for constraint 3: a brief naming several issue numbers in list position is the board leaking in.
# Deliberately crude — it guards a property, it does not parse markdown.
wb_has_board() {
  grep -qE '^[[:space:]]*[-|*][[:space:]]*#[0-9]+|^\|[[:space:]]*#?[0-9]+[[:space:]]*\|'
}

# wb_sections — stdin is markdown; echo each `## ` heading's title, one per line, in order.
wb_sections() {
  sed -n 's/^##[[:space:]]\{1,\}//p'
}

# wb_fit <budget> <head-file> <tail-file> — stdin is the cuttable middle. Emit head + as many of
# the middle's `## ` sections as fit + tail, within <budget> bytes.
#
# Sections are dropped from the END because the brief orders them that way already: what the issue
# owns, then the helpers, then the standing gotchas. The first is unrecoverable from elsewhere; the
# last is a rule file the worker can read on its own.
#
# rc 2 when head + tail alone exceed the budget. They are still emitted — a worker with no framing
# and no receipt contract is worse than one that overran a number — and the caller is told, because
# a budget that cannot hold the invariants is a config error someone has to fix.
_wb_note() {
  local kept="${1:-0}" n_total="${2:-0}" names="${3:-}" dropped
  [ "$kept" -lt "$n_total" ] || return 0
  # `paste -d` takes a LIST of delimiters and cycles them, so `-d', '` joins with a comma, then a
  # space, then a comma — `a,b c,d`. One delimiter, then widen it.
  dropped="$(printf '%s\n' "$names" | grep . | tail -n +$(( kept + 1 )) | paste -sd, - | sed 's/,/, /g')"
  printf '\n_%s section(s) omitted to fit this profile'"'"'s contextBudget: %s. Read them with `cckit brief`._\n' \
    "$(( n_total - kept ))" "$dropped"
}

wb_fit() {
  local budget="${1:-}" head="${2:-}" tail="${3:-}" mid base kept=0 out sec_names n_total try i
  mid="$(cat)"
  if [ -z "$budget" ]; then
    cat "$head"; printf '%s\n' "$mid"; cat "$tail"
    return 0
  fi

  base=$(( $(wc -c < "$head") + $(wc -c < "$tail") ))
  sec_names="$(printf '%s\n' "$mid" | wb_sections)"
  n_total="$(printf '%s\n' "$sec_names" | grep -c . || true)"

  # The floor is head + tail + the WORST-CASE omission note (every section dropped). The note is an
  # invariant too: a truncated brief that cannot afford to say it was truncated reads as complete,
  # which is the failure this whole file exists to avoid. Leaving it out of the floor is how the
  # first version overran its budget by the width of the sentence announcing the truncation.
  if [ $(( base + $(_wb_note 0 "$n_total" "$sec_names" | wc -c) )) -ge "$budget" ]; then
    cat "$head"; cat "$tail"
    echo "worker-brief: contextBudget $budget cannot hold the framing, the receipt contract and a truncation notice (${base}+ bytes); nothing else was included" >&2
    return 2
  fi

  # Grow the kept prefix one section at a time. Counting up rather than trimming down means the
  # answer is the same whether a section is 10 bytes or 10 kilobytes.
  #
  # The omission note is measured INSIDE the loop, for the exact number of sections that candidate
  # drops. Reserving it up front would be circular — how long the note is depends on how many
  # sections drop, which depends on whether the note fits — and leaving it out entirely is how the
  # first version overran its own budget by the width of the sentence announcing the truncation.
  out=""
  i=1
  while [ "$i" -le "${n_total:-0}" ]; do
    try="$(printf '%s\n' "$mid" | awk -v want="$i" '
      /^##[[:space:]]/ { n++ }
      (n == 0 || n <= want) { print }
    ')"
    if [ $(( base + $(printf '%s\n' "$try" | wc -c) + $(_wb_note "$i" "$n_total" "$sec_names" | wc -c) )) -le "$budget" ]; then
      out="$try"; kept="$i"
    else
      break
    fi
    i=$(( i + 1 ))
  done

  cat "$head"
  [ -n "$out" ] && printf '%s\n' "$out"
  _wb_note "$kept" "$n_total" "$sec_names"
  cat "$tail"
  return 0
}

# wb_compose <num> <branch> <budget> — stdin is the issue brief. Emit the whole worker prompt.
#
# The brief's text BEFORE its first `## ` heading joins the head rather than the cuttable middle.
# That preamble is the issue title, the worktree, the branch, the seed freshness and the gate
# command — where to work and what must pass. A worker that loses it cannot start, so it is an
# invariant on the same footing as the framing and the receipt contract, not the cheapest section
# to drop. Only the `## ` sections below it compete for the remaining budget.
wb_compose() {
  local num="${1:-?}" branch="${2:-?}" budget="${3:-}" tmp rc=0 brief
  brief="$(cat)"
  tmp="$(mktemp -d)" || return 1
  {
    wb_preamble "$num" "$branch"
    printf '\n'
    printf '%s\n' "$brief" | awk '/^##[[:space:]]/ { exit } { print }'
  } > "$tmp/head"
  { printf '\n'; wb_receipt_contract "$num"; } > "$tmp/tail"
  printf '%s\n' "$brief" | awk 'f || /^##[[:space:]]/ { f = 1; print }' \
    | wb_fit "$budget" "$tmp/head" "$tmp/tail" || rc=$?
  rm -rf "$tmp"
  return $rc
}
