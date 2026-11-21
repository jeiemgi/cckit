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

# ---- 0. a live backend that reads stdin must not swallow the remaining records ----
# The real `claude -p` reads stdin. The runners loop with `while read … done < <(records)`, so a
# child inheriting that stdin drained it and each set scored only its first record.
STUB="$FIX/stub"; mkdir -p "$STUB"
printf '%s\n' '#!/bin/sh' 'cat >/dev/null' 'echo NONE' > "$STUB/claude"; chmod +x "$STUB/claude"
n="$(PATH="$STUB:$PATH" BENCH_BACKEND=claude bash "$HERE/run.sh" --set "$FIX/bench/retrieval.jsonl" --json 2>/dev/null | jq -r '.total')"
t "a stdin-reading backend still runs every record" "$n" "2"

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

# ---- 10. live report keeps every number on one line (#252) -------------------
# run.sh exits 1 on this fixture (1 pass / 2 fail, section 5). report.sh used to append a second
# JSON document on that exit, so each number it read came back as two lines ("33\n0%").
rm -f "$FIX/RESULTS.md"
rep_out="$(BENCH_BACKEND=mock bash "$HERE/report.sh" --out "$FIX/RESULTS.md" 2>/dev/null)"
grep -q 'Retrieval score: 33%\*\* — of 3 questions' "$FIX/RESULTS.md"; t "live report: score + total on one line" "$?" "0"
grep -q '\*\*1\*\* times' "$FIX/RESULTS.md";                          t "live report: pass count on one line" "$?" "0"
grep -qE '^0(%|\*\*| questions)' "$FIX/RESULTS.md";                    t "live report: no number split over a newline" "$?" "1"
t "live report: stdout summary is one line" "$(printf '%s\n' "$rep_out" | wc -l | tr -d ' ')" "1"
case "$rep_out" in *"retrieval 33%"*) rc=0 ;; *) rc=1 ;; esac;        t "live report: stdout carries 33%" "$rc" "0"

# ---- 11. a tier that prints nothing still reports zeros, not a crash ---------
# No quality set on disk: run-quality.sh exits non-zero with no JSON; the report falls back to {}.
mv "$FIX/bench/quality.jsonl" "$FIX/bench/quality.jsonl.off"
BENCH_BACKEND=mock bash "$HERE/report.sh" --out "$FIX/RESULTS.md" >/dev/null 2>&1; t "report without quality set exits 0" "$?" "0"
grep -q 'Retrieval score: 33%\*\* — of 3 questions' "$FIX/RESULTS.md"; t "report without quality set keeps headline" "$?" "0"
grep -q 'Answer quality' "$FIX/RESULTS.md";                            t "report without quality set omits quality line" "$?" "1"
mv "$FIX/bench/quality.jsonl.off" "$FIX/bench/quality.jsonl"

# ---- 12. the quality tier grades a full answer, not a path --------------------
# run-quality.sh used to call bench_ask, which returns ONE path (the last non-empty line of the
# reply). A path covers no rubric point, so every claim scored 0 whatever the docs said. The stub
# answers in two lines and its judge returns 1 only when both lines reached it.
QSTUB="$FIX/qstub"; mkdir -p "$QSTUB"
cat > "$QSTUB/claude" <<'STUBEOF'
#!/bin/sh
cat >/dev/null
case "$2" in
  *"Grade an answer"*) case "$2" in *"line one"*"line two"*) echo 1 ;; *) echo 0 ;; esac ;;
  *"answering a question"*) printf 'line one\nline two\n' ;;
  *) echo NONE ;;
esac
STUBEOF
chmod +x "$QSTUB/claude"
q_mean="$(PATH="$QSTUB:$PATH" BENCH_BACKEND=claude bash "$HERE/run-quality.sh" --json --answers "$FIX/answers" 2>/dev/null | jq -r '.mean == 1')"
t "quality: the judge sees the whole answer" "$q_mean" "true"
t "quality: --answers keeps the graded answer" "$(wc -l < "$FIX/answers/q1.txt" 2>/dev/null | tr -d ' ')" "2"
t "quality: --answers keeps the judge's reply" "$(cat "$FIX/answers/q1.judge.txt" 2>/dev/null)" "1"

# An empty answer (backend failed or timed out) scores 0 and never reaches the judge.
cat > "$QSTUB/claude" <<'STUBEOF'
#!/bin/sh
cat >/dev/null
case "$2" in *"Grade an answer"*) echo 1 ;; esac
STUBEOF
q_mean="$(PATH="$QSTUB:$PATH" BENCH_BACKEND=claude bash "$HERE/run-quality.sh" --json 2>/dev/null | jq -r '.mean == 0 and .count == 1')"
t "quality: an empty answer scores 0" "$q_mean" "true"

# --answers with no directory is refused. It used to loop forever: `shift 2` with one argument left
# shifts nothing, so the parser saw --answers again. The watchdog turns a regression into a failure.
perl -e 'alarm 20; exec @ARGV' bash "$HERE/run-quality.sh" --dry --answers >/dev/null 2>&1
t "quality: --answers without a directory exits 2" "$?" "2"
bash "$HERE/run-quality.sh" --dry --answers= >/dev/null 2>&1
t "quality: an empty --answers= exits 2" "$?" "2"
# The empty-answer run above wrote into no directory; with one, a judge reply left by an earlier run
# is removed, because this run's answer never reached the judge.
PATH="$QSTUB:$PATH" BENCH_BACKEND=claude bash "$HERE/run-quality.sh" --json --answers "$FIX/answers" >/dev/null 2>&1
[ ! -e "$FIX/answers/q1.judge.txt" ]; t "quality: a stale judge reply is removed" "$?" "0"

# ---- 13. cckit's own sets point at pages that exist --------------------------
# benchmarks/ scores cckit's own docs. A renamed or deleted page turns its questions into
# guaranteed failures that read as a retrieval regression, so the paths are checked offline here.
REPO="$(cd "$HERE/../.." && pwd)"
# Only in cckit's own checkout: a consuming project's sets use paths relative to its knowledge dir.
if [ -f "$REPO/bin/cckit" ] && [ -f "$REPO/benchmarks/benchmark.config.json" ]; then
  missing="$(cd "$REPO" && for f in benchmarks/*.jsonl; do
      grep -vE '^[[:space:]]*(#|$)' "$f" | jq -r '[.expect // empty, .source // empty] | flatten | .[]'
    done | grep -v '^NONE$' | sort -u | while IFS= read -r p; do [ -f "$p" ] || printf '%s\n' "$p"; done)"
  t "own sets: every expect/source path exists" "$missing" ""
  dupes="$(cd "$REPO" && cat benchmarks/*.jsonl | grep -vE '^[[:space:]]*(#|$)' | jq -r '.id' | sort | uniq -d)"
  t "own sets: ids are unique" "$dupes" ""
  (cd "$REPO" && BENCH_DIR="$REPO/benchmarks" bash "$HERE/run.sh" --dry >/dev/null 2>&1);         t "own sets: run --dry" "$?" "0"
  (cd "$REPO" && BENCH_DIR="$REPO/benchmarks" bash "$HERE/run-quality.sh" --dry >/dev/null 2>&1); t "own sets: quality --dry" "$?" "0"
  nosrc="$(cd "$REPO" && grep -vE '^[[:space:]]*(#|$)' benchmarks/quality.jsonl 2>/dev/null | jq -r 'select((.source // "") == "") | .id')"
  t "own sets: every quality record cites its source page" "$nosrc" ""
fi

[ "$fail" -eq 0 ] && echo "ALL OK" || echo "SOME FAILED"
exit "$fail"
