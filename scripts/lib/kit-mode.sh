#!/usr/bin/env bash
# kit-mode.sh — resolve the effective enforcement MODE for a location, and map it to a gate (#371).
#
# `mode` (draft | guided | enforced) is a cascade key (workspace -> project -> island), so it is
# resolved by kit-config-resolve.sh like any other field. This lib gives hooks and skills a single
# place to ask "how strict am I HERE?" and "should I block, warn, or stay silent?".
#
#   draft     guardrails OFF      — explore freely; hooks no-op
#   guided    guardrails WARN     — hooks print a notice, never block (default)
#   enforced  guardrails BLOCK    — hooks exit non-zero (worktree-only, PR-per-issue)
#
# Source it:  source scripts/lib/kit-mode.sh   (auto-sources kit-config-resolve.sh alongside)
# CLI:        scripts/lib/kit-mode.sh [--dir DIR]            -> prints the mode
#             scripts/lib/kit-mode.sh --gate [--dir DIR]     -> prints block|warn|off

_kit_mode_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_kit_mode_dir/kit-config-resolve.sh"
# shellcheck source=/dev/null
. "$_kit_mode_dir/kit-cli.sh"   # kit_is_main

KIT_MODE_DEFAULT="${KIT_MODE_DEFAULT:-guided}"

# kit_mode [dir] -> draft|guided|enforced  (default guided; KIT_MODE env overrides everything)
kit_mode() {
  if [ -n "${KIT_MODE:-}" ]; then printf '%s\n' "$KIT_MODE"; return 0; fi
  local m; m="$(kit_resolve_get '.mode' "${1:-$PWD}" 2>/dev/null)"
  case "$m" in
    draft|guided|enforced) printf '%s\n' "$m";;
    *) printf '%s\n' "$KIT_MODE_DEFAULT";;
  esac
}

# kit_gate [dir] -> block|warn|off  (what a guardrail hook should do at this mode)
kit_gate() {
  case "$(kit_mode "${1:-$PWD}")" in
    enforced) printf 'block\n';;
    draft)    printf 'off\n';;
    *)        printf 'warn\n';;   # guided
  esac
}

# kit_gate_apply <message> [dir]
# The hook helper: emit + exit per the resolved gate. enforced -> stderr + exit 2 (blocks the
# tool call in Claude Code); guided -> stderr notice + exit 0; draft -> silent exit 0.
# Hooks call:  kit_gate_apply "branch-naming: use <kind>/<N>-slug"   (and let it set the exit code)
kit_gate_apply() {
  local msg="$1" dir="${2:-$PWD}"
  case "$(kit_gate "$dir")" in
    block) printf 'kit[enforced]: %s\n' "$msg" >&2; return 2;;
    warn)  printf 'kit[guided]: %s\n'   "$msg" >&2; return 0;;
    off)   return 0;;
  esac
}

# CLI (direct execution only; zsh-safe guard)
# CLI (direct execution only)
if kit_is_main; then
  _d="$PWD"; _gate=0
  while [ $# -gt 0 ]; do case "$1" in
    --dir) _d="$2"; shift 2;;
    --gate) _gate=1; shift;;
    -h|--help) echo "usage: kit-mode.sh [--dir DIR] [--gate]"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac; done
  [ "$_gate" = 1 ] && kit_gate "$_d" || kit_mode "$_d"
fi
