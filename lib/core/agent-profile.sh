#!/usr/bin/env bash
# agent-profile.sh — read and validate the named agent profiles declared in kit config (#325).
#
# A profile is project DATA, not workflow logic: it carries the agent kind, a SPEND TIER, extra CLI
# argv, a permission policy, the stages it may run at, and whether it may write to a branch.
#
# cckit deliberately does NOT name models. A kit that suggests an expensive model in its own config
# schema pushes every user toward spending more, which is the opposite of the point. The project
# spells its own flags in `args`; `tier` is the only cost signal the kit reads, and the cheapest
# profile is what runs when nothing else is chosen. This file reads and validates the declaration —
# choosing WHICH profile an issue resolves to is #319, and launching one is #320.
#
# Everything here refuses early and loudly: a profile selected for a stage it does not list, or a
# `default` naming a profile that was never declared, is an error before a worktree or pane exists,
# not a silent fallback to something plausible.
# errors: mixed — the readers are pure jq over a config file and echo empty for an absent key;
# ap_profile_validate / ap_default_profile propagate rc 2 on an undeclared profile, a missing kind,
# or a stage outside the vocabulary. rc 3 is reserved for "jq is not installed".
# shellcheck shell=bash

# The built-in stage vocabulary. `agents.stages` in the config replaces it; CCKIT_AGENT_STAGES wins
# per invocation. Kept as a space-separated string, not an array, for bash 3.2.
AP_STAGES_DEFAULT="build review design docs"

_ap_need_jq() {
  command -v jq >/dev/null 2>&1 || { echo "agent-profile: jq is required to read agent profiles" >&2; return 3; }
}

# ap_stages <cfg> — echo the stage vocabulary, one per line.
ap_stages() {
  local cfg="${1:-}" declared=""
  if [ -n "${CCKIT_AGENT_STAGES:-}" ]; then
    printf '%s\n' $CCKIT_AGENT_STAGES
    return 0
  fi
  if [ -n "$cfg" ] && [ -f "$cfg" ] && command -v jq >/dev/null 2>&1; then
    declared="$(jq -r '(.agents.stages // [])[]' "$cfg" 2>/dev/null)"
  fi
  if [ -n "$declared" ]; then printf '%s\n' "$declared"; else printf '%s\n' $AP_STAGES_DEFAULT; fi
}

# ap_profile_names <cfg> — echo every declared profile name, one per line. Empty when none.
ap_profile_names() {
  local cfg="${1:-}"
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0
  _ap_need_jq || return $?
  jq -r '(.agents.profiles // {}) | keys[]' "$cfg" 2>/dev/null
}

# ap_profile_exists <cfg> <name> — rc 0 when the profile is declared.
ap_profile_exists() {
  local cfg="${1:-}" name="${2:-}"
  [ -n "$name" ] || return 1
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 1
  _ap_need_jq || return $?
  jq -e --arg n "$name" '(.agents.profiles // {}) | has($n)' "$cfg" >/dev/null 2>&1
}

# ap_profile_field <cfg> <name> <field> — echo one scalar field, empty when absent.
# Scalars only (kind, tier, permissions, contextBudget, write); `args`/`stages` are arrays.
ap_profile_field() {
  local cfg="${1:-}" name="${2:-}" field="${3:-}"
  [ -n "$cfg" ] && [ -f "$cfg" ] && [ -n "$name" ] && [ -n "$field" ] || return 0
  _ap_need_jq || return $?
  jq -r --arg n "$name" --arg f "$field" \
    '(.agents.profiles[$n][$f]) // "" | if type == "boolean" then (if . then "1" else "0" end) else tostring end' \
    "$cfg" 2>/dev/null | sed 's/^null$//'
}

# ap_profile_args <cfg> <name> — echo the profile's extra CLI argv, ONE PER LINE so an argument
# containing spaces survives. A caller builds an array with: while IFS= read -r a; do ...; done
ap_profile_args() {
  local cfg="${1:-}" name="${2:-}"
  [ -n "$cfg" ] && [ -f "$cfg" ] && [ -n "$name" ] || return 0
  _ap_need_jq || return $?
  jq -r --arg n "$name" '(.agents.profiles[$n].args // [])[]' "$cfg" 2>/dev/null
}

# ap_profile_stages <cfg> <name> — echo the stages the profile lists, one per line.
ap_profile_stages() {
  local cfg="${1:-}" name="${2:-}"
  [ -n "$cfg" ] && [ -f "$cfg" ] && [ -n "$name" ] || return 0
  _ap_need_jq || return $?
  jq -r --arg n "$name" '(.agents.profiles[$n].stages // [])[]' "$cfg" 2>/dev/null
}

