#!/usr/bin/env bash
# qa-lane-test.sh — launched and usable are different facts (#295); the review route comes from
# the work (#297); a stop leaves the ports with no listener (#298); a verdict is bound to the
# commit that was reviewed and a later commit reads it stale (#299).
#
# Hermetic: `curl` is a stub on PATH that answers from a table, the "stack" is a `sleep`, and every
# file lands in a scratch repo. `open`, `xdg-open` and `gh` are stubs too: no browser starts and no
# network is touched. Only the stop sections listen on a port — a loopback port the kernel picked —
# and they skip with a printed reason when perl, or both lsof and ss, are absent.
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
# ── the browser openers and gh: each logs its arguments; gh answers a PR body from a file ──────
OPEN_LOG="$TMP/open.log"; export OPEN_LOG; : > "$OPEN_LOG"
for o in open xdg-open; do
  cat > "$STUB/$o" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$OPEN_LOG"
SH
  chmod +x "$STUB/$o"
done
GH_LOG="$TMP/gh.log"; export GH_LOG; : > "$GH_LOG"
PR_BODY="$TMP/pr.body"; export PR_BODY
PR_META="$TMP/pr.meta"; export PR_META
GH_COMMENTS="$TMP/gh.comments"; export GH_COMMENTS; : > "$GH_COMMENTS"
cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
# stub: `gh pr view <ref> --json body --jq …` prints the body file; no file means no PR (rc 1).
# For the verdict (#299) it also answers the PR's number/url/head/branch from $PR_META and keeps
# the PR's comments in $GH_COMMENTS as `<id><TAB><json body>` rows: list, create, edit in place.
printf '%s\n' "$*" >> "$GH_LOG"
case "$*" in
  *"--json number,url,headRefOid,headRefName"*)
    [ -f "$PR_META" ] || { echo "no pull requests found" >&2; exit 1; }
    cat "$PR_META"; exit 0 ;;
  "api --paginate "*) cat "$GH_COMMENTS" 2>/dev/null; exit 0 ;;
  "api --method PATCH "*)
    id="${4##*/}"; f="${6#body=@}"
    grep -v "^$id	" "$GH_COMMENTS" > "$GH_COMMENTS.tmp"
    printf '%s\t%s\n' "$id" "$(jq -Rs . < "$f")" >> "$GH_COMMENTS.tmp"
    mv "$GH_COMMENTS.tmp" "$GH_COMMENTS"; exit 0 ;;
  "pr comment "*)
    n=$(( $(wc -l < "$GH_COMMENTS" 2>/dev/null || echo 0) + 9001 ))
    printf '%s\t%s\n' "$n" "$(jq -Rs . < "$5")" >> "$GH_COMMENTS"; exit 0 ;;
esac
[ -f "$PR_BODY" ] || { echo "no pull requests found" >&2; exit 1; }
cat "$PR_BODY"
SH
chmod +x "$STUB/gh"
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

# The sections that launch on the default bases (3000, 4000) answer their probes from the curl stub
# and bind nothing. `up` refuses a lane port somebody already listens on, and this machine may run
# a dev server there, so the holder lookup is off until the stop sections, which pick free ports.
QA_PORT_TOOL=none; export QA_PORT_TOOL

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

# ── the route line: what counts as declared (#297) ─────────────────────────────────────────────
decl() { printf '%s\n' "$1" | qa_route_declared; }
t "a plain QA route line"          "$(decl 'QA route: /settings/billing')" "/settings/billing"
t "a bulleted, backticked line"    "$(decl '- QA route: `/orders/42?tab=items`')" "/orders/42?tab=items"
t "a bold label, any letter case"  "$(decl '**qa Route:** /a')" "/a"
t "the first usable line wins"     "$(decl "$(printf 'intro\nQA route: /one\nQA route: /two')")" "/one"
t "CRLF bodies are read"           "$(printf 'QA route: /crlf\r\n' | qa_route_declared)" "/crlf"
t "an unfilled template placeholder is skipped" "$(decl "$(printf 'QA route: <path>\nQA route: /real')")" "/real"
decl 'QA route: settings' >/dev/null;             t "a value with no leading slash is not a route" "$?" "1"
decl 'QA route: https://evil.example/x' >/dev/null; t "a full URL is not a route" "$?" "1"
decl 'the QA route: /x is mentioned mid-sentence' >/dev/null; t "a mid-sentence mention is not a declaration" "$?" "1"
decl 'no route here' >/dev/null;                  t "a body with no line declares nothing" "$?" "1"
qa_route_valid '/ok/path';   t "a path is a valid route" "$?" "0"
qa_route_valid '/a b';       t "a route with a space is refused" "$?" "1"
qa_route_valid '/a";rm';     t "a route with a quote is refused" "$?" "1"

