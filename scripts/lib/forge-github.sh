#!/usr/bin/env bash
# shellcheck shell=bash
# forge-github.sh — the GitHub provider of the forge port (E537.2): REST over curl with a token from
# forge_token. No gh subcommand is run here; `gh` is used only by forge_token to read its token.
#   CCKIT_FORGE_API   the API base (default https://api.github.com); tests point it at a shim
# errors: strict — an HTTP error is rc 1 with the API message on stderr; jq is required for JSON
_fg_api_base() { printf '%s' "${CCKIT_FORGE_API:-https://api.github.com}"; }

# _fg_curl <method> <path> <body-or-empty> [accept] [headers-file]: one request. The body on stdout,
# rc 1 on HTTP >= 400 (the API's message on stderr) or a transport failure. <path> may be a full URL.
_fg_curl() {
  # `rpath`, not `path`: in zsh `path` is the array tied to PATH, and a local by that name hides
  # every command from the function (the delegation brief's zsh gotcha).
  local method="$1" rpath="$2" body="${3:-}" accept="${4:-application/vnd.github+json}" hdr="${5:-}" token out code url
  token="$(forge_token)" || { echo "cckit: no forge token (GH_TOKEN, GITHUB_TOKEN, or gh auth login)" >&2; return 1; }
  case "$rpath" in http://*|https://*) url="$rpath" ;; *) url="$(_fg_api_base)/${rpath#/}" ;; esac
  set -- -sS -X "$method" -H "Authorization: Bearer $token" -H "Accept: $accept" -w '\n%{http_code}'
  [ -n "$hdr" ] && set -- "$@" -D "$hdr"
  if [ -n "$body" ]; then set -- "$@" -H "Content-Type: application/json" --data-binary "$body"; fi
  out="$(curl "$@" "$url")" || return 1
  code="${out##*$'\n'}"; out="${out%$'\n'*}"
  case "$code" in
    2*) [ -n "$out" ] && printf '%s\n' "$out"; return 0 ;;
    *)  printf 'cckit: GitHub answered %s on %s %s: %s\n' "$code" "$method" "${rpath#/}" \
          "$(printf '%s' "$out" | jq -r '.message // .' 2>/dev/null | sed -n 1p)" >&2; return 1 ;;
  esac
}

# forge_api <method> <path> [json-body]: the response body on stdout; rc 1 on an HTTP error.
forge_api() { _fg_curl "$1" "$2" "${3:-}"; }

# forge_graphql <query> [k=v …]: POST /graphql with the query and string variables; a value of the
# form N:<int> is an Int variable. The whole response (data and errors) on stdout, as gh api graphql
# prints it. Unavailable in a cloud session (the proxy refuses GraphQL): see cckit_board_skipped.
forge_graphql() {
  local query="$1" vars='{}' kv k v; shift
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    case "$v" in
      N:*) vars="$(printf '%s' "$vars" | jq --arg k "$k" --argjson v "${v#N:}" '.[$k] = $v')" ;;
      *)   vars="$(printf '%s' "$vars" | jq --arg k "$k" --arg v "$v" '.[$k] = $v')" ;;
    esac
  done
  _fg_curl POST graphql "$(jq -n --arg q "$query" --argjson v "$vars" '{query: $q, variables: $v}')"
}

