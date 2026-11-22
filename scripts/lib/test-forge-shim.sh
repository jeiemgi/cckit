#!/usr/bin/env bash
# shellcheck shell=bash
# test-forge-shim.sh — the forge stand-in for tests (E537.3). `forge_shim_install <bindir>` writes a
# `curl` that answers like the GitHub REST API and logs every request, plus a `gh` that answers only
# `gh auth token` and fails loudly on any subcommand (a leftover gh call in the code under test is a
# red test, not a silent pass). Source it, call forge_shim_install, put <bindir> first on PATH and
# export the knobs below. The code under test then talks to the forge through the real
# scripts/lib/forge*.sh, over the shim.
#
#   GH_LOG          one line per request: `METHOD <path> <body>` (body: compact JSON, newlines as \036)
#   GH_TITLE        issue title · GH_LABELS issue labels JSON · GH_REPO_LABELS the repo's label list
#   GH_HEAD GH_BASE the PR's branches · GH_MERGEABLE true|false · GH_CLOSED "7 8" closed issue numbers
#   GH_N            counter file for created issue numbers (starts at 50)
#   GH_FAIL_EP      a glob: that path answers 404 (the API error body + message)
#   GH_GRAPHQL      the JSON every POST graphql answers (default {"data":{}})
#   GH_DIFF         the diff every `GET pulls/<n>` with the diff Accept header answers
#   GH_SHIM_TOKEN   what `gh auth token` prints; empty = not signed in (tests usually set GH_TOKEN)
#
# A test that needs other fixtures sets GH_FIXTURE=<file>: a bash snippet sourced by the shim after
# its own case, which may set `out` and `code` for the current `$method $path`.
# errors: strict — the installer fails when <bindir> is not writable
forge_shim_install() {
  local d="${1:?forge_shim_install <bindir>}"
  mkdir -p "$d" || return 1
  cat > "$d/curl" <<'SH'
#!/usr/bin/env bash
method=GET; url=""; body=""; accept=""; hdr=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) case "$2" in Accept:*) accept="$2" ;; esac; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -D) hdr="$2"; shift 2 ;;
    -w|-o|-m|--max-time|--retry|--retry-delay) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
