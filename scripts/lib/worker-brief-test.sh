#!/usr/bin/env bash
# worker-brief-test.sh — the bounded worker prompt (#321).
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/worker-brief.sh"

fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
yes() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> missing '$3' in [$2]"; fail=1 ;; esac; }
no()  { case "$2" in *"$3"*) echo "FAIL: $1 -> found '$3' in [$2]"; fail=1 ;; *) echo "ok: $1" ;; esac; }

# Sections 2 and 3 are padded far larger than section 1 so a budget can keep exactly one of them
# without the test depending on byte-level arithmetic that drifts whenever the wording changes.
PAD="$(printf 'x%.0s' $(seq 1 2000))"
BRIEF="$(cat <<EOF
# Delegation brief — #41

- gate: \`bash scripts/check.sh\` must pass before the PR

## Files this issue owns

- \`scripts/one.sh\`

## Helpers you already have

$PAD

## Standing gotchas

- Refresh the base first. $PAD
EOF
)"


# ── the invariants ─────────────────────────────────────────────────────────────────────────────
pre="$(wb_preamble 41 task/41-x)"
yes "the preamble names the issue" "$pre" "issue #41"
yes "the preamble names the branch" "$pre" "branch task/41-x"
yes "the preamble forbids reading the board" "$pre" "Do not read the board"

rc="$(wb_receipt_contract 41)"
for f in outcome url gate blocker "next stage"; do
  yes "the receipt contract declares '$f'" "$rc" "$f:"
done
yes "the receipt contract names the PR verb" "$rc" "cckit pr 41"
yes "the receipt contract names the no-op close" "$rc" "cckit close 41"
# The contract must name the verb that PERSISTS it (#322). A prompt that only asks the worker to
# "report" leaves the record in the pane, which is what the receipt exists to replace.
yes "the receipt contract names the recording verb" "$rc" "cckit receipt 41 --stage"
yes "the receipt contract says a re-run is safe" "$rc" "rewrites its own attempt"

# ── unbounded: everything survives ─────────────────────────────────────────────────────────────
full="$(printf '%s\n' "$BRIEF" | wb_compose 41 task/41-x '')"
yes "with no budget the gotchas survive" "$full" "Refresh the base first"
yes "with no budget the framing survives" "$full" "running HEADLESS"
yes "with no budget the contract survives" "$full" "next stage:"
no  "an unbounded brief claims no omission" "$full" "omitted to fit"

# ── bounded: sections drop from the END, and the cut is stated ──────────────────────────────────
# A budget with room for the invariants and the small first section, but not for either 2 KB one.
one=$(( $(wb_preamble 41 task/41-x | wc -c) + $(wb_receipt_contract 41 | wc -c) + 600 ))
cut="$(printf '%s\n' "$BRIEF" | wb_compose 41 task/41-x "$one")"
yes "the first section is kept" "$cut" "scripts/one.sh"
no  "a later section is dropped" "$cut" "Refresh the base first"
yes "the cut is stated, not silent" "$cut" "omitted to fit"
yes "the omission NAMES what was dropped" "$cut" "Standing gotchas"
# `paste -d` cycles a LIST of delimiters, so `-d', '` joined names as `a,b c,d`.
yes "dropped names are comma-separated, not delimiter-cycled" "$cut" "Helpers you already have, Standing gotchas"
# The brief's pre-section metadata is where to work and what must pass — an invariant, not the
# cheapest section to drop.
yes "truncation keeps the brief's gate line" "$cut" "bash scripts/check.sh"
yes "truncation keeps the brief's title line" "$cut" "Delegation brief"
yes "the omission says how to recover it" "$cut" "cckit brief"
# Constraint 3: dropping sections must never drop the framing or the contract.
yes "truncation keeps the headless framing" "$cut" "running HEADLESS"
yes "truncation keeps the receipt contract" "$cut" "next stage:"
if [ "$(printf '%s' "$cut" | wc -c)" -le "$one" ]; then
  echo "ok: the bounded brief is within its budget"
else
  echo "FAIL: the bounded brief overran its budget"; fail=1
fi

# A budget too small for the invariants still emits them, and SAYS so — a worker with no receipt
# contract reports in a shape nothing can parse, which is worse than overrunning a number.
tiny="$(printf '%s\n' "$BRIEF" | wb_compose 41 task/41-x 10 2>/dev/null)"; trc=$?
t   "an impossible budget is reported as rc 2" "$trc" "2"
yes "an impossible budget still emits the framing" "$tiny" "running HEADLESS"
yes "an impossible budget still emits the contract" "$tiny" "next stage:"
yes "an impossible budget explains itself on stderr" \
  "$(printf '%s\n' "$BRIEF" | wb_compose 41 task/41-x 10 2>&1 >/dev/null)" "cannot hold the framing"

# ── the budget comes from the profile ──────────────────────────────────────────────────────────
cfg="$(mktemp)"
cat > "$cfg" <<'JSON'
{"agents":{"profiles":{
  "cheap":{"kind":"claude","contextBudget":4096},
  "loose":{"kind":"claude"},
  "bad":{"kind":"claude","contextBudget":"lots"},
  "zero":{"kind":"claude","contextBudget":0}
}}}
JSON
t "a declared budget is read" "$(wb_profile_budget "$cfg" cheap)" "4096"
t "an unset budget is empty (unbounded)" "$(wb_profile_budget "$cfg" loose)" ""
# Treated as absent, not as zero: refusing to brief a worker over a typo is the worse failure.
t "a non-numeric budget is treated as unset" "$(wb_profile_budget "$cfg" bad)" ""
t "a zero budget is treated as unset" "$(wb_profile_budget "$cfg" zero)" ""
t "an undeclared profile has no budget" "$(wb_profile_budget "$cfg" nope)" ""
rm -f "$cfg"

# ── the board never reaches a worker ───────────────────────────────────────────────────────────
printf '%s\n' "$full" | wb_has_board; t "a one-issue brief carries no board" "$?" "1"
printf -- '- #41 one\n- #42 two\n' | wb_has_board; t "an issue list IS board state" "$?" "0"
printf -- '| #41 | one |\n' | wb_has_board; t "a board table IS board state" "$?" "0"

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "worker brief: FAILURES"
exit "$fail"
