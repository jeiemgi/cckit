#!/usr/bin/env bash
# shellcheck shell=bash
# light-task-run-test.sh — `cckit task run <id>` end to end (#496): start, ONE headless objective
# built from the task record, finish, the review link.
#
# Hermetic, in the style of scripts/autopilot-run-test.sh: `claude` and `codex` are one stub script
# on PATH whose behaviour STUB_MODE selects, `gh` is a stub that logs every call, origin is a bare
# repository in the temp dir. It proves what cckit decides around the agent process (which steps
# run, what opens a review, the exit code); it does not prove a real agent does the task.
#
# Covers: a run from a draft opens one review; a re-run after the review is open reports it and
# starts no agent; a failing gate opens none and exits 6; a stopped earlier run is discarded and a
# round that changed nothing opens none (exit 5); the gate precedence --check > tasks.check > none;
# --no-finish stops before the review; --llm is one JSON object; usage errors.
# Run: bash scripts/lib/light-task-run-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
CCKIT="$(cd "$LIB/../.." && pwd)/bin/cckit"
# shellcheck source=/dev/null
. "$LIB/test-env.sh" && test_env_seal
unset CLAUDE_CODE_REMOTE CCKIT_GH_TRANSPORT
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '[$2]' lacks '[$3]'"; fail=1 ;; esac; }
hasnt() { case "$2" in *"$3"*) echo "FAIL: $1 -> '[$2]' has '[$3]'"; fail=1 ;; *) echo "ok: $1" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "light-task-run-test: jq absent — skipping"; exit 0; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
export FX="$tmp" GH_LOG="$tmp/gh.log" GH_OPEN_URL=""
: > "$GH_LOG"
mkdir -p "$tmp/bin"

# The agent stub: reads the prompt on stdin like the real CLIs, then does what STUB_MODE says in
# the directory it was started in (the task's worktree).
cat > "$tmp/bin/agent-stub" <<'STUB'
#!/usr/bin/env bash
me="$(basename "$0")"
printf '%s\n' "$*" > "$FX/$me.argv"
cat > "$FX/$me.prompt"
pwd > "$FX/$me.cwd"
n="$(cat "$FX/rounds" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$FX/rounds"
case "${STUB_MODE:-work}" in
  work) echo "round $n" >> page.txt; git add -A >/dev/null 2>&1; git commit -q -m "round $n"
        echo "made in round $n" > made.txt ;;   # left uncommitted: `finish --all` has to carry it
  idle) : ;;
esac
printf '{"type":"result","total_cost_usd":0.01,"usage":{"input_tokens":100,"output_tokens":50}}\n'
STUB
chmod +x "$tmp/bin/agent-stub"
cp "$tmp/bin/agent-stub" "$tmp/bin/claude"; cp "$tmp/bin/agent-stub" "$tmp/bin/codex"

cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
{ printf '%s' "$*" | tr '\n' '\036'; echo; } >> "$GH_LOG"
case "$1 $2" in
  "pr list")   case " $* " in *" --head "*) [ -n "$GH_OPEN_URL" ] && echo "$GH_OPEN_URL" ;; esac ;;
  "pr create") echo "https://github.com/o/r/pull/77" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" KIT_WT_INSTALL=0 KIT_STATE_DIR="$tmp/state"

git init -q --bare "$tmp/remote.git"
git clone -q "$tmp/remote.git" "$tmp/work" 2>/dev/null
cd "$tmp/work" || exit 1
git config user.email t@t; git config user.name t; git config commit.gpgsign false
cat > cckit.config.json <<'JSON'
{"kitVersion":"0.0.0","project":{"name":"x","slug":"x","owner":"o","language":"en"},"profile":"p",
 "github":{"repo":"o/r","owner":"o","baseBranch":"develop","projectsV2":false}}
JSON
echo "hello" > page.txt
printf '.claude/worktrees/\n.cckit/\n' > .gitignore
git add -A; git commit -q -m init; git branch -M develop; git push -q origin develop 2>/dev/null
W="$tmp/work"

