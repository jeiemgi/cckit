#!/usr/bin/env bash
# benchmark/gate.sh — the per-round "no-mistakes" bundle for the objective autopilot loop. It is the
# offline bar every round of growing/hardening the benchmark sets must clear before it counts as a
# clean round: nothing may be broken by an edit.
#
# Checks (all offline — NO model calls):
#   1. bash -n on every harness script (syntax).
#   2. run.sh --dry + run-quality.sh --dry on every set (dataset shape: every record well-formed).
#   3. the project's knowledge-lint (canonical-doc governance), if present — so a set that points at
#      a doc which drifted out of the manifest is caught here.
#
# Usage: benchmark/gate.sh [--dir <benchmarks>]
# Exit 0 = clean round; non-zero = something is broken, do not count the round.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIRFLAG=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir)   DIRFLAG=(--dir "$2"); shift 2 ;;
    --dir=*) DIRFLAG=(--dir "${1#*=}"); shift ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "gate.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

fail=0
note() { printf '%s\n' "$*" >&2; }

note "==> [1/3] harness syntax (bash -n)"
for f in "$SCRIPT_DIR"/*.sh "$SCRIPT_DIR"/lib/*.sh; do
  [ -e "$f" ] || continue
  bash -n "$f" || { note "x syntax: $f"; fail=1; }
done

note "==> [2/3] every set --dry (dataset shape)"
bash "$SCRIPT_DIR/run.sh" --dry "${DIRFLAG[@]+"${DIRFLAG[@]}"}"          || { note "x retrieval/abstain sets failed --dry"; fail=1; }
bash "$SCRIPT_DIR/run-quality.sh" --dry "${DIRFLAG[@]+"${DIRFLAG[@]}"}"  || { note "x quality set failed --dry"; fail=1; }

note "==> [3/3] knowledge-lint (canonical-doc governance)"
# Prefer the project's own linter (it knows the project's knowledge dir + manifest); fall back to
# the kit's copy. Absent linter is not a failure — the gate stays dependency-light.
# BENCH_SKIP_KNOWLEDGE_LINT=1 opts out (self-tests run against a throwaway fixture, not a real KB).
if [ "${BENCH_SKIP_KNOWLEDGE_LINT:-0}" = "1" ]; then
  note "  (knowledge-lint skipped — BENCH_SKIP_KNOWLEDGE_LINT=1)"
elif [ -f "$PWD/scripts/knowledge-lint.sh" ]; then
  bash "$PWD/scripts/knowledge-lint.sh" || { note "x knowledge-lint failed"; fail=1; }
elif [ -f "$SCRIPT_DIR/../knowledge-lint.sh" ]; then
  bash "$SCRIPT_DIR/../knowledge-lint.sh" || { note "x knowledge-lint failed"; fail=1; }
else
  note "  (knowledge-lint absent — skipping)"
fi

[ "$fail" -eq 0 ] && note "PASS benchmark gate clean" || note "FAIL benchmark gate"
exit "$fail"
