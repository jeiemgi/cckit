#!/usr/bin/env bash
# autopilot-run.sh - ONE bounded, unattended objective on the current branch (E257.7, #264).
#
# `cckit autopilot` launches interactive panes. This is the other half: it starts the agent with no
# terminal (`claude -p` or `codex exec`, through scripts/lib/agent-launch.sh), one round at a time,
# and decides in CODE after every round whether the run goes on. Nothing the agent says ends or
# extends a run; a limit in the prompt is not a limit.
#
# Usage:
#   cckit autopilot run [<issue>] --objective "<text>" [options]
#   cckit autopilot run --resume [limit options]
#
#   --objective "<text>" | --prompt-file <f>   what to do (one is required on a new run)
#   --agent <claude|codex>      the CLI (default: CCKIT_AGENT, else claude)
#   --profile <name>            a declared agent profile: its kind + args; it must allow `build`
#                               and declare write:true
#   --agent-arg <arg>           one extra argv entry for the agent CLI (repeatable). cckit adds no
#                               permission flag: a run that must edit files names its own here
#   --until "<cmd>"             completion check, run after every round; rc 0 ends the run
#   --check "<cmd>"             publication gate, run once the work is complete; a failure stops
#                               the run and nothing is published
#   --max-iters <n>             rounds allowed in total (default 5)
#   --max-seconds <s>           wall-clock allowed in total (default 3600)
#   --round-seconds <s>         wall-clock allowed per round (default 900)
#   --max-tokens <n>            token ceiling, checked BETWEEN rounds from the runtime's own usage
#                               output; a round that reports no usage stops the run
#   --publish --summary "<s>"   on success open the PR with `cckit pr <issue> "<s>"`, unless the
#                               branch already has an open one
#   --resume                    continue the stopped run on this branch; counters carry over
#   --fresh                     discard a stopped run's state and start over
#   --dry-run                   print the plan; start nothing, write nothing
#
# Stop reasons, each decided by code and written to the state file:
#   done            the completion check passed (and the gate, when given)        exit 0
#   agent-failed    the agent exited non-zero                                     exit 3
#   limit-iters | limit-seconds | limit-tokens | usage-unknown                    exit 4
#   no-progress     a round changed neither HEAD nor the working tree             exit 5
#   check-failed    the publication gate failed                                   exit 6
#   publish-failed  the work passed but `cckit pr` did not open the PR            exit 7
#   interrupted     this process or the agent was killed by a signal              exit 130
# A refusal (bad flag, base branch, unsupported agent, a live run on the branch, an agent an
# earlier run left alive) is exit 2 and writes nothing.
#
# A round that was cut short (a signal, or this process killed outright) is counted from whatever
# usage its output holds; when it holds none the run's tokens read `unknown`, never a sum that
# leaves the round out.
#
# Not here, on purpose: merging. A run never merges and never closes an issue.
# errors: strict — every stop is a state-file write plus the exit code above
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/agent-launch.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/kit-state.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/worktree-issue.sh"

die() { echo "autopilot run: $*" >&2; exit 2; }
is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

ISSUE="" OBJECTIVE="" PROMPT_FILE="" AGENT="" AGENT_SET=0 PROFILE="" UNTIL="" CHECK=""
MAX_ITERS="" MAX_SECONDS="" ROUND_SECONDS="" MAX_TOKENS="" PUBLISH="" SUMMARY=""
RESUME=0 FRESH=0 DRYRUN=0
AGENT_ARGS=()

