#!/usr/bin/env bash
# shellcheck shell=bash
# gh-board-add-test.sh — the board add when the item is already on the board (#590). A Projects v2
# board with GitHub's auto-add workflow puts every new issue and PR on the board within seconds of
# its creation, so the kit's REST add answers 422 "Content already exists in this project" — where
# GraphQL's addProjectV2ItemById returned the existing item. The add must read that card back, fall
# back to GraphQL when it cannot, and `cckit new` must then go on to set the card's fields.
# Hermetic: the shared forge shim (test-forge-shim.sh) over a curl stand-in; a throwaway repo.
# Run: bash scripts/lib/gh-board-add-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$LIB/../../lib/core/test-env.sh" && test_env_seal
unset CLAUDE_CODE_REMOTE CCKIT_GH_TRANSPORT CCKIT_GRAPHQL
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '$2' lacks '$3'"; fail=1 ;; esac; }
command -v jq  >/dev/null 2>&1 || { echo "gh-board-add-test: jq required — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "gh-board-add-test: git required — skipping"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# shellcheck source=/dev/null
. "$LIB/../../lib/forge/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export GH_TOKEN=test-token CCKIT_FORGE=github GH_LOG="$tmp/gh.log" GH_N="$tmp/n"

# Org board acme #3. POST items answers as GH_ADD_MODE says: exists = the documented 422 for content
# already on the board · forbidden = 403 · ok = 201 with a new item. GET items lists issue 42, PR 7
# and issue 50 (the number the shim gives the first created issue) unless GH_ITEMS_EMPTY=1.
cat > "$tmp/fixture.sh" <<'SH'
case "$method $ep" in
  "GET orgs/acme/projectsV2/3")
    out='{"id":11,"node_id":"PVT_rest","number":3,"title":"Board"}' ;;
  "GET orgs/acme/projectsV2/3/fields")
    out='[{"id":101,"node_id":"PVTSSF_status","name":"Status","data_type":"single_select","options":[{"id":"opt_todo","name":{"raw":"Todo","html":"Todo"}}]}]' ;;
  "GET orgs/acme/projectsV2/3/items")
    if [ "${GH_ITEMS_EMPTY:-0}" = 1 ]; then out='[]'; else
    out='[{"id":502,"node_id":"PVTI_other","content_type":"Issue","content":{"number":42,"repository":{"full_name":"acme/other"}}},
          {"id":501,"node_id":"PVTI_a","content_type":"Issue","content":{"number":42,"repository":{"full_name":"acme/app"}}},
          {"id":503,"node_id":"PVTI_pr","content_type":"PullRequest","content":{"number":7,"repository":{"full_name":"acme/app"}}},
          {"id":550,"node_id":"PVTI_new50","content_type":"Issue","content":{"number":50,"repository":{"full_name":"acme/app"}}}]'; fi ;;
  "POST orgs/acme/projectsV2/3/items")
    case "${GH_ADD_MODE:-exists}" in
      exists)    code=422; out='{"message":"Content already exists in this project","documentation_url":"https://docs.github.com/rest/projects/items#add-item-to-organization-owned-project","status":"422"}' ;;
      forbidden) code=403; out='{"message":"Resource not accessible by integration","status":"403"}' ;;
      *)         code=201; out='{"id":777,"node_id":"PVTI_made","content_type":"Issue"}' ;;
    esac ;;
  "PATCH orgs/acme/projectsV2/3/items/"*)
    out="{\"id\":${ep##*/},\"node_id\":\"PVTI_x\"}" ;;
esac
SH
export GH_FIXTURE="$tmp/fixture.sh"
export GH_GRAPHQL='{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_gql"}}}}'

add() {  # <snippet> — run gh-project.sh functions against the org board, over the shim
  : > "$GH_LOG"
  PATH="$tmp/bin:$PATH" KIT_CONFIG=/nonexistent KIT_REPO=acme/app KIT_OWNER=acme KIT_PROJECT_NUMBER=3 \
    KIT_PROJECT_OWNER_TYPE=organization PROJECT_ID=PVT_rest bash -c "source '$LIB/../../lib/forge/gh-project.sh'; $1" 2>"$tmp/add.err"
}

# ── the item is already on the board: REST 422 → the existing card ───────────────────────────────
got="$(add 'project_add_item I_42 acme/app 42 Issue')"
t   "422 exists: prints the existing card as <id>:<node id>"   "$got" "501:PVTI_a"
has "422 exists: the POST was tried first"                     "$(sed -n 1p "$GH_LOG")" "POST orgs/acme/projectsV2/3/items"
has "422 exists: then the board's items were read"             "$(sed -n 2p "$GH_LOG")" "GET orgs/acme/projectsV2/3/items"
t   "422 exists: no GraphQL call"                              "$(grep -c '^POST graphql' "$GH_LOG")" "0"
t   "422 exists: nothing on stderr"                            "$(cat "$tmp/add.err")" ""

