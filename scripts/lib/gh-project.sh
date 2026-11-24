#!/usr/bin/env bash
# Helpers for GitHub Projects v2: REST first, GraphQL as the fallback (E546.7).
# Source after kit-config.sh:  source scripts/lib/gh-project.sh; load_project_ids
# Requires scripts/.project-ids.env — populate via scripts/capture-project-ids.sh.
# errors: strict — a failed GraphQL call propagates; the board is not guessed

# Locate scripts/ portably when sourced (#313): BASH_SOURCE is bash-only — empty in
# zsh, where dirname "" resolved to CWD and the env was sought in the wrong dir.
# zsh exposes the sourced file via the %x prompt escape; eval keeps bash from parsing it.
# The forge port (E537): every GitHub call goes through forge_* / gh_rest_* (scripts/lib/gh-rest.sh).
if ! command -v gh_rest_issue_json >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/gh-rest.sh"
fi

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

# The board moves over REST first (E546.7): load_project_ids, project_add_item, project_find_item_by_issue,
# project_set_single_select, project_set_iteration and project_set_text call the Projects v2 REST
# endpoints (gh_rest_board_*, scripts/lib/gh-rest.sh) and fall back to GraphQL only when REST cannot
# serve the call (404, 410, 415, 501, a transport failure, an unexpected answer), with one stderr note.
# Where GraphQL is unavailable too (a cloud session, CCKIT_GRAPHQL=0) such a step prints the one skip
# notice and returns 0. With no forge every board function returns 0 at once (cckit_board_skipped).
# project_issue_status is GraphQL-only.
#
# Item ids: a REST item is "<id>:<node_id>" (the integer REST id, then the GraphQL node id); a GraphQL
# item is its node id. Every setter takes either: REST with the integer, GraphQL with the node id.
if ! type cckit_board_skipped >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/lib/gh-rest.sh" ]; then
  # shellcheck source=gh-rest.sh
  . "$SCRIPT_DIR/lib/gh-rest.sh"
fi
type cckit_board_skipped >/dev/null 2>&1 || cckit_board_skipped() { return 1; }
type cckit_graphql_off >/dev/null 2>&1 || cckit_graphql_off() { return 1; }
type cckit_board_graphql_notice >/dev/null 2>&1 || cckit_board_graphql_notice() { :; }

# _ghp_fallback <step> — REST could not serve <step>. rc 0: go on with GraphQL (one note printed);
# rc 1: GraphQL is unavailable here, the skip notice is printed once, the caller returns 0.
_ghp_fallback() {
  if cckit_graphql_off; then cckit_board_graphql_notice; return 1; fi
  printf 'cckit: board %s: REST could not serve it, falling back to GraphQL\n' "$1" >&2
  return 0
}

# The REST endpoint prefix of our board, or rc 3 when the owner or number is unresolved.
_ghp_rest_base() {
  command -v gh_rest_board_base >/dev/null 2>&1 || return 3
  gh_rest_board_base "$(_ghp_resolve_owner_type)" "$(_ghp_resolve_owner)" "$(_ghp_resolve_pnum)"
}

# An item handle's REST id ("<id>:<node>" or "<id>"), or rc 1; and its GraphQL node id, or empty.
_ghp_item_num() {
  local n="${1%%:*}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$n"
}
_ghp_item_node() {
  case "$1" in
    *:*)        printf '%s' "${1#*:}" ;;
    *[!0-9]*)   printf '%s' "$1" ;;
    *)          : ;;
  esac
}

