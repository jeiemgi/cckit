#!/usr/bin/env bash
# shellcheck shell=bash
# effort-ops.sh — the effort lifecycle as shell ops, so `cckit effort new|chain|start|pr|close` works
# from any shell or agent (not only via the effort-* skills). Thin: composes the git-mechanics helpers
# in effort.sh (linking, snapshots, title lint) plus gh + git. bash 3.2 compatible. Requires: gh, jq, git.
#
#   effort_new [flags] "<name>" [<sub spec> …]   parent (4-section body + labels) + native sub-issues
#   effort_chain <a> <b> [<c> …]          wire N issues into a linear blocked_by chain (#243)
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
# errors: mixed — lifecycle ops propagate; board + label side effects are best-effort

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
# full four-heading scaffold; passing content fills it. The `## Relations` chain is NOT composed
# here — it is layered on afterwards by _eff_relations_add (one formatter, #243).
_eff_compose_body() {
  local goal="$1" scope="$2" for_agents="$3" verification="$4"
  cat <<EOF
## Goal
${goal:-<!-- problem statement: what outcome, in one or two lines -->}

## Scope
${scope:-<!-- the sub-issue plan; mark each parallel | sequential / dependsOn -->}

## For agents
${for_agents:-<!-- exact file paths / entry points a future agent needs -->}

## Verification
${verification:-<!-- how we know it is done: commands, checks, acceptance -->}
EOF
}

