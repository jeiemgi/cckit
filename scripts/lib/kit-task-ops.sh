#!/usr/bin/env bash
# kit-task-ops.sh — the ONE canonical home for the kit-task pr|pr-merge|new|close
# git/GitHub mechanics (Family 1 of kit-engine-boundary.md, rule #1/#2).
#
# The four .claude/skills/kit-task-{pr,pr-merge,new,close} skills, the `scripts/kit task <op>`
# dispatcher, and any future surface CALL these functions — they never re-implement the logic.
# Each function is parameterized (no AskUserQuestion / no interactive prompts here — the caller
# collects inputs), and sources the existing helpers (role-identity, gh-project ids).
#
# Source it:  source scripts/lib/kit-task-ops.sh
# Requires: git, gh, jq. bash 3.2 compatible; sourceable under zsh too (no bash-only indirection).
# Self-test: bash scripts/lib/kit-task-ops-test.sh  (pure helpers only — no network)
#
# Functions:
#   kto_repo                                          echo the repo slug (owner/name)
#   kto_branch_issue_number [branch]                  echo issue # parsed from a <kind>/<N>-<slug> branch
#   kto_labels_role <labels-csv>                      echo the role slug from a labels CSV (role:<slug>)
#   kto_labels_kind <labels-csv>                      echo the kind slug from a labels CSV (kind:<slug>)
#   kto_compose_pr_body <num> <summary> <role-slug>   echo a PR body from the template
#   kto_compose_issue_body <user-body> <plan> <blocked> <role-slug>   echo an issue body
#   kto_closing_issue_numbers <pr-num>                echo the issue #s a merged PR closes
#   kto_task_pr   <num> <summary> [commit-msg]        commit+push+open PR (board → In Review)
#   kto_task_pr_merge [pr-num]                         squash-merge + close issues + switch develop + GC
#   kto_task_new  <title> <role> <kind> <prio> <ms> [plan] [blocked] <body>   create issue + board fields
#   kto_task_close <num> <summary> [pr-num]            close issue + board → Done

# --- repo resolution -----------------------------------------------------------------------------
# Resolve the repo slug from KIT_REPO (kit-config) when available, else the kit's home repo. A
# caller may export KIT_TASK_REPO to override.
if [[ -z "${KIT_REPO:-}" ]]; then
  _kto_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$_kto_root" && -f "$_kto_root/scripts/lib/kit-config.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_kto_root/scripts/lib/kit-config.sh" && load_kit_config >/dev/null 2>&1 || true
  fi
  unset _kto_root
fi

kto_repo() {
  printf '%s' "${KIT_TASK_REPO:-${KIT_REPO:-jeiemgi/cckit}}"
}

# The base branch a PR targets / pr-merge returns to (portable: KIT_BASE_BRANCH, default develop).
kto_base_branch() {
  printf '%s' "${KIT_BASE_BRANCH:-develop}"
}

# True (rc 0) iff board updates should run. Off when KIT_PROJECTS_V2 is explicitly "false" — keeps
# the op portable to a project with no Projects v2 board (the plugin's KIT_PROJECTS_V2 toggle).
kto_board_enabled() {
  [[ "${KIT_PROJECTS_V2:-true}" != "false" ]]
}

# --- pure parsers (network-free; covered by the self-test) ---------------------------------------

# Parse the issue number from a `<kind>/<N>-<slug>` branch (e.g. feat/173-x -> 173). Empty if none.
kto_branch_issue_number() {
  local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
  printf '%s' "$branch" | grep -oE '/[0-9]+-' | head -1 | tr -d '/-'
}

# Echo the role slug from a comma-separated labels list (role:<slug>). Empty if absent.
kto_labels_role() {
  printf '%s' "$1" | tr ',' '\n' | grep '^role:' | head -1 | cut -d: -f2
}

# Echo the kind slug from a comma-separated labels list (kind:<slug>). Empty if absent.
kto_labels_kind() {
  printf '%s' "$1" | tr ',' '\n' | grep '^kind:' | head -1 | cut -d: -f2
}

