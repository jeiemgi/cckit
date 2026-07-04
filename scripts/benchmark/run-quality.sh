#!/usr/bin/env bash
# benchmark/run-quality.sh — the quality judge tier.
#
# Beyond "did the agent find the doc", this measures "was the answer correct + complete". For each
# claim-style record the model answers headlessly (bench_ask-style, but a full answer), then a judge
# scores that answer 0..1 against the record's `must` rubric. The rubric de-biases the judge: it
# grades coverage of the required points, not tone. The tier score is the mean.
#
# Usage:
#   benchmark/run-quality.sh [--set <file>] [--dir <benchmarks>] [--dry] [--json]
#
#   --dry   validate every record has a claim + a non-empty `must` rubric; call NO model; exit 0.
#   --set   run one quality set; else every tier:"quality" set in benchmark.config.json (or every
#           *quality*.jsonl in the dir).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/bench-common.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/model.sh"

DRY=0; JSON=0; ONE_SET=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry)        DRY=1; shift ;;
    --json|--llm) JSON=1; shift ;;
    --set)        ONE_SET="$2"; shift 2 ;;
    --set=*)      ONE_SET="${1#*=}"; shift ;;
    --dir)        BENCH_DIR="$2"; export BENCH_DIR; shift 2 ;;
    --dir=*)      BENCH_DIR="${1#*=}"; export BENCH_DIR; shift ;;
    -h|--help)    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            echo "run-quality.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "run-quality.sh: jq is required" >&2; exit 2; }

DIR="$(bench_dir)"
KDIR="$(bench_knowledge_dir)"
CFG="$(bench_config)"

SETS=()
if [ -n "$ONE_SET" ]; then
  f="$ONE_SET"; [ -f "$f" ] || f="$DIR/$ONE_SET"
  SETS+=("$f")
elif [ -n "$CFG" ]; then
  while IFS= read -r f; do [ -n "$f" ] && SETS+=("$DIR/$f"); done \
    < <(jq -r '.sets[]? | select((.tier // "") == "quality") | .file' "$CFG")
else
  for f in "$DIR"/*quality*.jsonl; do [ -e "$f" ] && SETS+=("$f"); done
fi

[ "${#SETS[@]}" -ge 1 ] || { echo "run-quality.sh: no quality sets found in $DIR" >&2; exit 2; }

N=0; SUM="0"; FAILN=0
RESULTS_JSON="[]"

for file in "${SETS[@]}"; do
  [ -f "$file" ] || { echo "run-quality.sh: set missing: $file" >&2; FAILN=$((FAILN+1)); continue; }
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    id="$(printf '%s' "$rec" | jq -r '.id // "?"')"
    claim="$(printf '%s' "$rec" | jq -r '.claim // .q // empty')"
    must="$(printf '%s' "$rec" | jq -r '(.must // []) | join("\n")')"

    if [ "$DRY" -eq 1 ]; then
      N=$((N+1))
      if [ -z "$claim" ]; then echo "run-quality.sh --dry: $file id=$id missing 'claim'" >&2; FAILN=$((FAILN+1)); fi
      if [ -z "$must" ];  then echo "run-quality.sh --dry: $file id=$id has empty 'must' rubric" >&2; FAILN=$((FAILN+1)); fi
      continue
    fi

    answer="$(bench_ask "$claim" "$KDIR")"
    score="$(bench_judge "$claim" "$answer" "$must")"
    N=$((N+1))
    SUM="$(awk -v a="$SUM" -v b="$score" 'BEGIN{printf "%.4f", a+b}')"
    RESULTS_JSON="$(printf '%s' "$RESULTS_JSON" | jq -c \
      --arg set "$(basename "$file")" --arg id "$id" --arg score "$score" \
      '. + [{set:$set,id:$id,score:($score|tonumber)}]')"
  done < <(bench_records "$file")
done

MEAN="0"; [ "$N" -gt 0 ] && MEAN="$(awk -v s="$SUM" -v n="$N" 'BEGIN{printf "%.3f", s/n}')"

if [ "$JSON" -eq 1 ]; then
  jq -n --argjson n "$N" --arg mean "$MEAN" --argjson dry "$DRY" --argjson results "$RESULTS_JSON" \
    '{kind:"quality-run", dry:($dry==1), count:$n, mean:($mean|tonumber), results:$results}'
else
  printf 'quality run%s — %s\n' "$([ "$DRY" -eq 1 ] && echo ' (--dry)')" "$DIR"
  if [ "$DRY" -eq 1 ]; then
    printf 'validated %s record(s)\n' "$N"
  else
    printf 'mean score: %s over %s claim(s)\n' "$MEAN" "$N"
  fi
fi

if [ "$DRY" -eq 1 ]; then
  [ "$FAILN" -eq 0 ] && exit 0 || exit 1
fi
# A live quality run is informational (a mean, not a pass/fail bar) — exit 0 unless a set was missing.
[ "$FAILN" -eq 0 ] && exit 0 || exit 1
