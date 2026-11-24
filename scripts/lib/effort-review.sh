#!/usr/bin/env bash
# shellcheck shell=bash
# effort-review.sh — `cckit effort review <N>` (E547, #583): check each sub of an effort against its
# own `## Spec`, one verdict line per sub. A read: it writes nothing on the forge or in git.
#
#   effort_review <N> [--branch B]
#
# Per sub it reads the forge state and the body, runs spec_lint on the body, and looks on the
# effort branch (`effort/<N>-*`, local or origin, or --branch) for a commit that names the sub
# (`#<sub>`). Verdicts, first match wins:
#   no spec                   the sub's body has no checkable `## Spec` — nothing to review against
#   done                      closed, and on the branch (or no branch found to check)
#   closed, not on the branch closed on the forge, but no commit on the effort branch names it
#   landed, still open        a commit names it, the issue is still open
#   open                      neither
# Output: a TSV table (sub, state, spec, landed, verdict, title), then `review #N: D of M done`.
# rc 0 when every sub is done · 1 when one is not, or the forge read failed · 2 usage.
# bash 3.2 compatible.
# errors: strict — a check: rc 1 on any sub that is not done

if ! command -v spec_lint >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/spec-lint.sh"
fi
if ! command -v forge_rest >/dev/null 2>&1 && ! command -v gh_rest_issue_json >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/gh-rest.sh"
fi

# _er_branch <N> — the effort branch: a local `effort/<N>-*`, else origin's. Empty when neither.
_er_branch() {
  git for-each-ref --format='%(refname:short)' "refs/heads/effort/$1-*" "refs/remotes/origin/effort/$1-*" 2>/dev/null | head -1
}

# effort_review_verdict <state> <spec ok|none> <landed yes|no|-> — the verdict for one sub. Pure.
effort_review_verdict() {
  local state="$1" spec="$2" landed="$3"
  if [ "$spec" != ok ]; then echo "no spec"; return; fi
  case "$state:$landed" in
    closed:yes|closed:-) echo "done" ;;
    closed:no)           echo "closed, not on the branch" ;;
    open:yes)            echo "landed, still open" ;;
    *)                   echo "open" ;;
  esac
}

effort_review() {
  local num="" branch="" repo subs n i sub state title body spec landed verdict log done_n=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --branch)   [ $# -ge 2 ] || { echo "effort review: --branch needs a name" >&2; return 2; }; branch="$2"; shift 2 ;;
      --branch=*) branch="${1#--branch=}"; shift ;;
      -*) echo "effort review: unknown flag '$1'" >&2; return 2 ;;
      *)  [ -z "$num" ] || { echo "effort review: one effort at a time" >&2; return 2; }; num="${1#\#}"; shift ;;
    esac
  done
  case "$num" in ''|*[!0-9]*) echo "usage: cckit effort review <N> [--branch B]" >&2; return 2 ;; esac
  forge_need "effort review" || return 1
  command -v jq >/dev/null 2>&1 || { echo "effort review: jq is required" >&2; return 1; }
  repo="${EFFORT_REPO:-${KIT_REPO:-}}"
  [ -n "$repo" ] || repo="$(forge_repo_from_git 2>/dev/null)" || { echo "effort review: no repository (github.repo unset)" >&2; return 1; }

  subs="$(forge_rest "repos/$repo/issues/$num/sub_issues" -X GET -f per_page=100 \
    --jq '[.[] | {number, state, title, body: (.body // "")}] | tojson' 2>&1)" || {
    printf 'effort review: could not read the subs of #%s\n%s\n' "$num" "$subs" >&2; return 1; }
  n="$(printf '%s' "$subs" | jq 'length')"
  [ "${n:-0}" -gt 0 ] || { echo "effort review: #$num has no sub-issues" >&2; return 1; }

  [ -n "$branch" ] || branch="$(_er_branch "$num")"
  log=""
  if [ -n "$branch" ]; then
    log="$(git log --format=%B "$branch" 2>/dev/null)" || { echo "effort review: cannot read branch '$branch'" >&2; return 1; }
  fi

  printf 'sub\tstate\tspec\tlanded\tverdict\ttitle\n'
  i=0
  while [ "$i" -lt "$n" ]; do
    sub="$(printf '%s' "$subs" | jq -r ".[$i].number")"
    state="$(printf '%s' "$subs" | jq -r ".[$i].state")"
    title="$(printf '%s' "$subs" | jq -r ".[$i].title")"
    body="$(printf '%s' "$subs" | jq -r ".[$i].body")"
    if spec_lint "$body" 2>/dev/null; then spec=ok; else spec=none; fi
    if [ -z "$branch" ]; then landed="-"
    elif printf '%s\n' "$log" | grep -qE "(^|[^0-9A-Za-z])#$sub([^0-9]|$)"; then landed=yes
    else landed=no; fi
    verdict="$(effort_review_verdict "$state" "$spec" "$landed")"
    [ "$verdict" = done ] && done_n=$((done_n + 1))
    printf '#%s\t%s\t%s\t%s\t%s\t%s\n' "$sub" "$state" "$spec" "$landed" "$verdict" "$title"
    i=$((i + 1))
  done
  printf 'review #%s: %s of %s done%s\n' "$num" "$done_n" "$n" "${branch:+ (branch $branch)}"
  [ "$done_n" -eq "$n" ]
}
