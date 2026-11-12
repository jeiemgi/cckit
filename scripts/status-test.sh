#!/usr/bin/env bash
# shellcheck shell=bash
# status-test.sh — regression for #142: `cckit status` board counters must be clean integers and
# never throw "integer expression expected". The bug: status fed `task-sync --llm` (TOON, not JSON)
# into `jq 'length'`, so the count became a concatenated value like "1\n0" that broke `[ … -gt 8 ]`.
# Hermetic: a fixture repo + a stubbed gh returning a known issue list. Run: bash scripts/status-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has(){ case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> output lacks '$3'"; fail=1 ;; esac; }
no() { case "$2" in *"$3"*) echo "FAIL: $1 -> output HAS '$3'"; fail=1 ;; *) echo "ok: $1" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "status-test: jq required — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "status-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fix="$tmp/proj"; mkdir -p "$fix"; ( cd "$fix" && git init -q )
printf '{"kitVersion":"9.9.9","project":{"name":"fix"},"github":{"repo":"octo/fixture","owner":"octo","baseBranch":"main"}}' > "$fix/cckit.config.json"

# Stub gh: `issue list` returns $GH_ISSUES (a JSON array file) — or, when the call filters on
# `--label effort`, $GH_EFFORTS (the open efforts; [] when unset, i.e. "no issue carries the label").
# `api …/issues/<N>/dependencies/blocked_by` returns $GH_DEPS/<N>.json when present. Everything
# else returns [].
stub="$tmp/bin"; mkdir -p "$stub"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    case " $* " in
      *" --label effort "*) [ -z "${GH_EFFORTS_FAIL:-}" ] || exit 1
                            cat "${GH_EFFORTS:-/nonexistent}" 2>/dev/null || echo '[]' ;;
      *) cat "$GH_ISSUES" 2>/dev/null || echo '[]' ;;
    esac ;;
  "api repos/"*)
    n="${2%/dependencies/blocked_by}"; n="${n##*/}"
    cat "${GH_DEPS:-/nonexistent}/$n.json" 2>/dev/null || echo '[]' ;;
  *) echo "[]" ;;
esac
SH
chmod +x "$stub/gh"

run_status() {  # stdout+stderr of `status.sh` against the fixture with the stub gh
  ( cd "$fix" && KIT_CONFIG="$fix/cckit.config.json" PATH="$stub:$PATH" GH_ISSUES="$1" \
      bash "$ROOT/scripts/status.sh" 2>&1 )
}

# 3 open issues, one blocked ("Blocked by" in the body).
cat > "$tmp/issues3.json" <<'JSON'
[ {"number":10,"title":"first","body":"plain"},
  {"number":11,"title":"second","body":"Blocked by #10"},
  {"number":12,"title":"third","body":""} ]
JSON
out3="$(run_status "$tmp/issues3.json")"
has "counts open + blocked correctly" "$out3" "open issues: 3   blocked: 1"
no  "no integer-expression error"      "$out3" "integer expression"
no  "count is not the concatenated 1\\n0 bug" "$out3" "open issues: 1"

# 10 open issues -> the ">8 more" line must render (the integer test path that used to crash).
printf '[' > "$tmp/issues10.json"
for i in $(seq 1 10); do printf '%s{"number":%d,"title":"i%d","body":""}' "$([ "$i" -gt 1 ] && echo ,)" "$i" "$i"; done >> "$tmp/issues10.json"
printf ']' >> "$tmp/issues10.json"
out10="$(run_status "$tmp/issues10.json")"
has "counts 10 open" "$out10" "open issues: 10"
has "renders the '... and N more' line" "$out10" "and 2 more"
no  "no integer-expression error (10)" "$out10" "integer expression"

# empty board -> 0/0, still clean.
echo '[]' > "$tmp/issues0.json"
out0="$(run_status "$tmp/issues0.json")"
has "empty board counts 0/0" "$out0" "open issues: 0   blocked: 0"
no  "no integer-expression error (empty)" "$out0" "integer expression"

