#!/usr/bin/env bash
# agent-launch-test.sh — the shared headless launcher (E257.7, #264).
#
# Hermetic: no agent, no network. The commands al_run bounds are plain shell, and the usage parser
# reads fixture output written here in the shapes each runtime documents.
# Run:  bash scripts/lib/agent-launch-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/agent-launch.sh"

fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '[$2]' want '[$3]'"; fail=1; fi; }

# ── which kinds have a headless form ─────────────────────────────────────────────────────────────
al_supported claude;          rc "claude is supported"            "$?" "0"
al_supported codex;           rc "codex is supported"             "$?" "0"
al_supported /opt/bin/codex;  rc "a path to codex is supported"   "$?" "0"
al_supported aider;           rc "an unknown kind is not"         "$?" "1"
al_supported "";              rc "an empty kind is not"           "$?" "1"

# ── the command line ─────────────────────────────────────────────────────────────────────────────
t "claude text"  "$(al_headless_cmd claude text)" "'claude' -p"
t "claude json"  "$(al_headless_cmd claude json)" "'claude' -p --output-format json"
t "codex text reads stdin"  "$(al_headless_cmd codex text)" "'codex' exec -"
t "codex json reads stdin"  "$(al_headless_cmd codex json)" "'codex' exec --json -"
t "args are quoted and precede codex's stdin marker" \
  "$(al_headless_cmd codex json "$(printf '%s\n' '-s' 'workspace-write' "it's here")")" \
  "'codex' exec --json '-s' 'workspace-write' 'it'\\''s here' -"
t "claude args follow the mode" \
  "$(al_headless_cmd claude text "$(printf '%s\n' '--permission-mode' 'acceptEdits')")" \
  "'claude' -p '--permission-mode' 'acceptEdits'"
al_headless_cmd aider text >/dev/null 2>&1; rc "an unsupported kind is rc 2" "$?" "2"
t "an unsupported kind prints no command" "$(al_headless_cmd aider text 2>/dev/null)" ""

# The built line really runs: a stub named codex receives the argv and the prompt on stdin.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/codex" <<'STUB'
#!/usr/bin/env bash
printf 'argv:%s|' "$*"; cat
STUB
chmod +x "$tmp/bin/codex"
got="$(printf 'the prompt' | PATH="$tmp/bin:$PATH" al_run 10 "$(al_headless_cmd codex text "$(printf '%s\n' 'a b')")")"
t "the stub gets the argv and the prompt on stdin" "$got" "argv:exec a b -|the prompt"

# ── the bound ────────────────────────────────────────────────────────────────────────────────────
t "a command inside its bound returns its output" "$(printf '' | al_run 10 'echo alive')" "alive"
t "stdin reaches the command" "$(printf 'piped' | al_run 10 'cat')" "piped"
printf '' | al_run 10 'exit 7' >/dev/null 2>&1
rc "a command's own exit code survives" "$?" "7"
t "AL_PID is cleared after a run" "$AL_PID" ""

start=$(date +%s)
printf 'ignored\n' | al_run 1 'sleep 60' >/dev/null 2>&1
rc "a command past its bound is rc 124" "$?" "124"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 20 ] && echo "ok: it was killed in ${elapsed}s, not left running" \
  || { echo "FAIL: still ran ${elapsed}s after a 1s bound"; fail=1; }

# TERM is ignored -> KILL lands. The marker file proves the command was running when the bound hit.
start=$(date +%s)
al_run 1 "trap '' TERM; echo up > '$tmp/stubborn'; while :; do sleep 1; done" </dev/null >/dev/null 2>&1
rc "a command that ignores TERM is still rc 124" "$?" "124"
t "it had started" "$(cat "$tmp/stubborn" 2>/dev/null)" "up"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 40 ] && echo "ok: KILL followed TERM (${elapsed}s)" \
  || { echo "FAIL: a TERM-ignoring command ran ${elapsed}s"; fail=1; }

# A grandchild does not outlive the bound when perl gives the command its own process group.
if command -v perl >/dev/null 2>&1; then
  al_run 1 "(sleep 300 & echo \$! > '$tmp/grandchild'; wait)" </dev/null >/dev/null 2>&1
  gpid="$(cat "$tmp/grandchild" 2>/dev/null)"
  sleep 1
  if [ -n "$gpid" ] && kill -0 "$gpid" 2>/dev/null; then
    echo "FAIL: grandchild $gpid survived the bound"; kill -KILL "$gpid" 2>/dev/null; fail=1
  else echo "ok: the grandchild died with the bound"; fi
else
  echo "skip: perl absent — process-group kill not exercised"
fi