# _ghp_rest_set <kind> <item> <field> <value> — the REST half of a setter. rc 0 set · 1 a hard error
# · 3 go on with GraphQL (note printed) · 4 GraphQL unavailable (notice printed; return 0).
_ghp_rest_set() {
  local kind="$1" item="$2" field="$3" value="$4" inum base rc=3
  if inum="$(_ghp_item_num "$item")" && base="$(_ghp_rest_base)"; then
    gh_log rest mutation "project_set_$kind" "gh-project"
    rc=0; gh_rest_board_set_field "$base" "$inum" "$field" "$kind" "$value" || rc=$?
  fi
  case "$rc" in 0) return 0 ;; 3) ;; *) return 1 ;; esac
  _ghp_fallback "set $kind" || return 4
  [ -n "$(_ghp_item_node "$item")" ] || { echo "cckit: board item '$item' has no GraphQL node id" >&2; return 1; }
  return 3
}

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
  cckit_board_skipped && return 0
  # First run in a checkout that still has the legacy file: migrate it to the shared path.
  if [[ ! -f "$PROJECT_ENV" && -f "$PROJECT_ENV_LEGACY" ]]; then
    cp "$PROJECT_ENV_LEGACY" "$PROJECT_ENV" 2>/dev/null || PROJECT_ENV="$PROJECT_ENV_LEGACY"
  fi
  if [[ ! -f "$PROJECT_ENV" ]]; then
    # No captured file (a fresh clone, a cloud session): read the ids over REST into this shell.
    _ghp_load_ids_rest && return 0
    if cckit_graphql_off; then cckit_board_graphql_notice; return 0; fi
    echo "✗ project IDs not found ($PROJECT_ENV). Run: ./scripts/capture-project-ids.sh first." >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$PROJECT_ENV"
}

# _ghp_load_ids_rest — export the ids gh_rest_board_ids_env reads. Each line must be NAME=value with
# NAME in [A-Z0-9_] and an id-shaped value; nothing is evaluated. rc 1 when REST cannot read them.
_ghp_load_ids_rest() {
  local base lines line k v
  command -v gh_rest_board_ids_env >/dev/null 2>&1 || return 1
  base="$(_ghp_rest_base)" || return 1
  gh_log rest query "load_project_ids" "gh-project"
  lines="$(gh_rest_board_ids_env "$base" 2>/dev/null)" || return 1
  case "$lines" in PROJECT_ID=?*) ;; *) return 1 ;; esac
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in ''|*[!A-Z0-9_]*) continue ;; esac
    case "$v" in *[!A-Za-z0-9_=+/-]*) continue ;; esac
    export "$k=$v"
  done <<EOF
$lines
EOF
  echo "cckit: board ids read over REST (no captured file; scripts/capture-project-ids.sh writes one)" >&2
  return 0
}

# Add an issue/PR to the project. Echoes the new item ID.
# Args: <content node id> [<repo> <number> [Issue|PullRequest]]. REST adds by repo + number, so it
# runs when those are given (the type defaults from the node id: PR_… is a pull request); GraphQL
# adds by the node id.
project_add_item() {
  cckit_board_skipped && return 0
  local node="${1:-}" repo="${2:-}" num="${3:-}" type="${4:-}" base out rc=3
  if [ -z "$type" ]; then case "$node" in PR_*) type=PullRequest ;; *) type=Issue ;; esac; fi
  if [ -n "$repo" ] && [ -n "$num" ] && base="$(_ghp_rest_base)"; then
    gh_log rest mutation "project_add_item" "gh-project"
    rc=0; out="$(gh_rest_board_add_item "$base" "$type" "$repo" "$num")" || rc=$?
  fi
  case "$rc" in 0) printf '%s\n' "$out"; return 0 ;; 3) ;; *) return 1 ;; esac
  _ghp_fallback "add item" || return 0
  [ -n "$node" ] || { echo "cckit: project_add_item: no content node id for the GraphQL fallback" >&2; return 1; }
  gh_log graphql mutation "project_add_item" "gh-project"
  forge_rest graphql \
    -f query='mutation($project:ID!, $content:ID!) {
      addProjectV2ItemById(input:{projectId:$project, contentId:$content}){ item { id } }
    }' \
    -f project="$PROJECT_ID" -f content="$1" \
    --jq '.data.addProjectV2ItemById.item.id'
}