# _eff_relations_add <body> <blocker> — echo <body> with `- Depends on #<blocker>` recorded in its
# `## Relations` section. THE one formatter for the human-readable dependency line (rules/
# effort-model.md): both `effort_new --depends-on` and `effort_chain` go through it, so the two
# produce byte-identical lines.
#
# Placement: appended to the END of an existing `## Relations` section (the lines before the next
# `## ` heading, or the end of the body); when the body has no such section, a new one is appended
# at the end of the body. IDEMPOTENT — a body that already carries the exact line comes back
# unchanged, so re-running never duplicates a line. Trailing blank lines are trimmed.
# Pure: no gh, no network — stdin-free, argument in / body out.
_eff_relations_add() {
  printf '%s\n' "$1" | awk -v dep="$2" '
    BEGIN { want = "- Depends on #" dep; rel = 0; have = 0 }
    {
      L[NR] = $0
      if (rel == 0 && $0 ~ /^[ \t]*##[ \t]+Relations[ \t]*$/) rel = NR
      t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
      if (t == want) have = 1
    }
    END {
      n = NR
      while (n > 0 && L[n] ~ /^[ \t]*$/) n--          # trim trailing blank lines
      if (have) { for (i = 1; i <= n; i++) print L[i]; exit }
      if (rel == 0) {                                  # no section yet → append one
        for (i = 1; i <= n; i++) print L[i]
        if (n > 0) print ""                            # no leading blank on an empty body
        print "## Relations"; print want
        exit
      }
      e = n                                            # end of the Relations section
      for (i = rel + 1; i <= n; i++) if (L[i] ~ /^##[ \t]/) { e = i - 1; break }
      while (e > rel && L[e] ~ /^[ \t]*$/) e--
      for (i = 1; i <= e; i++) print L[i]
      print want
      for (i = e + 1; i <= n; i++) print L[i]
    }
  '
}

# _eff_ensure_label <name> <color> <description> — make sure a kit-defined label exists in the repo
# before `gh issue create --label` uses it (which fails hard on a missing label, #153). Idempotent:
# creating an existing label is a silent no-op.
_eff_ensure_label() {
  gh label create "$1" --repo "$(_eff_repo)" --color "$2" \
    --description "$3" >/dev/null 2>&1 || true
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

  local flow="" role="" priority="p1" goal="" scope="" for_agents="" verification="" depends_on="" milestone="" explicit_slug="" par=""
  # Flags are position-INDEPENDENT: recognized --flag [value] pairs are consumed wherever they occur
  # (before the title, between subs, or after them) and the remaining positionals are collected as the
  # title (first) + sub specs (rest). Previously the parser broke at the first positional, so any flag
  # placed after the title was mis-read as a sub-issue spec — creating junk sub-issues. `--` forces
  # everything after it to be treated as positional (for a sub name that starts with a dash).
  local pos=()
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
      --par)          par="${2:-}"; shift 2 ;;
      --par=*)        par="${1#*=}"; shift ;;
      --)             shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      --*)            echo "effort_new: unknown flag $1" >&2; return 1 ;;
      *)              pos+=("$1"); shift ;;
    esac
  done
  set -- "${pos[@]+"${pos[@]}"}"

  # Parallelism hint label (#121): --par seq | wide | <positive-int> → a par:<value> label on the
  # parent (how the effort's subs are meant to run). Validated before anything is created.
  if [ -n "$par" ]; then
    case "$par" in
      seq|wide) : ;;
      ''|*[!0-9]*) echo "effort_new: --par must be 'seq', 'wide', or a positive integer (got '$par')" >&2; return 1 ;;
      *) : ;;
    esac
  fi

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

  # Compose the four-section body, then layer the ## Relations chain from --depends-on through the
  # ONE formatter (#243) — the same one `effort_chain` uses, so both write identical lines. (It was
  # built inline here before, and `$( … )` ate every newline: the section shipped as the single
  # mangled line `## Relations- Depends on #1- Depends on #2`.)
  local body d; body="$(_eff_compose_body "$goal" "$scope" "$for_agents" "$verification")"
  if [ -n "$depends_on" ]; then
    for d in $(printf '%s' "$depends_on" | tr ',' ' '); do
      d="${d#\#}"; [ -n "$d" ] && body="$(_eff_relations_add "$body" "$d")"
    done
  fi

  # Label set: ctx (session weight from the sub count) + kind + priority + optional role + optional flow.
  local subcount=$#; [ "$subcount" -ge 1 ] || subcount=1
  local ctx="ctx:S"
  command -v effort_ctx_bucket >/dev/null 2>&1 && ctx="$(effort_ctx_bucket 1 "$subcount")"
  # Every kit-defined label is ensured before use — `gh issue create --label` fails hard on a
  # missing label, which aborted the whole parent create on repos without the ctx:* set (#153).
  _eff_ensure_label "$ctx" bfd4f2 "effort session weight"
  _eff_ensure_label "kind:task" d4c5f9 "kit issue kind"
  _eff_ensure_label "priority:$priority" e99695 "kit priority"
  local labels="$ctx,kind:task,priority:$priority"
  if [ -n "$role" ]; then
    _eff_ensure_label "role:$role" 0e8a16 "kit role lane"
    labels="$labels,role:$role"
  fi
  if [ -n "$flow" ]; then
    local flow_lc; flow_lc="$(printf '%s' "$flow" | tr '[:upper:]' '[:lower:]')"
    _eff_ensure_label "flow:$flow_lc" 1d76db "kit flow lane"
    labels="$labels,flow:$flow_lc"
  fi
  if [ -n "$par" ]; then
    _eff_ensure_label "par:$par" c5def5 "effort parallelism hint"
    labels="$labels,par:$par"
  fi

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

# _eo_source_effort — lazily source the git-mechanics lib (effort.sh) so the ops that need
# effort_set_blocked_by work when effort-ops.sh is sourced on its own. No-op if already loaded.
_eo_source_effort() {
  command -v effort_set_blocked_by >/dev/null 2>&1 && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/effort.sh" ] && . "$d/effort.sh"
}

# _eff_blockers <issue> — echo the issue's CURRENT blocked_by numbers, one per line. Empty when the
# issue has no edges or the API call fails (the caller treats that as "no known edge").
_eff_blockers() {
  gh api "repos/$(_eff_repo)/issues/$1/dependencies/blocked_by" --jq '.[].number' 2>/dev/null || true
}

