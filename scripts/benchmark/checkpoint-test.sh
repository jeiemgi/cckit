#!/usr/bin/env bash
# checkpoint-test.sh — benchmark checkpoints per release and the release gate (#452). Offline: run
# files are fixtures or the mock backend, and publish.sh only ever runs as a dry run.
# Run: bash scripts/benchmark/checkpoint-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CP="$HERE/checkpoint.sh"
PUBLISH="$ROOT/scripts/publish.sh"

fail=0
t() { if [ "$2" != "$3" ]; then echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok: $1"; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '[$3]' not in '[$2]'"; fail=1 ;; esac; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq absent"; exit 0; }

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT

# A project with a benchmarks dir: 4 questions, mock backend answers NONE (1 of 4 right).
new_project() {
  local d="$1"
  mkdir -p "$d/benchmarks"
  cat > "$d/benchmarks/benchmark.config.json" <<'JSON'
{ "knowledgeDir": "knowledge",
  "sets": [ {"name":"retrieval","file":"retrieval.jsonl","tier":"retrieval"},
            {"name":"abstain","file":"abstain.jsonl","tier":"abstain"} ] }
JSON
  printf '%s\n' '{"id":"r1","q":"How do we release?","expect":"releasing.md"}' \
                '{"id":"r2","q":"Branch model?","expect":["branching.md","git.md"]}' \
                '{"id":"r3","q":"Branch | model <x>?","expect":"x.md"}' > "$d/benchmarks/retrieval.jsonl"
  printf '%s\n' '{"id":"a1","q":"DB password?","expect":"NONE"}' > "$d/benchmarks/abstain.jsonl"
}

# A run as `cckit bench run --json` prints it: <pass> right answers out of <total>.
mk_run() {
  jq -n --argjson pass "$1" --argjson total "$2" '
    { kind: "retrieval-run", dry: false, total: $total, pass: $pass, fail: ($total - $pass),
      score_pct: (($pass * 100 / $total) | floor),
      results: [ range(0; $total) | { set: "retrieval.jsonl", tier: "retrieval", id: ("r" + (. + 1 | tostring)),
                 got: (if . < $pass then "x.md" else "NONE" end), expect: "x.md",
                 pass: (. < $pass), latency_ms: 1000 } ] }'
}

P="$FIX/p1"; new_project "$P"
export BENCH_DIR="$P/benchmarks"
RUNS="$BENCH_DIR/runs"
mk_run 2 3 > "$FIX/run-2of3.json"
mk_run 3 3 > "$FIX/run-3of3.json"
mk_run 1 3 > "$FIX/run-1of3.json"
mk_run 5 6 > "$FIX/run-5of6.json"
mk_run 4 6 > "$FIX/run-4of6.json"
rec() { bash "$CP" record "$@" --date 2026-01-02 --commit abc1234 --ref develop --model test-model >/dev/null 2>&1; }

# ---- 1. record: one file per version, several checkpoints in it -------------
rec 1.2.0 --from "$FIX/run-2of3.json"; t "record exits 0" "$?" "0"
t "run file is named after the version" "$([ -f "$RUNS/1.2.0.json" ] && echo yes)" "yes"
t "file carries schema + version" "$(jq -r '"\(.schema) \(.version)"' "$RUNS/1.2.0.json")" "1 1.2.0"
t "checkpoint 1 score" "$(jq -r '.checkpoints[0] | "\(.n) \(.pass)/\(.total) \(.score_pct)"' "$RUNS/1.2.0.json")" "1 2/3 66"
t "checkpoint 1 provenance" "$(jq -r '.checkpoints[0] | "\(.date) \(.ref) \(.commit) \(.model) \(.passes)"' "$RUNS/1.2.0.json")" "2026-01-02 develop abc1234 test-model 1"
t "checkpoint 1 per-tier score" "$(jq -c '.checkpoints[0].tiers' "$RUNS/1.2.0.json")" '{"retrieval":{"total":3,"pass":2}}'
t "question text is recorded with the result" "$(jq -r '.checkpoints[0].results[0].q' "$RUNS/1.2.0.json")" "How do we release?"
rec 1.2.0 --from "$FIX/run-3of3.json" --note "after the fix"
t "a second checkpoint lands in the same file" "$(jq -r '.checkpoints | length' "$RUNS/1.2.0.json")" "2"
t "checkpoint 2 is numbered 2" "$(jq -r '.checkpoints[1] | "\(.n) \(.pass)/\(.total) \(.note)"' "$RUNS/1.2.0.json")" "2 3/3 after the fix"
t "only one run file exists" "$(find "$RUNS" -name '*.json' | wc -l | tr -d ' ')" "1"

# ---- 2. several passes are summed ------------------------------------------
rec 1.3.0 --from "$FIX/run-2of3.json" --from "$FIX/run-3of3.json"
t "two passes: asked 6, right 5" "$(jq -r '.checkpoints[0] | "\(.passes) \(.questions) \(.pass)/\(.total) \(.score_pct)"' "$RUNS/1.3.0.json")" "2 3 5/6 83"
t "a question missed in one pass is not a pass" "$(jq -c '.checkpoints[0].results[2] | [.passed,.asked,.pass,.got]' "$RUNS/1.3.0.json")" '[1,2,false,"NONE"]'
rm -f "$RUNS/1.3.0.json"

# ---- 3. record without --from runs the benchmark ---------------------------
( cd "$P" && BENCH_BACKEND=mock bash "$CP" record 1.3.0 --passes 2 --date 2026-01-03 --commit def5678 --ref develop >/dev/null 2>&1 )
t "live record, 2 passes over 4 questions" "$(jq -r '.checkpoints[0] | "\(.passes) \(.pass)/\(.total) \(.model)"' "$RUNS/1.3.0.json")" "2 2/8 mock"
rm -f "$RUNS/1.3.0.json"

# ---- 4. refusals that write nothing ----------------------------------------
before="$(cat "$RUNS/1.2.0.json")"
bash "$CP" record nightly --from "$FIX/run-3of3.json" >/dev/null 2>&1;     t "record refuses a non X.Y.Z version" "$?" "2"
bash "$CP" record 1.2.0 --from "$FIX/missing.json" >/dev/null 2>&1;        t "record refuses a missing run file" "$?" "2"
jq '.dry = true | .results = []' "$FIX/run-3of3.json" > "$FIX/run-dry.json"
bash "$CP" record 1.2.0 --from "$FIX/run-dry.json" >/dev/null 2>&1;        t "record refuses a --dry run" "$?" "2"
bash "$CP" record 1.2.0 --passes 0 >/dev/null 2>&1;                        t "record refuses --passes 0" "$?" "2"
t "a refused record leaves the file unchanged" "$(cat "$RUNS/1.2.0.json")" "$before"

# ---- 5. list ---------------------------------------------------------------
t "list prints one row per checkpoint" "$(bash "$CP" list | wc -l | tr -d ' ')" "2"
t "list --json drops the per-question results" "$(bash "$CP" list --json | jq -c '[.[] | has("results")] | unique')" "[false]"

# ---- 6. check: the gate ----------------------------------------------------
# 1.2.0 so far: 2/3 then 3/3.
bash "$CP" check 1.2.0 >/dev/null 2>&1;  t "check: higher than the previous checkpoint passes" "$?" "0"
bash "$CP" check 1.3.0 >/dev/null 2>&1;  t "check: missing run file refuses" "$?" "1"
has "check: missing names the version" "$(bash "$CP" check 1.3.0 2>&1)" "no recorded checkpoint for 1.3.0"
rec 1.3.0 --from "$FIX/run-3of3.json"
bash "$CP" check 1.3.0 >/dev/null 2>&1;  t "check: equal to the previous version's last checkpoint passes" "$?" "0"
rec 1.3.0 --from "$FIX/run-2of3.json"
bash "$CP" check 1.3.0 >/dev/null 2>&1;  t "check: lower than the previous checkpoint refuses" "$?" "1"
has "check: lower names both scores" "$(bash "$CP" check 1.3.0 2>&1)" "1.3.0 checkpoint 2: 2/3 (66%) is lower than 1.3.0 checkpoint 1: 3/3 (100%)"
rec 1.3.0 --from "$FIX/run-3of3.json"
bash "$CP" check 1.3.0 >/dev/null 2>&1;  t "check: a later, higher checkpoint clears the refusal" "$?" "0"
bash "$CP" check 1.2.0 >/dev/null 2>&1;  t "check: a later version does not change an earlier verdict" "$?" "0"
bash "$CP" check bogus >/dev/null 2>&1;  t "check: a non X.Y.Z version is a usage error" "$?" "2"

# First version ever recorded has nothing to compare against.
P2="$FIX/p2"; new_project "$P2"
BENCH_DIR="$P2/benchmarks" bash "$CP" record 0.1.0 --from "$FIX/run-1of3.json" >/dev/null 2>&1
BENCH_DIR="$P2/benchmarks" bash "$CP" check 0.1.0 >/dev/null 2>&1; t "check: the first recorded checkpoint passes" "$?" "0"

# Versions order numerically (0.10.0 follows 0.9.0), and scores compare as fractions.
P3="$FIX/p3"; new_project "$P3"
cp3() { BENCH_DIR="$P3/benchmarks" bash "$CP" "$@" >/dev/null 2>&1; }
cp3 record 0.9.0 --from "$FIX/run-2of3.json"
cp3 record 0.10.0 --from "$FIX/run-4of6.json"
cp3 check 0.10.0; t "check: 4/6 equals 2/3 on a larger set" "$?" "0"
cp3 record 0.10.0 --from "$FIX/run-1of3.json"
cp3 record 0.9.1 --from "$FIX/run-5of6.json"
cp3 check 0.9.1;  t "check: 0.9.1 compares against 0.9.0, not 0.10.0" "$?" "0"
cp3 check 0.10.0; t "check: 0.10.0 last checkpoint 1/3 is lower than 4/6" "$?" "1"

# ---- 7. cckit release (publish.sh) refuses on the same verdict --------------
# Dry runs only: publish.sh prints its plan and changes nothing.
rel() { BENCH_DIR="$1" bash "$PUBLISH" "$2" ${3:+"$3"} 2>&1; }
out="$(rel "$P/benchmarks" 9.9.9)";      t "release: missing run refuses (exit 1)" "$?" "1"
has "release: missing run says why" "$out" "no recorded checkpoint for 9.9.9"
has "release: refusal names the override flag" "$out" "--skip-bench-check"
case "$out" in *"DRY: "*) rc=1 ;; *) rc=0 ;; esac; t "release: a refusal plans no step" "$rc" "0"
out="$(rel "$P3/benchmarks" 0.10.0)";    t "release: lower score refuses (exit 1)" "$?" "1"
has "release: lower score says why" "$out" "is lower than"
out="$(rel "$P/benchmarks" 1.3.0)";      t "release: higher score proceeds" "$?" "0"
has "release: higher score reaches the plan" "$out" "DRY: git"
P4="$FIX/p4"; new_project "$P4"
BENCH_DIR="$P4/benchmarks" bash "$CP" record 2.0.0 --from "$FIX/run-2of3.json" >/dev/null 2>&1
BENCH_DIR="$P4/benchmarks" bash "$CP" record 2.0.0 --from "$FIX/run-2of3.json" >/dev/null 2>&1
out="$(rel "$P4/benchmarks" 2.0.0)";     t "release: equal score proceeds" "$?" "0"
has "release: equal score prints the comparison" "$out" "not lower than"
out="$(rel "$P/benchmarks" 9.9.9 --skip-bench-check)";    t "release: override proceeds on a missing run" "$?" "0"
has "release: override is printed" "$out" "OVERRIDDEN by --skip-bench-check"
has "release: override still prints the reason" "$out" "no recorded checkpoint for 9.9.9"
out="$(rel "$P3/benchmarks" 0.10.0 --skip-bench-check)";  t "release: override proceeds on a lower score" "$?" "0"
has "release: override on a lower score is printed" "$out" "OVERRIDDEN by --skip-bench-check"
out="$(rel "$P/benchmarks" 1.3.0 --skip-bench-check)"
case "$out" in *OVERRIDDEN*) rc=1 ;; *) rc=0 ;; esac; t "release: a passing check prints no override" "$rc" "0"

