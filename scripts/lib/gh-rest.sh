#!/usr/bin/env bash
# shellcheck shell=bash
# gh-rest.sh — the REST forms of the lifecycle calls, over the forge port (E537.3; #396 before it).
#
# Every call here is `forge_rest repos/<owner>/<repo>/…` (scripts/lib/forge.sh), endpoint first: REST
# over curl with a token, no gh subcommand. REST is the ONLY transport now — the gh-subcommand
# (GraphQL) transport of #396 is gone, so `cckit_gh_rest` is always true and `CCKIT_GH_TRANSPORT`
# does nothing but warn once. What still depends on where cckit runs is GraphQL itself: a cloud
# agent session reaches GitHub through a proxy that refuses it (403), and Projects v2 is GraphQL-only,
# so the board moves over the Projects v2 REST endpoints first (E546.7, gh_rest_board_* below) and
# GraphQL is only the fallback; where GraphQL is unavailable too, a board step that REST could not
# serve is skipped with ONE notice line (exit 0, never a failure). With the forge provider `none`
# every board step is skipped the same way.
#
#   cckit_gh_rest                         rc 0 (kept for callers; REST is the only transport)
#   cckit_gh_transport                    echo rest
#   cckit_board_skipped                   rc 0 iff board steps are skipped (prints the notice once): no
#                                         forge, or GraphQL off with KIT_OWNER/KIT_PROJECT_NUMBER unset
#   cckit_graphql_off                     rc 0 iff GraphQL is unavailable: CLAUDE_CODE_REMOTE=true or CCKIT_GRAPHQL=0
#   cckit_board_graphql_notice            the GraphQL-unavailable board notice, once per process
#   gh_rest_closing_refs                  stdin: a PR body → the issue #s it closes (pure)
#   gh_rest_issue_json <repo> <n>         {number,title,body,state,labels[{name}],milestone{title,number}}
#   gh_rest_issue_state <repo> <n>        OPEN | CLOSED
#   gh_rest_issue_create <repo> <title> <body> <labels-csv> [milestone-title] [assign 1|0]   → html_url
#   gh_rest_issue_close <repo> <n> <completed|not_planned|duplicate> [comment]
#   gh_rest_issue_edit_title <repo> <n> <title>
#   gh_rest_issue_set_body <repo> <n> <body>
#   gh_rest_issue_add_labels <repo> <n> <labels-csv>
#   gh_rest_label_create <repo> <name> <color> <description>   (idempotent)
#   gh_rest_label_upsert <repo> <name> <color> <description>   → created|updated (the --force form)
#   gh_rest_issue_comment <repo> <n> <body|@file>              → html_url (PRs too)
#   gh_rest_issue_comments <repo> <n>                          every comment body
#   gh_rest_pr_url_for_head <repo> <branch>                    the open PR's url, or empty
#   gh_rest_repo_default_branch <repo> · gh_rest_user_login
#   gh_rest_milestone_number <repo> <title>
#   gh_rest_pr_create <repo> <base> <head> <title> <body> <labels-csv> [milestone-title]   → html_url
#   gh_rest_pr_for_head <repo> <branch>   the open PR number for a head branch
#   gh_rest_pr_json <repo> <pr>           {mergeable,mergeStateStatus,baseRefName,headRefName,body,title,mergeCommit,state}
#   gh_rest_pr_commit_subjects <repo> <pr>  one subject line per PR commit, oldest first
#   gh_rest_pr_merge <repo> <pr> <squash|merge|rebase>
#   gh_rest_pr_closing_issues <repo> <pr>
#   gh_rest_pr_diff <repo> <pr>
#   gh_rest_sub_issue_numbers <repo> <n>
#   gh_rest_issue_numbers_by_label <repo> <label>   open issues only
#   gh_rest_open_issue_titles <repo>      "<n>\t<title>" for every open issue
#   gh_rest_issue_closing_prs <repo> <n>  merged PRs that close <n> by keyword (timeline)
#   gh_rest_wave_rows <repo> <parent>     "sub|STATE|pr|merge-sha|pr-title" per sub (wave close)
#
#   gh_rest_board_base <owner-type> <owner> <number>       orgs/<o>/projectsV2/<n> | users/<o>/projectsV2/<n>
#   gh_rest_board_project <base>          {id,node_id,number,title}
#   gh_rest_board_fields <base>           [{id,node_id,name,data_type,options[{id,name}],iterations[{id,title,start_date}]}]
#   gh_rest_board_ids_env <base>          the scripts/.project-ids.env lines, read over REST
#   gh_rest_board_find_item <base> <Issue|PullRequest> <repo> <n>  "<item id>:<item node id>", empty when not on the board
#   gh_rest_board_find_issue_item <base> <repo> <n>        the same, for an issue
#   gh_rest_board_add_item <base> <Issue|PullRequest> <repo> <n>   "<item id>:<item node id>"
#   gh_rest_board_set_field <base> <item id> <field id|node id> <single_select|iteration|text> <value>
#   (board rc: 0 ok · 3 REST cannot serve it, the caller may fall back to GraphQL · 1 any other error)
#
# Not reachable in the cloud: GraphQL (so the board's GraphQL fallback), and remote branch deletion
# (the proxy rejects DELETE git/refs) — callers keep the branch and say so.
# bash 3.2 + zsh compatible. Requires jq.
# errors: mixed — creates, closes and merges propagate; labels/milestone/assignee are best-effort
_ghr_self="${BASH_SOURCE[0]:-$0}"
if ! command -v forge_rest >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "$_ghr_self")" && pwd)/forge.sh"
fi
unset _ghr_self