# ── open: the screen the change touched, on the lane's own port ────────────────────────────────
write_cfg 'exec sleep 60'
jq '.qa.route = "/dashboard"' "$P/cckit.config.json" > "$TMP/cfg.tmp" && mv "$TMP/cfg.tmp" "$P/cckit.config.json"
answers ":3 200" ":4 200"
printf 'Summary of the change.\n\nQA route: /settings/billing\n' > "$PR_BODY"
: > "$OPEN_LOG"; : > "$GH_LOG"
url="$(qa_cli open 2>"$TMP/open.err")"; rc=$?
t "open on a usable lane returns 0" "$rc" "0"
t "a declared route opens on the lane's first port" "$url" "http://localhost:$web7/settings/billing"
t "the opener got exactly that URL, once" "$(cat "$OPEN_LOG")" "open http://localhost:$web7/settings/billing"
yes "the PR is looked up by the lane's branch" "$(cat "$GH_LOG")" "pr view task/7-review-stack"
yes "open says where the route came from" "$(cat "$TMP/open.err")" "declared route /settings/billing"
t "open appended one event" "$(events qa.open)" "1"
t "the open event carries the url and the source" \
  "$(grep '"op":"qa.open"' "$EVENTS" | jq -r '"\(.type) \(.payload.source) \(.payload.opened) \(.payload.url)"')" \
  "op.done declared true http://localhost:$web7/settings/billing"

# No declared line: the configured route is the fallback.
printf 'Summary only, no route line.\n' > "$PR_BODY"
: > "$OPEN_LOG"
t "with no declared route the configured one is used" "$(qa_cli open 2>/dev/null)" "http://localhost:$web7/dashboard"
t "the opener got the configured route" "$(cat "$OPEN_LOG")" "open http://localhost:$web7/dashboard"
# No PR at all (gh fails) reads the same as no declared line.
rm -f "$PR_BODY"
t "with no PR the configured route is used" "$(qa_cli open --print 2>/dev/null)" "http://localhost:$web7/dashboard"

# --pr reads another PR; --route overrides both; --port-env picks the port; --print opens nothing.
printf 'QA route: /from-pr-31\n' > "$PR_BODY"
: > "$GH_LOG"; : > "$OPEN_LOG"
t "--pr reads the named PR" "$(qa_cli open --pr 31 --print 2>/dev/null)" "http://localhost:$web7/from-pr-31"
yes "--pr is what gh was asked for" "$(cat "$GH_LOG")" "pr view 31"
t "--route overrides the declared route" "$(qa_cli open --route /override --print 2>/dev/null)" "http://localhost:$web7/override"
t "--port-env picks another port variable" "$(qa_cli open --port-env API_PORT --print 2>/dev/null)" "http://localhost:$api7/from-pr-31"
t "--print opens no browser" "$(cat "$OPEN_LOG")" ""
j="$(CCKIT_OUTPUT=json qa_cli open --print 2>/dev/null)"
t "--llm reports the url, the source and opened" \
  "$(printf '%s' "$j" | jq -r '"\(.url) \(.source) \(.opened)"')" "http://localhost:$web7/from-pr-31 declared false"
# Another lane opens on ITS port.
web8="$(sed -n 's/^WEB_PORT=//p' "$KIT_STATE_DIR/qa/8/ports")"
t "another lane opens on its own port" "$(qa_cli open --lane 8 --route /x --print 2>/dev/null)" "http://localhost:$web8/x"
# QA_OPENER replaces the default opener.
: > "$OPEN_LOG"
QA_OPENER=xdg-open qa_cli open --route /via-env >/dev/null 2>&1
t "QA_OPENER names the opener" "$(cat "$OPEN_LOG")" "xdg-open http://localhost:$web7/via-env"

