#!/usr/bin/env bash
# shellcheck shell=bash
# next-test.sh — self-test for next.sh (`cckit next`), E241.4: the human output names the weekly
# cadence, and the `--llm` TOON rows stay {number,ctx,title} — the cadence is prose for a person and
# must not leak into the rows an agent parses.
# Hermetic: a stubbed gh serves a three-issue board (one blocked) from fixture JSON and applies the
# caller's own `--jq` program with the real jq, so the plan machine runs unmodified. bash only —
# next_issue sources its siblings through BASH_SOURCE, as the dispatcher runs it.
# Run:  bash scripts/lib/next-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
dir="$(cd "$(dirname "$0")" && pwd)"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has(){ case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> output lacks '$3'"; fail=1 ;; esac; }
no() { case "$2" in *"$3"*) echo "FAIL: $1 -> output HAS '$3'"; fail=1 ;; *) echo "ok: $1" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "next-test: jq required — skipping"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
stub="$tmp/bin"; mkdir -p "$stub" "$tmp/labels" "$tmp/deps"

# Stub gh. Picks the fixture by subcommand, then runs the `--jq` program the caller passed (gh's
# --jq prints raw strings, i.e. `jq -r`). `issue list` -> $FX/issues.json; `issue view <N>` ->
# $FX/labels/<N>.json; `api …/issues/<N>/dependencies/blocked_by` -> $FX/deps/<N>.json or [].
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
src=""
case "$1 $2" in
  "issue list") src="$FX/issues.json" ;;
  "issue view") src="$FX/labels/$3.json" ;;
  "api repos/"*)
    n="${2%/dependencies/blocked_by}"; n="${n##*/}"
    src="$FX/deps/$n.json"; [ -f "$src" ] || src="" ;;
esac
prog="."
while [ "$#" -gt 0 ]; do
  case "$1" in --jq) prog="$2"; shift 2 ;; *) shift ;; esac
done
if [ -n "$src" ] && [ -f "$src" ]; then jq -r "$prog" "$src"; else echo '[]' | jq -r "$prog"; fi
SH
chmod +x "$stub/gh"

# Board: #5 (p2), #6 (p0), #7 blocked_by OPEN #5. Wave 0 = {6, 5} in priority order; 7 is wave 1.
cat > "$tmp/issues.json" <<'JSON'
[ {"number":5,"title":"[Effort 3] 1 · tidy the parser","body":"","milestone":null},
  {"number":6,"title":"fix the login crash","body":"","milestone":null},
  {"number":7,"title":"ship the report","body":"","milestone":null} ]
JSON
echo '{"labels":[{"name":"ctx:S"},{"name":"priority:p2"}]}' > "$tmp/labels/5.json"
echo '{"labels":[{"name":"ctx:M"},{"name":"priority:p0"}]}' > "$tmp/labels/6.json"
echo '{"labels":[{"name":"ctx:L"}]}'                        > "$tmp/labels/7.json"
echo '[{"number":5,"state":"open"}]'                        > "$tmp/deps/7.json"

run_next() {  # stdout of `next_issue "$@"` against the fixture board
  ( export FX="$tmp" PATH="$stub:$PATH" NEXT_REPO="octo/fixture" PLAN_REPO="octo/fixture" CCKIT_NO_GLOW=1
    unset CCKIT_OUTPUT
    # shellcheck source=/dev/null
    . "$dir/next.sh"
    next_issue "$@" )
}

# ── human output: the unblocked set, the pick, and the cadence ──────────────────────────────────
human="$(run_next 2>&1)"; rc=$?
t   "human: rc 0"                              "$rc" "0"
has "human: lists the unblocked p0 issue"      "$human" "| #6 | M | fix the login crash |"
has "human: lists the unblocked p2 issue"      "$human" "| #5 | S | tidy the parser |"
no  "human: the blocked issue is not offered"  "$human" "ship the report"
has "human: recommends the most urgent"        "$human" "cckit start 6"
has "human: names the cadence"                 "$human" "Weekly cadence"
has "human: plan on Monday"                    "$human" 'Monday: `cckit plan`'
has "human: next daily"                        "$human" 'daily: `cckit next`'
has "human: gc on Friday"                      "$human" 'Friday: `cckit gc`'
no  "human: digest is not in the cadence"      "$human" "digest"
t   "human: the cadence is printed once"       "$(printf '%s\n' "$human" | grep -c 'Weekly cadence')" "1"

# ── --llm: TOON rows stay {number,ctx,title}; no cadence prose in the machine output ────────────
llm="$(run_next --llm 2>/dev/null)"; rc=$?
t   "llm: rc 0"                                "$rc" "0"
has "llm: the TOON header is number,ctx,title" "$llm" "{number,ctx,title}"
t   "llm: two rows, the unblocked set"         "$(printf '%s\n' "$llm" | head -1 | grep -c '^\[2\]')" "1"
t   "llm: the p0 row leads"                    "$(printf '%s\n' "$llm" | sed -n 2p)" '6,"M","fix the login crash"'
t   "llm: header + two rows, nothing else"     "$(printf '%s\n' "$llm" | grep -c .)" "3"
no  "llm: no cadence line"                     "$llm" "cadence"
no  "llm: no weekday"                          "$llm" "Monday"

# ── an empty board keeps its one-line answers ───────────────────────────────────────────────────
echo '[]' > "$tmp/issues.json"
t "empty board, llm: []"   "$(run_next --llm 2>/dev/null)" "[]"
has "empty board, human: says nothing is unblocked" "$(run_next 2>&1)" "nothing unblocked"

# ── --help prints the usage lines, cadence included ─────────────────────────────────────────────
help="$(run_next --help 2>&1)"
has "help: shows the bare verb"        "$help" "cckit next "
has "help: shows --effort"             "$help" "cckit next --effort <N>"
has "help: shows --llm"                "$help" "cckit next --llm"
no  "help: stops before the requires line" "$help" "Requires"

[ "$fail" -eq 0 ] && echo "ALL OK (next)" || echo "next: FAILURES"
exit "$fail"
