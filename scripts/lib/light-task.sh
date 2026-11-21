#!/usr/bin/env bash
# shellcheck shell=bash
# light-task.sh — `cckit task <new|list|next|start|finish|run|share>` (#450): track work without
# GitHub issues. The records come from a task source (task-source.sh; the `file` source keeps one
# tracked file per task); this file is the verbs, and it never reads a task any other way.
#
#   new    record a task in this checkout                         (no branch, no commit)
#   list   every open task and its state; --all adds done and dropped
#   next   the task to take next + the command that starts it
#   start  worktree `.claude/worktrees/light+<id>-<slug>` on branch `light/<id>-<slug>`, cut from
#          the base branch, pushed so the team sees the task is taken        (alias: take)
#   finish mark the task done ON ITS BRANCH, commit, push, open the pull request. The task is done
#          when that pull request merges — review stays a pull request       (alias: done)
#   default  print `light` or `issues`: which list is the project's default (tasks.default)
#   run    start + ONE headless objective built from the task record + finish: hands a task to an
#          agent and prints the review link. Never merges (#496). For a page task (kind `page`, or
#          `tasks.design: true` in the config) the objective names the `page-design` skill and the
#          review lists the skills the run loaded (#504)
#   share  one pull request that adds this checkout's drafts to the base branch, for a backlog
#          nobody has started yet. The tasks list as `shared` until it merges; run again with no
#          new drafts, it retries a share whose push or pull request failed
#
# Branch form: `light/<id>-<slug>`. `light` is not a kind and <id> starts with a letter, so the
# branch never parses as an issue number; worktree-issue.sh (wt_task_id) parses it instead, and
# `cckit gc` keeps the branch while the task is not done on the base branch.
#
# Never merges, never closes anything, and writes nothing to GitHub but the branch and the PR.
#
#   lt_cli <sub> [args…]     the dispatcher bin/cckit calls; honours --llm (CCKIT_OUTPUT=json)
#     returns: 0 ok · 1 refused or a failed step · 2 usage
#
# Requires: git, jq; gh for finish and share. worktree-start.sh (wt_bootstrap) and kit-task-ops.sh
# (kto_pr_title) when loaded. bash 3.2 compatible; sourceable under zsh.
# errors: strict — rc 1 on any failed step; nothing is pushed or opened after a failure
# Runs under the dispatcher's `set -eu`: every read that may fail carries `|| true` or an `if`.

_LT_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
if ! command -v task_source_call >/dev/null 2>&1; then
  # shellcheck source=task-source.sh
  . "$_LT_LIB_DIR/task-source.sh"
fi
if ! command -v wt_task_id >/dev/null 2>&1; then
  # shellcheck source=worktree-issue.sh
  . "$_LT_LIB_DIR/worktree-issue.sh"
fi
if ! type cckit_gh_rest >/dev/null 2>&1; then
  # shellcheck source=gh-rest.sh
  [ -f "$_LT_LIB_DIR/gh-rest.sh" ] && . "$_LT_LIB_DIR/gh-rest.sh"
fi
type cckit_gh_rest >/dev/null 2>&1 || cckit_gh_rest() { return 1; }
type cckit_is_json >/dev/null 2>&1 || cckit_is_json() { [ "${CCKIT_OUTPUT:-human}" = "json" ]; }

_LT_TAB="$(printf '\t')"

# _lt_say <technical> <plain> — one progress line, worded for the reader (#420). With
# plainLanguage.enabled (KIT_PLAIN_LANGUAGE=true) the plain wording is printed: no worktree, branch
# or pull request. Only human progress lines go through here; stdout contracts and --llm do not.
# The plain finish hint names --all: a draft is a file the task created, and without --all
# `finish` opens the review without it.
_lt_say() {
  if [ "${KIT_PLAIN_LANGUAGE:-false}" = "true" ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}

_lt_usage() {
  cat >&2 <<'EOF'
cckit task new [--priority p0|p1|p2|p3] [--kind K] [--body B|--body-file F] "<title>"
cckit task list [--all]
cckit task next
cckit task start [--force] [--no-push] <id>          (alias: take)
cckit task finish [<id>] "<summary>" [--all]         (alias: done)
cckit task run <id> [--check "<cmd>"] [--max-iters N] [--max-seconds N] [--agent <cmd>] [--agent-arg <arg>]… [--no-finish]
cckit task share ["<summary>"]
  a page task: --kind page, or tasks.design: true in the config. `task run` then names the
  page-design skill to the agent, and the review lists the skills the run loaded
cckit task default                                    light | issues (tasks.default in the config)
EOF
}

_lt_root() { git worktree list --porcelain 2>/dev/null | awk '/^worktree / && !hit { print substr($0, 10); hit = 1 }'; }
_lt_top()  { git rev-parse --show-toplevel 2>/dev/null; }
_lt_base() { printf '%s' "${KIT_BASE_BRANCH:-main}"; }
_lt_repo() { printf '%s' "${KIT_TASK_REPO:-${KIT_REPO:-}}"; }

# _lt_worktree_of <root> <branch> — the worktree that has <branch> checked out, or nothing.
_lt_worktree_of() {
  git -C "$1" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$2" '
    /^worktree / { w = substr($0, 10) }
    /^branch /   { if (substr($0, 8) == b) { print w; exit } }'
}

_lt_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40 | sed -E 's/-+$//'
}

