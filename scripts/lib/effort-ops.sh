#!/usr/bin/env bash
# shellcheck shell=bash
# effort-ops.sh — the effort lifecycle as shell ops, so `cckit effort new|start|pr|close` works from
# any shell or agent (not only via the effort-* skills). Thin: composes the git-mechanics helpers in
# effort.sh (linking, snapshots, title lint) plus gh + git. bash 3.2 compatible. Requires: gh, jq, git.
#
#   effort_new "<name>" [--slug <s>] [<sub title> …]   parent issue (template) + native sub-issues
#   effort_start <slug|N> [<slug>]        effort/<N> branch + worktree from the base branch
#   effort_pr [<slug|N>]                  open the ONE PR effort/<N> → base branch
#   effort_close <slug|N>                 snapshot sub-diffs, squash-merge the PR, close parent + subs
#
# Commands accept the human slug as well as the canonical number (#93): a pure-digits arg is a number,
# anything else is resolved via effort_slug_resolve. Repo + base branch come from kit.config.json
# (EFFORT_REPO / KIT_BASE_BRANCH), loaded by effort.sh.

# Slug layer (#93): _eff_slug, _eff_title_slug, effort_display, effort_slug_resolve. One home in
# effort-slug.sh; source it here so the lifecycle ops accept `<slug|N>` and render `slug #N`.
if ! command -v effort_slug_resolve >/dev/null 2>&1; then
  _eo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$_eo_dir/effort-slug.sh" ] && . "$_eo_dir/effort-slug.sh"
  unset _eo_dir
fi

_eff_repo()  { printf '%s' "${EFFORT_REPO:-${KIT_REPO:-}}"; }
_eff_base()  { printf '%s' "${KIT_BASE_BRANCH:-main}"; }
_eff_need()  { command -v "$1" >/dev/null 2>&1 || { echo "effort: $1 is required" >&2; return 1; }; }

# The parent-issue body template (rules/effort-model.md): the four sections double as the work record.
_eff_parent_body() {
  cat <<'EOF'
## Goal
<!-- problem statement: what outcome, in one or two lines -->

## Scope
<!-- the sub-issue plan; mark each parallel | sequential / dependsOn -->

## For agents
<!-- exact file paths / entry points a future agent needs -->

## Verification
<!-- how we know it's done: commands, checks, acceptance -->
EOF
}

# effort_new "<name>" [<sub title> …] — create the parent (template) + native sub-issues, linked.
effort_new() {
  _eff_need gh || return 1; _eff_need jq || return 1
  local repo name; repo="$(_eff_repo)"; name="${1:-}"; shift || true
  [ -n "$repo" ] || { echo "effort_new: no repo (KIT_REPO/EFFORT_REPO unset — run in a kit project)" >&2; return 1; }
  [ -n "$name" ] || { echo 'effort_new: usage: effort_new "<name>" [<sub title> …]' >&2; return 1; }
  # Validate the name against the title rule BEFORE creating anything (synthetic prefix for the lint).
  effort_title_lint "[Effort] 0 · $name" || { echo "effort_new: fix the name and retry" >&2; return 1; }

  local url num
  url="$(gh issue create --repo "$repo" --title "[Effort] · $name" --body "$(_eff_parent_body)")" \
    || { echo "effort_new: failed to create the parent issue" >&2; return 1; }
  num="${url##*/}"
  gh issue edit "$num" --repo "$repo" --title "[Effort] $num · $name" >/dev/null 2>&1
  echo "  ✓ effort #$num · $name" >&2

  local i=0 sub child
  for sub in "$@"; do
    i=$((i + 1))
    child="$(gh issue create --repo "$repo" --title "[Effort $num] $i · $sub" --body "Parent #$num." )" || continue
    effort_link_sub "$num" "${child##*/}" || true
  done
  printf '%s\n' "$num"
}

