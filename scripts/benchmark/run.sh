#!/usr/bin/env bash
# benchmark/run.sh — the retrieval + abstain runner (objective, no judge).
#
# Measures how well a cold agent finds the project's OWN canonical docs. For each record it asks the
# model which single doc answers the question (bench_ask), then scores by objective top-hit path
# match against the record's expected path(s). Three tiers share this runner:
#   retrieval    direct questions        -> top-hit path must match expected
#   adversarial  paraphrased / no-keyword / split-canonical / trap -> same scoring, harder inputs
#   abstain      unanswerable            -> ANY path returned is a FAIL; only NONE passes
#
# Usage:
#   benchmark/run.sh [--set <file>] [--tier retrieval|adversarial|abstain]
#                    [--dir <benchmarks>] [--dry] [--json]
#
#   --dry   validate every record's shape and count them; call NO model. Always exits 0 on
#           well-formed data — the no-mistakes gate + CI run this offline.
#   --set   run one set file; otherwise every non-quality set in benchmark.config.json (or every
#           *.jsonl in the dir when there is no config), each scored per its declared tier.
#   --json  machine-readable summary on stdout (for report.sh / autopilot); human table otherwise.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/bench-common.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/model.sh"

DRY=0; JSON=0; ONE_SET=""; FORCE_TIER=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry)       DRY=1; shift ;;
    --json|--llm) JSON=1; shift ;;
    --set)       ONE_SET="$2"; shift 2 ;;
    --set=*)     ONE_SET="${1#*=}"; shift ;;
    --tier)      FORCE_TIER="$2"; shift 2 ;;
    --tier=*)    FORCE_TIER="${1#*=}"; shift ;;
    --dir)       BENCH_DIR="$2"; export BENCH_DIR; shift 2 ;;
    --dir=*)     BENCH_DIR="${1#*=}"; export BENCH_DIR; shift ;;
    -h|--help)   sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           echo "run.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "run.sh: jq is required" >&2; exit 2; }

DIR="$(bench_dir)"
KDIR="$(bench_knowledge_dir)"
CFG="$(bench_config)"

# Build the list of "<file>|<tier>" sets to run.
SETS=()
if [ -n "$ONE_SET" ]; then
  f="$ONE_SET"; [ -f "$f" ] || f="$DIR/$ONE_SET"
  t="${FORCE_TIER:-retrieval}"
  # Infer tier from filename when not forced.
  [ -n "$FORCE_TIER" ] || case "$(basename "$f")" in
    *abstain*)     t="abstain" ;;
    *adversar*)    t="adversarial" ;;
    *)             t="retrieval" ;;
  esac
  SETS+=("$f|$t")
