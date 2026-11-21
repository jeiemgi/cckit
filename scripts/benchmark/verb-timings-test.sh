#!/usr/bin/env bash
# verb-timings-test.sh — wall time + gh call count per verb (#452). Offline: the measured CLI is a
# fake `cckit` and `gh` is a stub on PATH, so no verb of the real CLI runs and no network call is made.
# Run: bash scripts/benchmark/verb-timings-test.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
VT="$HERE/verb-timings.sh"

fail=0
t() { if [ "$2" != "$3" ]; then echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok: $1"; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '[$3]' not in '[$2]'"; fail=1 ;; esac; }

command -v jq >/dev/null 2>&1   || { echo "SKIP: jq absent"; exit 0; }
command -v perl >/dev/null 2>&1 || { echo "SKIP: perl absent"; exit 0; }

FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT
FIX="$(cd "$FIX" && pwd -P)"
mkdir -p "$FIX/bin" "$FIX/co" "$FIX/tmp"

# The stub gh: records its arguments one per line, prints a line, exits 4 for `gh fail`.
cat > "$FIX/bin/gh" <<'STUB'
#!/bin/sh
for a in "$@"; do printf '[%s]' "$a" >> "$STUB_LOG"; done; printf '\n' >> "$STUB_LOG"
echo "stub-out:$1"
[ "$1" = "fail" ] && exit 4
exit 0
STUB
chmod +x "$FIX/bin/gh"

# The fake CLI. Every call appends "<cwd>|<args>" to FAKE_LOG.
cat > "$FIX/fake-cckit" <<'FAKE'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$FAKE_LOG"
case "$*" in
  alpha)       gh api "repos/o/r/issues" -f "q=a b" > "$FAKE_OUT"; gh issue list >> "$FAKE_OUT"; echo "noise on stdout" ;;
  "two words") gh pr list >/dev/null ;;
  beta)        exit 3 ;;
  ghfail)      gh fail > "$FAKE_OUT"; echo "rc=$?" >> "$FAKE_OUT" ;;
  slow)        sleep 0.3 ;;
  vary)        n="$(cat "$FAKE_COUNT" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" > "$FAKE_COUNT"
               case "$n" in 1) k=1 ;; 2) k=5 ;; *) k=2 ;; esac
               i=0; while [ "$i" -lt "$k" ]; do gh api x >/dev/null; i=$((i+1)); done ;;
  path)        command -v gh > "$FAKE_OUT" ;;
esac
exit 0
FAKE

export STUB_LOG="$FIX/stub.log" FAKE_LOG="$FIX/fake.log" FAKE_OUT="$FIX/fake.out" FAKE_COUNT="$FIX/count"
: > "$STUB_LOG"; : > "$FAKE_LOG"
PATH_BEFORE="$FIX/bin:$PATH"
vt() { PATH="$FIX/bin:$PATH" TMPDIR="$FIX/tmp" bash "$VT" --checkout "$FIX/co" --cckit "$FIX/fake-cckit" "$@"; }

# ---- 1. counts, exit codes, shape -------------------------------------------
out="$(vt --json --verb alpha --verb "two words" --verb beta 2>/dev/null)"; t "measure exits 0" "$?" "0"
t "one JSON object of kind verb-timings" "$(jq -r '"\(.kind) \(.runs) \(.verbs | length)"' <<<"$out")" "verb-timings 3 3"
t "alpha: 2 gh calls per run" "$(jq -c '.verbs[0] | [.verb, .runs, .gh_calls, .exit]' <<<"$out")" '["alpha",3,2,0]'
t "a two-word verb is one row and is split into arguments" "$(jq -c '.verbs[1] | [.verb, .gh_calls]' <<<"$out")" '["two words",1]'
t "beta: no gh call, exit code kept" "$(jq -c '.verbs[2] | [.verb, .gh_calls, .exit]' <<<"$out")" '["beta",0,3]'
t "every row has integer timings, min <= median" "$(jq -c '[.verbs[] | (.min_ms | type) == "number" and .min_ms == (.min_ms | floor) and .min_ms <= .median_ms] | all' <<<"$out")" "true"
t "each verb ran --runs times" "$(grep -c '|alpha$' "$FAKE_LOG")" "3"
t "the verbs ran in the checkout" "$(sed -n 1p "$FAKE_LOG")" "$FIX/co|alpha"
t "the verb's own output is not in the result" "$(grep -c 'noise' <<<"$out")" "0"

# ---- 2. the shim changes nothing --------------------------------------------
t "the real gh got the same arguments, spaces kept" "$(sed -n 1p "$STUB_LOG")" "[api][repos/o/r/issues][-f][q=a b]"
t "the real gh ran once per call: 3 runs x 3 calls" "$(wc -l < "$STUB_LOG" | tr -d ' ')" "9"
t "gh's output reaches the verb" "$(tr '\n' ' ' < "$FAKE_OUT")" "stub-out:api stub-out:issue "
vt --json --runs 1 --verb ghfail >/dev/null 2>&1
t "gh's exit code reaches the verb" "$(tr '\n' ' ' < "$FAKE_OUT")" "stub-out:fail rc=4 "
vt --json --runs 1 --verb path >/dev/null 2>&1
shim="$(cat "$FAKE_OUT")"
has "inside a measured verb gh is the shim, in the temp dir" "$shim" "$FIX/tmp/"
t "the shim is gone after the run" "$([ -e "$shim" ] && echo present || echo gone)" "gone"
t "nothing is left in the temp dir" "$(find "$FIX/tmp" -mindepth 1 | wc -l | tr -d ' ')" "0"
t "the caller's PATH is unchanged" "$FIX/bin:$PATH" "$PATH_BEFORE"
t "the caller still resolves the real gh" "$(PATH="$FIX/bin:$PATH" command -v gh)" "$FIX/bin/gh"

