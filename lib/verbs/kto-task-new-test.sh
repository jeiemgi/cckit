#!/usr/bin/env bash
# kto-task-new-test.sh — kto_task_new over the forge shim (#387, E537): a label the repo does not have
# is dropped with a warning and the issue is still created; with every label present the POST
# repos/o/r/issues body is unchanged; a failed create returns non-zero and prints no URL.
# Run: bash lib/verbs/kto-task-new-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
tn() { if grep -qE -- "$2" "$1"; then echo "FAIL: $3 (/$2/ in $1)"; fail=1; else echo "ok: $3"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"
# shellcheck source=/dev/null
. "$LIB/../forge/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export PATH="$tmp/bin:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github
export KIT_REPO="o/r" KIT_BASE_BRANCH="main" KIT_PROJECTS_V2="false"
export GH_N="$tmp/n"
unset KIT_CONFIG CLAUDE_CODE_REMOTE CCKIT_GH_TRANSPORT GH_FAIL_EP
cd "$tmp" || exit 1
# have <names…> — the repo's label list (GH_REPO_LABELS), as GET repos/o/r/labels answers it.
# fresh — an empty request log, and the next created issue is #50.
fresh() { : > "$GH_LOG"; echo 49 > "$GH_N"; }
have() { GH_REPO_LABELS="$(printf '%s\n' "$@" | jq -R . | jq -sc 'map({name:.})')"; export GH_REPO_LABELS; }

# shellcheck source=/dev/null
. "$LIB/kit-task-ops.sh"

# ── a missing label is a warning, not an abort ────────────────────────────────────────────────────
have kind:task priority:p2 role:backend
fresh
kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "missing kind label: rc 0"                        "$rc" "0"
tc "$tmp/out" '^✓ https://github.com/o/r/issues/50$' "missing kind label: prints the issue URL"
t  "missing kind label: echoes the number"           "$(tail -1 "$tmp/out")" "50"
tc "$tmp/err" "kind:feat"                            "missing kind label: the warning names kind:feat"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"Test","body":"x","labels":\["priority:p2","role:backend"\]\}$' "missing kind label: only existing labels are sent"
tn "$GH_LOG" '^POST repos/o/r/issues .*kind:feat'    "missing kind label: kind:feat is not sent"
tn "$GH_LOG" '^POST repos/o/r/labels'                "missing kind label: no label is created"
tc "$GH_LOG" '^POST repos/o/r/issues/50/assignees \{"assignees":\["me"\]\}$' "missing kind label: the author is assigned"

# Label names are case-insensitive on GitHub.
have Kind:Feat priority:p2 role:backend
fresh
kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "case-insensitive match: rc 0"                    "$rc" "0"
t  "case-insensitive match: no warning"              "$(grep -c 'kind:feat' "$tmp/err")" "0"
tc "$GH_LOG" '^POST repos/o/r/issues .*"labels":\["kind:feat","priority:p2","role:backend"\]' "case-insensitive match: the label is sent"

# ── every label missing: the issue is created with no labels field at all ──────────────────────────────
have bug
fresh
kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "no label exists: rc 0"                           "$rc" "0"
tc "$tmp/out" '^✓ https://github.com/o/r/issues/50$' "no label exists: prints the issue URL"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"Test","body":"x"\}$' "no label exists: no labels field"
t  "no label exists: three labels warned"            "$(grep -cE 'kind:feat|priority:p2|role:backend' "$tmp/err")" "3"

# ── all labels present: the create body is unchanged ──────────────────────────────────────────────
have kind:feat priority:p2 role:backend
fresh
kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "all labels present: rc 0"                        "$rc" "0"
tc "$GH_LOG" '^POST repos/o/r/issues \{"title":"Test","body":"x","labels":\["kind:feat","priority:p2","role:backend"\]\}$' "all labels present: the create body is unchanged"
tc "$GH_LOG" '^POST repos/o/r/issues/50/assignees \{"assignees":\["me"\]\}$' "all labels present: the author is assigned"
t  "all labels present: no warning"                  "$(wc -c < "$tmp/err" | tr -d ' ')" "0"

