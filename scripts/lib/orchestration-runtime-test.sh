#!/usr/bin/env bash
# orchestration-runtime-test.sh — Herdr runtime contract for cckit orchestrate (#317).
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/orchestration-runtime.sh"

fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
yes() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> missing '$3' in [$2]"; fail=1 ;; esac; }
no() { case "$2" in *"$3"*) echo "FAIL: $1 -> found '$3' in [$2]"; fail=1 ;; *) echo "ok: $1" ;; esac; }

or_runtime_validate tmux >/dev/null 2>&1; t "tmux runtime is accepted" "$?" "0"
or_runtime_validate herdr >/dev/null 2>&1; t "Herdr runtime is accepted" "$?" "0"
or_runtime_validate screen >/dev/null 2>&1; t "unknown runtime is rejected" "$?" "2"
or_herdr_kind_supported codex; t "Codex is a supported Herdr kind" "$?" "0"
or_herdr_kind_supported custom-agent; t "arbitrary commands are rejected by Herdr" "$?" "1"

name="$(or_herdr_agent_name 'My Very Long Project Name That Exceeds The Limit' 317)"
t "Herdr agent name stays within 32 characters" "${#name}" "32"
t "Herdr agent name preserves the issue suffix" "${name##*-}" "317"
case "$name" in [a-z][a-z0-9_-]*) name_ok=yes ;; *) name_ok=no ;; esac
t "Herdr agent name uses the accepted character set" "$name_ok" "yes"

stub="$(mktemp -d)"
export HERDR_TEST_LOG="$stub/herdr.log"
: > "$HERDR_TEST_LOG"
cat > "$stub/herdr" <<'SH'
#!/usr/bin/env bash
domain="$1"
{
  printf '%s' "$1"; shift
  for arg in "$@"; do printf '|%s' "$arg"; done
  printf '\n'
} >> "$HERDR_TEST_LOG"
case "$1" in
  create)
    case "$domain" in
      workspace) echo '{"result":{"workspace":{"workspace_id":"w1"},"root_pane":{"pane_id":"w1:p1"}}}' ;;
      tab) echo '{"result":{"root_pane":{"pane_id":"w1:p2"}}}' ;;
    esac
    ;;
  *) echo '{"result":{}}' ;;
esac
SH
cat > "$stub/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  api) exit 0 ;;
  *) echo '[]' ;;
esac
SH
chmod +x "$stub/herdr" "$stub/codex" "$stub/gh"

seed_for() { printf 'seed issue %s on %s in %s' "$1" "$2" "$3"; }
old_path="$PATH"
PATH="$stub:$PATH"
out="$(or_herdr_launch sweep codex 1 1 demo "" "/tmp/wt1|task/41-one|41" "/tmp/wt2|task/42-two|42")"
log="$(cat "$HERDR_TEST_LOG")"
yes "Herdr creates one orchestration workspace" "$log" "workspace|create|--cwd|/tmp/wt1|--label|cckit:demo:sweep|--no-focus"
yes "Herdr starts the first issue agent" "$log" "agent|start|cckit-demo-41|--kind|codex|--pane|w1:p1"
yes "Herdr creates a tab rooted in the second worktree" "$log" "tab|create|--workspace|w1|--cwd|/tmp/wt2|--label|issue-42|--no-focus"
yes "Herdr sends the existing headless seed" "$log" "agent|prompt|cckit-demo-41|seed issue 41 on task/41-one in /tmp/wt1"
yes "detached launch prints a reopen command" "$out" "herdr workspace focus w1 && herdr"

: > "$HERDR_TEST_LOG"
or_herdr_launch sweep codex 0 1 demo "" "/tmp/wt1|task/41-one|41" >/dev/null
no "--no-seed starts the agent without prompting" "$(cat "$HERDR_TEST_LOG")" "agent|prompt"

# ── the supported-kind list comes from the INSTALLED binary, not a copy kept in cckit ───────────
# A hand-written list drifts: it carried `letta`, which herdr 0.9.0 rejects, so the kind passed
# preflight and failed later — after the worktree existed, which is exactly what preflight exists
# to prevent.
or_herdr_kind_supported claude; t "a kind herdr supports is accepted" "$?" "0"
or_herdr_kind_supported letta;  t "a kind herdr does NOT support is rejected" "$?" "1"
or_herdr_kind_supported '';     t "an empty kind is rejected" "$?" "1"
yes "the refusal lists the kinds actually supported" "$(or_runtime_preflight herdr letta 1 2>&1)" "supported here:"