# forge_rest <endpoint> [gh api flags…]: the `gh api` argument form over curl, so a call site moves
# with its arguments unchanged. Understood: -X|--method, -f|--raw-field k=v (string), -F|--field k=v
# (true|false|null|integer typed, @file reads the file, k[]=v appends), -q|--jq <filter> (applied
# with jq -r, per page), --paginate (follows Link rel=next), -H|--header 'Name: value',
# --input <file|-> (a raw JSON body), --silent. Fields go to the query string on GET and DELETE and
# to a JSON body otherwise; fields with no method mean POST. `graphql` as the endpoint posts the
# query= and variables as forge_graphql does. rc 1 on an HTTP error with nothing on stdout.
forge_rest() {
  local ep="" method="" filter="" paginate=0 accept="application/vnd.github+json" input="" silent=0
  local body='{}' has_field=0 q="" k v raw typed arr
  while [ $# -gt 0 ]; do
    case "$1" in
      -X|--method) method="$2"; shift 2 ;;
      -q|--jq) filter="$2"; shift 2 ;;
      --paginate) paginate=1; shift ;;
      --silent) silent=1; shift ;;
      -H|--header) case "$2" in [Aa]ccept:*) accept="$(printf '%s' "${2#*:}" | sed 's/^ *//')" ;; esac; shift 2 ;;
      --input) input="$2"; shift 2 ;;
      -f|--raw-field|-F|--field)
        raw="$2"; k="${raw%%=*}"; v="${raw#*=}"; has_field=1
        typed=0; [ "$1" = "-F" ] || [ "$1" = "--field" ] && typed=1
        if [ "$typed" = 1 ]; then
          case "$v" in
            @*) v="$(cat "${v#@}")"; typed=0 ;;
            true|false|null) ;;
            ''|*[!0-9-]*) typed=0 ;;
          esac
        fi
        arr=0; case "$k" in *'[]') k="${k%\[\]}"; arr=1 ;; esac
        if [ "$ep" = graphql ] && [ "$k" != query ]; then
          # a GraphQL variable: typed integers travel as Int
          if [ "$typed" = 1 ]; then q="$q${q:+ }$k=N:$v"; else q="$q${q:+ }$k=$v"; fi
        elif [ "$ep" = graphql ]; then
          body="$(printf '%s' "$body" | jq --arg v "$v" '.query = $v')"
        elif [ "$typed" = 1 ]; then
          if [ "$arr" = 1 ]; then body="$(printf '%s' "$body" | jq --arg k "$k" --argjson v "$v" '.[$k] += [$v]')"
          else body="$(printf '%s' "$body" | jq --arg k "$k" --argjson v "$v" '.[$k] = $v')"; fi
        else
          if [ "$arr" = 1 ]; then body="$(printf '%s' "$body" | jq --arg k "$k" --arg v "$v" '.[$k] += [$v]')"
          else body="$(printf '%s' "$body" | jq --arg k "$k" --arg v "$v" '.[$k] = $v')"; fi
        fi
        shift 2 ;;
      -*) shift ;;
      *) if [ -z "$ep" ]; then ep="$1"; fi; shift ;;
    esac
  done
  [ -n "$ep" ] || { echo "forge_rest: an endpoint is required" >&2; return 2; }
  # gh's placeholders for the repository of the current directory's origin remote.
  case "$ep" in *'{owner}'*|*'{repo}'*)
    local _r; _r="$(forge_repo_from_git)" || { echo "forge_rest: {owner}/{repo} needs an origin remote on GitHub" >&2; return 1; }
    ep="$(printf '%s' "$ep" | sed -e "s#{owner}#${_r%%/*}#g" -e "s#{repo}#${_r##*/}#g")" ;;
  esac
  if [ "$ep" = graphql ]; then
    local query; query="$(printf '%s' "$body" | jq -r '.query // ""')"
    # shellcheck disable=SC2086
    out="$(forge_graphql "$query" $q)" || return 1
    [ "$silent" = 1 ] && return 0
    if [ -n "$filter" ]; then printf '%s\n' "$out" | jq -r "$filter"; else printf '%s\n' "$out"; fi
    return 0
  fi
  [ -n "$method" ] || { if [ "$has_field" = 1 ] || [ -n "$input" ]; then method=POST; else method=GET; fi; }
  local send="" url="${ep#/}" out hdr next
  if [ -n "$input" ]; then
    if [ "$input" = "-" ]; then send="$(cat)"; else send="$(cat "$input")"; fi
  elif [ "$has_field" = 1 ]; then
    case "$method" in
      GET|DELETE)
        local qs; qs="$(printf '%s' "$body" | jq -r 'to_entries | map("\(.key)=\(.value|tostring|@uri)") | join("&")')"
        case "$url" in *\?*) url="$url&$qs" ;; *) url="$url?$qs" ;; esac ;;
      *) send="$body" ;;
    esac
  fi
  hdr="$(mktemp)"; local frc=0
  while :; do
    out="$(_fg_curl "$method" "$url" "$send" "$accept" "$hdr")" || { rm -f "$hdr"; return 1; }
    if [ "$silent" != 1 ]; then
      # A --jq that fails (a non-JSON 200 body) is a failed read, rc 1, not an empty answer.
      if [ -n "$filter" ]; then printf '%s\n' "$out" | jq -r "$filter" || frc=1; else printf '%s\n' "$out"; fi
    fi
    [ "$paginate" = 1 ] || break
    next="$(tr -d '\r' < "$hdr" | sed -nE 's/^[Ll]ink: .*<([^>]+)>; rel="next".*/\1/p' | sed -n 1p)"
    [ -n "$next" ] || break
    url="$next"
  done
  rm -f "$hdr"
  return "$frc"
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
    base: .base.ref, head: .head.ref, head_sha: .head.sha, mergeable, merged, url: .html_url}'
}

forge_pr_merge() {
  forge_api PUT "repos/$1/pulls/$2/merge" "$(jq -n --arg m "${3:-squash}" '{merge_method: $m}')" >/dev/null
}

forge_pr_list() {
  local repo="$1" state="${2:-open}" head="${3:-}" q="state=$state&per_page=100"
  [ -n "$head" ] && q="$q&head=${repo%%/*}:$head"
  _fg_json GET "repos/$repo/pulls?$q" "" '[.[] | {number, title, state: (.state|ascii_upcase), head: .head.ref, base: .base.ref, url: .html_url}]'
}

# --- the gh CLI, inside the layer -----------------------------------------------------------------
# gh is OPTIONAL: it is how a person gets a token interactively, and nothing else here needs it.
forge_cli_present() { command -v gh >/dev/null 2>&1; }
forge_cli_version() { gh --version 2>/dev/null | sed -n 1p | awk '{print $3}'; }
# forge_login: an interactive sign-in. With gh installed it runs `gh auth login`; without, it says
# how to provide a token. rc 1 when no token resolves afterwards.
forge_login() {
  if forge_cli_present; then gh auth login --git-credential-helper || return 1
  else
    echo "cckit: no gh installed — put a token in GH_TOKEN (a fine-grained token with Issues, Pull requests and Contents on the repository), or install gh and run gh auth login" >&2
    return 1
  fi
  forge_token >/dev/null 2>&1
}
# forge_login_scope <scope>: add an OAuth scope to gh's token (`gh auth refresh -s <scope>`). rc 1
# without gh, where the token in GH_TOKEN is the user's to re-issue.
forge_login_scope() {
  forge_cli_present || { echo "cckit: scope '$1' is added to a gh token with gh auth refresh -s $1; a GH_TOKEN is re-issued with it" >&2; return 1; }
  gh auth refresh -s "$1"
}
# forge_token_scopes: the token's OAuth scopes (X-OAuth-Scopes), comma-separated; empty for a
# fine-grained token, which carries none.
forge_token_scopes() {
  local token; token="$(forge_token)" || return 1
  curl -sS -I -H "Authorization: Bearer $token" "$(_fg_api_base)/user" 2>/dev/null \
    | tr -d '\r' | sed -nE 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: *//p' | sed -n 1p
}
