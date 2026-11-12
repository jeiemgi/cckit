#!/usr/bin/env bash
# orchestration-runtime.sh — terminal-runtime adapters for cckit orchestrate.
#
# cckit owns the work: issue selection, worktrees, branches, pull requests. A runtime owns only the
# terminal the agent runs in. Everything here is that second half — validate the runtime name,
# refuse an agent kind the runtime cannot start, and build the Herdr topology (workspace → tab →
# pane → agent) that tmux gets for free from `tmux new-session`.
# errors: strict — an invalid runtime, an unsupported agent kind, a missing binary or a failed
# herdr call propagates its rc; the caller must not create worktrees after a non-zero preflight.
# shellcheck shell=bash

or_runtime_validate() {
  case "${1:-}" in
    tmux|herdr) return 0 ;;
    *) echo "orchestrate: --runtime must be tmux or herdr (got '${1:-}')" >&2; return 2 ;;
  esac
}

# The kinds Herdr can start. Read from the INSTALLED binary rather than a copy kept here: a
# hand-written list drifts silently against the runtime, and it already had — it carried `letta`,
# which herdr 0.9.0 does not support, so `--agent letta` passed preflight and then failed at
# `agent start`, after the worktree existed. The fallback list is only for when herdr is absent
# (a dry run) or its help output changes shape; it is deliberately the 0.9.0 set.
_OR_HERDR_KINDS_FALLBACK="pi claude codex gemini cursor devin agy cline omp mastracode opencode copilot kimi kiro droid amp grok hermes kilo qodercli qwen maki muse"
_OR_HERDR_KINDS=""

or_herdr_kinds() {
  [ -n "$_OR_HERDR_KINDS" ] && { printf '%s\n' "$_OR_HERDR_KINDS"; return 0; }
  local live=""
  if command -v herdr >/dev/null 2>&1; then
    live="$(herdr agent start --help 2>&1 \
      | tr -d '\n' \
      | sed -n 's/.*\[possible values:\([^]]*\)\].*/\1/p' \
      | tr -d ' ' | tr ',' ' ')"
  fi
  case "$live" in
    *claude*) _OR_HERDR_KINDS="$live" ;;   # sanity: a parse that lost `claude` is a bad parse
    *)        _OR_HERDR_KINDS="$_OR_HERDR_KINDS_FALLBACK" ;;
  esac
  printf '%s\n' "$_OR_HERDR_KINDS"
}

or_herdr_kind_supported() {
  local want="${1:-}" k
  [ -n "$want" ] || return 1
  for k in $(or_herdr_kinds); do
    [ "$k" = "$want" ] && return 0
  done
  return 1
}

or_runtime_preflight() {
  local runtime="$1" agent="$2" dryrun="${3:-0}"
  or_runtime_validate "$runtime" || return $?

  if [ "$runtime" = "herdr" ] && ! or_herdr_kind_supported "$agent"; then
    echo "orchestrate: Herdr needs a supported agent kind, not '$agent'" >&2
    echo "             supported here: $(or_herdr_kinds)" >&2
    return 2
  fi

  [ "$dryrun" -eq 1 ] && return 0
  command -v "$runtime" >/dev/null 2>&1 || {
    case "$runtime" in
      tmux)  echo "orchestrate: tmux not installed (brew install tmux)" >&2 ;;
      herdr) echo "orchestrate: Herdr not installed (see https://herdr.dev/install)" >&2 ;;
    esac
    return 1
  }
  command -v "$agent" >/dev/null 2>&1 || {
    echo "orchestrate: agent '$agent' not on PATH" >&2
    return 1
  }
}