# _ghr_api <endpoint> [_ghr_api flags…] — the forge, loaded on first use. A `none` provider refuses
# here with one line naming the verb (forge_need), rc 1.
_ghr_api() { forge_load || return 1; forge_rest "$@"; }

CCKIT_BOARD_SKIP_NOTICE="cckit: board step skipped (GraphQL unavailable; the project's built-in workflows move the card)"
CCKIT_BOARD_SKIP_NOTICE_NOFORGE="cckit: board step skipped (no forge is configured; see forge.provider)"

# REST is the only transport (E537.3). CCKIT_GH_TRANSPORT is read only to say so, once.
cckit_gh_rest() {
  if [ -n "${CCKIT_GH_TRANSPORT:-}" ] && [ -z "${_CCKIT_TRANSPORT_WARNED:-}" ]; then
    printf 'cckit: CCKIT_GH_TRANSPORT is ignored — every GitHub call is REST over the forge (forge.provider)\n' >&2
    _CCKIT_TRANSPORT_WARNED=1
  fi
  return 0
}

cckit_gh_transport() { cckit_gh_rest; printf 'rest'; }

# rc 0 in a cloud agent session, where the proxy also rejects remote branch deletion (#396).
cckit_in_cloud() { [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; }

# rc 0 when GraphQL is unavailable: a cloud session (the proxy answers 403) or CCKIT_GRAPHQL=0.
# The board still moves over REST there; only its GraphQL fallback is gone.
cckit_graphql_off() { [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || [ "${CCKIT_GRAPHQL:-1}" = "0" ]; }

_cckit_board_notice() {
  if [ -z "${_CCKIT_BOARD_NOTICE_DONE:-}" ]; then
    printf '%s\n' "$1" >&2
    _CCKIT_BOARD_NOTICE_DONE=1
  fi
}

# The notice for a board step REST could not serve where GraphQL is unavailable. Once per process.
cckit_board_graphql_notice() { _cckit_board_notice "$CCKIT_BOARD_SKIP_NOTICE"; }

# rc 0 when board steps are skipped outright: no forge is configured, or GraphQL is unavailable and
# REST cannot name the board (KIT_OWNER or KIT_PROJECT_NUMBER unset). Prints the notice at most once
# per process. A cloud session with both set is not a skip: the board moves over REST (E546.7).
cckit_board_skipped() {
  if command -v forge_available >/dev/null 2>&1 && ! forge_available; then
    _cckit_board_notice "$CCKIT_BOARD_SKIP_NOTICE_NOFORGE"
    return 0
  fi
  if cckit_graphql_off && { [ -z "${KIT_OWNER:-}" ] || [ -z "${KIT_PROJECT_NUMBER:-}" ]; }; then
    _cckit_board_notice "$CCKIT_BOARD_SKIP_NOTICE"
    return 0
  fi
  return 1
}

# --- pure ----------------------------------------------------------------------------------------

# A PR body on stdin → the issue numbers it closes, one per line, sorted. REST has no
# closingIssuesReferences, so the keywords are read from the body (the same regex the graphql path
# falls back to).
gh_rest_closing_refs() {
  grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?) +#[0-9]+' | grep -oE '[0-9]+' | sort -un
}

# Split a comma list into `-f <key>[]=<item>` args on stdout, one arg per line (callers read them
# back with a while loop: no word splitting, so a label with a space survives).
_ghr_array_args() {
  local key="$1" item
  printf '%s\n' "$2" | tr ',' '\n' | while IFS= read -r item; do
    item="$(printf '%s' "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -n "$item" ] && printf -- '-f\n%s[]=%s\n' "$key" "$item"
  done
}

