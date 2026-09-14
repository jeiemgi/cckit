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

or_herdr_kind_supported() {
  case "${1:-}" in
    pi|claude|codex|gemini|cursor|devin|agy|cline|omp|mastracode|opencode|copilot|kimi|kiro|droid|amp|grok|hermes|kilo|qodercli|qwen|letta|maki|muse) return 0 ;;
    *) return 1 ;;
  esac
}

or_runtime_preflight() {
  local runtime="$1" agent="$2" dryrun="${3:-0}"
  or_runtime_validate "$runtime" || return $?

  if [ "$runtime" = "herdr" ] && ! or_herdr_kind_supported "$agent"; then
    echo "orchestrate: Herdr needs a supported agent kind, not '$agent'" >&2
    echo "             use --agent codex, --agent claude, or another kind listed by 'herdr agent start --help'" >&2
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

or_herdr_launch() {
  local session="$1" agent="$2" seed_enabled="$3" detach="$4" project="$5"
  shift 5
  local entries=("$@") first entry wt rest branch num created workspace pane tab name seed

  first=1
  workspace=""
  for entry in "${entries[@]}"; do
    wt="${entry%%|*}"; rest="${entry#*|}"; branch="${rest%%|*}"; num="${rest##*|}"
    if [ "$first" -eq 1 ]; then
      created="$(herdr workspace create --cwd "$wt" --label "cckit:${project:-project}:$session" --no-focus)" || return $?
      workspace="$(printf '%s\n' "$created" | jq -r '.result.workspace.workspace_id // empty')"
      pane="$(printf '%s\n' "$created" | jq -r '.result.root_pane.pane_id // empty')"
      [ -n "$workspace" ] && [ -n "$pane" ] || {
        echo "orchestrate: Herdr workspace response did not include workspace and pane IDs" >&2
        return 1
      }
      first=0
    else
      tab="$(herdr tab create --workspace "$workspace" --cwd "$wt" --label "issue-$num" --no-focus)" || return $?
      pane="$(printf '%s\n' "$tab" | jq -r '.result.root_pane.pane_id // empty')"
      [ -n "$pane" ] || {
        echo "orchestrate: Herdr tab response did not include a pane ID for issue #$num" >&2
        return 1
      }
    fi

    name="$(or_herdr_agent_name "$project" "$num")"
    herdr agent start "$name" --kind "$agent" --pane "$pane" >/dev/null || return $?
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