need() { [ "$#" -ge 2 ] || die "$1 needs a value"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --objective)     need "$@"; OBJECTIVE="$2"; shift 2 ;;
    --prompt-file)   need "$@"; PROMPT_FILE="$2"; shift 2 ;;
    --agent)         need "$@"; AGENT="$2"; AGENT_SET=1; shift 2 ;;
    --profile)       need "$@"; PROFILE="$2"; shift 2 ;;
    --agent-arg)     need "$@"; AGENT_ARGS+=("$2"); shift 2 ;;
    --until)         need "$@"; UNTIL="$2"; shift 2 ;;
    --check)         need "$@"; CHECK="$2"; shift 2 ;;
    --max-iters)     need "$@"; MAX_ITERS="$2"; shift 2 ;;
    --max-seconds)   need "$@"; MAX_SECONDS="$2"; shift 2 ;;
    --round-seconds) need "$@"; ROUND_SECONDS="$2"; shift 2 ;;
    --max-tokens)    need "$@"; MAX_TOKENS="$2"; shift 2 ;;
    --summary)       need "$@"; SUMMARY="$2"; shift 2 ;;
    --publish)       PUBLISH=1; shift ;;
    --resume)        RESUME=1; shift ;;
    --fresh)         FRESH=1; shift ;;
    --dry-run)       DRYRUN=1; shift ;;
    --notify|--notify=*|--plan|--plan=*)
      die "'${1%%=*}' is not supported: no code path delivers a notification or runs a plan from here (see docs: agent-compatibility, unattended limits)" ;;
    -h|--help) sed -n '2,49p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    [0-9]*) [ -z "$ISSUE" ] || die "one issue at a time (got '$ISSUE' and '$1')"; ISSUE="$1"; shift ;;
    *) die "unknown arg '$1'" ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || die "not inside a git repository"
[ "$BRANCH" != "HEAD" ] || die "detached HEAD - a run needs a branch to own"
WORKTREE="$(git rev-parse --show-toplevel)"

# Never on the base branch: every round commits. The config names it; main/develop are refused
# with or without a config, since a run that could not read the config must not conclude it is safe.
BASE=""
CFG="$(. "$SCRIPT_DIR/lib/config-path.sh" 2>/dev/null && kit_config_path 2>/dev/null || true)"
[ -n "$CFG" ] && [ -f "$CFG" ] && BASE="$(jq -r '.github.baseBranch // .github.integrationBranch // .github.flow // ""' "$CFG" 2>/dev/null)"
BASE="${KIT_BASE_BRANCH:-$BASE}"
case "$BRANCH" in main|master|develop|"$BASE") die "refusing to run on '$BRANCH' - start a worktree first (cckit start <issue>)" ;; esac

KEY="$(printf '%s' "$BRANCH" | tr -c 'A-Za-z0-9._-' '_')"
SDIR="$(kit_state_dir)/autopilot"
STATE="$SDIR/$KEY.json"
# Where al_run records the agent it has running. Read below before anything starts: a runner killed
# with SIGKILL leaves `status: running` behind with a dead pid, and only this file can say whether
# its agent went with it.
AL_PIDFILE="$SDIR/$KEY.agent.pid"
sget() { jq -r "$1" "$STATE" 2>/dev/null; }

