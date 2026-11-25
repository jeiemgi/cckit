#!/usr/bin/env bash
# kto-task-close-test.sh — `cckit close` closes with a reason from the close-reason set, maps it to
# GitHub's state_reason, still posts the summary and still sets the board to Done (#377).
# Hermetic: the forge shim (REST over a curl stand-in) and stubbed board helpers. Run: bash scripts/lib/kto-task-close-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$LIB/../.." && pwd)"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "kto-task-close-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GH_LOG="$tmp/gh.log" GH_CLOSED=""
# shellcheck source=/dev/null
. "$LIB/../../lib/forge/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export PATH="$tmp/bin:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github
export KIT_REPO="o/r" KIT_PROJECTS_V2="true"
unset KIT_CONFIG CLAUDE_CODE_REMOTE

# shellcheck source=/dev/null
. "$LIB/../../lib/verbs/kit-task-ops.sh"
# Board stubs: the close must still move the item to Done whatever the reason.
BOARD_LOG="$tmp/board.log"
load_project_ids()           { STATUS_FIELD_ID="SF"; STATUS_OPT_DONE="DONE"; return 0; }
project_find_item_by_issue() { echo "ITEM-$1"; }
project_set_single_select()  { echo "$*" >> "$BOARD_LOG"; }

run() { : > "$GH_LOG"; : > "$BOARD_LOG"; kto_task_close "$@" >/dev/null 2>"$tmp/err"; echo $?; }
# A close is one PATCH repos/o/r/issues/<n> {"state":"closed","state_reason":…}; the summary is a POST comment first.
CLOSE='^PATCH repos/o/r/issues/'
COMMENT='^POST repos/o/r/issues/'

t  "default close succeeds"                      "$(run 5 "Shipped in #9.")" 0
tc "$GH_LOG" "${CLOSE}5 \{\"state\":\"closed\",\"state_reason\":\"completed\"\}$" "default reason is completed"
tc "$GH_LOG" "${COMMENT}5/comments \{\"body\":\"Shipped in #9\.\"\}$" "with the summary as a comment"
tc "$BOARD_LOG" '^ITEM-5 SF DONE$'                "the board goes to Done"

t  "--reason not-planned succeeds"               "$(run 6 "Measured; not worth it." --reason not-planned)" 0
tc "$GH_LOG" "${CLOSE}6 \{\"state\":\"closed\",\"state_reason\":\"not_planned\"\}$" "not-planned maps to GitHub's not_planned"
tc "$GH_LOG" "${COMMENT}6/comments \{\"body\":\"Measured; not worth it\.\"\}$" "not-planned keeps the summary"
tc "$BOARD_LOG" '^ITEM-6 SF DONE$'                "not planned still sets Done"

t  "--duplicate-of succeeds without a summary"   "$(run 7 --duplicate-of 4)" 0
tc "$GH_LOG" "${CLOSE}7 \{\"state\":\"closed\",\"state_reason\":\"duplicate\"\}$" "--duplicate-of closes as a duplicate"
tc "$GH_LOG" "${COMMENT}7/comments \{\"body\":\"Duplicate of #4\.\"\}$" "and defaults the comment to the original"
tc "$BOARD_LOG" '^ITEM-7 SF DONE$'                "a duplicate still sets Done"
t  "--reason duplicate + --duplicate-of"         "$(run 7 "Same as #4." --reason duplicate --duplicate-of '#4')" 0
tc "$GH_LOG" "${CLOSE}7 \{\"state\":\"closed\",\"state_reason\":\"duplicate\"\}$" "'#4' is accepted as the duplicate"
tc "$GH_LOG" "${COMMENT}7/comments \{\"body\":\"Same as #4\.\"\}$" "an explicit summary naming the original is kept as is"

t  "--superseded-by succeeds"                    "$(run 8 "Folded into the new effort." --superseded-by 12)" 0
tc "$GH_LOG" "${CLOSE}8 \{\"state\":\"closed\",\"state_reason\":\"not_planned\"\}$" "superseded closes as not planned"
tc "$GH_LOG" "${COMMENT}8/comments \{\"body\":\"Folded into the new effort\.\\\\n\\\\nSuperseded by #12\.\"\}$" "and the comment says Superseded by #12"
t  "--superseded-by alone defaults the comment"  "$(run 8 --superseded-by 12)" 0
tc "$GH_LOG" "${CLOSE}8 \{\"state\":\"closed\",\"state_reason\":\"not_planned\"\}$" "superseded alone closes as not planned"
tc "$GH_LOG" "${COMMENT}8/comments \{\"body\":\"Superseded by #12\.\"\}$" "default superseded comment"

t  "--reason completed is accepted explicitly"   "$(run 9 "Done." --reason completed)" 0
tc "$GH_LOG" "${CLOSE}9 \{\"state\":\"closed\",\"state_reason\":\"completed\"\}$" "explicit completed"

# refusals: nothing is closed and the board is not touched
t  "an unknown reason is refused (rc 2)"         "$(run 10 "x" --reason wontfix)" 2
t  "an unknown flag is refused (rc 2)"           "$(run 10 "x" --force)" 2
t  "duplicate without --duplicate-of (rc 2)"     "$(run 10 "x" --reason duplicate)" 2
t  "--duplicate-of contradicting --reason (rc 2)" "$(run 10 "x" --reason completed --duplicate-of 4)" 2
t  "--duplicate-of + --superseded-by (rc 2)"     "$(run 10 "x" --duplicate-of 4 --superseded-by 5)" 2
t  "a non-number --duplicate-of (rc 2)"          "$(run 10 "x" --duplicate-of abc)" 2
t  "no summary and no default (rc 1)"            "$(run 10)" 1
t  "refusals closed nothing"                     "$(grep -cE '^(PATCH|POST) ' "$GH_LOG")" 0
t  "refusals left the board alone"               "$(wc -l < "$BOARD_LOG" | tr -d ' ')" 0

# an already-closed issue: board only, no second close
GH_CLOSED="11"
t  "an already-closed issue is fine"             "$(run 11 "x" --reason not-planned)" 0
t  "it is not closed again"                      "$(grep -cE '^(PATCH|POST) ' "$GH_LOG")" 0
t  "no gh subcommand ran"                        "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" 0
tc "$BOARD_LOG" '^ITEM-11 SF DONE$'               "but the board still goes to Done"

t  "the dispatcher answers --help"               "$("$ROOT/bin/cckit" close --help | sed -n 1p | cut -c1-19)" "cckit close <issue>"

[ "$fail" -eq 0 ] && echo "kto-task-close: all passed" || echo "kto-task-close: FAILURES"
exit "$fail"