creates() { grep -c '^pr create' "$GH_LOG" || true; }
rounds()  { cat "$tmp/rounds" 2>/dev/null || echo 0; }
state()   { "$CCKIT" task list --all --llm | jq -r --arg id "$1" '.[] | select(.id == $id) | .state'; }

# ── usage errors start nothing ──────────────────────────────────────────────────────────────────
"$CCKIT" task run >/dev/null 2>&1;                    t "run without an id is a usage error" "$?" "2"
"$CCKIT" task run x1 --max-iters 0 >/dev/null 2>&1;   t "a zero limit is a usage error" "$?" "2"
"$CCKIT" task run x1 --check >/dev/null 2>&1;         t "--check without a value is a usage error" "$?" "2"
"$CCKIT" task run x1 --nope >/dev/null 2>&1;          t "an unknown flag is a usage error" "$?" "2"
"$CCKIT" task run zz9 >/dev/null 2>&1;                t "an unknown task is refused" "$?" "1"
t "none of them started an agent" "$(rounds)" "0"

# ── from a draft to one review ──────────────────────────────────────────────────────────────────
A="$("$CCKIT" task new --body "Three sections: hero, menu, contact." "Landing page for a bakery" --llm | jq -r .id)"
out="$("$CCKIT" task run "$A" --check "test -f made.txt" 2>"$tmp/run.err")"; t "run from a draft exits 0" "$?" "0"
t "stdout is the review link" "$out" "✓ https://github.com/o/r/pull/77"
WT="$W/.claude/worktrees/light+$A-landing-page-for-a-bakery"
BR="light/$A-landing-page-for-a-bakery"
t "the agent ran once" "$(rounds)" "1"
t "the agent ran in the task's worktree" "$(cat "$tmp/claude.cwd")" "$WT"
t "the agent was started headless" "$(cat "$tmp/claude.argv")" "-p --output-format json"
has "the objective carries the task title" "$(cat "$tmp/claude.prompt")" "Do this task: Landing page for a bakery"
has "the objective carries the task notes" "$(cat "$tmp/claude.prompt")" "Three sections: hero, menu, contact."
has "the objective names the task record" "$(cat "$tmp/claude.prompt")" "tasks/$A.md"
t "exactly one review was opened" "$(creates)" "1"
has "the review targets the base branch from the task branch" "$(grep '^pr create' "$GH_LOG")" "--base develop --head $BR"
has "its title ends in the task id" "$(grep '^pr create' "$GH_LOG")" "--title feat: Landing page for a bakery [$A]"
t "the pushed branch says the task is done" "$(git --git-dir="$tmp/remote.git" show "$BR:tasks/$A.md" | sed -n 3p)" "status: done"
t "a file the agent left uncommitted is in the review" "$(git --git-dir="$tmp/remote.git" show "$BR:made.txt")" "made in round 1"
t "the draft moved off the starting checkout" "$([ -f "$W/tasks/$A.md" ] && echo left || echo moved)" "moved"
t "the task lists as review" "$(state "$A")" "review"
t "nothing was merged: the base branch is unchanged" "$(git --git-dir="$tmp/remote.git" rev-parse develop)" "$(git rev-parse develop)"
has "the run says which gate it used" "$(cat "$tmp/run.err")" "gate: test -f made.txt"

# ── re-running once the review is open reports it and creates nothing ───────────────────────────
: > "$GH_LOG"
out="$(GH_OPEN_URL="https://github.com/o/r/pull/77" "$CCKIT" task run "$A" 2>"$tmp/rerun.err")"; t "a re-run exits 0" "$?" "0"
t "a re-run prints the open review" "$out" "✓ https://github.com/o/r/pull/77"
t "a re-run starts no agent" "$(rounds)" "1"
t "a re-run opens no second review" "$(creates)" "0"
has "a re-run says no round ran" "$(cat "$tmp/rerun.err")" "no agent round"
out="$(GH_OPEN_URL="https://github.com/o/r/pull/77" "$CCKIT" task run "$A" --llm)"
t "--llm is one JSON object: verb, ok, id, url" "$(printf '%s' "$out" | jq -r '[.verb, .ok, .id, .url] | join(" ")')" \
  "task run true $A https://github.com/o/r/pull/77"

