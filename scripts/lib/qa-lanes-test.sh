#!/usr/bin/env bash
# qa-lanes-test.sh — `cckit qa lanes` is a read of what other verbs recorded (#301): one row per
# lane with its branch, worktree, ports, whether something listens on them, and how its verdict
# reads against the local tip of its branch. It writes nothing and calls neither gh nor curl.
#
# Hermetic: a scratch repo, a hand-written port-slot ledger, `gh` and `curl` stubs that only log
# (the log must stay empty across every `lanes` call). One section listens on a loopback port the
# kernel picked; it skips with a printed reason when perl, or both lsof and ss, are absent.
#
# Run:  bash scripts/lib/qa-lanes-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "qa-lanes-test: jq absent — skipping"; exit 0; }
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

# ── gh and curl: log every call and fail. `lanes` must never reach either. ─────────────────────
STUB="$TMP/stub"; mkdir -p "$STUB"
NET_LOG="$TMP/net.log"; export NET_LOG; : > "$NET_LOG"
for o in gh curl; do
  cat > "$STUB/$o" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >> "$NET_LOG"
exit 1
SH
  chmod +x "$STUB/$o"
done
PATH="$STUB:$PATH"; export PATH

# ── the project: three lane branches, one of them checked out in its own worktree ──────────────
P="$TMP/proj"; mkdir -p "$P"
(
  cd "$P" && git init -q . && git config user.email t@t && git config user.name t &&
  git commit -q --allow-empty -m base &&
  git branch task/11-alpha && git branch task/12-beta && git branch task/15-gamma &&
  git worktree add -q "$TMP/wt12" task/12-beta
) || { echo "qa-lanes-test: could not build the fixture repo"; exit 1; }
jq -n '{qa: {command: "sleep 60", route: "/", credentialEnv: [],
             ports: [{env: "WEB_PORT", base: 3000}, {env: "API_PORT", base: 4000}],
             readiness: [{env: "WEB_PORT", path: "/"}]}}' > "$P/cckit.config.json"

KIT_STATE_DIR="$TMP/state"; export KIT_STATE_DIR
KIT_CONFIG="$P/cckit.config.json"; export KIT_CONFIG
QA_PORT_TOOL=none; export QA_PORT_TOOL
cd "$P" || exit 1
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/qa-lane.sh"

lanes()  { qa_cli lanes 2>/dev/null; }
jlanes() { CCKIT_OUTPUT=json qa_cli lanes 2>/dev/null; }
row()    { jlanes | jq -c --arg l "$1" '.[] | select(.lane == $l)'; }
field()  { row "$1" | jq -r "$2"; }

# ── nothing recorded: no lane, rc 0, an empty array ────────────────────────────────────────────
out="$(qa_cli lanes 2>"$TMP/e")"; rc=$?
t "no lane is rc 0" "$rc" "0"
t "no lane prints no table" "$out" ""
yes "no lane says so on stderr" "$(cat "$TMP/e")" "no QA lanes"
t "--llm with no lane is an empty array" "$(jlanes)" "[]"
t "listing created no state directory" "$([ -e "$KIT_STATE_DIR" ] && echo yes || echo no)" "no"

# ── the ledger gives a lane its slot; a row whose worktree is gone is nobody's ─────────────────
mkdir -p "$TMP/wt11"
LEDGER="$P/.git/kit-portslots.tsv"
printf '11\t3\t%s\n12\t5\t%s\n13\t6\t%s\n' "$TMP/wt11" "$TMP/wt12" "$TMP/gone" > "$LEDGER"
t "one lane per ledger row with a live worktree" "$(jlanes | jq -r '[.[].lane] | join(" ")')" "11 12"
t "the lane's branch is the local head carrying its number" "$(field 11 .branch)" "task/11-alpha"
t "a branch checked out nowhere falls back to the ledger's worktree" "$(field 11 .worktree)" "$TMP/wt11"
t "a checked-out branch names its worktree" "$(field 12 .worktree)" "$TMP/wt12"
t "ports with no launch record come from qa.ports and the slot" "$(field 11 '"\(.ports.WEB_PORT) \(.ports.API_PORT)"')" "3030 4030"
t "the second lane's ports are its own slot's" "$(field 12 '"\(.ports.WEB_PORT) \(.ports.API_PORT)"')" "3050 4050"
t "with no tool to read listeners, up is unknown" "$(field 11 .up)" "unknown"
t "a lane nobody reviewed reads none" "$(field 11 .verdict)" "none"

