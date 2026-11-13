#!/usr/bin/env bash
# autopilot-run-test.sh — scenario A07 as a fixture: a bounded headless objective, under both
# launch kinds, stopped by a failing check, a no-progress round, a kill mid-run (TERM and KILL) and
# each configured limit, then resumed without a second PR or a second agent (E257.7, #264).
#
# Hermetic. `claude` and `codex` are stub scripts on PATH whose behaviour STUB_MODE selects, `gh` is
# a stub that records every `pr create`, and origin is a bare repo in the temp dir. This proves what
# cckit's code decides around an agent process; it does not prove either real agent behaves.
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "autopilot-run-test: jq absent — skipping"; exit 0; }
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/agent-launch.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '[$2]' lacks '$3'"; fail=1 ;; esac; }

# ── fixture: a project on a task branch, with a bare origin ──────────────────────────────────────
mkdir -p "$TMP/bin" "$TMP/project"
git init -q --bare "$TMP/origin.git"
P="$TMP/project"
git -C "$P" init -q
git -C "$P" config user.email t@example.invalid
git -C "$P" config user.name tester
git -C "$P" config commit.gpgsign false
printf '%s\n' '{"project":{"name":"fx","slug":"fx"},"github":{"repo":"fixture/project","owner":"fixture","baseBranch":"develop","projectsV2":false}}' > "$P/cckit.config.json"
echo seed > "$P/work.txt"
git -C "$P" add -A && git -C "$P" commit -q -m seed
git -C "$P" branch -M develop
git -C "$P" remote add origin "$TMP/origin.git"
git -C "$P" push -q origin develop
git -C "$P" checkout -q -b task/7-thing

export KIT_CONFIG="$P/cckit.config.json"
export KIT_STATE_DIR="$TMP/state"
export FX="$TMP"
unset KIT_BASE_BRANCH CCKIT_AGENT CCKIT_OUTPUT 2>/dev/null || true
STATE="$TMP/state/autopilot/task_7-thing.json"

# The agent stub. One file, installed under both names; it reads the prompt like the real CLIs do
# and prints usage in the shape its name documents.
cat > "$TMP/bin/agent-stub" <<'STUB'
#!/usr/bin/env bash
me="$(basename "$0")"
printf '%s\n' "$*" > "$FX/$me.argv"
cat > "$FX/$me.prompt"
n="$(cat "$FX/rounds" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$FX/rounds"
usage() {
  case "$me" in
    claude) printf '{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":50}}\n' ;;
    codex)  printf '{"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":50}}\n' ;;
  esac
}
work() { echo "round $n" >> work.txt; git add -A >/dev/null 2>&1; git commit -q -m "round $n"; }
case "${STUB_MODE:-work}" in
  work)    work; [ "$n" -ge "${STUB_DONE_AT:-1}" ] && touch "$FX/done.flag"; usage ;;
  idle)    usage ;;
  nousage) work; echo "plain text, no usage" ;;
  fail)    echo "boom" >&2; exit 9 ;;
  hang)    echo "$$" > "$FX/agent.pid"; sleep 300 ;;
esac
STUB
chmod +x "$TMP/bin/agent-stub"
cp "$TMP/bin/agent-stub" "$TMP/bin/claude"; cp "$TMP/bin/agent-stub" "$TMP/bin/codex"

cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  'pr list')    [ -f "$FX/pr.url" ] && cat "$FX/pr.url"; exit 0 ;;
  'pr create')  echo "create $*" >> "$FX/gh.log"
                echo "https://github.com/fixture/project/pull/41" | tee "$FX/pr.url" ;;
  'issue view') echo '{"title":"thing","labels":[{"name":"kind:task"}],"milestone":null}' ;;
  *)            echo "other $*" >> "$FX/gh.log"; exit 0 ;;
esac
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