# _lt_fetch — refresh the cached refs the source reads. Best-effort: offline still lists.
_lt_fetch() {
  [ "${KIT_TASK_FETCH:-1}" != "0" ] || return 0
  git remote get-url origin >/dev/null 2>&1 || return 0
  git fetch --quiet --prune origin 2>/dev/null || echo "⚠ could not fetch origin — showing the last fetched state" >&2
  return 0
}

# _lt_rows_json — stdin: TSV rows. stdout: a JSON array.
_lt_rows_json() {
  jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
    | {id: .[0], state: .[1], priority: .[2], kind: .[3], created: .[4],
       branch: (if .[5] == "-" then null else .[5] end), title: .[6]})'
}

_lt_table() {
  local id state prio kind created br title
  printf '%-7s %-7s %-4s %s\n' "ID" "STATE" "PRIO" "TITLE"
  while IFS="$_LT_TAB" read -r id state prio kind created br title; do
    [ -n "$id" ] || continue
    printf '%-7s %-7s %-4s %s\n' "$id" "$state" "$prio" "$title"
  done
}

# ── new ─────────────────────────────────────────────────────────────────────────────────────────
lt_new() {
  local prio="p2" kind="task" body="" title="" id dir
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --priority)  prio="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
      --kind)      kind="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
      --body)      body="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
      --body-file) body="$(cat "${2:-/dev/null}")"; shift; [ "$#" -gt 0 ] && shift ;;
      -h|--help)   _lt_usage; return 0 ;;
      --)          shift; title="${title:+$title }$*"; break ;;
      -*)          echo "✗ task new: unknown flag '$1'" >&2; _lt_usage; return 2 ;;
      *)           title="${title:+$title }$1"; shift ;;
    esac
  done
  [ -n "$title" ] || { echo '✗ task new: a title is required — cckit task new "<title>"' >&2; return 2; }
  case "$prio" in p0|p1|p2|p3) : ;; *) echo "✗ task new: --priority is one of p0 p1 p2 p3 (got '$prio')" >&2; return 2 ;; esac
  case "$kind" in ''|*[!a-z]*) echo "✗ task new: --kind is one lowercase word (got '$kind')" >&2; return 2 ;; esac
  id="$(task_source_call create "$title" "$prio" "$kind" "$body")" || return 1
  dir="$(task_source_dir)"
  if cckit_is_json; then
    cckit_json verb "task new" ok true id "$id" title "$title" file "$dir/$id.md"
    return 0
  fi
  echo "✓ task $id · $title"
  if [ "$(task_source_name)" = "file" ]; then
    _lt_say "  file:  $dir/$id.md (a draft: only in this checkout until it is started or shared)" \
            "  file:  $dir/$id.md (only on this computer until you start it or share the list)"
  fi
  echo "  start: cckit task start $id"
}

# ── list / next ─────────────────────────────────────────────────────────────────────────────────
lt_list() {
  local all=0 rows a
  for a in "$@"; do
    case "$a" in
      --all|-a) all=1 ;;
      -h|--help) _lt_usage; return 0 ;;
      *) echo "✗ task list: unknown argument '$a'" >&2; return 2 ;;
    esac
  done
  _lt_fetch
  rows="$(task_source_call list)" || return 1
  if [ "$all" = 0 ]; then rows="$(printf '%s\n' "$rows" | awk -F'\t' '$2 != "done" && $2 != "dropped"')"; fi
  if cckit_is_json; then printf '%s\n' "$rows" | _lt_rows_json; return 0; fi
  if [ -z "$rows" ]; then
    echo '(no open tasks — create one with: cckit task new "<title>")'; return 0
  fi
  printf '%s\n' "$rows" | _lt_table
  # `draft` in the STATE column is about the task record, not about a piece of writing (#487).
  if [ "${KIT_PLAIN_LANGUAGE:-false}" = "true" ] && grep -q "^[^$_LT_TAB]*${_LT_TAB}draft${_LT_TAB}" <<<"$rows"; then
    echo "draft = the task is on this computer only: not started, not on the shared list yet"
  fi
}

lt_next() {
  local row id state prio kind created br title
  _lt_fetch
  row="$(task_source_call list | awk -F'\t' '$2 == "todo" || $2 == "draft"' | sed -n 1p)" || true
  if [ -z "$row" ]; then
    if cckit_is_json; then echo 'null'; else echo '(nothing to take — create a task with: cckit task new "<title>")'; fi
    return 0
  fi
  if cckit_is_json; then printf '%s\n' "$row" | _lt_rows_json | jq -c '.[0] + {start: ("cckit task start " + .[0].id)}'; return 0; fi
  IFS="$_LT_TAB" read -r id state prio kind created br title <<EOF
$row
EOF
  echo "next: $id · $title ($prio)"
  echo "  start: cckit task start $id"
}