# ── open refuses a lane that is not ready ──────────────────────────────────────────────────────
opens="$(events qa.open)"
answers ":3 200" ":4 503"
: > "$OPEN_LOG"
err="$(qa_cli open 2>&1 >/dev/null)"; rc=$?
t "open on a lane that is not usable returns 1" "$rc" "1"
yes "the refusal says the lane is not usable" "$err" "NOT usable — refusing to open"
yes "the refusal names the probe that failed" "$err" "API_PORT http://localhost:$api7/health -> 503"
yes "the refusal names the launch log" "$err" "$KIT_STATE_DIR/qa/7/launch.log"
t "a refused open starts no browser" "$(cat "$OPEN_LOG")" ""
t "a refused open emits no open event" "$(events qa.open)" "$opens"
qa_cli open --lane 21 >/dev/null 2>&1;             t "open on a lane never launched is rc 2" "$?" "2"
answers ":3 200" ":4 200"
qa_cli open --route 'no-slash' >/dev/null 2>&1;    t "a --route that is not a route is rc 2" "$?" "2"
qa_cli open --port-env NOPE_PORT >/dev/null 2>&1;  t "a --port-env the lane does not hold is rc 2" "$?" "2"
qa_cli open --pr abc >/dev/null 2>&1;              t "a non-numeric --pr is rc 2" "$?" "2"
qa_cli open --timeout 5 >/dev/null 2>&1;           t "--timeout on open is rc 2" "$?" "2"
qa_cli up --route /x >/dev/null 2>&1;              t "--route on up is rc 2" "$?" "2"
jq '.qa.route = "bad route"' "$P/cckit.config.json" > "$TMP/cfg.tmp" && mv "$TMP/cfg.tmp" "$P/cckit.config.json"
rm -f "$PR_BODY"
err="$(qa_cli open --print 2>&1 >/dev/null)"; rc=$?
t "a configured route that is not a route is rc 2" "$rc" "2"
yes "that refusal names qa.route" "$err" "qa.route"
t "no refused open was recorded" "$(events qa.open)" "$opens"

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

