#!/usr/bin/env bash
# shellcheck shell=bash
# task-sync-test.sh — covers the dashboard layer of `cckit sync` (#383): the `--json` summary, the
# atomic `--write` cache, `--cached [TTL]`, one `--watch` iteration, the op.start/op.done events and
# `--plan`. Hermetic: a throwaway repo + a stubbed gh that counts its calls and fails on demand.
# Run: bash scripts/task-sync-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has(){ case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> output lacks '$3'"; fail=1 ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "task-sync-test: jq required — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "task-sync-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fix="$tmp/proj"; mkdir -p "$fix"; ( cd "$fix" && git init -q )
printf '%s' '{"kitVersion":"9.9.9","project":{"name":"fix"},"roles":["Tech Lead","Docs"],"github":{"repo":"octo/fixture","owner":"octo","baseBranch":"main","projectsV2":false}}' \
  > "$fix/cckit.config.json"
CACHE="$fix/.git/kit-sync-cache.json"
EVENTS="$fix/.git/kit-events.jsonl"
CALLS="$tmp/gh-calls"

OLD20="$(date -u -v-20d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '20 days ago' +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$tmp/issues.json" <<JSON
[ {"number":1,"title":"lead work","labels":[{"name":"role:tech-lead"},{"name":"priority:p1"}],"milestone":{"title":"v1"},"assignees":[],"updatedAt":"$NOW","body":"plain"},
  {"number":2,"title":"docs work","labels":[{"name":"role:docs"}],"milestone":null,"assignees":[],"updatedAt":"$OLD20","body":"Blocked by #1"},
  {"number":3,"title":"no role","labels":[],"milestone":null,"assignees":[],"updatedAt":"$NOW","body":""} ]
JSON
# Same five PRs board-view-test.sh orders: ready(risk asc, size asc) → draft → blocked.
cat > "$tmp/prs.json" <<'JSON'
[
 {"number":10,"title":"blocked one","labels":[{"name":"risk:low"},{"name":"size:S"},{"name":"blocked"}],"isDraft":false,"headRefName":"feat/10","reviewDecision":"APPROVED","mergeable":"MERGEABLE"},
 {"number":11,"title":"draft one","labels":[{"name":"risk:low"},{"name":"size:XS"}],"isDraft":true,"headRefName":"feat/11","reviewDecision":null,"mergeable":"MERGEABLE"},
 {"number":12,"title":"ready high risk","labels":[{"name":"risk:high"},{"name":"size:S"}],"isDraft":false,"headRefName":"claude/12","reviewDecision":"APPROVED","mergeable":"MERGEABLE"},
 {"number":13,"title":"ready low risk L","labels":[{"name":"risk:low"},{"name":"size:L"}],"isDraft":false,"headRefName":"feat/13","reviewDecision":"APPROVED","mergeable":"MERGEABLE"},
 {"number":14,"title":"ready low risk S","labels":[{"name":"risk:low"},{"name":"size:S"}],"isDraft":false,"headRefName":"feat/14","reviewDecision":"APPROVED","mergeable":"MERGEABLE"}
]
JSON

# Stub gh: every call is counted; GH_FAIL=1 fails every call, GH_FAIL_PR=1 only `pr list`.
# `issue list --label effort` is effort_plan's query (effort_open_rows parses the --json array).
stub="$tmp/bin"; mkdir -p "$stub"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
[ "${GH_FAIL:-0}" = 1 ] && { echo "gh: network down" >&2; exit 1; }
case "$1 $2" in
  "issue list")
    case " $* " in
      *" --label effort "*) echo '[{"number":42,"title":"[Effort] 42 · [Core] demo effort","labels":[{"name":"effort"},{"name":"flow:core"},{"name":"ctx:M"}]}]' ;;
      *) cat "$GH_ISSUES" ;;
    esac ;;
  "pr list") [ "${GH_FAIL_PR:-0}" = 1 ] && { echo "gh: pr list failed" >&2; exit 1; }; cat "$GH_PRS" ;;
  *) echo "" ;;
esac
SH
chmod +x "$stub/gh"

sync() {  # run task-sync.sh against the fixture; extra env via leading VAR=val words in "$ENVV"
  ( cd "$fix" && env KIT_CONFIG="$fix/cckit.config.json" PATH="$stub:$PATH" GH_CALLS="$CALLS" \
      GH_ISSUES="$tmp/issues.json" GH_PRS="$tmp/prs.json" CCKIT_OUTPUT=human ${ENVV:-} \
      bash "$ROOT/scripts/task-sync.sh" "$@" )
}
calls() { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi; }
sum()   { cksum < "$1"; }

