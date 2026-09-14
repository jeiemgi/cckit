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
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
 'issue list') [ "${FAIL_BOARD:-0}" = 0 ] || exit 1; cat "$FIXTURE_BOARD" ;;
 'api '*)
   [ "${FAIL_DEPS:-0}" = 0 ] || exit 1
   [ "${BLOCKER_STATE:-}" = '' ] || echo 99
   exit 0 ;;
 'issue view') echo "${BLOCKER_STATE:-OPEN}" ;;
 *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
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
printf '%s\n' 'invalid JSON' > "$FIXTURE_BOARD"
fails run
has "$(cat "$TMP/failure")" 'invalid board data'
printf '%s\n' '[]' > "$FIXTURE_BOARD"
has "$(run 2>&1)" 'nothing open to drive'
fails run --cap 0 3
# The agent-facing format remains TOON for multiple rows; raw mode preserves label objects.
printf '%s\n' '[{"number":3,"title":"a","labels":[{"name":"effort"}],"assignees":[]},{"number":4,"title":"b","labels":[],"assignees":[]}]' > "$FIXTURE_BOARD"
raw="$(bash "$TMP/install/scripts/task-sync.sh" --raw-json)"
[ "$(printf '%s' "$raw" | jq -r '.[0].labels[0].name')" = effort ]
has "$(bash "$TMP/install/scripts/task-sync.sh" --llm)" '[2]{number,title,priority,labels,milestone,assignees,blocked}:'
echo 'PASS autopilot selection and failures for Claude and Codex launchers'
