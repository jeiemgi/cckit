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
#   kto_task_pr_merge [pr-num] [--squash|--merge|--rebase]   merge (squash default) + close issues + GC + update the PR base
#   kto_task_new  <title> <role> <kind> <prio> [ms] [plan] [blocked] <body>   create issue + board fields (ms may be empty)
#   kto_task_close <num> <summary> [pr-num]            close issue + board → Done
# errors: mixed — git/gh ops propagate; board + label side effects are best-effort

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
  printf '%s' "${KIT_TASK_REPO:-${KIT_REPO:-}}"
}

# The base branch a PR targets / pr-merge returns to (portable: KIT_BASE_BRANCH, default develop).
kto_base_branch() {
  printf '%s' "${KIT_BASE_BRANCH:-main}"
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

# Compose the PR title as a Conventional Commit subject. Because PRs are squash-merged, this title
# becomes the single commit release-please reads to pick the next version — a non-conventional title
# under-bumps silently, and the commitlint gate (.github/workflows/commitlint.yml) now rejects it.
# Args: <raw-issue-title> <summary> <labels-csv>
#   1. An author <summary> that is ALREADY a conventional subject wins — the author knows the change's
#      true type (e.g. a kind:task that is really a fix). Validated by the shared commitlint.sh.
#   2. Otherwise derive the type from the kind:/bug label (kind:task, the default, → feat) and strip
#      the "[Effort N] M · " / leading "[Tag] " noise from the issue title.
# Network-free (covered by the self-test). Output always passes commitlint_check.
kto_pr_title() {
  local raw="${1:-}" summary="${2:-}" labels="${3:-}" kind ctype desc
  # pr.titleStyle = issue-title (KIT_PR_TITLE_STYLE): the PR title IS the issue title, verbatim — for
  # repos whose convention is "PR title = exact issue title" and that run no commitlint gate.
  if [ "${KIT_PR_TITLE_STYLE:-conventional}" = "issue-title" ] && [ -n "$raw" ]; then
    printf '%s' "$raw"; return 0
  fi
  # Reuse the ONE commit-lint implementation. bin/cckit sources it; if a bare caller hasn't, pull it
  # from the repo (kto_task_pr always runs in-repo). Degrades gracefully if it can't be found.
  if ! type commitlint_check >/dev/null 2>&1; then
    local _cl; _cl="$(git rev-parse --show-toplevel 2>/dev/null)/scripts/lib/commitlint.sh"
    [ -f "$_cl" ] && . "$_cl" 2>/dev/null || true
  fi
  # 1) Prefer an author-provided conventional summary.
  if [ -n "$summary" ] && type commitlint_check >/dev/null 2>&1 && commitlint_check "$summary" >/dev/null 2>&1; then
    printf '%s' "$summary"; return 0
  fi
  # 2) Derive the type from the kind:/bug label.
  kind="$(kto_labels_kind "$labels")"
  case "$kind" in
    feat)     ctype=feat ;;
    chore)    ctype=chore ;;
    docs)     ctype=docs ;;
    ci)       ctype=ci ;;
    test)     ctype=test ;;
    perf)     ctype=perf ;;
    refactor) ctype=refactor ;;
    fix|bug)  ctype=fix ;;
    *)        ctype=feat ;;   # kind:task (the default) and anything unknown → feat
  esac
  case ",$labels," in *,bug,*) ctype=fix ;; esac   # a plain `bug` label → fix
  # 3) Strip "[Effort N] M · " (the "· " consumed here as a literal — byte-wise match is portable
  #    across BSD/GNU sed + locales; a negated class over the multibyte middot is not) and then a
  #    leading "[Tag] " (e.g. [Core]). Order matters: eat the separator before the next tag's "[".
  desc="$(printf '%s' "$raw" | sed -E \
    -e 's/^\[Effort[^]]*\] +[0-9]+ +· +//' \
    -e 's/^\[[^]]+\] +//' \
    -e 's/^[[:space:]]+//')"
  [ -n "$desc" ] || desc="$raw"
  printf '%s: %s' "$ctype" "$desc"
}

