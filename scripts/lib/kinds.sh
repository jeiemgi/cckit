#!/usr/bin/env bash
# kinds.sh — the ONE closed vocabulary for the `kind:` label and the branch prefix it becomes.
#
# `cckit start` turns an issue's `kind:<k>` label into the branch `<k>/<N>-<slug>`, so a kind value
# is only usable if it is also a legal branch prefix. The set below is the closed set of
# rules/branch-naming.md and of the SessionStart hygiene hook (templates/hooks/repo-hygiene.sh.tmpl),
# which warns on any other prefix. scripts/lib/kinds-test.sh pins the three lists together.
#
#   KIT_KINDS                 space-separated closed set
#   kit_kind_valid  <kind>    rc 0 when <kind> is in the set
#   kit_kind_branch <kind>    echo the branch prefix for <kind>: itself when valid; otherwise `task`,
#                             with a warning on stderr naming the value that was replaced
#
# Sourced by bash AND zsh (no arrays, no glob held in a variable). Requires: nothing.
# errors: best-effort — an unknown kind degrades to `task` and says so; it never aborts a start

KIT_KINDS="${KIT_KINDS:-feat fix task chore security scaffold ci adr spike plan}"

kit_kind_valid() {
  [ -n "${1:-}" ] || return 1
  case " $KIT_KINDS " in *" $1 "*) return 0 ;; esac
  return 1
}

kit_kind_branch() {
  if kit_kind_valid "${1:-}"; then printf '%s\n' "$1"; return 0; fi
  echo "⚠ kind '${1:-}' is not one of: $KIT_KINDS — using 'task' as the branch prefix" >&2
  printf 'task\n'
}