# effort_start <N> [<slug>] — create the effort/<N> integration branch + its worktree from the base.
effort_start() {
  _eff_need git || return 1
  local num="${1:-}" slug_override="${2:-}" repo base root title slug branch wt
  [ -n "$num" ] || { echo "effort_start: <effort issue #> required" >&2; return 1; }
  repo="$(_eff_repo)"; base="$(_eff_base)"
  root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
  [ -n "$root" ] || { echo "effort_start: not in a git repo" >&2; return 1; }

  if [ -n "$slug_override" ]; then slug="$slug_override"
  else
    title="$(gh issue view "$num" --repo "$repo" --json title -q .title 2>/dev/null)"
    slug="$(_eff_slug "${title:-effort}")"; [ -n "$slug" ] || slug="effort"
  fi
  branch="effort/$num-$slug"; wt="$root/.claude/worktrees/effort-$num"

  git -C "$root" fetch origin "$base" --quiet 2>/dev/null || true
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "effort_start: branch $branch already exists" >&2
  else
    local from="origin/$base"; git -C "$root" rev-parse --verify --quiet "$from" >/dev/null 2>&1 || from="$base"
    git -C "$root" worktree add -b "$branch" "$wt" "$from" >/dev/null 2>&1 \
      || { echo "effort_start: failed to create worktree for $branch" >&2; return 1; }
  fi
  echo "  ✓ effort #$num → $branch  (worktree: $wt)" >&2
  printf '%s|%s|%s\n' "$wt" "$branch" "$num"
}

# effort_pr [<N>] — open the single PR effort/<N> → base. N defaults to the current effort branch.
effort_pr() {
  _eff_need gh || return 1
  local num="${1:-}" repo base branch title name
  repo="$(_eff_repo)"; base="$(_eff_base)"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$num" ] || num="$(effort_branch_num "$branch")"
  [ -n "$num" ] || { echo "effort_pr: not on an effort/<N>-… branch and no <N> given" >&2; return 1; }
  case "$branch" in effort/"$num"-*) : ;; *) echo "effort_pr: current branch ($branch) is not effort/$num-…" >&2; return 1 ;; esac

  git push -u origin "$branch" >/dev/null 2>&1 || true
  title="$(gh issue view "$num" --repo "$repo" --json title -q .title 2>/dev/null)"
  name="$(printf '%s' "$title" | sed -E 's/^\[Effort\] [0-9]+ · ?//')"
  gh pr create --repo "$repo" --base "$base" --head "$branch" \
    --title "[Effort] $num · ${name:-effort}" \
    --body "$(printf 'Closes the #%s effort.\n\n## For agents\nSee #%s for the goal, scope, and entry points.\n' "$num" "$num")"
}

# effort_close <N> — snapshot per-sub diffs (before squash), squash-merge the PR, close parent + subs.
# Destructive: it merges and closes. Snapshots first so the per-sub work record survives the squash.
effort_close() {
  _eff_need gh || return 1; _eff_need jq || return 1
  local num="${1:-}" repo base branch
  [ -n "$num" ] || { echo "effort_close: <effort issue #> required" >&2; return 1; }
  repo="$(_eff_repo)"; base="$(_eff_base)"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$branch" in effort/"$num"-*) : ;; *) echo "effort_close: run from the effort/$num-… branch" >&2; return 1 ;; esac

  # (a) snapshot the per-sub-issue diffs while the unsquashed history still exists.
  effort_snapshot_subs "$num" "origin/$base" || true
  # (b) squash-merge the effort PR.
  gh pr merge "$branch" --repo "$repo" --squash --delete-branch >/dev/null 2>&1 \
    || { echo "effort_close: could not squash-merge the PR for $branch (open? mergeable?)" >&2; return 1; }
  echo "  ✓ merged $branch" >&2
  # (c) close every native sub-issue, then the parent.
  local sub
  for sub in $(gh api "repos/$repo/issues/$num/sub_issues" --jq '.[].number' 2>/dev/null); do
    gh issue close "$sub" --repo "$repo" --reason completed >/dev/null 2>&1 && echo "  ✓ closed sub #$sub" >&2
  done
  gh issue close "$num" --repo "$repo" --reason completed >/dev/null 2>&1 && echo "  ✓ closed effort #$num" >&2
}
