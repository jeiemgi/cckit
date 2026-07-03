#!/usr/bin/env bash
# shellcheck shell=bash
# effort-ops.sh — the effort lifecycle as shell ops, so `cckit effort new|start|pr|close` works from
# any shell or agent (not only via the effort-* skills). Thin: composes the git-mechanics helpers in
# effort.sh (linking, snapshots, title lint) plus gh + git. bash 3.2 compatible. Requires: gh, jq, git.
#
#   effort_new [flags] "<name>" [<sub spec> …]   parent (4-section body + labels) + native sub-issues
#   effort_start <slug|N> [<slug>]        effort/<N> branch + worktree from the base branch
#   effort_pr [<slug|N>]                  open the ONE PR effort/<N> → base branch
#   effort_close <slug|N>                 snapshot sub-diffs, squash-merge the PR, close parent + subs
#
# effort_new is the SHARED creation core (effort #98): both `cckit effort new` (the verb) and
# /kit-effort-new (the skill) call it, so they produce structurally identical efforts — one source of
# truth for body composition + the ctx/kind/priority/role/flow label set + per-sub title lint.
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

# Compose the four-section parent body (rules/effort-model.md): the sections double as the work
# record. An empty section falls back to its template placeholder so a bare call still yields the
# full four-heading scaffold; passing content fills it. $5 is an optional pre-built ## Relations block.
_eff_compose_body() {
  local goal="$1" scope="$2" for_agents="$3" verification="$4" relations="$5"
  cat <<EOF
## Goal
${goal:-<!-- problem statement: what outcome, in one or two lines -->}

## Scope
${scope:-<!-- the sub-issue plan; mark each parallel | sequential / dependsOn -->}

## For agents
${for_agents:-<!-- exact file paths / entry points a future agent needs -->}

## Verification
${verification:-<!-- how we know it is done: commands, checks, acceptance -->}${relations}
EOF
}

# Add an issue (by number) to the project board + set Status=Todo and the Role field. Guarded: a
# no-op unless Projects v2 is on AND the project helpers (gh-project.sh) are already sourced, so the
# verb can run from any shell with no board config. Mirrors the skill's old inline board block.
_eff_board_add() {
  local n="$1" role="${2:-}" repo node item ropt
  [ "${KIT_PROJECTS_V2:-}" = "true" ] || return 0
  command -v project_add_item >/dev/null 2>&1 || return 0
  repo="$(_eff_repo)"
  node="$(gh api "repos/$repo/issues/$n" --jq .node_id 2>/dev/null)" || return 0
  item="$(project_add_item "$node" 2>/dev/null)" || return 0
  [ -n "$item" ] || return 0
  [ -n "${STATUS_FIELD_ID:-}" ] && [ -n "${STATUS_OPT_TODO:-}" ] \
    && project_set_single_select "$item" "$STATUS_FIELD_ID" "$STATUS_OPT_TODO" 2>/dev/null || true
  if [ -n "$role" ] && command -v role_option_id >/dev/null 2>&1; then
    ropt="$(role_option_id "$role" 2>/dev/null || echo "")"
    [ -n "$ropt" ] && [ -n "${ROLE_FIELD_ID:-}" ] \
      && project_set_single_select "$item" "$ROLE_FIELD_ID" "$ropt" 2>/dev/null || true
  fi
  return 0
}