# Set a single-select field. Args: <item_id> <field_id> <option_id>
project_set_single_select() {
  cckit_board_skipped && return 0
  local _rs=0
  _ghp_rest_set single_select "$1" "$2" "$3" || _rs=$?
  case "$_rs" in 0|4) return 0 ;; 1) return 1 ;; esac
  gh_log graphql mutation "project_set_single_select" "gh-project"
  forge_rest graphql \
    -f query='mutation($project:ID!, $item:ID!, $field:ID!, $option:String!) {
      updateProjectV2ItemFieldValue(input:{
        projectId:$project, itemId:$item, fieldId:$field,
        value:{ singleSelectOptionId:$option }
      }){ projectV2Item { id } }
    }' \
    -f project="$PROJECT_ID" -f item="$(_ghp_item_node "$1")" -f field="$2" -f option="$3" >/dev/null
}

# Set an iteration field. Args: <item_id> <field_id> <iteration_id>
project_set_iteration() {
  cckit_board_skipped && return 0
  local _rs=0
  _ghp_rest_set iteration "$1" "$2" "$3" || _rs=$?
  case "$_rs" in 0|4) return 0 ;; 1) return 1 ;; esac
  gh_log graphql mutation "project_set_iteration" "gh-project"
  forge_rest graphql \
    -f query='mutation($project:ID!, $item:ID!, $field:ID!, $iteration:String!) {
      updateProjectV2ItemFieldValue(input:{
        projectId:$project, itemId:$item, fieldId:$field,
        value:{ iterationId:$iteration }
      }){ projectV2Item { id } }
    }' \
    -f project="$PROJECT_ID" -f item="$(_ghp_item_node "$1")" -f field="$2" -f iteration="$3" >/dev/null
}

# Set a text field. Args: <item_id> <field_id> <text>
project_set_text() {
  cckit_board_skipped && return 0
  local _rs=0
  _ghp_rest_set text "$1" "$2" "$3" || _rs=$?
  case "$_rs" in 0|4) return 0 ;; 1) return 1 ;; esac
  gh_log graphql mutation "project_set_text" "gh-project"
  forge_rest graphql \
    -f query='mutation($project:ID!, $item:ID!, $field:ID!, $text:String!) {
      updateProjectV2ItemFieldValue(input:{
        projectId:$project, itemId:$item, fieldId:$field, value:{ text:$text }
      }){ projectV2Item { id } }
    }' \
    -f project="$PROJECT_ID" -f item="$(_ghp_item_node "$1")" -f field="$2" -f text="$3" >/dev/null
}