got="$(add 'project_add_item PR_7 acme/app 7')"
t   "422 exists, a PR: the PR's card, not an issue's"          "$got" "503:PVTI_pr"

# ── 422 but the card cannot be read back: the idempotent GraphQL add decides ──────────────────────
got="$(add 'GH_ITEMS_EMPTY=1; export GH_ITEMS_EMPTY; project_add_item I_42 acme/app 42 Issue')"
t   "422, card not listed: GraphQL's item"                     "$got" "PVTI_gql"
has "422, card not listed: GraphQL adds by the content node id" "$(cat "$GH_LOG")" '"content":"I_42"'
has "422, card not listed: one fallback note"                  "$(cat "$tmp/add.err")" "board add item: REST could not serve it, falling back to GraphQL"

# ── any other REST failure of the add: GraphQL too (an item missing from the board strands the rest)
got="$(add 'GH_ADD_MODE=forbidden; export GH_ADD_MODE; project_add_item I_42 acme/app 42 Issue')"
t   "REST 403 on add: GraphQL's item"                          "$got" "PVTI_gql"
has "REST 403 on add: the API's answer is still reported"      "$(cat "$tmp/add.err")" "GitHub answered 403"
t   "REST 403 on add: one GraphQL call"                        "$(grep -c '^POST graphql' "$GH_LOG")" "1"

# A cloud session: no GraphQL, so the skip notice and rc 0, never a GraphQL call.
got="$(add 'GH_ADD_MODE=forbidden; export GH_ADD_MODE; CLAUDE_CODE_REMOTE=true; project_add_item I_42 acme/app 42 Issue; echo rc=$?')"
t   "cloud, REST 403 on add: rc 0, no item"                    "$got" "rc=0"
t   "cloud, REST 403 on add: no GraphQL call"                  "$(grep -c '^POST graphql' "$GH_LOG")" "0"

# A fresh add still prints the new card.
got="$(add 'GH_ADD_MODE=ok; export GH_ADD_MODE; project_add_item I_42 acme/app 42 Issue')"
t   "201: the new card"                                        "$got" "777:PVTI_made"

# ── cckit new on an auto-add board: on the board, no warning, its Status set on the existing card ─
git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@t; git config user.name t
git checkout -q -b develop; git commit -q --allow-empty -m init; git push -q origin develop
export PATH="$tmp/bin:$PATH" KIT_CONFIG=/nonexistent KIT_REPO=acme/app KIT_OWNER=acme KIT_PROJECT_NUMBER=3 \
  KIT_PROJECT_OWNER_TYPE=organization KIT_BASE_BRANCH=develop KIT_PROJECTS_V2=true KIT_WT_INSTALL=0
export GH_REPO_LABELS='[{"name":"kind:task"},{"name":"priority:p2"},{"name":"role:tech-lead"}]'
export PROJECT_ID=PVT_rest STATUS_FIELD_ID=PVTSSF_status STATUS_OPT_TODO=opt_todo
unset GH_ADD_MODE GH_ITEMS_EMPTY
# shellcheck source=/dev/null
. "$LIB/../../lib/forge/gh-project.sh"
# shellcheck source=/dev/null
. "$LIB/../../lib/verbs/kit-task-ops.sh"
load_project_ids() { :; }   # the ids are exported above; no captured file in the throwaway repo
: > "$GH_LOG"
num="$(kto_task_new "Add a thing" tech-lead task p2 "" "" "" "Body." 2>"$tmp/new.err" | tail -1)"
t   "new: the new issue's number"                              "$num" "50"
t   "new: no 'NOT added to the board' warning"                 "$(grep -c 'NOT added' "$tmp/new.err")" "0"
has "new: the board add was tried over REST"                   "$(cat "$GH_LOG")" 'POST orgs/acme/projectsV2/3/items {"type":"Issue","owner":"acme","repo":"app","number":50}'
has "new: the Status is set on the existing card"              "$(cat "$GH_LOG")" 'PATCH orgs/acme/projectsV2/3/items/550 {"fields":[{"id":101,"value":"opt_todo"}]}'
t   "new: no GraphQL call"                                     "$(grep -c '^POST graphql' "$GH_LOG")" "0"

[ "$fail" -eq 0 ] && echo "ALL OK (gh-board-add)" || echo "gh-board-add: FAILURES"
exit "$fail"