or_herdr_agent_name() {
  local project="$1" issue="$2" base room
  base="cckit-${project:-project}"
  base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')"
  base="${base#-}"
  [ -n "$base" ] || base="cckit-project"
  case "$base" in [a-z]*) ;; *) base="cckit-$base" ;; esac
  room=$((31 - ${#issue}))
  [ "$room" -gt 0 ] || room=1
  printf '%.*s-%s' "$room" "$base" "$issue"
}

# or_base_override — echo the base branch the CALLER named in KIT_BASE_BRANCH, or nothing when the
# base in effect is the config's. Read after load_kit_config, which sets both variables (#352).
or_base_override() {
  [ -n "${KIT_BASE_BRANCH:-}" ] && [ -n "${KIT_BASE_BRANCH_CONFIG:-}" ] || return 0
  [ "$KIT_BASE_BRANCH" = "$KIT_BASE_BRANCH_CONFIG" ] || printf '%s\n' "$KIT_BASE_BRANCH"
  return 0
}

# or_tmux_new_session <session> <window> <cwd> — `tmux new-session -d` that keeps the base branch
# out of the tmux server (#352).
#
# The first client to reach tmux STARTS the server, and the server keeps that client's environment
# as its global environment: every pane of every later session inherits it, in any repo. An
# orchestrate run in project A would leave its base branch there, and `cckit` in a pane opened on
# project B would then read it as an override of B's config. So the server is never started with
# the variable, and one left by a server an earlier cckit started is dropped. An override reaches
# the pane on the agent's command line instead (or_tmux_agent_cmd).
or_tmux_new_session() {
  local session="$1" window="$2" cwd="$3"
  tmux set-environment -g -u KIT_BASE_BRANCH 2>/dev/null || true
  tmux set-environment -g -u KIT_BASE_BRANCH_DEFAULTED 2>/dev/null || true
  ( unset KIT_BASE_BRANCH KIT_BASE_BRANCH_DEFAULTED; tmux new-session -d -s "$session" -n "$window" -c "$cwd" )
}

# or_tmux_agent_cmd <kind> <agent-args-nl> [<base-override>] — echo the command LINE tmux types into a pane.
#
# The two runtimes receive a profile's argv differently, and the difference is the whole reason this
# exists. Herdr takes an argv array and never meets a shell; tmux `send-keys` writes a command line
# INTO the pane's shell, so every argument must be single-quoted here or that shell re-splits it.
#
# Skipping this dropped a profile's args on the DEFAULT runtime while orchestrate still printed the
# resolved profile — a profile selecting a model ran on the CLI's default model with no warning.
#
# <base-override> (optional, from or_base_override) is put on the command line as
# `env KIT_BASE_BRANCH='<base>' <kind> …` (#352). A pane's environment comes from the tmux SERVER,
# not from the orchestrate process: with a server already running the pane never saw the caller's
# KIT_BASE_BRANCH, so `cckit pr` inside it targeted the config's base while the worktree had been
# cut from the override. Typed onto the command line, the base reaches the agent either way.
# `env`, not a bare `VAR=value cmd`, so it also runs in a pane whose shell is not POSIX.
or_tmux_agent_cmd() {
  local kind="${1:-}" args_nl="${2:-}" base="${3:-}" cmd="${1:-}" a esc
  if [ -n "$base" ]; then
    esc=${base//\'/\'\\\'\'}
    cmd="env KIT_BASE_BRANCH='$esc' $cmd"
  fi
  [ -n "$args_nl" ] || { printf '%s\n' "$cmd"; return 0; }
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    # Escape in its OWN assignment, not inline in the concatenation: the `'\''` idiom needs one
    # level of quoting and doing it inside a double-quoted string silently adds another. The
    # seed prompt a few lines down in orchestrate.sh uses this exact two-step form for the same
    # reason — it was arrived at by a bug, not by taste.
    esc=${a//\'/\'\\\'\'}
    cmd="$cmd '$esc'"
  done <<EOF
$args_nl
EOF
  printf '%s\n' "$cmd"
}

# or_tmux_worker_cmd <wave-worker-path> <session> <issue> — the prefix that puts the agent command
# under the result-recording wrapper: `'<path>' '<session>' <issue> --`. Quoted the same way and for
# the same reason as the argv above — tmux types this into a shell, and an install path or a session
# name containing a space would otherwise be re-split there.
or_tmux_worker_cmd() {
  local w="${1:-}" s="${2:-}" n="${3:-}" ew es
  ew=${w//\'/\'\\\'\'}
  es=${s//\'/\'\\\'\'}
  printf "'%s' '%s' %s --\n" "$ew" "$es" "$n"
}

# or_herdr_launch <session> <kind> <seed?> <detach?> <project> <agent-args-nl> <entry>...
#
# <agent-args-nl> is the profile's extra CLI argv, ONE PER LINE (empty for none). They are handed to
# `herdr agent start ... -- <args>`, which is Herdr's documented passthrough to the agent process.
# One-per-line, then rebuilt into an array, so an argument containing spaces stays one argument —
# a flat string would be re-split by the shell and silently change what the agent was asked to do.
or_herdr_launch() {
  local session="$1" agent="$2" seed_enabled="$3" detach="$4" project="$5" args_nl="${6:-}"
  shift 6
  local entries=("$@") first entry wt rest branch num created workspace pane tab name seed
  local aargs=() _a
  if [ -n "$args_nl" ]; then
    while IFS= read -r _a; do [ -n "$_a" ] && aargs+=("$_a"); done <<EOF
$args_nl
EOF
  fi

  # A caller's base override (#352) goes in with `--env`: the pane's process is started by the
  # Herdr server, which never saw the orchestrate process's environment.
  local envargs=() base
  base="$(or_base_override)"
  [ -n "$base" ] && envargs=(--env "KIT_BASE_BRANCH=$base")

  first=1
  workspace=""
  for entry in "${entries[@]}"; do
    wt="${entry%%|*}"; rest="${entry#*|}"; branch="${rest%%|*}"; num="${rest##*|}"
    if [ "$first" -eq 1 ]; then
      created="$(herdr workspace create --cwd "$wt" --label "cckit:${project:-project}:$session" ${envargs+"${envargs[@]}"} --no-focus)" || return $?
      workspace="$(printf '%s\n' "$created" | jq -r '.result.workspace.workspace_id // empty')"
      pane="$(printf '%s\n' "$created" | jq -r '.result.root_pane.pane_id // empty')"
      [ -n "$workspace" ] && [ -n "$pane" ] || {
        echo "orchestrate: Herdr workspace response did not include workspace and pane IDs" >&2
        return 1
      }
      first=0
    else
      tab="$(herdr tab create --workspace "$workspace" --cwd "$wt" --label "issue-$num" ${envargs+"${envargs[@]}"} --no-focus)" || return $?
      pane="$(printf '%s\n' "$tab" | jq -r '.result.root_pane.pane_id // empty')"
      [ -n "$pane" ] || {
        echo "orchestrate: Herdr tab response did not include a pane ID for issue #$num" >&2
        return 1
      }
    fi

    name="$(or_herdr_agent_name "$project" "$num")"
    if [ "${#aargs[@]}" -gt 0 ]; then
      herdr agent start "$name" --kind "$agent" --pane "$pane" -- "${aargs[@]}" >/dev/null || return $?
    else
      herdr agent start "$name" --kind "$agent" --pane "$pane" >/dev/null || return $?
    fi
    if [ "$seed_enabled" -eq 1 ]; then
      seed="$(seed_for "$num" "$branch" "$wt")"
      herdr agent prompt "$name" "$seed" >/dev/null || return $?
    fi
    echo "  #$num  Herdr agent '$name' in $wt"
  done

  if [ "$detach" -eq 1 ]; then
    echo "orchestrate: Herdr workspace '$workspace' built. Open: herdr workspace focus $workspace && herdr"
  else
    herdr workspace focus "$workspace" >/dev/null
    exec herdr
  fi
}