# ── start ───────────────────────────────────────────────────────────────────────────────────────
# stdout: "<worktree>|<branch>|<id>" (the shape wt_start prints). stderr: progress.
lt_start() {
  local force="${KIT_FORCE:-0}" push=1 want="" a row id state prio kind created br title
  local root from base base_ref lbr rbr branch wt
  for a in "$@"; do
    case "$a" in
      --force)   force=1 ;;
      --no-push) push=0 ;;
      -h|--help) _lt_usage; return 0 ;;
      -*) echo "✗ task start: unknown flag '$a'" >&2; return 2 ;;
      *)  if [ -z "$want" ]; then want="$a"; else echo "✗ task start: one task id only" >&2; return 2; fi ;;
    esac
  done
  [ -n "$want" ] || { echo "✗ task start: a task id is required — see 'cckit task list'" >&2; return 2; }
  root="$(_lt_root)"; from="$(_lt_top)"
  [ -n "$root" ] && [ -n "$from" ] || { echo "✗ task start: not inside a git repository" >&2; return 1; }
  base="$(_lt_base)"
  if git -C "$root" remote get-url origin >/dev/null 2>&1; then
    git -C "$root" fetch --quiet origin 2>/dev/null || echo "⚠ could not fetch origin — starting from the last fetched $base" >&2
  fi

  row="$(task_source_call get "$want")" || return 1
  IFS="$_LT_TAB" read -r id state prio kind created br title <<EOF
$row
EOF
  case "$state" in
    done|dropped) echo "✗ task $id is already $state" >&2; return 1 ;;
    shared)
      echo "✗ task $id is waiting in a share pull request ($br) — start it once that merges" >&2
      return 1 ;;
  esac

  lbr="$(git -C "$root" for-each-ref --format='%(refname:short)' "refs/heads/light/$id-*" 2>/dev/null | sed -n 1p)"
  rbr="$(git -C "$root" for-each-ref --format='%(refname:short)' "refs/remotes/origin/light/$id-*" 2>/dev/null | sed -n 1p)"
  if [ -n "$lbr" ]; then
    branch="$lbr"
    wt="$(_lt_worktree_of "$root" "$branch")"
    if [ -n "$wt" ]; then
      echo "[$id] reusing worktree $wt" >&2
    else
      wt="$root/.claude/worktrees/$(printf '%s' "$branch" | tr '/' '+')"
      git -C "$root" worktree add "$wt" "$branch" >/dev/null 2>&1 \
        || { echo "✗ task start: worktree add failed for the existing branch $branch" >&2; return 1; }
      echo "[$id] created worktree $wt (existing branch $branch)" >&2
    fi
  elif [ -n "$rbr" ]; then
    branch="${rbr#origin/}"
    if [ "$force" != "1" ]; then
      echo "✗ task $id is already taken: origin has $branch" >&2
      echo "  'cckit task start --force $id' continues that branch in a worktree here." >&2
      return 1
    fi
    wt="$root/.claude/worktrees/$(printf '%s' "$branch" | tr '/' '+')"
    git -C "$root" worktree add -b "$branch" "$wt" "$rbr" >/dev/null 2>&1 \
      || { echo "✗ task start: worktree add failed for $branch" >&2; return 1; }
    echo "[$id] ⚠ --force: continuing $branch from origin in $wt" >&2
  else
    if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$base"; then base_ref="origin/$base"
    elif git -C "$root" show-ref --verify --quiet "refs/heads/$base"; then base_ref="$base"
    else
      # Name the fix (#487): the usual cause is a config whose base branch was never created.
      echo "✗ task start: no base branch '$base' to cut from" >&2
      echo "  The project config names '$base' (github.baseBranch) and this repository has no such branch, here or on origin." >&2
      echo "  Create it and push it:  cckit init --yes   (inside $root)" >&2
      echo "  Or point the config at a branch that exists: this folder is on '$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null || echo "no branch")'." >&2
      return 1
    fi
    branch="light/$id-$(_lt_slug "$title")"
    branch="${branch%-}"
    case "$branch" in "light/$id") branch="light/$id-task" ;; esac
    wt="$root/.claude/worktrees/$(printf '%s' "$branch" | tr '/' '+')"
    git -C "$root" worktree add --no-track -b "$branch" "$wt" "$base_ref" >/dev/null 2>&1 \
      || { echo "✗ task start: worktree add failed for $branch" >&2; return 1; }
    _lt_say "[$id] created worktree $wt (branch $branch from $base_ref)" \
            "[$id] started — the draft lives in $wt" >&2
    if type wt_bootstrap >/dev/null 2>&1; then wt_bootstrap "$root" "$wt" "$id" >&2 || true; fi
  fi

  task_source_call on_start "$id" "$wt" "$from" || return 1

  if [ "$push" = 1 ] && git -C "$root" remote get-url origin >/dev/null 2>&1; then
    if KIT_PR_BASE="$base" git -C "$wt" push --quiet -u origin "$branch" >/dev/null 2>&1; then
      _lt_say "[$id] pushed $branch — the team's list now shows the task as doing" \
              "[$id] the team's list now shows this task as in progress" >&2
    else
      _lt_say "[$id] ⚠ could not push $branch; the task shows as doing on this machine only" \
              "[$id] ⚠ could not reach the shared copy; the task shows as in progress on this computer only" >&2
    fi
  fi
  _lt_say "[$id] when the work is ready: cckit task finish $id \"<summary>\"" \
          "[$id] when the draft is ready for review: cckit task finish $id \"<summary>\" --all" >&2
  echo "$wt|$branch|$id"
}

