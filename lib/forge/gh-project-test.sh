#!/usr/bin/env bash
# shellcheck shell=bash
# gh-project-test.sh — covers the board owner-type resolution adoption needs (#118). A Projects v2
# board can live under a USER login or an ORGANIZATION login, and each needs a different GraphQL root
# (user(login:) vs organization(login:)). A user-only query silently returns null for an org board.
# Covered: _ghp_owner_root resolution, kit-config exporting KIT_PROJECT_OWNER_TYPE, and
# capture-project-ids.sh selecting the matching root end-to-end (over the forge shim — no network).
# Run:  bash lib/forge/gh-project-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/lib"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '$2' lacks '$3'"; fail=1 ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "gh-project-test: jq required — skipping"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# ── _ghp_owner_root resolves from KIT_PROJECT_OWNER_TYPE ───────────────────────────────────────
# shellcheck source=/dev/null
( KIT_PROJECT_OWNER_TYPE=organization; source "$LIB/forge/gh-project.sh"; [ "$(_ghp_owner_root)" = organization ] ) \
  && echo "ok: owner_root=organization for org type" || { echo "FAIL: org owner_root"; fail=1; }
( KIT_PROJECT_OWNER_TYPE=org; source "$LIB/forge/gh-project.sh"; [ "$(_ghp_owner_root)" = organization ] ) \
  && echo "ok: owner_root=organization for 'org' shorthand" || { echo "FAIL: org shorthand"; fail=1; }
( unset KIT_PROJECT_OWNER_TYPE; KIT_CONFIG=/nonexistent; source "$LIB/forge/gh-project.sh"; [ "$(_ghp_owner_root)" = user ] ) \
  && echo "ok: owner_root=user by default" || { echo "FAIL: default user owner_root"; fail=1; }

# ── kit-config exports KIT_PROJECT_OWNER_TYPE from config ──────────────────────────────────────
printf '%s' '{"github":{"projectOwnerType":"organization"}}' > "$tmp/org.json"
got="$(KIT_CONFIG="$tmp/org.json" bash -c "source '$LIB/core/kit-config.sh'; load_kit_config >/dev/null 2>&1; printf '%s' \"\$KIT_PROJECT_OWNER_TYPE\"")"
t "kit-config exports owner type from config" "$got" "organization"
printf '%s' '{"github":{}}' > "$tmp/none.json"
got="$(KIT_CONFIG="$tmp/none.json" bash -c "source '$LIB/core/kit-config.sh'; load_kit_config >/dev/null 2>&1; printf '%s' \"\$KIT_PROJECT_OWNER_TYPE\"")"
t "kit-config defaults owner type to user" "$got" "user"