# A read. The output is kept only on rc 0: a failed read is no data (rc 1), never an error body
# taken as a value.
_ghr_read() {
  local out
  out="$(_ghr_api "$@")" || return 1
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# --- issues --------------------------------------------------------------------------------------

gh_rest_issue_json() {
  _ghr_read "repos/$1/issues/$2" --jq '{number, title, body: (.body // ""), state: (.state | ascii_upcase),
    labels: [.labels[]? | {name}],
    milestone: (if .milestone then {title: .milestone.title, number: .milestone.number} else null end)}'
}

gh_rest_issue_state() {
  _ghr_read "repos/$1/issues/$2" --jq '.state | ascii_upcase'
}

gh_rest_milestone_number() {
  local tab n t; tab="$(printf '\t')"
  _ghr_read "repos/$1/milestones" -X GET -f state=all -f per_page=100 \
    --jq '.[] | "\(.number)\t\(.title)"' 2>/dev/null \
    | while IFS="$tab" read -r n t; do [ "$t" = "$2" ] && { printf '%s' "$n"; break; }; done
}

# Create an issue with labels + milestone, then assign it to its author (the REST form of
# `gh issue create --assignee @me`: the token's own login is the author). <assign> 0 skips that.
# Echoes the html_url.
gh_rest_issue_create() {
  local repo="$1" title="$2" body="$3" labels="${4:-}" ms="${5:-}" assign="${6:-1}" msnum="" out num url login a
  local tab; tab="$(printf '\t')"
  set -- -f "title=$title" -f "body=$body"
  while IFS= read -r a; do [ -n "$a" ] && set -- "$@" "$a"; done <<EOF
$(_ghr_array_args labels "$labels")
EOF
  if [ -n "$ms" ]; then
    msnum="$(gh_rest_milestone_number "$repo" "$ms")"
    if [ -n "$msnum" ]; then set -- "$@" -F "milestone=$msnum"
    else echo "cckit: milestone '$ms' not found in $repo — issue created without it" >&2; fi
  fi
  out="$(_ghr_api "repos/$repo/issues" -X POST "$@" \
    --jq '"\(.number)\t\(.html_url)\t\(.user.login // "")"')" || return 1
  IFS="$tab" read -r num url login <<EOF
$out
EOF
  [ -n "$num" ] || return 1
  if [ "$assign" = 1 ] && [ -n "$login" ]; then
    _ghr_api "repos/$repo/issues/$num/assignees" -X POST -f "assignees[]=$login" >/dev/null 2>&1 \
      || echo "cckit: #$num created but not assigned to $login" >&2
  fi
  printf '%s\n' "$url"
}

# Close with a GitHub state_reason (completed | not_planned | duplicate); the comment goes first,
# as `gh issue close --comment` does.
gh_rest_issue_close() {
  local repo="$1" n="$2" reason="${3:-completed}" comment="${4:-}"
  reason="$(printf '%s' "$reason" | tr ' -' '__')"
  if [ -n "$comment" ]; then
    _ghr_api "repos/$repo/issues/$n/comments" -X POST -f "body=$comment" >/dev/null || return 1
  fi
  _ghr_api "repos/$repo/issues/$n" -X PATCH -f state=closed -f "state_reason=$reason" >/dev/null
}

gh_rest_issue_edit_title() {
  _ghr_api "repos/$1/issues/$2" -X PATCH -f "title=$3" >/dev/null
}

gh_rest_issue_set_body() {
  _ghr_api "repos/$1/issues/$2" -X PATCH -f "body=$3" >/dev/null
}

gh_rest_issue_add_labels() {
  local repo="$1" n="$2" labels="${3:-}" a
  set --
  while IFS= read -r a; do [ -n "$a" ] && set -- "$@" "$a"; done <<EOF
$(_ghr_array_args labels "$labels")
EOF
  [ $# -gt 0 ] || return 0
  _ghr_api "repos/$repo/issues/$n/labels" -X POST "$@" >/dev/null
}

# Idempotent: an existing label answers 422, which is fine.
gh_rest_label_create() {
  _ghr_api "repos/$1/labels" -X POST -f "name=$2" -f "color=$3" -f "description=$4" >/dev/null 2>&1 || true
}

# Every label name in the repo, one per line. rc 1 when the list cannot be read.
gh_rest_label_names() {
  _ghr_read "repos/$1/labels" -X GET -f per_page=100 --paginate --jq '.[].name'
}

# gh_rest_issue_comment <repo> <n> <body|@file> → the comment's html_url. Works for PRs too.
gh_rest_issue_comment() {
  case "$3" in
    @*) _ghr_api "repos/$1/issues/$2/comments" -X POST -F "body=$3" --jq .html_url ;;
    *)  _ghr_api "repos/$1/issues/$2/comments" -X POST -f "body=$3" --jq .html_url ;;
  esac
}

