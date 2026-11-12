#!/usr/bin/env bash
# kto-task-new-test.sh — kto_task_new against a stubbed gh (#387): a label the repo does not have
# is dropped with a warning and the issue is still created; with every label present the create
# call is unchanged; a failed create returns non-zero and prints no URL.
# Run: bash scripts/lib/kto-task-new-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
tn() { if grep -qE -- "$2" "$1"; then echo "FAIL: $3 (/$2/ in $1)"; fail=1; else echo "ok: $3"; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"
mkdir -p "$tmp/bin"
# GH_HAVE: the repo's labels, comma-separated. GH_LIST_FAIL=1: `gh label list` fails.
# GH_CREATE_FAIL=1: `gh issue create` fails. Like real gh, a create naming a label the repo does
# not have fails with "could not add label".
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "label list")
    [ -n "${GH_LIST_FAIL:-}" ] && { echo "gh: HTTP 403" >&2; exit 1; }
    printf '%s\n' "$GH_HAVE" | tr ',' '\n' ;;
  "issue create")
    [ -n "${GH_CREATE_FAIL:-}" ] && { echo "gh: HTTP 500" >&2; exit 1; }
    want=""; while [ $# -gt 0 ]; do [ "$1" = "--label" ] && want="${2:-}"; shift; done
    for l in $(printf '%s' "$want" | tr ',' ' '); do
      case ",$(printf '%s' "$GH_HAVE" | tr 'A-Z' 'a-z')," in *",$l,"*) ;; *) echo "could not add label: '$l' not found" >&2; exit 1 ;; esac
    done
    echo "https://github.com/o/r/issues/50" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" KIT_REPO="o/r" KIT_BASE_BRANCH="main" KIT_PROJECTS_V2="false"
unset KIT_CONFIG CLAUDE_CODE_REMOTE CCKIT_GH_TRANSPORT GH_LIST_FAIL GH_CREATE_FAIL
cd "$tmp" || exit 1

# shellcheck source=/dev/null
. "$LIB/kit-task-ops.sh"

# ── a missing label is a warning, not an abort ────────────────────────────────────────────────────
export GH_HAVE="kind:task,priority:p2,role:backend"
: > "$GH_LOG"
kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "missing kind label: rc 0"                        "$rc" "0"
tc "$tmp/out" '^✓ https://github.com/o/r/issues/50$' "missing kind label: prints the issue URL"
t  "missing kind label: echoes the number"           "$(tail -1 "$tmp/out")" "50"
tc "$tmp/err" "kind:feat"                            "missing kind label: the warning names kind:feat"
tc "$GH_LOG" '^issue create .*--label priority:p2,role:backend( |$)' "missing kind label: only existing labels are sent"
tn "$GH_LOG" '^issue create .*kind:feat'             "missing kind label: kind:feat is not sent"
tn "$GH_LOG" '^label create'                         "missing kind label: no label is created"

# Label names are case-insensitive on GitHub.
export GH_HAVE="Kind:Feat,priority:p2,role:backend"
: > "$GH_LOG"
kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "case-insensitive match: rc 0"                    "$rc" "0"
t  "case-insensitive match: no warning"              "$(grep -c 'kind:feat' "$tmp/err")" "0"
tc "$GH_LOG" '^issue create .*--label kind:feat,priority:p2,role:backend ' "case-insensitive match: the label is sent"

# ── every label missing: the issue is created with no --label at all ──────────────────────────────
export GH_HAVE="bug"
: > "$GH_LOG"
kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "no label exists: rc 0"                           "$rc" "0"
tc "$tmp/out" '^✓ https://github.com/o/r/issues/50$' "no label exists: prints the issue URL"
tn "$GH_LOG" '^issue create .*--label'               "no label exists: no --label flag"
t  "no label exists: three labels warned"            "$(grep -cE 'kind:feat|priority:p2|role:backend' "$tmp/err")" "3"

# ── all labels present: the create call is unchanged ──────────────────────────────────────────────
export GH_HAVE="kind:feat,priority:p2,role:backend"
: > "$GH_LOG"
kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "all labels present: rc 0"                        "$rc" "0"
tc "$GH_LOG" '^issue create --repo o/r --title Test --body .*--label kind:feat,priority:p2,role:backend --assignee @me$' "all labels present: the create call is unchanged"
t  "all labels present: no warning"                  "$(wc -c < "$tmp/err" | tr -d ' ')" "0"

# ── the label list cannot be read: send every label, as before ────────────────────────────────────
: > "$GH_LOG"
GH_LIST_FAIL=1 kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "unreadable label list: rc 0"                     "$rc" "0"
tc "$GH_LOG" '^issue create .*--label kind:feat,priority:p2,role:backend ' "unreadable label list: every label is sent"

# ── the create itself fails: non-zero, no URL ─────────────────────────────────────────────────────
: > "$GH_LOG"
GH_CREATE_FAIL=1 kto_task_new "Test" backend feat p2 "" "" "" x >"$tmp/out" 2>"$tmp/err"; rc=$?
t  "create fails: rc non-zero"                       "$([ "$rc" -ne 0 ] && echo nonzero)" "nonzero"
t  "create fails: prints nothing on stdout"          "$(wc -c < "$tmp/out" | tr -d ' ')" "0"

[ "$fail" -eq 0 ] && echo "kto-task-new: all passed" || echo "kto-task-new: FAILURES"
exit "$fail"
