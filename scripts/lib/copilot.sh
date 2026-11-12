#!/usr/bin/env bash
# copilot.sh — the copilot driver: turn the wave plan into a fan-out BRIEF the driving agent enacts
# (Effort 75 · #78). This is cckit's prompt machine.
#
# The orchestration brain is the driving agent, not a background launcher. So the copilot does not
# spawn anything itself — it EMITS the plan-as-instructions: for the current wave, a ready-to-run
# worker prompt per issue, and the between-waves drive (gate + merge with the captain, then re-run
# for the next wave). The agent reads the brief and acts.
#
# Two layers, kept apart (E257.6, #263). The WAVE DATA — which issues, their ctx, the prompt each
# worker gets — is the same for every runtime, and `--llm` emits only that. The DISPATCH wording —
# how this runtime starts N isolated workers — is chosen per adapter: Claude Code fans out Task
# subagents with worktree isolation; for Codex, cckit creates the worktrees (`cckit orchestrate`).
#
#   cckit wave                    brief for the open board: wave 0 fan-out + the loop
#   cckit wave --effort <N>       brief scoped to effort #N's sub-issues
#   cckit wave --cap <K>          session ctx budget per wave (passed to the plan machine)
#   cckit wave --adapter <claude|codex|both>   dispatch wording (default: the project's adapters)
#   cckit wave --llm              the fan-out as TOON rows (wave,number,ctx,prompt) for an agent
#
# Requires: gh, jq (via the plan machine). bash 3.2 / zsh compatible.
# errors: strict — refuses to emit a brief without gh + jq

COPILOT_REPO="${COPILOT_REPO:-${KIT_REPO:-}}"
# Resolved at source time: inside a function zsh's $0 is the function's name, not this file.
_COPILOT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

# _copilot_seed <num> <title> — the headless worker prompt for one issue (worktree already isolated).
# Runtime-neutral on purpose: it is wave data, so it must read the same whichever agent receives it.
_copilot_seed() {
  local num="$1" title="$2"
  printf 'You are a worker in a cckit wave run — NO human is present, so never ask: decide autonomously and apply effort proportional to the task. Your worktree and branch for issue #%s are already isolated. Do: `gh issue view %s`, implement "%s", run `bash scripts/check.sh` until green, then open the PR with `cckit pr %s "<summary>"`. If it is a no-op, run `cckit close %s "<reason>"` with why. Return a one-line result.' \
    "$num" "$num" "$title" "$num" "$num"
}

# _copilot_adapters <explicit> — the adapters whose dispatch wording the brief carries, as a
# canonical list ("claude", "codex" or "claude codex"). Precedence: --adapter, then CCKIT_ADAPTER,
# then the project's stored selection, then claude (every project scaffolded before the key existed).
_copilot_adapters() {
  local want="${1:-${CCKIT_ADAPTER:-}}" here="$_COPILOT_DIR"
  # shellcheck source=/dev/null
  command -v adapter_normalize >/dev/null 2>&1 || . "$here/adapter-select.sh"
  if [ -n "$want" ]; then adapter_normalize "$want"; return $?; fi
  # shellcheck source=/dev/null
  command -v kit_config_path >/dev/null 2>&1 || . "$here/config-path.sh" 2>/dev/null || true
  adapter_project_list 2>/dev/null || printf 'claude\n'
}

# _copilot_dispatch <adapter> <count> <issue-numbers> — how THIS runtime starts the wave's workers.
_copilot_dispatch() {
  local adapter="$1" n0="$2" nums="$3"
  case "$adapter" in
    claude)
      printf '### Claude Code — spawn %s parallel Task subagent(s)\n\n' "$n0"
      printf 'Each in its OWN worktree (Task isolation: "worktree", run in background). Branches are\nfile-disjoint within a wave, so they will not collide.\n\n'
      ;;
    codex)
      printf '### Codex — launch %s Codex session(s), one cckit worktree each\n\n' "$n0"
      printf 'cckit creates the worktrees: it has not verified an isolation mode for Codex subagents, so do\nnot fan this wave out as subagents of one session in one checkout. Launch one session per issue,\nthen collect how each one ended:\n\n'
      printf '   ```\n   cckit orchestrate --agent codex --detach %s\n   cckit orchestrate --results --wait 3600\n   ```\n\n' "$nums"
      printf '`orchestrate` skips an issue whose `blocked_by` is open, holds `--cap` (default 4) and seeds each\nworker from `cckit brief <issue>`. The prompts below state the same task for a session you start\nby hand in a worktree from `cckit start <issue>`.\n\n'
      ;;
  esac
}