elif [ -n "$CFG" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && SETS+=("$line")
  done < <(jq -r '.sets[]? | select((.tier // "retrieval") != "quality") | "\(.file)|\(.tier // "retrieval")"' "$CFG")
else
  # No config: discover *.jsonl, infer tier from filename, skip quality.
  for f in "$DIR"/*.jsonl; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in
      *quality*)   continue ;;
      *abstain*)   SETS+=("$f|abstain") ;;
      *adversar*)  SETS+=("$f|adversarial") ;;
      *)           SETS+=("$f|retrieval") ;;
    esac
  done
fi

[ "${#SETS[@]}" -ge 1 ] || { echo "run.sh: no sets found in $DIR" >&2; exit 2; }

# ---- portable millisecond clock (latency) ---------------------------------
now_ms() {
  if date +%s%3N >/dev/null 2>&1 && [ "$(date +%3N)" != "3N" ]; then
    date +%s%3N
  else
    printf '%s000' "$(date +%s)"   # second resolution fallback (BSD date)
  fi
}

TOTAL=0; PASS=0; FAILN=0
RESULTS_JSON="[]"
HUMAN=""

for spec in "${SETS[@]}"; do
  file="${spec%%|*}"; tier="${spec##*|}"
  [ -f "$file" ] || file="$DIR/$file"   # config lists bare filenames relative to the benchmarks dir
  s_total=0; s_pass=0
  if [ ! -f "$file" ]; then
    HUMAN="${HUMAN}  ! set missing: $file (tier=$tier)\n"
    continue
  fi

  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    id="$(printf '%s' "$rec" | jq -r '.id // "?"')"
    q="$(printf '%s' "$rec" | jq -r '.q // .claim // empty')"
    expect="$(printf '%s' "$rec" | jq -c '.expect // "NONE"')"

    # --dry: shape validation only. Every record needs a question; non-abstain needs an expect path.
    if [ "$DRY" -eq 1 ]; then
      s_total=$((s_total+1)); TOTAL=$((TOTAL+1))
      if [ -z "$q" ]; then
        echo "run.sh --dry: $file id=$id missing 'q'/'claim'" >&2; FAILN=$((FAILN+1)); continue
      fi
      if [ "$tier" != "abstain" ] && [ "$expect" = '"NONE"' ]; then
        echo "run.sh --dry: $file id=$id ($tier) has no 'expect' path" >&2; FAILN=$((FAILN+1)); continue
      fi
      s_pass=$((s_pass+1)); PASS=$((PASS+1))
      continue
    fi

    # Live: ask the model, score objectively.
    t0="$(now_ms)"
    got="$(bench_ask "$q" "$KDIR")"
    t1="$(now_ms)"; lat=$((t1 - t0)); [ "$lat" -ge 0 ] || lat=0

    ok=0
    if [ "$tier" = "abstain" ]; then
      # Only NONE passes; any path returned = hallucinated retrieval = fail.
      case "$(printf '%s' "$got" | tr 'A-Z' 'a-z')" in none|"") ok=1 ;; *) ok=0 ;; esac
    else
      if [ "$(printf '%s' "$got" | tr 'A-Z' 'a-z')" = "none" ]; then ok=0
      elif bench_path_match "$got" "$expect"; then ok=1; fi
    fi

    s_total=$((s_total+1)); TOTAL=$((TOTAL+1))
    if [ "$ok" -eq 1 ]; then s_pass=$((s_pass+1)); PASS=$((PASS+1)); else FAILN=$((FAILN+1)); fi

    RESULTS_JSON="$(printf '%s' "$RESULTS_JSON" | jq -c \
      --arg set "$(basename "$file")" --arg tier "$tier" --arg id "$id" \
      --arg got "$got" --argjson expect "$expect" --argjson ok "$ok" --argjson lat "$lat" \
      '. + [{set:$set,tier:$tier,id:$id,got:$got,expect:$expect,pass:($ok==1),latency_ms:$lat}]')"
  done < <(bench_records "$file")

  pct=0; [ "$s_total" -gt 0 ] && pct=$(( s_pass * 100 / s_total ))
  HUMAN="${HUMAN}  $tier ($(basename "$file")): $s_pass/$s_total  (${pct}%)\n"
done

SCORE_PCT=0; [ "$TOTAL" -gt 0 ] && SCORE_PCT=$(( PASS * 100 / TOTAL ))

if [ "$JSON" -eq 1 ]; then
  jq -n --argjson total "$TOTAL" --argjson pass "$PASS" --argjson fail "$FAILN" \
        --argjson pct "$SCORE_PCT" --argjson dry "$DRY" --argjson results "$RESULTS_JSON" \
        '{kind:"retrieval-run", dry:($dry==1), total:$total, pass:$pass, fail:$fail, score_pct:$pct, results:$results}'
else
  printf 'benchmark run%s — %s\n' "$([ "$DRY" -eq 1 ] && echo ' (--dry)')" "$DIR"
  printf '%b' "$HUMAN"
  printf 'total: %s/%s passed  (%s%%)\n' "$PASS" "$TOTAL" "$SCORE_PCT"
fi

# --dry always succeeds on well-formed data (it is the offline gate). A live run exits non-zero when
# anything failed so autopilot / CI notice a retrieval regression.
if [ "$DRY" -eq 1 ]; then
  [ "$FAILN" -eq 0 ] && exit 0 || exit 1
fi
[ "$FAILN" -eq 0 ] && exit 0 || exit 1