# ── (1) --json: one JSON object — per role, merge queue, stale ──────────────────────────────────
ENVV=""; doc="$(sync --json 2>/dev/null)"
t "--json emits one JSON object" "$(printf '%s' "$doc" | jq -rs 'length, (.[0]|type)' | tr '\n' ' ')" "1 object "
t "--json names the repo" "$(printf '%s' "$doc" | jq -r '.repo')" "octo/fixture"
t "--json counts open issues" "$(printf '%s' "$doc" | jq -r '.open')" "3"
t "--json lists roles in config order" "$(printf '%s' "$doc" | jq -r '[.roles[].role]|join(",")')" "Tech Lead,Docs"
t "--json groups issues under their role" "$(printf '%s' "$doc" | jq -r '[.roles[]|(.issues|map(.number|tostring)|join("+"))]|join(",")')" "1,2"
t "--json puts a role-less issue in unassigned" "$(printf '%s' "$doc" | jq -c '[.unassigned[].number]')" "[3]"
t "--json carries priority + milestone" "$(printf '%s' "$doc" | jq -r '.roles[0].issues[0]|"\(.priority) \(.milestone)"')" "p1 v1"
t "--json lists blocked issues" "$(printf '%s' "$doc" | jq -c '.blocked')" "[2]"
t "--json stale section" "$(printf '%s' "$doc" | jq -c '.stale')" '{"days":14,"issues":[{"number":2,"days":20}]}'
t "--json notOnBoard is null with the board off" "$(printf '%s' "$doc" | jq -r '.notOnBoard')" "null"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/board-view.sh"
rendered="$(board_merge_queue "$(cat "$tmp/prs.json")" | grep -oE '#1[0-4]' | tr -d '#' | tr '\n' ' ')"
t "--json merge queue order matches board_merge_queue" "$(printf '%s' "$doc" | jq -r '[.mergeQueue[].number|tostring]|join(" ")') " "$rendered"
t "--json merge queue order is ready, draft, blocked" "$(printf '%s' "$doc" | jq -r '[.mergeQueue[].number|tostring]|join(" ")')" "14 13 12 11 10"
t "--json does not write the cache on its own" "$([ -f "$CACHE" ] && echo yes || echo no)" "no"
t "--json applies --role" "$(sync --json --role Docs 2>/dev/null | jq -r '([.roles[].role]|join(",")) + " " + (.unassigned|length|tostring)')" "Docs 0"

# ── (5) events: op.start + op.done for the sync ────────────────────────────────────────────────
t "kit-events.jsonl has an op.start for sync" "$(jq -rs '[.[]|select(.type=="op.start" and .op=="sync")]|length > 0' "$EVENTS" 2>/dev/null)" "true"
t "kit-events.jsonl has an op.done for sync"  "$(jq -rs '[.[]|select(.type=="op.done" and .op=="sync")]|length > 0' "$EVENTS" 2>/dev/null)" "true"
t "op.done records success" "$(jq -rs '[.[]|select(.type=="op.done" and .op=="sync")][0].payload.ok' "$EVENTS" 2>/dev/null)" "true"

# ── (2) --write: atomic cache; a failing fetch leaves it byte-identical ─────────────────────────
ENVV=""; sync --write >/dev/null 2>&1; rc=$?
t "--write exits 0" "$rc" "0"
t "--write creates <git-common-dir>/kit-sync-cache.json" "$([ -f "$CACHE" ] && echo yes || echo no)" "yes"
t "the cache is the --json document" "$(jq -r '.mergeQueue|length' "$CACHE" 2>/dev/null)" "5"
t "--write leaves no temp file behind" "$(find "$fix/.git" -maxdepth 1 -name 'kit-sync-cache.json.*' | wc -l | tr -d ' ')" "0"
before="$(sum "$CACHE")"
ENVV="GH_FAIL=1"; sync --write >/dev/null 2>&1; rc=$?
t "--write with a failing gh exits non-zero" "$([ "$rc" -ne 0 ] && echo nz || echo z)" "nz"
t "a failing fetch leaves the cache byte-identical" "$(sum "$CACHE")" "$before"
ENVV="GH_FAIL_PR=1"; sync --write >/dev/null 2>&1; rc=$?
t "a partial fetch (PR list down) exits non-zero" "$([ "$rc" -ne 0 ] && echo nz || echo z)" "nz"
t "a partial fetch leaves the cache byte-identical" "$(sum "$CACHE")" "$before"
t "a failed sync still emits op.done (ok:false)" "$(jq -rs '[.[]|select(.type=="op.done" and .op=="sync" and .payload.ok==false)]|length > 0' "$EVENTS")" "true"
ENVV=""; sync --write --role Docs >/dev/null 2>&1; rc=$?
t "--write refuses a filtered document" "$rc" "2"
t "the refusal leaves the cache byte-identical" "$(sum "$CACHE")" "$before"