# ── the pid file, and a caller that dies without running a trap ──────────────────────────────────
# AL_PIDFILE exists while a command runs and is gone once it is reaped.
AL_PIDFILE="$tmp/run.pid"
al_run 10 "cat '$tmp/run.pid' > '$tmp/seen.pid'" </dev/null >/dev/null 2>&1
t "the pid file is there while the command runs" "$([ -s "$tmp/seen.pid" ] && echo yes || echo no)" "yes"
t "and removed once it is reaped" "$([ -e "$tmp/run.pid" ] && echo left || echo gone)" "gone"
al_run 1 'sleep 60' </dev/null >/dev/null 2>&1
t "a command killed at its bound leaves no pid file" "$([ -e "$tmp/run.pid" ] && echo left || echo gone)" "gone"
AL_PIDFILE=""

sleep 60 & live=$!
printf '%s 0\n' "$live" > "$tmp/live.pid"
al_pidfile_alive "$tmp/live.pid"; rc "a recorded live pid reads alive" "$?" "0"
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
al_pidfile_alive "$tmp/live.pid"; rc "a recorded dead pid does not" "$?" "1"
al_pidfile_alive "$tmp/absent.pid"; rc "a missing pid file does not" "$?" "1"
printf 'junk\n' > "$tmp/junk.pid"
al_pidfile_alive "$tmp/junk.pid"; rc "a pid file that holds no pid does not" "$?" "1"

# The shell that called al_run is killed with SIGKILL: no trap runs, nothing calls al_stop. The
# watchdog notices its parent is gone and stops the command's group.
if command -v perl >/dev/null 2>&1; then
  cat > "$tmp/caller.sh" <<CALLER
. "$ROOT/scripts/lib/agent-launch.sh"
al_run 300 "echo \\\$\\\$ > '$tmp/orphan.pid'; exec sleep 300" </dev/null >/dev/null 2>&1
CALLER
  bash "$tmp/caller.sh" & caller=$!
  i=0; while [ ! -s "$tmp/orphan.pid" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i + 1)); done
  opid="$(cat "$tmp/orphan.pid" 2>/dev/null)"
  t "the command started under the caller" "$([ -n "$opid" ] && kill -0 "$opid" 2>/dev/null && echo alive || echo gone)" "alive"
  kill -KILL "$caller"; wait "$caller" 2>/dev/null
  i=0; while [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  if [ -n "$opid" ] && kill -0 "$opid" 2>/dev/null; then
    echo "FAIL: command $opid outlived its SIGKILLed caller"; kill -KILL "$opid" 2>/dev/null; fail=1
  else echo "ok: the command does not outlive a SIGKILLed caller"; fi
else
  echo "skip: perl absent — the watchdog is not exercised"
fi

# ── usage, from the runtime's own output ─────────────────────────────────────────────────────────
cat > "$tmp/claude.json" <<'JSON'
{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.0421,"usage":{"input_tokens":120,"cache_creation_input_tokens":30,"cache_read_input_tokens":50,"output_tokens":75}}
JSON
t "claude: input includes cache tokens, cost is the runtime's own" \
  "$(al_usage claude "$tmp/claude.json")" "200 75 0.0421"

# The same result as the last element of an event array.
printf '%s\n' '[{"type":"system"},{"type":"result","usage":{"input_tokens":5,"output_tokens":6}}]' > "$tmp/claude-arr.json"
t "claude: a result inside an array, no cost printed" "$(al_usage claude "$tmp/claude-arr.json")" "5 6 unknown"

cat > "$tmp/codex.jsonl" <<'JSONL'
{"type":"thread.started","thread_id":"t"}
not json at all
{"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200}}
{"type":"turn.completed","usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":50}}
JSONL
t "codex: turns are summed, a non-JSON line is skipped, cost is unknown" \
  "$(al_usage codex "$tmp/codex.jsonl")" "1500 250 unknown"

printf 'plain text reply\n' > "$tmp/plain.txt"
t "claude: text output has no usage"      "$(al_usage claude "$tmp/plain.txt")"  "unknown unknown unknown"
t "codex: text output has no usage"       "$(al_usage codex "$tmp/plain.txt")"   "unknown unknown unknown"
t "codex output read as claude is unknown, not a wrong number" \
  "$(al_usage claude "$tmp/codex.jsonl")" "unknown unknown unknown"
t "a missing file is unknown"             "$(al_usage codex "$tmp/absent")"      "unknown unknown unknown"
t "an unsupported kind is unknown"        "$(al_usage aider "$tmp/claude.json")" "unknown unknown unknown"
: > "$tmp/empty"
t "an empty file is unknown"              "$(al_usage claude "$tmp/empty")"      "unknown unknown unknown"

[ "$fail" -eq 0 ] && echo "ALL OK (agent-launch)" || echo "agent-launch: FAILURES"
exit "$fail"