path="${url#*://}"; path="${path#*/}"          # strip scheme and host
{ printf '%s %s %s\n' "$method" "$path" "$(printf '%s' "$body" | jq -c . 2>/dev/null || printf '%s' "$body" | tr '\n' '\036')"; } >> "${GH_LOG:-/dev/null}"
[ -n "$hdr" ] && printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n' > "$hdr"
code=200; out='{}'
# Defaults that contain braces live in variables: a `}` inside `${VAR:-…}` ends the expansion.
_d_graphql='{"data":{}}'
_d_issues='[{"number":99,"title":"[Effort] 99 · demo effort","state":"open","labels":[{"name":"effort"}],"body":""},{"number":5,"title":"PR","state":"open","labels":[],"pull_request":{}}]'
_d_diff="$(printf 'diff --git a/src/app.ts b/src/app.ts\n+app')"
ep="${path%%\?*}"
case "$ep" in ${GH_FAIL_EP:-//never//})
  printf '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}\n404'; exit 0 ;;
esac
next() { n=$(( $(cat "${GH_N:-/dev/null}" 2>/dev/null || echo 49) + 1 )); [ -n "${GH_N:-}" ] && echo "$n" > "$GH_N"; echo "$n"; }
state_of() { case " ${GH_CLOSED:-} " in *" $1 "*) echo closed ;; *) echo open ;; esac; }
case "$method $ep" in
  "POST graphql")                 out="${GH_GRAPHQL:-$_d_graphql}" ;;
  "GET user")                     out='{"login":"me","type":"User"}' ;;
  "GET repos/"*"/labels")         out="${GH_REPO_LABELS:-[]}" ;;
  "POST repos/"*"/labels")        out='{}' ;;
  "GET repos/"*"/milestones")     out='[{"number":2,"title":"M0"},{"number":3,"title":"M1"}]' ;;
  "POST repos/"*"/milestones")    out='{"number":4}' ;;
  "POST repos/"*"/issues/"*"/comments") n="${ep#repos/}"; n="${n#*/*/issues/}"; n="${n%%/*}"; out="{\"html_url\":\"https://github.com/o/r/issues/$n#issuecomment-1\"}" ;;
  "POST repos/"*"/issues/"*"/assignees") out='{}' ;;
  "POST repos/"*"/issues/"*"/labels")    out='[]' ;;
  "GET repos/"*"/issues/"*"/sub_issues") out='[{"number":101,"state":"closed"},{"number":102,"state":"closed"}]' ;;
  "GET repos/"*"/issues/"*"/dependencies/blocked_by") out='[]' ;;
  "POST repos/"*"/issues/"*"/dependencies/blocked_by") out='{}' ;;
  "POST repos/"*"/issues/"*"/sub_issues") out='{}' ;;
  "GET repos/"*"/issues/"*"/timeline")
    sub="${ep#repos/}"; sub="${sub#*/*/issues/}"; sub="${sub%/timeline}"
    out="[{\"event\":\"cross-referenced\",\"source\":{\"issue\":{\"number\":6$sub,\"body\":\"mentions #$sub\",\"repository_url\":\"https://api.github.com/repos/o/r\",\"pull_request\":{\"merged_at\":\"2026-01-01\"}}}},
          {\"event\":\"cross-referenced\",\"source\":{\"issue\":{\"number\":5$sub,\"body\":\"Closes #$sub\",\"repository_url\":\"https://api.github.com/repos/o/r\",\"pull_request\":{\"merged_at\":\"2026-01-01\"}}}}]" ;;
  "POST repos/"*"/issues")        n="$(next)"; out="{\"number\":$n,\"html_url\":\"https://github.com/o/r/issues/$n\",\"user\":{\"login\":\"me\"},\"node_id\":\"I_$n\"}" ;;
  "GET repos/"*"/issues")
    out="${GH_ISSUES:-$_d_issues}"
    # labels=a,b filters as the API does: only issues carrying every listed label.
    case "$path" in *labels=*)
      _lb="${path#*labels=}"; _lb="${_lb%%&*}"; _lb="$(printf '%s' "$_lb" | sed 's/%3A/:/g; s/%2C/,/g; s/%20/ /g')"
      out="$(printf '%s' "$out" | jq -c --arg l "$_lb" '[.[] | select(([.labels[]?.name] | index(($l | split(",")) | .[])) and (($l | split(",")) - [.labels[]?.name] | length == 0))]' 2>/dev/null || printf '%s' "$out")" ;;
    esac ;;
  "PATCH repos/"*"/issues/"*)     n="${ep##*/}"; out="{\"number\":$n,\"state\":\"closed\"}" ;;
  "GET repos/"*"/issues/"*)
    n="${ep##*/}"
    out="{\"number\":$n,\"title\":\"${GH_TITLE:-Fix the thing}\",\"state\":\"$(state_of "$n")\",\"body\":\"${GH_BODY:-## Goal\\nship it}\",\"labels\":${GH_LABELS:-[]},\"milestone\":{\"number\":3,\"title\":\"M1\"},\"user\":{\"login\":\"me\"},\"html_url\":\"https://github.com/o/r/issues/$n\",\"node_id\":\"I_$n\"}" ;;
  "POST repos/"*"/pulls")         out='{"number":7,"html_url":"https://github.com/o/r/pull/7","user":{"login":"me"},"node_id":"PR_7"}' ;;
  "GET repos/"*"/pulls")          out="[{\"number\":9,\"title\":\"feat: sub 9\",\"head\":{\"ref\":\"${GH_HEAD:-fix/9-x}\",\"sha\":\"abc1234def\"},\"base\":{\"ref\":\"${GH_BASE:-develop}\"},\"state\":\"open\",\"merged_at\":null,\"html_url\":\"https://github.com/o/r/pull/9\",\"body\":\"\",\"draft\":false,\"labels\":[]}]" ;;
  "GET repos/"*"/pulls/"*"/commits") out='[{"commit":{"message":"feat: one\n\nbody"}},{"commit":{"message":"fix: two"}}]' ;;
  "GET repos/"*"/pulls/"*"/files")   out='[{"filename":"src/app.ts"}]' ;;
  "PUT repos/"*"/pulls/"*"/merge")   out='{"merged":true,"sha":"deadbeef"}' ;;
  "PATCH repos/"*"/pulls/"*)         out='{}' ;;
  "GET repos/"*"/pulls/"*)
    n="${ep##*/}"
    case "$accept" in *diff*) printf '%s\n200' "${GH_DIFF:-$_d_diff}"; exit 0 ;; esac
    out="{\"number\":$n,\"title\":\"feat: sub $n\",\"mergeable\":${GH_MERGEABLE:-true},\"mergeable_state\":\"clean\",\"base\":{\"ref\":\"${GH_BASE:-develop}\"},\"head\":{\"ref\":\"${GH_HEAD:-fix/9-x}\",\"sha\":\"abc1234def\"},\"body\":\"Closes #42\\nFixes #43\\nsee #44\",\"state\":\"open\",\"merged_at\":null,\"merge_commit_sha\":\"abc1234def\",\"html_url\":\"https://github.com/o/r/pull/$n\",\"node_id\":\"PR_$n\",\"draft\":false,\"labels\":[]}" ;;
  "GET repos/"*"/commits/"*"/check-runs") out='{"check_runs":[]}' ;;
  "GET repos/"*"/commits/"*"/status")     out='{"state":"success","statuses":[]}' ;;
  "GET repos/"*)                  r="${ep#repos/}"; r="${r%%/*}/$(printf '%s' "${ep#repos/*/}" | cut -d/ -f1)"; out="{\"full_name\":\"$r\",\"html_url\":\"https://github.com/$r\",\"ssh_url\":\"git@github.com:$r.git\",\"default_branch\":\"${GH_DEFAULT_BRANCH:-main}\",\"private\":true}" ;;
  "POST user/repos"|"POST orgs/"*"/repos") out='{"full_name":"o/r","html_url":"https://github.com/o/r","ssh_url":"git@github.com:o/r.git"}' ;;
  "PATCH repos/"*)                out='{}' ;;
  "POST repos/"*"/releases")      out='{"html_url":"https://github.com/o/r/releases/tag/v1"}' ;;
esac
[ -n "${GH_FIXTURE:-}" ] && [ -f "$GH_FIXTURE" ] && . "$GH_FIXTURE"
printf '%s\n%s' "$out" "$code"
SH
  cat > "$d/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "auth token") [ -n "${GH_SHIM_TOKEN:-}" ] && { printf '%s\n' "$GH_SHIM_TOKEN"; exit 0; }; exit 1 ;;
  "--version") echo "gh version 2.0.0 (shim)"; exit 0 ;;
esac
echo "gh shim: a gh subcommand was run by the code under test: gh $*" >&2
printf '%s\n' "GH-SUBCOMMAND gh $*" >> "${GH_LOG:-/dev/null}"
exit 97
SH
  chmod +x "$d/curl" "$d/gh"
}