# ── capture-project-ids.sh selects the matching GraphQL root (over the forge shim) ──────────────
# Isolated scripts dir in an installed project's flat layout: a copy of the script + a scripts/lib/
# of links to the real layered libs, so $0-relative sourcing + OUT path stay inside tmp. The shim's curl logs every request — a GraphQL call is ONE
# `POST graphql {"query":…,"variables":{…}}` line — and a fixture reads the query root out of the
# body and answers JSON under that same root.
mkdir -p "$tmp/scripts" "$tmp/bin"
cp "$ROOT/lib/verbs/capture-project-ids.sh" "$tmp/scripts/"
mkdir -p "$tmp/scripts/lib"
for f in "$LIB"/core/*.sh "$LIB"/forge/*.sh "$LIB"/verbs/*.sh; do ln -s "$f" "$tmp/scripts/lib/"; done
# shellcheck source=/dev/null
. "$LIB/forge/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export GH_TOKEN=test-token CCKIT_FORGE=github GH_LOG="$tmp/gh.log"
cat > "$tmp/root-fixture.sh" <<'SH'
case "$method $ep" in "POST graphql")
  q="$(printf '%s' "$body" | jq -r '.query // ""')"
  case "$q" in *"organization(login"*) root=organization ;; *) root=user ;; esac
  out="{\"data\":{\"$root\":{\"projectV2\":{\"id\":\"PVT_org123\",\"fields\":{\"nodes\":[
  {\"__typename\":\"ProjectV2SingleSelectField\",\"id\":\"F_status\",\"name\":\"Status\",\"options\":[{\"id\":\"O_todo\",\"name\":\"Todo\"}]},
  {\"__typename\":\"ProjectV2FieldCommon\",\"id\":\"F_plan\",\"name\":\"Plan Link\"}
]}}}}}" ;;
esac
SH

run_capture() {  # <owner-type>
  printf '%s' "{\"github\":{\"projectsV2\":true,\"owner\":\"acme\",\"projectNumber\":3,\"projectOwnerType\":\"$1\"}}" > "$tmp/cfg.json"
  : > "$GH_LOG"
  GH_FIXTURE="$tmp/root-fixture.sh" KIT_CONFIG="$tmp/cfg.json" PATH="$tmp/bin:$PATH" \
    bash "$tmp/scripts/capture-project-ids.sh" >/dev/null 2>&1
}

run_capture organization
rc=$?
t "capture rc 0 (org board)" "$rc" "0"
has "capture uses organization root for an org board" "$(cat "$GH_LOG")" "organization(login"
t   "capture is one GraphQL POST, no gh subcommand" "$(grep -c '^POST graphql ' "$GH_LOG"):$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "1:0"
has "capture sends the login and the number as variables" "$(cat "$GH_LOG")" '"variables":{"login":"acme","number":3}'
[ -f "$tmp/scripts/.project-ids.env" ] && has "org capture wrote PROJECT_ID" "$(cat "$tmp/scripts/.project-ids.env")" "PROJECT_ID=PVT_org123" || { echo "FAIL: no env written (org)"; fail=1; }
has "org capture wrote a field id" "$(cat "$tmp/scripts/.project-ids.env" 2>/dev/null)" "STATUS_FIELD_ID=F_status"
rm -f "$tmp/scripts/.project-ids.env"

run_capture user
has "capture uses user root for a user board" "$(cat "$GH_LOG")" "user(login"

# ── project_issue_status: read an issue's board Status via the cheap issue.projectItems query (#124) ─
# The issue.projectItems Status query: issue is "In Progress" on project #3 (and Todo on some other).
# GH_GRAPHQL is what the shim answers to every POST graphql.
export GH_GRAPHQL='{"data":{"repository":{"issue":{"projectItems":{"nodes":[
  {"project":{"number":7},"fieldValueByName":{"name":"Todo"}},
  {"project":{"number":3},"fieldValueByName":{"name":"In Progress"}}
]}}}}}'
: > "$GH_LOG"
st="$(PATH="$tmp/bin:$PATH" KIT_REPO="acme/app" KIT_PROJECT_NUMBER=3 bash -c "source '$LIB/forge/gh-project.sh'; project_issue_status 42")"
t "project_issue_status returns the board Status for our project" "$st" "In Progress"
has "project_issue_status asks for issue 42 of acme/app" "$(cat "$GH_LOG")" '"variables":{"o":"acme","r":"app","n":42}'
# unresolved repo/number -> non-zero, no guess.
PATH="$tmp/bin:$PATH" KIT_REPO="" KIT_PROJECT_NUMBER="" bash -c "source '$LIB/forge/gh-project.sh'; project_issue_status 42" >/dev/null 2>&1
t "project_issue_status fails (rc 1) with unresolved repo/number" "$?" "1"
# no forge: every board step is skipped with the one notice, rc 0, and nothing is requested (#396)
: > "$GH_LOG"
out="$(PATH="$tmp/bin:$PATH" CCKIT_FORGE=none KIT_REPO="acme/app" KIT_PROJECT_NUMBER=3 bash -c "source '$LIB/forge/gh-project.sh'; project_issue_status 42; echo rc=\$?" 2>"$tmp/noforge.err")"
t   "no forge: project_issue_status is a quiet rc 0" "$out" "rc=0"
has "no forge: the board notice names the cause" "$(cat "$tmp/noforge.err")" "board step skipped (no forge is configured; see forge.provider)"
t   "no forge: no request was made" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

# ── role_option_id: any board Role option resolves, not a fixed list (#378) ─────────────────────
# capture-project-ids.sh writes ROLE_OPT_<NAME> for every option the board has; the lookup reads
# that variable by normalized name. Run under bash AND zsh — these libs are sourced into both, and
# bash-only ${!var} indirection dies in zsh with "bad substitution".
for rsh in bash zsh; do
  command -v "$rsh" >/dev/null 2>&1 || continue
  rq() {  # <role> -> stdout of role_option_id (stderr to $tmp/rerr)
    ROLE_OPT_BACKEND=x ROLE_OPT_TECH_LEAD=tl ROLE_OPT_DATA_ENG=de KIT_CONFIG=/nonexistent \
      "$rsh" -c "source '$LIB/forge/gh-project.sh'; role_option_id \"\$1\"" _ "$1" 2>"$tmp/rerr"
  }
  t "[$rsh] role_option_id backend"   "$(rq backend)"     "x"
  t "[$rsh] role_option_id Backend"   "$(rq Backend)"     "x"
  t "[$rsh] role_option_id Tech Lead" "$(rq 'Tech Lead')" "tl"
  t "[$rsh] role_option_id data-eng"  "$(rq data-eng)"    "de"
  t "[$rsh] known role is silent"     "$(rq backend >/dev/null; cat "$tmp/rerr")" ""
  t "[$rsh] unknown role -> empty stdout" "$(rq astronaut)" ""
  rq astronaut >/dev/null
  has "[$rsh] unknown role warns on stderr"   "$(cat "$tmp/rerr")" "ROLE_OPT_ASTRONAUT"
  has "[$rsh] the warning names the role"     "$(cat "$tmp/rerr")" "astronaut"
  t "[$rsh] empty role -> empty, no warning"  "$(rq ''; cat "$tmp/rerr")" ""
  # A name outside ^[A-Z0-9_]+$ must never reach the variable expansion.
  rm -f "$tmp/pwned"
  for evil in "x\$(touch $tmp/pwned)" "x;touch $tmp/pwned" "x\`touch $tmp/pwned\`" "BACKEND
\$(touch $tmp/pwned)" 'a}b' 'é'; do
    t "[$rsh] unsafe role name -> empty stdout" "$(rq "$evil")" ""
    rq "$evil" >/dev/null
    has "[$rsh] unsafe role name warns" "$(cat "$tmp/rerr")" "role"
    case "$(cat "$tmp/rerr")" in *"bad substitution"*|*"parse error"*|*"syntax error"*)
      echo "FAIL: [$rsh] unsafe role name reached the shell: $(cat "$tmp/rerr")"; fail=1 ;; esac
  done
  [ -e "$tmp/pwned" ] && { echo "FAIL: [$rsh] role_option_id evaluated its argument"; fail=1; } \
    || echo "ok: [$rsh] role_option_id evaluates nothing from its argument"
done

# ── the board over REST first, GraphQL as the fallback (E546.7) ────────────────────────────────
# A fixture answers the Projects v2 REST endpoints of org board acme #3 in the documented shapes
# (docs.github.com/en/rest/projects): integer field and item ids, node ids beside them, option and
# iteration ids as strings, option names as {raw, html}. GH_BOARD_PATCH_CODE makes the PATCH answer
# that HTTP code. No request leaves the shim.
cat > "$tmp/board-fixture.sh" <<'SH'
case "$method $ep" in
  "GET orgs/acme/projectsV2/3")
    out='{"id":11,"node_id":"PVT_rest","number":3,"title":"Board"}' ;;
  "GET orgs/acme/projectsV2/3/fields")
    out='[{"id":101,"node_id":"PVTSSF_status","name":"Status","data_type":"single_select","options":[{"id":"opt_todo","name":{"raw":"Todo","html":"Todo"}},{"id":"opt_done","name":{"raw":"Done","html":"Done"}}]},
          {"id":102,"node_id":"PVTIF_iter","name":"Iteration","data_type":"iteration","configuration":{"iterations":[{"id":"it_1","title":{"raw":"Iteration 1","html":"Iteration 1"},"start_date":"2026-11-01","duration":14,"completed":false}]}},
          {"id":103,"node_id":"PVTF_plan","name":"Plan Link","data_type":"text"}]' ;;
  "GET orgs/acme/projectsV2/3/items")
    out='[{"id":502,"node_id":"PVTI_other","content_type":"Issue","content":{"number":42,"repository":{"full_name":"acme/other"}}},
          {"id":501,"node_id":"PVTI_a","content_type":"Issue","content":{"number":42,"repository":{"full_name":"acme/app"}}}]' ;;
  "POST orgs/acme/projectsV2/3/items")
    code=201; out='{"id":777,"node_id":"PVTI_new","content_type":"Issue"}' ;;
  "PATCH orgs/acme/projectsV2/3/items/"*)
    code="${GH_BOARD_PATCH_CODE:-200}"
    if [ "$code" = 200 ]; then out="{\"id\":${ep##*/},\"node_id\":\"PVTI_a\"}"; else out='{"message":"Resource not accessible"}'; fi ;;
