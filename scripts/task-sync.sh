#!/usr/bin/env bash
# Read-only board status, grouped by role. Pure gh + jq. bash 3.2 compatible.
# Reads repo from .claude/kit.config.json. Run from project root.
#   ./scripts/task-sync.sh [--role <Name>] [--milestone <label>]
set -euo pipefail
source "$(dirname "$0")/lib/kit-config.sh" && load_kit_config

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

echo "## Board — $KIT_REPO"
echo ""

# Roles come from config; iterate in declared order, plus an "unlabeled" bucket.
print_role() {
  local role="$1" slug rows
  slug=$(echo "$role" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  rows=$(echo "$ISSUES" | jq -r --arg slug "role:$slug" --arg ms "$MS_FILTER" '
    .[] | select(any(.labels[]; .name == $slug))
        | select($ms == "" or (.milestone.title // "") == $ms)
        | { n:.number, t:.title,
            p:([.labels[].name | select(startswith("priority:"))][0] // "—" | sub("priority:";"")),
            m:(.milestone.title // "—"),
            blocked:(.body // "" | test("Blocked by")) }
        | "| #\(.n) | \(.t) | \(.p) | \(.m) | \(if .blocked then "! blocked" else "—" end) |"')
  [[ -z "$rows" ]] && return
  echo "### $role"
  echo "| # | Title | Pri | Milestone | Flag |"
  echo "| - | ----- | --- | --------- | ---- |"
  echo "$rows"
  echo ""
}

if [[ -n "$ROLE_FILTER" ]]; then
  print_role "$ROLE_FILTER"
else
  while IFS= read -r role; do [[ -n "$role" ]] && print_role "$role"; done <<< "$KIT_ROLES"
fi

BLOCKED=$(echo "$ISSUES" | jq -r '[.[] | select((.body // "") | test("Blocked by"))] | length')
echo "**Blocked:** ${BLOCKED} item(s)"
STALE=$(echo "$ISSUES" | jq -r '[.[] | .updatedAt] | length')
echo "**Open total:** ${STALE}"
