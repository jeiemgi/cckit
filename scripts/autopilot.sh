#!/usr/bin/env bash
# autopilot.sh - unattended multi-flow driver. A THIN wrapper over orchestrate.sh: pick the issues
# to run (explicit args, or auto-select the unblocked open issues from the board), then orchestrate
# them under a concurrency cap, detached, with no human present.
#
# This is the SCRIPT half of autopilot - it launches the flows. The "captain" half (decide, review,
# merge each PR, continue to the next wave) is the driving agent's job, not this script's.
#
# Usage:
#   cckit autopilot                 # auto-select unblocked open issues from the board
#   cckit autopilot 6 7 8           # drive exactly these issues
#   cckit autopilot --cap 3         # cap concurrent flows (passed through to orchestrate)
#   cckit autopilot --agent codex   # drive a different agent CLI
#   cckit autopilot --dry-run       # print the plan, launch nothing
set -euo pipefail

PASS=()        # flags forwarded to orchestrate
ISSUES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --cap|--agent) PASS+=("$1" "$2"); shift 2 ;;
    --cap=*|--agent=*|--dry-run|--no-seed|--force|--session=*) PASS+=("$1"); shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    [0-9]*) ISSUES+=("$1"); shift ;;
    *) echo "autopilot: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# No explicit issues -> auto-select from the board: open issues, minus effort PARENTS (the
# "[Effort] N ..." umbrella issues that decompose into subs, identified by label:effort OR the
# title convention) and minus anything blocked_by an open issue. orchestrate re-checks the
# blocked_by gate at launch; this is the coarse pre-filter so the board drives the wave.
if [ "${#ISSUES[@]}" -eq 0 ]; then
  echo "autopilot: no issues passed - auto-selecting unblocked open issues from the board"
  board="$(bash "$ROOT/scripts/task-sync.sh" --raw-json)" || {
    echo "autopilot: could not read the board" >&2; exit 1;
  }
  # Capture the parser status before reading rows. Process substitution hides its failures.
  selected="$(printf '%s' "$board" | jq -r '
    if type != "array" then error("expected an issue array") else . end
    | .[]
    | select((any(.labels[]; .name == "effort")) or (.title | test("^\\[Effort\\] ")) | not)
    | .number')" || { echo "autopilot: invalid board data" >&2; exit 1; }
  while IFS= read -r n; do
    [ -n "$n" ] && ISSUES+=("$n")
  done <<< "$selected"
  [ "${#ISSUES[@]}" -ge 1 ] || { echo "autopilot: nothing open to drive" >&2; exit 0; }
fi

echo "autopilot: driving ${#ISSUES[@]} issue(s) -> orchestrate (detached): ${ISSUES[*]}"
exec bash "$ROOT/scripts/orchestrate.sh" --detach "${PASS[@]+"${PASS[@]}"}" "${ISSUES[@]}"