# _eff_chain_reaches <from> <target> <pending> — is <target> reachable from <from> by following
# blocked_by edges? Breadth-first over the COMBINED graph: the edges GitHub already holds plus
# <pending>, a space-separated list of `child>parent` pairs this call is about to write. Used as the
# cycle pre-flight: adding "<target> blocked_by <from>" closes a cycle exactly when <from> already
# depends (transitively) on <target>. rc 0 = reachable.
_eff_chain_reaches() {
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options ksh_arrays sh_word_split 2>/dev/null
  local from="$1" target="$2" pending="$3"
  local queue="$from" seen=" " cur b
  while [ -n "$queue" ]; do
    # shellcheck disable=SC2086
    set -- $queue; cur="$1"; shift; queue="$*"
    case "$seen" in *" $cur "*) continue ;; esac
    seen="$seen$cur "
    for b in $(_eff_blockers "$cur") \
             $(printf '%s\n' $pending | sed -n "s/^$cur>//p"); do
      [ "$b" = "$target" ] && return 0
      queue="$queue $b"
    done
  done
  return 1
}

# effort_chain <a> <b> [<c> …] — wire N issues into a LINEAR dependency chain (#243): B becomes
# blocked_by A, C blocked_by B, and so on, and each issue after the first gets a `- Depends on #<its
# predecessor>` line in its `## Relations` section. This is the verb that FEEDS `cckit plan` — the
# wave layering in plan-machine.sh reads exactly these `blocked_by` edges, so a chained set lands
# one issue per wave, in the order given.
#
# Everything is VALIDATED BEFORE ANYTHING IS WRITTEN (the effort_new discipline): a rejected chain
# leaves the board untouched. The rules:
#   arity        fewer than two numbers is a usage error — a chain needs a predecessor and a
#                successor. Nothing is written.
#   numbers      each arg is an issue number, with an optional leading `#`. Anything else is
#                rejected. Nothing is written.
#   existence    every issue is fetched first; a number that does not resolve aborts the whole
#                chain. Nothing is written.
#   cycles       a repeated number (`chain 1 2 1`) is refused — the chain would revisit a node. So
#                is a chain whose new edge closes a loop through edges GitHub ALREADY holds (the
#                pre-flight walks the combined graph). `cckit plan` cannot layer a cyclic graph into
#                waves, so a cycle is refused rather than written. Nothing is written.
#   pre-existing an issue already blocked by something else KEEPS that blocker: blocked_by is a set,
#     blockers  and this only ever ADDS its edge. The issue ends up with both.
#   idempotent   an edge that is already present is skipped (no duplicate POST, no error) and a body
#                that already carries the exact `- Depends on #N` line is left alone (no second
#                line, no `gh issue edit`). A re-run writes nothing and reports each half as
#                `already blocked_by` / `already records`.
# Progress goes to stderr; rc 0 only when every link of the chain is in place.
effort_chain() {
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options ksh_arrays sh_word_split 2>/dev/null
  _eff_need gh || return 1
  _eo_source_effort
  local repo; repo="$(_eff_repo)"
  [ -n "$repo" ] || { echo "effort_chain: no repo (KIT_REPO/EFFORT_REPO unset — run in a kit project)" >&2; return 1; }

  # 1. arity, shape, and repeats — all before a single write. `#12` and `12` are the same issue; a
  #    number that appears twice means the chain revisits a node, which is a cycle, not a chain.
  [ "$#" -ge 2 ] || { echo 'effort_chain: usage: effort_chain <a> <b> [<c> …]  (two or more issue numbers)' >&2; return 1; }
  local a n b list=""
  for a in "$@"; do
    n="${a#\#}"
    case "$n" in
      ''|*[!0-9]*) echo "effort_chain: '$a' is not an issue number — nothing written" >&2; return 1 ;;
    esac
    for b in $list; do
      [ "$b" = "$n" ] && { echo "effort_chain: #$n appears twice — that is a cycle, not a chain; nothing written" >&2; return 1; }
    done
    list="$list$n "
  done

  # 2. every issue must exist before a single edge is written.
  for n in $list; do
    gh api "repos/$repo/issues/$n" --jq .number >/dev/null 2>&1 \
      || { echo "effort_chain: #$n does not exist in $repo — nothing written" >&2; return 1; }
  done

  # 3. cycle pre-flight over the existing graph PLUS the edges this call would add. Adding
  #    "next blocked_by prev" closes a loop exactly when prev already depends on next.
  local pending="" prev="" next
  for next in $list; do
    if [ -n "$prev" ] && _eff_chain_reaches "$prev" "$next" "$pending"; then
      echo "effort_chain: #$next blocked_by #$prev would create a dependency cycle — nothing written" >&2
      return 1
    fi
    [ -n "$prev" ] && pending="$pending$next>$prev "
    prev="$next"
  done

  # 4. write. Per link: the native blocked_by edge and the `Depends on` line, each skipped when it
  #    is already there — so a re-run reports and touches nothing.
  local rc=0 have body newbody
  prev=""
  for next in $list; do
    if [ -n "$prev" ]; then
      have=""
      for b in $(_eff_blockers "$next"); do [ "$b" = "$prev" ] && have=1; done
      if [ -n "$have" ]; then
        echo "  · #$next already blocked_by #$prev" >&2
      else
        effort_set_blocked_by "$next" "$prev" || rc=1
      fi

      # A FAILED read is not an empty body: writing the composed body after a failed fetch would
      # wipe the issue. Only a successful read is edited.
      if ! body="$(gh issue view "$next" --repo "$repo" --json body --jq .body 2>/dev/null)"; then
        echo "  ✗ could not read #$next's body — 'Depends on #$prev' not recorded" >&2; rc=1
      elif printf '%s\n' "$body" | grep -qE "^[[:space:]]*- Depends on #${prev}[[:space:]]*$"; then
        echo "  · #$next already records 'Depends on #$prev'" >&2
      else
        newbody="$(_eff_relations_add "$body" "$prev")"
        gh issue edit "$next" --repo "$repo" --body "$newbody" >/dev/null 2>&1 \
          && echo "  ✓ #$next records 'Depends on #$prev'" >&2 \
          || { echo "  ✗ could not update #$next's body" >&2; rc=1; }
      fi
    fi
    prev="$next"
  done

  echo "  ✓ chain $(printf '#%s → ' $list | sed 's/ → $//')" >&2
  return "$rc"
}

