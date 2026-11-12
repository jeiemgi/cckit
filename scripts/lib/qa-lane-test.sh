#!/usr/bin/env bash
# qa-lane-test.sh — launched and usable are different facts (#295).
#
# Hermetic: `curl` is a stub on PATH that answers from a table, the "stack" is a `sleep`, and every
# file lands in a scratch repo. Nothing listens on a port.
#
# Run:  bash scripts/lib/qa-lane-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "qa-lane-test: jq absent — skipping"; exit 0; }
# Sealed from the caller's KIT_*/CCKIT_* (#369): the suite builds its own project.
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal

TMP="$(cd "$(mktemp -d)" && pwd -P)" || exit 1
PIDS=""
cleanup() { local p; for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
yes() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> missing '$3' in [$2]"; fail=1 ;; esac; }
no()  { case "$2" in *"$3"*) echo "FAIL: $1 -> found '$3' in [$2]"; fail=1 ;; *) echo "ok: $1" ;; esac; }

# ── the curl stub: status per URL substring, first match wins; no match is a refused connection ──
STUB="$TMP/stub"; mkdir -p "$STUB"
CURL_TABLE="$TMP/curl.table"; export CURL_TABLE
CURL_LOG="$TMP/curl.log"; export CURL_LOG
cat > "$STUB/curl" <<'SH'
#!/usr/bin/env bash
url=""; for a in "$@"; do url="$a"; done
printf '%s\n' "$*" >> "$CURL_LOG"
while read -r needle code; do
  [ -n "$needle" ] || continue
  case "$url" in *"$needle"*) printf '%s' "$code"; [ "$code" = 000 ] && exit 7; exit 0 ;; esac
done < "$CURL_TABLE"
printf '000'; exit 7
SH
chmod +x "$STUB/curl"
PATH="$STUB:$PATH"; export PATH
answers() { printf '%s\n' "$@" > "$CURL_TABLE"; }

# ── a project that declared its stack the way `kit-add.sh qa` records it (#294) ────────────────
P="$TMP/proj"; mkdir -p "$P"
(
  cd "$P" && git init -q . && git config user.email t@t && git config user.name t &&
  git commit -q --allow-empty -m base && git checkout -q -b task/7-review-stack
) || { echo "qa-lane-test: could not build the fixture repo"; exit 1; }
DEF_PORTS='[{"env":"WEB_PORT","base":3000},{"env":"API_PORT","base":4000}]'
DEF_READY='[{"env":"WEB_PORT","path":"/"},{"env":"API_PORT","path":"/health"}]'
write_cfg() { # <command> [<ports-json>] [<readiness-json>]
  local ports="${2:-$DEF_PORTS}" ready="${3:-$DEF_READY}"
  jq -n --arg c "$1" --argjson ports "$ports" --argjson ready "$ready" \
    '{qa: {command: $c, ports: $ports, readiness: $ready, route: "/", credentialEnv: []}}' \
    > "$P/cckit.config.json"
}
write_cfg 'env > "env.$LANE_TAG.dump"; exec sleep 60'

KIT_STATE_DIR="$TMP/state"; export KIT_STATE_DIR
KIT_CONFIG="$P/cckit.config.json"; export KIT_CONFIG
QA_READY_INTERVAL=0.1; export QA_READY_INTERVAL
EVENTS="$P/.git/kit-events.jsonl"
events() { local c; c="$(grep -c "\"op\":\"$1\"" "$EVENTS" 2>/dev/null)"; [ -n "$c" ] || c=0; printf '%s' "$c"; }

cd "$P" || exit 1
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/qa-lane.sh"

# ── one probe: what counts as up ───────────────────────────────────────────────────────────────
answers "/ok 200" "/login-wall 302" "/missing 404" "/broken 503"
qa_probe "http://localhost:1/ok" >/dev/null;         t "a 200 is up" "$?" "0"
qa_probe "http://localhost:1/login-wall" >/dev/null; t "a 302 to sign-in is up" "$?" "0"
qa_probe "http://localhost:1/missing" >/dev/null;    t "a 404 is not up" "$?" "1"
qa_probe "http://localhost:1/broken" >/dev/null;     t "a 503 is not up" "$?" "1"
qa_probe "http://localhost:1/nothing" >/dev/null;    t "a refused connection is not up" "$?" "1"
t "a refused connection reads as 000" "$(qa_probe "http://localhost:1/nothing")" "000"
: > "$CURL_LOG"; qa_probe "http://localhost:1/login-wall" >/dev/null
no "redirects are not followed" "$(cat "$CURL_LOG")" " -L"