esac
SH
export GH_HDR_LOG="$tmp/hdr.log"
board() {  # <snippet> — run gh-project.sh functions against the org board, over the shim
  : > "$GH_LOG"; : > "$GH_HDR_LOG"
  PATH="$tmp/bin:$PATH" GH_FIXTURE="$tmp/board-fixture.sh" KIT_CONFIG=/nonexistent \
    KIT_REPO=acme/app KIT_OWNER=acme KIT_PROJECT_NUMBER=3 KIT_PROJECT_OWNER_TYPE=organization \
    PROJECT_ID=PVT_rest bash -c "source '$LIB/forge/gh-project.sh'; $1" 2>"$tmp/board.err"
}
export GH_GRAPHQL='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"PVTI_gql","project":{"number":3}}]}}}}}'

got="$(board 'project_find_item_by_issue 42')"
t   "REST find: the card of acme/app#42, as <id>:<node id>" "$got" "501:PVTI_a"
has "REST find: reads the board's items over REST" "$(cat "$GH_LOG")" "GET orgs/acme/projectsV2/3/items?per_page=100"
t   "REST find: no GraphQL call" "$(grep -c '^POST graphql' "$GH_LOG")" "0"
has "REST find: sends the documented API version" "$(cat "$GH_HDR_LOG")" "X-GitHub-Api-Version: 2026-03-10"
t   "REST find: no fallback note" "$(grep -c 'falling back' "$tmp/board.err")" "0"