# ---- 3. median and timing ---------------------------------------------------
rm -f "$FAKE_COUNT"
out="$(vt --json --verb vary 2>/dev/null)"
t "gh_calls is the median across runs (1, 5, 2 -> 2)" "$(jq -r '.verbs[0].gh_calls' <<<"$out")" "2"
rm -f "$FAKE_COUNT"
out="$(vt --json --runs 2 --verb vary 2>/dev/null)"
t "an even number of runs takes the mean of the middle two, rounded down (1, 5 -> 3)" "$(jq -r '.verbs[0].gh_calls' <<<"$out")" "3"
out="$(vt --json --runs 1 --verb slow 2>/dev/null)"
t "a verb that sleeps 300 ms is timed at 300 ms or more" "$(jq -r '.verbs[0].min_ms >= 300' <<<"$out")" "true"
t "--runs is recorded per verb" "$(jq -r '.verbs[0].runs' <<<"$out")" "1"

# ---- 4. the default list and the human table --------------------------------
: > "$FAKE_LOG"
out="$(vt --runs 1 2>/dev/null)"
t "the default list, in order" "$(sed 's/^.*|//' "$FAKE_LOG" | tr '\n' ',')" "status,sync,next,plan,gc,effort plan,claims,task list,qa lanes,"
has "the table has a header" "$(sed -n 1p <<<"$out")" "MEDIAN_MS"
t "the table has one row per verb" "$(wc -l <<<"$out" | tr -d ' ')" "10"
# No verb in the default list is one that writes: each is a read verb of bin/cckit.
bad=0
while IFS= read -r v; do
  case "$v" in start*|pr*|close*|merge*|cleanup*|new*|"effort new"*|"effort start"*|"effort close"*|"effort pr"*|"effort chain"*|"task new"*|"task start"*|"task finish"*|"qa up"*|"qa stop"*|"qa verdict"*|release*|init*|*--prune*|*--write*|*--fix*) echo "  writes: $v"; bad=1 ;; esac
done < <(sed 's/^.*|//' "$FAKE_LOG")
t "the default list holds no verb that writes" "$bad" "0"

# ---- 5. refusals ------------------------------------------------------------
vt --runs 0 >/dev/null 2>&1;                 t "--runs 0 is a usage error" "$?" "2"
vt --runs >/dev/null 2>&1;                   t "--runs with no value is a usage error" "$?" "2"
vt --bogus >/dev/null 2>&1;                  t "an unknown argument is a usage error" "$?" "2"
PATH="$FIX/bin:$PATH" bash "$VT" --checkout "$FIX/nowhere" --cckit "$FIX/fake-cckit" >/dev/null 2>&1; t "a missing checkout is refused" "$?" "2"
PATH="$FIX/bin:$PATH" bash "$VT" --checkout "$FIX/co" --cckit "$FIX/no-cckit" >/dev/null 2>&1;       t "a missing cckit is refused" "$?" "2"
has "--help prints the usage" "$(bash "$VT" --help 2>&1)" "verb-timings.sh [--runs <N>]"

# ---- 6. the result attaches to a checkpoint, and the verb reaches the script --
mkdir -p "$FIX/p/benchmarks"
printf '%s\n' '{"id":"r1","q":"How do we release?","expect":"x.md"}' > "$FIX/p/benchmarks/retrieval.jsonl"
jq -n '{ kind: "retrieval-run", dry: false, total: 1, pass: 1,
         results: [ { set: "retrieval.jsonl", tier: "retrieval", id: "r1", got: "x.md", expect: "x.md", pass: true, latency_ms: 1 } ] }' > "$FIX/run.json"
vt --json --runs 1 --verb alpha --verb beta > "$FIX/verbs.json" 2>/dev/null
BENCH_DIR="$FIX/p/benchmarks" bash "$HERE/checkpoint.sh" record 1.0.0 --from "$FIX/run.json" --verbs "$FIX/verbs.json" \
  --date 2026-01-02 --commit abc1234 --ref develop --model test-model >/dev/null 2>&1
t "checkpoint record --verbs takes the script's output" "$?" "0"
t "the checkpoint holds both verbs" "$(jq -c '[.checkpoints[0].verbs[] | [.verb, .gh_calls]]' "$FIX/p/benchmarks/runs/1.0.0.json")" '[["alpha",2],["beta",0]]'
has "cckit bench verbs reaches the script" "$(bash "$ROOT/bin/cckit" bench verbs --help 2>&1)" "verb-timings.sh [--runs <N>]"

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit "$fail"
