#!/usr/bin/env bash
# benchmark/stop-check.sh — the Stop=Both predicate for objective autopilot mode.
#
# cckit autopilot objective mode drives a capped `/loop --until '<check>'` that grows + hardens the
# benchmark sets each round. This is that `<check>`: it exits 0 (loop is done) ONLY when BOTH
# conditions hold at once —
#   (A) SIZE:  the suite has reached its record-count target (config target.minRecords), AND
#   (B) CLEAN: the no-mistakes gate (gate.sh) has passed target.cleanRounds rounds in a row.
#
# It runs the gate itself and tracks the clean streak in benchmarks/.stop-state.json, so the loop
# can't stop on a round that grew the suite but broke it. A broken round resets the streak to 0.
#
# Usage: benchmark/stop-check.sh [--dir <benchmarks>] [--min N] [--rounds K] [--json]
# Exit 0 = stop (both met); non-zero = keep looping.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/bench-common.sh"

JSON=0; MIN=""; ROUNDS=""
DIRFLAG=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)     BENCH_DIR="$2"; export BENCH_DIR; DIRFLAG=(--dir "$2"); shift 2 ;;
    --dir=*)   BENCH_DIR="${1#*=}"; export BENCH_DIR; DIRFLAG=(--dir "${1#*=}"); shift ;;
    --min)     MIN="$2"; shift 2 ;;
    --min=*)   MIN="${1#*=}"; shift ;;
    --rounds)  ROUNDS="$2"; shift 2 ;;
    --rounds=*) ROUNDS="${1#*=}"; shift ;;
    --json|--llm) JSON=1; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "stop-check.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "stop-check.sh: jq is required" >&2; exit 2; }

DIR="$(bench_dir)"
CFG="$(bench_config)"
STATE="$DIR/.stop-state.json"

# Targets: flags win, else config, else conservative defaults.
[ -n "$MIN" ]    || MIN="$(   [ -n "$CFG" ] && jq -r '.target.minRecords // empty' "$CFG" 2>/dev/null)"
[ -n "$ROUNDS" ] || ROUNDS="$([ -n "$CFG" ] && jq -r '.target.cleanRounds // empty' "$CFG" 2>/dev/null)"
[ -n "$MIN" ]    || MIN=12
[ -n "$ROUNDS" ] || ROUNDS=2

# (A) SIZE — total records across every set (dry-count via run.sh gives retrieval/abstain; add
# quality). Reuse the runners' --dry --json totals so the count matches exactly what ships.
ret_n="$(bash "$SCRIPT_DIR/run.sh"        --dry --json "${DIRFLAG[@]+"${DIRFLAG[@]}"}" 2>/dev/null | jq -r '.total // 0')"
qual_n="$(bash "$SCRIPT_DIR/run-quality.sh" --dry --json "${DIRFLAG[@]+"${DIRFLAG[@]}"}" 2>/dev/null | jq -r '.count // 0')"
[ -n "$ret_n" ]  || ret_n=0
[ -n "$qual_n" ] || qual_n=0
TOTAL=$((ret_n + qual_n))
size_ok=0; [ "$TOTAL" -ge "$MIN" ] && size_ok=1

# (B) CLEAN — run the gate this round; update the streak.
streak=0
[ -f "$STATE" ] && streak="$(jq -r '.clean_streak // 0' "$STATE" 2>/dev/null || echo 0)"
if bash "$SCRIPT_DIR/gate.sh" "${DIRFLAG[@]+"${DIRFLAG[@]}"}" >/dev/null 2>&1; then
  streak=$((streak + 1))
else
  streak=0   # a broken round resets the streak — cannot stop on it
fi
jq -n --argjson s "$streak" '{clean_streak:$s}' > "$STATE" 2>/dev/null || true
clean_ok=0; [ "$streak" -ge "$ROUNDS" ] && clean_ok=1

STOP=0; [ "$size_ok" -eq 1 ] && [ "$clean_ok" -eq 1 ] && STOP=1

if [ "$JSON" -eq 1 ]; then
  jq -n --argjson total "$TOTAL" --argjson min "$MIN" --argjson streak "$streak" \
        --argjson rounds "$ROUNDS" --argjson size "$size_ok" --argjson clean "$clean_ok" \
        --argjson stop "$STOP" \
    '{records:$total, min:$min, size_ok:($size==1), clean_streak:$streak, rounds:$rounds, clean_ok:($clean==1), stop:($stop==1)}'
else
  printf 'stop-check: records %s/%s (%s) · clean streak %s/%s (%s) -> %s\n' \
    "$TOTAL" "$MIN"    "$([ "$size_ok" -eq 1 ] && echo met || echo below)" \
    "$streak" "$ROUNDS" "$([ "$clean_ok" -eq 1 ] && echo met || echo short)" \
    "$([ "$STOP" -eq 1 ] && echo STOP || echo CONTINUE)"
fi

[ "$STOP" -eq 1 ] && exit 0 || exit 1