board 'project_set_single_select 501:PVTI_a PVTSSF_status opt_done; echo rc=$?' > "$tmp/out"
t   "REST Status: rc 0" "$(cat "$tmp/out")" "rc=0"
has "REST Status: PATCH the item with the field's integer id and the option id" "$(cat "$GH_LOG")" \
    'PATCH orgs/acme/projectsV2/3/items/501 {"fields":[{"id":101,"value":"opt_done"}]}'
t   "REST Status: no GraphQL call" "$(grep -c '^POST graphql' "$GH_LOG")" "0"

board 'project_set_iteration 501:PVTI_a PVTIF_iter it_1' >/dev/null
has "REST Iteration: PATCH with the iteration id" "$(cat "$GH_LOG")" \
    'PATCH orgs/acme/projectsV2/3/items/501 {"fields":[{"id":102,"value":"it_1"}]}'
board 'project_set_text 501:PVTI_a PVTF_plan https://x/plan' >/dev/null
has "REST text: PATCH with the text" "$(cat "$GH_LOG")" \
    'PATCH orgs/acme/projectsV2/3/items/501 {"fields":[{"id":103,"value":"https://x/plan"}]}'

got="$(board 'project_add_item I_42 acme/app 42')"
t   "REST add: prints the new item as <id>:<node id>" "$got" "777:PVTI_new"
has "REST add: POST items by owner, repo and number" "$(cat "$GH_LOG")" \
    'POST orgs/acme/projectsV2/3/items {"type":"Issue","owner":"acme","repo":"app","number":42}'
board 'project_add_item PR_7 acme/app 7' >/dev/null
has "REST add: a PR_ node id adds a PullRequest" "$(cat "$GH_LOG")" '"type":"PullRequest"'

got="$(board 'PROJECT_ENV=/nonexistent/ids.env; unset PROJECT_ID; load_project_ids; echo "$PROJECT_ID $STATUS_FIELD_ID $STATUS_FIELD_NUM $STATUS_OPT_DONE $ITERATION_ITER_ITERATION_1 $PLAN_LINK_FIELD_ID"')"
t   "REST ids: load_project_ids reads the ids over REST with no captured file" "$got" \
    "PVT_rest PVTSSF_status 101 opt_done it_1 PVTF_plan"
has "REST ids: says the ids came over REST" "$(cat "$tmp/board.err")" "board ids read over REST"

# An unknown option is not sent over REST: the GraphQL fallback decides.
board 'project_set_single_select 501:PVTI_a PVTSSF_status opt_missing' >/dev/null
t   "REST Status: an option REST does not list is not PATCHed" "$(grep -c '^PATCH' "$GH_LOG")" "0"
has "REST Status: ... and goes to GraphQL" "$(cat "$GH_LOG")" '"option":"opt_missing"'