# ── (3) --cached: zero gh calls inside the TTL, one refresh past it ─────────────────────────────
rm -f "$CALLS"
ENVV=""; out="$(sync --cached 600 2>/dev/null)"
t "--cached inside the TTL makes zero gh calls" "$(calls)" "0"
t "--cached serves the cache bytes" "$(printf '%s\n' "$out" | cksum)" "$before"
# Age the cache past the TTL by rewriting its timestamp (no sleep).
jq '.generatedEpoch = 1000' "$CACHE" > "$CACHE.aged" && mv "$CACHE.aged" "$CACHE"
out="$(sync --cached 600 2>/dev/null)"
t "--cached past the TTL refreshes (gh called)" "$([ "$(calls)" -gt 0 ] && echo yes || echo no)" "yes"
t "the refresh rewrote the cache" "$([ "$(jq -r '.generatedEpoch' "$CACHE")" -gt 1000 ] && echo yes || echo no)" "yes"
t "the refresh prints the fresh document" "$(printf '%s' "$out" | jq -r '.open')" "3"
n1="$(calls)"; sync --cached 600 >/dev/null 2>&1
t "the next --cached call is served from the cache again" "$(calls)" "$n1"
rm -f "$CALLS"; sync --cached >/dev/null 2>&1
t "--cached with no TTL uses the default and stays cached" "$(calls)" "0"

# ── (4) --watch: one iteration with a failing fetch keeps the last good cache ───────────────────
before="$(sum "$CACHE")"
ENVV="GH_FAIL=1 KIT_SYNC_WATCH_MAX=1"; werr="$(sync --watch 1 2>&1 >/dev/null)"; rc=$?
t "a failing watch iteration keeps the last good cache" "$(sum "$CACHE")" "$before"
has "the watch loop reports the failed refresh" "$werr" "kept the last good cache"
t "a watch that ends on a failed refresh exits non-zero" "$([ "$rc" -ne 0 ] && echo nz || echo z)" "nz"
jq '.generatedEpoch = 1000' "$CACHE" > "$CACHE.aged" && mv "$CACHE.aged" "$CACHE"
ENVV="KIT_SYNC_WATCH_MAX=2"; sync --watch 0 >/dev/null 2>&1; rc=$?
t "a healthy watch exits 0 at its iteration cap" "$rc" "0"
t "a healthy watch iteration refreshes the cache" "$([ "$(jq -r '.generatedEpoch' "$CACHE")" -gt 1000 ] && echo yes || echo no)" "yes"

# ── (6) --plan inlines `effort plan` ────────────────────────────────────────────────────────────
ENVV=""; pout="$(sync --plan 2>/dev/null)"
has "--plan output contains the effort plan header" "$pout" "kit effort plan"
has "--plan still prints the board" "$pout" "Merge Queue"
has "--plan lists the effort" "$pout" "demo effort"
has "--json --plan carries the plan text" "$(sync --json --plan 2>/dev/null | jq -r '.plan')" "kit effort plan"
t "--json without --plan has no plan key" "$(printf '%s' "$doc" | jq -r 'has("plan")')" "false"

# ── unchanged surfaces ─────────────────────────────────────────────────────────────────────────
has "human board still renders" "$(sync 2>/dev/null)" "## Board — octo/fixture"
t "--raw-json still returns the gh issue objects" "$(sync --raw-json 2>/dev/null | jq -r '.[0].labels[0].name')" "role:tech-lead"
has "--llm is still TOON" "$(sync --llm 2>/dev/null)" '[3]{number,title,priority,labels,milestone,assignees,blocked}:'
ENVV=""; sync --bogus >/dev/null 2>&1; t "an unknown flag still exits 1" "$?" "1"

[ "$fail" -eq 0 ] && echo "ALL OK (task-sync)" || echo "task-sync: FAILURES"
exit "$fail"
