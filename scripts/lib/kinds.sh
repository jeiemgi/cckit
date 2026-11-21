#!/usr/bin/env bash
# kinds.sh — the ONE closed vocabulary for the `kind:` label and the branch prefix it becomes.
#
# `cckit start` turns an issue's `kind:<k>` label into the branch `<k>/<N>-<slug>`, so a kind value
# is only usable if it is also a legal branch prefix. The set below is the closed set of
# rules/branch-naming.md and of the SessionStart hygiene hook (templates/hooks/repo-hygiene.sh.tmpl),
# which warns on any other prefix. scripts/lib/kinds-test.sh pins the three lists together.
#
#   KIT_KINDS                 space-separated closed set of BRANCH kinds
#   KIT_CONTENT_KINDS         space-separated content kinds: `kind:` label values for content work
#                             (#417). A content kind is NEVER a branch prefix: it maps onto one of
#                             KIT_KINDS, so the branch set that gc and the hygiene hook parse does
#                             not grow.
#   kit_kind_valid  <kind>    rc 0 when <kind> is in KIT_KINDS (a legal branch prefix)
#   kit_kind_content <kind>   rc 0 when <kind> is in KIT_CONTENT_KINDS
#   kit_kind_label_valid <kind>   rc 0 when <kind> is in either set — what `--kind` accepts
#   kit_kind_branch <kind>    echo the branch prefix for <kind>: itself when in KIT_KINDS; the mapped
#                             prefix for a content kind (post -> task, campaign -> plan,
#                             brand -> task, research -> spike), silently; otherwise `task`, with a
#                             warning on stderr naming the value that was replaced
#   kit_kind_commit_type <kind>   echo the Conventional Commit type a PR title takes from <kind>:
#                             feat chore docs ci test perf refactor fix -> itself; bug -> fix;
#                             a content kind -> docs; anything else (kind:task included) -> feat
#
# Sourced by bash AND zsh (no arrays, no glob held in a variable). Requires: nothing.
# errors: best-effort — an unknown kind degrades to `task` and says so; it never aborts a start

KIT_KINDS="${KIT_KINDS:-feat fix task chore security scaffold ci adr spike plan}"
KIT_CONTENT_KINDS="${KIT_CONTENT_KINDS:-post campaign brand research}"

kit_kind_valid() {
  [ -n "${1:-}" ] || return 1
  case " $KIT_KINDS " in *" $1 "*) return 0 ;; esac
  return 1
}

kit_kind_content() {
  [ -n "${1:-}" ] || return 1
  case " $KIT_CONTENT_KINDS " in *" $1 "*) return 0 ;; esac
  return 1
}

kit_kind_label_valid() { kit_kind_valid "${1:-}" || kit_kind_content "${1:-}"; }

kit_kind_branch() {
  if kit_kind_valid "${1:-}"; then printf '%s\n' "$1"; return 0; fi
  if kit_kind_content "${1:-}"; then
    case "$1" in
      campaign) printf 'plan\n' ;;
      research) printf 'spike\n' ;;
      *)        printf 'task\n' ;;   # post, brand, and a content kind a project adds
    esac
    return 0
  fi
  echo "⚠ kind '${1:-}' is not one of: $KIT_KINDS $KIT_CONTENT_KINDS — using 'task' as the branch prefix" >&2
  printf 'task\n'
}

kit_kind_commit_type() {
  if kit_kind_content "${1:-}"; then printf 'docs\n'; return 0; fi
  case "${1:-}" in
    feat|chore|docs|ci|test|perf|refactor|fix) printf '%s\n' "$1" ;;
    bug) printf 'fix\n' ;;
    *)   printf 'feat\n' ;;
  esac
}