# _eo_source_wt — lazily source the worktree mechanic (worktree-start.sh) so effort_start gets the
# SAME full worktree setup as `cckit start`: wt_bootstrap (env-file copy + per-worktree dev port +
# dependency install) and the _wt_session_owns collision guard. bin/cckit's `effort` verb does not
# load it, so effort-ops brings it in on demand (#119). No-op if already loaded.
_eo_source_wt() {
  command -v wt_bootstrap >/dev/null 2>&1 && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/worktree-start.sh" ] && . "$d/worktree-start.sh"
}

# effort_start <slug|N> [<slug>] — create the effort/<N> integration branch + its worktree from base,
# with the full `cckit start` worktree setup (env copy, per-worktree dev port, dependency install —
# opt out with KIT_WT_INSTALL=0) and a live-session collision guard.
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
  # Worktree dir follows the kind+N-slug convention (branch-naming.md) so kit-gc's issue-open
  # protection recognizes it by DIRECTORY name too — matching the kit-effort-start skill (#119).
  branch="effort/$num-$slug"; wt="$root/.claude/worktrees/effort+$num-$slug"

  _eo_source_wt

  # Session-collision precheck: never disturb a worktree a LIVE session is sitting in (its work may
  # be uncommitted). Guarded on the helper being available.
  if [ -d "$wt" ] && command -v _wt_session_owns >/dev/null 2>&1 && _wt_session_owns "$root" "$wt"; then
    echo "effort_start: a live session owns $wt — refusing to disturb it" >&2; return 1
  fi

  git -C "$root" fetch origin "$base" --quiet 2>/dev/null || true
  if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
    echo "effort_start: branch $branch already exists" >&2
  else
    local from="origin/$base"; git -C "$root" rev-parse --verify --quiet "$from" >/dev/null 2>&1 || from="$base"
    git -C "$root" worktree add -b "$branch" "$wt" "$from" >/dev/null 2>&1 \
      || { echo "effort_start: failed to create worktree for $branch" >&2; return 1; }
  fi

  # Bootstrap the worktree for local dev: copy gitignored env, assign a per-worktree dev port, and
  # install deps (KIT_WT_INSTALL=0 opts out). Best-effort — a hiccup never fails the start.
  command -v wt_bootstrap >/dev/null 2>&1 && wt_bootstrap "$root" "$wt" "$num" || true

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
  # ONE shared composer (effort.sh) so the verb + the kit-effort-pr skill title identically, then the
  # mandatory-[#N] check before we ever call gh — refuse rather than open an id-less PR (#121).
  local pr_title; pr_title="$(effort_pr_title "$num" "${name:-effort}")"
  effort_pr_title_check "$pr_title" "$num" || { echo "effort_pr: refusing to open a PR without the [#$num] effort id" >&2; return 1; }
  gh pr create --repo "$repo" --base "$base" --head "$branch" \
    --title "$pr_title" \
    --body "$(printf 'Closes the #%s effort.\n\n## For agents\nSee #%s for the goal, scope, and entry points.\n' "$num" "$num")"
}