# ── the lane id ────────────────────────────────────────────────────────────────────────────────
t "the lane is the branch's issue number" "$(qa_lane_id)" "7"
t "--lane overrides the branch"           "$(qa_lane_id 12)" "12"
qa_lane_id abc >/dev/null 2>&1; t "a non-numeric lane is refused" "$?" "2"

# ── launch: the command's environment holds the project's OWN port variables ───────────────────
answers ":3 200" ":4 200"
out7="$(LANE_TAG=7 qa_cli up --timeout 5 2>"$TMP/up7.err")"; rc=$?
PIDS="$PIDS $(cat "$KIT_STATE_DIR/qa/7/pid" 2>/dev/null)"
t "up returns 0 once every probe answers" "$rc" "0"
yes "up prints the usable line" "$out7" "lane 7 usable"
waited=0; while [ ! -s "$P/env.7.dump" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited+1)); done
web7="$(sed -n 's/^WEB_PORT=//p' "$P/env.7.dump" 2>/dev/null)"
api7="$(sed -n 's/^API_PORT=//p' "$P/env.7.dump" 2>/dev/null)"
t "WEB_PORT in the command's env is the recorded lane port" "$web7" "$(sed -n 's/^WEB_PORT=//p' "$KIT_STATE_DIR/qa/7/ports")"
t "API_PORT in the command's env is the recorded lane port" "$api7" "$(sed -n 's/^API_PORT=//p' "$KIT_STATE_DIR/qa/7/ports")"
slot7="$(awk -F'\t' '$1==7 {print $2}' "$P/.git/kit-portslots.tsv")"
t "the web port is base + slot * stride" "$web7" "$(( 3000 + slot7 * 10 ))"
t "the api port is base + slot * stride" "$api7" "$(( 4000 + slot7 * 10 ))"
yes "the probes hit the lane's own ports" "$(cat "$CURL_LOG")" "http://localhost:$api7/health"
t "launch appended one event" "$(events qa.launch)" "1"
t "ready appended one event"  "$(events qa.ready)" "1"
t "the launch event is an op.start carrying the ports" \
  "$(grep '"op":"qa.launch"' "$EVENTS" | jq -r '"\(.type) \(.payload.lane) \(.payload.ports.WEB_PORT)"')" "op.start 7 $web7"

# A second `up` on a live lane must not start a second stack.
pid_before="$(cat "$KIT_STATE_DIR/qa/7/pid")"
LANE_TAG=7 qa_cli up --timeout 5 >/dev/null 2>"$TMP/up7b.err"; rc=$?
t "a second up on a live lane still reports usable" "$rc" "0"
t "a second up keeps the running pid" "$(cat "$KIT_STATE_DIR/qa/7/pid")" "$pid_before"
yes "a second up says it did not relaunch" "$(cat "$TMP/up7b.err")" "already launched"
t "a second up emits no second launch event" "$(events qa.launch)" "1"

# ── two lanes get disjoint ports ───────────────────────────────────────────────────────────────
LANE_TAG=8 qa_cli up --lane 8 --timeout 5 >/dev/null 2>&1; rc=$?
PIDS="$PIDS $(cat "$KIT_STATE_DIR/qa/8/pid" 2>/dev/null)"
t "a second lane comes up" "$rc" "0"
all="$(cat "$KIT_STATE_DIR/qa/7/ports" "$KIT_STATE_DIR/qa/8/ports" | cut -d= -f2)"
t "two lanes hold four ports"          "$(printf '%s\n' "$all" | grep -c .)" "4"
t "two lanes hold four DISTINCT ports" "$(printf '%s\n' "$all" | sort -u | grep -c .)" "4"

# ── usable needs EVERY probe: a web 200 with the API failing is not usable ─────────────────────
before_ready="$(events qa.ready)"
answers ":3 200" ":4 503"
err="$(qa_cli ready --timeout 1 2>&1 >/dev/null)"; rc=$?
t "web up + API failing is NOT usable" "$rc" "1"
yes "the failure names the probe that did not answer" "$err" "API_PORT http://localhost:$api7/health -> 503"
yes "the failure names the launch log" "$err" "$KIT_STATE_DIR/qa/7/launch.log"
t "a failed wait emits no ready event" "$(events qa.ready)" "$before_ready"
t "timeout appended one event" "$(events qa.timeout)" "1"
t "the timeout event carries the log path" \
  "$(grep '"op":"qa.timeout"' "$EVENTS" | jq -r '.payload.log')" "$KIT_STATE_DIR/qa/7/launch.log"

