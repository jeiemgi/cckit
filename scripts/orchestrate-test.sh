#!/usr/bin/env bash
# orchestrate-test.sh — scenario A06 as a fixture: parallel workers, a blocked dependent, a cap,
# and three distinct collected results, under both launch kinds (E257.6, #263).
#
# Hermetic. A real git repository with a bare origin, and four stubs on PATH:
#   gh      serves the fixture issues and the blocked_by edge (stateful: an issue can be closed)
#   tmux    a pane is a recorded working directory; `send-keys` runs the typed command line in it
#           with bash, in the background — so the test executes the exact line orchestrate types
#   claude  \_ one stub agent under two names: it writes a marker into its working directory, then
#   codex   /  exits 0, exits 3, or blocks until the test kills it, per the issue's fixture file
#
# Per kind, wave 0 asks for four issues under --cap 2:
#   #11 forced to fail · #12 killed mid-run · #13 blocked_by #11 (open) · #14 past the cap
# then, with #11 closed, wave 1 launches #13 and #14 and both succeed.
# What a stub cannot show: that a live Claude Code or Codex session behaves this way. The stub
# proves the launch line, the gate, the cap and the result record are the same for both kinds.
#
# Run: bash scripts/orchestrate-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
command -v jq >/dev/null 2>&1 || { echo "orchestrate-test: jq required" >&2; exit 1; }
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 (missing '$3')"; fail=1 ;; esac; }
no()  { case "$2" in *"$3"*) echo "FAIL: $1 (unexpected '$3')"; fail=1 ;; *) echo "ok: $1" ;; esac; }

TMP="$(cd "$(mktemp -d)" && pwd -P)"
cleanup() {
  # Stop any stub agent still blocked, then remove the fixture.
  find "$TMP" -name 'agent.*.pid' 2>/dev/null | while IFS= read -r p; do kill -9 "$(cat "$p")" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# --- gh stub -------------------------------------------------------------------------------
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
# Fixture gh. $FX_STATE/closed lists closed issue numbers; issue 13 is blocked_by 11.
set -u
JQ=""; POS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) JQ="$2"; shift 2 ;;
    --repo|--json|--state|--limit|-f|-F) shift 2 ;;
    --*) shift ;;
    *) POS+=("$1"); shift ;;
  esac
done
out() { if [ -n "$JQ" ]; then jq -r "$JQ"; else cat; fi; }
case "${POS[0]:-} ${POS[1]:-}" in
  "issue view")
    n="${POS[2]:-}"
    case "$n" in 11|12|13|14) ;; *) exit 1 ;; esac
    st=OPEN; grep -qx "$n" "$FX_STATE/closed" 2>/dev/null && st=CLOSED
    printf '{"title":"wave fixture %s","labels":[{"name":"kind:task"}],"state":"%s","number":%s,"body":""}\n' "$n" "$st" "$n" | out ;;
  api\ *)
    case "${POS[1]:-}" in
      */issues/13/dependencies/blocked_by) echo '[{"number":11}]' | out ;;
      */dependencies/blocked_by)           echo '[]' | out ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB

# --- tmux stub -----------------------------------------------------------------------------
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
# Fixture tmux: a pane is a file holding its working directory. send-keys runs the typed line.
set -u
P="$FX_STATE/panes"; mkdir -p "$P"
cmd="${1:-}"; shift || true
arg_after() { local want="$1"; shift; while [ "$#" -gt 1 ]; do [ "$1" = "$want" ] && { printf '%s' "$2"; return 0; }; shift; done; return 1; }
case "$cmd" in
  new-session)  arg_after -c "$@" > "$P/%0"; echo 0 > "$P/count" ;;
  display)      echo '%0' ;;
  split-window) n=$(( $(cat "$P/count") + 1 )); echo "$n" > "$P/count"; arg_after -c "$@" > "$P/%$n"; echo "%$n" ;;
  send-keys)
    pane="$(arg_after -t "$@")"; shift 2
    printf '%s\n' "$1" >> "$FX_STATE/typed.log"; echo "$pane" >> "$FX_STATE/typed.panes"
    ( cd "$(cat "$P/$pane")" && bash -c "$1" ) >> "$FX_STATE/pane.log" 2>&1 </dev/null &
    ;;
  kill-session|select-layout|set|select-window|attach) : ;;
  *) echo "tmux stub: unexpected '$cmd'" >&2; exit 1 ;;
esac
STUB