# _lt_pr_title <title> <summary> <kind> <token> — a Conventional Commit subject ending in [<token>].
_lt_pr_title() {
  local t
  if type kto_pr_title >/dev/null 2>&1; then
    t="$(KIT_PR_TITLE_STYLE=conventional kto_pr_title "$1" "$2" "kind:$3")"
  else
    t="feat: $1"
  fi
  case "$t" in *"[$4]"*) : ;; *) t="$t [$4]" ;; esac
  printf '%s' "$t"
}

# _lt_open_pr <worktree> <branch> <title> <body> — push, then report the open PR or create one.
# stdout: "✓ <url>".
_lt_open_pr() {
  local wt="$1" branch="$2" title="$3" body="$4" repo base url="" n
  repo="$(_lt_repo)"; base="$(_lt_base)"
  if ! KIT_PR_BASE="$base" git -C "$wt" push -u origin "$branch" >&2; then
    echo "✗ could not push $branch — the commit is kept in $wt; run the same command again to retry" >&2
    return 1
  fi
  if cckit_gh_rest; then
    n="$(gh_rest_pr_for_head "$repo" "$branch" 2>/dev/null || true)"
    if [ -n "$n" ]; then url="https://github.com/$repo/pull/$n"; fi
  else
    url="$(gh pr list --repo "$repo" --head "$branch" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)"
  fi
  if [ -n "$url" ]; then
    _lt_say "[task] a pull request is already open for $branch" \
            "[task] this draft is already waiting for review" >&2
    echo "✓ $url"; return 0
  fi
  if cckit_gh_rest; then
    url="$(gh_rest_pr_create "$repo" "$base" "$branch" "$title" "$body" "" "")" || url=""
  else
    url="$(gh pr create --repo "$repo" --base "$base" --head "$branch" \
      --title "$title" --body "$body" --assignee "@me")" || url=""
  fi
  if [ -z "$url" ]; then
    echo "✗ could not open the pull request for $branch — the branch is pushed; run the same command again to retry" >&2
    return 1
  fi
  [ "${KIT_PLAIN_LANGUAGE:-false}" = "true" ] && echo "[task] ready for review — open the link and approve it there" >&2
  echo "✓ $url"
}

# ── finish ──────────────────────────────────────────────────────────────────────────────────────
lt_finish() {
  local all=0 a p1="" p2="" npos=0 want="" summary="" row id state prio kind created br title
  local root branch wt cur dir pr_title body page_check design
  for a in "$@"; do
    case "$a" in
      --all)     all=1 ;;
      -h|--help) _lt_usage; return 0 ;;
      -*) echo "✗ task finish: unknown flag '$a'" >&2; return 2 ;;
      *)  npos=$((npos + 1)); case "$npos" in 1) p1="$a" ;; 2) p2="$a" ;; *) echo "✗ task finish: too many arguments" >&2; return 2 ;; esac ;;
    esac
  done
  cur="$(wt_task_id "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)")"
  if [ "$npos" -eq 2 ]; then want="$p1"; summary="$p2"
  elif [ "$npos" -eq 1 ] && [ -n "$cur" ] && [ "$p1" != "$cur" ]; then want="$cur"; summary="$p1"
  elif [ "$npos" -eq 1 ]; then want="$p1"
  else want="$cur"; fi
  [ -n "$want" ] || { echo '✗ task finish: which task? — cckit task finish <id> "<summary>"' >&2; return 2; }
  [ -n "$summary" ] || { echo '✗ task finish: a summary is required — cckit task finish <id> "<what was done>"' >&2; return 2; }

  root="$(_lt_root)"
  [ -n "$root" ] || { echo "✗ task finish: not inside a git repository" >&2; return 1; }
  row="$(task_source_call get "$want")" || return 1
  IFS="$_LT_TAB" read -r id state prio kind created br title <<EOF