# The fallback: REST answers 404 → one note, then GraphQL with the node id.
export GH_FAIL_EP='orgs/*'
got="$(board 'project_find_item_by_issue 42')"
t   "fallback find: GraphQL's item after a REST 404" "$got" "PVTI_gql"
has "fallback find: REST was tried first" "$(sed -n 1p "$GH_LOG")" "GET orgs/acme/projectsV2/3/items"
t   "fallback find: then one GraphQL call" "$(grep -c '^POST graphql' "$GH_LOG")" "1"
t   "fallback find: one stderr note" "$(grep -c 'board find item: REST could not serve it, falling back to GraphQL' "$tmp/board.err")" "1"
board 'project_set_single_select 501:PVTI_a PVTSSF_status opt_done; echo rc=$?' > "$tmp/out"
t   "fallback Status: rc 0" "$(cat "$tmp/out")" "rc=0"
has "fallback Status: GraphQL gets the item's node id, not the REST id" "$(cat "$GH_LOG")" '"item":"PVTI_a"'
t   "fallback Status: one note" "$(grep -c 'falling back to GraphQL' "$tmp/board.err")" "1"
got="$(board 'project_add_item I_42 acme/app 42')"
has "fallback add: GraphQL adds by the content node id" "$(cat "$GH_LOG")" '"content":"I_42"'
# A cloud session: REST failed and GraphQL is unavailable → the skip notice, rc 0, no GraphQL.
board 'CLAUDE_CODE_REMOTE=true; project_set_single_select 501:PVTI_a PVTSSF_status opt_done; echo rc=$?' > "$tmp/out"
t   "cloud, REST 404: rc 0" "$(cat "$tmp/out")" "rc=0"
t   "cloud, REST 404: no GraphQL call" "$(grep -c '^POST graphql' "$GH_LOG")" "0"
has "cloud, REST 404: the skip notice" "$(cat "$tmp/board.err")" "board step skipped (GraphQL unavailable"
unset GH_FAIL_EP

# A cloud session where REST works: the card moves.
board 'CLAUDE_CODE_REMOTE=true; project_set_single_select 501:PVTI_a PVTSSF_status opt_done; echo rc=$?' > "$tmp/out"
t   "cloud: Status moves over REST" "$(grep -c '^PATCH orgs/acme/projectsV2/3/items/501 ' "$GH_LOG"):$(grep -c '^POST graphql' "$GH_LOG")" "1:0"

# A hard REST error (403) is reported, not retried over GraphQL.
board 'GH_BOARD_PATCH_CODE=403; export GH_BOARD_PATCH_CODE; project_set_single_select 501:PVTI_a PVTSSF_status opt_done; echo rc=$?' > "$tmp/out"
t   "REST 403: rc 1" "$(cat "$tmp/out")" "rc=1"
t   "REST 403: no GraphQL call" "$(grep -c '^POST graphql' "$GH_LOG")" "0"
has "REST 403: the API's answer on stderr" "$(cat "$tmp/board.err")" "GitHub answered 403"

# A GraphQL item handle (a node id) skips REST, which needs the integer id.
board 'project_set_single_select PVTI_gql PVTSSF_status opt_done' >/dev/null
t   "node-id item: no REST PATCH" "$(grep -c '^PATCH' "$GH_LOG")" "0"
has "node-id item: GraphQL with the node id" "$(cat "$GH_LOG")" '"item":"PVTI_gql"'

# capture-project-ids.sh reads the board over REST and writes the same file.
printf '%s' '{"github":{"projectsV2":true,"owner":"acme","projectNumber":3,"projectOwnerType":"organization"}}' > "$tmp/cfg.json"
: > "$GH_LOG"
GH_FIXTURE="$tmp/board-fixture.sh" KIT_CONFIG="$tmp/cfg.json" PATH="$tmp/bin:$PATH" \
  bash "$tmp/scripts/capture-project-ids.sh" >/dev/null 2>&1
t   "REST capture: rc 0" "$?" "0"
t   "REST capture: no GraphQL call" "$(grep -c '^POST graphql' "$GH_LOG")" "0"
has "REST capture: PROJECT_ID is the node id" "$(cat "$tmp/scripts/.project-ids.env" 2>/dev/null)" "PROJECT_ID=PVT_rest"
has "REST capture: the Status option" "$(cat "$tmp/scripts/.project-ids.env" 2>/dev/null)" "STATUS_OPT_DONE=opt_done"
unset GH_HDR_LOG

[ "$fail" -eq 0 ] && echo "ALL OK (gh-project)" || echo "gh-project: FAILURES"
exit "$fail"
