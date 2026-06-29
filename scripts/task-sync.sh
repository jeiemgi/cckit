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
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

ISSUES=$(gh issue list --repo "$KIT_REPO" --state open --limit 200 \
  --json number,title,labels,milestone,assignees,updatedAt,body)

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