$row
EOF
  case "$state" in done|dropped) echo "✗ task $id is already $state" >&2; return 1 ;; esac
  branch="$(git -C "$root" for-each-ref --format='%(refname:short)' "refs/heads/light/$id-*" 2>/dev/null | sed -n 1p)"
  [ -n "$branch" ] || { echo "✗ task $id has not been started here — run: cckit task start $id" >&2; return 1; }
  wt="$(_lt_worktree_of "$root" "$branch")"
  [ -n "$wt" ] && [ -d "$wt" ] || { echo "✗ task $id: branch $branch has no worktree — run: cckit task start $id" >&2; return 1; }

  task_source_call on_finish "$id" "$wt" || return 1
  if [ "$all" = 1 ]; then
    git -C "$wt" add -A
  else
    git -C "$wt" add -u
    if [ -n "$(git -C "$wt" ls-files --others --exclude-standard 2>/dev/null)" ]; then
      echo "task finish: new files NOT included (re-run with --all, or git add the ones that belong):" >&2
      git -C "$wt" ls-files --others --exclude-standard 2>/dev/null | sed 's/^/  /' >&2
    fi
  fi
  pr_title="$(_lt_pr_title "$title" "$summary" "$kind" "$id")"
  if ! git -C "$wt" diff --cached --quiet 2>/dev/null; then
    git -C "$wt" commit -q -m "$pr_title" >&2 || { echo "✗ task finish: the commit failed in $wt" >&2; return 1; }
  fi

  dir="$(task_source_dir)"
  # A page task (#504): the reviewer is asked to open the page, and the body says which design
  # skills the run loaded.
  page_check=""; design=""
  if _lt_page_task "$kind"; then
    page_check='- [ ] Open the page in a browser and compare it with the design brief'
    design="$(_lt_design_section "$id" "$wt" "$branch")"
  fi
  if type kto_pr_body_style >/dev/null 2>&1 && [ "$(kto_pr_body_style)" = "content" ]; then
    # pr.bodyStyle = content (#418): the reviewer is not a developer — say what approving does and
    # what to check, without "diff".
    body="$(printf '## Task\n\n`%s` · %s\n\n## Summary\n\n%s\n\n## Review\n\n%s\n\nApproving and merging this pull request marks the task done: it changes the task record `%s/%s.md` to `status: done`. No GitHub issue is linked.\n' \
      "$id" "$title" "$summary" "$(kto_content_review_checklist)${page_check:+
$page_check}" "$dir" "$id")"
  else
    body="$(printf '## Light task\n\n`%s` · %s\n\n## Summary\n\n%s\n\n## Review\n\n%sMerging this pull request is what marks the task done: its diff carries the task record with `status: done` (`%s/%s.md` with the file source). No GitHub issue is linked.\n' \
      "$id" "$title" "$summary" "${page_check:+$page_check

}" "$dir" "$id")"
  fi
  if [ -n "$design" ]; then body="$body

$design"; fi
  _lt_open_pr "$wt" "$branch" "$pr_title" "$body"
}

# ── run ─────────────────────────────────────────────────────────────────────────────────────────
# _lt_check_default — `tasks.check` of the project config (the gate `task run` uses with no
# --check), or nothing. The config is the one kit_config_path resolves.
_lt_check_default() {
  local cfg
  cfg="$(_lt_config_file)"
  [ -n "$cfg" ] || return 0
  jq -r '.tasks.check // empty | strings' "$cfg" 2>/dev/null || true
}

# _lt_config_file — the project config kit_config_path resolves, or nothing.
_lt_config_file() {
  local cfg=""
  if ! command -v kit_config_path >/dev/null 2>&1 && [ -f "$_LT_LIB_DIR/config-path.sh" ]; then
    # shellcheck source=config-path.sh
    . "$_LT_LIB_DIR/config-path.sh"
  fi
  if command -v kit_config_path >/dev/null 2>&1; then cfg="$(kit_config_path 2>/dev/null || true)"; fi
  if [ -n "$cfg" ] && [ -f "$cfg" ]; then printf '%s\n' "$cfg"; fi
  return 0
}

# ── page tasks (#504) ───────────────────────────────────────────────────────────────────────────
# The design skills a page is built with: cckit's own `page-design`, then the three third-party
# skills it coordinates (integrations/impeccable.json, emil-design-eng.json,
# web-design-guidelines.json).
_LT_DESIGN_SKILLS="page-design impeccable emil-design-eng web-design-guidelines"

# _lt_page_task <kind> — rc 0 when the task builds or changes a page. The rule is two facts, read
# from the record and the config, never guessed from the title or the notes:
#   1. the task's kind is `page`  (cckit task new --kind page "<title>"), or
#   2. `tasks.design` is true in the project config: every task of the project is a page task
#      (the nextjs-shadcn recipe writes it).
_lt_page_task() {
  local cfg
  [ "${1:-}" = "page" ] && return 0
  cfg="$(_lt_config_file)"
  [ -n "$cfg" ] || return 1
  jq -e '.tasks.design == true' "$cfg" >/dev/null 2>&1
}

# _lt_run_state_file <worktree> <branch> — the state file `cckit autopilot run` keeps for a branch.
_lt_run_state_file() {
  ( cd "$1" 2>/dev/null && . "$_LT_LIB_DIR/kit-state.sh" && printf '%s/autopilot/%s.json' "$(kit_state_dir)" \
      "$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')" ) || true
}

# _lt_design_brief <id> — where page-design writes the brief and the self-review of a task.
_lt_design_brief() { printf 'docs/design/%s.md' "$1"; }