# ── a profile's argv reaches the agent through Herdr's `--` passthrough ─────────────────────────
: > "$HERDR_TEST_LOG"
or_herdr_launch sweep codex 0 1 demo "$(printf -- '--model\nsome model')" "/tmp/wt1|task/41-one|41" >/dev/null
yes "profile args are passed after herdr's --" "$(cat "$HERDR_TEST_LOG")" "--kind|codex|--pane|w1:p1|--|--model|some model"
# One-per-line then rebuilt as an array: an argument containing a space must stay ONE argument.
no "a space-bearing arg is not split into two" "$(cat "$HERDR_TEST_LOG")" "|some|model"

: > "$HERDR_TEST_LOG"
or_herdr_launch sweep codex 0 1 demo "" "/tmp/wt1|task/41-one|41" >/dev/null
no "no profile args means no trailing -- separator" "$(cat "$HERDR_TEST_LOG")" "--pane|w1:p1|--"

# ── the SAME argv reaches the agent on the tmux path, which is the DEFAULT runtime ─────────────
# This had no test, and that is why it shipped broken: the argv was threaded to or_herdr_launch and
# nowhere else, so a profile's `args` were dropped on the runtime almost everyone runs.
t "no args is the bare command" "$(or_tmux_agent_cmd claude '')" "claude"
t "args are quoted onto the command line" \
  "$(or_tmux_agent_cmd claude "$(printf -- '--model\nsome model')")" "claude '--model' 'some model'"
# Assert the ROUND TRIP, not the literal: what matters is the argv the pane's shell ends up with,
# and an eval is the only thing that proves it. Comparing the quoted string to an expected literal
# is how a doubly-escaped `'\''` passes a test and still breaks the pane.
argv() { eval "printf '[%s]' $(or_tmux_agent_cmd claude "$1")"; }
t "the pane shell sees one arg per declared arg" \
  "$(argv "$(printf -- '--model\nsome model')")" "[claude][--model][some model]"
t "a single quote survives instead of terminating the quoting" \
  "$(argv "$(printf -- "it's odd")")" "[claude][it's odd]"

PATH="/usr/bin:/bin"
missing="$(or_runtime_preflight herdr codex 0 2>&1)"; rc=$?
t "missing Herdr fails before worktree creation" "$rc" "1"
yes "missing Herdr names the dependency" "$missing" "Herdr not installed"
PATH="$old_path"

dry="$(cd "$ROOT" && PATH="$stub:$PATH" "$ROOT/bin/cckit" orchestrate --runtime herdr --agent codex --dry-run 41 2>&1)"
yes "orchestrate accepts the Herdr runtime flag" "$dry" "runtime 'herdr', agent 'codex'"
yes "Herdr dry-run creates no runtime state" "$dry" "no worktrees created, no panes started"

auto="$(cd "$ROOT" && PATH="$stub:$PATH" "$ROOT/bin/cckit" autopilot --runtime herdr --agent codex --dry-run 41 2>&1)"
yes "autopilot passes the runtime to orchestrate" "$auto" "runtime 'herdr', agent 'codex'"

# autopilot forwards an explicit allow-list, so a flag orchestrate grew is rejected until it is
# added here too — `--profile` was, and the unattended driver is where a profile matters most.
prof="$(cd "$ROOT" && PATH="$stub:$PATH" "$ROOT/bin/cckit" autopilot --profile build --dry-run 41 2>&1)"
no "autopilot forwards --profile instead of rejecting it" "$prof" "unknown arg '--profile'"
# Forwarding is proven by WHO refuses. cckit's own config declares no profiles, so the resolver
# must be the one to say so — a message from agent-profile means the flag reached orchestrate.
yes "--profile reaches the resolver, not autopilot's arg parser" "$prof" "agent-profile: no profile named 'build'"
yes "autopilot lists --profile in its help" \
  "$(cd "$ROOT" && "$ROOT/bin/cckit" autopilot --help 2>&1)" "--profile build"
no "autopilot help stops before the script body" \
  "$(cd "$ROOT" && "$ROOT/bin/cckit" autopilot --help 2>&1)" "set -euo pipefail"

rm -rf "$stub"
[ "$fail" -eq 0 ] && echo "ALL OK" || echo "orchestration runtime: FAILURES"
exit "$fail"