# --- an existing run on this branch --------------------------------------------------------------
PREV_ROUNDS=0 PREV_ELAPSED=0 TOK_IN=0 TOK_OUT=0 TOK_KNOWN=1 COST=0 COST_KNOWN=1 PR_URL="" USAGE_SRC="none"
PREV_OPEN_AGENT=""
if [ -f "$STATE" ]; then
  prev_status="$(sget '.status // ""')"; prev_pid="$(sget '.pid // ""')"; prev_reason="$(sget '.reason // ""')"
  if [ "$prev_status" = "running" ] && is_uint "$prev_pid" && kill -0 "$prev_pid" 2>/dev/null \
     && [ "$(sget '.host // ""')" = "$(hostname 2>/dev/null)" ]; then
    die "a run is already live on '$BRANCH' (pid $prev_pid) - one writer per branch"
  fi
  # The runner is gone; its agent may not be. Checked for every start that would launch an agent
  # (--resume, --fresh, a new run; --dry-run launches none), because each would put a second
  # writer on the branch. Refused, not killed: the pid is all the file knows, and a recycled pid
  # belongs to someone else.
  if [ "$DRYRUN" != "1" ] && [ "$(sget '.host // ""')" = "$(hostname 2>/dev/null)" ] && al_pidfile_alive "$AL_PIDFILE"; then
    read -r _apid _agrp < "$AL_PIDFILE" || true
    [ "$_agrp" = "1" ] && _akill="kill -TERM -- -$_apid" || _akill="kill -TERM $_apid"
    die "the agent an earlier run started on '$BRANCH' is still alive (pid $_apid) though its runner is gone - one writer per branch. Stop it with: $_akill   (if pid $_apid is not that agent, remove $AL_PIDFILE)"
  fi
  if [ "$RESUME" = "1" ]; then
    if [ "$prev_reason" = "done" ]; then
      echo "autopilot run: '$BRANCH' already finished (reason=done) - nothing to resume"
      [ -n "$(sget '.pr_url // ""')" ] && echo "autopilot run: PR $(sget '.pr_url')"
      exit 0
    fi
    # Flags given with --resume win (that is how a limit-stopped run is extended); everything
    # else comes back from the state file so the resumed run is the same run.
    [ -n "$ISSUE" ]         || ISSUE="$(sget '.issue // ""')"
    [ -n "$OBJECTIVE" ] || [ -n "$PROMPT_FILE" ] || OBJECTIVE="$(sget '.objective // ""')"
    [ "$AGENT_SET" = "1" ] || [ -n "$PROFILE" ] || AGENT="$(sget '.agent // ""')"
    if [ "${#AGENT_ARGS[@]}" -eq 0 ] && [ -z "$PROFILE" ]; then
      while IFS= read -r _a; do [ -n "$_a" ] && AGENT_ARGS+=("$_a"); done <<< "$(sget '.agent_args // [] | .[]')"
    fi
    [ -n "$UNTIL" ]         || UNTIL="$(sget '.until // ""')"
    [ -n "$CHECK" ]         || CHECK="$(sget '.check // ""')"
    [ -n "$MAX_ITERS" ]     || MAX_ITERS="$(sget '.limits.max_iters // ""')"
    [ -n "$MAX_SECONDS" ]   || MAX_SECONDS="$(sget '.limits.max_seconds // ""')"
    [ -n "$ROUND_SECONDS" ] || ROUND_SECONDS="$(sget '.limits.round_seconds // ""')"
    [ -n "$MAX_TOKENS" ]    || MAX_TOKENS="$(sget '.limits.max_tokens // "" | tostring' | sed 's/^null$//')"
    [ -n "$PUBLISH" ]       || { [ "$(sget '.publish // false')" = "true" ] && PUBLISH=1; }
    [ -n "$SUMMARY" ]       || SUMMARY="$(sget '.summary // ""')"
    PREV_ROUNDS="$(sget '.rounds // 0')"; PREV_ELAPSED="$(sget '.elapsed_seconds // 0')"
    PR_URL="$(sget '.pr_url // ""')"; USAGE_SRC="$(sget '.usage.source // "none"')"
    TOK_IN="$(sget '.usage.known_input_tokens // 0')"; TOK_OUT="$(sget '.usage.known_output_tokens // 0')"
    [ "$(sget '.usage.tokens')" = "unknown" ] && [ "$PREV_ROUNDS" != "0" ] && TOK_KNOWN=0
    COST="$(sget '.usage.known_cost_usd // 0')"
    [ "$(sget '.usage.cost_usd')" = "unknown" ] && [ "$PREV_ROUNDS" != "0" ] && COST_KNOWN=0
    # A runner that died with a round in flight never counted that round. Its output file is still
    # there; it is counted once the helpers below exist (see "the round a dead runner left open").
    [ "$(sget '.round_open // false')" = "true" ] && [ "$PREV_ROUNDS" != "0" ] && PREV_OPEN_AGENT="$(sget '.agent // ""')"
  elif [ "$FRESH" != "1" ] && [ "$DRYRUN" != "1" ]; then
    die "'$BRANCH' has a stopped run (reason=${prev_reason:-?}, rounds=$(sget '.rounds // 0')): pass --resume to continue it or --fresh to discard it"
  fi