cd "$P" || exit 1
run()     { bash "$ROOT/scripts/autopilot.sh" run "$@" > "$TMP/out" 2>&1; }
reason()  { jq -r .reason "$STATE" 2>/dev/null; }
field()   { jq -r "$1" "$STATE" 2>/dev/null; }
creates() { if [ -f "$TMP/gh.log" ]; then grep -c '^create ' "$TMP/gh.log"; else echo 0; fi; }
reset()   { rm -rf "$TMP/state" "$TMP/rounds" "$TMP/done.flag" "$TMP/agent.pid" "$TMP/gh.log" "$TMP/pr.url"; }
UNTIL="test -f '$TMP/done.flag'"

# ── refusals write nothing ───────────────────────────────────────────────────────────────────────
run --agent aider --objective x;              t "an agent with no headless form is refused" "$?" "2"
has "and says which are supported" "$(cat "$TMP/out")" "supported: claude, codex"
run;                                          t "no objective is refused"                 "$?" "2"
run --objective x --notify me;                t "--notify is refused as unsupported"      "$?" "2"
has "and says it is not supported" "$(cat "$TMP/out")" "'--notify' is not supported"
run --objective x --max-iters 0;              t "a zero limit is refused"                 "$?" "2"
run --objective x --max-tokens lots;          t "a non-numeric token limit is refused"    "$?" "2"
run --objective x --publish;                  t "--publish without --summary is refused"  "$?" "2"
run --resume;                                 t "--resume with no state is refused"       "$?" "2"
git checkout -q develop
run --objective x;                            t "the base branch is refused"              "$?" "2"
git checkout -q task/7-thing
t "no refusal started an agent" "$([ -f "$TMP/rounds" ] && echo ran || echo no)" "no"
t "no refusal wrote state"      "$([ -d "$TMP/state" ] && echo wrote || echo no)" "no"

run --dry-run --agent codex --agent-arg -s --agent-arg workspace-write --objective x --max-tokens 9
t "--dry-run exits 0" "$?" "0"
has "--dry-run shows the non-interactive codex line" "$(cat "$TMP/out")" "'codex' exec --json '-s' 'workspace-write' -"
t "--dry-run wrote no state" "$([ -d "$TMP/state" ] && echo wrote || echo no)" "no"

# ── --until that already passes: exit 0, no round, and stderr says nothing was done (#496) ───────
reset
bash "$ROOT/scripts/autopilot.sh" run --objective x --until "true" > "$TMP/out" 2> "$TMP/err"
t "an --until that already passes exits 0" "$?" "0"
t "reason is done" "$(reason)" "done"
t "no round ran" "$(field .rounds)" "0"
t "no agent was started" "$([ -f "$TMP/rounds" ] && echo ran || echo no)" "no"
has "stderr says no round ran and nothing changed" "$(cat "$TMP/err")" "no round ran and nothing was changed"
has "stderr names --check as the gate flag" "$(cat "$TMP/err")" 'use --check "<cmd>"'
# A run that did work before --until passed is not told that.
reset
run --objective x --until "$UNTIL"
case "$(cat "$TMP/out")" in *"no round ran"*) echo "FAIL: a run that worked was told no round ran"; fail=1 ;; *) echo "ok: a run that worked gets no such notice" ;; esac