# gh_rest_issue_comments <repo> <n> → every comment body, one JSON string per line is not safe for
# multi-line bodies, so bodies are printed raw separated by newlines (as `gh issue view --json
# comments -q '.comments[].body'` did).
gh_rest_issue_comments() {
  _ghr_read "repos/$1/issues/$2/comments" -X GET -f per_page=100 --paginate --jq '.[].body'
}

# gh_rest_label_upsert <repo> <name> <color> <description> → rc 0 "created", rc 0 "updated"
# (the `--force` form of label create): a new label is created, an existing one takes the color
# and description. Prints created|updated. rc 1 when neither worked.
gh_rest_label_upsert() {
  if _ghr_api "repos/$1/labels" -X POST -f "name=$2" -f "color=$3" -f "description=$4" >/dev/null 2>&1; then
    echo created; return 0
  fi
  _ghr_api "repos/$1/labels/$2" -X PATCH -f "color=$3" -f "description=$4" >/dev/null 2>&1 && { echo updated; return 0; }
  return 1
}

# gh_rest_pr_url_for_head <repo> <branch> → the open PR's html_url, or empty.
gh_rest_pr_url_for_head() {
  _ghr_read "repos/$1/pulls" -X GET -f "head=${1%%/*}:$2" -f state=open --jq '.[0].html_url // empty'
}

# gh_rest_repo_default_branch <repo> → the repository's default branch, or rc 1.
gh_rest_repo_default_branch() { _ghr_read "repos/$1" --jq '.default_branch // empty'; }

# gh_rest_user_login → the token's login, or rc 1.
gh_rest_user_login() { _ghr_read user --jq '.login // empty'; }