elif [ "$RESUME" = "1" ]; then
  die "nothing to resume on '$BRANCH' (no state at $STATE)"
fi

# --- validate everything before anything runs ----------------------------------------------------
[ -n "$PROFILE" ] && [ "$AGENT_SET" = "1" ] && die "--agent and --profile are two ways to pick the CLI - pass one"
if [ -n "$PROFILE" ]; then
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/lib/agent-profile.sh"
  [ -n "$CFG" ] && [ -f "$CFG" ] || die "--profile '$PROFILE' given but no kit config was found"
  ap_profile_validate "$CFG" "$PROFILE" build || exit 2
  ap_profile_writes "$CFG" "$PROFILE" || die "profile '$PROFILE' does not declare write:true - an unattended run commits to the branch"
  AGENT="$(ap_profile_field "$CFG" "$PROFILE" kind)"
  AGENT_ARGS=()
  while IFS= read -r _a; do [ -n "$_a" ] && AGENT_ARGS+=("$_a"); done <<< "$(ap_profile_args "$CFG" "$PROFILE")"
fi
[ -n "$AGENT" ] || AGENT="${CCKIT_AGENT:-claude}"
al_supported "$AGENT" || die "agent '$AGENT' has no non-interactive form cckit knows (supported: claude, codex)"

if [ -n "$PROMPT_FILE" ]; then
  [ -f "$PROMPT_FILE" ] || die "--prompt-file '$PROMPT_FILE' not found"
  OBJECTIVE="$(cat "$PROMPT_FILE")"
fi
[ -n "$OBJECTIVE" ] || die "an objective is required: --objective \"<text>\" or --prompt-file <f>"
[ -n "$ISSUE" ] || ISSUE="$(wt_issue_number "$BRANCH")"

MAX_ITERS="${MAX_ITERS:-5}"; MAX_SECONDS="${MAX_SECONDS:-3600}"; ROUND_SECONDS="${ROUND_SECONDS:-900}"
for _pair in "--max-iters:$MAX_ITERS" "--max-seconds:$MAX_SECONDS" "--round-seconds:$ROUND_SECONDS"; do
  is_uint "${_pair#*:}" && [ "${_pair#*:}" -gt 0 ] || die "${_pair%%:*} '${_pair#*:}' is not a positive integer"
done
if [ -n "$MAX_TOKENS" ]; then
  is_uint "$MAX_TOKENS" && [ "$MAX_TOKENS" -gt 0 ] || die "--max-tokens '$MAX_TOKENS' is not a positive integer"
fi
if [ -n "$PUBLISH" ]; then
  [ -n "$ISSUE" ]   || die "--publish needs an issue: pass <issue>, or run on a <kind>/<N>-<slug> branch"
  [ -n "$SUMMARY" ] || die "--publish needs --summary \"<text>\" (a PR summary is never invented)"
fi

ARGS_NL=""
[ "${#AGENT_ARGS[@]}" -gt 0 ] && ARGS_NL="$(printf '%s\n' "${AGENT_ARGS[@]}")"
AGENT_CMD="$(al_headless_cmd "$AGENT" json "$ARGS_NL")" || exit 2
# No reader is in a headless run: `cckit page` in the agent's shell reads this and prints to the
# terminal instead of opening a review page (#451).
export CCKIT_HEADLESS=1

if [ "$DRYRUN" = "1" ]; then
  echo "autopilot run (dry-run): branch $BRANCH${ISSUE:+ (issue #$ISSUE)} in $WORKTREE"
  echo "  agent   : $AGENT_CMD   < prompt on stdin"
  echo "  limits  : max-iters $MAX_ITERS · max-seconds $MAX_SECONDS · round-seconds $ROUND_SECONDS · max-tokens ${MAX_TOKENS:-none}"
  echo "  until   : ${UNTIL:-<the agent exits 0 after a round that changed something>}"
  echo "  check   : ${CHECK:-<none>}"
  echo "  publish : $([ -n "$PUBLISH" ] && echo "cckit pr $ISSUE" || echo no)"
  echo "  state   : $STATE"
  exit 0