# ── stop: the ports are free afterwards, and the report is what actually stopped (#298) ────────
# These sections run REAL processes: a supervisor shell that respawns a perl listener on a port
# the kernel just handed out. The curl stub still answers the readiness probes.
free_port() { perl -MIO::Socket::INET -e 'my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => 0) or exit 1; print $s->sockport' 2>/dev/null; }
listening() { [ -n "$(qa_port_pids "$1")" ] && echo yes || echo no; }
wait_listen() { local i=0; while [ "$(listening "$1")" = no ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done; }
running() { _qa_alive "$1" && echo yes || echo no; }
# The supervisor: respawn the listener for as long as this shell lives.
cat > "$TMP/listen.pl" <<'PL'
use IO::Socket::INET;
my $s = IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1", LocalPort => $ENV{WEB_PORT}, ReuseAddr => 1) or exit 1;
sleep 600;
PL
SUPERVISE="while :; do perl '$TMP/listen.pl'; sleep 0.1; done"

unset QA_PORT_TOOL
if ! command -v perl >/dev/null 2>&1; then
  echo "skip: stop — perl is absent, so the fixture cannot open a listener"
elif ! qa_port_tool >/dev/null 2>&1; then
  echo "skip: stop — neither lsof nor ss is installed, so a port's holder cannot be resolved"
else
  # (1) through the verb: launch a respawning stack, stop it, and the port has no listener.
  slot30="$(wt_port_slot "$P" 30 "$P")"
  port30="$(free_port)"
  write_cfg "$SUPERVISE" "[{\"env\":\"WEB_PORT\",\"base\":$(( port30 - slot30 * 10 ))}]" '[{"env":"WEB_PORT","path":"/"}]'
  answers ":$port30 200"
  qa_cli up --lane 30 --timeout 5 >/dev/null 2>&1; t "the respawning fixture stack comes up" "$?" "0"
  sup30="$(cat "$KIT_STATE_DIR/qa/30/pid" 2>/dev/null)"; PIDS="$PIDS $sup30"
  t "the lane was launched on the free port" "$(sed -n 's/^WEB_PORT=//p' "$KIT_STATE_DIR/qa/30/ports")" "$port30"
  wait_listen "$port30"
  lis30="$(qa_port_pids "$port30" | head -n 1)"
  t "the fixture listener holds the port" "$(listening "$port30")" "yes"
  # The supervisor really respawns: kill the listener alone and the port is held again.
  kill "$lis30" 2>/dev/null; sleep 0.5; wait_listen "$port30"
  t "killing the listener alone does not free the port" "$(listening "$port30")" "yes"
  no "the respawned listener is a new process" " $(qa_port_pids "$port30" | tr '\n' ' ')" " $lis30 "
  lis30="$(qa_port_pids "$port30" | head -n 1)"

  stops="$(events qa.stop)"
  err="$(qa_cli stop --lane 30 2>&1 >/dev/null)"; rc=$?
  t "stop returns 0 once the port is free" "$rc" "0"
  sleep 0.5
  t "the port has no listener after stop" "$(listening "$port30")" "no"
  t "the supervisor pid is gone" "$(running "$sup30")" "no"
  t "the listener pid is gone" "$(running "$lis30")" "no"
  yes "stop reports the supervisor it stopped" "$err" "$sup30"
  yes "stop reports the listener it stopped" "$err" "$lis30"
  yes "stop says the ports are free" "$err" "ports free: $port30"
  t "stop appended one event" "$(events qa.stop)" "$(( stops + 1 ))"
  t "the stop event says the ports were freed" "$(grep '"op":"qa.stop"' "$EVENTS" | tail -n 1 | jq -r '"\(.payload.lane) \(.payload.freed) \(.payload.held | length)"')" "30 true 0"
  t "a stopped lane keeps no pid or ports record" "$([ -e "$KIT_STATE_DIR/qa/30/pid" ] || [ -e "$KIT_STATE_DIR/qa/30/ports" ] && echo yes || echo no)" "no"

  # A second stop on the already-stopped lane: nothing stopped, rc 0.
  err="$(qa_cli stop --lane 30 2>&1 >/dev/null)"; rc=$?
  t "a second stop returns 0" "$rc" "0"
  yes "a second stop reports nothing stopped" "$err" "nothing stopped"
  no "a second stop claims no process" "$err" "stopped 1"
  t "a second stop appends no event" "$(events qa.stop)" "$(( stops + 1 ))"
  t "--llm on a stopped lane is an empty stop" "$(CCKIT_OUTPUT=json qa_cli stop --lane 30 2>/dev/null | jq -c '.stopped')" "[]"
  qa_cli ready --lane 30 --timeout 1 >/dev/null 2>&1; t "ready on a stopped lane is a refusal" "$?" "2"
  qa_cli stop --lane 30 --timeout 5 >/dev/null 2>&1;  t "--timeout on stop is rc 2" "$?" "2"

  # (2) the recorded pid is dead but its supervisor lives on: the port's holder names it.
  port31="$(free_port)"
  ( WEB_PORT="$port31" exec sh -c "$SUPERVISE" ) >/dev/null 2>&1 &
  sup31=$!; PIDS="$PIDS $sup31"
  ( exit 0 ) & gone=$!; wait "$gone" 2>/dev/null
  mkdir -p "$KIT_STATE_DIR/qa/31"
  printf '%s\n' "$gone" > "$KIT_STATE_DIR/qa/31/pid"
  printf 'WEB_PORT=%s\n' "$port31" > "$KIT_STATE_DIR/qa/31/ports"
  wait_listen "$port31"
  t "the orphaned stack holds its port" "$(listening "$port31")" "yes"
  # Nothing ties that listener to the lane: the recorded pid is dead and there is no group on
  # record. An unforced stop leaves it running and says how to stop it.
  err="$(qa_cli stop --lane 31 2>&1 >/dev/null)"; rc=$?
  t "an unforced stop does not call a lane with a held port down" "$rc" "1"
  t "an unforced stop leaves a listener it cannot tie to the lane" "$(running "$sup31")" "yes"
  yes "an unforced stop names --force" "$err" "stop --lane 31 --force"
  t "an unforced stop keeps the record for the retry" "$([ -f "$KIT_STATE_DIR/qa/31/ports" ] && echo yes || echo no)" "yes"
  qa_cli up --lane 31 --force >/dev/null 2>&1; t "--force belongs to stop only" "$?" "2"
  j="$(CCKIT_OUTPUT=json qa_cli stop --lane 31 --force 2>/dev/null)"; rc=$?
  t "a forced stop finds a stack through its port when the recorded pid is dead" "$rc" "0"
  sleep 0.5
  t "that port has no listener after stop" "$(listening "$port31")" "no"
  t "the supervisor behind the listener is gone" "$(running "$sup31")" "no"
  t "--llm lists the supervisor among the stopped pids" "$(printf '%s' "$j" | jq -r --argjson p "$sup31" '"\(.freed) \(.stopped | index($p) != null)"')" "true true"
  t "this shell survived the ancestor climb" "$(running "$$")" "yes"

  # (3) a recycled pid is not the lane's stack: a start time that does not match is left alone.
  sleep 60 & stranger=$!; PIDS="$PIDS $stranger"
  mkdir -p "$KIT_STATE_DIR/qa/32"
  printf '%s\n' "$stranger" > "$KIT_STATE_DIR/qa/32/pid"
  printf 'Thu Jan  1 00:00:00 1970\n' > "$KIT_STATE_DIR/qa/32/started"
  printf 'WEB_PORT=%s\n' "$(free_port)" > "$KIT_STATE_DIR/qa/32/ports"
  err="$(qa_cli stop --lane 32 2>&1 >/dev/null)"; rc=$?
  t "a recorded pid with another start time is not stopped" "$(running "$stranger")" "yes"
  yes "that stop reports nothing stopped" "$err" "nothing stopped"
  t "that stop still returns 0: the port is free" "$rc" "0"
  kill "$stranger" 2>/dev/null

  # (4) with no holder lookup the recorded tree is still stopped, and the ports are not called free.
  ( exec sh -c 'sleep 60 & wait' ) >/dev/null 2>&1 &
  sup33=$!; PIDS="$PIDS $sup33"
  mkdir -p "$KIT_STATE_DIR/qa/33"
  printf '%s\n' "$sup33" > "$KIT_STATE_DIR/qa/33/pid"
  printf 'WEB_PORT=%s\n' "$(free_port)" > "$KIT_STATE_DIR/qa/33/ports"
  err="$(QA_PORT_TOOL=none qa_cli stop --lane 33 2>&1 >/dev/null)"; rc=$?
  t "without lsof or ss the recorded tree is still stopped" "$(running "$sup33")" "no"
  t "without lsof or ss a clean stop is rc 0" "$rc" "0"
  yes "without lsof or ss the ports are reported as not checked" "$err" "ports NOT checked"
  no "without lsof or ss the ports are not called free" "$err" "ports free"

  # (5) the same stop under zsh, where an unquoted list does not word-split.
  if command -v zsh >/dev/null 2>&1; then
    port35="$(free_port)"
    ( WEB_PORT="$port35" exec sh -c "$SUPERVISE" ) >/dev/null 2>&1 &
    sup35=$!; PIDS="$PIDS $sup35"
    mkdir -p "$KIT_STATE_DIR/qa/35"
    printf '%s\n' "$sup35" > "$KIT_STATE_DIR/qa/35/pid"
    printf 'WEB_PORT=%s\n' "$port35" > "$KIT_STATE_DIR/qa/35/ports"
    wait_listen "$port35"
    lis35="$(qa_port_pids "$port35" | head -n 1)"
    err="$(zsh -c "cd '$P'; . '$ROOT/scripts/lib/qa-lane.sh'; qa_stop 35" 2>&1 >/dev/null)"; rc=$?
    t "zsh: stop returns 0" "$rc" "0"
    sleep 0.5
    t "zsh: the port has no listener after stop" "$(listening "$port35")" "no"
    t "zsh: the supervisor pid is gone" "$(running "$sup35")" "no"
    yes "zsh: stop reports both processes" "$err" "stopped 2 process(es): "
    yes "zsh: the listener is in the report" "$err" "$lis35"
    err="$(zsh -c "cd '$P'; . '$ROOT/scripts/lib/qa-lane.sh'; qa_stop 35" 2>&1 >/dev/null)"; rc=$?
    t "zsh: a second stop returns 0" "$rc" "0"
    yes "zsh: a second stop reports nothing stopped" "$err" "nothing stopped"
  else
    echo "ok: zsh absent — skipping the zsh stop pass (dependency-light gate)"
  fi

  # (6) a port somebody already listens on refuses the launch, before any record is written. The
  # curl stub answers 200 on that port, so without the refusal the stranger makes the lane "usable".
  slot36="$(wt_port_slot "$P" 36 "$P")"
  port36="$(free_port)"
  ( WEB_PORT="$port36" exec perl "$TMP/listen.pl" ) >/dev/null 2>&1 &
  squat36=$!; PIDS="$PIDS $squat36"
  wait_listen "$port36"
  write_cfg 'exec sleep 60' "[{\"env\":\"WEB_PORT\",\"base\":$(( port36 - slot36 * 10 ))}]" '[{"env":"WEB_PORT","path":"/"}]'
  answers ":$port36 200"
  launches="$(events qa.launch)"
  err="$(qa_cli up --lane 36 --timeout 5 2>&1 >/dev/null)"; rc=$?
  t "up refuses a lane whose port is already in use" "$rc" "2"
  yes "the refusal names the port" "$err" "WEB_PORT=$port36"
  yes "the refusal names the listener" "$err" "pid $squat36"
  t "a refused launch writes no ports or pid record" "$([ -e "$KIT_STATE_DIR/qa/36/ports" ] || [ -e "$KIT_STATE_DIR/qa/36/pid" ] && echo yes || echo no)" "no"
  t "a refused launch emits no launch event" "$(events qa.launch)" "$launches"
  qa_cli open --lane 36 --print >/dev/null 2>&1; t "open on the refused lane is a refusal" "$?" "2"
  qa_cli stop --lane 36 >/dev/null 2>&1
  t "the listener that was there first is still running" "$(running "$squat36")" "yes"
  t "qa_port_held sees that listener" "$(qa_port_held "$port36" && echo yes || echo no)" "yes"
  kill "$squat36" 2>/dev/null

  # (7) a listener that takes the lane's port AFTER the launch is not the lane's: stop ends the
  # launched command, leaves the stranger, and exits 1; --force stops the stranger too.
  slot37="$(wt_port_slot "$P" 37 "$P")"
  port37="$(free_port)"
  write_cfg 'exec sleep 60' "[{\"env\":\"WEB_PORT\",\"base\":$(( port37 - slot37 * 10 ))}]" '[{"env":"WEB_PORT","path":"/"}]'
  answers ":$port37 200"
  qa_cli up --lane 37 --timeout 5 >/dev/null 2>&1; t "a lane on a free port comes up" "$?" "0"
  own37="$(cat "$KIT_STATE_DIR/qa/37/pid" 2>/dev/null)"; PIDS="$PIDS $own37"
  ( WEB_PORT="$port37" exec perl "$TMP/listen.pl" ) >/dev/null 2>&1 &
  squat37=$!; PIDS="$PIDS $squat37"
  wait_listen "$port37"
  err="$(qa_cli stop --lane 37 2>&1 >/dev/null)"; rc=$?
  t "stop ends the command the lane launched" "$(running "$own37")" "no"
  t "stop leaves a listener the lane did not launch" "$(running "$squat37")" "yes"
  t "stop is rc 1 while that listener holds the port" "$rc" "1"
  yes "stop names the listener it left" "$err" "did not launch pid $squat37"
  no "stop does not report the stranger as stopped" "$(printf '%s\n' "$err" | grep 'stopped ')" "$squat37"
  err="$(qa_cli stop --lane 37 --force 2>&1 >/dev/null)"; rc=$?
  t "stop --force stops that listener" "$(running "$squat37")" "no"
  t "stop --force returns 0 once the port is free" "$rc" "0"
  t "a forced stop clears the record" "$([ -e "$KIT_STATE_DIR/qa/37/ports" ] && echo yes || echo no)" "no"
  write_cfg 'exec sleep 60'
fi
QA_PORT_TOOL=none; export QA_PORT_TOOL
QA_PORT_TOOL=none qa_port_tool >/dev/null 2>&1; t "QA_PORT_TOOL=none means no holder lookup" "$?" "1"
qa_cli stop --lane 34 >/dev/null 2>&1;            t "stop on a lane never launched is rc 0" "$?" "0"

# ── the verdict: bound to the reviewed commit, upserted on the PR, a fail mailed back (#299) ────
KIT_MAIL_DIR="$TMP/mail"; export KIT_MAIL_DIR
sha1="$(git -C "$P" rev-parse HEAD)"
printf '31\nhttps://github.com/o/r/pull/31\n%s\ntask/7-review-stack\n' "$sha1" > "$PR_META"
: > "$GH_COMMENTS"
ncomments() { grep -c . "$GH_COMMENTS" 2>/dev/null || true; }
nreceipts() { ls "$KIT_STATE_DIR/receipts/7-qa-"*.json 2>/dev/null | grep -c . || true; }

t "a lane with no verdict reads none" "$(qa_cli verdict 2>/dev/null)" "none"
qa_cli verdict >/dev/null 2>&1; t "reading a lane with no verdict is rc 1" "$?" "1"

ev0="$(events qa.verdict)"
qa_cli verdict pass > "$TMP/v.out" 2> "$TMP/v.err"; rc=$?
t "a pass verdict returns 0" "$rc" "0"
t "the verdict prints the receipt path" "$(cat "$TMP/v.out")" "$KIT_STATE_DIR/receipts/7-qa-1.json"
t "the qa receipt's head_sha is the reviewed commit" "$(jq -r '.head_sha' "$KIT_STATE_DIR/receipts/7-qa-1.json")" "$sha1"
t "the qa receipt is a clean pass" \
  "$(jq -r '"\(.stage) \(.outcome) \(.gate) \(.next_stage) \(.invalid | length)"' "$KIT_STATE_DIR/receipts/7-qa-1.json")" "qa pr-open pass none 0"
t "the first verdict creates the PR comment" "$PR_EVIDENCE_LAST_RESULT" "created"
t "one comment is on the PR" "$(ncomments)" "1"
yes "the comment carries the verdict marker" "$(cat "$GH_COMMENTS")" "cckit:pr-evidence key=qa-verdict"
yes "the comment names the reviewed commit" "$(cat "$GH_COMMENTS")" "commit:  $sha1"
t "a verdict appends one event" "$(( $(events qa.verdict) - ev0 ))" "1"
t "the event carries the verdict, the commit and the PR" \
  "$(grep '"op":"qa.verdict"' "$EVENTS" | tail -n 1 | jq -r '"\(.type) \(.payload.verdict) \(.payload.head) \(.payload.pr) \(.payload.comment) \(.payload.mailed)"')" \
  "op.done pass $sha1 31 created false"
t "a pass mails nobody" "$(find "$KIT_MAIL_DIR" -name '*.md' 2>/dev/null | grep -c . || true)" "0"

qa_cli verdict pass >/dev/null 2>&1
t "the same verdict again edits the comment" "$PR_EVIDENCE_LAST_RESULT" "updated"
t "still one comment on the PR" "$(ncomments)" "1"
t "the same verdict on the same commit rewrites its attempt" "$(nreceipts)" "1"
t "the second verdict appended its own event" "$(( $(events qa.verdict) - ev0 ))" "2"

t "the verdict reads pass against the reviewed commit" "$(qa_verdict_state 7 "$sha1")" "pass"
qa_verdict_state 7 "$sha1" >/dev/null; t "a fresh pass is rc 0" "$?" "0"
t "the verb reads pass on the lane's head" "$(qa_cli verdict 2>/dev/null)" "pass"
t "receipt show prints the qa receipt" "$("$ROOT/bin/cckit" receipt show 7 qa | jq -r '.head_sha')" "$sha1"
t "the same receipt against another head reads stale" "$(qa_verdict_state 7 0000000000000000000000000000000000000000)" "stale"
t "a verdict with no head to compare reads stale" "$(qa_verdict_state 7 '')" "stale"
t "a lane nobody reviewed reads none" "$(qa_verdict_state 99 "$sha1")" "none"

# A later commit on the lane's branch: the recorded pass no longer covers what is there.
git -C "$P" commit -q --allow-empty -m "a later push"
sha2="$(git -C "$P" rev-parse HEAD)"
out="$(qa_cli verdict 2>"$TMP/v.err")"; rc=$?
t "after a later commit the verdict reads stale" "$out" "stale"
t "a stale verdict is rc 1" "$rc" "1"
yes "the stale report names the commit it was recorded against" "$(cat "$TMP/v.err")" "$sha1"
t "--llm reports the state and both commits" \
  "$(CCKIT_OUTPUT=json qa_cli verdict 2>/dev/null | jq -r '"\(.state) \(.head) \(.verdict_head)"')" "stale $sha2 $sha1"
t "--head reads the verdict against a named commit" "$(qa_cli verdict --head "$sha1" 2>/dev/null)" "pass"

# A fail: notes are required, and they go back to the builder's branch as a steer.
qa_cli verdict fail >/dev/null 2>"$TMP/v.err"; t "a fail with no notes is refused" "$?" "2"
yes "the refusal says what is missing" "$(cat "$TMP/v.err")" "a fail needs its notes"
t "a refused verdict writes no receipt" "$(nreceipts)" "1"
qa_cli verdict pass --shot "$TMP/absent.png" >/dev/null 2>&1; t "a screenshot that is not a file is refused" "$?" "2"
qa_cli verdict maybe >/dev/null 2>&1;                          t "an unknown verdict word is refused" "$?" "2"
qa_cli verdict --note "orphan" >/dev/null 2>&1;                t "notes with no verdict are refused" "$?" "2"
qa_cli up pass >/dev/null 2>&1;                                t "pass belongs to verdict only" "$?" "2"
t "none of the refusals wrote a receipt" "$(nreceipts)" "1"

printf 'png' > "$TMP/broken-save.png"
j="$(CCKIT_OUTPUT=json qa_cli verdict fail --note "Save does nothing on /settings/billing" --shot "$TMP/broken-save.png" 2>"$TMP/v.err")"; rc=$?
t "a fail verdict returns 0 once the notes are mailed" "$rc" "0"
t "--llm reports the fail, its commit and the mail" \
  "$(printf '%s' "$j" | jq -r '"\(.verdict) \(.head) \(.pr) \(.attempt) \(.mailed)"')" "fail $sha2 31 2 true"
t "the fail is a new attempt bound to the later commit" "$(jq -r '.head_sha' "$KIT_STATE_DIR/receipts/7-qa-2.json")" "$sha2"
t "the fail receipt sends the work back to build" \
  "$(jq -r '"\(.outcome)|\(.gate)|\(.blocker)|\(.next_stage)|\(.invalid | length)"' "$KIT_STATE_DIR/receipts/7-qa-2.json")" \
  "blocked|fail — Save does nothing on /settings/billing|Save does nothing on /settings/billing|build|0"
mail="$(ls "$KIT_MAIL_DIR"/*/task+7-review-stack/new/*-steer-from-*.md 2>/dev/null)"
t "one steer mail is in the builder branch's mailbox" "$(printf '%s\n' "$mail" | grep -c .)" "1"
yes "the mail is a steer" "$(cat $mail 2>/dev/null)" "kind: steer"
yes "the mail carries the notes" "$(cat $mail 2>/dev/null)" "Save does nothing on /settings/billing"
yes "the mail names the reviewed commit" "$(cat $mail 2>/dev/null)" "$sha2"
yes "the verdict comment was edited in place" "$(grep 'qa-verdict' "$GH_COMMENTS")" "verdict: fail"
t "the screenshot is its own upserted comment" "$(grep -c 'key=qa-screenshot-1' "$GH_COMMENTS")" "1"
yes "the screenshot is a path reference" "$(grep 'qa-screenshot-1' "$GH_COMMENTS")" "$TMP/broken-save.png"
t "verdict and screenshot are the only comments" "$(ncomments)" "2"
t "the lane now reads fail" "$(qa_cli verdict 2>/dev/null)" "fail"
qa_cli verdict >/dev/null 2>&1; t "a fresh fail is rc 1" "$?" "1"
yes "a PR behind the reviewed commit is said out loud" "$(cat "$TMP/v.err")" "reads stale against it until $sha2 is pushed"

# --to names another mailbox; with no PR the verdict is still recorded, and nothing is posted.
rm -f "$PR_META"; before="$(ncomments)"
printf 'Still broken.\nSecond line.\n' > "$TMP/notes.txt"
qa_cli verdict fail --notes-file "$TMP/notes.txt" --to task/50-elsewhere >/dev/null 2>"$TMP/v.err"; rc=$?
t "a fail with no PR still records and mails" "$rc" "0"
t "--to names the mailbox" "$(ls "$KIT_MAIL_DIR"/*/task+50-elsewhere/new/*-steer-from-*.md 2>/dev/null | grep -c .)" "1"
t "with no PR nothing is posted" "$(ncomments)" "$before"
yes "the missing PR is said out loud" "$(cat "$TMP/v.err")" "no pull request found for lane 7"
t "the event records that nothing was posted" \
  "$(grep '"op":"qa.verdict"' "$EVENTS" | tail -n 1 | jq -r '.payload.comment')" "no-pr"
# A lane with no branch and no PR has no commit to bind to: refused, nothing written.
qa_cli verdict pass --lane 77 >/dev/null 2>"$TMP/v.err"; t "a lane with no commit to bind is refused" "$?" "2"
yes "the refusal offers --head" "$(cat "$TMP/v.err")" "pass --head <sha>"
t "the refused lane has no receipt" "$([ -e "$KIT_STATE_DIR/receipts/77-qa-1.json" ] && echo yes || echo no)" "no"
if command -v zsh >/dev/null 2>&1; then
  out="$(zsh -c "cd '$P'; . '$ROOT/scripts/lib/qa-lane.sh'; qa_cli verdict pass --lane 78 --head '$sha2' >/dev/null 2>&1; qa_verdict_state 78 '$sha2'; qa_verdict_state 78 '$sha1'" 2>&1)"
  t "zsh: a verdict records and reads back pass, then stale" "$(printf '%s' "$out" | tr '\n' ' ')" "pass stale"
else
  echo "ok: zsh absent — skipping the zsh verdict pass (dependency-light gate)"
fi

# ── the verb is wired ──────────────────────────────────────────────────────────────────────────
yes "cckit commands lists qa" " $("$ROOT/bin/cckit" commands) " " qa "
answers ":3 200" ":4 200"
"$ROOT/bin/cckit" qa ready --lane 7 --timeout 5 >/dev/null 2>&1; t "cckit qa ready dispatches to the lib" "$?" "0"
yes "cckit qa stop dispatches to the lib" "$("$ROOT/bin/cckit" qa stop --lane 34 2>&1)" "nothing stopped"
# Its own lane, recorded here: lane 78's pass exists only when zsh ran the pass above.
qa_cli verdict pass --lane 79 --head "$sha2" >/dev/null 2>&1
t "cckit qa verdict dispatches to the lib" "$("$ROOT/bin/cckit" qa verdict --lane 79 --head "$sha2" 2>/dev/null)" "pass"
t "cckit qa open dispatches to the lib" "$("$ROOT/bin/cckit" qa open --lane 7 --route /wired --print 2>/dev/null)" "http://localhost:$web7/wired"

[ "$fail" -eq 0 ] && echo "ALL OK (qa-lane)" || echo "qa-lane: FAILURES"
exit "$fail"