# ── the verdict column: qa_verdict_state against the LOCAL tip of the lane's branch ────────────
tip="$(git -C "$P" rev-parse task/11-alpha)"
qa_cli verdict pass --lane 11 --head "$tip" >/dev/null 2>&1
qa_cli verdict pass --lane 12 --head "$tip" >/dev/null 2>&1
qa_cli verdict fail --lane 15 --head "$tip" --note "the save button stays disabled" >/dev/null 2>&1
qa_cli verdict pass --lane 14 --head "$tip" >/dev/null 2>&1
git -C "$TMP/wt12" commit -q --allow-empty -m "a later push"
: > "$NET_LOG"
t "a receipt alone makes a lane" "$(jlanes | jq -r '[.[].lane] | join(" ")')" "11 12 14 15"
t "a pass on the branch tip reads pass" "$(field 11 .verdict)" "pass"
t "a commit after the verdict reads stale" "$(field 12 .verdict)" "stale"
t "a fail on the branch tip reads fail" "$(field 15 .verdict)" "fail"
t "a verdict with no local branch to compare reads unknown" "$(field 14 .verdict)" "unknown"
t "a lane with no local branch has a null branch and worktree" "$(field 14 '"\(.branch) \(.worktree)"')" "null null"
t "a lane with no slot has no ports" "$(field 15 '.ports | length')" "0"
t "a lane with no ports is up unknown" "$(field 15 .up)" "unknown"

# ── the table: a header, one line per lane, the same words ─────────────────────────────────────
out="$(lanes)"
t "the table has a header and one line per lane" "$(printf '%s\n' "$out" | grep -c .)" "5"
t "the header names the columns" "$(printf '%s\n' "$out" | sed -n 1p | tr -s ' ')" "LANE BRANCH PORTS UP VERDICT WORKTREE"
t "a row reads lane, branch, ports, up, verdict, worktree" \
  "$(printf '%s\n' "$out" | grep '^11 ' | tr -s ' ')" "11 task/11-alpha WEB_PORT=3030 API_PORT=4030 unknown pass $TMP/wt11"
t "an empty cell is a dash" "$(printf '%s\n' "$out" | grep '^14 ' | tr -s ' ')" "14 - - unknown unknown -"

# ── read-only: no file changes, no event, no gh, no curl ───────────────────────────────────────
snap() { { find "$KIT_STATE_DIR" "$LEDGER" "$P/.git/kit-events.jsonl" -type f -exec cksum {} + 2>/dev/null; git -C "$P" worktree list; } | sort; }
before="$(snap)"
lanes >/dev/null; jlanes >/dev/null
t "listing changes no state, ledger or event file" "$(snap)" "$before"
t "listing calls neither gh nor curl" "$(cat "$NET_LOG")" ""
t "the dead ledger row is left for cckit start to reclaim" "$(grep -c '^13	' "$LEDGER")" "1"
t "listing allocates no slot for a lane that has none" "$(grep -c '^15	' "$LEDGER")" "0"

# ── arguments ──────────────────────────────────────────────────────────────────────────────────
qa_cli lanes --lane 11 >/dev/null 2>"$TMP/e"; t "lanes takes no argument" "$?" "2"
yes "the refusal names the argument" "$(cat "$TMP/e")" "unknown argument '--lane'"
yes "the help lists lanes" "$(qa_cli help 2>&1)" "cckit qa lanes"
yes "an unknown subcommand names lanes" "$(qa_cli nope 2>&1)" "verdict|lanes"

