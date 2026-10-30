#!/usr/bin/env bash
# shellcheck shell=bash
# contribute-root.sh — which cckit checkout `cckit contribute` acts on (#368).
#
#   contribute_root <dir> <installed-root>   print the checkout to contribute from
#
# The cckit checkout that contains <dir> wins: a worktree (where the rules say work happens) or any
# other clone. "A cckit checkout" = a git toplevel carrying bin/cckit and scripts/contribute.sh.
# Otherwise the installed checkout <installed-root> is used, as before. Before #368 it was always
# the installed checkout, so contribute ran the gate and opened the PR for whatever branch that
# checkout had, never the worktree the agent was working in.
# errors: pure — prints a path, rc 0; never changes directory
# bash 3.2 + zsh compatible.
contribute_root() {
  local dir="${1:-$PWD}" installed="${2:-}" top
  top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
  if [ -n "$top" ] && [ -f "$top/bin/cckit" ] && [ -f "$top/scripts/contribute.sh" ]; then
    printf '%s\n' "$top"
  else
    printf '%s\n' "$installed"
  fi
}