fi
command -v "$AGENT" >/dev/null 2>&1 || die "agent CLI '$AGENT' is not on PATH"

mkdir -p "$SDIR" || die "cannot create $SDIR"
STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T0="$(date +%s)"
ROUNDS="$PREV_ROUNDS"
DETAIL=""
# 1 from the moment a round is numbered until its usage is counted. A stop in between (a signal)
# counts the round first, so the record never holds a total that silently leaves a round out.
ROUND_OPEN=0

elapsed() { echo $(( PREV_ELAPSED + $(date +%s) - T0 )); }
tokens()  { if [ "$TOK_KNOWN" = "1" ] && [ "$ROUNDS" -gt 0 ]; then echo $(( TOK_IN + TOK_OUT )); else echo unknown; fi; }

# save <status> <reason> — the durable record. Written through a temp file and renamed, so a kill
# mid-write leaves the previous record whole instead of a truncated one.
save() {
  local st="$1" reason="$2" tmpf tok cost
  tok="$(tokens)"
  if [ "$COST_KNOWN" = "1" ] && [ "$ROUNDS" -gt 0 ] && [ "$USAGE_SRC" != "none" ]; then cost="$COST"; else cost=unknown; fi
  tmpf="$STATE.tmp.$$"
  jq -n \
    --arg run "$KEY" --arg issue "$ISSUE" --arg branch "$BRANCH" --arg worktree "$WORKTREE" \
    --arg agent "$AGENT" --arg args "$ARGS_NL" --arg objective "$OBJECTIVE" \
    --arg until "$UNTIL" --arg check "$CHECK" --arg summary "$SUMMARY" --arg publish "${PUBLISH:-0}" \
    --arg status "$st" --arg reason "$reason" --arg detail "$DETAIL" \
    --argjson rounds "$ROUNDS" --argjson elapsed "$(elapsed)" \
    --argjson mi "$MAX_ITERS" --argjson ms "$MAX_SECONDS" --argjson rs "$ROUND_SECONDS" --arg mt "$MAX_TOKENS" \
    --arg tok "$tok" --argjson tin "$TOK_IN" --argjson tout "$TOK_OUT" --arg cost "$cost" --arg kcost "$COST" \
    --arg src "$USAGE_SRC" --arg pr "$PR_URL" --arg pid "$$" --arg host "$(hostname 2>/dev/null)" \
    --arg started "$STARTED_AT" --arg updated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg open "$ROUND_OPEN" '
    def num: if . == "unknown" or . == "" then "unknown" else (tonumber * 1000000 | round / 1000000) end;
    { run: $run, issue: $issue, branch: $branch, worktree: $worktree,
      agent: $agent, agent_args: ($args | split("\n") | map(select(. != ""))),
      objective: $objective, until: $until, check: $check,
      publish: ($publish == "1"), summary: $summary,
      status: $status, reason: $reason, detail: $detail,
      rounds: $rounds, round_open: ($open == "1"), elapsed_seconds: $elapsed,
      limits: { max_iters: $mi, max_seconds: $ms, round_seconds: $rs,
                max_tokens: (if $mt == "" then null else ($mt | tonumber) end) },
      usage: { tokens: ($tok | num), known_input_tokens: $tin, known_output_tokens: $tout,
               cost_usd: ($cost | num), known_cost_usd: ($kcost | num), source: $src },
      pr_url: $pr, pid: ($pid | tonumber), host: $host,
      started_at: $started, updated_at: $updated,
      resume: (if $reason == "done" or $status == "running" then "" else "cckit autopilot run --resume" end) }' \
    > "$tmpf" && mv -f "$tmpf" "$STATE"
}

