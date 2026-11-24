#!/usr/bin/env bash
# shellcheck shell=bash
# status-test.sh — regression for #142: `cckit status` board counters must be clean integers and
# never throw "integer expression expected". The bug: status fed `task-sync --llm` (TOON, not JSON)
# into `jq 'length'`, so the count became a concatenated value like "1\n0" that broke `[ … -gt 8 ]`.
# Hermetic: a fixture repo + the forge shim (scripts/lib/test-forge-shim.sh) answering a known issue
# list over REST. Run: bash scripts/status-test.sh
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

# The shim's fixture: the open issue list of any octo/* repo answers $GH_ISSUES (a JSON array file)
# — or, when the query filters on `labels=effort`, $GH_EFFORTS (the open efforts; [] when unset, i.e.
# "no issue carries the label"; GH_EFFORTS_FAIL=1 makes that read an HTTP 500). `…/issues/<N>/
# dependencies/blocked_by` answers $GH_DEPS/<N>.json when present. The PR list is empty.
stub="$tmp/bin"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-forge-shim.sh"; forge_shim_install "$stub"
export GH_FIXTURE="$tmp/fixture.sh" GH_TOKEN=test-token CCKIT_FORGE=github
cat > "$GH_FIXTURE" <<'SH'
case "$method $ep" in
  "GET repos/octo/"*"/issues")
    case "$path" in
      *labels=effort*) [ -z "${GH_EFFORTS_FAIL:-}" ] || code=500
                       out="$(cat "${GH_EFFORTS:-/nonexistent}" 2>/dev/null || echo '[]')" ;;
      *) out="$(cat "$GH_ISSUES" 2>/dev/null || echo '[]')" ;;
    esac ;;
  "GET repos/octo/"*"/issues/"*"/dependencies/blocked_by")
    n="${ep%/dependencies/blocked_by}"; n="${n##*/}"
    out="$(cat "${GH_DEPS:-/nonexistent}/$n.json" 2>/dev/null || echo '[]')" ;;
  "GET repos/octo/"*"/pulls") out='[]' ;;
esac
SH