# --- the stub agent, installed as both `claude` and `codex` -----------------------------------
cat > "$BIN/agent-stub" <<'STUB'
#!/usr/bin/env bash
# Behaves per $FX_STATE/behavior.<issue>: ok | fail | hang. The issue comes from the worktree name.
set -u
kind="$(basename "$0")"
num="$(basename "$PWD" | sed -E 's/^[a-z]+\+([0-9]+)-.*/\1/')"
printf '%s\n' "$kind" > "$PWD/agent-marker.txt"
printf '%s\n' "$#" > "$FX_STATE/argc.$num"
[ "$#" -ge 1 ] && eval "last=\${$#}" && printf '%s' "$last" > "$FX_STATE/seed.$num"
case "$(cat "$FX_STATE/behavior.$num" 2>/dev/null)" in
  fail) exit 3 ;;
  hang) echo "$$" > "$FX_STATE/agent.$num.pid"; while :; do sleep 1; done ;;
  *)    exit 0 ;;
esac
STUB
chmod +x "$BIN/gh" "$BIN/tmux" "$BIN/agent-stub"
cp "$BIN/agent-stub" "$BIN/claude"; cp "$BIN/agent-stub" "$BIN/codex"

wait_for() {  # wait_for <file> — up to 30s
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$1" ]
}
result_of() { printf '%s\n' "$1" | jq -r --argjson n "$2" '.[] | select(.issue == $n) | .result'; }

