#!/usr/bin/env bash
# shellcheck shell=bash
# loose-issues.sh — count the open issues that belong to no unit of work (E546.2). A loose issue is
# an open issue (not a pull request) that is not an effort (`effort` label), not a sub-issue (the
# REST field `parent_issue_url` is set), carries no relation line (`Depends on #N`, `Blocks #N`,
# `Extends #N`, `Parallel-safe with #N`, `Sub-issue of #N`, `Blocked by: #N`; the forms
# `naming_body_has_relation` accepts), and is not on the board with Status = Backlog. The Backlog
# marker is the board's Status column; with the board off (`github.projectsV2: false`) no issue can
# carry it, so every standalone issue with no relation line counts.
#
#   loose_board_on [cfg]            rc 0 iff the config turns the board on (projectsV2 true + a number)
#   loose_repo [cfg]                owner/name: .github.repo, else the origin remote; rc 1 when neither
#   loose_issues_list <repo> [cfg]  `N<TAB>title` per loose issue, ascending; rc 1 when the read failed
#   loose_baseline_read <file>      the first number in the baseline file (lines starting # are notes)
#
# Every GitHub read goes through the forge (forge_rest). Reads only; nothing is moved or relabelled.
# bash 3.2 + zsh compatible. Requires jq.
# errors: strict — a failed forge read is rc 1 and is never reported as zero loose issues
_loose_self="${BASH_SOURCE[0]:-$0}"
LOOSE_LIB="$(cd "$(dirname "$_loose_self")" && pwd)"
unset _loose_self
command -v forge_rest >/dev/null 2>&1 || . "$LOOSE_LIB/../forge/forge.sh"
command -v kit_config_path >/dev/null 2>&1 || . "$LOOSE_LIB/config-path.sh"

_loose_cfg() { [ -n "${1:-}" ] && { printf '%s' "$1"; return 0; }; kit_config_path 2>/dev/null; }

loose_board_on() {
  local cfg; cfg="$(_loose_cfg "${1:-}")" || return 1
  [ -f "$cfg" ] || return 1
  [ "$(jq -r '(.github.projectsV2 // false) and (.github.projectNumber != null)' "$cfg" 2>/dev/null)" = true ]
}

loose_repo() {
  local cfg r=""
  cfg="$(_loose_cfg "${1:-}")" || cfg=""
  [ -n "$cfg" ] && [ -f "$cfg" ] && r="$(jq -r '.github.repo // empty' "$cfg" 2>/dev/null)"
  [ -n "$r" ] || r="$(forge_repo_from_git "$(dirname "${cfg:-.}")" 2>/dev/null)" || r=""
  [ -n "$r" ] || return 1
  printf '%s' "$r"
}

loose_issues_list() {
  local repo="$1" cfg="${2:-}" raw n title st pnum=""
  raw="$(forge_rest "repos/$repo/issues?state=open&per_page=100" --paginate \
    --jq '.[] | select(.pull_request == null)
              | select(([.labels[]?.name] | index("effort")) | not)
              | select((.parent_issue_url // "") == "")
              | select((.body // "" | gsub("[*]"; "") | test("(?im)^[ \\t]*([-+][ \\t]+)?(depends on|blocks|extends|parallel-safe with|sub-issue of|blocked by:?)[ \\t]+(.*[^0-9])?#[0-9]+")) | not)
              | "\(.number)\t\(.title)"')" || return 1
  [ -n "$raw" ] || return 0
  if loose_board_on "$cfg"; then
    # The board holds the Backlog marker: one cheap issue.projectItems read per standalone issue.
    command -v project_issue_status >/dev/null 2>&1 || . "$LOOSE_LIB/../forge/gh-project.sh"
    pnum="$(jq -r '.github.projectNumber' "$(_loose_cfg "$cfg")")"
    printf '%s\n' "$raw" | while IFS="$(printf '\t')" read -r n title; do
      [ -n "$n" ] || continue
      st="$(KIT_REPO="$repo" project_issue_status "$n" "$pnum" 2>/dev/null)" || st=""
      [ "$st" = "Backlog" ] || printf '%s\t%s\n' "$n" "$title"
    done | sort -n
  else
    printf '%s\n' "$raw" | sort -n
  fi
}

loose_baseline_read() {
  [ -f "$1" ] || return 1
  grep -v '^#' "$1" | grep -E '^[0-9]+$' | sed -n 1p
}