# ── the label list cannot be read: send every label, as before ────────────────────────────────────
fresh
GH_FAIL_EP="repos/o/r/labels" kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "unreadable label list: rc 0"                     "$rc" "0"
tc "$GH_LOG" '^POST repos/o/r/issues .*"labels":\["kind:feat","priority:p2","role:backend"\]' "unreadable label list: every label is sent"

# ── the create itself fails: non-zero, no URL ─────────────────────────────────────────────────────
fresh
GH_FAIL_EP="repos/o/r/issues" kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "create fails: rc non-zero"                       "$([ "$rc" -ne 0 ] && echo nonzero)" "nonzero"
t  "create fails: prints nothing on stdout"          "$(wc -c < "$tmp/out" | tr -d ' ')" "0"
t  "no gh subcommand ran"                            "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"

# ── the board Status (E546.2): no milestone -> Backlog when the board has it, else Todo ──────────────
have kind:feat priority:p2 role:backend
export KIT_PROJECTS_V2="true"
load_project_ids() { STATUS_FIELD_ID="SF"; STATUS_OPT_TODO="OPT_TODO"; return 0; }
project_add_item() { echo "ITEM"; }
project_set_single_select() { echo "set $1 $2 $3" >> "$tmp/board"; }
: > "$tmp/board"; fresh
STATUS_OPT_BACKLOG="OPT_BACKLOG" kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"
tc "$tmp/board" '^set ITEM SF OPT_BACKLOG$' "no milestone, a Backlog option: Status is Backlog"
tn "$tmp/board" 'OPT_TODO'                  "no milestone, a Backlog option: Status is not Todo"
: > "$tmp/board"; fresh
STATUS_OPT_BACKLOG="OPT_BACKLOG" kto_task_new "Test" backend feat p2 "M1" "" "" x >"$tmp/out" 2>"$tmp/err"
tc "$tmp/board" '^set ITEM SF OPT_TODO$'    "a milestone named: Status is Todo"
: > "$tmp/board"; fresh
kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"
tc "$tmp/board" '^set ITEM SF OPT_TODO$'    "no Backlog option on the board: Status stays Todo"
export KIT_PROJECTS_V2="false"

# ── an issue that cites an effort carries a relation to it (E632.4) ──────────────────────────────────
have kind:feat priority:p2 role:backend
creates() { grep -c '^POST repos/o/r/issues ' "$GH_LOG" | tr -d ' '; }
fresh; unset KIT_FORCE
kto_task_new "Test" backend feat p2 "" "" "" "Part of [E632.4]." >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "cites [E632] with no relation: rc non-zero"      "$([ "$rc" -ne 0 ] && echo nonzero)" "nonzero"
t  "cites [E632] with no relation: no create call"   "$(creates)" "0"
tc "$tmp/err" 'cites \[E632\] but carries no relation to #632' "cites [E632] with no relation: the refusal names the token"
tc "$tmp/err" -- '--force'                           "cites [E632] with no relation: the refusal names --force"
fresh
KIT_FORCE=1 kto_task_new "Test" backend feat p2 "" "" "" "Part of [E632.4]." >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "cites [E632], KIT_FORCE=1: rc 0"                 "$rc" "0"
t  "cites [E632], KIT_FORCE=1: the issue is created" "$(creates)" "1"
fresh
kto_task_new "Test" backend feat p2 "" "" "" "Part of [E632].

## Relations
- Depends on #632" >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "cites [E632] with Depends on #632: rc 0"         "$rc" "0"
t  "cites [E632] with Depends on #632: created"      "$(creates)" "1"
fresh
kto_task_new "Test" backend feat p2 "" "" "#632" "Part of [E632]." >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "cites [E632] with --blocked-by #632: rc 0"       "$rc" "0"
fresh
kto_task_new "Test" backend feat p2 "" "" "" "A body with no effort token." >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "no effort token: rc 0"                           "$rc" "0"
t  "no effort token: created"                        "$(creates)" "1"

[ "$fail" -eq 0 ] && echo "kto-task-new: all passed" || echo "kto-task-new: FAILURES"
exit "$fail"