# ---- 8. the results page is generated from the run files --------------------
page="$FIX/page.md"
bash "$CP" page --out "$page" >/dev/null 2>&1;      t "page --out writes" "$?" "0"
has "page: frontmatter title" "$(head -2 "$page")" "title: Benchmark results"
has "page: newest version first" "$(grep '^## ' "$page" | head -1)" "## 1.3.0"
has "page: a checkpoint row with its score" "$(cat "$page")" "| 1 | 2026-01-02 | \`develop@abc1234\` | test-model | 1 | **2/3** (66%)"
has "page: a missed question is listed, table-safe" "$(cat "$page")" 'Branch \| model &lt;x>?'
bash "$CP" page --out "$page" --check >/dev/null 2>&1; t "page --check: current" "$?" "0"
rec 1.3.0 --from "$FIX/run-3of3.json"
bash "$CP" page --out "$page" --check >/dev/null 2>&1; t "page --check: stale after a new checkpoint" "$?" "1"
# With `resultsPage` in the config, recording a checkpoint rewrites the page.
jq '. + {resultsPage: "site/results.md"}' "$BENCH_DIR/benchmark.config.json" > "$FIX/cfg.json" && cp "$FIX/cfg.json" "$BENCH_DIR/benchmark.config.json"
rec 1.3.0 --from "$FIX/run-3of3.json"
t "record rewrites the configured page" "$([ -s "$P/site/results.md" ] && echo yes)" "yes"
bash "$CP" page --check >/dev/null 2>&1;               t "page --check reads the configured path" "$?" "0"

