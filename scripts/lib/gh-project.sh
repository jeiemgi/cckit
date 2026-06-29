#!/usr/bin/env bash
# Helpers for GitHub Projects v2 via gh CLI + GraphQL.
# Source after kit-config.sh:  source scripts/lib/gh-project.sh; load_project_ids
# Requires scripts/.project-ids.env — populate via scripts/capture-project-ids.sh.

# Locate scripts/ portably when sourced (#313): BASH_SOURCE is bash-only — empty in
# zsh, where dirname "" resolved to CWD and the env was sought in the wrong dir.
# zsh exposes the sourced file via the %x prompt escape; eval keeps bash from parsing it.
if [ -n "${BASH_SOURCE:-}" ]; then
  _ghp_self="$BASH_SOURCE"
elif [ -n "${ZSH_VERSION:-}" ]; then
  eval '_ghp_self="${(%):-%x}"'
else
  _ghp_self="$0"
fi
SCRIPT_DIR="$(cd "$(dirname "$_ghp_self")/.." && pwd)"
unset _ghp_self

# GitHub request log (best-effort) — point model + ceilings in scripts/lib/gh-log.sh.
if [ -f "$SCRIPT_DIR/lib/gh-log.sh" ]; then
  # shellcheck source=gh-log.sh
  . "$SCRIPT_DIR/lib/gh-log.sh" 2>/dev/null || true
fi
type gh_log >/dev/null 2>&1 || gh_log() { :; }

