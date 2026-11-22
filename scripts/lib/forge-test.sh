#!/usr/bin/env bash
# shellcheck shell=bash
# forge-test.sh — E537.2: the forge port. Provider selection (env, config, token, default), the none
# provider refuses every call with one line naming the verb, and the github provider speaks REST
# over curl with a bearer token and never runs a gh subcommand. Hermetic: a curl shim on PATH logs
# every request and answers fixtures; a gh shim stands in for an installed gh.
# Run: bash scripts/lib/forge-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$LIB/test-env.sh" && test_env_seal
unset GH_TOKEN GITHUB_TOKEN CCKIT_FORGE CCKIT_VERB KIT_CONFIG
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tc() { if grep -qE -- "$2" "$1"; then echo "ok: $3"; else echo "FAIL: $3 (no /$2/ in $1)"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "forge-test: jq required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/proj"
export CURL_LOG="$tmp/curl.log"; : > "$CURL_LOG"
export GH_SHIM_TOKEN=""   # what the gh shim answers to `gh auth token` (empty = not signed in)

cat > "$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
# logs: METHOD URL BODY AUTH, answers a fixture by URL, ends with the http code like -w '\n%{http_code}'
method=GET; url=""; body=""; auth=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H) case "$2" in Authorization:*) auth="$2" ;; esac; shift 2 ;;
    --data-binary) body="$2"; shift 2 ;;
    -w|-o) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
{ printf '%s %s %s %s\n' "$method" "$url" "$(printf '%s' "$body" | tr '\n' ' ')" "$auth"; } >> "$CURL_LOG"
code=200
case "$method $url" in
  "GET "*"/milestones?"*)      out='[{"number":4,"title":"v1"},{"number":9,"title":"v2"}]' ;;
  "GET "*"/issues/404")        code=404; out='{"message":"Not Found"}' ;;
  "GET "*"/issues/7")          out='{"number":7,"title":"Seven","body":null,"state":"open","labels":[{"name":"kind:fix"}],"milestone":{"title":"v2","number":9},"html_url":"https://x/issues/7"}' ;;
  "GET "*"/issues?"*)          out='[{"number":7,"title":"Seven","state":"open","labels":[]},{"number":8,"title":"A PR","state":"open","labels":[],"pull_request":{}}]' ;;
  "POST "*"/issues/"*"/comments") out='{"html_url":"https://x/issues/7#c1"}' ;;
  "POST "*"/issues/"*"/labels") out='[]' ;;
  "POST "*"/issues")            out='{"number":12,"html_url":"https://x/issues/12"}' ;;
  "PATCH "*"/issues/"*)         out='{"state":"closed"}' ;;
  "POST "*"/pulls")             out='{"number":30,"html_url":"https://x/pull/30"}' ;;
  "GET "*"/pulls?"*"head="*)    out='[{"number":30}]' ;;
  "GET "*"/pulls?"*)            out='[{"number":30,"title":"P","state":"open","head":{"ref":"fix/1-x"},"base":{"ref":"develop"},"html_url":"https://x/pull/30"}]' ;;
  "GET "*"/pulls/30")           out='{"number":30,"title":"P","body":"b","state":"open","base":{"ref":"develop"},"head":{"ref":"fix/1-x"},"mergeable":true,"merged":false,"html_url":"https://x/pull/30"}' ;;
  "PUT "*"/pulls/30/merge")     out='{"merged":true}' ;;
  *) code=500; out='{"message":"unexpected '"$method $url"'"}' ;;
esac
printf '%s\n%s' "$out" "$code"
SH
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "auth token") [ -n "${GH_SHIM_TOKEN:-}" ] && { printf '%s\n' "$GH_SHIM_TOKEN"; exit 0; }; exit 1 ;;
  *) echo "gh shim: a gh subcommand was run: $*" >&2; exit 97 ;;
esac
SH
chmod +x "$tmp/bin/curl" "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"

# run <env…> -- <function> <args…>: in a fresh bash with the port loaded; stdout to $tmp/out, stderr to $tmp/err
run() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  env "${envs[@]+"${envs[@]}"}" bash -c '. "$0/forge.sh"; forge_load; "$@"' "$LIB" "$@" >"$tmp/out" 2>"$tmp/err"
}