# Compose a PR body from the kit-task-pr template. Args: <num> <summary> <role-slug>
kto_compose_pr_body() {
  local num="$1" summary="$2" role="$3" sig=""
  if type role_signature >/dev/null 2>&1; then sig="$(role_signature "$role")"; fi
  cat <<EOF
## Closes

Closes #$num

## Summary

$summary

## Verification

- [ ] Reproduced manually
- [ ] No unrelated files in the diff
- [ ] Labels match the issue
- [ ] If plan deliverable: opened in browser, styles render

## Notes for review

—

## Out of scope

—

$sig

---
<sub>· \`claude-kit\` · kit-task-pr</sub>
EOF
}

# Compose an issue body. Args: <user-body> <plan-link> <blocked-by> <role-slug>
kto_compose_issue_body() {
  local body_user="$1" plan="$2" blocked="$3" role="$4" repo base out="" sig=""
  repo="$(kto_repo)"; base="$(kto_base_branch)"
  [[ -n "$plan" ]] && out+="**Plan:** [\`$plan\`](https://github.com/$repo/blob/$base/$plan)"$'\n\n'
  [[ -n "$blocked" ]] && out+="**Blocked by:** $blocked"$'\n\n'
  out+="$body_user"
  if type role_signature >/dev/null 2>&1; then sig="$(role_signature "$role")"; fi
  [[ -n "$sig" ]] && out+=$'\n\n---\n'"$sig"
  printf '%s' "$out"
}

# Echo the issue numbers a merged PR closes — GitHub's parse first, regex over the body as fallback.
# Args: <pr-num>
kto_closing_issue_numbers() {
  local pr="$1" repo issues body
  repo="$(kto_repo)"
  issues=$(gh pr view "$pr" --repo "$repo" --json closingIssuesReferences \
    --jq '.closingIssuesReferences[].number' 2>/dev/null)
  if [[ -z "$issues" ]]; then
    body=$(gh pr view "$pr" --repo "$repo" --json body --jq .body 2>/dev/null)
    issues=$(printf '%s\n' "$body" \
      | grep -ioE '(close[sd]?|fix(e[sd])?|resolve[sd]?) +#[0-9]+' \
      | grep -oE '[0-9]+' | sort -u)
  fi
  printf '%s' "$issues"
}

# --- the four ops (network; not exercised by the self-test) --------------------------------------

# Map a role slug to the board's Role single-select option id (uses gh-project's role_option_id,
# which takes a display name — translate slug -> display via role_display).
_kto_role_option_for_slug() {
  local slug="$1" disp=""
  if type role_display >/dev/null 2>&1; then disp="$(role_display "$slug")"; fi
  [[ -z "$disp" ]] && return 0
  if type role_option_id >/dev/null 2>&1; then role_option_id "$disp"; fi
}

# kit task pr — commit current changes (role identity in a Co-authored-by TRAILER, never the
# author field — Vercel rejects unknown author emails), push, open the PR with the issue's
# labels/milestone, add it to the board In Review, and move the issue to In Review.
# Args: <issue-num> <summary> [commit-msg]
kto_task_pr() {
  # Default-safe reads: callers (scripts/kit) may run under `set -u`.
  local num="${1:-}" summary="${2:-}" commit_msg="${3:-}"
  local repo branch meta title labels milestone role author url pr_num pr_node item role_opt issue_item
  repo="$(kto_repo)"
  branch="$(git rev-parse --abbrev-ref HEAD)"

  [[ -n "$num" ]] || num="$(kto_branch_issue_number "$branch")"
  [[ -n "$num" ]] || { echo "✗ kto_task_pr: branch '$branch' doesn't match <kind>/<N>-<slug> and no issue number passed" >&2; return 1; }
  [[ -n "$summary" ]] || { echo "✗ kto_task_pr: a Summary is required (never invent one)" >&2; return 1; }

  meta=$(gh issue view "$num" --repo "$repo" --json title,labels,milestone) || return 1
  title=$(printf '%s' "$meta" | jq -r .title)
  labels=$(printf '%s' "$meta" | jq -r '[.labels[].name] | join(",")')
  milestone=$(printf '%s' "$meta" | jq -r '.milestone.title // ""')
  role="$(kto_labels_role "$labels")"
  [[ -z "$commit_msg" ]] && commit_msg="${role:-task}: $title"

  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    if type role_git_author >/dev/null 2>&1; then author="$(role_git_author "$role")"; fi
    if [[ -n "$author" ]]; then
      git commit -m "$commit_msg" -m "Co-authored-by: ${author%%|*} <${author##*|}>"
    else
      git commit -m "$commit_msg"
    fi
  fi

  git push -u origin "$branch" || return 1

  url=$(gh pr create --repo "$repo" \
    --base "$(kto_base_branch)" --head "$branch" \
    --title "$title" \
    --body "$(kto_compose_pr_body "$num" "$summary" "$role")" \
    --label "$labels" \
    ${milestone:+--milestone "$milestone"} \
    --assignee "@me") || return 1
  echo "✓ $url"

  # Board: add the PR (In Review) + move the issue to In Review. Best-effort — never fail the op.
  if kto_board_enabled && type load_project_ids >/dev/null 2>&1 && load_project_ids 2>/dev/null; then
    pr_num="$(basename "$url")"
    pr_node=$(gh api "repos/$repo/pulls/$pr_num" --jq .node_id 2>/dev/null)
    if [[ -n "$pr_node" ]]; then
      item=$(project_add_item "$pr_node" 2>/dev/null || true)
      if [[ -n "$item" ]]; then
        role_opt="$(_kto_role_option_for_slug "$role")"
        [[ -n "$role_opt" ]] && project_set_single_select "$item" "$ROLE_FIELD_ID" "$role_opt" 2>/dev/null || true
        [[ -n "${STATUS_OPT_IN_REVIEW:-}" ]] && project_set_single_select "$item" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_REVIEW" 2>/dev/null || true
      fi
    fi
    issue_item=$(project_find_item_by_issue "$num" 2>/dev/null || true)
    [[ -n "$issue_item" && -n "${STATUS_OPT_IN_REVIEW:-}" ]] && \
      project_set_single_select "$issue_item" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_REVIEW" 2>/dev/null || true
  fi
}

# kit task pr-merge — squash-merge the open PR for the current branch (rebase-fix conflicts onto
# develop first), close its linked issues (GitHub native auto-close only fires on main), switch the
# main checkout to develop + pull, then clean up the merged branch + worktree.
# Args: [pr-num]   (defaults to the open PR for the current branch)
kto_task_pr_merge() {
  local input_pr="${1:-}"
  local repo branch base pr_num mergeable merge_state issues n state wt main_wt
  repo="$(kto_repo)"
  base="$(kto_base_branch)"
  branch="$(git rev-parse --abbrev-ref HEAD)"

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ Working tree is dirty — commit or stash changes first" >&2; return 1
  fi

  pr_num="$input_pr"
  if [[ -z "$pr_num" ]]; then
    pr_num=$(gh pr list --repo "$repo" --head "$branch" --state open --json number --jq '.[0].number // empty')
    [[ -z "$pr_num" ]] && { echo "✗ No open PR found for branch $branch" >&2; return 1; }
  fi
  echo "→ PR #$pr_num on branch $branch"

  mergeable=$(gh pr view "$pr_num" --repo "$repo" --json mergeable,mergeStateStatus \
    --jq '{mergeable:.mergeable, status:.mergeStateStatus}')
  merge_state=$(printf '%s' "$mergeable" | jq -r .mergeable)
  echo "  mergeable=$merge_state status=$(printf '%s' "$mergeable" | jq -r .status)"

  if [[ "$merge_state" == "CONFLICTING" ]]; then
    echo "→ Conflicts detected — rebasing onto $base..."
    git fetch origin "$base"
    if git rebase "origin/$base"; then
      git push --force-with-lease origin "$branch"
      echo "✓ Rebased and pushed — re-checking mergeability..."
    else
      echo "✗ Rebase had conflicts that need manual resolution — resolve, then run pr-merge again" >&2
      git rebase --abort 2>/dev/null || true
      return 1
    fi
  fi

  if ! gh pr merge "$pr_num" --repo "$repo" --squash 2>&1; then
    echo "✗ Merge failed — check PR status: https://github.com/$repo/pull/$pr_num" >&2
    return 1
  fi
  echo "✓ PR #$pr_num merged"

  # Close linked issues (replaces issue-close-on-merge.yml; native auto-close only fires on main).
  issues="$(kto_closing_issue_numbers "$pr_num")"
  for n in $issues; do
    state=$(gh issue view "$n" --repo "$repo" --json state --jq .state 2>/dev/null)
    if [[ "$state" == "OPEN" ]]; then
      gh issue close "$n" --repo "$repo" \
        --comment "Closed automatically on merge of #$pr_num to $base (kit task pr-merge; GitHub native auto-close only fires on the default branch)." \
        && echo "✓ Closed issue #$n"
    elif [[ -n "$state" ]]; then
      echo "  issue #$n already $state — skipped"
    fi
  done

  # Locate the branch's worktree + the main worktree, switch develop + pull, clean up.
  wt=$(git worktree list --porcelain | awk -v b="refs/heads/$branch" '/^worktree /{p=$2} /^branch /{if($2==b) print p}')
  main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
  git -C "$main_wt" checkout "$base" 2>/dev/null || git checkout "$base"
  git -C "$main_wt" pull origin "$base" 2>/dev/null || git pull origin "$base"

  if [[ -n "$wt" && "$wt" != "$main_wt" ]]; then
    git worktree remove "$wt" --force && echo "✓ Removed worktree $wt"
  fi
  git branch -D "$branch" 2>/dev/null && echo "✓ Deleted local branch $branch"
  git push origin --delete "$branch" 2>/dev/null && echo "✓ Deleted remote branch $branch" || echo "  (remote branch already gone)"
  git worktree prune
  echo "✓ On $base, up to date — merged branch + worktree cleaned"
}

# kit task new — create a GitHub issue with labels + milestone, add it to the board, set Role +
# Status(Todo) + Plan Link. Inputs are passed (the caller does the AskUserQuestion). No invented
# values; fails loudly on an unknown label family upstream (the caller validates the closed sets).
# Args: <title> <role-display-or-slug> <kind> <priority> <milestone> [plan-link] [blocked-by] <body>
kto_task_new() {
  local title="${1:-}" role="${2:-}" kind="${3:-}" prio="${4:-}" milestone="${5:-}" plan="${6:-}" blocked="${7:-}" body_user="${8:-}"
  local repo role_slug labels body url num node item role_opt
  repo="$(kto_repo)"
  [[ -n "$title" && -n "$role" && -n "$kind" && -n "$prio" && -n "$milestone" ]] || {
    echo "✗ kto_task_new: title, role, kind, priority, milestone are required" >&2; return 1; }

  role_slug="$(printf '%s' "$role" | tr 'A-Z ' 'a-z-')"
  labels="kind:${kind},priority:${prio},role:${role_slug}"
  body="$(kto_compose_issue_body "$body_user" "$plan" "$blocked" "$role_slug")"

  url=$(gh issue create --repo "$repo" \
    --title "$title" --body "$body" \
    --label "$labels" --milestone "$milestone" --assignee "@me") || return 1
  num=$(basename "$url")
  echo "✓ $url"

  if kto_board_enabled && type load_project_ids >/dev/null 2>&1 && load_project_ids 2>/dev/null; then
    node=$(gh api "repos/$repo/issues/$num" --jq .node_id 2>/dev/null)
    if [[ -n "$node" ]]; then
      item=$(project_add_item "$node" 2>/dev/null || true)
      if [[ -n "$item" ]]; then
        role_opt="$(_kto_role_option_for_slug "$role_slug")"
        [[ -n "$role_opt" ]] && project_set_single_select "$item" "$ROLE_FIELD_ID" "$role_opt" 2>/dev/null || true
        [[ -n "${STATUS_OPT_TODO:-}" ]] && project_set_single_select "$item" "$STATUS_FIELD_ID" "$STATUS_OPT_TODO" 2>/dev/null || true
        [[ -n "$plan" && -n "${PLAN_LINK_FIELD_ID:-}" ]] && project_set_text "$item" "$PLAN_LINK_FIELD_ID" "$plan" 2>/dev/null || true
      fi
    fi
  fi
  printf '%s' "$num"
}

# kit task close — set the board Status to Done and close the issue (with a summary comment).
# Plan-badge flip stays in the skill (it edits a repo file → needs a worktree/PR). Args: <num> <summary> [pr-num]
kto_task_close() {
  local num="${1:-}" summary="${2:-}"
  local repo issue_json state item
  repo="$(kto_repo)"
  [[ -n "$num" ]] || { echo "✗ kto_task_close: issue number required" >&2; return 1; }
  [[ -n "$summary" ]] || { echo "✗ kto_task_close: a summary is required" >&2; return 1; }

  issue_json=$(gh issue view "$num" --repo "$repo" --json state,projectItems) || return 1
  state=$(printf '%s' "$issue_json" | jq -r .state)

  if kto_board_enabled && type load_project_ids >/dev/null 2>&1 && load_project_ids 2>/dev/null; then
    item=$(project_find_item_by_issue "$num" 2>/dev/null || true)
    [[ -n "$item" && -n "${STATUS_OPT_DONE:-}" ]] && \
      project_set_single_select "$item" "$STATUS_FIELD_ID" "$STATUS_OPT_DONE" 2>/dev/null && \
      echo "✓ Board Status → Done for #$num" || true
  fi

  if [[ "$state" == "OPEN" ]]; then
    gh issue close "$num" --repo "$repo" --comment "$summary" && echo "✓ Closed issue #$num"
  else
    echo "  issue #$num already $state — board status updated only"
  fi
}
