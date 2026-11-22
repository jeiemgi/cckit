#!/usr/bin/env bash
# shellcheck shell=bash
# forge-github.sh — the GitHub provider of the forge port (E537.2): REST over curl with a token from
# forge_token. No gh subcommand is run here; `gh` is used only by forge_token to read its token.
#   CCKIT_FORGE_API   the API base (default https://api.github.com); tests point it at a shim
# errors: strict — an HTTP error is rc 1 with the API message on stderr; jq is required for JSON
_fg_api_base() { printf '%s' "${CCKIT_FORGE_API:-https://api.github.com}"; }

# forge_api <method> <path> [json-body]: the response body on stdout. rc 1 on HTTP >= 400 (the API's
# message on stderr) or a transport failure.
forge_api() {
  local method="$1" path="$2" body="${3:-}" token out code
  token="$(forge_token)" || { echo "cckit: no forge token (GH_TOKEN, GITHUB_TOKEN, or gh auth login)" >&2; return 1; }
  path="${path#/}"
  if [ -n "$body" ]; then
    out="$(curl -sS -X "$method" -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" \
      -H "Content-Type: application/json" -w '\n%{http_code}' --data-binary "$body" "$(_fg_api_base)/$path")" || return 1
  else
    out="$(curl -sS -X "$method" -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" \
      -w '\n%{http_code}' "$(_fg_api_base)/$path")" || return 1
  fi
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  case "$code" in
    2*) [ -n "$out" ] && printf '%s\n' "$out"; return 0 ;;
    *)  printf 'cckit: GitHub answered %s on %s %s: %s\n' "$code" "$method" "$path" \
          "$(printf '%s' "$out" | jq -r '.message // .' 2>/dev/null | sed -n 1p)" >&2; return 1 ;;
  esac
}

# _fg_json <method> <path> <body-or-empty> <jq-filter>: the call, then the filter. The call is
# captured first so an HTTP error is rc 1 whether or not the caller set pipefail.
_fg_json() {
  local out
  out="$(forge_api "$1" "$2" "$3")" || return 1
  printf '%s\n' "$out" | jq "$4"
}
_fg_jq_r() { # same, raw output
  local out
  out="$(forge_api "$1" "$2" "$3")" || return 1
  printf '%s\n' "$out" | jq -r "$4"
}

_fg_labels_json() { # csv → ["a","b"]
  printf '%s' "${1:-}" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d' | jq -R . | jq -sc .
}
_fg_milestone_number() { # <repo> <title> → number or empty
  [ -n "${2:-}" ] || return 0
  local out
  out="$(forge_api GET "repos/$1/milestones?state=all&per_page=100")" || return 1
  printf '%s\n' "$out" | jq -r --arg t "$2" '.[] | select(.title==$t) | .number' | sed -n 1p
}

forge_issue_view() {
  _fg_json GET "repos/$1/issues/$2" "" '{number, title, body: (.body // ""), state: (.state | ascii_upcase),
    labels: [.labels[]? | {name}],
    milestone: (if .milestone then {title: .milestone.title, number: .milestone.number} else null end),
    url: .html_url}'
}

forge_issue_create() {
  local repo="$1" title="$2" body="$3" labels="${4:-}" ms="${5:-}" msnum payload
  msnum="$(_fg_milestone_number "$repo" "$ms")" || return 1
  payload="$(jq -n --arg t "$title" --arg b "$body" --argjson l "$(_fg_labels_json "$labels")" --arg m "$msnum" \
    '{title: $t, body: $b, labels: $l} + (if $m != "" then {milestone: ($m|tonumber)} else {} end)')"
  _fg_jq_r POST "repos/$repo/issues" "$payload" .html_url
}

forge_issue_close() {
  local repo="$1" n="$2" reason="${3:-completed}" comment="${4:-}"
  if [ -n "$comment" ]; then forge_issue_comment "$repo" "$n" "$comment" >/dev/null || return 1; fi
  forge_api PATCH "repos/$repo/issues/$n" "$(jq -n --arg r "$reason" '{state: "closed", state_reason: $r}')" >/dev/null
}

forge_issue_comment() {
  _fg_jq_r POST "repos/$1/issues/$2/comments" "$(jq -n --arg b "$3" '{body: $b}')" .html_url
}

forge_issue_label() {
  forge_api POST "repos/$1/issues/$2/labels" "$(jq -n --argjson l "$(_fg_labels_json "$3")" '{labels: $l}')" >/dev/null
}

forge_issue_list() {
  local repo="$1" state="${2:-open}" labels="${3:-}" q
  q="state=$state&per_page=100"
  [ -n "$labels" ] && q="$q&labels=$(printf '%s' "$labels" | sed 's/ //g')"
  _fg_json GET "repos/$repo/issues?$q" "" '[.[] | select(.pull_request == null) | {number, title, state: (.state|ascii_upcase), labels: [.labels[]? | {name}]}]'
}

forge_pr_open() {
  local repo="$1" base="$2" head="$3" title="$4" body="$5" labels="${6:-}" out num
  out="$(forge_api POST "repos/$repo/pulls" "$(jq -n --arg t "$title" --arg b "$body" --arg base "$base" --arg head "$head" '{title: $t, body: $b, base: $base, head: $head}')")" || return 1
  num="$(printf '%s' "$out" | jq -r .number)"
  if [ -n "$labels" ]; then forge_issue_label "$repo" "$num" "$labels" || true; fi
  printf '%s' "$out" | jq -r .html_url
}

forge_pr_view() {
  local repo="$1" ref="$2" n
  n="$ref"
  case "$ref" in
    *[!0-9]*) n="$(_fg_jq_r GET "repos/$repo/pulls?state=all&head=${repo%%/*}:$ref&per_page=1" "" '.[0].number // empty')" || return 1
              [ -n "$n" ] || { echo "cckit: no pull request from $ref in $repo" >&2; return 1; } ;;
  esac
  _fg_json GET "repos/$repo/pulls/$n" "" '{number, title, body: (.body // ""), state: (.state|ascii_upcase),
    base: .base.ref, head: .head.ref, mergeable, merged, url: .html_url}'
}

forge_pr_merge() {
  forge_api PUT "repos/$1/pulls/$2/merge" "$(jq -n --arg m "${3:-squash}" '{merge_method: $m}')" >/dev/null
}

forge_pr_list() {
  local repo="$1" state="${2:-open}" head="${3:-}" q="state=$state&per_page=100"
  [ -n "$head" ] && q="$q&head=${repo%%/*}:$head"
  _fg_json GET "repos/$repo/pulls?$q" "" '[.[] | {number, title, state: (.state|ascii_upcase), head: .head.ref, base: .base.ref, url: .html_url}]'
}