# effort_new [flags] "<name>" [<sub spec> …] — the shared creation core (effort #98).
# Flags (all optional): --flow F --role R --priority p1 --goal G --scope S --for-agents A
#   --verification V --depends-on "#1,#2" --milestone M --slug S.  A <sub spec> is "name :: one-line
#   desc" (the desc is optional → just "name"). Fills the four body sections, applies the
#   ctx/kind/priority/role/flow label set, lints the parent + EVERY sub title up front (so a bad sub
#   name aborts before anything is created), links native sub-issues, sets blocked_by edges, adds
#   everything to the board (guarded), and records the human slug handle (#93) as a slug:<slug> label.
#   Echoes the parent number on stdout.
effort_new() {
  _eff_need gh || return 1; _eff_need jq || return 1
  local repo; repo="$(_eff_repo)"
  [ -n "$repo" ] || { echo "effort_new: no repo (KIT_REPO/EFFORT_REPO unset — run in a kit project)" >&2; return 1; }

  local flow="" role="" priority="p1" goal="" scope="" for_agents="" verification="" depends_on="" milestone="" explicit_slug=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --flow)         flow="${2:-}"; shift 2 ;;
      --role)         role="${2:-}"; shift 2 ;;
      --priority)     priority="${2:-p1}"; shift 2 ;;
      --goal)         goal="${2:-}"; shift 2 ;;
      --scope)        scope="${2:-}"; shift 2 ;;
      --for-agents)   for_agents="${2:-}"; shift 2 ;;
      --verification) verification="${2:-}"; shift 2 ;;
      --depends-on)   depends_on="${2:-}"; shift 2 ;;
      --milestone)    milestone="${2:-}"; shift 2 ;;
      --slug)         explicit_slug="${2:-}"; shift 2 ;;
      --slug=*)       explicit_slug="${1#*=}"; shift ;;
      --)             shift; break ;;
      --*)            echo "effort_new: unknown flag $1" >&2; return 1 ;;
      *)              break ;;
    esac
  done

  local name="${1:-}"; shift || true
  [ -n "$name" ] || { echo 'effort_new: usage: effort_new [flags] "<name>" [<sub spec> …]' >&2; return 1; }

  # Optional leading [Flow] tag on the board title (validated by effort_title_lint).
  local flow_tag=""; [ -n "$flow" ] && flow_tag="[$flow] "

  # Guard the parent name against the title rule BEFORE creating anything (synthetic number — the
  # rule is about the NAME, not the not-yet-assigned N).
  effort_title_lint "[Effort] 0 · ${flow_tag}${name}" || { echo "effort_new: fix the name and retry" >&2; return 1; }

  # Lint EVERY sub title up front too (parity with the skill's intent) so a bad sub name fails the
  # whole op before a half-effort exists. Synthetic parent number 0 for the lint.
  local i=0 spec sub_name sub_title
  for spec in "$@"; do
    i=$((i + 1))
    sub_name="${spec%% :: *}"
    sub_title="[Effort 0] $i · $sub_name"
    effort_title_lint "$sub_title" \
      || { echo "effort_new: fix sub title #$i and retry: $sub_name" >&2; return 1; }
  done

  # Compose the four-section body + an optional ## Relations chain from --depends-on.
  local relations="" d
  if [ -n "$depends_on" ]; then
    relations="$(printf '\n\n## Relations\n')"
    for d in $(printf '%s' "$depends_on" | tr ',' ' '); do
      d="${d#\#}"; [ -n "$d" ] && relations="$relations$(printf -- '- Depends on #%s\n' "$d")"
    done
  fi
  local body; body="$(_eff_compose_body "$goal" "$scope" "$for_agents" "$verification" "$relations")"

  # Label set: ctx (session weight from the sub count) + kind + priority + optional role + optional flow.
  local subcount=$#; [ "$subcount" -ge 1 ] || subcount=1
  local ctx="ctx:S"
  command -v effort_ctx_bucket >/dev/null 2>&1 && ctx="$(effort_ctx_bucket 1 "$subcount")"
  local labels="$ctx,kind:task,priority:$priority"
  [ -n "$role" ] && labels="$labels,role:$role"
  [ -n "$flow" ] && labels="$labels,flow:$(printf '%s' "$flow" | tr '[:upper:]' '[:lower:]')"

  local url num slug
  url="$(gh issue create --repo "$repo" --title "[Effort] · ${flow_tag}${name}" --body "$body" \
        --label "$labels" ${milestone:+--milestone "$milestone"})" \
    || { echo "effort_new: failed to create the parent issue" >&2; return 1; }
  num="${url##*/}"
  gh issue edit "$num" --repo "$repo" --title "[Effort] $num · ${flow_tag}${name}" >/dev/null 2>&1
  # The human handle (#93): explicit --slug if given, else derived from the title (number/flow peeled).
  if [ -n "$explicit_slug" ]; then slug="$(_eff_slug "$explicit_slug")"
  else slug="$(_eff_title_slug "[Effort] $num · ${flow_tag}${name}")"; fi
  if [ -n "$slug" ]; then
    gh label create "slug:$slug" --repo "$repo" --color ededed \
      --description "effort slug handle" >/dev/null 2>&1 || true   # idempotent: ok if it exists
    gh issue edit "$num" --repo "$repo" --add-label "slug:$slug" >/dev/null 2>&1 || true
  fi
  echo "  ✓ effort $(effort_display "$num" "$slug") · ${flow_tag}${name}" >&2

  # Native dependency edges (the visible board chain) — guarded on the helper being available.
  if [ -n "$depends_on" ] && command -v effort_set_blocked_by >/dev/null 2>&1; then
    for d in $(printf '%s' "$depends_on" | tr ',' ' '); do
      d="${d#\#}"; [ -n "$d" ] && { effort_set_blocked_by "$num" "$d" || true; }
    done
  fi

  # Board: add the parent (guarded — no-op when Projects v2 is off / helpers not loaded).
  _eff_board_add "$num" "$role" || true

  # Create each sub-issue (titles already linted), native-link it, add it to the board.
  local sub_desc child child_num
  i=0
  for spec in "$@"; do
    i=$((i + 1))
    sub_name="${spec%% :: *}"
    sub_desc="${spec#* :: }"; [ "$sub_desc" = "$spec" ] && sub_desc=""
    sub_title="[Effort $num] $i · $sub_name"
    local sub_labels="kind:task,priority:$priority"
    [ -n "$role" ] && sub_labels="$sub_labels,role:$role"
    child="$(gh issue create --repo "$repo" --title "$sub_title" \
      --body "$(printf '%s\n\nSub-issue of #%s (effort).' "$sub_desc" "$num")" \
      --label "$sub_labels" ${milestone:+--milestone "$milestone"})" || continue
    child_num="${child##*/}"
    effort_link_sub "$num" "$child_num" || true
    _eff_board_add "$child_num" "$role" || true
    echo "  ✓ sub #$child_num · $sub_name" >&2
  done
  printf '%s\n' "$num"
}

