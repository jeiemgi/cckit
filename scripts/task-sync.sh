#!/usr/bin/env bash
# Read-only board status, grouped by role. Pure gh + jq. bash 3.2 compatible.
# Reads repo from .claude/kit.config.json. Run from project root.
#   ./scripts/task-sync.sh [--role <Name>] [--milestone <label>]
set -euo pipefail
source "$(dirname "$0")/lib/kit-config.sh" && load_kit_config
# Pure board-view render helpers (merge queue, stale flag, not-on-board flag, Project Status).
source "$(dirname "$0")/lib/board-view.sh"

ROLE_FILTER=""; MS_FILTER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE_FILTER="$2"; shift 2 ;;
    --milestone) MS_FILTER="$2"; shift 2 ;;
    --llm|--output=json) CCKIT_OUTPUT=json; shift ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

ISSUES=$(gh issue list --repo "$KIT_REPO" --state open --limit 200 \
  --json number,title,labels,milestone,assignees,updatedAt,body)

# Structured output for agents: emit the open board and stop (--llm / CCKIT_OUTPUT). The board is a
# uniform list, so it goes out as TOON — far cheaper in tokens than JSON — via the shared encoder,
# which falls back to JSON for a non-uniform/empty result. labels + assignees are flattened to
# space-joined strings (and priority is lifted out) so every row is scalar-only and TOON-eligible.
if [ "${CCKIT_OUTPUT:-human}" = "json" ]; then
  board="$(echo "$ISSUES" | jq -c '[.[] | {
      number,
      title,
      priority: ([.labels[].name | select(startswith("priority:")) | sub("priority:";"")][0] // ""),
      labels: ([.labels[].name] | join(" ")),
      milestone: (.milestone.title // ""),
      assignees: ([.assignees[].login] | join(" ")),
      blocked: ((.body // "") | test("Blocked by"))
    }]')"
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/toon.sh"
  printf '%s' "$board" | toon_encode
  exit 0
fi

# Project Status map {"<number>":"<status>"} — from the Projects v2 board when it is enabled, so each
# issue row shows its board Status and we can flag issues that never got added (no-board-entry). A
# best-effort, config-guarded read: with projectsV2 off (or any hiccup) the map stays {} and every
# row shows "—" — the board view still renders, just without Status.
STATUS_MAP="{}"
if [ "${KIT_PROJECTS_V2:-false}" = "true" ] && [ -n "${KIT_PROJECT_NUMBER:-}" ] && [ -n "${KIT_OWNER:-}" ]; then
  case "${KIT_PROJECT_OWNER_TYPE:-user}" in org|organization) _ROOT=organization ;; *) _ROOT=user ;; esac
  STATUS_MAP="$(gh api graphql -f query="
    query(\$login:String!,\$number:Int!){
      $_ROOT(login:\$login){ projectV2(number:\$number){ items(first:200){ nodes{
        content{ ... on Issue { number } ... on PullRequest { number } }
        fieldValueByName(name:\"Status\"){ ... on ProjectV2ItemFieldSingleSelectValue { name } }
      }}}}}" -f login="$KIT_OWNER" -F number="$KIT_PROJECT_NUMBER" 2>/dev/null \
    | jq -c "[.data.${_ROOT}.projectV2.items.nodes[]
        | select(.content.number != null)
        | {key:(.content.number|tostring), value:(.fieldValueByName.name // \"—\")}]
      | from_entries" 2>/dev/null || printf '{}')"
  [ -n "$STATUS_MAP" ] || STATUS_MAP="{}"
fi

# Open PRs for the merge queue (fetched once; risk/size labels + draft/review state drive the order).
PRS_JSON="$(gh pr list --repo "$KIT_REPO" --state open --limit 100 \
  --json number,title,labels,isDraft,headRefName,reviewDecision,mergeable 2>/dev/null || echo '[]')"

echo "## Board — $KIT_REPO"
echo ""

# Roles come from config; iterate in declared order, plus an "unlabeled" bucket.
print_role() {
  local role="$1" slug rows
  slug=$(echo "$role" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  rows=$(echo "$ISSUES" | jq -r --arg slug "role:$slug" --arg ms "$MS_FILTER" --argjson st "$STATUS_MAP" '
    .[] | select(any(.labels[]; .name == $slug))
        | select($ms == "" or (.milestone.title // "") == $ms)
        | { n:.number, t:.title,
            s:($st[(.number|tostring)] // "—"),
            p:([.labels[].name | select(startswith("priority:"))][0] // "—" | sub("priority:";"")),
            m:(.milestone.title // "—"),
            blocked:(.body // "" | test("Blocked by")) }
        | "| #\(.n) | \(.s) | \(.t) | \(.p) | \(.m) | \(if .blocked then "! blocked" else "—" end) |"')
  [[ -z "$rows" ]] && return
  echo "### $role"
  echo "| # | Status | Title | Pri | Milestone | Flag |"
  echo "| - | ------ | ----- | --- | --------- | ---- |"
  echo "$rows"
  echo ""
}

if [[ -n "$ROLE_FILTER" ]]; then
  print_role "$ROLE_FILTER"
else
  while IFS= read -r role; do [[ -n "$role" ]] && print_role "$role"; done <<< "$KIT_ROLES"
fi

# ── Flags: blocked / not-on-board / stale ───────────────────────────────────────────────────────
BLOCKED_LIST=$(echo "$ISSUES" | jq -r '[.[] | select((.body // "") | test("Blocked by")) | "#\(.number)"] | join(" ")')
NOT_ON_BOARD=$(board_not_on_board "$ISSUES" "$STATUS_MAP")
STALE_LIST=$(board_stale_list "$ISSUES" 14)
echo "**Blocked:** ${BLOCKED_LIST:-none ✓}"
# Only surface no-board-entry when a board is actually configured (otherwise every issue trivially
# has no entry — noise, not signal).
if [ "${KIT_PROJECTS_V2:-false}" = "true" ]; then
  echo "**Not on board:** ${NOT_ON_BOARD:-none ✓}"
fi
echo "**Stale (>14 days no activity):** ${STALE_LIST:-none ✓}"
OPEN_TOTAL=$(echo "$ISSUES" | jq -r 'length')
echo "**Open total:** ${OPEN_TOTAL}"
echo ""

# ── Merge Queue: open PRs ordered ready → draft → blocked (risk asc, size asc) ───────────────────
board_merge_queue "$PRS_JSON"

# ── Optional local-model digest — only when the local endpoint is alive (zero API cost) ──────────
# A 3–5 line executive read of the board (merge order, blockers, staleness). Best-effort: absent or
# offline local model → nothing appended, the board view above stands on its own.
if [ -f "$(dirname "$0")/lib/kit-local.sh" ]; then
  # shellcheck source=/dev/null
  if source "$(dirname "$0")/lib/kit-local.sh" 2>/dev/null && kit_local_alive 2>/dev/null; then
    echo ""
    echo "### Local digest"
    kit_local_chat \
      "You are a release captain. In 3–5 lines, summarize the merge order, blockers, and staleness for a busy maintainer." \
      "Blocked: ${BLOCKED_LIST:-none}. Stale: ${STALE_LIST:-none}. Merge queue follows the ready→draft→blocked order." \
      2>/dev/null || echo "_(local digest unavailable)_"
  fi
fi