# ── up: who listens on the lane's ports ────────────────────────────────────────────────────────
free_port() { perl -MIO::Socket::INET -e 'my $s = IO::Socket::INET->new(Listen => 1, LocalAddr => "127.0.0.1", LocalPort => 0) or exit 1; print $s->sockport' 2>/dev/null; }
unset QA_PORT_TOOL
if ! command -v perl >/dev/null 2>&1; then
  echo "skip: up — perl is absent, so the fixture cannot open a listener"
elif ! qa_port_tool >/dev/null 2>&1; then
  echo "skip: up — neither lsof nor ss is installed, so a port's listener cannot be read"
else
  cat > "$TMP/listen.pl" <<'PL'
use IO::Socket::INET;
my $s = IO::Socket::INET->new(Listen => 5, LocalAddr => "127.0.0.1", LocalPort => $ARGV[0], ReuseAddr => 1) or exit 1;
sleep 600;
PL
  held="$(free_port)"
  perl "$TMP/listen.pl" "$held" & lpid=$!; PIDS="$PIDS $lpid"
  i=0; while [ -z "$(qa_port_pids "$held")" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  idle="$(free_port)"
  # The record `qa up` writes: the ports the lane was launched with win over the computed ones.
  mkdir -p "$KIT_STATE_DIR/qa/11"
  printf 'WEB_PORT=%s\n' "$held" > "$KIT_STATE_DIR/qa/11/ports"
  t "recorded ports replace the computed ones" "$(field 11 '.ports | tostring')" "{\"WEB_PORT\":$held}"
  t "every port listened on is up" "$(field 11 .up)" "up"
  printf 'WEB_PORT=%s\nAPI_PORT=%s\n' "$held" "$idle" > "$KIT_STATE_DIR/qa/11/ports"
  t "some ports listened on is partial" "$(field 11 .up)" "partial"
  printf 'WEB_PORT=%s\n' "$idle" > "$KIT_STATE_DIR/qa/11/ports"
  t "no port listened on is down" "$(field 11 .up)" "down"
  yes "the table carries the same word" "$(lanes | grep '^11 ')" " down "
  lanes >/dev/null
  t "listing leaves the listener it found running" "$(kill -0 "$lpid" 2>/dev/null && echo yes || echo no)" "yes"
  rm -rf "$KIT_STATE_DIR/qa"
fi
QA_PORT_TOOL=none; export QA_PORT_TOOL

# ── zsh reads the same table; the verb is wired ────────────────────────────────────────────────
want="$(jlanes)"
if command -v zsh >/dev/null 2>&1; then
  got="$(zsh -c "cd '$P'; . '$ROOT/scripts/lib/qa-lane.sh'; CCKIT_OUTPUT=json qa_cli lanes" 2>&1)"
  t "zsh: lanes prints the same array" "$got" "$want"
  t "zsh: the table has the same lines" "$(zsh -c "cd '$P'; . '$ROOT/scripts/lib/qa-lane.sh'; qa_cli lanes" 2>&1)" "$(lanes)"
else
  echo "ok: zsh absent — skipping the zsh lanes pass (dependency-light gate)"
fi
t "cckit qa lanes --llm dispatches to the lib" "$("$ROOT/bin/cckit" qa lanes --llm 2>/dev/null)" "$want"
t "cckit qa lanes prints the table" "$("$ROOT/bin/cckit" qa lanes 2>/dev/null)" "$(lanes)"
t "nothing in this run reached gh or curl" "$(cat "$NET_LOG")" ""

[ "$fail" -eq 0 ] && echo "ALL OK (qa-lanes)" || echo "qa-lanes: FAILURES"
exit "$fail"
