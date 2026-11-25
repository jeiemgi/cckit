#!/usr/bin/env bash
# shellcheck shell=bash
# naming-verbs-test.sh — the naming rule at the verbs (E546.1), over the forge shim: each creating
# verb refuses a bad title before any forge write; `effort sub` titles [E<n>.<step>]; `effort retitle`
# is a dry run until --apply; `start E<n>.<step>` resolves the token. Hermetic, no network.
# Run: bash scripts/lib/naming-verbs-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/core/test-env.sh" && test_env_seal
LIB="$ROOT/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "naming-verbs-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log" GH_N="$tmp/n"; : > "$GH_LOG"; echo 49 > "$GH_N"
# shellcheck source=/dev/null
. "$LIB/forge/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export PATH="$tmp/bin:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github
export KIT_REPO="o/r" EFFORT_REPO="o/r" KIT_BASE_BRANCH="main" KIT_PROJECTS_V2="false"
unset KIT_CONFIG CLAUDE_CODE_REMOTE CCKIT_GH_TRANSPORT GH_FAIL_EP KIT_PR_TITLE_STYLE
# Effort 30 has two subs: #301 a legacy title, #302 already new. Effort 40 has two untitled-by-step subs.
export GH_FIXTURE="$tmp/fixture.sh"
cat > "$GH_FIXTURE" <<'SH'
case "$method $ep" in
  "GET repos/o/r/issues/30/sub_issues") out='[{"number":301,"state":"open","title":"[Effort 30] 1 · first step"},{"number":302,"state":"open","title":"[E30.2] second step"}]' ;;
  "GET repos/o/r/issues/40/sub_issues") out='[{"number":401,"state":"open","title":"plain one"},{"number":402,"state":"open","title":"plain two"}]' ;;
esac
SH
writes() { grep -cE '^(POST|PATCH|PUT|DELETE) ' "$GH_LOG" | tr -d ' '; }
fresh() { : > "$GH_LOG"; echo 49 > "$GH_N"; }

# shellcheck source=/dev/null
source "$LIB/core/effort.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$LIB/verbs/effort-ops.sh"

# ── effort new: a bad parent or sub name is refused before any write ─────────────────────────────
fresh
effort_new "refactor the wiring" "first sub" >/dev/null 2>"$tmp/err"; rc=$?
t  "effort new: a jargon name is refused (rc 1)" "$rc" "1"
t  "effort new: a refused name writes nothing"   "$(writes)" "0"
tc "$tmp/err" "jargon word 'refactor'"           "effort new: the reason is on stderr"
fresh
effort_new "demo effort" "a sub (with parens)" >/dev/null 2>"$tmp/err"; rc=$?
t  "effort new: a bad sub name is refused (rc 1)" "$rc" "1"
t  "effort new: a refused sub writes nothing"     "$(writes)" "0"

# ── effort sub ────────────────────────────────────────────────────────────────────────────────────
export GH_TITLE="[E30] demo effort" GH_LABELS='[{"name":"effort"},{"name":"role:backend"},{"name":"kind:task"},{"name":"priority:p2"}]'
fresh
child="$(effort_sub 30 "third step" 2>"$tmp/err")"; rc=$?
t  "effort sub: rc 0"                       "$rc" "0"
t  "effort sub: echoes the child number"    "$child" "50"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"\[E30\.3\] third step"' "effort sub: titles [E<n>.<count+1>] <name>"
tc "$GH_LOG" '^POST repos/o/r/issues .*"labels":\["kind:task","priority:p2","role:backend"\]' "effort sub: inherits kind, priority and role"
tc "$GH_LOG" '^POST repos/o/r/issues/30/sub_issues ' "effort sub: links the child as a native sub-issue"
fresh
effort_sub 30 "one two three four five six seven" >/dev/null 2>"$tmp/err"; rc=$?
t  "effort sub: a long name is refused (rc 1)" "$rc" "1"
t  "effort sub: a refused name writes nothing" "$(writes)" "0"
export GH_LABELS='[{"name":"kind:task"}]'
fresh
effort_sub 30 "third step" >/dev/null 2>"$tmp/err"; rc=$?
t  "effort sub: a non-effort parent is refused" "$rc" "1"
t  "effort sub: nothing written for a non-effort" "$(writes)" "0"