# The API coming back flips the same lane to usable — the verdict is read, not remembered.
answers ":3 302" ":4 200"
qa_cli ready --timeout 5 >/dev/null 2>&1; t "a 302 on web plus a 200 on the API is usable" "$?" "0"

# --llm: one JSON object, usable is a boolean.
j="$(CCKIT_OUTPUT=json qa_cli ready --timeout 5 2>/dev/null)"
t "--llm reports usable + the lane's ports" "$(printf '%s' "$j" | jq -r '"\(.usable) \(.lane) \(.ports.API_PORT)"')" "true 7 $api7"
answers ":3 200"
j="$(CCKIT_OUTPUT=json qa_cli ready --timeout 1 2>/dev/null)"; rc=$?
t "--llm on a timeout still exits 1" "$rc" "1"
t "--llm on a timeout says usable false and names the log" \
  "$(printf '%s' "$j" | jq -r '"\(.usable) \(.log)"')" "false $KIT_STATE_DIR/qa/7/launch.log"

# ── a command that exits is reported at once, not at the timeout ───────────────────────────────
write_cfg 'echo "boot failed: missing DATABASE_URL"; exit 3'
answers "nothing 200"
start="$(date +%s)"
err="$(qa_cli up --lane 9 --timeout 60 2>&1 >/dev/null)"; rc=$?
took=$(( $(date +%s) - start ))
t "a stack command that exits is not usable" "$rc" "1"
yes "the failure says the command exited" "$err" "exited before it was ready"
yes "the failure names that lane's log" "$err" "$KIT_STATE_DIR/qa/9/launch.log"
yes "the log holds the command's own output" "$(cat "$KIT_STATE_DIR/qa/9/launch.log")" "missing DATABASE_URL"
t "an exited command does not wait out the 60s timeout" "$([ "$took" -lt 30 ] && echo fast || echo "slow:$took")" "fast"
t "exited appended one event" "$(events qa.exited)" "1"

# ── refusals happen before anything launches ───────────────────────────────────────────────────
launches="$(events qa.launch)"
refuse() { # <label> <want-in-stderr> — expects rc 2, no lane 20 state, no launch event
  local e rc
  e="$(qa_cli up --lane 20 --timeout 1 2>&1 >/dev/null)"; rc=$?
  t "$1: rc 2" "$rc" "2"
  yes "$1: says why" "$e" "$2"
  t "$1: no lane state is left" "$([ -e "$KIT_STATE_DIR/qa/20/ports" ] || [ -e "$KIT_STATE_DIR/qa/20/pid" ] && echo yes || echo no)" "no"
}
jq -n '{}' > "$P/cckit.config.json"
refuse "no qa.command" "no qa.command"
write_cfg 'exec sleep 60' '[]'
refuse "no port variables" "qa.ports is empty"
write_cfg 'exec sleep 60' '[{"env":"WEB_PORT","base":3000},{"env":"API_PORT","base":3100}]'
refuse "bases a stride multiple apart" "two lanes would share a port"
write_cfg 'exec sleep 60' '[{"env":"WEB_PORT","base":3000},{"env":"WEB_PORT","base":3001}]'
refuse "a port variable declared twice" "declares WEB_PORT twice"
write_cfg 'exec sleep 60' '[{"env":"WEB_PORT","base":3000}]' '[]'
refuse "no readiness probe" "qa.readiness is empty"
write_cfg 'exec sleep 60' '[{"env":"WEB_PORT","base":3000}]' '[{"env":"API_PORT","path":"/health"}]'
refuse "a probe on an undeclared variable" "not a port variable in qa.ports"
t "no refusal launched anything" "$(events qa.launch)" "$launches"

write_cfg 'exec sleep 60'
qa_cli ready --lane 21 --timeout 1 >/dev/null 2>&1; t "ready on a lane never launched is a refusal, not a timeout" "$?" "2"
qa_cli nope >/dev/null 2>&1;                        t "an unknown subcommand is rc 2" "$?" "2"
qa_cli up --wat >/dev/null 2>&1;                    t "an unknown argument is rc 2" "$?" "2"

# ── the verb is wired ──────────────────────────────────────────────────────────────────────────
yes "cckit commands lists qa" " $("$ROOT/bin/cckit" commands) " " qa "
answers ":3 200" ":4 200"
"$ROOT/bin/cckit" qa ready --lane 7 --timeout 5 >/dev/null 2>&1; t "cckit qa ready dispatches to the lib" "$?" "0"

[ "$fail" -eq 0 ] && echo "ALL OK (qa-lane)" || echo "qa-lane: FAILURES"
exit "$fail"