copilot_brief() {
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "copilot: needs gh + jq" >&2; return 1; }
  local repo="$COPILOT_REPO" out="${CCKIT_OUTPUT:-human}" effort="" cap="" adapter_arg="" adapters planargs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --llm|--output=json) out="json"; shift ;;
      --effort)    effort="$2"; planargs+=(--effort "$2"); shift 2 ;;
      --effort=*)  effort="${1#*=}"; planargs+=(--effort "${1#*=}"); shift ;;
      --cap)       cap="$2"; planargs+=(--cap "$2"); shift 2 ;;
      --cap=*)     cap="${1#*=}"; planargs+=(--cap "${1#*=}"); shift ;;
      --adapter)   adapter_arg="${2:-}"; shift 2 ;;
      --adapter=*) adapter_arg="${1#*=}"; shift ;;
      -h|--help)   sed -n '15,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "copilot: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$repo" ] || { echo "copilot: no repo (set KIT_REPO / COPILOT_REPO)" >&2; return 1; }
  # Resolved before any read, so an unknown adapter name refuses instead of emitting a brief with
  # no dispatch section. --llm carries wave data only, but still validates the flag it was given.
  adapters="$(_copilot_adapters "$adapter_arg")" || { echo "copilot: --adapter takes claude, codex or both" >&2; return 2; }

  # pull the wave plan as raw rows from the plan machine (#76).
  local here; here="$(dirname "${BASH_SOURCE[0]}")"
  # shellcheck source=/dev/null
  . "$here/plan-machine.sh"
  local rows
  rows="$(CCKIT_OUTPUT=tsv plan_machine "${planargs[@]+"${planargs[@]}"}" 2>/dev/null)"
  if [ -z "$rows" ]; then
    [ "$out" = "json" ] && echo "[]" || echo "wave: nothing to drive (no open issues in scope)"
    return 0
  fi

  # wave 0 = the issues to fan out right now (everything currently unblocked).
  local wave0; wave0="$(printf '%s\n' "$rows" | awk -F'\t' '$1==0')"
  local waves_total; waves_total="$(printf '%s\n' "$rows" | awk -F'\t' '{print $1}' | sort -nu | tail -1)"

  if [ "$out" = "json" ]; then
    # TOON rows {wave,number,ctx,prompt} — the fan-out as token-cheap agent input.
    local json
    json="$(printf '%s\n' "$wave0" | awk -F'\t' '{print $3"\t"$4"\t"$6}' \
      | while IFS="$(printf '\t')" read -r num ctx title; do
          [ -n "$num" ] || continue
          disp="$(printf '%s' "$title" | sed -E 's/^\[Effort( [0-9]+)?\] [0-9]+ · ?//; s/^\[[A-Za-z]+\] //')"
          printf '%s\t%s\t%s\n' "$num" "$ctx" "$(_copilot_seed "$num" "$disp")"
        done \
      | jq -R -s '[ split("\n")[] | select(length>0) | split("\t")
                    | {wave:0, number:(.[0]|tonumber), ctx:.[1], prompt:.[2]} ]')"
    # shellcheck source=/dev/null
    . "$here/toon.sh"
    printf '%s' "$json" | toon_encode
    return 0
  fi

  # human brief — markdown the agent enacts, routed through the rendering seam (#82): rich via glow
  # in a TTY, verbatim markdown otherwise (renders natively in Claude Code, pipe-safe).
  # shellcheck source=/dev/null
  . "$here/render.sh"
  local n0 esfx nums ad; n0="$(printf '%s\n' "$wave0" | grep -c .)"
  # Not `esfx="$([ -n "$effort" ] && echo …)"`: with no --effort that substitution returns 1, and
  # bin/cckit runs under `set -e`, so the assignment ended the verb before a line was printed —
  # the human brief was empty for every un-scoped `cckit wave`.
  esfx=""; [ -z "$effort" ] || esfx=" --effort $effort"
  nums="$(printf '%s\n' "$wave0" | awk -F'\t' '$3 != "" { printf "%s%s", sep, $3; sep = " " }')"
  {
    printf '# cckit wave — %s%s\n' "$repo" "$([ -n "$effort" ] && echo " · effort #$effort")"
    printf '\nThe plan machine laid out %s wave(s). You are the orchestrator: fan wave 0 out as parallel\nworkers, gate + merge with the captain, then re-run this brief for the next wave.\n' "$((waves_total + 1))"

    printf '\n## Wave 0 — %s parallel worker(s)\n\n' "$n0"
    # The dispatch wording is the adapter's; everything after it is wave data shared by both.
    for ad in $(printf '%s\n' "$adapters"); do _copilot_dispatch "$ad" "$n0" "$nums"; done
    printf '%s\n' "$wave0" | awk -F'\t' '{print $3"\t"$4"\t"$6}' \
      | while IFS="$(printf '\t')" read -r num ctx title; do
          [ -n "$num" ] || continue
          disp="$(printf '%s' "$title" | sed -E 's/^\[Effort( [0-9]+)?\] [0-9]+ · ?//; s/^\[[A-Za-z]+\] //')"
          printf '### #%s · [%s] · %s\n\n' "$num" "$ctx" "$disp"
          printf '> %s\n\n' "$(_copilot_seed "$num" "$disp")"
        done

    printf '## Between waves — drive the captain\n\n'
    printf '1. When the wave-0 workers have opened their PRs, gate + merge them:\n'
    printf '   ```\n   cckit watch --merge%s\n   ```\n' "$esfx"
    printf '2. Merging unblocks the next wave. Re-run this brief to get it:\n'
    printf '   ```\n   cckit wave%s\n   ```\n' "$esfx"
    printf '3. Repeat until `cckit wave` reports nothing to drive. To let the captain self-pace the\n   gate/merge passes, use `cckit watch --loop`'
    # `/loop` is a Claude Code command; a brief for Codex alone must not name it.
    case " $adapters " in *" claude "*) printf ' (or drive this brief under `/loop` in Claude Code)' ;; esac
    printf '.\n\n'
  } | cckit_render
}