# account_round <agent> <round> — add what the runtime printed for one round to the totals. A
# round whose output holds no usage makes the total unknown: the tokens it spent are real and
# uncounted, so a sum without them is an undercount, not a figure.
account_round() {
  local u_in u_out u_cost
  read -r u_in u_out u_cost <<< "$(al_usage "$1" "$SDIR/$KEY.round-$2.out")"
  if is_uint "$u_in" && is_uint "$u_out"; then
    TOK_IN=$((TOK_IN + u_in)); TOK_OUT=$((TOK_OUT + u_out)); USAGE_SRC="$1"
  else
    TOK_KNOWN=0
  fi
  if [ "$u_cost" = "unknown" ]; then COST_KNOWN=0
  else COST="$(awk -v a="$COST" -v b="$u_cost" 'BEGIN{printf "%.6f", a + b}')"; fi
  ROUND_OPEN=0
}

# The round a dead runner left open (SIGKILL, power loss: no trap ran). Counted here, once, from
# the output file it left; the state written next carries round_open=false, so a second resume
# does not count it again.
[ -z "$PREV_OPEN_AGENT" ] || account_round "$PREV_OPEN_AGENT" "$PREV_ROUNDS"

# stop <reason> <exit-code> — the one way a run ends.
stop() {
  save stopped "$1"
  echo "autopilot run: stopped - reason=$1 rounds=$ROUNDS elapsed=$(elapsed)s tokens=$(tokens)${DETAIL:+ ($DETAIL)}"
  echo "autopilot run: state $STATE"
  [ "$1" = "done" ] || echo "autopilot run: resume with: cckit autopilot run --resume"
  exit "$2"
}

on_signal() {
  trap '' INT TERM HUP
  al_stop
  # The round in flight is over now; count it before the record is written. Skipping this left
  # the interrupted round out of the total, and `--max-tokens` kept passing after a resume.
  [ "$ROUND_OPEN" != "1" ] || account_round "$AGENT" "$ROUNDS"
  DETAIL="this process received a signal during round $ROUNDS"
  stop interrupted 130
}
trap on_signal INT TERM HUP

# fingerprint — HEAD plus the working tree. Two equal fingerprints around a round mean the round
# produced nothing a reviewer could read, whatever the agent printed.
fingerprint() {
  { git rev-parse HEAD 2>/dev/null; git status --porcelain 2>/dev/null; git diff 2>/dev/null; } | cksum
}

# run_cmd <label> <command> — a completion check or gate, bounded like a round, output kept.
run_cmd() {
  al_run "$ROUND_SECONDS" "$2" </dev/null > "$SDIR/$KEY.$1.out" 2>&1
}

publish() {
  [ -n "$PUBLISH" ] || return 0
  if [ -n "$PR_URL" ]; then echo "autopilot run: PR already recorded - $PR_URL"; return 0; fi
  local existing
  # A read, so a run killed between `gh pr create` and the state write still finds its PR.
  existing="$(gh pr list --head "$BRANCH" --state open --json url --jq '.[0].url // ""' 2>/dev/null)" || existing=""
  if [ -n "$existing" ]; then
    PR_URL="$existing"; echo "autopilot run: the branch already has an open PR - $PR_URL"; return 0
  fi
  local out
  out="$("$ROOT/bin/cckit" pr "$ISSUE" "$SUMMARY" 2>&1)" || { DETAIL="cckit pr failed: $(printf '%s' "$out" | tail -n 3 | tr '\n' ' ')"; return 1; }
  PR_URL="$(printf '%s\n' "$out" | grep -oE 'https?://[^ ]+/pull/[0-9]+' | tail -n 1)"
  echo "autopilot run: opened ${PR_URL:-a PR (url not parsed)}"
}

finish() {
  if [ -n "$CHECK" ]; then
    run_cmd check "$CHECK" || { DETAIL="--check exited $? - output in $SDIR/$KEY.check.out"; stop check-failed 6; }
  fi
  publish || stop publish-failed 7
  stop done 0
}

echo "autopilot run: $BRANCH${ISSUE:+ (issue #$ISSUE)} · agent $AGENT · max-iters $MAX_ITERS · max-seconds $MAX_SECONDS · max-tokens ${MAX_TOKENS:-none}"
save running ""