# _lt_design_section <id> <worktree> <branch> — the `## Design` section of a page task's review.
# The skill list is the one the run recorded from the agent CLI's own event output
# (autopilot-run.sh --record-skills → state `.skills`). It is never taken from the agent's account
# of itself, and a list this code cannot stand behind is reported as not known, not as empty.
_lt_design_section() {
  local id="$1" wt="$2" branch="$3" sfile brief
  sfile="$(_lt_run_state_file "$wt" "$branch")"
  brief="$(_lt_design_brief "$id")"
  printf '## Design\n\n'
  if [ -n "$sfile" ] && [ -f "$sfile" ]; then
    jq -r --arg want "$_LT_DESIGN_SKILLS" '
      def base: split(":") | last;
      ($want | split(" ")) as $w
      | if (.skills | type) != "object" then
          "Which skills were loaded is not known: the last run on this task did not record them."
        elif .skills.complete != true then
          "Which skills were loaded is not known: the agent CLI printed no event output in at least one round of the run."
        else
          (.skills.loaded // []) as $l
          | [ $w[] as $x | $l[] | select(base == $x) ] as $d
          | ($w | map(select(. as $x | any($d[]; base == $x) | not))) as $m
          | ($l - $d) as $o
          | (if ($d | length) == 0 then "No design skill was loaded in this run."
             else "Design skills loaded in this run: \($d | join(", "))." end),
            (if ($m | length) > 0 then "Design skills not loaded in this run: \($m | join(", "))." else empty end),
            (if ($o | length) > 0 then "Other skills loaded in this run: \($o | join(", "))." else empty end),
            "Read from the events the agent CLI (\(.skills.source)) printed during the run: a skill is listed when its call returned without an error. What the agent wrote about itself is not used."
        end' "$sfile" 2>/dev/null \
      || printf 'Which skills were loaded is not known: the run record %s could not be read.\n' "$sfile"
  else
    printf 'Which skills were loaded is not known: no `cckit task run` is recorded for this task.\n'
  fi
  printf '\n'
  if [ -f "$wt/$brief" ]; then
    printf 'Design brief and self-review: `%s`.\n' "$brief"
  else
    printf 'No design brief is in this change: `%s` was not written.\n' "$brief"
  fi
}

# lt_run <id> [flags] — delegate ONE task end to end (#496): lt_start (reusing the task's worktree),
# one `cckit autopilot run` objective built from the task's title and notes, then lt_finish --all.
# It adds no engine: the three steps are the code paths the separate verbs run.
#   --check "<cmd>"   the gate the work must pass before a review opens; else `tasks.check` in the
#                     project config; else none
#   --max-iters N · --max-seconds N · --agent <claude|codex> · --agent-arg <arg> (repeatable)
#                     passed to the run. The run has no --until, so it is one round;
#                     --max-seconds also bounds that round
#   --no-finish       stop after the run: nothing is pushed for review, no pull request
# A stopped earlier run on the task's branch is discarded (--fresh): the task record is the
# objective, so there is nothing to resume. A task whose branch already says done (state `review`)
# starts no agent: the open pull request is reported, or opening it is retried.
# stdout: "✓ <url>" — or "<worktree>|<branch>|<id>" with --no-finish. stderr: progress.
# returns: the run's exit code (0 done · 2 refused · 3 agent failed · 4 limit · 5 the round changed
#   nothing · 6 gate failed · 130 interrupted) · 7 the review could not be opened · 1 the task
#   could not be started · 2 usage
lt_run() {
  local want="" check="" check_set=0 iters="" secs="" agent="" finish=1 line id wt branch rest
  local row state prio kind created br title dir body objective rc sfile reason detail summary page=0
  local -a pass
  pass=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check)       [ "$#" -ge 2 ] || { echo "✗ task run: --check needs a value" >&2; return 2; }; check="$2"; check_set=1; shift 2 ;;
      --max-iters)   [ "$#" -ge 2 ] || { echo "✗ task run: --max-iters needs a value" >&2; return 2; }; iters="$2"; shift 2 ;;
      --max-seconds) [ "$#" -ge 2 ] || { echo "✗ task run: --max-seconds needs a value" >&2; return 2; }; secs="$2"; shift 2 ;;
      --agent)       [ "$#" -ge 2 ] || { echo "✗ task run: --agent needs a value" >&2; return 2; }; agent="$2"; shift 2 ;;
      --agent-arg)   [ "$#" -ge 2 ] || { echo "✗ task run: --agent-arg needs a value" >&2; return 2; }; pass+=(--agent-arg "$2"); shift 2 ;;
      --no-finish)   finish=0; shift ;;
      -h|--help)     _lt_usage; return 0 ;;
      -*) echo "✗ task run: unknown flag '$1'" >&2; _lt_usage; return 2 ;;
      *)  if [ -z "$want" ]; then want="$1"; shift; else echo "✗ task run: one task id only" >&2; return 2; fi ;;
    esac
  done
  [ -n "$want" ] || { echo "✗ task run: a task id is required — see 'cckit task list'" >&2; return 2; }
  for rest in "$iters" "$secs"; do
    case "$rest" in *[!0-9]*|0) echo "✗ task run: '$rest' is not a positive integer" >&2; return 2 ;; esac
  done
  [ "$check_set" = 1 ] || check="$(_lt_check_default)"

  line="$(lt_start "$want")" || return 1
  line="$(printf '%s\n' "$line" | tail -n 1)"
  wt="${line%%|*}"; id="${line##*|}"; rest="${line#*|}"; branch="${rest%%|*}"
  [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$id" ] || { echo "✗ task run: the task could not be started" >&2; return 1; }
  [ -z "${_LT_RUN_ID_FILE:-}" ] || printf '%s' "$id" > "$_LT_RUN_ID_FILE"
  row="$(task_source_call get "$id")" || return 1
  IFS="$_LT_TAB" read -r id state prio kind created br title <<EOF
$row
EOF

  if [ "$state" = review ]; then
    # The branch's copy already says done: an earlier run or `task finish` got that far. No round.
    _lt_say "[$id] already finished on $branch — no agent round; reporting its pull request" \
            "[$id] this task was already handed in for review — nothing new was written" >&2
    lt_finish "$id" "$title" --all || return 7
    return 0
  fi

  dir="$(task_source_dir)"
  if _lt_page_task "$kind"; then
    page=1
    if [ ! -f "$wt/.claude/skills/page-design/SKILL.md" ] && [ ! -f "$wt/.agents/skills/page-design/SKILL.md" ]; then
      echo "⚠ task $id is a page task and the page-design skill is not in this project — add it with: cckit add page-design" >&2
    fi
  fi
  body=""
  if task_source_has body; then body="$(task_source_call body "$id" "$wt" || true)"; fi
  objective="$(printf 'Do this task: %s\n' "$title"
    if [ -n "$body" ]; then printf '\nNotes from the task record:\n%s\n' "$body"; fi
    printf '\nThe task is recorded in %s/%s.md. Leave that file as it is: cckit marks the task done when the work goes to review.\n' "$dir" "$id"
    if [ "$page" = 1 ]; then
      printf '\nThis task builds or changes a page. Before writing any code, load the `page-design` skill (in Claude Code with the Skill tool; otherwise read `.claude/skills/page-design/SKILL.md` or `.agents/skills/page-design/SKILL.md`) and follow it.\n'
      printf 'Write the design brief to %s before the first line of code, and add the self-review to the same file after the build.\n' "$(_lt_design_brief "$id")"
      printf 'This run is unattended: do not start the live mode of `impeccable`, and do not report a skill you could not load as used.\n'
    fi)"

  pass+=(--objective "$objective" --fresh)
  if [ "$page" = 1 ]; then pass+=(--record-skills); fi
  if [ -n "$check" ]; then pass+=(--check "$check"); fi
  if [ -n "$iters" ]; then pass+=(--max-iters "$iters"); fi
  if [ -n "$secs" ];  then pass+=(--max-seconds "$secs" --round-seconds "$secs"); fi
  if [ -n "$agent" ]; then pass+=(--agent "$agent"); fi
  _lt_say "[$id] running one headless objective in $wt (gate: ${check:-none})" \
          "[$id] the assistant is working on this task now (check before review: ${check:-none})" >&2
  rc=0
  ( cd "$wt" && bash "$_LT_LIB_DIR/../autopilot-run.sh" "${pass[@]}" ) >&2 || rc=$?

  if [ "$rc" -ne 0 ]; then
    # Say why in one line of our own: the run's "resume with" hint does not apply here, because a
    # re-run of `task run` starts over from the task record.
    reason=""; detail=""
    sfile="$(_lt_run_state_file "$wt" "$branch")"
    if [ -n "$sfile" ] && [ -f "$sfile" ]; then
      reason="$(jq -r '.reason // ""' "$sfile" 2>/dev/null || true)"
      detail="$(jq -r '.detail // ""' "$sfile" 2>/dev/null || true)"
    fi
    echo "✗ task $id: no review was opened — the run stopped with exit $rc${reason:+ (reason=$reason${detail:+: $detail})}. The work so far is kept in $wt; 'cckit task run $id' starts the task over from its record." >&2
    return "$rc"
  fi

  if [ "$finish" = 0 ]; then
    _lt_say "[$id] the run is done; --no-finish: nothing was sent for review. When ready: cckit task finish $id \"<summary>\" --all" \
            "[$id] the work is written; nothing was sent for review yet. When ready: cckit task finish $id \"<summary>\" --all" >&2
    echo "$wt|$branch|$id"
    return 0
  fi
  summary="Delegated with cckit task run: one headless round; gate: ${check:-none}$([ -n "$check" ] && printf ' (passed)' || true)."
  lt_finish "$id" "$summary" --all || return 7
}