# --- provider selection -------------------------------------------------------------------------
t "CCKIT_FORGE=none wins" "$(CCKIT_FORGE=none bash -c '. "$0/forge.sh"; forge_provider' "$LIB")" "none"
t "CCKIT_FORGE=github wins" "$(CCKIT_FORGE=github bash -c '. "$0/forge.sh"; forge_provider' "$LIB")" "github"
echo '{"forge":{"provider":"github"}}' > "$tmp/proj/cckit.config.json"
t "config forge.provider is read" "$(cd "$tmp/proj" && bash -c '. "$0/forge.sh"; forge_provider' "$LIB")" "github"
echo '{"forge":{"provider":"none"}}' > "$tmp/proj/cckit.config.json"
t "config none even with a token" "$(cd "$tmp/proj" && GH_TOKEN=t bash -c '. "$0/forge.sh"; forge_provider' "$LIB")" "none"
echo '{}' > "$tmp/proj/cckit.config.json"
t "unset: a GH_TOKEN selects github" "$(cd "$tmp/proj" && GH_TOKEN=t bash -c '. "$0/forge.sh"; forge_provider' "$LIB")" "github"
t "unset: a GITHUB_TOKEN selects github" "$(cd "$tmp/proj" && GITHUB_TOKEN=t bash -c '. "$0/forge.sh"; forge_provider' "$LIB")" "github"
t "unset: a signed-in gh selects github" "$(cd "$tmp/proj" && GH_SHIM_TOKEN=ghs bash -c '. "$0/forge.sh"; forge_provider' "$LIB")" "github"
t "unset: no token anywhere selects none" "$(cd "$tmp/proj" && bash -c '. "$0/forge.sh"; forge_provider' "$LIB")" "none"
echo '{"forge":{"provider":"gitlab"}}' > "$tmp/proj/cckit.config.json"
out="$(cd "$tmp/proj" && bash -c '. "$0/forge.sh"; forge_provider' "$LIB" 2>"$tmp/err")"
t "an unknown provider falls to the default" "$out" "none"
tc "$tmp/err" "forge.provider must be github or none" "an unknown provider warns once"
echo '{}' > "$tmp/proj/cckit.config.json"

# --- none refuses, naming the verb --------------------------------------------------------------
cd "$tmp/proj"
run CCKIT_FORGE=none CCKIT_VERB=pr -- forge_issue_view o/r 7; rc=$?
t "none: forge_issue_view is rc 1" "$rc" "1"
t "none: nothing on stdout" "$(cat "$tmp/out")" ""
tc "$tmp/err" "^cckit pr: needs a forge \(GitHub\)" "none: the one line names the verb from CCKIT_VERB"
tc "$tmp/err" "git steps of pr run without one" "none: the line says the git steps still run"
run CCKIT_FORGE=none -- forge_need merge; rc=$?
t "forge_need <verb> rc 1 without a forge" "$rc" "1"
tc "$tmp/err" "^cckit merge: needs a forge" "forge_need names the verb it was given"
run CCKIT_FORGE=none -- forge_pr_merge o/r 30; t "none: forge_pr_merge rc 1" "$?" "1"
run CCKIT_FORGE=none -- forge_api GET repos/o/r; t "none: forge_api rc 1" "$?" "1"
t "none: no curl request was made" "$(wc -l < "$CURL_LOG" | tr -d ' ')" "0"
run CCKIT_FORGE=github GH_TOKEN=t -- forge_need pr; t "forge_need rc 0 with a forge" "$?" "0"
run CCKIT_FORGE=github GH_TOKEN=t -- forge_available; t "forge_available rc 0 with a forge" "$?" "0"

