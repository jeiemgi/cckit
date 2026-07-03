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

# Stub gh: `issue list` returns $GH_ISSUES (a JSON array file); everything else returns [].
stub="$tmp/bin"; mkdir -p "$stub"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list") cat "$GH_ISSUES" 2>/dev/null || echo '[]' ;;
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

[ "$fail" -eq 0 ] && echo "ALL OK (status)" || echo "status: FAILURES"
exit "$fail"