# ---- 9. the verb reaches the script -----------------------------------------
out="$(cd "$P" && bash "$ROOT/bin/cckit" bench checkpoints 2>&1)"
has "cckit bench checkpoints lists" "$out" "1.2.0  #1"
( cd "$P" && bash "$ROOT/bin/cckit" bench check 9.9.9 >/dev/null 2>&1 ); t "cckit bench check exits 1 on a missing run" "$?" "1"

# ---- 10. this repo's own record ---------------------------------------------
unset BENCH_DIR
own_page="$(jq -r '.resultsPage // empty' "$ROOT/benchmarks/benchmark.config.json")"
t "this repo names its results page" "$own_page" "docs-site/src/content/docs/benchmark-results.md"
( cd "$ROOT" && bash "$CP" page --check >/dev/null 2>&1 ); t "the published results page matches benchmarks/runs" "$?" "0"
bad=0
for f in "$ROOT"/benchmarks/runs/*.json; do
  [ -e "$f" ] || continue
  v="$(basename "$f" .json)"
  printf '%s' "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "  not X.Y.Z: $f"; bad=1; }
  jq -e --arg v "$v" '.schema == 1 and .version == $v and (.checkpoints | length) >= 1
    and ([.checkpoints[].n] == [range(1; (.checkpoints | length) + 1)])' "$f" >/dev/null 2>&1 || { echo "  malformed: $f"; bad=1; }
done
t "every run file in benchmarks/runs is a well-formed checkpoint file" "$bad" "0"

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit "$fail"