# effort_start <slug|N> [<slug>] — create the effort/<N> integration branch + its worktree from base.
effort_start() {
  _eff_need git || return 1
  local raw="${1:-}" slug_override="${2:-}" num repo base root title slug branch wt
  [ -n "$raw" ] || { echo "effort_start: <slug|effort issue #> required" >&2; return 1; }
  num="$(effort_slug_resolve "$raw")" || { echo "effort_start: could not resolve '$raw' to an effort" >&2; return 1; }
  repo="$(_eff_repo)"; base="$(_eff_base)"
  root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
  [ -n "$root" ] || { echo "effort_start: not in a git repo" >&2; return 1; }

  if [ -n "$slug_override" ]; then slug="$(_eff_slug "$slug_override")"
  else
    title="$(gh issue view "$num" --repo "$repo" --json title -q .title 2>/dev/null)"
    slug="$(_eff_title_slug "${title:-effort}")"; [ -n "$slug" ] || slug="effort"
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
  echo "  ✓ effort $(effort_display "$num" "$slug") → $branch  (worktree: $wt)" >&2
  printf '%s|%s|%s\n' "$wt" "$branch" "$num"
}

# effort_pr [<slug|N>] — open the single PR effort/<N> → base. Defaults to the current effort branch.
effort_pr() {
  _eff_need gh || return 1
  local raw="${1:-}" num repo base branch title name
  repo="$(_eff_repo)"; base="$(_eff_base)"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -n "$raw" ]; then
    num="$(effort_slug_resolve "$raw")" || { echo "effort_pr: could not resolve '$raw' to an effort" >&2; return 1; }
  else
    num="$(effort_branch_num "$branch")"
  fi
  [ -n "$num" ] || { echo "effort_pr: not on an effort/<N>-… branch and no <slug|N> given" >&2; return 1; }
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
  local raw="${1:-}" num repo base branch
  [ -n "$raw" ] || { echo "effort_close: <slug|effort issue #> required" >&2; return 1; }
  num="$(effort_slug_resolve "$raw")" || { echo "effort_close: could not resolve '$raw' to an effort" >&2; return 1; }
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
