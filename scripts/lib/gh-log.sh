#!/usr/bin/env bash
# cckit-forwarding-stub: scripts/lib/gh-log.sh moved to lib/forge/gh-log.sh (#601). Installed projects call this path, so
# the stub stays until the release after 0.13 (decision 66). Sourced (bash or zsh) or run, it forwards.
_cckit_self="${BASH_SOURCE[0]:-$0}"
_cckit_fwd="$(cd "$(dirname "$_cckit_self")" 2>/dev/null && pwd)/../../lib/forge/gh-log.sh"
_cckit_sourced=0
if [ -n "${ZSH_VERSION:-}" ]; then
  case "${ZSH_EVAL_CONTEXT:-}" in *file*) _cckit_sourced=1 ;; esac
elif [ "$_cckit_self" != "$0" ]; then
  _cckit_sourced=1
fi
# shellcheck source=/dev/null
if [ "$_cckit_sourced" = 1 ]; then unset _cckit_self _cckit_sourced; . "$_cckit_fwd" "$@"; return $?; fi
exec bash "$_cckit_fwd" "$@"
