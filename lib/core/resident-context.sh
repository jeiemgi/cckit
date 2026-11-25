#!/usr/bin/env bash
# resident-context.sh — the resident-context ratchet for this repository.
#
# Resident context is what an agent session loads before it reads a single file of the task:
# AGENTS.md, a root CLAUDE.md if there is one, and every `.claude/rules/*.md` with no `paths:`
# frontmatter (counted by instruction-budget-lint.sh --resident-bytes). The total may not grow past
# the number in lib/core/resident-context.baseline. Lower the baseline in the change that shrinks
# the total; raise it only on purpose.
#
#   lib/core/resident-context.sh            check against the baseline (rc 1 one byte over)
#   lib/core/resident-context.sh --bytes    the current total, a bare number
#   lib/core/resident-context.sh --update   write the current total as the baseline
#
# RESIDENT_CONTEXT_ROOT measures another directory (the test points it at a fixture).
# errors: strict — rc 1 over the baseline, rc 2 on a missing or unreadable baseline
set -uo pipefail
LC_ALL=C
export LC_ALL

HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
ROOT="${RESIDENT_CONTEXT_ROOT:-$(cd "$HERE/../.." && pwd)}"
BASELINE="$ROOT/lib/core/resident-context.baseline"

resident_bytes() {
  local total=0 rules
  [ -f "$ROOT/AGENTS.md" ] && total="$(wc -c < "$ROOT/AGENTS.md" | tr -d ' ')"
  # CLAUDE.md, CLAUDE.local.md, .claude/CLAUDE.md and the resident rules.
  rules="$(INSTRUCTION_BUDGET_ROOT="$ROOT" bash "$HERE/instruction-budget-lint.sh" --resident-bytes)" || return 1
  printf '%s\n' "$(( total + ${rules:-0} ))"
}

case "${1:-check}" in
  --bytes) resident_bytes; exit $? ;;
  --update)
    now="$(resident_bytes)" || exit 2
    printf '%s\n' "$now" > "$BASELINE"
    echo "ok wrote $BASELINE ($now bytes)"; exit 0 ;;
  check) ;;
  *) echo "usage: resident-context.sh [--bytes|--update]" >&2; exit 2 ;;
esac

[ -r "$BASELINE" ] || { echo "x no baseline at $BASELINE — run: lib/core/resident-context.sh --update" >&2; exit 2; }
base="$(tr -d ' \n' < "$BASELINE")"
case "$base" in ''|*[!0-9]*) echo "x baseline is not a number: $BASELINE" >&2; exit 2 ;; esac
now="$(resident_bytes)" || exit 2
if [ "$now" -gt "$base" ]; then
  echo "x resident context grew to $now bytes, over the baseline of $base"
  echo "  move a section out of AGENTS.md, or give a rule a paths: frontmatter; raise the baseline only on purpose"
  exit 1
fi
if [ "$now" -lt "$base" ]; then
  echo "ok resident context $now bytes, under the baseline of $base — lower it: lib/core/resident-context.sh --update"
else
  echo "ok resident context $now bytes (baseline $base)"
fi
exit 0