# The stop condition may already hold (a resumed run whose last round finished the work, or an
# objective that was done before it started). Asking costs one command, not one agent round.
if [ -n "$UNTIL" ] && run_cmd until "$UNTIL"; then
  DETAIL="--until already passed before round $((ROUNDS + 1))"
  finish
fi

FEEDBACK="" UNTIL_FAILED=0
while :; do
  [ "$ROUNDS" -lt "$MAX_ITERS" ] || { DETAIL="$ROUNDS of $MAX_ITERS rounds used"; stop limit-iters 4; }
  left=$(( MAX_SECONDS - $(elapsed) ))
  [ "$left" -gt 0 ] || { DETAIL="$(elapsed)s of ${MAX_SECONDS}s used"; stop limit-seconds 4; }
  if [ -n "$MAX_TOKENS" ] && [ "$ROUNDS" -gt 0 ]; then
    [ "$TOK_KNOWN" = "1" ] || { DETAIL="--max-tokens $MAX_TOKENS cannot be checked: a round reported no usage"; stop usage-unknown 4; }
    [ $(( TOK_IN + TOK_OUT )) -lt "$MAX_TOKENS" ] || { DETAIL="$(( TOK_IN + TOK_OUT )) of $MAX_TOKENS tokens used"; stop limit-tokens 4; }
  fi

  ROUNDS=$((ROUNDS + 1)); ROUND_OPEN=1
  bound="$ROUND_SECONDS"; [ "$left" -lt "$bound" ] && bound="$left"
  {
    printf '%s\n\n' "$OBJECTIVE"
    cat <<EOF
You are running HEADLESS in $WORKTREE on branch $BRANCH: no human is in this session to answer a
question, so decide within what the repository shows. This is round $ROUNDS of at most $MAX_ITERS.
Commit your work on this branch as you go. Do not push, open a pull request, merge, or switch
branches: cckit publishes the branch after its own checks pass.
EOF
    [ -n "$UNTIL" ] && printf '\nThe run ends when this command exits 0:\n  %s\n' "$UNTIL"
    [ "$UNTIL_FAILED" = "1" ] && printf '\nIt failed after the previous round.%s\n' "${FEEDBACK:+ Its last output:
$FEEDBACK}"
  } > "$SDIR/$KEY.prompt"
  save running ""
  # Taken after this round's own files are written, so only the agent's work can move it.
  before="$(fingerprint)"

  echo "autopilot run: round $ROUNDS (bound ${bound}s)"
  al_run "$bound" "$AGENT_CMD" < "$SDIR/$KEY.prompt" > "$SDIR/$KEY.round-$ROUNDS.out" 2> "$SDIR/$KEY.round-$ROUNDS.err"
  arc=$?

  # Usage first, so a round that failed or was killed still counts what it reported.
  account_round "$AGENT" "$ROUNDS"

  if [ "$arc" = "124" ]; then
    DETAIL="round $ROUNDS hit its ${bound}s bound and was killed"; stop limit-seconds 4
  elif [ "$arc" -gt 128 ]; then
    DETAIL="the agent died on signal $((arc - 128)) in round $ROUNDS"; stop interrupted 130
  elif [ "$arc" != "0" ]; then
    DETAIL="the agent exited $arc in round $ROUNDS - stderr in $SDIR/$KEY.round-$ROUNDS.err"; stop agent-failed 3
  fi

  if [ -n "$UNTIL" ]; then
    if run_cmd until "$UNTIL"; then DETAIL="--until passed after round $ROUNDS"; finish; fi
    UNTIL_FAILED=1; FEEDBACK="$(tail -n 40 "$SDIR/$KEY.until.out" 2>/dev/null)"
  fi
  if [ "$(fingerprint)" = "$before" ]; then
    DETAIL="round $ROUNDS changed neither HEAD nor the working tree"; stop no-progress 5
  fi
  if [ -z "$UNTIL" ]; then DETAIL="the agent exited 0 after round $ROUNDS"; finish; fi
done