# ── share ───────────────────────────────────────────────────────────────────────────────────────
# _lt_share_body <ids> <summary> — the share pull request's body.
_lt_share_body() {
  printf '## Tasks added\n\n%s\n\n## Summary\n\n%s\n\n## Review\n\nMerging adds these tasks to the shared list as `todo`. No work is included.\n' \
    "$(printf '%s\n' "$1" | sed 's/^/- `/; s/$/`/')" "$2"
}

lt_share() {
  local summary="" a root from base base_ref stamp branch wt ids n pr_title body rows
  for a in "$@"; do
    case "$a" in
      -h|--help) _lt_usage; return 0 ;;
      -*) echo "✗ task share: unknown flag '$a'" >&2; return 2 ;;
      *)  summary="${summary:+$summary }$a" ;;
    esac
  done
  if ! task_source_has share; then
    echo "✗ task share: the '$(task_source_name)' source has nothing to share — its tasks are not drafts in a checkout" >&2
    return 1
  fi
  root="$(_lt_root)"; from="$(_lt_top)"
  [ -n "$root" ] && [ -n "$from" ] || { echo "✗ task share: not inside a git repository" >&2; return 1; }
  base="$(_lt_base)"
  git -C "$root" fetch --quiet origin "$base" 2>/dev/null || true
  rows="$(task_source_call list)" || return 1
  n="$(printf '%s\n' "$rows" | awk -F'\t' '$2 == "draft"' | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    # Nothing new. A share branch of this repository whose tasks are not on the base branch yet is
    # an earlier share: its push or its pull request may have failed, so run that step again. An
    # open pull request is reported, not re-created.
    branch="$(printf '%s\n' "$rows" | awk -F'\t' '$2 == "shared" && $6 ~ /^light\/share-/ && !hit { print $6; hit = 1 }')"
    wt=""
    if [ -n "$branch" ]; then wt="$(_lt_worktree_of "$root" "$branch")"; fi
    if [ -z "$wt" ] || [ ! -d "$wt" ]; then echo "(no drafts to share in this checkout)"; return 0; fi
    ids="$(printf '%s\n' "$rows" | awk -F'\t' -v b="$branch" '$2 == "shared" && $6 == b { print $1 }')"
    n="$(printf '%s\n' "$ids" | grep -c . || true)"
    pr_title="$(git -C "$wt" log -1 --format=%s 2>/dev/null || true)"
    echo "[task] no new drafts; $n task(s) already committed on $branch" >&2
    _lt_open_pr "$wt" "$branch" "$pr_title" "$(_lt_share_body "$ids" "${summary:-Adds $n task(s) to the list.}")"
    return $?
  fi
  if git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$base"; then base_ref="origin/$base"
  else echo "✗ task share: origin has no branch '$base'" >&2; return 1; fi
  stamp="$(date +%Y%m%d%H%M%S)"
  branch="light/share-$stamp"
  wt="$root/.claude/worktrees/light+share-$stamp"
  git -C "$root" worktree add --no-track -b "$branch" "$wt" "$base_ref" >/dev/null 2>&1 \
    || { echo "✗ task share: worktree add failed for $branch" >&2; return 1; }
  ids="$(task_source_call share "$wt" "$from")" || true
  n="$(printf '%s\n' "$ids" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true
    git -C "$root" branch -D "$branch" >/dev/null 2>&1 || true
    echo "(no drafts to share: the task files here are already tracked by git)"; return 0
  fi
  pr_title="chore(tasks): add $n task$([ "$n" -eq 1 ] || echo s) [share-$stamp]"
  git -C "$wt" commit -q -m "$pr_title" >&2 || { echo "✗ task share: the commit failed in $wt" >&2; return 1; }
  body="$(_lt_share_body "$ids" "${summary:-Adds $n task(s) to the list.}")"
  echo "[task] moved $n draft(s) onto $branch — 'cckit task list' shows them as shared until the pull request merges" >&2
  _lt_open_pr "$wt" "$branch" "$pr_title" "$body"
}