# ── effort retitle ────────────────────────────────────────────────────────────────────────────────
export GH_TITLE="[Effort] 30 · [Core] demo effort"
fresh
out="$(effort_retitle 30 2>&1)"; rc=$?
t  "retitle dry run: rc 0"               "$rc" "0"
t  "retitle dry run: writes nothing"     "$(writes)" "0"
case "$out" in *"-> [E30] demo effort"*"-> [E30.1] first step"*"dry run: 2 title(s)"*) echo "ok: retitle dry run lists the parent and the legacy sub" ;;
  *) echo "FAIL: retitle dry run output: $out"; fail=1 ;; esac
case "$out" in *"#302"*) echo "FAIL: retitle lists a title already in the new form"; fail=1 ;; *) echo "ok: retitle skips a title already in the new form" ;; esac
fresh
effort_retitle 30 --apply >/dev/null 2>&1; rc=$?
t  "retitle --apply: rc 0" "$rc" "0"
tc "$GH_LOG" '^PATCH repos/o/r/issues/30 \{"title":"\[E30\] demo effort"\}$'   "retitle --apply renames the parent"
tc "$GH_LOG" '^PATCH repos/o/r/issues/301 \{"title":"\[E30\.1\] first step"\}$' "retitle --apply renames the legacy sub"
t  "retitle --apply: two writes"         "$(writes)" "2"

# ── start: the token resolves ─────────────────────────────────────────────────────────────────────
(
  # shellcheck source=/dev/null
  . "$LIB/core/worktree-start.sh" >/dev/null 2>&1
  export WT_START_REPO="o/r"
  r=0
  [ "$(_wt_resolve_token E545 2>/dev/null)" = 545 ]   || { echo "FAIL: E545 -> 545"; r=1; }
  [ "$(_wt_resolve_token E30.2 2>/dev/null)" = 302 ]  || { echo "FAIL: E30.2 by title -> 302"; r=1; }
  [ "$(_wt_resolve_token E30.1 2>/dev/null)" = 301 ]  || { echo "FAIL: E30.1 by legacy title -> 301"; r=1; }
  [ "$(_wt_resolve_token E40.2 2>/dev/null)" = 402 ]  || { echo "FAIL: E40.2 by position -> 402"; r=1; }
  _wt_resolve_token E40.5 >/dev/null 2>&1             && { echo "FAIL: E40.5 should not resolve"; r=1; }
  _wt_resolve_token E4x >/dev/null 2>&1               && { echo "FAIL: E4x is not a token"; r=1; }
  [ "$r" = 0 ] && echo "ok: start resolves E<n>, E<n>.<step> by title, legacy title and position"
  exit "$r"
) || fail=1

# ── cckit new: a bad standalone title is refused before any write ─────────────────────────────────
(
  cd "$tmp" || exit 1
  # shellcheck source=/dev/null
  . "$LIB/verbs/kit-task-ops.sh"
  r=0
  fresh
  kto_task_new "[E12] an effort title" backend task p2 "" "" "" x >/dev/null 2>&1 && { echo "FAIL: new accepted a prefixed title"; r=1; }
  [ "$(writes)" = 0 ] || { echo "FAIL: new wrote to the forge on a bad title"; r=1; }
  fresh
  kto_task_new "one two three four five six seven" backend task p2 "" "" "" x >/dev/null 2>&1 && { echo "FAIL: new accepted 7 words"; r=1; }
  [ "$(writes)" = 0 ] || { echo "FAIL: new wrote on a long title"; r=1; }
  [ "$r" = 0 ] && echo "ok: cckit new refuses a bad title and writes nothing"
  # The PR title carries the trailing token.
  [ "$(kto_pr_title "[E30.2] second step" "fix the thing" "kind:fix" 302)" = "fix: second step [E30.2]" ] \
    || { echo "FAIL: kto_pr_title sub token: $(kto_pr_title "[E30.2] second step" "fix the thing" "kind:fix" 302)"; r=1; }
  [ "$(kto_pr_title "Fix the thing" "fix the thing" "kind:fix" 42)" = "fix: Fix the thing [#42]" ] \
    || { echo "FAIL: kto_pr_title standalone token: $(kto_pr_title "Fix the thing" "fix the thing" "kind:fix" 42)"; r=1; }
  [ "$r" = 0 ] && echo "ok: cckit pr titles end in the work's token"
  exit "$r"
) || fail=1

[ "$fail" -eq 0 ] && echo "ALL OK"
exit "$fail"