# Compose a PR body from the kit-task-pr template. Args: <num> <summary> <role-slug> [issue-title]
# pr.orchestratorSection = true (KIT_PR_ORCHESTRATOR_SECTION) prepends a 2-line
# `## For the orchestrator` section: the issue id + title, then what to review.
kto_compose_pr_body() {
  local num="$1" summary="$2" role="$3" title="${4:-}" sig=""
  if type role_signature >/dev/null 2>&1; then sig="$(role_signature "$role")"; fi
  if [ "${KIT_PR_ORCHESTRATOR_SECTION:-false}" = "true" ]; then
    printf '## For the orchestrator\n\n#%s%s\nReview: the summary below and the diff.\n\n' "$num" "${title:+ · $title}"
  fi
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
  local repo branch meta title labels milestone role author="" url pr_num pr_node item role_opt issue_item
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
  # Conventional Commit PR title (squash-merge commit release-please reads + the commitlint gate).
  local pr_title; pr_title="$(kto_pr_title "$title" "$summary" "$labels")"
  [[ -z "$commit_msg" ]] && commit_msg="$pr_title"

  # TRACKED changes only: `git add -A` would sweep an untracked .env.local (copied into every worktree)
  # into the PR. Untracked files are listed, never committed — `git add` them yourself if they belong.
  if [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
    echo "kto_task_pr: untracked files NOT committed (git add them first if they belong):" >&2
    git ls-files --others --exclude-standard 2>/dev/null | sed 's/^/  /' >&2
  fi
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    git add -u
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
    --title "$pr_title" \
    --body "$(kto_compose_pr_body "$num" "$summary" "$role" "$title")" \
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

# kit task pr-merge — merge a PR (squash by default; --merge or --rebase), rebase-fix conflicts onto
# the PR's base first, close its linked issues (GitHub native auto-close only fires on the default
# branch), then clean up the PR's head branch + worktree and bring the PR's base up to date.
# Args: [<pr-num>] [--squash|--merge|--rebase]   (the PR defaults to the open PR for the current branch)
#
# The PR's base and head come from GitHub, never from the current checkout (#376): the base may be an
# effort/<N> branch, and a sub PR merged from the effort worktree must not GC the effort branch.
kto_task_pr_merge() {
  local input_pr="" method="squash" a
  for a in "$@"; do
    case "$a" in
      --squash) method="squash" ;;
      --merge)  method="merge" ;;
      --rebase) method="rebase" ;;
      -*) echo "✗ kto_task_pr_merge: unknown flag '$a' — usage: cckit merge [<pr>] [--squash|--merge|--rebase]" >&2; return 2 ;;
      *)
        # Refuse anything but a PR number (#366). `gh pr merge --help` exits 0, so a flag taken as
        # the number used to "merge", then run the cleanup on the base branch.
        if [[ -n "$input_pr" || ! "$a" =~ ^#?[0-9]+$ ]]; then
          echo "✗ kto_task_pr_merge: '$a' is not a PR number — usage: cckit merge [<pr>] [--squash|--merge|--rebase]" >&2; return 2
        fi
        input_pr="${a#\#}" ;;
    esac
  done

  local repo branch base pr_num meta merge_state pr_base head issues n state wt main_wt base_wt common
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

  meta=$(gh pr view "$pr_num" --repo "$repo" --json mergeable,mergeStateStatus,baseRefName,headRefName) || return 1
  merge_state=$(printf '%s' "$meta" | jq -r '.mergeable // ""')
  pr_base=$(printf '%s' "$meta" | jq -r '.baseRefName // empty'); pr_base="${pr_base:-$base}"
  head=$(printf '%s' "$meta" | jq -r '.headRefName // empty'); head="${head:-$branch}"
  echo "→ PR #$pr_num: $head → $pr_base ($method)"
  echo "  mergeable=$merge_state status=$(printf '%s' "$meta" | jq -r '.mergeStateStatus // ""')"

  # Branches that are never rebased, force-pushed or deleted here: the repo base, the PR's base
  # (it may be an effort branch), and the release branches (#366).
  _kto_protected() { case "$1" in "$base"|"$pr_base"|main|master|develop|HEAD) return 0 ;; esac; return 1; }

  if [[ "$merge_state" == "CONFLICTING" ]]; then
    if [[ "$branch" != "$head" ]] || _kto_protected "$branch"; then
      echo "✗ PR #$pr_num conflicts — rebase $head onto $pr_base from its own worktree (not from $branch)" >&2; return 1
    fi
    echo "→ Conflicts detected — rebasing onto $pr_base..."
    git fetch origin "$pr_base"
    if git rebase "origin/$pr_base"; then
      git push --force-with-lease origin "$head"
      echo "✓ Rebased and pushed — re-checking mergeability..."
    else
      echo "✗ Rebase had conflicts that need manual resolution — resolve, then run cckit merge again" >&2
      git rebase --abort 2>/dev/null || true
      return 1
    fi
  fi

  if ! gh pr merge "$pr_num" --repo "$repo" "--$method" 2>&1; then
    echo "✗ Merge failed — check PR status: https://github.com/$repo/pull/$pr_num" >&2
    return 1
  fi
  echo "✓ PR #$pr_num merged ($method)"

  # Close linked issues (replaces issue-close-on-merge.yml; native auto-close only fires on main).
  issues="$(kto_closing_issue_numbers "$pr_num")"
  for n in $issues; do
    state=$(gh issue view "$n" --repo "$repo" --json state --jq .state 2>/dev/null)
    if [[ "$state" == "OPEN" ]]; then
      gh issue close "$n" --repo "$repo" \
        --comment "Closed automatically on merge of #$pr_num to $pr_base (cckit merge; GitHub native auto-close only fires on the default branch)." \
        && echo "✓ Closed issue #$n"
    elif [[ -n "$state" ]]; then
      echo "  issue #$n already $state — skipped"
    fi
  done

  # Clean up FROM the main checkout (#371): run from the PR's own worktree, removing it deletes our
  # cwd. Main checkout = parent of the shared git dir; fall back to the first `worktree list` entry.
  wt=$(git worktree list --porcelain | awk -v b="refs/heads/$head" '/^worktree /{p=$2} /^branch /{if($2==b) print p}')
  base_wt=$(git worktree list --porcelain | awk -v b="refs/heads/$pr_base" '/^worktree /{p=$2} /^branch /{if($2==b) print p}')
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  main_wt=""
  [[ -n "$common" && "$(basename "$common")" == ".git" ]] && main_wt="$(dirname "$common")"
  [[ -n "$main_wt" ]] || main_wt=$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')
  cd "$main_wt" || { echo "✗ cannot reach the main checkout $main_wt for cleanup" >&2; return 1; }

  if [[ -n "$wt" && "$wt" != "$main_wt" ]] && ! _kto_protected "$head"; then
    git -C "$main_wt" worktree remove "$wt" --force && echo "✓ Removed worktree $wt"
  fi
  # -D, not -d: a squash merge leaves the branch "not fully merged" by ancestry.
  if _kto_protected "$head"; then
    echo "  ($head is protected — no branch cleanup)"
  else
    git -C "$main_wt" branch -D "$head" 2>/dev/null && echo "✓ Deleted local branch $head"
    git -C "$main_wt" push origin --delete "$head" 2>/dev/null && echo "✓ Deleted remote branch $head" || echo "  (remote branch already gone)"
  fi
  git -C "$main_wt" worktree prune

  # Bring the PR's base up to date where it lives. The repo base: the main checkout switches to it and
  # pulls. An effort/<N> base is checked out in its own worktree (git allows one checkout per branch),
  # so that worktree fast-forwards; with no worktree, the local ref is fast-forwarded by fetch.
  if [[ "$pr_base" == "$base" ]]; then
    git -C "$main_wt" checkout "$pr_base" 2>/dev/null || true
    git -C "$main_wt" pull --ff-only origin "$pr_base" 2>/dev/null || true
    echo "✓ On $pr_base in $main_wt, up to date — merged branch + worktree cleaned"
  elif [[ -n "$base_wt" ]]; then
    git -C "$base_wt" pull --ff-only origin "$pr_base" 2>/dev/null || true
    echo "✓ $pr_base updated in $base_wt — continue there (merged branch + worktree cleaned)"
  else
    git -C "$main_wt" fetch origin "$pr_base:$pr_base" 2>/dev/null || git -C "$main_wt" fetch origin "$pr_base" 2>/dev/null || true
    echo "✓ $pr_base fetched (no worktree has it checked out) — merged branch + worktree cleaned"
  fi
}