run_status() {  # stdout+stderr of `status.sh` against the fixture over the shim
  ( cd "$fix" && KIT_CONFIG="$fix/cckit.config.json" PATH="$stub:$PATH" GH_ISSUES="$1" GH_LOG="$tmp/status.log" \
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
has "the board is one REST read of the open issues" "$(cat "$tmp/status.log")" "GET repos/octo/fixture/issues?state=open&per_page=100 "
t   "status ran no gh subcommand"      "$(grep -c '^GH-SUBCOMMAND' "$tmp/status.log")" "0"

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
has "status names the cadence"             "$out3" 'Monday: `cckit effort plan --issues`'
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

# No forge configured: the section says it could not read, never "no efforts", and nothing is requested.
: > "$tmp/status.log"
outn="$(CCKIT_FORGE=none run_status "$tmp/issues3.json")"
has "no forge: unreadable efforts say so"   "$outn" "Could not read the open efforts"
no  "no forge: not reported as empty"       "$outn" "No open issue carries"
t   "no forge: no request was made"         "$(wc -l < "$tmp/status.log" | tr -d ' ')" "0"

# --llm: the same rows under ONE new key, next_efforts.
run_status_llm() {
  ( cd "$fix" && KIT_CONFIG="$fix/cckit.config.json" PATH="$stub:$PATH" GH_ISSUES="$tmp/issues3.json" GH_LOG="$tmp/status.log" \
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
  "ai_review_expected,cleanup,deps,instruction_budget,light_tasks,local_undone,next_efforts,prs,prs_read,worktrees"

# ── light tasks (#487) ──────────────────────────────────────────────────────────────────────────
# A project with no light task: no section, and `light_tasks` is null.
no "no light task: no section" "$(run_status "$tmp/empty.json")" "## Light tasks"
t  "no light task: llm is null" "$(run_status_llm | jq -c '.light_tasks')" "null"

# Three tasks waiting for review, two not started, one only in this checkout. The states come from
# git alone: a `light/<id>-…` branch whose copy says done is `review`; a file on the base branch is
# `todo`; an untracked file is `draft`.
lt="$tmp/light"; mkdir -p "$lt/tasks"; ( cd "$lt" && git init -q && git symbolic-ref HEAD refs/heads/main )
printf '{"kitVersion":"9.9.9","project":{"name":"lt"},"github":{"repo":"octo/light","owner":"octo","baseBranch":"main"},"tasks":{"default":"light"}}' > "$lt/cckit.config.json"
task_file() { printf 'id: %s\ntitle: %s\nstatus: %s\npriority: p2\nkind: post\ncreated: 2026-11-13\n' "$1" "$2" "$3" > "$lt/tasks/$1.md"; }
for i in ta01 ta02 ta03 tb01 tb02; do task_file "$i" "Piece $i" todo; done
( cd "$lt" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m base
  for i in ta01 ta02 ta03; do
    git checkout -q -b "light/$i-piece" main
    sed 's/^status: todo/status: done/' "tasks/$i.md" > t.tmp && mv t.tmp "tasks/$i.md"
    git -c user.name=t -c user.email=t@t commit -q -am "finish $i"
  done
  git checkout -q main )
task_file tc01 "Local only" todo
: > "$tmp/gh.log"
lt_status() { ( cd "$lt" && KIT_CONFIG="$lt/cckit.config.json" PATH="$stub:$PATH" GH_LOG="$tmp/gh.log" GH_ISSUES="$tmp/empty.json" bash "$ROOT/scripts/status.sh" "$@" 2>&1 ); }
out_lt="$(lt_status)"
has "light tasks: the section is there" "$out_lt" "## Light tasks"
has "light tasks: counts by state" "$out_lt" "review: 3   doing: 0   todo: 2   draft: 1   shared: 0   done: 0"
has "light tasks: a review row names its branch" "$out_lt" '| `ta01` | **review** | Piece ta01 | waiting for review: its pull request is open from light/ta01-piece |'
has "light tasks: a draft row says what to do" "$out_lt" '| `tc01` | **draft** | Local only | only in this checkout; start it (cckit task start tc01)'
no  "light tasks: a todo task is counted, not listed" "$out_lt" '| `tb01` |'
has "light tasks: the board line is still printed" "$out_lt" "open issues: 0   blocked: 0"
js_lt="$(lt_status --llm 2>/dev/null)"
t "light tasks llm: counts" "$(printf '%s' "$js_lt" | jq -c '.light_tasks.counts')" \
  '{"draft":1,"todo":2,"shared":0,"doing":0,"review":3,"done":0,"dropped":0}'
t "light tasks llm: attention rows, review first" "$(printf '%s' "$js_lt" | jq -r '[.light_tasks.attention[] | .id + ":" + .state] | join(" ")')" \
  "ta01:review ta02:review ta03:review tc01:draft"
# No GitHub call is made FOR the tasks: every forge request of the run is one the other sections make.
# (the repo is octo/light, so its REST path carries `light/`; the task ids and branches must not)
t "light tasks: no forge request names a task" "$(grep -cE 'light/t[abc]0|/tasks|ta0|tb0|tc0' "$tmp/gh.log" | tr -d ' ')" "0"
calls_with="$(grep -c . "$tmp/gh.log" | tr -d ' ')"
rm -rf "$lt/tasks"; ( cd "$lt" && git checkout -q -- . 2>/dev/null; rm -rf tasks; git branch -q -D light/ta01-piece light/ta02-piece light/ta03-piece; git rm -q -r tasks; git -c user.name=t -c user.email=t@t commit -q -m "no tasks" )
: > "$tmp/gh.log"; lt_status >/dev/null; lt_status --llm >/dev/null 2>&1
t "light tasks: the same number of forge requests with and without tasks" "$(grep -c . "$tmp/gh.log" | tr -d ' ')" "$calls_with"

[ "$fail" -eq 0 ] && echo "ALL OK (status)" || echo "status: FAILURES"
exit "$fail"
