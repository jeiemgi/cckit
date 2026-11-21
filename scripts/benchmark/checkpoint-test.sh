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

# A run over named questions: each argument is <id>:<1|0> (answered right or not).
mk_ids() {
  local a list=""
  for a in "$@"; do list="$list${list:+,}{\"id\":\"${a%%:*}\",\"ok\":${a##*:}}"; done
  jq -n --argjson qs "[$list]" '
    { kind: "retrieval-run", dry: false, total: ($qs | length), pass: ([ $qs[] | select(.ok == 1) ] | length),
      results: [ $qs[] | { set: "retrieval.jsonl", tier: "retrieval", id: .id,
                 got: (if .ok == 1 then "x.md" else "NONE" end), expect: "x.md",
                 pass: (.ok == 1), latency_ms: 1000 } ] }'
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
# An empty answer is what run.sh stores when the model backend failed; it is not a score.
jq '.results[0].got = ""' "$FIX/run-3of3.json" > "$FIX/run-noanswer.json"
out="$(bash "$CP" record 1.2.0 --from "$FIX/run-noanswer.json" 2>&1)";   t "record refuses a run with an empty answer" "$?" "2"
has "the empty-answer refusal says why" "$out" "the model backend returned nothing"
# A flag given last with no value is a usage error, not an endless parse loop (5 s watchdog).
for flag in --from --passes --model --commit --ref --date --note --verbs; do
  perl -e 'alarm 5; exec @ARGV' bash "$CP" record 1.2.0 "$flag" >/dev/null 2>&1; t "record: $flag with no value exits 2" "$?" "2"
done
perl -e 'alarm 5; exec @ARGV' bash "$CP" page --out >/dev/null 2>&1;      t "page: --out with no value exits 2" "$?" "2"
has "record --help prints the usage" "$(bash "$CP" record --help 2>&1)" "checkpoint.sh record <X.Y.Z>"
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
out="$(bash "$CP" check 1.3.0 2>&1)"
has "check: lower names both scores" "$out" "1.3.0 checkpoint 2: 2/3 (66%) is lower than 1.3.0 checkpoint 1: 3/3 (100%)"
has "check: lower names how many questions were compared" "$out" "on the 3 question(s) both asked (2/3 now, 3/3 before); 0 new, 0 removed"
has "check: lower names the question that got worse" "$out" "right before, missed now: retrieval.jsonl r3"
rec 1.3.0 --from "$FIX/run-3of3.json"
bash "$CP" check 1.3.0 >/dev/null 2>&1;  t "check: a later, higher checkpoint clears the refusal" "$?" "0"
bash "$CP" check 1.2.0 >/dev/null 2>&1;  t "check: a later version does not change an earlier verdict" "$?" "0"
bash "$CP" check bogus >/dev/null 2>&1;  t "check: a non X.Y.Z version is a usage error" "$?" "2"

# A run file that is not a checkpoint file is named, exit 2: no blank verdict, no empty list or page.
P5="$FIX/p5"; new_project "$P5"
cp5() { BENCH_DIR="$P5/benchmarks" bash "$CP" "$@" 2>&1; }
cp5 record 1.0.0 --from "$FIX/run-3of3.json" >/dev/null
cp5 page --out "$FIX/p5-page.md" >/dev/null; p5_page="$(cat "$FIX/p5-page.md")"
printf '{bad' > "$P5/benchmarks/runs/0.9.0.json"
out="$(cp5 check 1.0.0)";  t "check: an unreadable run file is exit 2" "$?" "2"
has "check: the unreadable file is named" "$out" "runs/0.9.0.json is not a checkpoint file"
cp5 list >/dev/null;       t "list: an unreadable run file is exit 2" "$?" "2"
cp5 page >/dev/null;       t "page: an unreadable run file is exit 2" "$?" "2"
cp5 page --out "$FIX/p5-page.md" >/dev/null; t "page --out: an unreadable run file is exit 2" "$?" "2"
t "page --out: the page on disk is left as it was" "$(cat "$FIX/p5-page.md")" "$p5_page"
cp5 record 1.0.0 --from "$FIX/run-3of3.json" >/dev/null; t "record: an unreadable run file is exit 2" "$?" "2"
t "record: nothing was appended" "$(jq '.checkpoints | length' "$P5/benchmarks/runs/1.0.0.json")" "1"
out="$(KIT_RELEASE_BENCH_DIR="$P5/benchmarks" bash "$PUBLISH" 1.0.0 2>&1)"; t "release: an unreadable run file refuses (exit 1)" "$?" "1"
has "release: the unreadable file is named" "$out" "is not a checkpoint file"

# First version ever recorded has nothing to compare against.
P2="$FIX/p2"; new_project "$P2"
BENCH_DIR="$P2/benchmarks" bash "$CP" record 0.1.0 --from "$FIX/run-1of3.json" >/dev/null 2>&1
BENCH_DIR="$P2/benchmarks" bash "$CP" check 0.1.0 >/dev/null 2>&1; t "check: the first recorded checkpoint passes" "$?" "0"

# Versions order numerically (0.10.0 follows 0.9.0). mk_run names its questions r1..rN and answers
# the first <pass> right, so a 6-question run shares r1..r3 with a 3-question one.
P3="$FIX/p3"; new_project "$P3"
cp3() { BENCH_DIR="$P3/benchmarks" bash "$CP" "$@" >/dev/null 2>&1; }
cp3 record 0.9.0 --from "$FIX/run-2of3.json"
cp3 record 0.10.0 --from "$FIX/run-4of6.json"
cp3 check 0.10.0; t "check: 4/6 against 2/3 is 3/3 against 2/3 on the 3 shared questions" "$?" "0"
cp3 record 0.10.0 --from "$FIX/run-1of3.json"
cp3 record 0.9.1 --from "$FIX/run-5of6.json"
cp3 check 0.9.1;  t "check: 0.9.1 compares against 0.9.0, not 0.10.0" "$?" "0"
cp3 check 0.10.0; t "check: 0.10.0 last checkpoint 1/3 is lower than 3/3 on the shared questions" "$?" "1"

# ---- 6b. comparison over the questions both checkpoints asked ---------------
# One project per case: a 3-question checkpoint, then a second one over a changed set.
cmp_case() {   # cmp_case <second run file> [<first run file>] -> prints the verdict, returns check's exit
  # Called in $(…), so the directory is named after the run file and not after a counter.
  local d; d="$FIX/c-$(basename "$1" .json)"; new_project "$d"
  BENCH_DIR="$d/benchmarks" bash "$CP" record 3.0.0 --from "${2:-$FIX/ids-base.json}" >/dev/null 2>&1
  BENCH_DIR="$d/benchmarks" bash "$CP" record 3.0.0 --from "$1" >/dev/null 2>&1
  BENCH_DIR="$d/benchmarks" bash "$CP" check 3.0.0 2>&1
}
mk_ids r1:1 r2:1 r3:1 > "$FIX/ids-base.json"
# Grown set, every shared question still right, one NEW question missed: 5/6 is under 3/3 as a
# whole-run fraction, and it is not lower.
mk_ids r1:1 r2:1 r3:1 n1:1 n2:1 n3:0 > "$FIX/ids-grown-ok.json"
out="$(cmp_case "$FIX/ids-grown-ok.json")"; t "check: grown set, shared questions all still right, passes" "$?" "0"
has "check: grown set says what was compared" "$out" "3.0.0 checkpoint 2: 5/6 (83%) — not lower than 3.0.0 checkpoint 1: 3/3 (100%) on the 3 question(s) both asked (3/3 now, 3/3 before); 3 new, 0 removed"
# Grown set, a shared question newly missed: refused although every new question is right.
mk_ids r1:1 r2:0 r3:1 n1:1 n2:1 n3:1 > "$FIX/ids-grown-low.json"
out="$(cmp_case "$FIX/ids-grown-low.json")"; t "check: grown set, a shared question newly missed, refuses" "$?" "1"
has "check: grown-set refusal says what was compared" "$out" "is lower than 3.0.0 checkpoint 1: 3/3 (100%) on the 3 question(s) both asked (2/3 now, 3/3 before); 3 new, 0 removed"
has "check: grown-set refusal names the question" "$out" "right before, missed now: retrieval.jsonl r2"
# No question in common: nothing to compare, so the checkpoint is a new baseline.
mk_ids n1:1 n2:0 > "$FIX/ids-disjoint.json"
out="$(cmp_case "$FIX/ids-disjoint.json")"; t "check: disjoint sets pass as a new baseline" "$?" "0"
has "check: a new baseline is named as one" "$out" "3.0.0 checkpoint 2: 1/2 (50%) — new baseline: it shares no question with 3.0.0 checkpoint 1: 3/3 (100%) (2 new, 3 removed)"
# The same id in another set file is another question.
jq '.results |= map(.set = "other.jsonl")' "$FIX/ids-base.json" > "$FIX/ids-otherset.json"
out="$(cmp_case "$FIX/ids-otherset.json")"; t "check: the same ids in another set file share nothing" "$?" "0"
has "check: another set file is a new baseline" "$out" "new baseline"
# Removed questions: a missed question that was dropped does not raise or lower the verdict.
mk_ids r1:1 r2:1 r3:0 > "$FIX/ids-base-miss.json"
mk_ids r1:1 r2:1 > "$FIX/ids-removed.json"
out="$(cmp_case "$FIX/ids-removed.json" "$FIX/ids-base-miss.json")"; t "check: removed question, the rest unchanged, passes" "$?" "0"
has "check: removed questions are counted" "$out" "on the 2 question(s) both asked (2/2 now, 2/2 before); 0 new, 1 removed"
mk_ids r1:1 r2:0 > "$FIX/ids-removed-low.json"
out="$(cmp_case "$FIX/ids-removed-low.json")"; t "check: removed question and a remaining one newly missed, refuses" "$?" "1"
has "check: the removal refusal counts both" "$out" "on the 2 question(s) both asked (1/2 now, 2/2 before); 0 new, 1 removed"
# The verdict is the score on the shared questions: one newly missed and one newly right is level,
# and the question that got worse is still named.
mk_ids r1:0 r2:1 r3:1 > "$FIX/ids-swap.json"
out="$(cmp_case "$FIX/ids-swap.json" "$FIX/ids-base-miss.json")"; t "check: one newly missed, one newly right, is not lower" "$?" "0"
has "check: a level score still names the question that got worse" "$out" "right before, missed now: retrieval.jsonl r1"
# Passes differ: 2 passes over r1..r3 (5 of 6 answers) against 1 pass (3 of 3) is lower.
d="$FIX/c-passes"; new_project "$d"
BENCH_DIR="$d/benchmarks" bash "$CP" record 3.0.0 --from "$FIX/ids-base.json" >/dev/null 2>&1
BENCH_DIR="$d/benchmarks" bash "$CP" record 3.0.0 --from "$FIX/ids-base.json" --from "$FIX/ids-base-miss.json" >/dev/null 2>&1
out="$(BENCH_DIR="$d/benchmarks" bash "$CP" check 3.0.0 2>&1)"; t "check: a question missed in one of two passes is lower" "$?" "1"
has "check: passes are counted as answers" "$out" "(5/6 now, 3/3 before)"
# The release reads the same verdict: a grown set does not refuse it.
d="$FIX/c-release"; new_project "$d"
BENCH_DIR="$d/benchmarks" bash "$CP" record 3.0.0 --from "$FIX/ids-base.json" >/dev/null 2>&1
BENCH_DIR="$d/benchmarks" bash "$CP" record 3.0.0 --from "$FIX/ids-grown-ok.json" >/dev/null 2>&1
out="$(KIT_RELEASE_BENCH_DIR="$d/benchmarks" bash "$PUBLISH" 3.0.0 2>&1)"; t "release: a grown set with no shared question worse proceeds" "$?" "0"
has "release: the grown-set comparison is printed" "$out" "3 new, 0 removed"

# ---- 7. cckit release (publish.sh) refuses on the same verdict --------------
# Dry runs only: publish.sh prints its plan and changes nothing.
rel() { KIT_RELEASE_BENCH_DIR="$1" bash "$PUBLISH" "$2" ${3:+"$3"} 2>&1; }
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
has "release: a redirected runs dir is printed" "$out" "benchmark runs read from KIT_RELEASE_BENCH_DIR=$P/benchmarks"
# BENCH_DIR belongs to `cckit bench`; the release reads this repo's own runs whatever it is set to.
# $P has no 9.9.9 run, so a release that honoured BENCH_DIR would be refused for 9.9.9 from $P.
own_v="$(basename "$(ls "$ROOT"/benchmarks/runs/*.json | sed -n 1p)" .json)"
out="$(BENCH_DIR="$FIX/nowhere" bash "$PUBLISH" "$own_v" 2>&1)"
case "$out" in *"$FIX/nowhere"*) rc=1 ;; *) rc=0 ;; esac; t "release: BENCH_DIR does not move the release check" "$rc" "0"
has "release: with BENCH_DIR set the check still reads this repo's runs" "$out" "benchmark check: $own_v checkpoint"

# ---- 8. the results page is generated from the run files --------------------
page="$FIX/page.md"
bash "$CP" page --out "$page" >/dev/null 2>&1;      t "page --out writes" "$?" "0"
has "page: frontmatter title" "$(head -2 "$page")" "title: Benchmark results"
has "page: newest version first" "$(grep '^## ' "$page" | sed -n 1p)" "## 1.3.0"
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

# ---- 8b. verb timings attached to a checkpoint ------------------------------
P6="$FIX/p6"; new_project "$P6"
cp6() { BENCH_DIR="$P6/benchmarks" bash "$CP" "$@" 2>&1; }
cat > "$FIX/verbs.json" <<'JSON'
{ "kind": "verb-timings", "date": "2026-01-02", "commit": "abc1234", "runs": 3,
  "verbs": [ { "verb": "status", "runs": 3, "min_ms": 410, "median_ms": 450, "gh_calls": 7, "exit": 0 },
             { "verb": "effort plan", "runs": 3, "min_ms": 90, "median_ms": 95, "gh_calls": 2, "exit": 1 } ] }
JSON
out="$(cp6 record 4.0.0 --from "$FIX/run-3of3.json" --verbs "$FIX/verbs.json" --date 2026-01-02 --commit abc1234 --ref develop --model test-model)"
t "record --verbs exits 0" "$?" "0"
has "record --verbs says how many verbs were attached" "$out" "2 verb timings"
t "the checkpoint carries the verbs" "$(jq -c '.checkpoints[0].verbs[0]' "$P6/benchmarks/runs/4.0.0.json")" '{"verb":"status","runs":3,"min_ms":410,"median_ms":450,"gh_calls":7}'
t "a non-zero exit is kept with the verb" "$(jq -c '.checkpoints[0].verbs[1].exit' "$P6/benchmarks/runs/4.0.0.json")" "1"
cp6 record 4.0.0 --from "$FIX/run-3of3.json" >/dev/null
t "a checkpoint without --verbs has no verbs key" "$(jq -c '.checkpoints[1] | has("verbs")' "$P6/benchmarks/runs/4.0.0.json")" "false"
cp6 check 4.0.0 >/dev/null; t "check ignores the verbs" "$?" "0"
p6_page="$(cp6 page)"
has "page: the verb table header" "$p6_page" "| Verb | Runs | Min ms | Median ms | gh calls |"
has "page: a verb row" "$p6_page" '| `cckit status` | 3 | 410 | 450 | 7 |'
has "page: a failed verb shows its exit code" "$p6_page" '| `cckit effort plan` (exit 1) | 3 | 90 | 95 | 2 |'
t "page: one verb table, for the checkpoint that has one" "$(grep -c 'verb timings' <<<"$p6_page")" "1"
before="$(cat "$P6/benchmarks/runs/4.0.0.json")"
cp6 record 4.0.0 --from "$FIX/run-3of3.json" --verbs "$FIX/nope.json" >/dev/null; t "record --verbs refuses a missing file" "$?" "2"
printf '%s' '{"verbs":[{"verb":"status","runs":3}]}' > "$FIX/verbs-bad.json"
out="$(cp6 record 4.0.0 --from "$FIX/run-3of3.json" --verbs "$FIX/verbs-bad.json")"; t "record --verbs refuses rows without the timing fields" "$?" "2"
has "the --verbs refusal says why" "$out" "is not a verb timings file"
t "a refused --verbs leaves the file unchanged" "$(cat "$P6/benchmarks/runs/4.0.0.json")" "$before"

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
  grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$v" || { echo "  not X.Y.Z: $f"; bad=1; }
  jq -e --arg v "$v" '.schema == 1 and .version == $v and (.checkpoints | length) >= 1
    and ([.checkpoints[].n] == [range(1; (.checkpoints | length) + 1)])' "$f" >/dev/null 2>&1 || { echo "  malformed: $f"; bad=1; }
done
t "every run file in benchmarks/runs is a well-formed checkpoint file" "$bad" "0"

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit "$fail"