for kind in claude codex; do
  echo "== A06 under launch kind '$kind' =="
  FX="$TMP/$kind"; REPO="$FX/repo"; FX_STATE="$FX/state"; export FX_STATE
  mkdir -p "$REPO" "$FX_STATE"; : > "$FX_STATE/closed"
  git init -q --bare "$FX/origin.git"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email kit-test@example.com; git -C "$REPO" config user.name kit-test
  printf '{"github":{"repo":"fixture/wave","owner":"fixture","baseBranch":"main","projectsV2":false},"project":{"slug":"wave"}}\n' > "$REPO/cckit.config.json"
  printf '.claude/worktrees/\n.cckit/\n' > "$REPO/.gitignore"
  git -C "$REPO" add -A && git -C "$REPO" commit -q -m "fixture"
  git -C "$REPO" remote add origin "$FX/origin.git" && git -C "$REPO" push -q origin main
  orch() { ( cd "$REPO" && PATH="$BIN:$PATH" KIT_WT_INSTALL=0 bash "$ROOT/bin/cckit" orchestrate "$@" ) 2>&1; }

  # ── wave 0: #11 fails, #12 is killed, #13 is blocked, #14 is past the cap ────────────────
  echo fail > "$FX_STATE/behavior.11"; echo hang > "$FX_STATE/behavior.12"
  out="$(orch --detach --cap 2 --agent "$kind" --session="a06 $kind" 11 12 13 14)"; rc=$?
  t   "$kind: wave 0 launches (rc)" "$rc" "0"
  has "$kind: the dependent is not launched" "$out" "#13  SKIP - blocked_by open: 11"
  has "$kind: the cap holds — #14 is queued" "$out" "queued past cap (run a later wave): 14"
  has "$kind: launch names the agent kind"   "$out" "agent '$kind'"
  wt11="$(find "$REPO/.claude/worktrees" -maxdepth 1 -name 'task+11-*')"
  wt12="$(find "$REPO/.claude/worktrees" -maxdepth 1 -name 'task+12-*')"
  t   "$kind: two writers, two worktrees" "$([ -n "$wt11" ] && [ -n "$wt12" ] && [ "$wt11" != "$wt12" ] && echo yes || echo no)" "yes"
  t   "$kind: exactly the capped number of worktrees" "$(find "$REPO/.claude/worktrees" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" "2"
  t   "$kind: each worktree is on its own branch" "$(git -C "$wt11" rev-parse --abbrev-ref HEAD) $(git -C "$wt12" rev-parse --abbrev-ref HEAD)" "task/11-wave-fixture-11 task/12-wave-fixture-12"
  t   "$kind: two panes were typed into" "$(LC_ALL=C sort -u "$FX_STATE/typed.panes" | wc -l | tr -d ' ')" "2"
  has "$kind: the pane runs the agent under the result wrapper" "$(sed -n 1p "$FX_STATE/typed.log")" "/scripts/wave-worker.sh' 'a06 $kind' 11 -- $kind '"

  wait_for "$FX_STATE/agent.12.pid" || { echo "FAIL: $kind: #12 never started"; fail=1; }
  mid="$(orch --results --session="a06 $kind" --llm 2>/dev/null)"
  t   "$kind: a live worker reads running" "$(result_of "$mid" 12)" "running"
  kill -9 "$(cat "$FX_STATE/agent.12.pid")" 2>/dev/null
  res="$(orch --results --session="a06 $kind" --llm --wait 30 2>/dev/null)"; rc=$?
  t   "$kind: forced failure reads failure"     "$(result_of "$res" 11)" "failure"
  t   "$kind: killed worker reads interrupted"  "$(result_of "$res" 12)" "interrupted"
  t   "$kind: failure keeps the agent's exit status" "$(printf '%s' "$res" | jq -r '.[] | select(.issue == 11) | .rc')" "3"
  t   "$kind: a signal exit status is kept"     "$(printf '%s' "$res" | jq -r '.[] | select(.issue == 12) | .rc')" "137"
  t   "$kind: results carry the launch kind"    "$(printf '%s' "$res" | jq -r '[.[].agent] | unique | join(",")')" "$kind"
  t   "$kind: only launched workers have results" "$(printf '%s' "$res" | jq -r '[.[].issue] | join(",")')" "11,12"
  t   "$kind: a failed wave is rc 1"            "$rc" "1"
  human="$(orch --results --session="a06 $kind")"
  has "$kind: human results name each state" "$human" "interrupted"
  t   "$kind: each writer wrote in its own worktree" "$(cat "$wt11/agent-marker.txt" 2>/dev/null)$(cat "$wt12/agent-marker.txt" 2>/dev/null)" "$kind$kind"
  t   "$kind: the shared checkout was not written to" "$([ -e "$REPO/agent-marker.txt" ] && echo written || echo clean)$(git -C "$REPO" status --porcelain | wc -l | tr -d ' ')" "clean0"
  has "$kind: the seed reaches the agent as one argument" "$(cat "$FX_STATE/seed.11" 2>/dev/null)" "issue #11"
  t   "$kind: the agent got exactly the seed" "$(cat "$FX_STATE/argc.11" 2>/dev/null)" "1"

  # ── wave 1: the blocker is closed, so the dependent and the queued issue launch ────────────
  echo 11 >> "$FX_STATE/closed"; : > "$FX_STATE/typed.log"
  out="$(orch --detach --cap 2 --agent "$kind" --session="a06 $kind w1" 13 14)"; rc=$?
  t   "$kind: wave 1 launches (rc)" "$rc" "0"
  no  "$kind: the dependent is no longer blocked" "$out" "SKIP"
  res="$(orch --results --session="a06 $kind w1" --llm --wait 30 2>/dev/null)"; rc=$?
  t   "$kind: both wave-1 workers read success" "$(result_of "$res" 13) $(result_of "$res" 14)" "success success"
  t   "$kind: an all-success wave is rc 0" "$rc" "0"
  t   "$kind: four writers, four worktrees" "$(find "$REPO/.claude/worktrees" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')" "4"
  w0="$(orch --results --session="a06 $kind" --llm 2>/dev/null)"
  t   "$kind: success, failure and interrupted are three distinct values" \
      "$(printf '%s\n%s\n' "$w0" "$res" | jq -r -s 'add | [.[].result] | unique | join(",")')" "failure,interrupted,success"

  # ── the read verb's own edges ──────────────────────────────────────────────────────────
  orch --results --session="never launched" >/dev/null 2>&1; t "$kind: no records is rc 1" "$?" "1"
  orch --results --wait soon >/dev/null 2>&1;               t "$kind: a non-numeric --wait is refused" "$?" "2"
done

# Both kinds went through one code path and produced the same shape of record.
t "claude and codex results differ only in the agent field" \
  "$(cd "$TMP/claude/repo" && FX_STATE="$TMP/claude/state" PATH="$BIN:$PATH" bash "$ROOT/bin/cckit" orchestrate --results --session="a06 claude" --llm 2>/dev/null | jq -c '[.[] | {issue, result, rc, runtime}]')" \
  "$(cd "$TMP/codex/repo"  && FX_STATE="$TMP/codex/state"  PATH="$BIN:$PATH" bash "$ROOT/bin/cckit" orchestrate --results --session="a06 codex"  --llm 2>/dev/null | jq -c '[.[] | {issue, result, rc, runtime}]')"

echo ""
[ "$fail" -eq 0 ] && echo "PASS: orchestrate A06 — worktree per writer, blocked dependent, cap, three distinct results (claude + codex)" || echo "FAILED"
exit "$fail"
