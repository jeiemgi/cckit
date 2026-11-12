#!/usr/bin/env bash
# wave-worker.sh — the process an orchestrate pane runs: start the agent, record how it ended.
# (E257.6, #263)
#
#   wave-worker.sh <session> <issue> -- <agent> [args…]
#
# `cckit orchestrate` types this into each tmux pane in front of the agent command, so the agent
# stays the pane's foreground process (it keeps the terminal) and its exit status is no longer
# lost when the pane closes. The record is scripts/lib/wave-result.sh's; read it with
# `cckit orchestrate --results`.
#
# The same wrapper runs every agent kind. It reads nothing the agent prints and passes its argv
# through untouched, so `claude`, `codex` or any other CLI is launched exactly as it was before.
#
# Exit status: the agent's own, so the pane shows what the agent returned.
set -u

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/lib/wave-result.sh"

session="${1:-}"; issue="${2:-}"
[ -n "$session" ] && [ -n "$issue" ] || { echo "wave-worker: usage: wave-worker.sh <session> <issue> -- <agent> [args…]" >&2; exit 2; }
shift 2
[ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || { echo "wave-worker: no agent command given" >&2; exit 2; }

now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

finished=0
finish() {  # <state> <rc>
  [ "$finished" -eq 0 ] || return 0
  finished=1
  wr_set "$session" "$issue" "state=$1" "rc=$2" "finished=$(now)" || true
}

# A recording failure must not stop the work: the worker still runs, its result is simply absent.
wr_set "$session" "$issue" "issue=$issue" "state=running" "pid=$$" "host=$(hostname 2>/dev/null)" \
  "started=$(now)" "rc=" "finished=" || echo "wave-worker: could not record the start of #$issue" >&2

# bash runs a trap only after the foreground child returns, so these fire once the agent is gone —
# a closed pane sends HUP to both. SIGKILL cannot be trapped: that case is read back from the dead
# pid by wr_state.
trap 'finish interrupted 129; exit 129' HUP
trap 'finish interrupted 130; exit 130' INT
trap 'finish interrupted 143; exit 143' TERM

"$@"
rc=$?
finish "$(wr_classify_rc "$rc")" "$rc"
exit "$rc"