# _eo_source_metrics — lazily source effort-metrics.sh so effort_close can call the shipped
# capture/judge/sync functions even when only effort-ops is loaded (bin/cckit sources it for the
# effort verb; this makes the composition robust + testable). No-op if already loaded.
_eo_source_metrics() {
  command -v capture_effort_metrics >/dev/null 2>&1 && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/effort-metrics.sh" ] && . "$d/effort-metrics.sh"
}

# _eo_source_board — lazily source the board helpers (gh-project.sh) + captured field ids so
# effort_close can set Status=Done from any shell, with no caller wiring (bin/cckit sources the
# board helpers only for `effort new`). Guarded: a no-op unless Projects v2 is on; a missing
# gh-project.sh or ids file degrades to a no-op (the board steps below are themselves guarded).
_eo_source_board() {
  [ "${KIT_PROJECTS_V2:-}" = "true" ] || return 0
  if ! command -v project_find_item_by_issue >/dev/null 2>&1; then
    local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    # shellcheck source=/dev/null
    [ -f "$d/gh-project.sh" ] && . "$d/gh-project.sh"
  fi
  if [ -z "${STATUS_FIELD_ID:-}" ] && command -v load_project_ids >/dev/null 2>&1; then
    load_project_ids >/dev/null 2>&1 || true
  fi
  return 0
}

# _eo_board_done <issue #> — set the board Status=Done for one issue. Guarded like _eff_board_add:
# a no-op unless Projects v2 is on AND the board helpers + field ids are loaded. Best-effort — a
# board hiccup never fails the close (the merge already landed).
_eo_board_done() {
  local n="$1" item
  [ "${KIT_PROJECTS_V2:-}" = "true" ] || return 0
  command -v project_find_item_by_issue >/dev/null 2>&1 || return 0
  [ -n "${STATUS_FIELD_ID:-}" ] && [ -n "${STATUS_OPT_DONE:-}" ] || return 0
  item="$(project_find_item_by_issue "$n" 2>/dev/null)" || return 0
  [ -n "$item" ] || { echo "  ⚠ #$n not on board — skipped" >&2; return 0; }
  project_set_single_select "$item" "$STATUS_FIELD_ID" "$STATUS_OPT_DONE" 2>/dev/null \
    && echo "  ✓ board Done: #$n" >&2 || true
  return 0
}

# Kit-managed paths (the kit ⇄ project sync surface): a change here that is not contributed
# upstream (/kit-contribute) is a latent regression the next /kit-update can clobber. One place —
# effort_close's drift check greps against this (was inlined in the kit-effort-close skill, #148).
_EO_KIT_MANAGED_RE='^(scripts/(lib/|kit$|kit-)|\.claude/(skills|rules|hooks|lib|agents)/)'