# Resolve an option ID from a human name.
# Names are normalized: uppercased, spaces/hyphens -> underscores.
#   role_option_id "Tech Lead"  -> $ROLE_OPT_TECH_LEAD
#   status_option_id "In Review" -> $STATUS_OPT_IN_REVIEW
# No ${!var} indirection: these libs are sourced into zsh sessions too, where
# bash-only indirection dies with "bad substitution" (#307).
_norm() { echo "$1" | tr '[:lower:]' '[:upper:]' | tr ' -' '__'; }
# role_option_id <name> — ANY board Role option, not a fixed list (#378): capture-project-ids.sh
# writes ROLE_OPT_<NAME> for every option the board has, so the lookup reads that variable by
# name. The name is expanded through eval (portable to bash and zsh), and only after it matches
# ^[A-Z0-9_]+$ byte-for-byte — anything else is refused before the eval, so the argument can never
# run as code. No option for the role: empty stdout plus a warning on stderr, so a Role field left
# unset is reported instead of silent. An empty name asks nothing and prints nothing.
role_option_id() {
  local LC_ALL=C _roi_name="" _roi_val=""
  [ -n "${1:-}" ] || return 0
  _roi_name="$(_norm "$1")"
  case "$_roi_name" in
    ''|*[!A-Z0-9_]*)
      echo "⚠ board Role not set: role '$1' is not a usable option name (letters, digits, spaces, hyphens, underscores only)" >&2
      echo ""
      return 0 ;;
  esac
  eval "_roi_val=\"\${ROLE_OPT_${_roi_name}:-}\""
  if [ -z "$_roi_val" ]; then
    echo "⚠ board Role not set: no Role option for '$1' (ROLE_OPT_${_roi_name} is not captured) — add the option to the board's Role field, then re-run scripts/capture-project-ids.sh" >&2
  fi
  echo "$_roi_val"
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
# A board can live under a user login OR an organization login. An org-owned board is what lets a
# single issue see its own card via the CHEAP issue.projectItems lookup (project_find_item_by_issue),
# so every board GraphQL query must branch on this: organization(login:) vs user(login:).
# Prefers the exported KIT_PROJECT_OWNER_TYPE (set by kit-config from github.projectOwnerType).
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
# own project cards (issue.projectItems) and filters by project number. issue.projectItems surfaces
# an issue's cards cheaply (O(1) per issue) whether the board is user- or org-owned, so this finder
# never paginates. An issue belongs to few projects, so first:20 covers it without a loop.
project_find_item_by_issue() {
  cckit_board_skipped && return 0
  local issue_num="$1"
  local pnum="${2:-$(_ghp_resolve_pnum)}"
  local repo owner name resp item_id
  repo="$(_ghp_resolve_repo)"
  owner="${repo%%/*}"
  name="${repo##*/}"
  # Guard: an empty repo/number is the silent-failure trap — surface it, don't no-op.
  if [[ -z "$owner" || -z "$name" || -z "$pnum" ]]; then
    if cckit_graphql_off; then cckit_board_graphql_notice; return 0; fi
    echo "✗ project_find_item_by_issue: repo/project-number unresolved (KIT_REPO='${KIT_REPO:-}' repo='$repo' KIT_PROJECT_NUMBER='${KIT_PROJECT_NUMBER:-}'). Set .github.repo + .github.projectNumber in kit.config.json, or pass the number as arg 2." >&2
    return 1
  fi
  # REST first: the board's items, read for this issue's card ("<id>:<node_id>").
  local base rc=3
  if base="$(gh_rest_board_base "$(_ghp_resolve_owner_type)" "$(_ghp_resolve_owner)" "$pnum" 2>/dev/null)"; then
    gh_log rest query "project_find_item_by_issue" "gh-project"
    rc=0; item_id="$(gh_rest_board_find_issue_item "$base" "$repo" "$issue_num")" || rc=$?
  fi
  case "$rc" in 0) [ -n "$item_id" ] && printf '%s\n' "$item_id"; return 0 ;; 3) ;; *) return 1 ;; esac
  _ghp_fallback "find item" || return 0
  gh_log graphql query "project_find_item_by_issue:cheap" "gh-project"
  # The cheap query: issue.projectItems(first:20), each node carrying its project number.
  # No pagination, no board scan — O(1) per issue.
  resp=$(forge_rest graphql \
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
    '.data.repository.issue.projectItems.nodes[] | select(.project.number==$n) | .id' 2>/dev/null | sed -n 1p)
  echo "$item_id"
}

# project_issue_status <issue_number> [<project_number>] — echo an issue's Project Status field value
# on OUR board ("Todo" / "In Progress" / "Done" / …), or empty when the issue isn't on the board.
# The cheap issue.projectItems lookup, same as project_find_item_by_issue. A claim precheck reads this
# before starting an issue so it can warn on a collision (another session already In Progress). #124.
project_issue_status() {
  cckit_board_skipped && return 0
  if cckit_graphql_off; then cckit_board_graphql_notice; return 0; fi
  local issue_num="$1" pnum="${2:-$(_ghp_resolve_pnum)}" repo owner name resp
  repo="$(_ghp_resolve_repo)"; owner="${repo%%/*}"; name="${repo##*/}"
  [ -n "$owner" ] && [ -n "$name" ] && [ -n "$pnum" ] || return 1
  resp="$(forge_rest graphql \
    -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){projectItems(first:20){nodes{project{number} fieldValueByName(name:"Status"){...on ProjectV2ItemFieldSingleSelectValue{name}}}}}}}' \
    -F o="$owner" -F r="$name" -F n="$issue_num" 2>/dev/null)" || return 1
  printf '%s' "$resp" | jq -r --argjson n "$pnum" \
    '.data.repository.issue.projectItems.nodes[]? | select(.project.number==$n) | .fieldValueByName.name // empty' \
    2>/dev/null | sed -n 1p
}
