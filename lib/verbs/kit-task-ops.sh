#!/usr/bin/env bash
# kit-task-ops.sh — the ONE canonical home for the kit-task pr|pr-merge|new|close
# git/GitHub mechanics (Family 1 of kit-engine-boundary.md, rule #1/#2).
#
# The four .claude/skills/kit-task-{pr,pr-merge,new,close} skills, the `scripts/kit task <op>`
# dispatcher, and any future surface CALL these functions — they never re-implement the logic.
# Each function is parameterized (no AskUserQuestion / no interactive prompts here — the caller
# collects inputs), and sources the existing helpers (role-identity, gh-project ids).
#
# Source it:  source lib/verbs/kit-task-ops.sh
# Requires: git, gh, jq. bash 3.2 compatible; sourceable under zsh too (no bash-only indirection).
# Self-test: bash lib/verbs/kit-task-ops-test.sh  (pure helpers only — no network)
#
# Functions:
#   kto_repo                                          echo the repo slug (owner/name)
#   kto_branch_issue_number [branch]                  echo issue # parsed from a <kind>/<N>-<slug> branch
#   kto_labels_role <labels-csv>                      echo the role slug from a labels CSV (role:<slug>)
#   kto_labels_kind <labels-csv>                      echo the kind slug from a labels CSV (kind:<slug>)
#   kto_compose_pr_body <num> <summary> <role-slug>   echo a PR body from the template
#   kto_pr_body_style                                 echo content|code (pr.bodyStyle, #418)
#   kto_compose_issue_body <user-body> <plan> <blocked> <role-slug>   echo an issue body
#   kto_closing_issue_numbers <pr-num>                echo the issue #s a merged PR closes
#   kto_task_pr   <num> <summary> [commit-msg] [--base <branch>]   commit+push+open PR (board → In Review)
#   kto_task_pr_merge [pr-num] [--squash|--merge|--rebase]   merge (squash default) + close issues + GC + update the PR base; refuses an effort/* head
#   kto_task_new  <title> <role> <kind> <prio> [ms] [plan] [blocked] <body>   lint the title and the body's effort relations (KIT_FORCE=1 skips the latter), create issue + board fields (ms may be empty)
#   kto_task_close <num> <summary> [pr-num] [--reason R] [--duplicate-of N] [--superseded-by N]   close + reason + board → Done; open subs close with it (#650)
# errors: mixed — git/gh ops propagate; board + label side effects are best-effort

# --- repo resolution -----------------------------------------------------------------------------
# Resolve the repo slug from KIT_REPO (kit-config) when available, else the kit's home repo. A
# caller may export KIT_TASK_REPO to override.
# The forge port (E537): every GitHub call goes through forge_* / gh_rest_* (lib/forge/gh-rest.sh).
if ! command -v gh_rest_issue_json >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/forge/gh-rest.sh"
fi

if [[ -z "${KIT_REPO:-}" ]]; then
  _kto_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$_kto_root" && -f "$_kto_root/scripts/lib/kit-config.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_kto_root/scripts/lib/kit-config.sh" && load_kit_config >/dev/null 2>&1 || true
  fi
  unset _kto_root
fi