# Worktree-durable location for the captured project IDs (#532). The legacy
# scripts/.project-ids.env is gitignored + untracked, so it is ABSENT in every worktree —
# load_project_ids then no-ops and board updates silently fail (root cause of board drift).
# Store under the shared git-common-dir: one copy the main checkout AND all worktrees see,
# and it survives `git worktree prune`.
_ghp_shared_env() {
  local common
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in /*) : ;; *) common="$(cd "$common" 2>/dev/null && pwd)" || return 1 ;; esac
  printf '%s/kit-project-ids.env' "$common"
}
PROJECT_ENV="$(_ghp_shared_env || printf '%s/.project-ids.env' "$SCRIPT_DIR")"
PROJECT_ENV_LEGACY="$SCRIPT_DIR/.project-ids.env"  # pre-#532 per-checkout path

load_project_ids() {
  # First run in a checkout that still has the legacy file: migrate it to the shared path.
  if [[ ! -f "$PROJECT_ENV" && -f "$PROJECT_ENV_LEGACY" ]]; then
    cp "$PROJECT_ENV_LEGACY" "$PROJECT_ENV" 2>/dev/null || PROJECT_ENV="$PROJECT_ENV_LEGACY"
  fi
  if [[ ! -f "$PROJECT_ENV" ]]; then
    echo "✗ project IDs not found ($PROJECT_ENV). Run: ./scripts/capture-project-ids.sh first." >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$PROJECT_ENV"
}

# Add an issue/PR (by node ID) to the project. Echoes the new item ID.
project_add_item() {
  gh_log graphql mutation "project_add_item" "gh-project"
  gh api graphql \
    -f query='mutation($project:ID!, $content:ID!) {
      addProjectV2ItemById(input:{projectId:$project, contentId:$content}){ item { id } }
    }' \
    -f project="$PROJECT_ID" -f content="$1" \
    --jq '.data.addProjectV2ItemById.item.id'
}

# Set a single-select field. Args: <item_id> <field_id> <option_id>
project_set_single_select() {
  gh_log graphql mutation "project_set_single_select" "gh-project"
  gh api graphql \
    -f query='mutation($project:ID!, $item:ID!, $field:ID!, $option:String!) {
      updateProjectV2ItemFieldValue(input:{
        projectId:$project, itemId:$item, fieldId:$field,
        value:{ singleSelectOptionId:$option }
      }){ projectV2Item { id } }
    }' \
    -f project="$PROJECT_ID" -f item="$1" -f field="$2" -f option="$3" >/dev/null
}

# Set a text field. Args: <item_id> <field_id> <text>
project_set_text() {
  gh_log graphql mutation "project_set_text" "gh-project"
  gh api graphql \
    -f query='mutation($project:ID!, $item:ID!, $field:ID!, $text:String!) {
      updateProjectV2ItemFieldValue(input:{
        projectId:$project, itemId:$item, fieldId:$field, value:{ text:$text }
      }){ projectV2Item { id } }
    }' \
    -f project="$PROJECT_ID" -f item="$1" -f field="$2" -f text="$3" >/dev/null
}

# Resolve an option ID from a human name via explicit case lookup (#307).
# Names are normalized: uppercased, spaces/hyphens -> underscores.
#   role_option_id "Tech Lead"  -> $ROLE_OPT_TECH_LEAD
#   status_option_id "In Review" -> $STATUS_OPT_IN_REVIEW
# No ${!var} indirection: these libs are sourced into zsh sessions too, where
# bash-only indirection dies with "bad substitution". Unknown names echo empty.
_norm() { echo "$1" | tr '[:lower:]' '[:upper:]' | tr ' -' '__'; }
role_option_id() {
  case "$(_norm "$1")" in
    DESIGNER)  echo "${ROLE_OPT_DESIGNER:-}" ;;
    DEVOPS)    echo "${ROLE_OPT_DEVOPS:-}" ;;
    PM)        echo "${ROLE_OPT_PM:-}" ;;
    FRONTEND)  echo "${ROLE_OPT_FRONTEND:-}" ;;
    TAURI)     echo "${ROLE_OPT_TAURI:-}" ;;
    AI_ENG)    echo "${ROLE_OPT_AI_ENG:-}" ;;
    SECURITY)  echo "${ROLE_OPT_SECURITY:-}" ;;
    QA)        echo "${ROLE_OPT_QA:-}" ;;
    TECH_LEAD) echo "${ROLE_OPT_TECH_LEAD:-}" ;;
    RESEARCH)  echo "${ROLE_OPT_RESEARCH:-}" ;;
    *)         echo "" ;;
  esac
}
status_option_id() {
  case "$(_norm "$1")" in
    PAUSED)      echo "${STATUS_OPT_PAUSED:-}" ;;
    TODO)        echo "${STATUS_OPT_TODO:-}" ;;
    IN_PROGRESS) echo "${STATUS_OPT_IN_PROGRESS:-}" ;;
    DONE)        echo "${STATUS_OPT_DONE:-}" ;;
    BLOCKED)     echo "${STATUS_OPT_BLOCKED:-}" ;;
    IN_REVIEW)   echo "${STATUS_OPT_IN_REVIEW:-}" ;;
    *)           echo "" ;;
  esac
}

# Resolve the project owner + number even when KIT_OWNER/KIT_PROJECT_NUMBER aren't exported.
# THE board-Done bug (#536): skills source `gh-project.sh; load_project_ids` but NOT kit-config.sh,
# and load_project_ids only sets PROJECT_ID + field/option IDs — never KIT_OWNER/KIT_PROJECT_NUMBER.
# The finder then ran the GraphQL with empty $o/$n, GitHub rejected the query, jq iterated null, and
# the function returned EMPTY silently — so every board-Done update for a real issue no-op'd (looked
# like "issue not on board"). Fix: resolve owner/number from kit.config.json here, and fail LOUDLY on
# an unresolved owner or a GraphQL error instead of returning empty.
_ghp_resolve_owner() {
  [[ -n "${KIT_OWNER:-}" ]] && { printf '%s' "$KIT_OWNER"; return 0; }
  local cfg="${KIT_CONFIG:-$SCRIPT_DIR/../.claude/kit.config.json}"
  [[ -f "$cfg" ]] && jq -r '.github.owner // empty' "$cfg" 2>/dev/null
}
_ghp_resolve_pnum() {
  [[ -n "${KIT_PROJECT_NUMBER:-}" ]] && { printf '%s' "$KIT_PROJECT_NUMBER"; return 0; }
  local cfg="${KIT_CONFIG:-$SCRIPT_DIR/../.claude/kit.config.json}"
  [[ -f "$cfg" ]] && jq -r '.github.projectNumber // empty' "$cfg" 2>/dev/null
}

# Resolve the project OWNER TYPE — "organization" or "user" (default "user").
# The board moved from a user project (jeiemgi #2) to an org project
# (tuempresadigital #3). An org-owned board is what lets a single issue see its
# own card via the CHEAP issue.projectItems lookup (project_find_item_by_issue),
# so every board GraphQL query must branch on this: organization(login:) vs user(login:).
_ghp_resolve_owner_type() {
  [[ -n "${KIT_PROJECT_OWNER_TYPE:-}" ]] && { printf '%s' "$KIT_PROJECT_OWNER_TYPE"; return 0; }
  local cfg="${KIT_CONFIG:-$SCRIPT_DIR/../.claude/kit.config.json}" t=""
  [[ -f "$cfg" ]] && t="$(jq -r '.github.projectOwnerType // empty' "$cfg" 2>/dev/null)"
  printf '%s' "${t:-user}"
}

# Echo the GraphQL root selector for the resolved owner type:
#   organization -> "organization"   (org-owned board)
#   *            -> "user"            (user-owned board, the legacy default)
# Callers interpolate this into the query string AND read the response under the
# same key (.data.<root>.projectV2…), so the two stay in lockstep.
_ghp_owner_root() {
  case "$(_ghp_resolve_owner_type)" in
    org|organization) printf 'organization' ;;
    *)                printf 'user' ;;
  esac
}

# Resolve the repo slug (owner/name) for the CHEAP issue-side lookup below.
# The repo is config-driven (`.github.repo`, e.g. jeiemgi/cckit) — independent
# of the board owner. KIT_REPO (kit-config) wins when exported.
_ghp_resolve_repo() {
  [[ -n "${KIT_REPO:-}" ]] && { printf '%s' "$KIT_REPO"; return 0; }
  local cfg="${KIT_CONFIG:-$SCRIPT_DIR/../.claude/kit.config.json}"
  [[ -f "$cfg" ]] && jq -r '.github.repo // empty' "$cfg" 2>/dev/null
}

# Find the project item node ID for a given issue number — the CHEAP, O(1) lookup.
# Args: <issue_number> [<project_number>]
# Prints the item node ID on stdout, or nothing if the issue genuinely isn't on the board.
#
# Instead of paginating the WHOLE board (the old 330+-item loop), this asks the ISSUE for its
# own project cards (issue.projectItems) and filters by project number. This works ONLY because
# the board is now ORG-owned (tuempresadigital #3) — an org project surfaces issue.projectItems
# cheaply; the move from the user board (#2) is the whole reason this finder no longer paginates.
# An issue belongs to few projects, so first:20 covers it without a loop.
project_find_item_by_issue() {
  local issue_num="$1"
  local pnum="${2:-$(_ghp_resolve_pnum)}"
  local repo owner name resp item_id
  repo="$(_ghp_resolve_repo)"
  owner="${repo%%/*}"
  name="${repo##*/}"
  # Guard: an empty repo/number is the silent-failure trap — surface it, don't no-op.
  if [[ -z "$owner" || -z "$name" || -z "$pnum" ]]; then
    echo "✗ project_find_item_by_issue: repo/project-number unresolved (KIT_REPO='${KIT_REPO:-}' repo='$repo' KIT_PROJECT_NUMBER='${KIT_PROJECT_NUMBER:-}'). Set .github.repo + .github.projectNumber in kit.config.json, or pass the number as arg 2." >&2
    return 1
  fi
  gh_log graphql query "project_find_item_by_issue:cheap" "gh-project"
  # The cheap query: issue.projectItems(first:20), each node carrying its project number.
  # No pagination, no board scan — O(1) per issue.
  resp=$(gh api graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){projectItems(first:20){nodes{id project{number}}}}}}' \
    -F o="$owner" -F r="$name" -F n="$issue_num" 2>&1)
  # A GraphQL/transport error (or a null issue) must abort LOUDLY — never let it read as
  # "issue not on board". Detect a missing projectItems and bail with the raw error on stderr.
  if [[ "$(printf '%s' "$resp" | jq -r 'if .data.repository.issue.projectItems then "y" else "n" end' 2>/dev/null || echo n)" != "y" ]]; then
    echo "✗ project_find_item_by_issue: issue query failed for $repo#$issue_num:" >&2
    printf '%s\n' "$resp" >&2
    return 1
  fi
  # Pick the card whose project number matches OUR board; empty if the issue isn't on it.
  item_id=$(printf '%s' "$resp" | jq -r --argjson n "$pnum" \
    '.data.repository.issue.projectItems.nodes[] | select(.project.number==$n) | .id' 2>/dev/null | head -1)
  echo "$item_id"
}