# ── a failing gate opens no review and exits 6 ──────────────────────────────────────────────────
B="$("$CCKIT" task new "Pricing table" --llm | jq -r .id)"
: > "$GH_LOG"; rm -f "$tmp/rounds"
out="$("$CCKIT" task run "$B" --check "echo gate-red; exit 1" 2>&1)"; t "a failing gate exits 6" "$?" "6"
t "a failing gate opens no review" "$(creates)" "0"
has "the last line says no review was opened, and why" "$(printf '%s\n' "$out" | tail -n 1)" "no review was opened — the run stopped with exit 6 (reason=check-failed"
t "the round did run" "$(rounds)" "1"
t "the task is still doing" "$(state "$B")" "doing"
WTB="$W/.claude/worktrees/light+$B-pricing-table"
t "the work is kept on the task branch" "$(git -C "$WTB" log -1 --format=%s)" "round 1"
t "the branch copy does not say done" "$(git -C "$WTB" show "HEAD:tasks/$B.md" | sed -n 3p)" "status: todo"

# ── the stopped run is discarded; a round that changed nothing opens no review ──────────────────
out="$(STUB_MODE=idle "$CCKIT" task run "$B" --llm 2>/dev/null)"; t "a round that changed nothing exits 5, not the refusal 2" "$?" "5"
t "the stopped earlier run did not block the new one" "$(rounds)" "2"
t "--llm reports the failure" "$(printf '%s' "$out" | jq -r '[.verb, .ok, .id, .url] | join(" ")')" "task run false $B "
has "the detail carries the reason" "$(printf '%s' "$out" | jq -r .detail)" "reason=no-progress"
has "and says how to retry" "$(printf '%s' "$out" | jq -r .detail)" "cckit task run $B"
t "a no-change round opens no review" "$(creates)" "0"

# ── gate precedence: tasks.check from the config, --check over it, --no-finish ──────────────────
jq --arg c "echo config-gate > '$tmp/gate.ran'" '.tasks = {check: $c}' "$W/cckit.config.json" > "$tmp/check.config.json"
C="$("$CCKIT" task new "Footer links" --llm | jq -r .id)"
: > "$GH_LOG"
out="$(KIT_CONFIG="$tmp/check.config.json" "$CCKIT" task run "$C" --no-finish --agent codex --max-seconds 60 2>"$tmp/nf.err")"
t "--no-finish exits 0" "$?" "0"
WTC="$W/.claude/worktrees/light+$C-footer-links"
t "--no-finish prints worktree|branch|id" "$out" "$WTC|light/$C-footer-links|$C"
t "with no --check the gate is tasks.check" "$(cat "$tmp/gate.ran" 2>/dev/null)" "config-gate"
t "--agent picks the CLI" "$(cat "$tmp/codex.cwd" 2>/dev/null)" "$WTC"
t "--no-finish opens no review" "$(creates)" "0"
t "--no-finish leaves the task doing" "$(state "$C")" "doing"
has "--no-finish names the command that sends it for review" "$(cat "$tmp/nf.err")" "cckit task finish $C"
rm -f "$tmp/gate.ran"
out="$(KIT_CONFIG="$tmp/check.config.json" "$CCKIT" task run "$C" --check "true" 2>/dev/null)"; t "a second run of the same task exits 0" "$?" "0"
t "--check wins over tasks.check" "$([ -f "$tmp/gate.ran" ] && echo config || echo flag)" "flag"
t "that run opens the review" "$(creates)" "1"
D="$("$CCKIT" task new "Contact form" --llm | jq -r .id)"
"$CCKIT" task run "$D" --no-finish >/dev/null 2>"$tmp/none.err"; t "a run with no gate anywhere exits 0" "$?" "0"
has "and says there is no gate" "$(cat "$tmp/none.err")" "gate: none"

[ "$fail" -eq 0 ] && echo "PASS light-task-run-test" || echo "FAIL light-task-run-test"
exit "$fail"
