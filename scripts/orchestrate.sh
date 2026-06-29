#!/usr/bin/env bash
# orchestrate.sh - run N issue flows as live tmux panes, each an agent in its own worktree.
#
# For each issue: create an isolated worktree + branch off the configured base branch
# (cckit.config.json: github.repo + github.baseBranch), then open a tmux session with one tiled
# pane per flow running the agent command. Branches must be file-disjoint - the flows edit in
# parallel, so disjointness is the caller's responsibility.
#
# Agent-agnostic: the per-pane command defaults to `claude` but is overridable, so cckit drives any
# CLI agent that takes a prompt as its first argument.
#   --agent <cmd> / CCKIT_AGENT=<cmd>
#
# Hardening:
#   --dry-run      resolve + print the launch plan; create no worktrees, start no panes
#   --cap <N>      concurrency cap: launch at most N flows (default 4); the rest are queued + reported
#   blocked_by     an issue whose native GitHub blocked_by edge points at an OPEN issue is skipped
#                  (override with --force)
#   set -euo pipefail + explicit pipe handling throughout
#
# Usage:
#   cckit orchestrate <issueA> <issueB> [<issueC> ...]
#   cckit orchestrate --dry-run 6 7 8
#   cckit orchestrate --cap 3 --agent codex 2 3 6 9
#   cckit orchestrate --no-seed 6 7          # don't auto-prompt each agent
#   cckit orchestrate --force 7              # launch even if blocked_by an open issue
#   cckit orchestrate --session=sweep 1 2    # custom tmux session name
#   cckit orchestrate --detach 6 7           # build the session, don't attach (testing/headless)
set -euo pipefail

SESSION="orchestrate"
SEED=1
DRYRUN=0
FORCE=0
DETACH=0
CAP=4
AGENT="${CCKIT_AGENT:-claude}"
ISSUES=()

usage() { sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-seed)   SEED=0; shift ;;
    --dry-run)   DRYRUN=1; shift ;;
    --force)     FORCE=1; shift ;;
    --detach)    DETACH=1; shift ;;
    --cap)       CAP="$2"; shift 2 ;;
    --cap=*)     CAP="${1#*=}"; shift ;;
    --agent)     AGENT="$2"; shift 2 ;;
    --agent=*)   AGENT="${1#*=}"; shift ;;
    --session=*) SESSION="${1#*=}"; shift ;;
    -h|--help)   usage; exit 0 ;;
    [0-9]*)      ISSUES+=("$1"); shift ;;
    *)           echo "orchestrate: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

[ "${#ISSUES[@]}" -ge 1 ] || { echo "orchestrate: pass at least one issue number" >&2; usage; exit 2; }
case "$CAP" in ''|*[!0-9]*) echo "orchestrate: --cap needs a number (got '$CAP')" >&2; exit 2 ;; esac