# --- github: REST over curl ----------------------------------------------------------------------
G=(CCKIT_FORGE=github GH_TOKEN=tok-1 CCKIT_FORGE_API=https://api.test)
run "${G[@]}" -- forge_issue_view o/r 7; t "issue_view rc" "$?" "0"
t "issue_view shape" "$(jq -c '{number,title,body,state,labels,milestone,url}' "$tmp/out")" \
  '{"number":7,"title":"Seven","body":"","state":"OPEN","labels":[{"name":"kind:fix"}],"milestone":{"title":"v2","number":9},"url":"https://x/issues/7"}'
tc "$CURL_LOG" "^GET https://api.test/repos/o/r/issues/7  Authorization: Bearer tok-1$" "issue_view: GET with the bearer token, no body"

: > "$CURL_LOG"
run "${G[@]}" -- forge_issue_create o/r "T" "B" "kind:fix, role:docs" v2; t "issue_create rc" "$?" "0"
t "issue_create prints the url" "$(cat "$tmp/out")" "https://x/issues/12"
tc "$CURL_LOG" "^GET https://api.test/repos/o/r/milestones" "issue_create resolves the milestone by title"
t "issue_create payload" "$(grep '^POST .*/issues ' "$CURL_LOG" | sed -E 's/^POST [^ ]+ (.*) Authorization.*/\1/' | jq -c .)" \
  '{"title":"T","body":"B","labels":["kind:fix","role:docs"],"milestone":9}'

: > "$CURL_LOG"
run "${G[@]}" -- forge_issue_close o/r 7 not_planned "bye"; t "issue_close rc" "$?" "0"
t "issue_close: comment then PATCH" "$(awk '{print $1}' "$CURL_LOG" | tr '\n' ' ')" "POST PATCH "
t "issue_close payload" "$(grep '^PATCH' "$CURL_LOG" | sed -E 's/^PATCH [^ ]+ (.*) Authorization.*/\1/' | jq -c .)" '{"state":"closed","state_reason":"not_planned"}'

: > "$CURL_LOG"
run "${G[@]}" -- forge_issue_comment o/r 7 "hello"; t "issue_comment prints the url" "$(cat "$tmp/out")" "https://x/issues/7#c1"
run "${G[@]}" -- forge_issue_label o/r 7 "a,b"; t "issue_label rc" "$?" "0"
t "issue_label payload" "$(grep '/labels ' "$CURL_LOG" | sed -E 's/^POST [^ ]+ (.*) Authorization.*/\1/' | jq -c .)" '{"labels":["a","b"]}'
run "${G[@]}" -- forge_issue_list o/r open "kind:fix"; t "issue_list drops pull requests" "$(jq -c '[.[].number]' "$tmp/out")" "[7]"
tc "$CURL_LOG" "issues\?state=open&per_page=100&labels=kind:fix" "issue_list passes state and labels"

: > "$CURL_LOG"
run "${G[@]}" -- forge_pr_open o/r develop fix/1-x "T" "B" "size:S"; t "pr_open rc" "$?" "0"
t "pr_open prints the url" "$(cat "$tmp/out")" "https://x/pull/30"
t "pr_open: POST pulls then labels" "$(awk '{print $1, $2}' "$CURL_LOG" | sed 's#https://api.test##' | tr '\n' ';')" "POST /repos/o/r/pulls;POST /repos/o/r/issues/30/labels;"
run "${G[@]}" -- forge_pr_view o/r 30; t "pr_view by number" "$(jq -c '{number,base,head,mergeable,merged}' "$tmp/out")" '{"number":30,"base":"develop","head":"fix/1-x","mergeable":true,"merged":false}'
: > "$CURL_LOG"
run "${G[@]}" -- forge_pr_view o/r fix/1-x; t "pr_view by head branch" "$(jq -r .number "$tmp/out")" "30"
tc "$CURL_LOG" "pulls\?state=all&head=o:fix/1-x" "pr_view resolves the head as owner:branch"
run "${G[@]}" -- forge_pr_merge o/r 30 merge; t "pr_merge rc" "$?" "0"
t "pr_merge payload" "$(grep '^PUT' "$CURL_LOG" | sed -E 's/^PUT [^ ]+ (.*) Authorization.*/\1/' | jq -c .)" '{"merge_method":"merge"}'
run "${G[@]}" -- forge_pr_list o/r open; t "pr_list shape" "$(jq -c '.[0] | {number,head,base}' "$tmp/out")" '{"number":30,"head":"fix/1-x","base":"develop"}'

run "${G[@]}" -- forge_issue_view o/r 404; t "an HTTP error is rc 1" "$?" "1"
t "an HTTP error leaves stdout empty" "$(cat "$tmp/out")" ""
tc "$tmp/err" "GitHub answered 404 on GET repos/o/r/issues/404: Not Found" "an HTTP error names code, call and message"
run CCKIT_FORGE=github -- forge_api GET repos/o/r; t "github with no token is rc 1" "$?" "1"
tc "$tmp/err" "no forge token" "github with no token says so"
t "no gh subcommand ran in the github provider" "$(grep -c 'gh shim: a gh subcommand' "$tmp/err" "$CURL_LOG" | awk -F: '{s+=$2} END{print s}')" "0"

# --- the layer is the port: no gh subcommand in forge-github.sh; forge-report leaves the layer out
t "forge-github.sh runs no gh subcommand" "$(grep -vE '^[[:space:]]*#' "$LIB/forge-github.sh" | grep -cE '(^|[;&|({`]|\$\(|if|then|do|exec)[[:space:]]*gh (api|pr|issue|repo|auth|label)')" "0"
t "forge-report lists the layer and keeps it out of the ratchet" \
  "$(bash "$LIB/../forge-report.sh" --files | awk '$1 ~ /scripts\/lib\/forge/ {print $1}' | sort | tr '\n' ' ')" \
  "scripts/lib/forge-github.sh scripts/lib/forge-none.sh scripts/lib/forge.sh "

[ "$fail" -eq 0 ] && echo "ALL OK (forge)"
exit "$fail"