# kit task new — create a GitHub issue with labels + milestone, add it to the board, set Role +
# Status(Todo) + Plan Link. Inputs are passed (the caller does the AskUserQuestion). No invented
# values; fails loudly on an unknown label family upstream (the caller validates the closed sets).
# Args: <title> <role-display-or-slug> <kind> <priority> [milestone|""] [plan-link] [blocked-by] <body>
kto_task_new() {
  local title="${1:-}" role="${2:-}" kind="${3:-}" prio="${4:-}" milestone="${5:-}" plan="${6:-}" blocked="${7:-}" body_user="${8:-}"
  local repo role_slug labels body url num node item role_opt
  repo="$(kto_repo)"
  # Milestone is optional: a repo with no milestones (cckit itself) must still be able to file an
  # issue through the verb, or agents fall back to raw `gh issue create` and the board drops it.
  [[ -n "$title" && -n "$role" && -n "$kind" && -n "$prio" ]] || {
    echo "✗ kto_task_new: title, role, kind, priority are required" >&2; return 1; }

  role_slug="$(printf '%s' "$role" | tr 'A-Z ' 'a-z-')"
  labels="kind:${kind},priority:${prio},role:${role_slug}"
  body="$(kto_compose_issue_body "$body_user" "$plan" "$blocked" "$role_slug")"

  url=$(gh issue create --repo "$repo" \
    --title "$title" --body "$body" \
    --label "$labels" ${milestone:+--milestone "$milestone"} --assignee "@me") || return 1
  num=$(basename "$url")
  echo "✓ $url"

  if kto_board_enabled && type load_project_ids >/dev/null 2>&1 && load_project_ids 2>/dev/null; then
    node=$(gh api "repos/$repo/issues/$num" --jq .node_id 2>/dev/null)
    item=""
    [[ -n "$node" ]] && item=$(project_add_item "$node" 2>/dev/null || true)
    # Loud, not silent: an issue missing from the board is the failure this verb exists to prevent.
    [[ -z "$item" ]] && echo "⚠ #$num was created but NOT added to the board — add it by hand" >&2
    if [[ -n "$node" ]]; then
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
