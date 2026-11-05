#!/usr/bin/env bash
# worktree-issue.sh — associate a branch / worktree with the GitHub issue it belongs to,
# and report whether that issue is still open. The association is DERIVED from the name —
# there is no hand-maintained registry.
#
# Conventions (see .claude/rules/branch-naming.md):
#   branch        <kind>/<N>-<slug>     e.g. feat/173-admin-clerk-signin
#   worktree dir  <kind>+<N>-<slug>     e.g. .claude/worktrees/feat+173-admin-clerk-signin
#
# Source it:  source scripts/lib/worktree-issue.sh
# Requires: git; gh (for state lookups — degrades to "unknown" without it).
# Portable: POSIX parameter expansion only — sourceable from bash 3.2+ AND zsh (#307;
# BASH_REMATCH stays silently empty in zsh, which switched the gc protection off).
# Self-test: bash scripts/lib/worktree-issue-test.sh  (runs the cases under bash + zsh)
# errors: mixed — name parsing is pure; the issue-open check needs gh

# The GitHub transport switch (#396): rest mode routes the gh calls below through gh-rest.sh.
if ! command -v cckit_gh_rest >/dev/null 2>&1; then
  _ghr_lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/gh-rest.sh"
  # shellcheck source=/dev/null
  [ -f "$_ghr_lib" ] && . "$_ghr_lib"
  unset _ghr_lib
fi
command -v cckit_gh_rest >/dev/null 2>&1 || cckit_gh_rest() { return 1; }

# Echo the issue number a branch name / worktree path belongs to (empty if none, e.g. bot branches).
# Normalize the numeric segment of a branch/dir name to an issue number.
# Accepts "1602" and also the effort SUB form "1604a" — `sub/<N><letter>-<slug>` is the documented
# sub-branch convention, and rejecting it meant every effort sub-branch parsed to "" and so got NO
# issue-open protection at all (gc listed live subs of an open effort as SAFE to delete).
# Exactly one trailing lowercase letter is stripped; anything else is not an issue number.
_wt_normalize_issue_num() {
  local n="$1" head tail
  case "$n" in
    '')       return 0 ;;
    *[!0-9]*) : ;;                                # has a non-digit — only the sub form survives
    *)        printf '%s' "$n"; return 0 ;;       # pure digits
  esac
  head="${n%?}"; tail="${n#"$head"}"
  case "$tail" in [a-z]) : ;; *) return 0 ;; esac # last char must be one lowercase letter
  case "$head" in ''|*[!0-9]*) return 0 ;; esac   # everything before it must be pure digits
  printf '%s' "$head"
}

wt_issue_number() {
  local ref="$1" base kind rest n
  # branch form: kind/N-slug  (kind = lowercase letters only, anchored at start)
  kind="${ref%%/*}"; rest="${ref#*/}"
  if [ "$kind" != "$ref" ]; then                     # ref contains "/"
    case "$kind" in
      ''|*[!a-z]*) : ;;                              # not a pure-lowercase kind
      *)
        n="${rest%%-*}"
        if [ "$n" != "$rest" ]; then                 # a "-" follows the number
          n="$(_wt_normalize_issue_num "$n")"
          [ -n "$n" ] && { printf '%s' "$n"; return 0; }
        fi
        ;;
    esac
  fi
  # worktree-dir form: .../kind+N-slug
  base="${ref##*/}"
  kind="${base%%+*}"; rest="${base#*+}"
  if [ "$kind" != "$base" ]; then                    # basename contains "+"
    case "$kind" in
      ''|*[!a-z]*) return 0 ;;
    esac
    n="${rest%%-*}"
    [ "$n" = "$rest" ] && return 0                   # no "-" after the number
    n="$(_wt_normalize_issue_num "$n")"
    [ -n "$n" ] && printf '%s' "$n"
  fi
  return 0
}

# Echo the issue state ("open" / "closed") for an issue number, lowercased. Empty when unknown
# (no number, no gh, or lookup failed) — callers must treat empty as "don't assume safe to delete".
wt_issue_state() {
  local n="$1" repo="${2:-}"
  [[ -z "$n" ]] && return 0
  command -v gh >/dev/null 2>&1 || return 0
  if cckit_gh_rest; then
    repo="${repo:-${KIT_REPO:-}}"; [[ -n "$repo" ]] || return 0
    gh api "repos/$repo/issues/$n" --jq .state 2>/dev/null | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  local args=(issue view "$n" --json state --jq .state)
  [[ -n "$repo" ]] && args+=(--repo "$repo")
  gh "${args[@]}" 2>/dev/null | tr '[:upper:]' '[:lower:]'
}

# Echo a protection reason if a branch/ref must NOT be garbage-collected because its issue
# is still open; empty string means "no issue-based protection" (other gc rules still apply).
wt_protected_reason() {
  local ref="$1" repo="${2:-}" n state
  n="$(wt_issue_number "$ref")"
  [[ -z "$n" ]] && return 0
  state="$(wt_issue_state "$n" "$repo")"
  if [[ "$state" == "open" ]]; then
    printf 'issue #%s still OPEN' "$n"
  fi
}