# The GitHub transport switch (#396): in rest mode every gh call below is `forge_rest repos/…`.
if ! type cckit_gh_rest >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE:-}" ]; then _kto_self="${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then eval '_kto_self="${(%):-%x}"'
  else _kto_self="$0"; fi
  _kto_self="$(cd "$(dirname "$_kto_self")/.." 2>/dev/null && pwd)/forge/gh-rest.sh"
  # shellcheck source=gh-rest.sh
  [ -f "$_kto_self" ] && . "$_kto_self"
  unset _kto_self
fi
type cckit_gh_rest >/dev/null 2>&1 || cckit_gh_rest() { return 1; }

# The kind vocabulary (kinds.sh): kto_pr_title takes the commit type from kit_kind_commit_type.
if ! type kit_kind_commit_type >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE:-}" ]; then _kto_self="${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then eval '_kto_self="${(%):-%x}"'
  else _kto_self="$0"; fi
  _kto_self="$(cd "$(dirname "$_kto_self")/.." 2>/dev/null && pwd)/core/kinds.sh"
  # shellcheck source=kinds.sh
  [ -f "$_kto_self" ] && . "$_kto_self"
  unset _kto_self
fi
type cckit_board_skipped >/dev/null 2>&1 || cckit_board_skipped() { return 1; }

# The one title convention (naming.sh, E546.1): kto_task_new lints the issue title and kto_task_pr
# the PR title before any forge write; kto_pr_title strips issue prefixes and appends the token.
if ! type naming_title_lint >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE:-}" ]; then _kto_self="${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then eval '_kto_self="${(%):-%x}"'
  else _kto_self="$0"; fi
  _kto_self="$(cd "$(dirname "$_kto_self")/.." 2>/dev/null && pwd)/core/naming.sh"
  # shellcheck source=naming.sh
  [ -f "$_kto_self" ] && . "$_kto_self"
  unset _kto_self
fi

kto_repo() {
  printf '%s' "${KIT_TASK_REPO:-${KIT_REPO:-}}"
}

# The base branch a PR targets / pr-merge returns to (portable: KIT_BASE_BRANCH, default develop).
# Args: [override] — a non-empty override wins over the configured base (#391: `cckit pr --base`).
kto_base_branch() {
  if [[ -n "${1:-}" ]]; then printf '%s' "$1"; return 0; fi
  printf '%s' "${KIT_BASE_BRANCH:-main}"
}

# True (rc 0) iff board updates should run. Off when KIT_PROJECTS_V2 is explicitly "false" — keeps
# the op portable to a project with no Projects v2 board (the plugin's KIT_PROJECTS_V2 toggle).
# In rest mode (#396) the board is GraphQL-only: skipped with one notice, never a failure.
kto_board_enabled() {
  [[ "${KIT_PROJECTS_V2:-true}" != "false" ]] || return 1
  cckit_board_skipped && return 1
  return 0
}

# --- pure parsers (network-free; covered by the self-test) ---------------------------------------

# Parse the issue number from a `<kind>/<N>-<slug>` branch (e.g. feat/173-x -> 173). Empty if none.
kto_branch_issue_number() {
  local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
  printf '%s' "$branch" | grep -oE '/[0-9]+-' | sed -n 1p | tr -d '/-'
}

# Echo the role slug from a comma-separated labels list (role:<slug>). Empty if absent.
kto_labels_role() {
  printf '%s' "$1" | tr ',' '\n' | grep '^role:' | sed -n 1p | cut -d: -f2
}

# Echo the kind slug from a comma-separated labels list (kind:<slug>). Empty if absent.
kto_labels_kind() {
  printf '%s' "$1" | tr ',' '\n' | grep '^kind:' | sed -n 1p | cut -d: -f2
}

# Compose the PR title as a Conventional Commit subject. Because PRs are squash-merged, this title
# becomes the single commit release-please reads to pick the next version — a non-conventional title
# under-bumps silently, and the commitlint gate (.github/workflows/commitlint.yml) now rejects it.
# Args: <raw-issue-title> <summary> <labels-csv> [<issue-num>]
#   1. An author <summary> that is ALREADY a conventional subject wins — the author knows the change's
#      true type (e.g. a kind:task that is really a fix). Validated by the shared commitlint.sh.
#   2. Otherwise derive the type from the kind:/bug label (kind:task, the default, → feat) and strip
#      the issue title's prefix, new ([E<n>.<s>] ) or legacy ([Effort N] M · ), and a leading [Tag].
#   3. With <issue-num>, the title ends in the work's token (rules/naming-and-ids.md) unless it
#      already does: [E<n>.<s>] when the issue is a sub, [E<n>] when it is an effort, else [#<num>].
# Network-free (covered by the self-test). Output always passes commitlint_check.
kto_pr_title() {
  local raw="${1:-}" summary="${2:-}" labels="${3:-}" num="${4:-}" t
  t="$(_kto_pr_title_subject "$raw" "$summary" "$labels")" || return 1
  if [ -n "$num" ] && [ "${KIT_PR_TITLE_STYLE:-conventional}" != "issue-title" ]; then
    t="$(_kto_pr_title_token "$t" "$raw" "$num")"
  fi
  printf '%s' "$t"
}

# _kto_pr_title_token <title> <raw-issue-title> <num> — <title> with the work's trailing token.
_kto_pr_title_token() {
  local t="$1" raw="$2" num="${3#\#}" tok=""
  if grep -qE '\[(E[0-9]+(\.[0-9]+)?|#[0-9]+|share-[0-9]+)\][[:space:]]*$' <<<"$t"; then printf '%s' "$t"; return 0; fi
  if type naming_title_token >/dev/null 2>&1; then tok="$(naming_title_token "$raw" 2>/dev/null || true)"; fi
  [ -n "$tok" ] || tok="#$num"
  printf '%s [%s]' "$t" "$tok"
}

# _kto_pr_title_subject <raw-issue-title> <summary> <labels-csv> — steps 1 and 2 of kto_pr_title.
_kto_pr_title_subject() {
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
  # 1) Prefer an author-provided conventional summary. Without commitlint.sh (a project that is not
  #    cckit), the shape alone decides: `type(scope)!: subject`.
  if [ -n "$summary" ] && type commitlint_check >/dev/null 2>&1 && commitlint_check "$summary" >/dev/null 2>&1; then
    printf '%s' "$summary"; return 0
  fi
  if [ -n "$summary" ] && ! type commitlint_check >/dev/null 2>&1 \
     && grep -qE '^[a-z]+(\([^)]*\))?!?: [^[:space:]]' <<<"$summary"; then
    printf '%s' "$summary"; return 0
  fi
  # 2) Derive the type from the kind:/bug label.
  kind="$(kto_labels_kind "$labels")"
  # The kind -> type map is kinds.sh's (kit_kind_commit_type): a content kind (post, campaign,
  # brand, research) titles as `docs`, kind:task and anything unknown as `feat`.
  if command -v kit_kind_commit_type >/dev/null 2>&1; then
    ctype="$(kit_kind_commit_type "$kind")"
  else
    case "$kind" in
      feat|chore|docs|ci|test|perf|refactor) ctype="$kind" ;;
      fix|bug) ctype=fix ;;
      post|campaign|brand|research) ctype=docs ;;
      *) ctype=feat ;;
    esac
  fi
  case ",$labels," in *,bug,*) ctype=fix ;; esac   # a plain `bug` label → fix
  # 3) Strip "[E<n>.<s>] " / "[E<n>] " and the legacy "[Effort N] M · " (the "· " consumed here as
  #    a literal — byte-wise match is portable across BSD/GNU sed + locales; a negated class over the
  #    multibyte middot is not), then a leading "[Tag] " (e.g. [Core]). Order matters: eat the
  #    separator before the next tag's "[".
  desc="$(printf '%s' "$raw" | sed -E \
    -e 's/^\[E[0-9]+(\.[0-9]+)?\] +//' \
    -e 's/^\[Effort[^]]*\] +[0-9]+ +· +//' \
    -e 's/^\[[^]]+\] +//' \
    -e 's/^[[:space:]]+//')"
  [ -n "$desc" ] || desc="$raw"
  # No issue title (no forge read it): the summary is the subject.
  [ -n "$desc" ] || desc="$(printf '%s' "$summary" | sed -E 's/^[a-z]+(\([^)]*\))?!?: //')"
  printf '%s: %s' "$ctype" "$desc"
}

