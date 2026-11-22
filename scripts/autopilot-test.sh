#!/usr/bin/env bash
# Verify board selection and failure propagation through a non-git installed copy.
# errors: strict — fixture failures exit nonzero
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/install" "$TMP/project" "$TMP/bin"
cp -R "$ROOT/scripts" "$TMP/install/scripts"
git -C "$TMP/project" init -q
printf '%s\n' '{"github":{"repo":"fixture/project","baseBranch":"develop","projectsV2":false}}' > "$TMP/project/cckit.config.json"
export KIT_CONFIG="$TMP/project/cckit.config.json"
export FIXTURE_BOARD="$TMP/board.json"
cat > "$FIXTURE_BOARD" <<'JSON'
[
 {"number":1,"title":"[Effort] 1 parent","labels":[],"assignees":[]},
 {"number":2,"title":"label parent","labels":[{"name":"effort"}],"assignees":[]},
 {"number":3,"title":"[Effort 1] 1 child","labels":[{"name":"role:tech-lead"}],"assignees":[]},
 {"number":4,"title":"ordinary task","labels":[],"assignees":[]}
]
JSON
# The forge (E537): the board and the blockers are read over REST. The shim's `curl` answers from
# this fixture — the board from $FIXTURE_BOARD, a blocker #99 on every issue when BLOCKER_STATE is
# set, a 500 when FAIL_BOARD / FAIL_DEPS is — and its `gh` fails on any subcommand.
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-forge-shim.sh"
forge_shim_install "$TMP/bin"
export GH_LOG="$TMP/forge.log" GH_TOKEN=test-token CCKIT_FORGE=github GH_FIXTURE="$TMP/fixture.sh"
cat > "$GH_FIXTURE" <<'FIX'
fail500() { out='{"message":"fixture failure"}'; code=500; }
case "$method $ep" in
  "GET repos/fixture/project/issues")
    if [ "${FAIL_BOARD:-0}" != 0 ]; then fail500; else out="$(cat "$FIXTURE_BOARD")"; fi ;;
  "GET repos/fixture/project/issues/"*"/dependencies/blocked_by")
    if [ "${FAIL_DEPS:-0}" != 0 ]; then fail500
    elif [ -n "${BLOCKER_STATE:-}" ]; then out='[{"number":99}]'
    else out='[]'; fi ;;
  "GET repos/fixture/project/issues/99")
    out="{\"number\":99,\"title\":\"blocker\",\"state\":\"$(printf '%s' "${BLOCKER_STATE:-OPEN}" | tr '[:upper:]' '[:lower:]')\",\"labels\":[],\"body\":\"\"}" ;;
esac
FIX
export PATH="$TMP/bin:$PATH"
cd "$TMP/project"
run() { bash "$TMP/install/scripts/autopilot.sh" --dry-run "$@"; }
has() { case "$1" in *"$2"*) : ;; *) echo "FAIL missing: $2"; exit 1 ;; esac; }
fails() { if "$@" > "$TMP/failure" 2>&1; then echo 'FAIL expected nonzero exit'; exit 1; fi; }
for agent in claude codex; do
 out="$(run --agent "$agent")"
 has "$out" 'would launch 2 flow(s): 3 4'
 has "$out" "agent '$agent'"
done
# #352: a KIT_BASE_BRANCH from the environment reaches orchestrate, and the banner says so. Without
# one the banner names the config's base and carries no override line.
out="$(KIT_BASE_BRANCH=effort/9-x run 3)"
has "$out" '(base effort/9-x)'
has "$out" "base 'effort/9-x' comes from KIT_BASE_BRANCH in the environment (the config says 'develop')"
out="$(env -u KIT_BASE_BRANCH bash "$TMP/install/scripts/autopilot.sh" --dry-run 3)"
has "$out" '(base develop)'
case "$out" in *'comes from KIT_BASE_BRANCH'*) echo 'FAIL override line printed with no override'; exit 1 ;; esac
out="$(run --cap 1)"; has "$out" 'would launch 1 flow(s): 3'; has "$out" 'queued past cap (run a later wave): 4'
out="$(BLOCKER_STATE=CLOSED run 3)"; has "$out" 'would launch 1 flow(s): 3'
export BLOCKER_STATE=OPEN
fails run 3
unset BLOCKER_STATE
export FAIL_DEPS=1
fails run 3
has "$(cat "$TMP/failure")" 'could not read blockers'
unset FAIL_DEPS
export FAIL_BOARD=1
fails run
has "$(cat "$TMP/failure")" 'could not read the board'
unset FAIL_BOARD
has "$(cat "$GH_LOG")" 'GET repos/fixture/project/issues?state=open&per_page=100'
has "$(cat "$GH_LOG")" 'GET repos/fixture/project/issues/3/dependencies/blocked_by'
[ "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" = 0 ] || { echo 'FAIL: a gh subcommand was run'; exit 1; }
# A body that is not JSON is diagnosed, never driven as an empty board. The diagnosis may come from
# autopilot ("invalid board data") or from the board read failing ("could not read the board").
printf '%s\n' 'invalid JSON' > "$FIXTURE_BOARD"
echo 'case: a board that is not JSON'
fails run
case "$(cat "$TMP/failure")" in
  *'invalid board data'*|*'could not read the board'*) : ;;
  *) echo 'FAIL: an unreadable board was not diagnosed'; cat "$TMP/failure"; exit 1 ;;
esac
printf '%s\n' '[]' > "$FIXTURE_BOARD"
has "$(run 2>&1)" 'nothing open to drive'
fails run --cap 0 3
# The agent-facing format remains TOON for multiple rows; raw mode preserves label objects.
printf '%s\n' '[{"number":3,"title":"a","labels":[{"name":"effort"}],"assignees":[]},{"number":4,"title":"b","labels":[],"assignees":[]}]' > "$FIXTURE_BOARD"
raw="$(bash "$TMP/install/scripts/task-sync.sh" --raw-json)"
[ "$(printf '%s' "$raw" | jq -r '.[0].labels[0].name')" = effort ]
has "$(bash "$TMP/install/scripts/task-sync.sh" --llm)" '[2]{number,title,priority,labels,milestone,assignees,blocked}:'
echo 'PASS autopilot selection and failures for Claude and Codex launchers'