# ── dispatcher ──────────────────────────────────────────────────────────────────────────────────
# With --llm: list and next print JSON themselves; the action verbs are wrapped into one object.
lt_cli() {
  local sub="${1:-}" out rc url rid
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    new)  lt_new "$@" ;;
    list|ls) lt_list "$@" ;;
    next) lt_next "$@" ;;
    start|take|finish|done|share|run)
      case "$sub" in take) sub="start" ;; done) sub="finish" ;; esac
      if cckit_is_json; then
        _LT_RUN_ID_FILE=""
        if [ "$sub" = run ]; then _LT_RUN_ID_FILE="$(mktemp 2>/dev/null || true)"; fi
        out="$("lt_$sub" "$@" 2>&1)" && rc=0 || rc=$?
        url="$(printf '%s\n' "$out" | grep -oE 'https://[^ ]+/pull/[0-9]+' | tail -1 || true)"
        if [ "$sub" = run ]; then
          rid=""
          if [ -n "$_LT_RUN_ID_FILE" ]; then rid="$(cat "$_LT_RUN_ID_FILE" 2>/dev/null || true)"; rm -f "$_LT_RUN_ID_FILE"; fi
          cckit_json verb "task run" ok "$([ "$rc" -eq 0 ] && echo true || echo false)" \
            id "$rid" url "$url" detail "$(printf '%s\n' "$out" | tail -1)"
        elif [ "$sub" = start ] && [ "$rc" -eq 0 ]; then
          out="$(printf '%s\n' "$out" | tail -1)"
          cckit_json verb "task start" ok true id "${out##*|}" worktree "${out%%|*}" \
            branch "$(printf '%s' "$out" | cut -d'|' -f2)"
        else
          cckit_json verb "task $sub" ok "$([ "$rc" -eq 0 ] && echo true || echo false)" \
            url "$url" detail "$(printf '%s\n' "$out" | tail -1)"
        fi
        return "$rc"
      fi
      "lt_$sub" "$@" ;;
    default)
      # Which list is this project's default (tasks.default). Read-only; no fetch, no gh.
      out="$(task_default_name)"
      if cckit_is_json; then cckit_json verb "task default" ok true default "$out"; else printf '%s\n' "$out"; fi ;;
    -h|--help|help) _lt_usage; return 0 ;;
    *) _lt_usage; return 2 ;;
  esac
}
