#!/usr/bin/env bash
# benchmark-test.sh — self-test for the benchmark harness (#200). Offline only: the mock backend +
# --dry paths, so it never calls a real model. Run: bash scripts/benchmark/benchmark-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

fail=0
t() { if [ "$2" != "$3" ]; then echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok: $1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }

# ---- isolated fixture ------------------------------------------------------
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bench"
cat > "$FIX/bench/benchmark.config.json" <<'JSON'
{ "knowledgeDir": "knowledge",
  "sets": [
    {"name":"retrieval","file":"retrieval.jsonl","tier":"retrieval"},
    {"name":"abstain","file":"abstain.jsonl","tier":"abstain"},
    {"name":"quality","file":"quality.jsonl","tier":"quality"} ],
  "target": {"minRecords": 3, "cleanRounds": 2} }
JSON
printf '%s\n' '{"id":"r1","q":"How do we release?","expect":"releasing.md"}' \
              '{"id":"r2","q":"Branch model?","expect":["branching.md","git.md"]}' > "$FIX/bench/retrieval.jsonl"
printf '%s\n' '{"id":"a1","q":"DB password?","expect":"NONE"}' > "$FIX/bench/abstain.jsonl"
printf '%s\n' '{"id":"q1","claim":"Summarize releasing.","must":["version bumped","tag pushed"]}' > "$FIX/bench/quality.jsonl"

export BENCH_DIR="$FIX/bench"

# ---- 1. --dry on well-formed data passes -----------------------------------
bash "$HERE/run.sh" --dry >/dev/null 2>&1;         t "run --dry well-formed" "$?" "0"
bash "$HERE/run-quality.sh" --dry >/dev/null 2>&1; t "quality --dry well-formed" "$?" "0"

# ---- 2. --dry catches a malformed record -----------------------------------
printf '%s\n' '{"id":"bad","expect":"x.md"}' >> "$FIX/bench/retrieval.jsonl"   # no q
bash "$HERE/run.sh" --dry >/dev/null 2>&1;         t "run --dry missing q fails" "$?" "1"
# restore
printf '%s\n' '{"id":"r1","q":"How do we release?","expect":"releasing.md"}' \
              '{"id":"r2","q":"Branch model?","expect":["branching.md","git.md"]}' > "$FIX/bench/retrieval.jsonl"

# ---- 3. abstain record with a stray expect path is caught? (abstain allows NONE only, so a non-
#         abstain tier needs an expect; abstain with NONE is fine — validate a retrieval with NONE) -
printf '%s\n' '{"id":"noexp","q":"orphan?","expect":"NONE"}' >> "$FIX/bench/retrieval.jsonl"
bash "$HERE/run.sh" --dry >/dev/null 2>&1;         t "run --dry retrieval w/ NONE expect fails" "$?" "1"
printf '%s\n' '{"id":"r1","q":"How do we release?","expect":"releasing.md"}' \
              '{"id":"r2","q":"Branch model?","expect":["branching.md","git.md"]}' > "$FIX/bench/retrieval.jsonl"

# ---- 4. path matching ------------------------------------------------------
# shellcheck source=/dev/null
. "$HERE/lib/bench-common.sh"
bench_path_match "knowledge/releasing.md" '"releasing.md"'; t "match: kdir prefix stripped" "$?" "0"
bench_path_match "./releasing.md"          '"releasing.md"'; t "match: ./ stripped"           "$?" "0"
bench_path_match "git.md"   '["branching.md","git.md"]';     t "match: array member"           "$?" "0"
bench_path_match "other.md" '"releasing.md"';                t "no-match: different doc"        "$?" "1"

# ---- 5. mock live scoring (mock backend always returns NONE) ----------------
# retrieval records fail (NONE != a path); the abstain record passes (NONE is correct).
res="$(BENCH_BACKEND=mock bash "$HERE/run.sh" --json 2>/dev/null)"
t "mock: abstain passes only"  "$(printf '%s' "$res" | jq -r '.pass')" "1"
t "mock: retrieval both fail"  "$(printf '%s' "$res" | jq -r '.fail')" "2"

# ---- 6. gate.sh clean on well-formed fixture -------------------------------
BENCH_SKIP_KNOWLEDGE_LINT=1 bash "$HERE/gate.sh" >/dev/null 2>&1; t "gate clean" "$?" "0"

# ---- 7. stop-check: size met but streak < rounds -> CONTINUE; 2nd clean -> STOP ----
rm -f "$FIX/bench/.stop-state.json"
BENCH_SKIP_KNOWLEDGE_LINT=1 bash "$HERE/stop-check.sh" >/dev/null 2>&1; rc1=$?
BENCH_SKIP_KNOWLEDGE_LINT=1 bash "$HERE/stop-check.sh" >/dev/null 2>&1; rc2=$?
t "stop-check round1 CONTINUE" "$rc1" "1"
t "stop-check round2 STOP"     "$rc2" "0"

# ---- 8. stop-check below size target never stops ---------------------------
# minRecords=99 forces size_ok=false regardless of clean streak.
rm -f "$FIX/bench/.stop-state.json"
BENCH_SKIP_KNOWLEDGE_LINT=1 bash "$HERE/stop-check.sh" --min 99 >/dev/null 2>&1; t "stop-check below size CONTINUE" "$?" "1"

# ---- 9. report.sh writes a RESULTS.md --------------------------------------
bash "$HERE/report.sh" --dry --out "$FIX/RESULTS.md" >/dev/null 2>&1
t "report wrote RESULTS.md" "$([ -s "$FIX/RESULTS.md" ] && echo yes)" "yes"
grep -q "Documentation benchmark" "$FIX/RESULTS.md"; t "report has heading" "$?" "0"

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit "$fail"