# ── next effort per flow (E241.4) ────────────────────────────────────────────────────────────────
# No open issue carries the `effort` label (the stub's default): the section is still there and
# says why it is empty, instead of being absent.
has "section is present with no efforts"   "$out3" "## Next effort per flow"
has "no efforts: states its own emptiness" "$out3" 'No open issue carries the `effort` label'
has "the section sits before the buckets"  "$(printf '%s\n' "$out3" | grep -E '^## ' | tr '\n' '|')" \
    "## Board|## Next effort per flow|## 1 · Local undone work|"
has "status names the cadence"             "$out3" 'Monday: `cckit plan`'
has "status names the Friday step"         "$out3" 'Friday: `cckit gc`'

# Two flows; core #11 is blocked_by the OPEN core #10, docs #20 is free.
mkdir -p "$tmp/deps"
cat > "$tmp/efforts.json" <<'JSON'
[ {"number":20,"title":"[Effort] 20 · [Docs] cadence page","labels":[{"name":"effort"},{"name":"flow:docs"},{"name":"ctx:S"}]},
  {"number":11,"title":"[Effort] 11 · [Core] second thing","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:L"}]},
  {"number":10,"title":"[Effort] 10 · [Core] first thing","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:M"}]} ]
JSON
echo '[{"number":10,"state":"open"}]' > "$tmp/deps/11.json"
oute="$(GH_EFFORTS="$tmp/efforts.json" GH_DEPS="$tmp/deps" run_status "$tmp/issues3.json")"
has "core row names the unblocked effort"   "$oute" "| core | **E10** — first thing | M | 1 |"
has "docs row names its effort"             "$oute" "| docs | **E20** — cadence page | S | 0 |"
no  "the blocked effort is never offered"   "$oute" "**E11**"
no  "a populated section is not 'empty'"    "$oute" "No open issue carries"
has "the board count is untouched by it"    "$oute" "open issues: 3   blocked: 1"

# Every effort in the flow blocked: the flow keeps its row and says nothing can start.
echo '[{"number":999,"state":"open"}]' > "$tmp/deps/10.json"
outb="$(GH_EFFORTS="$tmp/efforts.json" GH_DEPS="$tmp/deps" run_status "$tmp/issues3.json")"
has "a fully blocked flow says so"          "$outb" "| core | _none can start"
rm -f "$tmp/deps/10.json"

# The effort query fails: "could not read" must not read as "no efforts".
outf="$(GH_EFFORTS_FAIL=1 run_status "$tmp/issues3.json")"
has "unreadable efforts say so"             "$outf" "Could not read the open efforts"
no  "unreadable is not reported as empty"   "$outf" "No open issue carries"

# --llm: the same rows under ONE new key, next_efforts.
run_status_llm() {
  ( cd "$fix" && KIT_CONFIG="$fix/cckit.config.json" PATH="$stub:$PATH" GH_ISSUES="$tmp/issues3.json" \
      bash "$ROOT/scripts/status.sh" --llm 2>/dev/null )
}
jse="$(GH_EFFORTS="$tmp/efforts.json" GH_DEPS="$tmp/deps" run_status_llm)"
t "llm: next_efforts has one row per flow" "$(printf '%s' "$jse" | jq -r '.next_efforts | length')" "2"
t "llm: the core row"  "$(printf '%s' "$jse" | jq -c '.next_efforts[0]')" \
  '{"flow":"core","number":10,"ctx":"M","title":"first thing","waiting":1}'
t "llm: the docs row"  "$(printf '%s' "$jse" | jq -c '.next_efforts[1]')" \
  '{"flow":"docs","number":20,"ctx":"S","title":"cadence page","waiting":0}'
t "llm: no efforts is [] not null" "$(run_status_llm | jq -c '.next_efforts')" "[]"
t "llm: unreadable efforts is null" "$(GH_EFFORTS_FAIL=1 run_status_llm | jq -c '.next_efforts')" "null"
t "llm: the pre-existing keys are all still there" \
  "$(printf '%s' "$jse" | jq -r 'keys | join(",")')" \
  "ai_review_expected,cleanup,deps,local_undone,next_efforts,prs,prs_read,worktrees"

[ "$fail" -eq 0 ] && echo "ALL OK (status)" || echo "status: FAILURES"
exit "$fail"
