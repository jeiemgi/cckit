#!/usr/bin/env bash
# shellcheck shell=bash
# board-view-test.sh — covers the pure board-view render helpers (#122): the merge-ordered open-PR
# queue, the stale flag, the not-on-board flag, and Project Status lookup. Hermetic: canned JSON,
# no gh. Run:  bash scripts/lib/board-view-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> output lacks '$3'"; fail=1 ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "board-view-test: jq required — skipping"; exit 0; }

# shellcheck source=/dev/null
source "$LIB/board-view.sh"

# ── merge queue ordering: ready(1) → draft(2) → blocked(3); within a tier risk:low first, size asc ─
PRS='[
 {"number":10,"title":"blocked one","labels":[{"name":"risk:low"},{"name":"size:S"},{"name":"blocked"}],"isDraft":false,"headRefName":"feat/10","reviewDecision":"APPROVED","mergeable":"MERGEABLE"},
 {"number":11,"title":"draft one","labels":[{"name":"risk:low"},{"name":"size:XS"}],"isDraft":true,"headRefName":"feat/11","reviewDecision":null,"mergeable":"MERGEABLE"},
 {"number":12,"title":"ready high risk","labels":[{"name":"risk:high"},{"name":"size:S"}],"isDraft":false,"headRefName":"claude/12","reviewDecision":"APPROVED","mergeable":"MERGEABLE"},
 {"number":13,"title":"ready low risk L","labels":[{"name":"risk:low"},{"name":"size:L"}],"isDraft":false,"headRefName":"feat/13","reviewDecision":"APPROVED","mergeable":"MERGEABLE"},
 {"number":14,"title":"ready low risk S","labels":[{"name":"risk:low"},{"name":"size:S"}],"isDraft":false,"headRefName":"feat/14","reviewDecision":"APPROVED","mergeable":"MERGEABLE"}
]'
MQ="$(board_merge_queue "$PRS")"
order="$(printf '%s' "$MQ" | grep -oE '#1[0-4]' | tr '\n' ' ')"
t "merge queue orders ready(risk asc,size asc) → draft → blocked" "$order" "#14 #13 #12 #11 #10 "
has "ready PR marked ● ready"   "$MQ" "● ready"
has "draft PR marked · draft"   "$MQ" "· draft"
has "blocked PR marked ▪ blocked" "$MQ" "▪ blocked"
has "agent branch flagged ● agent" "$MQ" "● agent"

# empty PR set renders the no-open-PRs row, not an error.
has "empty merge queue renders a friendly row" "$(board_merge_queue '[]')" "no open PRs ✓"

# ── stale flag: > N days no activity, most-stale first ──────────────────────────────────────────
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OLD20="$(date -u -v-20d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '20 days ago' +%Y-%m-%dT%H:%M:%SZ)"
OLD40="$(date -u -v-40d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '40 days ago' +%Y-%m-%dT%H:%M:%SZ)"
ISS="[{\"number\":1,\"updatedAt\":\"$OLD20\"},{\"number\":2,\"updatedAt\":\"$NOW\"},{\"number\":3,\"updatedAt\":\"$OLD40\"}]"
sl="$(board_stale_list "$ISS" 14)"
t "stale list picks the >14d issues, most-stale first" "${sl%% *}" "#3(40d)"
has "stale list includes the 20d issue" "$sl" "#1(20d)"
case "$sl" in *"#2"*) echo "FAIL: fresh issue wrongly flagged stale"; fail=1 ;; *) echo "ok: fresh issue not flagged stale" ;; esac
t "no stale issues yields empty (caller renders none)" "$(board_stale_list "[{\"number\":9,\"updatedAt\":\"$NOW\"}]" 14)" ""

# ── not-on-board + status lookup ────────────────────────────────────────────────────────────────
t "not_on_board lists issues absent from the board map" "$(board_not_on_board '[{"number":1},{"number":2},{"number":3}]' '{"1":"Todo","3":"Done"}')" "#2"
t "not_on_board empty when all issues are on the board"  "$(board_not_on_board '[{"number":1}]' '{"1":"Todo"}')" ""
t "status_for returns the board status"                  "$(board_status_for 3 '{"1":"Todo","3":"Done"}')" "Done"
t "status_for returns — for an off-board issue"          "$(board_status_for 9 '{"1":"Todo"}')" "—"

[ "$fail" -eq 0 ] && echo "ALL OK (board-view)" || echo "board-view: FAILURES"
exit "$fail"
