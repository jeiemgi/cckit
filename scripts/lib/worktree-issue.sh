#!/usr/bin/env bash
# worktree-issue.sh — associate a branch / worktree with the GitHub issue it belongs to,
# and report whether that issue is still open. The association is DERIVED from the name —
# there is no hand-maintained registry.
#
# Conventions (see .claude/rules/branch-naming.md):
#   branch        <kind>/<N>-<slug>     e.g. feat/173-admin-clerk-signin
#   worktree dir  <kind>+<N>-<slug>     e.g. .claude/worktrees/feat+173-admin-clerk-signin
#   light task    light/<id>-<slug>     e.g. light/t3f9a-spring-newsletter (no issue; wt_task_id)
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

# This file's own directory, resolved at load time (file scope is the one place bash and zsh agree
# on it). wt_task_state loads task-source.sh from here on first use.
_WT_ISSUE_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

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

# Echo the issue state for an issue number, lowercased. Three answers, and they are not the same
# thing (#330):
#   open / closed   GitHub answered.
#   (empty)         there is nothing to ask about: no number, or GitHub says no such issue (404).
#   unknown         the read FAILED — no gh, no repo to ask in rest mode, or gh exited non-zero
#                   (rate limit, outage, auth). The issue may well be open.
# A failed read used to be echoed as empty, which made an outage indistinguishable from "no issue"
# and let gc treat an open issue's branch as unprotected. Callers must treat `unknown` as "do not
# assume safe to delete". rc 0 always, so a bare `state="$(wt_issue_state …)"` survives `set -e`.
wt_issue_state() {
  local n="$1" repo="${2:-}" out
  [[ -z "$n" ]] && return 0
  command -v gh >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  if cckit_gh_rest; then
    repo="${repo:-${KIT_REPO:-}}"; [[ -n "$repo" ]] || { printf 'unknown\n'; return 0; }
    out="$(gh api "repos/$repo/issues/$n" --jq .state 2>&1)" || { _wt_issue_state_failed "$out"; return 0; }
  else
    local args=(issue view "$n" --json state --jq .state)
    [[ -n "$repo" ]] && args+=(--repo "$repo")
    out="$(gh "${args[@]}" 2>&1)" || { _wt_issue_state_failed "$out"; return 0; }
  fi
  printf '%s\n' "$out" | tr '[:upper:]' '[:lower:]' | grep -E -x 'open|closed' | sed -n 1p
  return 0
}

# _wt_issue_state_failed <gh output> — what a FAILED state read means. gh's own "no such issue"
# answer (REST 404, GraphQL "Could not resolve to an Issue") is a definite absence and stays empty;
# every other failure is `unknown`.
_wt_issue_state_failed() {
  if grep -qiE 'HTTP 404|Could not resolve to an? (Issue|PullRequest)' <<<"$1"; then return 0; fi
  printf 'unknown\n'
}

# ── light tasks (#450): work tracked without a GitHub issue ───────────────────────────────────
# A light task's branch is `light/<id>-<slug>` and its worktree dir `light+<id>-<slug>`. <id> starts
# with a lowercase letter (then lowercase letters / digits, 2-12 characters in all), so
# wt_issue_number answers nothing for it and no GitHub issue is ever asked about. Without the two
# functions below such a branch would carry no id at all, and a branch with no id gets no
# protection: gc would call a task in progress LANDED the moment it has no commit beyond base.

# Echo the light-task id a branch name / worktree path belongs to (empty if it is not one).
wt_task_id() {
  local ref="$1" rest id
  case "$ref" in
    light/*) rest="${ref#light/}" ;;
    *) rest="${ref##*/}"
       case "$rest" in light+*) rest="${rest#light+}" ;; *) return 0 ;; esac ;;
  esac
  id="${rest%%-*}"
  [ "$id" != "$rest" ] || return 0                 # no "-" after the id
  case "$id" in ''|[!a-z]*|*[!a-z0-9]*) return 0 ;; esac
  [ "${#id}" -ge 2 ] && [ "${#id}" -le 12 ] || return 0
  printf '%s' "$id"
}

# Echo the state of a light task as the task source reports it (task-source.sh): open / closed,
# empty when there is no such task, `unknown` when the source could not be loaded or read. Same
# contract as wt_issue_state: callers treat `unknown` as "do not assume safe to delete". rc 0 always.
wt_task_state() {
  local id="$1" ref="${2:-}" out
  [ -n "$id" ] || return 0
  if ! command -v task_source_call >/dev/null 2>&1 \
     && [ -n "${_WT_ISSUE_LIB_DIR:-}" ] && [ -f "$_WT_ISSUE_LIB_DIR/task-source.sh" ]; then
    # shellcheck source=/dev/null
    . "$_WT_ISSUE_LIB_DIR/task-source.sh"
  fi
  command -v task_source_call >/dev/null 2>&1 || { printf 'unknown\n'; return 0; }
  out="$(task_source_call state "$id" "$ref" 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  printf '%s\n' "$out" | grep -E -x 'open|closed|unknown' | sed -n 1p
  return 0
}

# Echo a protection reason if a branch/ref must NOT be garbage-collected because its issue — or its
# light task — is still open; empty string means "no such protection" (other gc rules still apply).
wt_protected_reason() {
  local ref="$1" repo="${2:-}" n state
  n="$(wt_task_id "$ref")"
  if [ -n "$n" ]; then
    state="$(wt_task_state "$n" "$ref")"
    case "$state" in
      open)    printf 'light task %s still OPEN' "$n" ;;
      unknown) printf 'light task %s state unknown' "$n" ;;
    esac
    return 0
  fi
  n="$(wt_issue_number "$ref")"
  [[ -z "$n" ]] && return 0
  state="$(wt_issue_state "$n" "$repo")"
  if [[ "$state" == "open" ]]; then
    printf 'issue #%s still OPEN' "$n"
  fi
}