# _eo_knowledge_ingest <num> <trace_dir> <root> — optional post-close knowledge-ingest hook. Runs a
# project-configured command (github/effort.knowledgeIngestHook, or KIT_EFFORT_KNOWLEDGE_HOOK) with
# the effort number + trace dir, so a project can fold the closed effort's work record into its
# knowledge base. Config-gated: a NO-OP when unset or the hook file is missing/not executable — the
# kit ships no default hook. Best-effort — a hook failure never fails the close.
_eo_knowledge_ingest() {
  local num="$1" trace="$2" root="$3" hook="" cfg
  hook="${KIT_EFFORT_KNOWLEDGE_HOOK:-}"
  if [ -z "$hook" ]; then
    cfg="${KIT_CONFIG:-}"; [ -n "$cfg" ] || { [ -f "$root/cckit.config.json" ] && cfg="$root/cckit.config.json" || cfg="$root/.claude/kit.config.json"; }
    [ -f "$cfg" ] && command -v jq >/dev/null 2>&1 \
      && hook="$(jq -r '.effort.knowledgeIngestHook // empty' "$cfg" 2>/dev/null)"
  fi
  [ -n "$hook" ] || return 0
  case "$hook" in /*) : ;; *) hook="$root/$hook" ;; esac   # resolve a relative hook against the root
  [ -x "$hook" ] || { echo "effort_close: knowledge-ingest hook '$hook' not executable — skipping" >&2; return 0; }
  echo "  → knowledge-ingest hook: $hook $num" >&2
  "$hook" "$num" "$trace" >/dev/null 2>&1 || echo "effort_close: knowledge-ingest hook failed (non-fatal)" >&2
}

# effort_close <N> — the SINGLE close implementation (#148): the /kit-effort-close skill is a thin
# caller of this function, never a second close. Snapshot per-sub diffs + capture metrics BEFORE the
# squash (the squash erases the per-sub history), REFUSE to squash if no work trace was captured
# (KIT_FORCE=1 overrides), squash-merge, judge + sync the metrics, close parent + subs, set the board
# Status=Done for each (guarded), GC the worktree/branch, run the optional knowledge-ingest hook,
# and finish with the advisory kit-sync drift check. Destructive: it merges, closes, and prunes.
effort_close() {
  _eff_need gh || return 1; _eff_need jq || return 1
  local raw="${1:-}" num repo base branch root self_wt trace_dir kit_touched
  [ -n "$raw" ] || { echo "effort_close: <slug|effort issue #> required" >&2; return 1; }
  num="$(effort_slug_resolve "$raw")" || { echo "effort_close: could not resolve '$raw' to an effort" >&2; return 1; }
  repo="$(_eff_repo)"; base="$(_eff_base)"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$branch" in
    effort/"$num"-*) : ;;
    *)
      # Not on the integration branch. If effort/<num>-… exists (locally or on origin), this is
      # just the wrong cwd — keep the instruction. If it exists NOWHERE, this is a WAVE-style
      # effort (#164): the subs shipped as individual task PRs squash-merged straight to base, so
      # there is no branch to run from — close via the merged sub PRs instead.
      if git branch --list "effort/$num-*" 2>/dev/null | grep -q . \
         || git ls-remote --heads origin "effort/$num-*" 2>/dev/null | grep -q .; then
        echo "effort_close: run from the effort/$num-… branch" >&2; return 1
      fi
      _eo_close_wave "$num" "$repo" "$base"; return $? ;;
  esac
  root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
  self_wt="$(git rev-parse --show-toplevel 2>/dev/null)"
  _eo_source_metrics

  # (a) snapshot the per-sub-issue diffs while the unsquashed history still exists (echoes the trace dir).
  trace_dir="$(effort_snapshot_subs "$num" "origin/$base" 2>/dev/null)"

  # (a2) refuse-squash-without-trace backstop: the squash is irreversible and collapses the per-sub
  # commits that ARE the work record. If nothing was snapshotted, refuse — unless KIT_FORCE=1.
  if [ -z "$trace_dir" ] || ! ls "$trace_dir"/*.diff >/dev/null 2>&1; then
    if [ "${KIT_FORCE:-0}" = "1" ]; then
      echo "effort_close: no per-sub work trace captured — proceeding anyway (KIT_FORCE=1)" >&2
    else
      echo "effort_close: refusing to squash-merge #$num — no per-sub work trace was captured; the squash would erase the per-sub history irrecoverably. Run from the effort branch with its commits present, or set KIT_FORCE=1 to override." >&2
      return 1
    fi
  fi

  # (b) capture effort metrics PRE-squash (needs the live-branch diff + commit signals).
  command -v capture_effort_metrics >/dev/null 2>&1 && capture_effort_metrics "$num" "origin/$base" || true

  # (b2) record which kit-managed files this effort touched, PRE-squash (the branch is GC'd below,
  # so the live-branch diff is the reliable source). The warning itself is emitted last (step h).
  kit_touched="$(git diff --name-only "origin/$base"...HEAD 2>/dev/null \
    | grep -E "$_EO_KIT_MANAGED_RE" | sort -u || true)"

  # (c) squash-merge the effort PR.
  gh pr merge "$branch" --repo "$repo" --squash --delete-branch >/dev/null 2>&1 \
    || { echo "effort_close: could not squash-merge the PR for $branch (open? mergeable?)" >&2; return 1; }
  echo "  ✓ merged $branch" >&2

  # (d) judge + sync the metrics (judge reads the durable trace dir; sync no-ops when the engine is off).
  command -v judge_effort_metrics >/dev/null 2>&1 && judge_effort_metrics "$num" "origin/$base" || true
  command -v sync_effort_metrics  >/dev/null 2>&1 && sync_effort_metrics  "$num" || true

  # (e) close every native sub-issue, then the parent — and set the board Status=Done for each
  # (guarded: a no-op when Projects v2 is off or the board helpers/ids are unavailable). Board +
  # issue + record state are owned by this ONE op (effort-model.md) — never a separate "mark done".
  _eo_source_board
  local sub
  for sub in $(gh api "repos/$repo/issues/$num/sub_issues" --jq '.[].number' 2>/dev/null); do
    gh issue close "$sub" --repo "$repo" --reason completed >/dev/null 2>&1 && echo "  ✓ closed sub #$sub" >&2
    _eo_board_done "$sub"
  done
  gh issue close "$num" --repo "$repo" --reason completed >/dev/null 2>&1 && echo "  ✓ closed effort #$num" >&2
  _eo_board_done "$num"

  # (f) GC: switch the main checkout to base, remove the effort worktree, delete the local branch,
  # prune. The remote branch was deleted by --delete-branch above. All via `git -C "$root"` so the
  # caller's cwd is never moved. Best-effort — a GC hiccup never fails the (already-landed) close.
  if [ -n "$root" ]; then
    git -C "$root" checkout "$base" >/dev/null 2>&1 || true
    git -C "$root" pull origin "$base" --quiet >/dev/null 2>&1 || true
    if [ -n "$self_wt" ] && [ "$self_wt" != "$root" ]; then
      case "$self_wt" in "$root"/.claude/worktrees/*)
        git -C "$root" worktree remove "$self_wt" --force >/dev/null 2>&1 && echo "  ✓ removed worktree $self_wt" >&2 ;;
      esac
    fi
    git -C "$root" branch -D "$branch" >/dev/null 2>&1 && echo "  ✓ deleted local branch $branch" >&2
    git -C "$root" worktree prune >/dev/null 2>&1 || true
  fi

  # (g) optional, config-gated knowledge-ingest hook (no-op when absent).
  _eo_knowledge_ingest "$num" "${trace_dir:-}" "$root"

  # (h) kit-sync drift check — kit ⇄ project stay in sync (#148, moved here from the skill).
  _eo_kit_sync_warn "$kit_touched"
}

# _eo_kit_sync_warn <files> — the advisory kit-sync drift warning, shared by both close styles
# (#148/#164). If an effort changed kit-managed files they likely belong upstream (/kit-contribute);
# an un-upstreamed change is a latent regression the next /kit-update can clobber. Never blocks.
_eo_kit_sync_warn() {
  [ -n "${1:-}" ] || return 0
  {
    echo ""
    echo "  ⚠ kit-sync: this effort changed kit-managed files — review for upstream (/kit-contribute):"
    printf '%s\n' "$1" | sed 's/^/     /'
    echo "     kit ⇄ project must stay in sync; an un-upstreamed change can be clobbered by /kit-update."
  } >&2
}

# _eo_close_wave <num> <repo> <base> — close a WAVE-style effort (#164): every sub was delivered as
# its own task PR squash-merged straight to base (`cckit wave` → fan-out → `cckit watch --merge`),
# so no effort/<N> integration branch ever existed. Verifies every sub is CLOSED with a merged
# closing PR (refuses and lists the stragglers otherwise), snapshots the work trace from the merged
# sub PR diffs, then runs the SAME close tail as the branch path: judge + sync metrics, close the
# parent, board Status=Done for parent + subs, knowledge-ingest hook, kit-sync drift check.
# capture_effort_metrics is intentionally skipped — there is no live branch diff to measure; the
# merged PR diffs in the trace are the work record.
_eo_close_wave() {
  local num="$1" repo="$2" base="$3" root rows bad trace_dir kit_touched sub
  root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}')"
  _eo_source_metrics

  # (a) read every sub + the merged PR that closed it, one "sub|state|pr|merge-oid|title" line each
  # (title LAST so a stray "|" in it can't shift the fields awk/read split on).
  rows="$(gh api graphql -f query='
    query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ issue(number:$n){
      subIssues(first:50){ nodes { number state
        closedByPullRequestsReferences(first:10){ nodes { number merged mergeCommit{oid} title } } } } } } }' \
    -F o="${repo%/*}" -F r="${repo#*/}" -F n="$num" --jq '
      .data.repository.issue.subIssues.nodes[]
      | (((.closedByPullRequestsReferences.nodes // []) | map(select(.merged)) | .[0]) // null) as $pr
      | "\(.number)|\(.state)|\($pr.number // "")|\($pr.mergeCommit.oid // "")|\($pr.title // "")"' 2>/dev/null)"
  [ -n "$rows" ] || { echo "effort_close: no effort/$num-… branch and no readable sub-issues — nothing to close (wave-style needs merged subs, #164)" >&2; return 1; }

  # (b) every sub must be CLOSED with a merged closing PR — otherwise the effort is not done.
  bad="$(printf '%s\n' "$rows" | awk -F'|' '$2 != "CLOSED" || $3 == "" {
    printf "  #%s (%s%s)\n", $1, tolower($2), ($3 == "" ? ", no merged PR" : "") }')"
  if [ -n "$bad" ]; then
    echo "effort_close: #$num is not done — these subs are still open or lack a merged PR:" >&2
    printf '%s\n' "$bad" >&2
    return 1
  fi

  # (c) the work trace, from the merged sub PR diffs (the record the per-sub squashes left behind).
  # Same refuse-without-trace backstop as the branch path (#120) — KIT_FORCE=1 overrides.
  trace_dir="$(effort_snapshot_merged_subs "$num" "$rows" 2>/dev/null)"
  if [ -z "$trace_dir" ] || ! ls "$trace_dir"/*.diff >/dev/null 2>&1; then
    if [ "${KIT_FORCE:-0}" = "1" ]; then
      echo "effort_close: no per-sub work trace captured — proceeding anyway (KIT_FORCE=1)" >&2
    else
      echo "effort_close: refusing to close #$num — could not capture the work trace from the merged sub PRs. Set KIT_FORCE=1 to override." >&2
      return 1
    fi
  fi

  # (d) judge + sync the metrics off the trace (guarded, best-effort — same as the branch path).
  command -v judge_effort_metrics >/dev/null 2>&1 && judge_effort_metrics "$num" "origin/$base" || true
  command -v sync_effort_metrics  >/dev/null 2>&1 && sync_effort_metrics  "$num" || true

  # (e) kit-sync drift source: the union of files across the merged sub PR diffs.
  kit_touched="$(awk '/^diff --git /{print $3}' "$trace_dir"/*.diff 2>/dev/null | sed 's#^a/##' \
    | grep -E "$_EO_KIT_MANAGED_RE" | sort -u || true)"

  # (f) close the parent + board Status=Done for parent and every sub (subs are already closed).
  _eo_source_board
  for sub in $(printf '%s\n' "$rows" | cut -d'|' -f1); do
    _eo_board_done "$sub"
  done
  gh issue close "$num" --repo "$repo" --reason completed >/dev/null 2>&1 && echo "  ✓ closed effort #$num" >&2
  _eo_board_done "$num"

  # (g) GC: the sub branches/worktrees were GC'd by their own merges — just prune stragglers.
  [ -n "$root" ] && git -C "$root" worktree prune >/dev/null 2>&1 || true

  # (h) same optional hook + advisory drift check as the branch path.
  _eo_knowledge_ingest "$num" "${trace_dir:-}" "$root"
  _eo_kit_sync_warn "$kit_touched"
}
