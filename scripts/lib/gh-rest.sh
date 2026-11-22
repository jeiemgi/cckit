#!/usr/bin/env bash
# shellcheck shell=bash
# gh-rest.sh — the REST forms of the lifecycle calls, over the forge port (E537.3; #396 before it).
#
# Every call here is `forge_rest repos/<owner>/<repo>/…` (scripts/lib/forge.sh), endpoint first: REST
# over curl with a token, no gh subcommand. REST is the ONLY transport now — the gh-subcommand
# (GraphQL) transport of #396 is gone, so `cckit_gh_rest` is always true and `CCKIT_GH_TRANSPORT`
# does nothing but warn once. What still depends on where cckit runs is GraphQL itself: a cloud
# agent session reaches GitHub through a proxy that refuses it (403), and Projects v2 is GraphQL-only,
# so board steps are skipped there with ONE notice line (exit 0, never a failure). They are skipped
# the same way when the forge provider is `none`.
#
#   cckit_gh_rest                         rc 0 (kept for callers; REST is the only transport)
#   cckit_gh_transport                    echo rest
#   cckit_board_skipped                   rc 0 iff board steps are skipped (prints the notice once):
#                                         CLAUDE_CODE_REMOTE=true, CCKIT_GRAPHQL=0, or no forge
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
# Not reachable in the cloud: Projects v2 (skipped), and remote branch deletion (the proxy rejects
# DELETE git/refs) — callers keep the branch and say so.
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

# rc 0 when board steps (Projects v2, GraphQL-only) are skipped: a cloud session, CCKIT_GRAPHQL=0,
# or no forge. Prints the notice at most once per process.
cckit_board_skipped() {
  local why=""
  if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || [ "${CCKIT_GRAPHQL:-1}" = "0" ]; then why="$CCKIT_BOARD_SKIP_NOTICE"
  elif command -v forge_available >/dev/null 2>&1 && ! forge_available; then why="$CCKIT_BOARD_SKIP_NOTICE_NOFORGE"
  else return 1; fi
  if [ -z "${_CCKIT_BOARD_NOTICE_DONE:-}" ]; then
    printf '%s\n' "$why" >&2
    _CCKIT_BOARD_NOTICE_DONE=1
  fi
  return 0
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