# ap_profile_writes <cfg> <name> — rc 0 when the profile may write to a branch (default: it may not).
ap_profile_writes() {
  [ "$(ap_profile_field "${1:-}" "${2:-}" write)" = "1" ]
}

# ap_stage_allows <cfg> <name> <stage> — rc 0 when the profile lists that stage. A profile with NO
# `stages` key is allowed nowhere: an unstated permission is not a granted one.
ap_stage_allows() {
  local cfg="${1:-}" name="${2:-}" want="${3:-}" s
  [ -n "$want" ] || return 1
  while IFS= read -r s; do
    [ "$s" = "$want" ] && return 0
  done <<EOF
$(ap_profile_stages "$cfg" "$name")
EOF
  return 1
}

# ap_profile_validate <cfg> <name> [<stage>] — rc 0 when the profile is declared, names a kind, and
# lists only stages in the vocabulary. With <stage>, also requires the profile to allow it.
# Every refusal prints the reason and the fix, because this runs before any worktree exists and the
# operator needs to know which of the four things was wrong.
ap_profile_validate() {
  local cfg="${1:-}" name="${2:-}" stage="${3:-}" kind s known found
  [ -n "$name" ] || { echo "agent-profile: a profile name is required" >&2; return 2; }
  ap_profile_exists "$cfg" "$name" || {
    echo "agent-profile: no profile named '$name' in $cfg" >&2
    echo "               declared: $(ap_profile_names "$cfg" | tr '\n' ' ')" >&2
    return 2
  }
  kind="$(ap_profile_field "$cfg" "$name" kind)"
  [ -n "$kind" ] || { echo "agent-profile: profile '$name' declares no kind (the agent CLI to run)" >&2; return 2; }

  known="$(ap_stages "$cfg" | tr '\n' ' ')"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case " $known " in
      *" $s "*) : ;;
      *) echo "agent-profile: profile '$name' lists stage '$s', which is not in the vocabulary ($known)" >&2; return 2 ;;
    esac
  done <<EOF
$(ap_profile_stages "$cfg" "$name")
EOF

  if [ -n "$stage" ]; then
    case " $known " in
      *" $stage "*) : ;;
      *) echo "agent-profile: stage '$stage' is not in the vocabulary ($known)" >&2; return 2 ;;
    esac
    ap_stage_allows "$cfg" "$name" "$stage" || {
      found="$(ap_profile_stages "$cfg" "$name" | tr '\n' ' ')"
      echo "agent-profile: profile '$name' is not allowed at stage '$stage' (it lists: ${found:-none})" >&2
      return 2
    }
  fi
  return 0
}

# ap_tier_rank <tier> — echo a sortable rank for a spend tier. Unstated means `low`: assuming the
# CHEAP end when a profile says nothing is the safe direction to be wrong in.
ap_tier_rank() {
  case "${1:-low}" in
    low|"") printf '0\n' ;;
    mid)    printf '1\n' ;;
    high)   printf '2\n' ;;
    *)      printf '0\n' ;;
  esac
}

# ap_profile_tier <cfg> <name> — echo the profile's spend tier, `low` when unstated.
ap_profile_tier() {
  local t; t="$(ap_profile_field "${1:-}" "${2:-}" tier)"
  printf '%s\n' "${t:-low}"
}

# ap_cheapest_profile <cfg> — echo the lowest-tier declared profile. Ties break alphabetically so
# the answer is deterministic rather than dependent on jq's key order.
ap_cheapest_profile() {
  local cfg="${1:-}" p best="" best_rank=99 r
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    r="$(ap_tier_rank "$(ap_profile_tier "$cfg" "$p")")"
    if [ "$r" -lt "$best_rank" ]; then best="$p"; best_rank="$r"; fi
  done <<EOF
$(ap_profile_names "$cfg" | sort)
EOF
  [ -n "$best" ] || return 0
  printf '%s\n' "$best"
}

# ap_default_profile <cfg> — echo the profile to use when nothing more specific resolves.
#
# With `agents.default` set, that name is used and a dangling one is a config error: silently
# falling back would run a different agent while the operator believed the default applied.
# With NO `agents.default`, the CHEAPEST declared profile wins. That is the whole point — the
# inexpensive path is the default by construction, not by remembering to configure it.
ap_default_profile() {
  local cfg="${1:-}" name
  name="$(jq -r '.agents.default // ""' "$cfg" 2>/dev/null)"
  if [ -z "$name" ]; then
    ap_cheapest_profile "$cfg"
    return 0
  fi
  ap_profile_exists "$cfg" "$name" || {
    echo "agent-profile: agents.default is '$name', which is not a declared profile" >&2
    return 2
  }
  printf '%s\n' "$name"
}
