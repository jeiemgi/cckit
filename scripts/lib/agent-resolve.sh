#!/usr/bin/env bash
# agent-resolve.sh — choose WHICH agent profile a piece of work runs under (#319).
#
# Precedence, highest first (the research decision on #326):
#   1. an explicit command override      — the operator said so on this invocation
#   2. the issue's own `agent:<profile>` label
#   3. the parent effort's `agent:<profile>` label
#   4. `agents.default` — or, when that is unset, the CHEAPEST declared profile, so an
#      unconfigured project lands on the inexpensive path instead of an arbitrary one
#
# The walk is PURE: it takes label strings as arguments rather than fetching them, so the precedence
# rules are testable without gh, a network, or a fixture repo. `ap_labels_fetch` is the one impure
# helper, kept separate and thin for exactly that reason.
#
# A resolved name is always validated against the stage before it is returned, so a caller can treat
# a rc-0 result as launchable and never has to re-check.
# errors: mixed — the resolution walk is pure string work; ap_resolve propagates rc 2 from
# ap_profile_validate (undeclared profile, missing kind, bad stage) or on an ambiguous label set,
# and rc 4 when nothing resolves at all. ap_labels_fetch is best-effort and echoes empty on failure.
# shellcheck shell=bash

_ar_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[ -n "${AP_STAGES_DEFAULT:-}" ] || . "$_ar_dir/agent-profile.sh"

# ap_profile_from_labels <labels> — echo the profile named by a single `agent:<name>` label.
# Labels may be comma- or newline-separated. TWO different agent: labels is ambiguous and refused
# (rc 2) rather than resolved by picking one — a silent pick would run an agent nobody chose.
ap_profile_from_labels() {
  local raw="${1:-}" l seen="" count=0
  [ -n "$raw" ] || return 0
  while IFS= read -r l; do
    case "$l" in
      agent:?*) 
        l="${l#agent:}"
        case ",$seen," in *",$l,"*) continue ;; esac
        seen="${seen:+$seen,}$l"; count=$((count + 1)) ;;
    esac
  done <<EOF
$(printf '%s' "$raw" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
EOF
  [ "$count" -gt 0 ] || return 0
  if [ "$count" -gt 1 ]; then
    echo "agent-resolve: ambiguous agent labels ($seen) — an issue may carry only one" >&2
    return 2
  fi
  printf '%s\n' "$seen"
}

# ap_parent_effort_num <title> — echo the parent effort number from a sub-issue title
# (`[Effort 318] 3 · thing` -> 318). Empty for a standalone issue. Pure.
ap_parent_effort_num() {
  printf '%s' "${1:-}" | sed -n 's/^\[Effort \([0-9][0-9]*\)\].*/\1/p'
}

# ap_labels_fetch <repo> <issue> — echo an issue's labels, comma-separated. Best-effort: any gh
# failure echoes nothing, so a resolver falls through to the next precedence level instead of dying.
# Uses the REST endpoint rather than `gh issue view`, which goes through GraphQL and has its own,
# separately-exhaustible rate limit.
ap_labels_fetch() {
  local repo="${1:-}" num="${2:-}"
  [ -n "$repo" ] && [ -n "$num" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  gh api "repos/$repo/issues/$num" --jq '[.labels[].name] | join(",")' 2>/dev/null || true
}

# ap_resolve <cfg> <stage> <override> <issue-labels> <parent-labels> — echo the resolved profile.
# Pure given its arguments. rc 2 on an invalid/ambiguous selection, rc 4 when nothing resolves.
ap_resolve() {
  local cfg="${1:-}" stage="${2:-}" override="${3:-}" ilabels="${4:-}" plabels="${5:-}"
  local name src rc_
  if [ -n "$override" ]; then
    name="$override"; src="command override"
  else
    name="$(ap_profile_from_labels "$ilabels")" || return 2
    if [ -n "$name" ]; then src="issue label"
    else
      name="$(ap_profile_from_labels "$plabels")" || return 2
      if [ -n "$name" ]; then src="parent effort label"
      else
        name="$(ap_default_profile "$cfg")" || return 2
        src="agents.default"
      fi
    fi
  fi

  if [ -z "$name" ]; then
    echo "agent-resolve: no profile resolved for stage '${stage:-?}' — no override, no agent: label, no agents.default" >&2
    return 4
  fi

  ap_profile_validate "$cfg" "$name" "$stage" || { rc_=$?; echo "agent-resolve: rejected '$name' (from $src)" >&2; return "$rc_"; }
  printf '%s\n' "$name"
}

# ap_resolve_source <cfg> <override> <issue-labels> <parent-labels> — echo WHICH precedence level
# supplied the name, for the stage receipt. Mirrors ap_resolve's walk without re-validating.
ap_resolve_source() {
  local cfg="${1:-}" override="${2:-}" ilabels="${3:-}" plabels="${4:-}" n
  [ -n "$override" ] && { printf 'command override\n'; return 0; }
  n="$(ap_profile_from_labels "$ilabels" 2>/dev/null)" && [ -n "$n" ] && { printf 'issue label\n'; return 0; }
  n="$(ap_profile_from_labels "$plabels" 2>/dev/null)" && [ -n "$n" ] && { printf 'parent effort label\n'; return 0; }
  n="$(ap_default_profile "$cfg" 2>/dev/null)" && [ -n "$n" ] && { printf 'agents.default\n'; return 0; }
  return 4
}