# Resolve the main worktree root + load config (repo + base branch drive everything).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "$SCRIPT_DIR" worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
[ -n "$ROOT" ] || { echo "orchestrate: not in a git repo" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/kit-config.sh" && load_kit_config
REPO="$KIT_REPO"

# blocked_by gate: echo the OPEN blocker numbers of an issue (native GitHub dependency edge).
open_blockers() {
  local n="$1" b st blk
  blk="$(gh api "repos/$REPO/issues/$n/dependencies/blocked_by" --jq '.[].number' 2>/dev/null || true)"
  for b in $blk; do
    st="$(gh issue view "$b" --repo "$REPO" --json state --jq .state 2>/dev/null || echo OPEN)"
    [ "$st" = "OPEN" ] && printf '%s ' "$b"
  done
}

# Partition the requested issues into eligible / blocked / (later) queued.
ELIGIBLE=()
echo "orchestrate: repo $REPO (base ${KIT_BASE_BRANCH:-main}), cap $CAP, agent '$AGENT'"
for num in "${ISSUES[@]}"; do
  blockers="$(open_blockers "$num")"
  if [ -n "$blockers" ] && [ "$FORCE" -eq 0 ]; then
    echo "  #$num  SKIP - blocked_by open: ${blockers% }"
  else
    [ -n "$blockers" ] && echo "  #$num  FORCED past open blockers: ${blockers% }"
    ELIGIBLE+=("$num")
  fi
done
[ "${#ELIGIBLE[@]}" -ge 1 ] || { echo "orchestrate: nothing eligible to launch" >&2; exit 1; }

# Concurrency cap: launch the first CAP eligible flows; queue + report the rest.
LAUNCH=()
QUEUE=()
i=0
for num in "${ELIGIBLE[@]}"; do
  if [ "$i" -lt "$CAP" ]; then LAUNCH+=("$num"); else QUEUE+=("$num"); fi
  i=$((i + 1))
done
[ "${#QUEUE[@]}" -eq 0 ] || echo "  queued past cap (run a later wave): ${QUEUE[*]}"

if [ "$DRYRUN" -eq 1 ]; then
  echo "orchestrate: DRY RUN - would launch ${#LAUNCH[@]} flow(s): ${LAUNCH[*]}"
  echo "             (no worktrees created, no panes started)"
  exit 0
fi

command -v tmux >/dev/null || { echo "orchestrate: tmux not installed (brew install tmux)" >&2; exit 1; }
command -v "$AGENT" >/dev/null || { echo "orchestrate: agent '$AGENT' not on PATH" >&2; exit 1; }

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/worktree-start.sh"

# Headless seed: the agent runs with NO human present - it must never ask, decide autonomously,
# gauge difficulty + apply proportional effort, and close no-op issues itself. cckit verbs only.
seed_for() {
  local num="$1" branch="$2"
  printf '%s' "You are running HEADLESS inside a cckit orchestration: there is NO human to answer \
questions, so NEVER ask - decide autonomously and proceed. Gauge the task difficulty and apply \
proportional effort. Worktree + branch $branch for issue #$num are ready. Run: gh issue view $num, \
implement it, run bash scripts/check.sh until green, then open the PR with: cckit pr $num \"<summary>\". \
If it is a no-op (nothing to change), comment why and run: cckit close $num \"<reason>\". Do not wait for input."
}

ENTRIES=()
for num in "${LAUNCH[@]}"; do
  entry="$(wt_start "$num")" || { echo "orchestrate: wt_start #$num failed" >&2; exit 1; }
  ENTRIES+=("$entry")
done

tmux kill-session -t "$SESSION" 2>/dev/null || true
first=1
for entry in "${ENTRIES[@]}"; do
  wt="${entry%%|*}"; rest="${entry#*|}"; branch="${rest%%|*}"; num="${rest##*|}"
  if [ "$first" -eq 1 ]; then
    tmux new-session -d -s "$SESSION" -n flows -c "$wt"
    pane="$(tmux display -p -t "$SESSION:flows" '#{pane_id}')"
    first=0
  else
    pane="$(tmux split-window -t "$SESSION:flows" -c "$wt" -P -F '#{pane_id}')"
    tmux select-layout -t "$SESSION:flows" tiled >/dev/null
  fi
  if [ "$SEED" -eq 1 ]; then
    tmux send-keys -t "$pane" "$AGENT \"$(seed_for "$num" "$branch")\"" C-m
  else
    tmux send-keys -t "$pane" "$AGENT" C-m
  fi
done
tmux select-layout -t "$SESSION:flows" tiled >/dev/null
tmux set -t "$SESSION" mouse on
tmux select-window -t "$SESSION:flows" 2>/dev/null || true

hint="tabs/panes: click to focus, or Ctrl-b <number> - Ctrl-b d detaches"
if [ "$DETACH" -eq 1 ]; then
  echo "orchestrate: session '$SESSION' built ($hint). Attach: tmux attach -t $SESSION"
else
  echo "orchestrate: attaching to '$SESSION' - $hint"
  tmux attach -t "$SESSION"
fi