# ── every stop reason, under both launch kinds ───────────────────────────────────────────────────
for agent in claude codex; do
  # done: the completion check passes after round 2.
  reset
  STUB_DONE_AT=2 run --agent "$agent" --objective "build the thing" --until "$UNTIL" --agent-arg --flag
  t "[$agent] a met --until exits 0" "$?" "0"
  t "[$agent] reason is done"        "$(reason)" "done"
  t "[$agent] it took two rounds"    "$(field .rounds)" "2"
  t "[$agent] tokens come from the runtime's output" "$(field .usage.tokens)" "300"
  t "[$agent] usage names its source" "$(field .usage.source)" "$agent"
  has "[$agent] the objective reached the agent on stdin" "$(cat "$TMP/$agent.prompt")" "build the thing"
  has "[$agent] round 2 was told why round 1 was not enough" "$(cat "$TMP/$agent.prompt")" "It failed after the previous round"
  t "[$agent] a finished run offers no resume" "$(field .resume)" ""
  case "$agent" in
    claude) t "[claude] argv is print mode + json"   "$(cat "$TMP/claude.argv")" "-p --output-format json --flag"
            t "[claude] cost is what claude printed" "$(field .usage.cost_usd)" "0.02" ;;
    codex)  t "[codex] argv is exec + json + stdin"  "$(cat "$TMP/codex.argv")" "exec --json --flag -"
            t "[codex] cost is unknown, never a Claude price" "$(field .usage.cost_usd)" "unknown" ;;
  esac

  # failing check: the work is complete, the gate is not green, nothing is published.
  reset
  run --agent "$agent" --objective x --until "$UNTIL" --check "echo gate-red; exit 1" --publish --summary s
  t "[$agent] a failing gate exits 6"     "$?" "6"
  t "[$agent] reason is check-failed"     "$(reason)" "check-failed"
  t "[$agent] a failing gate opens no PR" "$(creates)" "0"
  has "[$agent] the gate output is kept"  "$(cat "$TMP/state/autopilot/task_7-thing.check.out")" "gate-red"

  # no-progress: the agent exits 0 having changed nothing.
  reset
  STUB_MODE=idle run --agent "$agent" --objective x --until "$UNTIL"
  t "[$agent] a round that changed nothing exits 5" "$?" "5"
  t "[$agent] reason is no-progress"                "$(reason)" "no-progress"
  t "[$agent] it stopped after that one round"      "$(field .rounds)" "1"

  # configured limit: rounds.
  reset
  STUB_DONE_AT=99 run --agent "$agent" --objective x --until "$UNTIL" --max-iters 2
  t "[$agent] the round limit exits 4"   "$?" "4"
  t "[$agent] reason is limit-iters"     "$(reason)" "limit-iters"
  t "[$agent] exactly two rounds ran"    "$(cat "$TMP/rounds")" "2"
  has "[$agent] the state names the resume command" "$(field .resume)" "cckit autopilot run --resume"
  # Resuming under the same limit starts no round: the counter carried over.
  STUB_DONE_AT=99 run --resume
  t "[$agent] resume under the same limit stops again" "$(reason)" "limit-iters"
  t "[$agent] and starts no agent"                     "$(cat "$TMP/rounds")" "2"
  # Raising the limit on resume buys exactly the extra rounds.
  STUB_DONE_AT=3 run --resume --max-iters 3
  t "[$agent] a raised limit lets the run finish" "$(reason)" "done"
  t "[$agent] rounds continue from the count"     "$(field .rounds)" "3"
  t "[$agent] tokens accumulate across the resume" "$(field .usage.tokens)" "450"

  # configured limit: wall clock. The hung agent is killed, not left running.
  reset
  STUB_MODE=hang run --agent "$agent" --objective x --round-seconds 1
  t "[$agent] the time bound exits 4"  "$?" "4"
  t "[$agent] reason is limit-seconds" "$(reason)" "limit-seconds"
  apid="$(cat "$TMP/agent.pid" 2>/dev/null)"
  t "[$agent] the hung agent is gone" "$([ -n "$apid" ] && kill -0 "$apid" 2>/dev/null && echo alive || echo gone)" "gone"

  # configured limit: tokens, checked between rounds from reported usage (150 per round).
  reset
  STUB_DONE_AT=99 run --agent "$agent" --objective x --until "$UNTIL" --max-tokens 200
  t "[$agent] the token ceiling exits 4" "$?" "4"
  t "[$agent] reason is limit-tokens"    "$(reason)" "limit-tokens"
  t "[$agent] it stopped once 300 >= 200, after round 2" "$(cat "$TMP/rounds")" "2"

  # a token ceiling the runtime gives no usage for is treated as reached, not ignored.
  reset
  STUB_MODE=nousage run --agent "$agent" --objective x --until "$UNTIL" --max-tokens 200
  t "[$agent] an uncheckable ceiling exits 4" "$?" "4"
  t "[$agent] reason is usage-unknown"        "$(reason)" "usage-unknown"
  t "[$agent] tokens read unknown"            "$(field .usage.tokens)" "unknown"
  t "[$agent] cost reads unknown"             "$(field .usage.cost_usd)" "unknown"
  t "[$agent] one round ran before it stopped" "$(cat "$TMP/rounds")" "1"

  # the agent itself fails.
  reset
  STUB_MODE=fail run --agent "$agent" --objective x
  t "[$agent] a failing agent exits 3" "$?" "3"
  t "[$agent] reason is agent-failed"  "$(reason)" "agent-failed"

  # kill mid-run, then resume: one PR, and none on a second resume.
  reset
  STUB_MODE=hang bash "$ROOT/scripts/autopilot.sh" run --agent "$agent" --objective x --until "$UNTIL" \
    --publish --summary "the thing works" > "$TMP/bg.out" 2>&1 &
  dpid=$!
  i=0; while [ ! -f "$TMP/agent.pid" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  apid="$(cat "$TMP/agent.pid" 2>/dev/null)"
  t "[$agent] the state says running while the agent works" "$(field .status)" "running"
  run --agent "$agent" --objective y --fresh
  t "[$agent] a second run on the live branch is refused" "$?" "2"
  kill -TERM "$dpid"; wait "$dpid"
  t "[$agent] a killed run exits 130"   "$?" "130"
  t "[$agent] reason is interrupted"    "$(reason)" "interrupted"
  t "[$agent] status is stopped"        "$(field .status)" "stopped"
  t "[$agent] the agent died with it"   "$([ -n "$apid" ] && kill -0 "$apid" 2>/dev/null && echo alive || echo gone)" "gone"
  t "[$agent] no PR from a killed run"  "$(creates)" "0"
  # The interrupted round printed no usage, so the total is unknown, not the sum without it.
  t "[$agent] an interrupted round reads tokens unknown" "$(field .usage.tokens)" "unknown"
  t "[$agent] and cost unknown"                          "$(field .usage.cost_usd)" "unknown"
  t "[$agent] the record leaves no round open"           "$(field .round_open)" "false"
  run --objective again
  t "[$agent] a new run over a stopped one is refused" "$?" "2"
  has "[$agent] and points at --resume" "$(cat "$TMP/out")" "--resume"

  run --resume
  t "[$agent] the resumed run finishes"       "$?" "0"
  t "[$agent] reason is done after resume"    "$(reason)" "done"
  t "[$agent] the interrupted round counted"  "$(field .rounds)" "2"
  t "[$agent] exactly one PR was opened"      "$(creates)" "1"
  t "[$agent] the PR is recorded"             "$(field .pr_url)" "https://github.com/fixture/project/pull/41"
  run --resume
  t "[$agent] resuming a finished run exits 0" "$?" "0"
  t "[$agent] and opens no second PR"          "$(creates)" "1"

  # A token ceiling cannot be checked across an interrupted round: resuming under one stops with
  # usage-unknown before another round starts, instead of counting the cut-short round as zero.
  reset
  STUB_MODE=hang bash "$ROOT/scripts/autopilot.sh" run --agent "$agent" --objective x --until "$UNTIL" > "$TMP/bg.out" 2>&1 &
  dpid=$!
  i=0; while [ ! -f "$TMP/agent.pid" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  kill -TERM "$dpid"; wait "$dpid"
  run --resume --max-tokens 100000
  t "[$agent] resume under --max-tokens after an interrupt exits 4" "$?" "4"
  t "[$agent] reason is usage-unknown, not an undercount"           "$(reason)" "usage-unknown"
  t "[$agent] and no further round ran"                             "$(cat "$TMP/rounds")" "1"

  # The runner is killed outright (SIGKILL): no trap runs. The agent must not outlive it, the
  # round it left open is counted on resume, and a second resume does not count it twice.
  if command -v perl >/dev/null 2>&1; then
    reset
    STUB_MODE=hang bash "$ROOT/scripts/autopilot.sh" run --agent "$agent" --objective x --until "$UNTIL" > "$TMP/bg.out" 2>&1 &
    dpid=$!
    i=0; while [ ! -f "$TMP/agent.pid" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
    apid="$(cat "$TMP/agent.pid" 2>/dev/null)"
    t "[$agent] the running agent is recorded beside the state" "$([ -s "$TMP/state/autopilot/task_7-thing.agent.pid" ] && echo yes || echo no)" "yes"
    kill -KILL "$dpid"; wait "$dpid" 2>/dev/null
    i=0; while [ -n "$apid" ] && kill -0 "$apid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
    t "[$agent] the agent does not outlive a SIGKILLed runner" "$([ -n "$apid" ] && kill -0 "$apid" 2>/dev/null && echo alive || echo gone)" "gone"
    # The watchdog reaps the agent and then exits; until it has, a start is refused, correctly.
    i=0; while al_pidfile_alive "$TMP/state/autopilot/task_7-thing.agent.pid" && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
    t "[$agent] nor does the process recorded for it" "$(al_pidfile_alive "$TMP/state/autopilot/task_7-thing.agent.pid" && echo alive || echo gone)" "gone"
    t "[$agent] the dead runner left status running"           "$(field .status)" "running"
    t "[$agent] with the round marked open"                    "$(field .round_open)" "true"
    run --resume --max-tokens 100000
    t "[$agent] resume after SIGKILL under --max-tokens exits 4" "$?" "4"
    t "[$agent] the open round made usage unknown"               "$(reason)" "usage-unknown"
    t "[$agent] no second agent was started"                     "$(cat "$TMP/rounds")" "1"
    t "[$agent] the open round is closed in the record"          "$(field .round_open)" "false"
  fi

  # Without the watchdog (no perl) a SIGKILLed runner can leave its agent alive. The recorded pid
  # is what stops the next start: a live one refuses --resume, --fresh and a new run alike.
  reset
  STUB_MODE=hang bash "$ROOT/scripts/autopilot.sh" run --agent "$agent" --objective x --until "$UNTIL" > "$TMP/bg.out" 2>&1 &
  dpid=$!
  i=0; while [ ! -f "$TMP/agent.pid" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
  kill -TERM "$dpid"; wait "$dpid"
  sleep 300 & orphan=$!
  jq '.status = "running" | .round_open = true' "$STATE" > "$STATE.t" && mv "$STATE.t" "$STATE"
  printf '%s 0\n' "$orphan" > "$TMP/state/autopilot/task_7-thing.agent.pid"
  before_rounds="$(cat "$TMP/rounds")"
  run --resume
  t "[$agent] --resume is refused while the earlier agent lives" "$?" "2"
  has "[$agent] and names the live agent pid" "$(cat "$TMP/out")" "still alive (pid $orphan)"
  run --agent "$agent" --objective y --fresh
  t "[$agent] --fresh is refused too"                 "$?" "2"
  t "[$agent] neither refusal started an agent"       "$(cat "$TMP/rounds")" "$before_rounds"
  kill "$orphan" 2>/dev/null; wait "$orphan" 2>/dev/null
  STUB_DONE_AT=2 run --resume
  t "[$agent] once that agent is gone the run resumes" "$?" "0"
  t "[$agent] and finishes"                            "$(reason)" "done"

  # The state file is lost but the PR exists: a fresh run finds it instead of opening another.
  rm -rf "$TMP/state" "$TMP/rounds" "$TMP/done.flag"
  run --agent "$agent" --objective x --until "$UNTIL" --publish --summary "the thing works"
  t "[$agent] a run with lost state still finishes" "$(reason)" "done"
  t "[$agent] and still opens no second PR"         "$(creates)" "1"
  t "[$agent] it records the PR it found"           "$(field .pr_url)" "https://github.com/fixture/project/pull/41"
done

[ "$fail" -eq 0 ] && echo "ALL OK (autopilot-run: A07 fixture, claude + codex)" || echo "autopilot-run: FAILURES"
exit "$fail"
