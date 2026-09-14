#!/usr/bin/env bash
# orchestrate.sh - run N issue flows as live terminal panes, each an agent in its own worktree.
#
# For each issue: create an isolated worktree + branch off the configured base branch
# (cckit.config.json: github.repo + github.baseBranch), then open a tmux session or Herdr workspace
# with one pane per flow running the agent command. Branches must be file-disjoint - the flows edit
# in parallel, so disjointness is the caller's responsibility.
#
# Agent-agnostic: the per-pane command defaults to `claude` but is overridable, so cckit drives any
# CLI agent that takes a prompt as its first argument.
#   --agent <cmd> / CCKIT_AGENT=<cmd>        the CLI directly (profile-free path)
#   --profile <name> / CCKIT_PROFILE=<name>  a declared agent profile: its kind + its argv
#   --runtime <tmux|herdr> / CCKIT_RUNTIME=<runtime>
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
#   cckit orchestrate --runtime herdr --agent codex 2 3 6 9
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
RUNTIME="${CCKIT_RUNTIME:-tmux}"
PROFILE="${CCKIT_PROFILE:-}"
AGENT_ARGS_NL=""
AGENT_EXPLICIT=0
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
    --agent)     AGENT="$2"; AGENT_EXPLICIT=1; shift 2 ;;
    --agent=*)   AGENT="${1#*=}"; AGENT_EXPLICIT=1; shift ;;
    --profile)   PROFILE="$2"; shift 2 ;;
    --profile=*) PROFILE="${1#*=}"; shift ;;
    --runtime)   RUNTIME="$2"; shift 2 ;;
    --runtime=*) RUNTIME="${1#*=}"; shift ;;
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
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"   # cckit INSTALL root — for sourcing libs (works on brew/npm installs)
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/orchestration-runtime.sh"

# Agent profiles (#320). A profile supplies the agent KIND and its extra argv; cckit never names a
# model, so whatever model flag the project wants lives in the profile's `args`. Resolution runs
# BEFORE the preflight so an unknown or stage-barred profile is refused with everything else — no
# worktree, no pane. `--agent` remains the direct, profile-free path and wins when given.
if [ "$AGENT_EXPLICIT" -eq 0 ]; then
  # shellcheck source=/dev/null
  source "$ROOT/scripts/lib/config-path.sh" 2>/dev/null || true
  # shellcheck source=/dev/null
  source "$ROOT/scripts/lib/agent-resolve.sh" 2>/dev/null || true
  _oc_cfg=""
  command -v kit_config_path >/dev/null 2>&1 && _oc_cfg="$(kit_config_path 2>/dev/null || true)"
  if [ -n "$_oc_cfg" ] && [ -f "$_oc_cfg" ] && command -v ap_resolve >/dev/null 2>&1; then
    # No issue labels here: this is the run-wide profile. Per-issue `agent:` labels select a
    # profile per entry, which the launch loop cannot express yet (it takes one kind for the run).
    # rc 2 is a REFUSAL (unknown profile, barred stage) and must stop before any worktree. rc 4 is
    # "this project declares no profiles", which is the normal state of every project that has not
    # opted in — it falls through to --agent's default rather than breaking plain orchestration.
    _oc_rc=0
    _oc_prof="$(ap_resolve "$_oc_cfg" build "$PROFILE" '' '')" || _oc_rc=$?
    case "$_oc_rc" in
      0) : ;;
      4) if [ -n "$PROFILE" ]; then
           echo "orchestrate: --profile '$PROFILE' given but no agent profiles are declared" >&2; exit 2
         fi
         _oc_prof="" ;;
      *) exit "$_oc_rc" ;;
    esac
    if [ -n "$_oc_prof" ]; then
      AGENT="$(ap_profile_field "$_oc_cfg" "$_oc_prof" kind)"
      AGENT_ARGS_NL="$(ap_profile_args "$_oc_cfg" "$_oc_prof")"
      echo "orchestrate: profile '$_oc_prof' (tier $(ap_profile_tier "$_oc_cfg" "$_oc_prof"), kind $AGENT)"
    fi
  elif [ -n "$PROFILE" ]; then
    echo "orchestrate: --profile '$PROFILE' given but no kit config declares agents.profiles" >&2
    exit 2
  fi
fi

or_runtime_preflight "$RUNTIME" "$AGENT" "$DRYRUN"
# The git-repo guard validates the INVOKING project ($PWD), not cckit's install dir; wt_start and
# load_kit_config below resolve the project + its config from the invoking directory.
git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1 || { echo "orchestrate: not in a git repo" >&2; exit 1; }
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
echo "orchestrate: repo $REPO (base ${KIT_BASE_BRANCH:-main}), cap $CAP, runtime '$RUNTIME', agent '$AGENT'"
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

# shellcheck source=/dev/null
source "$ROOT/scripts/lib/worktree-start.sh"

# Headless seed: the agent runs with NO human present - it must never ask, decide autonomously,
# gauge difficulty + apply proportional effort, and close no-op issues itself. cckit verbs only.
seed_for() {
  local num="$1" branch="$2" wt="${3:-$PWD}" brief
  brief="$(cd "$wt" && "$ROOT/bin/cckit" brief "$num" 2>/dev/null)" || brief=""
  printf '%s\n' "You are running HEADLESS inside a cckit orchestration. There is no human in this worker session: decide within the issue's scope and proceed. Do not read the whole board or take another issue. Work only on issue #$num in branch $branch."
  if [ -n "$brief" ]; then
    printf '\n%s\n' "$brief"
  else
    # Nested single quotes would terminate the format string and make printf recycle it over the
    # stray words as arguments, so the fallback names the command without quoting it.
    printf '\nThe generated cckit brief was unavailable. Read only issue #%s with: gh issue view %s\n' "$num" "$num"
  fi
  printf '\n%s\n' "Implement the issue, run the brief's gate until green, then open the PR with: cckit pr $num \"<summary>\". If no change is needed, comment why and run: cckit close $num \"<reason>\". Finish by reporting only the PR or issue URL, gate result, and any blocker."
}

ENTRIES=()
for num in "${LAUNCH[@]}"; do
  entry="$(wt_start "$num")" || { echo "orchestrate: wt_start #$num failed" >&2; exit 1; }
  ENTRIES+=("$entry")
done

if [ "$RUNTIME" = "herdr" ]; then
  or_herdr_launch "$SESSION" "$AGENT" "$SEED" "$DETACH" "${KIT_PROJECT_SLUG:-project}" "$AGENT_ARGS_NL" "${ENTRIES[@]}"
  exit $?
fi

# The profile's argv on the tmux path. Herdr got it as an argv array above; tmux types a command
# LINE into the pane's shell, so the quoting lives in or_tmux_agent_cmd beside the Herdr launcher —
# both runtimes answer the same question and neither may drop the args the resolution line promised.
AGENT_CMD="$(or_tmux_agent_cmd "$AGENT" "$AGENT_ARGS_NL")"

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
    # Single-quote the prompt so its embedded quotes / redirection chars (e.g. the
    # "<summary>" and "<reason>" placeholders) reach the agent literally instead of being
    # parsed by the pane's shell. Double-quoting collided with the seed's own quotes and
    # dumped `<summary>` onto zsh as a redirection ("no such file or directory: summary"),
    # so the agent never launched. Escape any single quotes for safe single-quote wrapping.
    seed="$(seed_for "$num" "$branch" "$wt")"
    esc=${seed//\'/\'\\\'\'}
    tmux send-keys -t "$pane" "$AGENT_CMD '$esc'" C-m
  else
    tmux send-keys -t "$pane" "$AGENT_CMD" C-m
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