# kto_pr_body_style — `content` or `code`: which wording a generated PR body uses (#418).
# pr.bodyStyle in the config (KIT_PR_BODY_STYLE); anything but `content` is `code`. The content and
# marketing profiles set `content`. Shared by `cckit pr`, `cckit effort pr` and `cckit task finish`.
kto_pr_body_style() {
  if [ "${KIT_PR_BODY_STYLE:-code}" = "content" ]; then printf 'content'; else printf 'code'; fi
}

# kto_content_review_checklist — the review checklist of a content-style PR body, one item per
# line. The same four lines in every body the kit writes for content work.
kto_content_review_checklist() {
  printf '%s\n' \
    '- [ ] Read the draft from start to finish' \
    '- [ ] Facts, names, numbers and links are checked' \
    '- [ ] The voice matches the brand guide' \
    '- [ ] Only the files for this piece changed'
}

# Compose a PR body from the kit-task-pr template. Args: <num> <summary> <role-slug> [issue-title]
# pr.orchestratorSection = true (KIT_PR_ORCHESTRATOR_SECTION) prepends a 2-line
# `## For the orchestrator` section: the issue id + title, then what to review.
# pr.bodyStyle = content swaps the code wording (diff, reproduced manually) for draft-and-review
# wording; `Closes #N`, the summary and the signature are the same in both.
kto_compose_pr_body() {
  local num="$1" summary="$2" role="$3" title="${4:-}" sig="" style
  style="$(kto_pr_body_style)"
  if type role_signature >/dev/null 2>&1; then sig="$(role_signature "$role")"; fi
  # A summary that already carries the section (an agent wrote the whole body) keeps its own: the
  # section is added only when absent, so it never prints twice.
  if [ "${KIT_PR_ORCHESTRATOR_SECTION:-false}" = "true" ] \
     && ! grep -q '^## For the orchestrator[[:space:]]*$' <<<"$summary"; then
    if [ "$style" = "content" ]; then
      printf '## For the orchestrator\n\n#%s%s\nReview: the summary below and the changed files.\n\n' "$num" "${title:+ · $title}"
    else
      printf '## For the orchestrator\n\n#%s%s\nReview: the summary below and the diff.\n\n' "$num" "${title:+ · $title}"
    fi
  fi
  if [ "$style" = "content" ]; then
    cat <<EOF
## Closes

Closes #$num

## Summary

$summary

## Review

$(kto_content_review_checklist)

## Notes for the reviewer

—

## Not in this piece

—

$sig

---
<sub>· \`claude-kit\` · kit-task-pr</sub>
EOF
    return 0
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
  gh_rest_pr_closing_issues "$repo" "$pr"; return 0
}

# --- the four ops (network; not exercised by the self-test) --------------------------------------

# Map a role slug to the board's Role single-select option id (uses gh-project's role_option_id,
# which takes a display name — translate slug -> display via role_display). A slug role_display
# does not list is passed as-is (#378): role_option_id normalizes it to the same ROLE_OPT_<NAME>.
_kto_role_option_for_slug() {
  local slug="$1" disp=""
  [[ -z "$slug" ]] && return 0
  if type role_display >/dev/null 2>&1; then disp="$(role_display "$slug")"; fi
  [[ -z "$disp" ]] && disp="$slug"
  if type role_option_id >/dev/null 2>&1; then role_option_id "$disp"; fi
}

# kit task pr — commit current changes (role identity in a Co-authored-by TRAILER, never the
# author field — Vercel rejects unknown author emails), push, open the PR with the issue's
# labels/milestone, add it to the board In Review, and move the issue to In Review.
# Args: <issue-num> <summary> [commit-msg] [--base <branch>]
#
# --base (#391) targets a branch other than the configured base — a release PR develop -> main.
# load_kit_config re-exports KIT_BASE_BRANCH from the config, so an env override cannot do this.
# The flag is parsed out before the positionals are read, anywhere on the line, and a missing value
# returns 2 before the commit and the push. The target is exported to the push as KIT_PR_BASE (set
# with or without the flag), so a project's git pre-push hook can compare against the branch the PR
# targets (#360).
kto_task_pr() {
  # Default-safe reads: callers (scripts/kit) may run under `set -u`.
  local num="" summary="" commit_msg="" base_override="" _pos=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          echo "✗ kto_task_pr: --base needs a branch — usage: cckit pr <issue> \"<summary>\" [--base <branch>]" >&2; return 2
        fi
        base_override="$2"; shift 2 ;;
      --base=*)
        base_override="${1#--base=}"
        if [ -z "$base_override" ]; then
          echo "✗ kto_task_pr: --base needs a branch — usage: cckit pr <issue> \"<summary>\" [--base <branch>]" >&2; return 2
        fi
        shift ;;
      *)
        _pos=$((_pos + 1))
        case "$_pos" in 1) num="$1" ;; 2) summary="$1" ;; 3) commit_msg="$1" ;; esac
        shift ;;
    esac
  done
  local base; base="$(kto_base_branch "$base_override")"
  local repo branch meta title labels milestone role author="" url pr_num pr_node item role_opt issue_item
  repo="$(kto_repo)"
  branch="$(git rev-parse --abbrev-ref HEAD)"

  [[ -n "$num" ]] || num="$(kto_branch_issue_number "$branch")"
  [[ -n "$num" ]] || { echo "✗ kto_task_pr: branch '$branch' doesn't match <kind>/<N>-<slug> and no issue number passed" >&2; return 1; }
  [[ -n "$summary" ]] || { echo "✗ kto_task_pr: a Summary is required (never invent one)" >&2; return 1; }

  if forge_available; then
    meta=$(gh_rest_issue_json "$repo" "$num") || return 1
    title=$(printf '%s' "$meta" | jq -r .title)
    labels=$(printf '%s' "$meta" | jq -r '[.labels[].name] | join(",")')
    milestone=$(printf '%s' "$meta" | jq -r '.milestone.title // ""')
  else
    # The git steps run: commit and push. The issue is not read and the pull request is not opened;
    # the compare page is printed when origin is on GitHub.
    forge_note_none pr "issue #$num is not read and the pull request is not opened; the branch is committed and pushed"
    title=""; labels=""; milestone=""
  fi
  role="$(kto_labels_role "$labels")"
  # Conventional Commit PR title (squash-merge commit release-please reads + the commitlint gate).
  local pr_title; pr_title="$(kto_pr_title "$title" "$summary" "$labels" "$num")"
  # The naming rule (E546.1) before the commit, the push or the PR: a Conventional Commit subject
  # ending in the work's token. Refused here, nothing is written.
  if type naming_title_lint >/dev/null 2>&1; then
    naming_title_lint pr "$pr_title" || { echo "✗ kto_task_pr: the PR title breaks the naming rule — pass a summary of the form 'type(scope): subject'" >&2; return 1; }
  fi
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

  KIT_PR_BASE="$base" git push -u origin "$branch" || return 1

  if ! forge_available; then
    local cmp; cmp="$(forge_compare_url "$base" "$branch" 2>/dev/null || true)"
    if [[ -n "$cmp" ]]; then echo "✓ pushed $branch → open the pull request: $cmp"
    else echo "✓ pushed $branch (no forge: open the pull request on your forge, $branch → $base)"; fi
    return 0
  fi
  url=$(gh_rest_pr_create "$repo" "$base" "$branch" "$pr_title" \
    "$(kto_compose_pr_body "$num" "$summary" "$role" "$title")" "$labels" "$milestone") || return 1
  echo "✓ $url"

  # Board: add the PR (In Review) + move the issue to In Review. Best-effort — never fail the op.
  if kto_board_enabled && type load_project_ids >/dev/null 2>&1 && load_project_ids 2>/dev/null; then
    pr_num="$(basename "$url")"
    pr_node=$(forge_rest "repos/$repo/pulls/$pr_num" --jq .node_id 2>/dev/null)
    if [[ -n "$pr_node" ]]; then
      item=$(project_add_item "$pr_node" "$repo" "$pr_num" PullRequest 2>/dev/null || true)
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

# kit task pr-merge — merge a PR (squash by default; --merge or --rebase), merge-fix conflicts from
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

  local repo branch base pr_num meta merge_state pr_base head issues n state wt main_wt base_wt common effort_n
  repo="$(kto_repo)"
  base="$(kto_base_branch)"
  branch="$(git rev-parse --abbrev-ref HEAD)"

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "✗ Working tree is dirty — commit or stash changes first" >&2; return 1
  fi

  if ! forge_available; then
    [[ -z "$input_pr" ]] || { echo "✗ cckit merge: no forge — a pull request number cannot be read; run it from the branch's worktree with no argument" >&2; return 1; }
    _kto_local_merge "$branch" "$base" "$method"
    return $?
  fi

  pr_num="$input_pr"
  if [[ -z "$pr_num" ]]; then
    pr_num=$(gh_rest_pr_for_head "$repo" "$branch")
    [[ -z "$pr_num" ]] && { echo "✗ No open PR found for branch $branch" >&2; return 1; }
  fi

  meta=$(gh_rest_pr_json "$repo" "$pr_num") || return 1
  merge_state=$(printf '%s' "$meta" | jq -r '.mergeable // ""')
  pr_base=$(printf '%s' "$meta" | jq -r '.baseRefName // empty'); pr_base="${pr_base:-$base}"
  head=$(printf '%s' "$meta" | jq -r '.headRefName // empty'); head="${head:-$branch}"
  echo "→ PR #$pr_num: $head → $pr_base ($method)"
  echo "  mergeable=$merge_state status=$(printf '%s' "$meta" | jq -r '.mergeStateStatus // ""')"

  # An effort's PR merges with `cckit effort close` (#379): that op snapshots each sub-issue's diff
  # before the squash destroys the per-sub commits. Refused before the rebase and the merge, so a
  # refusal writes nothing. KIT_FORCE=1 merges anyway.
  if [[ "$head" == effort/* ]]; then
    effort_n="${head#effort/}"; effort_n="${effort_n%%-*}"
    if [[ "${KIT_FORCE:-0}" == "1" ]]; then
      echo "⚠ KIT_FORCE=1: merging effort branch $head with cckit merge — no per-sub trace snapshot is taken (cckit effort close $effort_n takes it)" >&2
    else
      echo "✗ PR #$pr_num is an effort branch ($head) — merge it with: cckit effort close $effort_n" >&2
      echo "  cckit merge would skip the per-sub trace snapshot effort close takes before the squash. KIT_FORCE=1 merges anyway." >&2
      return 1
    fi
  fi

  # Branches that are never merged into, pushed to or deleted here: the repo base, the PR's base
  # (it may be an effort branch), and the release branches (#366). A pushed branch is brought onto
  # its base by merge, never by rebase, so no push here needs --force (#592).
  _kto_protected() { case "$1" in "$base"|"$pr_base"|main|master|develop|HEAD) return 0 ;; esac; return 1; }

  if [[ "$merge_state" == "CONFLICTING" ]]; then
    if [[ "$branch" != "$head" ]] || _kto_protected "$branch"; then
      echo "✗ PR #$pr_num conflicts — merge origin/$pr_base into $head from its own worktree (not from $branch)" >&2; return 1
    fi
    echo "→ Conflicts detected — merging origin/$pr_base into $head..."
    git fetch origin "$pr_base"
    if git merge --no-edit "origin/$pr_base"; then
      git push origin "$head"
      echo "✓ Merged $pr_base in and pushed — re-checking mergeability..."
    else
      echo "✗ Merge had conflicts that need manual resolution — from this branch's worktree run: git merge origin/$pr_base, resolve, commit, push, then run cckit merge again" >&2
      git merge --abort 2>/dev/null || true
      return 1
    fi
  fi

  if ! gh_rest_pr_merge "$repo" "$pr_num" "$method" 2>&1; then
    echo "✗ Merge failed — check PR status: https://github.com/$repo/pull/$pr_num" >&2
    return 1
  fi
  echo "✓ PR #$pr_num merged ($method)"

  # Close linked issues (replaces issue-close-on-merge.yml; native auto-close only fires on main).
  issues="$(kto_closing_issue_numbers "$pr_num")"
  # Read line by line on fd 3, not `for n in $issues` (#379): word-splitting follows the caller's
  # IFS, and a NUL-polluted IFS passed "1020\n1021" to gh as one issue number.
  while IFS= read -r n <&3; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    state=$(gh_rest_issue_state "$repo" "$n" 2>/dev/null)
    if [[ "$state" == "OPEN" ]]; then
      gh_rest_issue_close "$repo" "$n" completed \
        "Closed automatically on merge of #$pr_num to $pr_base (cckit merge; GitHub native auto-close only fires on the default branch)." \
        && echo "✓ Closed issue #$n"
    elif [[ -n "$state" ]]; then
      echo "  issue #$n already $state — skipped"
    fi
  done 3<<EOF
$issues
EOF

  _kto_merge_cleanup "$head" "$pr_base" "$base"
}

# _kto_local_merge <branch> <base> <squash|merge|rebase> — the forge-less merge (E537.4): the
# branch lands on the base through git alone. From the main checkout: fetch the base, fast-forward
# it, merge the branch (a squash commit titled after the branch's last commit; --merge keeps the
# commits under a merge commit; --rebase replays the branch first and fast-forwards), push the base.
# Then the usual cleanup. Linked issues are not closed: that needs a forge, and the note says so.
_kto_local_merge() {
  local head="$1" base="$2" method="$3" main_wt common subject rc=0
  forge_note_none merge "the branch lands on $base through git; no pull request is merged and no issue is closed"
  if [[ "$head" == effort/* ]]; then
    echo "✗ $head is an effort branch — merge it with: cckit effort close ${head#effort/}" >&2; return 1
  fi
  case "$head" in "$base"|main|master|develop|HEAD) echo "✗ cckit merge: run it from the branch to merge, not from $head" >&2; return 1 ;; esac
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  main_wt=""
  [[ -n "$common" && "$(basename "$common")" == ".git" ]] && main_wt="$(dirname "$common")"
  [[ -n "$main_wt" ]] || main_wt=$(git worktree list --porcelain | awk '/^worktree / && !hit {print $2; hit=1}')
  if [[ -n "$(git -C "$main_wt" status --porcelain --untracked-files=no)" ]]; then
    echo "✗ cckit merge: the main checkout $main_wt has uncommitted changes — commit or discard them first" >&2; return 1
  fi
  git -C "$main_wt" fetch -q origin "$base" 2>/dev/null || true
  git -C "$main_wt" checkout -q "$base" 2>/dev/null || { echo "✗ cckit merge: cannot check out $base in $main_wt" >&2; return 1; }
  git -C "$main_wt" merge -q --ff-only "origin/$base" 2>/dev/null || true
  subject="$(git log -1 --format=%s "$head")"
  case "$method" in
    squash)
      git -C "$main_wt" merge -q --squash "$head" >/dev/null 2>&1 || rc=1
      [[ $rc -eq 0 ]] && { git -C "$main_wt" commit -q -m "$subject" >/dev/null 2>&1 || rc=1; } ;;
    merge)
      git -C "$main_wt" merge -q --no-ff -m "Merge branch '$head' into $base" "$head" >/dev/null 2>&1 || rc=1 ;;
    rebase)
      git -C "$(git rev-parse --show-toplevel)" rebase -q "$base" >/dev/null 2>&1 || rc=1
      [[ $rc -eq 0 ]] && { git -C "$main_wt" merge -q --ff-only "$head" >/dev/null 2>&1 || rc=1; } ;;
  esac
  if [[ $rc -ne 0 ]]; then
    git -C "$main_wt" merge --abort >/dev/null 2>&1 || git -C "$main_wt" reset -q --hard "origin/$base" >/dev/null 2>&1 || true
    echo "✗ cckit merge: $head does not merge cleanly onto $base — rebase it onto origin/$base in its worktree and rerun" >&2
    return 1
  fi
  git -C "$main_wt" push -q origin "$base" 2>/dev/null || { echo "✗ cckit merge: merged locally on $base but the push to origin failed — push $base yourself" >&2; return 1; }
  echo "✓ $head merged into $base ($method) and pushed"
  _kto_merge_cleanup "$head" "$base" "$base"
}

# _kto_merge_cleanup <head> <pr-base> <base> — remove the merged branch's worktree and branches,
# then bring the PR's base up to date where it lives. Shared by the forge and the git-only merge.
_kto_merge_cleanup() {
  local head="$1" pr_base="$2" base="$3" wt base_wt common main_wt
  _kto_protected() { case "$1" in "$base"|"$pr_base"|main|master|develop|HEAD) return 0 ;; esac; return 1; }
  # Clean up FROM the main checkout (#371): run from the PR's own worktree, removing it deletes our
  # cwd. Main checkout = parent of the shared git dir; fall back to the first `worktree list` entry.
  wt=$(git worktree list --porcelain | awk -v b="refs/heads/$head" '/^worktree /{p=$2} /^branch /{if($2==b) print p}')
  base_wt=$(git worktree list --porcelain | awk -v b="refs/heads/$pr_base" '/^worktree /{p=$2} /^branch /{if($2==b) print p}')
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  main_wt=""
  [[ -n "$common" && "$(basename "$common")" == ".git" ]] && main_wt="$(dirname "$common")"
  [[ -n "$main_wt" ]] || main_wt=$(git worktree list --porcelain | awk '/^worktree / && !hit {print $2; hit=1}')
  cd "$main_wt" || { echo "✗ cannot reach the main checkout $main_wt for cleanup" >&2; return 1; }

  if [[ -n "$wt" && "$wt" != "$main_wt" ]] && ! _kto_protected "$head"; then
    git -C "$main_wt" worktree remove "$wt" --force && echo "✓ Removed worktree $wt"
  fi
  # -D, not -d: a squash merge leaves the branch "not fully merged" by ancestry.
  if _kto_protected "$head"; then
    echo "  ($head is protected — no branch cleanup)"
  else
    git -C "$main_wt" branch -D "$head" 2>/dev/null && echo "✓ Deleted local branch $head"
    if cckit_in_cloud; then
      # The cloud proxy rejects branch deletion (#396): keep it and say so.
      echo "  (remote branch $head kept — branch deletion is unavailable here; delete it on GitHub)"
    else
    git -C "$main_wt" push origin --delete "$head" 2>/dev/null && echo "✓ Deleted remote branch $head" || echo "  (remote branch already gone)"
    fi
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

# _kto_existing_labels <repo> <comma-labels> — the subset of <comma-labels> the repo has, comma-joined
# on stdout; each one it lacks is named in a warning on stderr (#387). `gh issue create --label`
# aborts on an unknown label before any issue exists, and the REST endpoint creates the label
# instead, so both transports are filtered here: the issue is filed, no label is invented. Names
# match case-insensitively, as GitHub's do. A label list that cannot be read filters nothing.
_kto_existing_labels() {
  local repo="$1" want="$2" have l keep=""
  have="$(gh_rest_label_names "$repo")" || { printf '%s' "$want"; return 0; }
  while IFS= read -r l; do
    [[ -n "$l" ]] || continue
    if grep -qixF -- "$l" <<<"$have"; then
      keep="${keep:+$keep,}$l"
    else
      echo "⚠ label '$l' not found in $repo — issue created without it (lib/verbs/setup-labels.sh provisions the kit's labels)" >&2
    fi
  done <<EOF
$(printf '%s\n' "$want" | tr ',' '\n')
EOF
  printf '%s' "$keep"
}

# kit task new — create a GitHub issue with labels + milestone, add it to the board, set Role +
# Status (Backlog when no milestone is named and the board has that option, else Todo) + Plan Link. Inputs are passed (the caller does the AskUserQuestion). No invented
# values: a label the repo does not have is dropped with a warning, never created, and the issue is
# still filed (#387). Non-zero only when the issue itself was not created.
# Args: <title> <role-display-or-slug> <kind> <priority> [milestone|""] [plan-link] [blocked-by] <body>
kto_task_new() {
  local title="${1:-}" role="${2:-}" kind="${3:-}" prio="${4:-}" milestone="${5:-}" plan="${6:-}" blocked="${7:-}" body_user="${8:-}"
  local repo role_slug labels body url num node item role_opt status_opt
  repo="$(kto_repo)"
  # Milestone is optional: a repo with no milestones (cckit itself) must still be able to file an
  # issue through the verb, or agents fall back to raw `gh issue create` and the board drops it.
  [[ -n "$title" && -n "$role" && -n "$kind" && -n "$prio" ]] || {
    echo "✗ kto_task_new: title, role, kind, priority are required" >&2; return 1; }

  # The naming rule (E546.1): a standalone issue is a plain outcome of at most six words, no prefix.
  # Checked before any forge read or write; multi-part work is `cckit effort new`.
  if type naming_title_lint >/dev/null 2>&1; then
    naming_title_lint issue "$title" || { echo "✗ kto_task_new: fix the title and retry — nothing was filed" >&2; return 1; }
  fi

  role_slug="$(printf '%s' "$role" | tr 'A-Z ' 'a-z-')"
  labels="kind:${kind},priority:${prio},role:${role_slug}"
  body="$(kto_compose_issue_body "$body_user" "$plan" "$blocked" "$role_slug")"

  # An issue that cites an effort ([E<n>] / [E<n>.<step>]) carries a relation to #<n>, or it is a
  # loose issue (E632.4). Checked on the composed body, so --blocked-by counts, before any forge
  # call; --force / KIT_FORCE=1 files it anyway.
  if [[ "${KIT_FORCE:-0}" != 1 ]] && type naming_body_relation_lint >/dev/null 2>&1; then
    naming_body_relation_lint "$body" || { echo "✗ kto_task_new: add the relation and retry — nothing was filed" >&2; return 1; }
  fi

  labels="$(_kto_existing_labels "$repo" "$labels")"

  url=$(gh_rest_issue_create "$repo" "$title" "$body" "$labels" "$milestone") || return 1
  num=$(basename "$url")
  echo "✓ $url"

  if kto_board_enabled && type load_project_ids >/dev/null 2>&1 && load_project_ids 2>/dev/null; then
    node=$(forge_rest "repos/$repo/issues/$num" --jq .node_id 2>/dev/null)
    item=""
    [[ -n "$node" ]] && item=$(project_add_item "$node" "$repo" "$num" Issue 2>/dev/null || true)
    # Loud, not silent: an issue missing from the board is the failure this verb exists to prevent.
    [[ -z "$item" ]] && echo "⚠ #$num was created but NOT added to the board — add it by hand" >&2
    if [[ -n "$node" ]]; then
      if [[ -n "$item" ]]; then
        role_opt="$(_kto_role_option_for_slug "$role_slug")"
        [[ -n "$role_opt" ]] && project_set_single_select "$item" "$ROLE_FIELD_ID" "$role_opt" 2>/dev/null || true
        # No sprint (milestone) named: the issue waits in the Backlog column, so it is not loose
        # (E546.2). A board without a Backlog option keeps Todo.
        status_opt="${STATUS_OPT_TODO:-}"
        [[ -z "$milestone" && -n "${STATUS_OPT_BACKLOG:-}" ]] && status_opt="$STATUS_OPT_BACKLOG"
        [[ -n "$status_opt" ]] && project_set_single_select "$item" "$STATUS_FIELD_ID" "$status_opt" 2>/dev/null || true
        [[ -n "$plan" && -n "${PLAN_LINK_FIELD_ID:-}" ]] && project_set_text "$item" "$PLAN_LINK_FIELD_ID" "$plan" 2>/dev/null || true
      fi
    fi
  fi
  printf '%s' "$num"
}

# kit task close — set the board Status to Done and close the issue with a summary comment and a
# close reason (#377). Plan-badge flip stays in the skill (it edits a repo file → needs a worktree/PR).
# Args: <num> <summary> [pr-num] [--reason completed|not-planned|duplicate] [--duplicate-of <N>]
#       [--superseded-by <N>]
#   --duplicate-of N   GitHub state_reason duplicate, linked to #N (implies --reason duplicate)
#   --superseded-by N  state_reason not planned + "Superseded by #N" in the comment
# The summary may be omitted with --duplicate-of / --superseded-by: it defaults to "Duplicate of #N."
# / "Superseded by #N.". Flags may come anywhere; the closed set is the close-reason vocabulary.
kto_task_close() {
  local num="" summary="" reason="" dup="" sup="" a pos=0
  while [[ $# -gt 0 ]]; do
    a="$1"
    case "$a" in
      --reason)        reason="${2:-}"; shift 2 ;;
      --reason=*)      reason="${a#--reason=}"; shift ;;
      --duplicate-of)  dup="${2:-}"; shift 2 ;;
      --superseded-by) sup="${2:-}"; shift 2 ;;
      -*) echo "✗ kto_task_close: unknown flag '$a' — usage: cckit close <issue> [\"<summary>\"] [--reason completed|not-planned|duplicate] [--duplicate-of N] [--superseded-by N]" >&2; return 2 ;;
      *)
        pos=$((pos+1))
        case "$pos" in 1) num="$a" ;; 2) summary="$a" ;; *) : ;; esac   # 3rd positional = legacy pr-num
        shift ;;
    esac
  done
  dup="${dup#\#}"; sup="${sup#\#}"
  [[ -n "$num" ]] || { echo "✗ kto_task_close: issue number required" >&2; return 1; }
  [[ -z "$dup" || "$dup" =~ ^[0-9]+$ ]] || { echo "✗ kto_task_close: --duplicate-of needs an issue number" >&2; return 2; }
  [[ -z "$sup" || "$sup" =~ ^[0-9]+$ ]] || { echo "✗ kto_task_close: --superseded-by needs an issue number" >&2; return 2; }
  [[ -n "$dup" && -n "$sup" ]] && { echo "✗ kto_task_close: --duplicate-of and --superseded-by are exclusive" >&2; return 2; }

  # The close-reason set (completed · not planned · duplicate · superseded) → GitHub's state_reason.
  local gh_reason
  case "$reason" in
    ""|completed)          gh_reason="completed" ;;
    not-planned|"not planned"|not_planned) gh_reason="not planned" ;;
    duplicate)             gh_reason="duplicate" ;;
    *) echo "✗ kto_task_close: --reason must be completed, not-planned or duplicate (got '$reason')" >&2; return 2 ;;
  esac
  if [[ -n "$dup" ]]; then
    [[ -z "$reason" || "$gh_reason" == "duplicate" ]] || { echo "✗ kto_task_close: --duplicate-of implies --reason duplicate" >&2; return 2; }
    gh_reason="duplicate"; summary="${summary:-Duplicate of #$dup.}"
  fi
  if [[ -n "$sup" ]]; then
    [[ -z "$reason" || "$gh_reason" == "not planned" ]] || { echo "✗ kto_task_close: --superseded-by implies --reason not-planned" >&2; return 2; }
    gh_reason="not planned"
    if [[ -z "$summary" ]]; then summary="Superseded by #$sup."
    else case "$summary" in *"#$sup"*) : ;; *) summary="$summary"$'\n\n'"Superseded by #$sup." ;; esac
    fi
  fi
  [[ "$gh_reason" == "duplicate" && -z "$dup" ]] && { echo "✗ kto_task_close: --reason duplicate needs --duplicate-of <N>" >&2; return 2; }
  [[ -n "$summary" ]] || { echo "✗ kto_task_close: a summary is required" >&2; return 1; }

  local repo issue_json state item
  repo="$(kto_repo)"
  issue_json=$(gh_rest_issue_json "$repo" "$num") || return 1
  state=$(printf '%s' "$issue_json" | jq -r .state)

  if kto_board_enabled && type load_project_ids >/dev/null 2>&1 && load_project_ids 2>/dev/null; then
    item=$(project_find_item_by_issue "$num" 2>/dev/null || true)
    [[ -n "$item" && -n "${STATUS_OPT_DONE:-}" ]] && \
      project_set_single_select "$item" "$STATUS_FIELD_ID" "$STATUS_OPT_DONE" 2>/dev/null && \
      echo "✓ Board Status → Done for #$num" || true
  fi

  if [[ "$state" == "OPEN" ]]; then
    # REST has no duplicate link: state_reason duplicate, and the comment names the original.
    if [[ -n "$dup" ]]; then
      case "$summary" in *"#$dup"*) : ;; *) summary="$summary"$'\n\n'"Duplicate of #$dup." ;; esac
    fi
    gh_rest_issue_close "$repo" "$num" "$gh_reason" "$summary" || return 1
    echo "✓ Closed issue #$num ($gh_reason${dup:+ of #$dup}${sup:+, superseded by #$sup})"
  else
    echo "  issue #$num already $state — board status updated only"
  fi
  # Its open native sub-issues close with it, same reason (#650): the one shared step both close
  # verbs call. Runs on an already-closed parent too, so a re-run finishes a close that left subs.
  local closed_subs sub
  closed_subs="$(gh_rest_close_open_subs "$repo" "$num" "$gh_reason")" || echo "  ⚠ could not close every sub-issue of #$num — check them on the forge" >&2
  while IFS= read -r sub; do
    [[ -n "$sub" ]] || continue
    echo "✓ Closed sub #$sub with its parent ($gh_reason)"
  done <<EOF_SUBS
$closed_subs
EOF_SUBS
  return 0
}
