#!/usr/bin/env bash
# shellcheck shell=bash
# effort-close-subs-test.sh — `cckit effort close` closes only the finished subs (#565, decision 52).
# Hermetic: the forge shim (test-forge-shim.sh) answers like the REST API and logs `METHOD path {json}`;
# a throwaway git repo with a bare remote. Run:  bash scripts/lib/effort-close-subs-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
command -v jq  >/dev/null 2>&1 || { echo "effort-close-subs-test: jq required"  >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "effort-close-subs-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; export GH_N="$tmp/n"; : > "$GH_LOG"; printf '0' > "$GH_N"
stub="$tmp/bin"
# shellcheck source=/dev/null
. "$LIB/test-forge-shim.sh"; forge_shim_install "$stub"
export PATH="$stub:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github
export GH_TITLE="[E66] demo effort" GH_LABELS='[{"name":"kind:task"}]'
export GH_HEAD="effort/66-demo" GH_BASE="main" GH_MERGEABLE=true
export GH_BODY='## Goal\nship it\n\n## Spec\n- it ships'
# Effort #66 has four subs: 601 already closed, 602 open but delivered by a `Closes #602` commit,
# 603 open but delivered by a commit tagged with its step id [E66.3], 604 open and delivered by
# nothing — the one that must stay open.
export GH_FIXTURE="$tmp/fixture.sh"
cat > "$GH_FIXTURE" <<'SH'
case "$method $ep" in
  "GET repos/o/r/issues/66/sub_issues")
    out='[{"number":601,"state":"closed","title":"[E66.1] first"},
          {"number":602,"state":"open","title":"[E66.2] second"},
          {"number":603,"state":"open","title":"[E66.3] third"},
          {"number":604,"state":"open","title":"[E66.4] release later"}]' ;;
esac
SH
export KIT_REPO="o/r" EFFORT_REPO="o/r" KIT_BASE_BRANCH="main" KIT_WT_INSTALL=0
# shellcheck source=/dev/null
source "$LIB/effort.sh" 2>/dev/null
# shellcheck source=/dev/null
source "$LIB/effort-ops.sh"

# ── the pure partition ───────────────────────────────────────────────────────────────────────────
refs="$(printf '#602\nE66.3\n')"
part="$(printf '%s\n' "601|closed|[E66.1] a" "602|open|[E66.2] b" "603|OPEN|[E66.3] c" "604|open|[E66.4] d" "605|open|[E67.3] e" \
  | _eo_partition_subs 66 "$refs" | tr '\n' ' ')"
t "partition: closed, #-delivered and step-delivered are done; the rest stay open" "$part" \
  "done|601|closed done|602|open done|603|open open|604|[E66.4] d open|605|[E67.3] e "
t "partition: no subs → no output" "$(printf '' | _eo_partition_subs 66 "$refs")" ""

# ── --help answers without resolving an effort (#578) ─────────────────────────────────────────────
: > "$GH_LOG"
h="$(effort_close --help 2>&1)"; rc=$?
t "effort close --help exits 0" "$rc" "0"
case "$h" in "cckit effort close"*) echo "ok: effort close --help prints the usage" ;; *) echo "FAIL: effort close --help: $h"; fail=1 ;; esac
h="$(effort_pr --help 2>&1)"; rc=$?
t "effort pr --help exits 0" "$rc" "0"
case "$h" in "cckit effort pr"*) echo "ok: effort pr --help prints the usage" ;; *) echo "FAIL: effort pr --help: $h"; fail=1 ;; esac
t "--help made no forge call" "$(grep -c . "$GH_LOG")" "0"

# ── effort close with one unfinished sub ─────────────────────────────────────────────────────────
( cd "$tmp" && git init -q --bare remote.git )
( cd "$tmp" && git clone -q remote.git work 2>/dev/null \
  && cd work && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init \
  && git push -q origin HEAD:main )
cd "$tmp/work" || exit 1
effort_start 66 demo >/dev/null 2>&1
cd "$tmp/work/.claude/worktrees/effort+66-demo" || { echo "FAIL: no effort worktree"; exit 1; }
c() { git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"; }
c "$(printf 'feat: second step [E66.2]\n\nCloses #602')"
c "feat: third step [E66.3]"
c "docs: mention #604 is follow-up work (#602)"   # names #604, but its last #ref is #602

: > "$GH_LOG"
out="$(effort_close 66 2>&1)"; rc=$?
cd "$tmp/work" || exit 1
t  "close succeeds with an open sub (rc 0)" "$rc" "0"
tc "$GH_LOG" '^PUT repos/o/r/pulls/[0-9]+/merge ' "close squash-merges the effort PR"
tc "$GH_LOG" '^PATCH repos/o/r/issues/66 \{"state":"closed","state_reason":"completed"\}$' "close closes the parent"
tc "$GH_LOG" '^PATCH repos/o/r/issues/602 \{"state":"closed","state_reason":"completed"\}$' "close closes the sub a commit closes"
tc "$GH_LOG" '^PATCH repos/o/r/issues/603 \{"state":"closed","state_reason":"completed"\}$' "close closes the sub a step tag delivers"
t  "close does not re-close the already-closed sub" "$(grep -c '^PATCH repos/o/r/issues/601 ' "$GH_LOG")" "0"
t  "close leaves the unfinished sub open (no write to #604)" "$(grep -cE '^(PATCH|POST|PUT|DELETE) repos/o/r/issues/604' "$GH_LOG")" "0"
t  "close detaches nothing (no DELETE of any kind)" "$(grep -c '^DELETE ' "$GH_LOG")" "0"
tc "$GH_LOG" '^POST repos/o/r/issues/66/comments .*Finished sub-issues: #601, #602, #603' "the close comment lists the finished subs"
tc "$GH_LOG" '^POST repos/o/r/issues/66/comments .*Left open, still linked.*- #604 \[E66\.4\] release later' "the close comment lists the open sub"
t  "the comment is posted before the parent closes" \
   "$(grep -nE '^POST repos/o/r/issues/66/comments |^PATCH repos/o/r/issues/66 ' "$GH_LOG" | sed -E 's/^[0-9]+:(POST|PATCH).*/\1/' | tr '\n' ' ')" "POST PATCH "
case "$out" in *"left open: sub #604"*) echo "ok: the output flags the open sub as it closes" ;; *) echo "FAIL: no left-open line: $out"; fail=1 ;; esac
case "$out" in *"closed with unfinished sub-issues still open"*"#604"*) echo "ok: the report ends with the open sub" ;; *) echo "FAIL: no closing report of the open sub: $out"; fail=1 ;; esac
t  "no gh subcommand ran" "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"

[ "$fail" = 0 ] && echo "ALL OK (effort-close-subs)" || { echo "effort-close-subs: FAILURES"; exit 1; }
