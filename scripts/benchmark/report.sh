#!/usr/bin/env bash
# benchmark/report.sh — turn a benchmark run into a plain, low-jargon RESULTS.md a non-expert can
# read: what we tested, what passed, and the one headline score. Runs the retrieval + quality tiers
# (unless handed pre-computed JSON on stdin) and writes RESULTS.md into the benchmarks dir.
#
# Usage:
#   benchmark/report.sh [--dir <benchmarks>] [--dry] [--out <path>]
#   benchmark/run.sh --json | benchmark/report.sh --stdin   # report a run you already have
#
#   --dry   run both tiers in --dry (offline, no model) so the report renders the shape of the
#           suite without spending a model call — handy in CI to prove report.sh works.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/bench-common.sh"

DRY=0; OUT=""; STDIN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry)     DRY=1; shift ;;
    --stdin)   STDIN=1; shift ;;
    --out)     OUT="$2"; shift 2 ;;
    --out=*)   OUT="${1#*=}"; shift ;;
    --dir)     BENCH_DIR="$2"; export BENCH_DIR; shift 2 ;;
    --dir=*)   BENCH_DIR="${1#*=}"; export BENCH_DIR; shift ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "report.sh: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "report.sh: jq is required" >&2; exit 2; }

DIR="$(bench_dir)"
[ -n "$OUT" ] || OUT="$DIR/RESULTS.md"
DRYFLAG=""; [ "$DRY" -eq 1 ] && DRYFLAG="--dry"

# Gather the two tier summaries (retrieval+abstain+adversarial in one, quality separately).
if [ "$STDIN" -eq 1 ]; then
  RET_JSON="$(cat)"
  QUAL_JSON='{"kind":"quality-run","dry":true,"count":0,"mean":0,"results":[]}'
else
  RET_JSON="$(bash "$SCRIPT_DIR/run.sh" $DRYFLAG --json 2>/dev/null || echo '{}')"
  QUAL_JSON="$(bash "$SCRIPT_DIR/run-quality.sh" $DRYFLAG --json 2>/dev/null || echo '{}')"
fi

# Pull the numbers with safe defaults (a tier may be absent).
r_total="$(printf '%s' "$RET_JSON"  | jq -r '.total // 0')"
r_pass="$(printf  '%s' "$RET_JSON"  | jq -r '.pass  // 0')"
r_pct="$(printf   '%s' "$RET_JSON"  | jq -r '.score_pct // 0')"
r_dry="$(printf   '%s' "$RET_JSON"  | jq -r '.dry // false')"
q_count="$(printf '%s' "$QUAL_JSON" | jq -r '.count // 0')"
q_mean="$(printf  '%s' "$QUAL_JSON" | jq -r '.mean  // 0')"

STAMP="$(date -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo 'unknown time')"
MODE="live"; [ "$r_dry" = "true" ] && MODE="dry (data validated offline, no model asked)"

# Per-tier breakdown table from the detailed results.
TIER_ROWS="$(printf '%s' "$RET_JSON" | jq -r '
  (.results // []) | group_by(.tier)[]
  | { tier: .[0].tier, pass: (map(select(.pass)) | length), total: length }
  | "| \(.tier) | \(.pass)/\(.total) | \( (if .total>0 then (.pass*100/.total) else 0 end) | floor )% |"' 2>/dev/null)"
[ -n "$TIER_ROWS" ] || TIER_ROWS="| (no per-tier detail in --dry) | $r_pass/$r_total | ${r_pct}% |"

{
  echo "# Documentation benchmark — RESULTS"
  echo
  echo "_Generated ${STAMP} · mode: ${MODE}_"
  echo
  echo "## What this measures"
  echo
  echo "How well this project's own canonical documents can be **found and used** by an agent that"
  echo "starts cold — the same way a new teammate or an AI assistant would. A high score means the"
  echo "docs are discoverable and the answers in them are complete."
  echo
  echo "## Headline"
  echo
  if [ "$r_dry" = "true" ]; then
    echo "- **Offline shape check** — ${r_total} retrieval/abstain records and the quality set were"
    echo "  validated as well-formed. This is not a live score; run without \`--dry\` to score."
  else
    echo "- **Retrieval score: ${r_pct}%** — of ${r_total} questions, the agent pointed at the right"
    echo "  canonical document (or correctly abstained) **${r_pass}** times."
    if [ "$q_count" -gt 0 ]; then
      echo "- **Answer quality: ${q_mean} / 1.0** — average completeness of ${q_count} judged answers."
    fi
  fi
  echo
  echo "## By tier"
  echo
  echo "| Tier | Passed | Score |"
  echo "| --- | --- | --- |"
  printf '%s\n' "$TIER_ROWS"
  echo
  echo "## How to read this"
  echo
  echo "- **Retrieval** — plain questions; can the agent find the one right doc?"
  echo "- **Adversarial** — reworded / no-keyword / trap questions; does retrieval survive them?"
  echo "- **Abstain** — questions with no documented answer; the agent must say \"none\", not invent one."
  echo "- **Quality** — the answer is graded 0–1 for completeness against a fixed checklist."
  echo
  echo "Run again with \`benchmark/report.sh\` after any docs or kit change to catch regressions."
} > "$OUT"

echo "report.sh: wrote $OUT (retrieval ${r_pct}%${q_count:+, quality ${q_mean}})"