gh_rest_sub_issue_numbers() {
  _ghr_read "repos/$1/issues/$2/sub_issues" -X GET -f per_page=100 --jq '.[].number'
}

gh_rest_issue_numbers_by_label() {
  _ghr_read "repos/$1/issues" -X GET -f state=open -f "labels=$2" -f per_page=100 \
    --jq '.[] | select(.pull_request | not) | .number'
}

gh_rest_open_issue_titles() {
  _ghr_read "repos/$1/issues" -X GET -f state=open -f per_page=100 --paginate \
    --jq '.[] | select(.pull_request | not) | "\(.number)\t\(.title)"'
}

# --- pull requests -------------------------------------------------------------------------------

# Open a PR, then set labels, milestone and assignee (its author — `--assignee @me`) in one PATCH.
# The PR is the failure that matters; the decoration is best-effort and says so. Echoes the html_url.
gh_rest_pr_create() {
  local repo="$1" base="$2" head="$3" title="$4" body="$5" labels="${6:-}" ms="${7:-}" msnum out num url login a
  local tab; tab="$(printf '\t')"
  out="$(_ghr_api "repos/$repo/pulls" -X POST -f "title=$title" -f "head=$head" -f "base=$base" -f "body=$body" \
    --jq '"\(.number)\t\(.html_url)\t\(.user.login // "")"')" || return 1
  IFS="$tab" read -r num url login <<EOF
$out
EOF
  [ -n "$num" ] || return 1
  set --
  while IFS= read -r a; do [ -n "$a" ] && set -- "$@" "$a"; done <<EOF
$(_ghr_array_args labels "$labels")
EOF
  [ -n "$login" ] && set -- "$@" -f "assignees[]=$login"
  if [ -n "$ms" ]; then
    msnum="$(gh_rest_milestone_number "$repo" "$ms")"
    if [ -n "$msnum" ]; then set -- "$@" -F "milestone=$msnum"
    else echo "cckit: milestone '$ms' not found in $repo — PR opened without it" >&2; fi
  fi
  if [ $# -gt 0 ]; then
    _ghr_api "repos/$repo/issues/$num" -X PATCH "$@" >/dev/null 2>&1 \
      || echo "cckit: PR #$num opened, but its labels/milestone/assignee were not set" >&2
  fi
  printf '%s\n' "$url"
}

gh_rest_pr_for_head() {
  _ghr_read "repos/$1/pulls" -X GET -f "head=${1%%/*}:$2" -f state=open --jq '.[0].number // empty'
}

# The fields the merge path reads, in the graphql vocabulary: mergeable MERGEABLE|CONFLICTING|UNKNOWN
# (REST true|false|null — null while GitHub computes it), mergeStateStatus = REST mergeable_state.
# mergeCommit is {oid} only once MERGED: REST fills merge_commit_sha on an open PR too, with the
# test-merge commit, which is not a commit anyone merged (#360).
gh_rest_pr_json() {
  _ghr_read "repos/$1/pulls/$2" --jq '{
    mergeable: (if .mergeable == true then "MERGEABLE" elif .mergeable == false then "CONFLICTING" else "UNKNOWN" end),
    mergeStateStatus: ((.mergeable_state // "unknown") | ascii_upcase),
    baseRefName: .base.ref, headRefName: .head.ref, body: (.body // ""),
    title: (.title // ""),
    mergeCommit: (if .merged_at then {oid: .merge_commit_sha} else null end),
    state: (if .merged_at then "MERGED" else (.state | ascii_upcase) end)}'
}

gh_rest_pr_commit_subjects() {
  _ghr_read "repos/$1/pulls/$2/commits" -X GET -f per_page=100 --paginate \
    --jq '.[].commit.message | split("\n")[0]'
}

gh_rest_pr_merge() {
  _ghr_api "repos/$1/pulls/$2/merge" -X PUT -f "merge_method=${3:-squash}" >/dev/null
}

gh_rest_pr_closing_issues() {
  _ghr_read "repos/$1/pulls/$2" --jq '.body // ""' 2>/dev/null | gh_rest_closing_refs
}

gh_rest_pr_diff() {
  _ghr_read "repos/$1/pulls/$2" -H 'Accept: application/vnd.github.v3.diff'
}

# The merged PRs that close issue <n> (graphql: closedByPullRequestsReferences, merged only). REST has
# no such link, so: the PRs in <n>'s timeline that cross-reference it, are merged, live in this repo,
# and close it by keyword. One number per line, timeline order.
gh_rest_issue_closing_prs() {
  local repo="$1" n="$2"
  _ghr_read "repos/$repo/issues/$n/timeline" -X GET -f per_page=100 --jq "
    .[] | select(.event == \"cross-referenced\") | .source.issue // empty
    | select(.pull_request.merged_at != null)
    | select((.repository_url // \"\") | endswith(\"/repos/$repo\"))
    | select((.body // \"\") | test(\"(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?) +#$n([^0-9]|\$)\"))
    | .number"
}

# The wave close's per-sub read (graphql: subIssues + closedByPullRequestsReferences): each sub from
# sub_issues, its first merged closing PR, then that PR's merge commit and title. A failed read leaves
# the field empty, so the close refuses (fails closed, as the graphql path does).
gh_rest_wave_rows() {
  local repo="$1" parent="$2" tab sub state pr oid title
  tab="$(printf '\t')"
  _ghr_read "repos/$repo/issues/$parent/sub_issues" -X GET -f per_page=100 \
    --jq '.[] | "\(.number)\t\(.state | ascii_upcase)"' 2>/dev/null \
  | while IFS="$tab" read -r sub state; do
      [ -n "$sub" ] || continue
      oid="" title=""
      pr="$(gh_rest_issue_closing_prs "$repo" "$sub" 2>/dev/null | sed -n 1p)"
      if [ -n "$pr" ]; then
        IFS="$tab" read -r oid title <<EOF
$(_ghr_read "repos/$repo/pulls/$pr" --jq '"\(.merge_commit_sha // "")\t\(.title // "")"' 2>/dev/null)
EOF
      fi
      printf '%s|%s|%s|%s|%s\n' "$sub" "$state" "$pr" "$oid" "$title"
    done
}

# --- Projects v2 board over REST (E546.7) --------------------------------------------------------
# GitHub's REST endpoints for Projects v2, as documented (read 2026-11-24):
#   https://docs.github.com/en/rest/projects/projects   GET {orgs/<org>|users/<user>}/projectsV2/<number>
#   https://docs.github.com/en/rest/projects/fields     GET …/projectsV2/<number>/fields
#   https://docs.github.com/en/rest/projects/items      GET|POST …/projectsV2/<number>/items
#                                                       PATCH …/projectsV2/<number>/items/<item_id>
# The docs send `X-GitHub-Api-Version: 2026-03-10` (CCKIT_BOARD_API_VERSION overrides it).
#   add an item    POST {"type":"Issue"|"PullRequest","owner":"<o>","repo":"<r>","number":<n>} → 201, the item
#   set a field    PATCH {"fields":[{"id":<field id, integer>,"value":<string|number|null>}]} → 200, the item;
#                  a single-select value is the option id, an iteration value the iteration id (strings)
# Field and item ids are integers in REST and node ids (`node_id`) in GraphQL; option and iteration ids
# are strings. A REST item travels as "<id>:<node_id>" so a GraphQL fallback still has its node id.
# The user-owned endpoints do not accept GitHub App tokens.
CCKIT_BOARD_API_VERSION_DEFAULT="2026-03-10"

# _ghr_board <endpoint> [flags…] — one board call. rc 0 with the output; rc 3 when REST cannot serve
# it (HTTP 404, 410, 415 or 501, a transport failure, or an answer the --jq filter rejects), with
# nothing printed; rc 1 on any other HTTP error, the API's message on stderr.
_ghr_board() {
  local err out rc=0 code
  err="$(mktemp)" || return 1
  out="$(_ghr_api "$@" -H "X-GitHub-Api-Version: ${CCKIT_BOARD_API_VERSION:-$CCKIT_BOARD_API_VERSION_DEFAULT}" 2>"$err")" || rc=$?
  if [ "$rc" = 0 ]; then
    rm -f "$err"
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  code="$(sed -nE 's/.*GitHub answered ([0-9]{3}) .*/\1/p' "$err" | sed -n 1p)"
  case "$code" in
    ''|404|410|415|501) rm -f "$err"; return 3 ;;
  esac
  cat "$err" >&2; rm -f "$err"
  return 1
}

# gh_rest_board_base <owner-type> <owner> <number> — the endpoint prefix; rc 3 with an owner or
# number missing or malformed.
gh_rest_board_base() {
  local otype="${1:-user}" owner="${2:-}" num="${3:-}"
  case "$owner" in ''|*[!A-Za-z0-9-]*) return 3 ;; esac
  case "$num" in ''|*[!0-9]*) return 3 ;; esac
  case "$otype" in
    org|organization) printf 'orgs/%s/projectsV2/%s' "$owner" "$num" ;;
    *)                printf 'users/%s/projectsV2/%s' "$owner" "$num" ;;
  esac
}

gh_rest_board_project() {
  _ghr_board "$1" --jq 'if (.node_id | type) == "string" then {id, node_id, number, title} | tojson else error("no project") end'
}

gh_rest_board_fields() {
  _ghr_board "$1/fields" -X GET -f per_page=100 --jq '
    if type != "array" then error("not a field list") else
    [.[] | {id, node_id, name, data_type,
            options: [(.options // [])[] | {id, name: (.name.raw? // .name)}],
            iterations: [((.configuration.iterations // [])[]) | {id, title: (.title.raw? // .title), start_date}]}]
    | tojson end'
}

# gh_rest_board_ids_env <base> — the lines capture-project-ids.sh writes, over REST: PROJECT_ID (the
# project node id), <FIELD>_FIELD_ID (the field node id, which the GraphQL fallback needs too),
# <FIELD>_FIELD_NUM (the REST field id), <FIELD>_OPT_<OPTION> and <FIELD>_ITER_<TITLE>. Names are
# upper-cased, spaces and hyphens become underscores, anything else outside [A-Z0-9_] is dropped.
gh_rest_board_ids_env() {
  local proj fields
  proj="$(gh_rest_board_project "$1")" || return $?
  fields="$(gh_rest_board_fields "$1")" || return $?
  printf 'PROJECT_ID=%s\n' "$(printf '%s' "$proj" | jq -r .node_id)"
  printf '%s' "$fields" | jq -r '
    def n: ascii_upcase | gsub("[ -]"; "_") | gsub("[^A-Z0-9_]"; "");
    .[] | select(.name != null) | (.name | n) as $f | select($f != "")
    | "\($f)_FIELD_ID=\(.node_id // .id)", "\($f)_FIELD_NUM=\(.id)",
      (.options[] | (.name | n) as $o | select($o != "") | "\($f)_OPT_\($o)=\(.id)"),
      (.iterations[] | (.title | n) as $t | select($t != "") | "\($f)_ITER_\($t)=\(.id)")'
}

# gh_rest_board_find_item <base> <Issue|PullRequest> <repo> <n> — the issue's or PR's card on the
# board, as "<id>:<node_id>"; empty (rc 0) when it is not on it. REST has no content-side lookup, so
# this reads the board's items, 100 a page.
gh_rest_board_find_item() {
  local base="$1" type="$2" repo="$3" n="$4" out
  case "$type" in Issue|PullRequest) ;; *) return 3 ;; esac
  case "$n" in ''|*[!0-9]*) return 3 ;; esac
  case "$repo" in */*) ;; *) return 3 ;; esac
  case "$repo" in *[!A-Za-z0-9._/-]*) return 3 ;; esac
  out="$(_ghr_board "$base/items" -X GET -f per_page=100 --paginate --jq "
    if type != \"array\" then error(\"not an item list\") else .[] end
    | select(.content_type == \"$type\")
    | select((.content.number // -1) == $n)
    | select(((.content.repository.full_name // \"$repo\") | ascii_downcase) == (\"$repo\" | ascii_downcase))
    | \"\(.id):\(.node_id // \"\")\"")" || return $?
  printf '%s\n' "$out" | sed '/^$/d' | sed -n 1p
}

# gh_rest_board_find_issue_item <base> <repo> <n> — gh_rest_board_find_item for an issue.
gh_rest_board_find_issue_item() { gh_rest_board_find_item "$1" Issue "$2" "$3"; }

# gh_rest_board_add_item <base> <Issue|PullRequest> <repo> <n> — add an issue or PR; prints
# "<id>:<node_id>" of the new (or existing) item. REST answers 422 "Content already exists in this
# project" when the item is already on the board, where GraphQL's addProjectV2ItemById returned the
# existing item. A board with GitHub's auto-add workflow puts every new issue and PR on the board
# within seconds, so the 422 is the common case there (#590): the existing card is read back instead.
# rc 3 when it cannot be read, so the GraphQL fallback (idempotent) decides.
gh_rest_board_add_item() {
  local base="$1" type="$2" repo="$3" n="$4" err out rc=0
  case "$type" in Issue|PullRequest) ;; *) return 3 ;; esac
  case "$n" in ''|*[!0-9]*) return 3 ;; esac
  case "$repo" in */*) ;; *) return 3 ;; esac
  err="$(mktemp)" || return 1
  out="$(_ghr_board "$base/items" -X POST -f "type=$type" -f "owner=${repo%%/*}" -f "repo=${repo##*/}" -F "number=$n" \
    --jq 'if (.id | type) == "number" then "\(.id):\(.node_id // "")" else error("no item id") end' 2>"$err")" || rc=$?
  if [ "$rc" = 1 ] && grep -q 'GitHub answered 422 .*already exists' "$err"; then
    rm -f "$err"
    out="$(gh_rest_board_find_item "$base" "$type" "$repo" "$n" 2>/dev/null)" || return 3
    [ -n "$out" ] || return 3
    printf '%s\n' "$out"
    return 0
  fi
  cat "$err" >&2; rm -f "$err"
  [ "$rc" = 0 ] || return "$rc"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# gh_rest_board_set_field <base> <item id> <field> <kind> <value> — set one field of one item.
# <field> is the REST field id or its node id (the captured <FIELD>_FIELD_ID); <kind> is
# single_select (value = an option id), iteration (an iteration id) or text. The field is read
# first: a field, option or iteration REST does not list is rc 3, so the GraphQL fallback decides.
gh_rest_board_set_field() {
  local base="$1" item="$2" field="$3" kind="$4" value="$5" fields fnum body
  case "$item" in ''|*[!0-9]*) return 3 ;; esac
  fields="$(gh_rest_board_fields "$base")" || return $?
  fnum="$(printf '%s' "$fields" | jq -r --arg f "$field" --arg k "$kind" --arg v "$value" '
    [.[] | select((.id | tostring) == $f or .node_id == $f)
         | select(if $k == "single_select" then any(.options[]; .id == $v)
                  elif $k == "iteration" then any(.iterations[]; .id == $v)
                  else .data_type == "text" end)
         | .id][0] // empty')"
  case "$fnum" in ''|*[!0-9]*) return 3 ;; esac
  body="$(jq -cn --argjson f "$fnum" --arg v "$value" '{fields: [{id: $f, value: $v}]}')"
  printf '%s' "$body" | _ghr_board "$base/items/$item" -X PATCH --input - \
    --jq 'if (.id | type) == "number" then .id else error("no item") end' >/dev/null
}
