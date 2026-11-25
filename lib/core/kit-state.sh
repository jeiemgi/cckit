#!/usr/bin/env bash
# kit-state.sh — the one home for cckit's LOCAL runtime state directory (.cckit/, gitignored).
#
# State here is per-checkout session state, not a repo artifact: the captain's gate record, the
# resume-here handoff, the user's private secret denylist. All of it must resolve to the SAME
# directory no matter which worktree you are standing in — cckit tells you to work in worktrees,
# so CWD-relative or `--show-toplevel`-relative state is state that silently splits per worktree.
#
# `git rev-parse --show-toplevel` is the wrong primitive: inside a worktree it returns the
# WORKTREE's root, so each worktree gets its own .cckit/ and none of them see the main one. The
# handoff note written before this fix was invisible from every worktree for exactly that reason.
# `--git-common-dir` points at the shared .git of the primary checkout in every worktree, so its
# parent is the one stable root.
#
#   kit_state_dir              echo the absolute .cckit directory (does not create it)
#   kit_state_file <name>      echo the absolute path of a file inside it
#   kit_state_ensure           create the directory; rc 1 if it cannot be created
#
# errors: best-effort — outside a git repo it falls back to $PWD/.cckit rather than failing, since
# session state is never worth aborting a command over.

# _kit_state_root — the primary checkout's root, the same from any worktree. Falls back to $PWD
# outside a git repo.
_kit_state_root() {
  local common
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || { printf '%s' "$PWD"; return 0; }
  [ -n "$common" ] || { printf '%s' "$PWD"; return 0; }
  # --git-common-dir returns ".git" (relative) at the primary checkout and an absolute path from a
  # worktree, so normalize before resolving the parent.
  case "$common" in /*) ;; *) common="$PWD/$common" ;; esac
  ( cd "$common/.." 2>/dev/null && pwd ) 2>/dev/null || printf '%s' "$PWD"
}

# kit_state_dir — absolute path of the state dir, shared across every worktree of one repo.
kit_state_dir() {
  if [ -n "${KIT_STATE_DIR:-}" ]; then
    # A RELATIVE override would resolve per-CWD and so reintroduce exactly the split this module
    # exists to remove — one state dir per worktree. Anchor it to the shared root instead, so
    # `KIT_STATE_DIR=.cckit-alt` means one directory, not one per place you happen to stand.
    case "$KIT_STATE_DIR" in
      /*) printf '%s' "$KIT_STATE_DIR" ;;
      *)  printf '%s/%s' "$(_kit_state_root)" "$KIT_STATE_DIR" ;;
    esac
    return 0
  fi
  printf '%s/.cckit' "$(_kit_state_root)"
}

# kit_state_file <name> — absolute path of one file in the state dir.
kit_state_file() {
  [ -n "${1:-}" ] || { echo "kit_state_file: <name> required" >&2; return 2; }
  printf '%s/%s' "$(kit_state_dir)" "$1"
}

# kit_state_ensure — create the state dir. rc 1 when it cannot be created, so a caller that must
# write can say so rather than emitting a raw shell redirection error.
kit_state_ensure() {
  local d; d="$(kit_state_dir)"
  [ -d "$d" ] && return 0
  mkdir -p "$d" 2>/dev/null || return 1
}
