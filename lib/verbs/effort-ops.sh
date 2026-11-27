#!/usr/bin/env bash
# shellcheck shell=bash
# effort-ops.sh — the effort lifecycle as shell ops, so `cckit effort new|chain|start|pr|close` works
# from any shell or agent (not only via the effort-* skills). Thin: composes the git-mechanics helpers
# in effort.sh (linking, snapshots, title lint) plus gh + git. bash 3.2 compatible. Requires: gh, jq, git.
#
#   effort_new [flags] "<name>" [<sub spec> …]   parent (5-section body + labels) + native sub-issues;
#                                         --grilling[-file] appends a linted `## Grilling` record;
#                                         --sprint[=YYYY-MM-DD] files it into that week's sprint
#   effort_sub <slug|N> "<name>" [--kind K]      add one sub-issue, titled [E<N>.<step>] <name>
#   effort_retitle [<slug|N>] [--apply]          rename legacy [Effort] titles (dry run by default)
#   effort_chain <a> <b> [<c> …]          wire N issues into a linear blocked_by chain (#243)
#   effort_start [--force] <slug|N> [<slug>]  effort/<N> branch + worktree from base, WIP-limited (#244)
#   effort_pr [<slug|N>]                  open the ONE PR effort/<N> → base branch
#   effort_close <slug|N> [--no-spec-check]  check the Spec, snapshot sub-diffs, squash-merge, delete the
#                                         effort branch and every sub/<N><letter>-* branch on origin,
#                                         close the parent + its subs, GC the worktrees + local branches
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
# The forge port (E537): every GitHub call goes through forge_* / gh_rest_* (lib/forge/gh-rest.sh).
if ! command -v gh_rest_issue_json >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)/forge/gh-rest.sh"
fi

if ! command -v effort_slug_resolve >/dev/null 2>&1; then
  _eo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$_eo_dir/../core/effort-slug.sh" ] && . "$_eo_dir/../core/effort-slug.sh"
  unset _eo_dir
fi

# The one title convention (naming.sh, E546.1): every title effort_new / effort_sub / effort_pr
# writes is linted there first, and every title read back is stripped there.
if ! command -v naming_title_lint >/dev/null 2>&1; then
  _eo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$_eo_dir/../core/naming.sh" ] && . "$_eo_dir/../core/naming.sh"
  unset _eo_dir
fi

# The `## Spec` check (spec-lint.sh, E546.5): effort_new lints the body it composed, effort_close
# the body it reads back.
if ! command -v spec_lint >/dev/null 2>&1; then
  _eo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$_eo_dir/../core/spec-lint.sh" ] && . "$_eo_dir/../core/spec-lint.sh"
  unset _eo_dir
fi

# The `## Grilling` record check (grill-record.sh, E547.2): effort_new lints --grilling before writing.
if ! command -v grill_record_lint >/dev/null 2>&1; then
  _eo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$_eo_dir/grill-record.sh" ] && . "$_eo_dir/grill-record.sh"
  unset _eo_dir
fi

# The sprint (sprint.sh, #570): effort_new --sprint files the effort into the current week's sprint.
if ! command -v sprint_name >/dev/null 2>&1; then
  _eo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$_eo_dir/sprint.sh" ] && . "$_eo_dir/sprint.sh"
  unset _eo_dir
fi

# The closed kind: vocabulary (KIT_KINDS / kit_kind_valid) — what `effort new --kind` accepts.
if ! command -v kit_kind_valid >/dev/null 2>&1; then
  _eo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$_eo_dir/../core/kinds.sh" ] && . "$_eo_dir/../core/kinds.sh"
  unset _eo_dir
fi

# The GitHub transport switch (#396): in rest mode the lifecycle calls below are `forge_rest repos/…`.
if ! command -v cckit_gh_rest >/dev/null 2>&1; then
  _eo_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$_eo_dir/../forge/gh-rest.sh" ] && . "$_eo_dir/../forge/gh-rest.sh"
  unset _eo_dir
fi
command -v cckit_gh_rest >/dev/null 2>&1 || cckit_gh_rest() { return 1; }
command -v cckit_board_skipped >/dev/null 2>&1 || cckit_board_skipped() { return 1; }

_eff_repo()  { printf '%s' "${EFFORT_REPO:-${KIT_REPO:-}}"; }
_eff_base()  { printf '%s' "${KIT_BASE_BRANCH:-main}"; }
_eff_need()  { command -v "$1" >/dev/null 2>&1 || { echo "effort: $1 is required" >&2; return 1; }; }
# _eff_forge — rc 0 with a forge; without one, forge_need's one line (naming the verb), rc 1.
_eff_forge() { forge_need; }

# Compose the five-section parent body (rules/effort-model.md): the sections double as the work
# record. An empty section falls back to its template placeholder so a bare call still yields the
# full scaffold; passing content fills it. The Spec is built by spec_section (plain lines become
# bullets); an empty one keeps only its hint, which spec_lint refuses. The `## Relations` chain is
# NOT composed here — it is layered on afterwards by _eff_relations_add (one formatter, #243).
_eff_compose_body() {
  local goal="$1" scope="$2" for_agents="$3" verification="$4" spec="${5:-}" spec_md
  if [ -n "$spec" ]; then spec_md="$(spec_section "$spec")"
  else spec_md="$(printf '## Spec\n<!-- what done means: a checkable list, one item per line -->')"; fi
  cat <<EOF
## Goal
${goal:-<!-- problem statement: what outcome, in one or two lines -->}

${spec_md}

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
  gh_rest_label_create "$(_eff_repo)" "$1" "$2" "$3"; return 0
}

# Add an issue (by number) to the project board + set Status=Todo and the Role field. Guarded: a
# no-op unless Projects v2 is on AND the project helpers (gh-project.sh) are already sourced, so the
# verb can run from any shell with no board config. Mirrors the skill's old inline board block.
_eff_board_add() {
  local n="$1" role="${2:-}" repo node item ropt
  [ "${KIT_PROJECTS_V2:-}" = "true" ] || return 0
  cckit_board_skipped && return 0
  command -v project_add_item >/dev/null 2>&1 || return 0
  repo="$(_eff_repo)"
  node="$(forge_rest "repos/$repo/issues/$n" --jq .node_id 2>/dev/null)" || return 0
  item="$(project_add_item "$node" "$repo" "$n" Issue 2>/dev/null)" || return 0
  [ -n "$item" ] || return 0
  [ -n "${STATUS_FIELD_ID:-}" ] && [ -n "${STATUS_OPT_TODO:-}" ] \
    && project_set_single_select "$item" "$STATUS_FIELD_ID" "$STATUS_OPT_TODO" 2>/dev/null || true
  if [ -n "$role" ] && [ -n "${ROLE_FIELD_ID:-}" ] && command -v role_option_id >/dev/null 2>&1; then
    ropt="$(role_option_id "$role" || echo "")"
    [ -n "$ropt" ] && [ -n "${ROLE_FIELD_ID:-}" ] \
      && project_set_single_select "$item" "$ROLE_FIELD_ID" "$ropt" 2>/dev/null || true
  fi
  return 0
}

# effort_new [flags] "<name>" [<sub spec> …] — the shared creation core (effort #98).
# Flags: --spec T | --spec-file F (required: what done means, checked by spec_lint before any forge
#   write); optional --flow F --role R --priority p1 --goal G --scope S --for-agents A
#   --verification V --depends-on "#1,#2" --milestone M --slug S.  A <sub spec> is "name :: one-line
#   desc" (the desc is optional → just "name"). Fills the five body sections, applies the
#   ctx/kind/priority/role/flow label set, lints the parent + EVERY sub title up front (so a bad sub
#   name aborts before anything is created), links native sub-issues, sets blocked_by edges, adds
#   everything to the board (guarded), and records the human slug handle (#93) as a slug:<slug> label.
#   Echoes the parent number on stdout.
effort_new() {
  _eff_forge || return 1; _eff_need jq || return 1
  local repo; repo="$(_eff_repo)"
  [ -n "$repo" ] || { echo "effort_new: no repo (KIT_REPO/EFFORT_REPO unset — run in a kit project)" >&2; return 1; }

  local flow="" role="" priority="p1" goal="" scope="" for_agents="" verification="" depends_on="" milestone="" explicit_slug="" kind="task" spec_text="" grilling="" sprint_day=""
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
      --spec)         spec_text="${2:-}"; shift 2 ;;
      --spec=*)       spec_text="${1#*=}"; shift ;;
      --spec-file)
        [ -r "${2:-}" ] || { echo "effort_new: --spec-file: cannot read '${2:-}'" >&2; return 1; }
        spec_text="$(cat "$2")"; shift 2 ;;
      --grilling)     grilling="${2:-}"; shift 2 ;;
      --grilling-file)
        [ -r "${2:-}" ] || { echo "effort_new: --grilling-file: cannot read '${2:-}'" >&2; return 1; }
        grilling="$(cat "$2")"; shift 2 ;;
      --sprint)       sprint_day="today"; shift ;;
      --sprint=*)     sprint_day="${1#*=}"; shift ;;
      --depends-on)   depends_on="${2:-}"; shift 2 ;;
      --milestone)    milestone="${2:-}"; shift 2 ;;
      --slug)         explicit_slug="${2:-}"; shift 2 ;;
      --slug=*)       explicit_slug="${1#*=}"; shift ;;
      --kind)         kind="${2:-}"; shift 2 ;;
      --kind=*)       kind="${1#*=}"; shift ;;
      --)             shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      --*)            echo "effort_new: unknown flag $1" >&2; return 1 ;;
      *)              pos+=("$1"); shift ;;
    esac
  done
  set -- "${pos[@]+"${pos[@]}"}"

  # --kind picks the kind:<k> label on the parent and every sub (default task). It is validated
  # against the closed set (kinds.sh) before anything is created: `cckit start` turns the label into
  # the branch prefix, so a value outside the set would yield a branch the hygiene hook rejects.
  if command -v kit_kind_label_valid >/dev/null 2>&1 && ! kit_kind_label_valid "$kind"; then
    echo "effort_new: --kind must be one of: $KIT_KINDS $KIT_CONTENT_KINDS (got '$kind')" >&2; return 1
  fi
  [ -n "$kind" ] || { echo "effort_new: --kind needs a value" >&2; return 1; }

  local name="${1:-}"; shift || true
  [ -n "$name" ] || { echo 'effort_new: usage: effort_new [flags] "<name>" [<sub spec> …]' >&2; return 1; }

  # The title is `[E<n>] <name>` (rules/naming-and-ids.md, E546.1): the flow lives in the flow:
  # label, so no [Flow] tag is written into the title any more. Lint the parent name BEFORE creating
  # anything (synthetic number 0: the rule is about the NAME, not the not-yet-assigned N).
  naming_title_lint effort "$(naming_effort_title 0 "$name")" || { echo "effort_new: fix the name and retry" >&2; return 1; }

  # Lint EVERY sub title up front too, so a bad sub name fails the whole op before a half-effort
  # exists. Synthetic parent number 0 for the lint.
  local i=0 spec sub_name sub_title
  for spec in "$@"; do
    i=$((i + 1))
    sub_name="${spec%% :: *}"
    sub_title="$(naming_sub_title 0 "$i" "$sub_name")"
    naming_title_lint sub "$sub_title" \
      || { echo "effort_new: fix sub title #$i and retry: $sub_name" >&2; return 1; }
  done

  # Compose the five-section body, then layer the ## Relations chain from --depends-on through the
  # ONE formatter (#243) — the same one `effort_chain` uses, so both write identical lines. (It was
  # built inline here before, and `$( … )` ate every newline: the section shipped as the single
  # mangled line `## Relations- Depends on #1- Depends on #2`.)
  local body d; body="$(_eff_compose_body "$goal" "$scope" "$for_agents" "$verification" "$spec_text")"
  # The Spec (E546.5): checked on the composed body, before any label or issue is written.
  spec_lint "$body" || { echo 'effort_new: say what done means with --spec "<item>" or --spec-file F, and retry' >&2; return 1; }
  # The Grilling record (E547.2): optional, but a record that is passed must be one — linted here,
  # before any forge write, then appended as the body's `## Grilling` section.
  if [ -n "$grilling" ]; then
    grill_record_lint "$grilling" || { echo 'effort_new: fix the --grilling record and retry' >&2; return 1; }
    body="$body"$'\n\n'"$(grill_record_section "$grilling")"
  fi
  # The sprint (#570): --sprint names the week the effort is planned into, in the body and as the
  # milestone of the parent and every sub. The milestone is opened when it does not exist yet.
  local sprint="" sprint_start="" sprint_end=""
  if [ -n "$sprint_day" ]; then
    [ "$sprint_day" = today ] && sprint_day="$(_sprint_today)"
    sprint="$(sprint_name "$sprint_day")" || { echo "effort_new: --sprint=YYYY-MM-DD names a day of the sprint" >&2; return 1; }
    IFS="$(printf '\t')" read -r sprint_start sprint_end <<EOF_SB
$(sprint_bounds "$sprint_day")
EOF_SB
    [ -z "$milestone" ] || [ "$milestone" = "$sprint" ] \
      || { echo "effort_new: --sprint and --milestone name different milestones ($sprint, $milestone)" >&2; return 1; }
    milestone="$sprint"
    body="$body"$'\n\n'"$(printf '## Sprint\n%s · Monday %s to Monday %s' "$sprint" "$sprint_start" "$sprint_end")"
  fi
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
  _eff_ensure_label "$ctx" bfd4f2 "$(kit_label_desc ctx "${ctx#ctx:}")"
  _eff_ensure_label "kind:$kind" d4c5f9 "$(kit_label_desc kind "$kind")"
  _eff_ensure_label "priority:$priority" e99695 "$(kit_label_desc priority "$priority")"
  # `effort` is what marks the parent AS an effort, and it is the label `effort_plan` queries
  # (`gh issue list --label effort`, effort-plan.sh). It was read and never written: the label did
  # not exist in this repo at all, so `cckit effort plan` answered "no open efforts found" for
  # every effort ever created here. A label something reads and nothing writes is the same defect
  # as one something writes and nothing reads — see rules/naming-and-ids.md § Labels.
  _eff_ensure_label "effort" 5319e7 "$(kit_label_desc effort)"
  local labels="effort,$ctx,kind:$kind,priority:$priority"
  if [ -n "$role" ]; then
    _eff_ensure_label "role:$role" 0e8a16 "$(kit_label_desc role "$role")"
    labels="$labels,role:$role"
  fi
  if [ -n "$flow" ]; then
    local flow_lc; flow_lc="$(printf '%s' "$flow" | tr '[:upper:]' '[:lower:]')"
    _eff_ensure_label "flow:$flow_lc" 1d76db "$(kit_label_desc flow "$flow_lc")"
    labels="$labels,flow:$flow_lc"
  fi

  if [ -n "$sprint" ]; then
    sprint_open --date "$sprint_day" >/dev/null 2>&1 \
      || echo "effort_new: could not open the sprint milestone $sprint — the effort is filed without it" >&2
  fi

  local url num slug
  # The number is assigned by the create, so the parent is filed under its plain name and renamed
  # to `[E<n>] <name>` at once. The `effort` label marks it as an effort in between.
  url="$(gh_rest_issue_create "$repo" "$name" "$body" "$labels" "$milestone" 0)" \
    || { echo "effort_new: failed to create the parent issue" >&2; return 1; }
  num="${url##*/}"
  gh_rest_issue_edit_title "$repo" "$num" "$(naming_effort_title "$num" "$name")" >/dev/null 2>&1 \
    || echo "effort_new: #$num was created but not renamed to $(naming_effort_title "$num" "$name") — run: cckit effort retitle $num --apply" >&2
  # The human handle (#93): explicit --slug if given, else derived from the name.
  if [ -n "$explicit_slug" ]; then slug="$(_eff_slug "$explicit_slug")"
  else slug="$(_eff_title_slug "$(naming_effort_title "$num" "$name")")"; fi
  if [ -n "$slug" ]; then
    gh_rest_label_create "$repo" "slug:$slug" ededed "effort slug handle"
    gh_rest_issue_add_labels "$repo" "$num" "slug:$slug" >/dev/null 2>&1 || true
  fi
  echo "  ✓ effort $(effort_display "$num" "$slug") · ${name}" >&2

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
    sub_title="$(naming_sub_title "$num" "$i" "$sub_name")"
    local sub_labels="kind:$kind,priority:$priority"
    [ -n "$role" ] && sub_labels="$sub_labels,role:$role"
    child="$(gh_rest_issue_create "$repo" "$sub_title" \
      "$(printf '%s\n\nSub-issue of #%s (effort).' "$sub_desc" "$num")" "$sub_labels" "$milestone" 0)" || continue
    child_num="${child##*/}"
    effort_link_sub "$num" "$child_num" || true
    _eff_board_add "$child_num" "$role" || true
    echo "  ✓ sub #$child_num · $sub_name" >&2
  done
  printf '%s\n' "$num"
}

# effort_sub <slug|N> "<name>" [--kind K] [--body B] [--spec T] — add ONE sub-issue to an effort
# (E546.1). The title is `[E<N>.<step>] <name>`, step = the effort's current native sub count + 1; it
# is linted before any forge write. The sub takes the parent's priority, role and milestone, and
# the kind:<k> label (--kind, else the parent's kind, else task), as effort_new's subs do; it is
# linked natively under the parent and added to the board. --spec adds an optional `## Spec` section
# (E546.5), linted like the parent's when given; a sub needs none. Echoes the new sub's number.
effort_sub() {
  _eff_forge || return 1; _eff_need jq || return 1
  local raw="" name="" kind="" body_in="" spec="" pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)   kind="${2:-}"; shift 2 ;;
      --kind=*) kind="${1#*=}"; shift ;;
      --body)   body_in="${2:-}"; shift 2 ;;
      --body=*) body_in="${1#*=}"; shift ;;
      --spec)   spec="${2:-}"; shift 2 ;;
      --spec=*) spec="${1#*=}"; shift ;;
      --)       shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*)       echo "effort_sub: unknown flag $1" >&2; return 2 ;;
      *)        pos+=("$1"); shift ;;
    esac
  done
  set -- "${pos[@]+"${pos[@]}"}"
  raw="${1:-}"; name="${2:-}"
  [ -n "$raw" ] && [ -n "$name" ] || { echo 'effort_sub: usage: cckit effort sub <N> "<name>" [--kind K] [--body B] [--spec T]' >&2; return 2; }
  # The rule is about the NAME: lint it first, with a synthetic token, before any forge read or write.
  naming_title_lint sub "$(naming_sub_title 0 1 "$name")" || { echo "effort_sub: fix the name and retry" >&2; return 1; }
  if [ -n "$spec" ]; then
    if [ -n "$body_in" ]; then body_in="$(printf '%s\n\n%s' "$body_in" "$(spec_section "$spec")")"
    else body_in="$(spec_section "$spec")"; fi
    spec_lint "$body_in" || { echo "effort_sub: fix the --spec and retry" >&2; return 1; }
  fi
  if [ -n "$kind" ] && command -v kit_kind_label_valid >/dev/null 2>&1 && ! kit_kind_label_valid "$kind"; then
    echo "effort_sub: --kind must be one of: $KIT_KINDS $KIT_CONTENT_KINDS (got '$kind')" >&2; return 1
  fi
  local repo num meta labels milestone priority role count step title child child_num sub_labels
  repo="$(_eff_repo)"
  [ -n "$repo" ] || { echo "effort_sub: no repo (KIT_REPO/EFFORT_REPO unset — run in a kit project)" >&2; return 1; }
  num="$(effort_slug_resolve "$raw")" || { echo "effort_sub: could not resolve '$raw' to an effort" >&2; return 1; }
  meta="$(gh_rest_issue_json "$repo" "$num" 2>/dev/null)" || { echo "effort_sub: effort #$num not found" >&2; return 1; }
  labels="$(printf '%s' "$meta" | jq -r '[.labels[]?.name] | join(",")' 2>/dev/null)"
  case ",$labels," in *,effort,*) : ;; *)
    echo "effort_sub: #$num is not an effort (no 'effort' label) — file a standalone issue with cckit new" >&2; return 1 ;;
  esac
  milestone="$(printf '%s' "$meta" | jq -r '.milestone.title // ""' 2>/dev/null)"
  priority="$(printf '%s' "$labels" | tr ',' '\n' | sed -n 's/^priority://p' | sed -n 1p)"; priority="${priority:-p1}"
  role="$(printf '%s' "$labels" | tr ',' '\n' | sed -n 's/^role://p' | sed -n 1p)"
  [ -n "$kind" ] || kind="$(printf '%s' "$labels" | tr ',' '\n' | sed -n 's/^kind://p' | sed -n 1p)"
  kind="${kind:-task}"
  count="$(forge_rest "repos/$repo/issues/$num/sub_issues" -X GET -f per_page=100 --jq 'length' 2>/dev/null)" \
    || { echo "effort_sub: could not read the sub-issues of #$num" >&2; return 1; }
  step=$(( ${count:-0} + 1 ))
  title="$(naming_sub_title "$num" "$step" "$name")"
  naming_title_lint sub "$title" || return 1
  _eff_ensure_label "kind:$kind" d4c5f9 "$(kit_label_desc kind "$kind")"
  _eff_ensure_label "priority:$priority" e99695 "$(kit_label_desc priority "$priority")"
  sub_labels="kind:$kind,priority:$priority"
  [ -n "$role" ] && sub_labels="$sub_labels,role:$role"
  child="$(gh_rest_issue_create "$repo" "$title" \
    "$(printf '%s\n\nSub-issue of #%s (effort).' "$body_in" "$num")" "$sub_labels" "$milestone" 0)" \
    || { echo "effort_sub: failed to create the sub-issue" >&2; return 1; }
  child_num="${child##*/}"
  effort_link_sub "$num" "$child_num" || true
  _eff_board_add "$child_num" "$role" || true
  echo "  ✓ sub #$child_num · $title" >&2
  printf '%s\n' "$child_num"
}

# _eff_retitle_rows <N> — the legacy titles of effort N and its open subs, one "num<TAB>old<TAB>new"
# row each. A title already in the new form, or one with no prefix at all, gives no row.
_eff_retitle_rows() {
  local repo num title new tab subs s_num s_title tok
  repo="$(_eff_repo)"; num="$1"; tab="$(printf '\t')"
  title="$(forge_rest "repos/$repo/issues/$num" --jq '.title // ""' 2>/dev/null)" || return 1
  case "$title" in
    "[Effort] "*)
      new="$(naming_effort_title "$num" "$(naming_strip_prefix "$title")")"
      printf '%s\t%s\t%s\n' "$num" "$title" "$new" ;;
  esac
  subs="$(forge_rest "repos/$repo/issues/$num/sub_issues" -X GET -f per_page=100 \
    --jq '.[] | select((.state // "open") == "open") | "\(.number)\t\(.title // "")"' 2>/dev/null)" || return 0
  while IFS="$tab" read -r s_num s_title; do
    [ -n "$s_num" ] || continue
    case "$s_title" in "[Effort "[0-9]*) : ;; *) continue ;; esac
    tok="$(naming_title_token "$s_title")" || continue
    new="$(naming_sub_title "$num" "${tok#*.}" "$(naming_strip_prefix "$s_title")")"
    printf '%s\t%s\t%s\n' "$s_num" "$s_title" "$new"
  done <<EOF_SUBS
$subs
EOF_SUBS
}

# effort_retitle [<slug|N>] [--apply] — rename legacy `[Effort] N · ` / `[Effort N] M · ` titles to
# `[E<n>] ` / `[E<n>.<step>] ` (E546.1). Without <N>: every open effort (label `effort`) and its open
# subs. A dry run by default: it lists each old title and the new one and writes nothing. --apply
# edits the titles through the forge. A [Flow] tag is dropped: the flow lives in the flow: label.
effort_retitle() {
  _eff_forge || return 1; _eff_need jq || return 1
  local raw="" apply=0 a repo nums n rows="" tab line r_num r_old r_new count=0 failed=0
  for a in "$@"; do
    case "$a" in
      --apply) apply=1 ;;
      -*) echo "effort_retitle: unknown flag $a — usage: cckit effort retitle [<N>] [--apply]" >&2; return 2 ;;
      *) [ -z "$raw" ] && raw="$a" ;;
    esac
  done
  repo="$(_eff_repo)"; tab="$(printf '\t')"
  [ -n "$repo" ] || { echo "effort_retitle: no repo (KIT_REPO/EFFORT_REPO unset — run in a kit project)" >&2; return 1; }
  if [ -n "$raw" ]; then
    nums="$(effort_slug_resolve "$raw")" || { echo "effort_retitle: could not resolve '$raw' to an effort" >&2; return 1; }
  else
    nums="$(gh_rest_issue_numbers_by_label "$repo" effort)" || { echo "effort_retitle: could not list the open efforts" >&2; return 1; }
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    line="$(_eff_retitle_rows "$n")" || { echo "effort_retitle: could not read #$n" >&2; failed=1; continue; }
    [ -n "$line" ] && rows="${rows:+$rows
}$line"
  done <<EOF_NUMS
$nums
EOF_NUMS
  if [ -z "$rows" ]; then echo "(no legacy titles: every effort and sub already reads [E<n>] / [E<n>.<step>])"; return "$failed"; fi
  while IFS="$tab" read -r r_num r_old r_new; do
    [ -n "$r_num" ] || continue
    count=$((count + 1))
    printf '#%s  %s\n   -> %s\n' "$r_num" "$r_old" "$r_new"
    if [ "$apply" = 1 ]; then
      gh_rest_issue_edit_title "$repo" "$r_num" "$r_new" >/dev/null 2>&1 \
        || { echo "  ✗ #$r_num not renamed" >&2; failed=1; }
    fi
  done <<EOF_ROWS
$rows
EOF_ROWS
  if [ "$apply" = 1 ]; then echo "renamed $count title(s)"
  else echo "dry run: $count title(s) would change — run again with --apply to rename them"; fi
  return "$failed"
}

# _eo_source_effort — lazily source the git-mechanics lib (effort.sh) so the ops that need
# effort_set_blocked_by work when effort-ops.sh is sourced on its own. No-op if already loaded.
_eo_source_effort() {
  command -v effort_set_blocked_by >/dev/null 2>&1 && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/../core/effort.sh" ] && . "$d/../core/effort.sh"
}

# _eff_issue_body <repo> <n> / _eff_issue_set_body <repo> <n> <body> — read and replace an issue
# body on the chosen transport (#396). A failed read returns non-zero, never an empty body.
_eff_issue_body() { forge_rest "repos/$1/issues/$2" --jq '.body // ""'; }
_eff_issue_set_body() { gh_rest_issue_set_body "$1" "$2" "$3"; }

# _eff_blockers <issue> — echo the issue's CURRENT blocked_by numbers, one per line. Empty when the
# issue has no edges or the API call fails (the caller treats that as "no known edge").
_eff_blockers() {
  forge_rest "repos/$(_eff_repo)/issues/$1/dependencies/blocked_by" --jq '.[].number' 2>/dev/null || true
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
# predecessor>` line in its `## Relations` section. This is the verb that FEEDS `cckit effort plan --issues` — the
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
#                pre-flight walks the combined graph). `cckit effort plan --issues` cannot layer a cyclic graph into
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
  _eff_forge || return 1
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
    forge_rest "repos/$repo/issues/$n" --jq .number >/dev/null 2>&1 \
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
      if ! body="$(_eff_issue_body "$repo" "$next" 2>/dev/null)"; then
        echo "  ✗ could not read #$next's body — 'Depends on #$prev' not recorded" >&2; rc=1
      elif grep -qE "^[[:space:]]*- Depends on #${prev}[[:space:]]*$" <<<"$body"; then
        echo "  · #$next already records 'Depends on #$prev'" >&2
      else
        newbody="$(_eff_relations_add "$body" "$prev")"
        _eff_issue_set_body "$repo" "$next" "$newbody" >/dev/null 2>&1 \
          && echo "  ✓ #$next records 'Depends on #$prev'" >&2 \
          || { echo "  ✗ could not update #$next's body" >&2; rc=1; }
      fi
    fi
    prev="$next"
  done

  # The banner must agree with rc: a ✓ over a nonzero exit reports a chain that is not fully wired.
  # Individual failures already printed their own ✗ line above; this is the summary for the whole run.
  if [ "$rc" -eq 0 ]; then
    echo "  ✓ chain $(printf '#%s → ' $list | sed 's/ → $//')" >&2
  else
    echo "  ✗ chain $(printf '#%s → ' $list | sed 's/ → $//') — incomplete, see the errors above" >&2
  fi
  return "$rc"
}

# ── WIP limit: how many efforts may be in progress at once (#244) ──────────────────────────────
#
# WHAT COUNTS AS "IN PROGRESS": an effort whose `effort/<N>-<slug>` branch exists — a local head, or
# a branch origin has right now (`git ls-remote`, not the cached `refs/remotes`; see effort_wip_rows
# for why). Both halves are parsed by the effort-slug.sh helpers the slug resolver is built on, so a
# ref name is decomposed in one place. This is the kit's existing notion of a started effort, not a
# new one: `effort_start` CREATES that branch and `effort_close` deletes it, so the branch set is
# exactly "started and not yet closed", by construction.
#
# The Projects v2 board Status is deliberately NOT the signal. It is written by the /kit-effort-start
# skill's additive board step, never by this verb, so the verb would be gating on state it does not
# set; it is empty whenever `github.projectsV2` is false (cckit's own default); and there is no
# status:* label to fall back on. One signal, no fallback chain.

# _eff_wip_limit_from_config — echo `effort.wipLimit` straight from the project config, so a
# configured limit applies even to callers that never ran load_kit_config. Mirrors
# _effort_flows_from_config (effort.sh). Empty output / rc 1 when unset or unreadable.
_eff_wip_limit_from_config() {
  command -v jq >/dev/null 2>&1 || return 1
  if ! command -v kit_config_path >/dev/null 2>&1; then
    local _wl_dir; _wl_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    # shellcheck source=/dev/null
    [ -n "$_wl_dir" ] && [ -f "$_wl_dir/../core/config-path.sh" ] && . "$_wl_dir/../core/config-path.sh"
  fi
  command -v kit_config_path >/dev/null 2>&1 || return 1
  local _wl_cfg; _wl_cfg="$(kit_config_path 2>/dev/null)" && [ -f "$_wl_cfg" ] || return 1
  jq -r 'if (.effort.wipLimit | type) == "null" then empty else (.effort.wipLimit | tostring) end' \
    "$_wl_cfg" 2>/dev/null
}

# _eff_wip_limit — echo the effective limit. Resolution order mirrors the flow vocabulary (#150), so
# the kit has ONE config idiom:
#   1. EFFORT_WIP_LIMIT in the environment always wins (per-invocation override)
#   2. the project config `effort.wipLimit` — via KIT_EFFORT_WIP_LIMIT (exported by load_kit_config)
#      or read straight from the config file
#   3. the built-in default, 2.
# A value that is not a non-negative integer (a typo, a float, a negative) is IGNORED with a warning
# on stderr and the built-in default is used: a misconfigured limit must not silently disable the
# gate, and must not wedge the verb either. `0` is valid and means "start no new effort".
_eff_wip_limit() {
  local v="" src=""
  if [ -n "${EFFORT_WIP_LIMIT:-}" ]; then
    v="$EFFORT_WIP_LIMIT"; src="EFFORT_WIP_LIMIT"
  elif [ -n "${KIT_EFFORT_WIP_LIMIT:-}" ]; then
    v="$KIT_EFFORT_WIP_LIMIT"; src="effort.wipLimit"
  else
    v="$(_eff_wip_limit_from_config 2>/dev/null || true)"; src="effort.wipLimit"
  fi
  [ -n "$v" ] || { printf '2'; return 0; }
  case "$v" in
    ''|*[!0-9]*)
      echo "effort_start: ignoring $src='$v' — the WIP limit must be a non-negative integer; using the default 2" >&2
      printf '2'; return 0 ;;
  esac
  printf '%s' "$v"
}

# effort_wip_rows — one TSV row `<N>\t<slug>` per effort that is IN PROGRESS, each effort exactly
# once, lowest number first. The counted set behind the WIP gate: local `refs/heads/effort/*` UNION
# the effort branches origin actually has right now.
#
# Why not the cached `refs/remotes` (#244 review): it is wrong in both directions and the gate is
# wrong with it. A branch pushed since the last fetch is absent, so the gate lets the limit be
# exceeded — and the gate runs before effort_start's fetch, which is base-only and would not refresh
# `refs/remotes/origin/effort/*` anyway. A branch DELETED on origin lingers in `refs/remotes` until
# a prune, so the gate blocks a start that should be allowed. `git ls-remote` answers both: it sees
# the new branch and does not see the deleted one, without writing or pruning a single ref.
#
# The cost is one network round-trip per `effort start`. That is accepted: a gate that miscounts in
# both directions is not a gate, and `effort start` is a rare interactive command that already
# fetches and installs dependencies. Two things keep it from being a liability:
#
#   EFFORT_WIP_REMOTE=0  skips the origin query outright and counts local heads + cached remotes —
#                        for a deterministic offline or CI run, and for anyone who would rather have
#                        the old approximation than the round-trip.
#   unreachable origin   ls-remote failing (offline, no remote, auth) is NOT fatal. The count falls
#                        back to the cached `refs/remotes`, one line says so on stderr, and the start
#                        proceeds. A gate that hard-fails with no network would be worse than one
#                        that miscounts.
#
# Deliberately NOT cached between invocations: a cache reintroduces the staleness window this
# replaces, and there is nothing to amortize — one ls-remote per interactive start.
effort_wip_rows() {
  command -v effort_branch_rows >/dev/null 2>&1 || return 0
  local remote=""
  {
    effort_branch_rows_local 2>/dev/null
    if [ "${EFFORT_WIP_REMOTE:-1}" = "0" ]; then
      effort_branch_rows 2>/dev/null            # opted out: local heads + cached remotes
    elif remote="$(effort_branch_rows_origin 2>/dev/null)"; then
      printf '%s\n' "$remote"
    else
      echo "effort_start: could not read origin's effort branches — counting work in progress from the last fetch, which may be stale (set EFFORT_WIP_REMOTE=0 to silence this)" >&2
      effort_branch_rows 2>/dev/null            # offline fallback: local heads + cached remotes
    fi
  } | awk -F'\t' 'NF > 0 && $1 != "" && !seen[$1]++' | sort -n
}

# _eff_wip_gate <num> <force> — rc 0 when starting effort <num> may proceed, rc 1 (with the refusal
# on stderr) when it may not. READ-ONLY: it reads refs (one of them over the network — see
# effort_wip_rows) and the config, and writes nothing, so a refusal leaves no branch, no worktree and
# no board change behind (the effort_new / effort_chain discipline). It is not free of reads: the
# gate itself queries origin, and for a SLUG argument effort_start has already resolved the handle
# through effort_slug_resolve, which may have run `gh issue list`. "Writes nothing" is the guarantee;
# "reads nothing" is not.
#
# The rules:
#   already started  an effort whose branch already exists is ALREADY in the counted set, so
#                    re-running `effort start` on it adds no WIP and the gate does not apply —
#                    `effort_start` stays safe to re-run at or over the limit.
#   at the limit     `in-progress count >= limit` REFUSES. The limit is a ceiling on concurrent
#                    efforts: at 2 of 2, a third would make 3. Only `count < limit` starts.
#   limit 0          refuses every new effort (a deliberate freeze); the override still works.
#   override         `--force` (or KIT_FORCE=1, the same escape hatch effort_close uses) starts
#                    anyway and says so on stderr.
_eff_wip_gate() {
  local num="$1" force="${2:-}" limit rows count n tab; tab="$(printf '\t')"
  limit="$(_eff_wip_limit)"
  rows="$(effort_wip_rows)"

  while IFS="$tab" read -r n _; do
    if [ "$n" = "$num" ]; then return 0; fi
  done <<EOF
$rows
EOF

  count="$(printf '%s\n' "$rows" | grep -cE '^[0-9]+' || true)"
  if [ "${count:-0}" -lt "$limit" ]; then return 0; fi

  {
    echo "effort_start: $count effort(s) already in progress and the WIP limit is $limit."
    printf '%s\n' "$rows" | grep -E '^[0-9]+' | while IFS="$tab" read -r n _slug; do
      printf '    · %s  (effort/%s-%s)\n' "$(effort_display "$n" "$_slug")" "$n" "$_slug"
    done
  } >&2
  if [ -n "$force" ]; then
    echo "  → starting #$num anyway (override)." >&2
    return 0
  fi
  {
    echo "  → refusing to start #$num — nothing was created."
    echo "     Close one with 'cckit effort close <N>', or start anyway with --force (or KIT_FORCE=1)."
    echo "     The limit is effort.wipLimit in the project config (default 2); EFFORT_WIP_LIMIT overrides it."
  } >&2
  return 1
}

# _eo_source_wt — lazily source the worktree mechanic (worktree-start.sh) so effort_start gets the
# SAME full worktree setup as `cckit start`: wt_bootstrap (env-file copy + per-worktree dev port +
# dependency install) and the _wt_session_owns collision guard. bin/cckit's `effort` verb does not
# load it, so effort-ops brings it in on demand (#119). No-op if already loaded.
_eo_source_wt() {
  command -v wt_bootstrap >/dev/null 2>&1 && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/../core/worktree-start.sh" ] && . "$d/../core/worktree-start.sh"
}

# effort_start [--force] <slug|N> [<slug>] — create the effort/<N> integration branch + its worktree
# from base, with the full `cckit start` worktree setup (env copy, per-worktree dev port, dependency
# install — opt out with KIT_WT_INSTALL=0) and a live-session collision guard.
#
# Gated by the WIP limit (#244): when as many efforts are already in progress as `effort.wipLimit`
# allows (default 2), starting a NEW one is refused before anything is written — see _eff_wip_gate
# above for the counted set and the exact rules. `--force` (or KIT_FORCE=1) starts anyway.
# The gate is specific to EFFORTS: `cckit start <issue>` (a plain task worktree, wt_start) is not
# affected and has no WIP limit.
effort_start() {
  _eff_need git || return 1
  local raw="" slug_override="" force="" num repo base root title slug branch wt
  # Flags are position-INDEPENDENT (the effort_new parser shape): `--` forces the rest positional.
  local pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --)      shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      --*)     echo "effort_start: unknown flag $1" >&2; return 1 ;;
      *)       pos+=("$1"); shift ;;
    esac
  done
  set -- "${pos[@]+"${pos[@]}"}"
  raw="${1:-}"; slug_override="${2:-}"
  if [ "${KIT_FORCE:-0}" = "1" ]; then force=1; fi
  [ -n "$raw" ] || { echo "effort_start: <slug|effort issue #> required" >&2; return 1; }
  num="$(effort_slug_resolve "$raw")" || { echo "effort_start: could not resolve '$raw' to an effort" >&2; return 1; }
  repo="$(_eff_repo)"; base="$(_eff_base)"
  root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / && !hit {print $2; hit=1}')"
  [ -n "$root" ] || { echo "effort_start: not in a git repo" >&2; return 1; }

  # WIP gate (#244) — BEFORE the fetch, the branch, the worktree and the bootstrap, so a refusal
  # leaves nothing behind. Reads refs + config only; writes nothing.
  _eff_wip_gate "$num" "$force" || return 1

  if [ -n "$slug_override" ]; then slug="$(_eff_slug "$slug_override")"
  else
    # A soft read (#330): the slug has a fallback, so a failed gh must not end the op — and under
    # `set -e` a bare failed assignment did exactly that, rc 1 with no output. Failed is told apart
    # from empty by gh's exit code, and said on stderr.
    local title_rc=0
    title="$(forge_rest "repos/$repo/issues/$num" --jq .title 2>/dev/null)" || title_rc=$?
    slug=""
    if [ "$title_rc" -ne 0 ]; then
      title=""
      # An effort already started keeps its branch: a re-start during an outage must land on
      # effort/<N>-<its slug>, not cut a second branch named after the fallback.
      slug="$(git -C "$root" for-each-ref --format='%(refname:short)' "refs/heads/effort/$num-*" 2>/dev/null | sed -n 1p)"
      slug="${slug#effort/"$num"-}"
      echo "effort_start: could not read the title of issue #$num from GitHub (gh exited $title_rc) — continuing with the slug '${slug:-effort}'. To choose the slug: effort start $num <slug>" >&2
    fi
    [ -n "$slug" ] || slug="$(_eff_title_slug "${title:-effort}")"; [ -n "$slug" ] || slug="effort"
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
    # Stamp the effort's start (#453): `effort close` subtracts it for build_seconds. Only here,
    # where the branch is created — a re-start of an effort begun earlier would stamp a start that
    # is too late, and capture falls back to the branch's oldest commit instead. Best-effort.
    _eo_source_metrics
    if command -v record_effort_start >/dev/null 2>&1; then
      ( cd "$root" && record_effort_start "$num" ) >/dev/null 2>&1 || true
    fi
  fi

  # Bootstrap the worktree for local dev: copy gitignored env, assign a per-worktree dev port, and
  # install deps (KIT_WT_INSTALL=0 opts out). Best-effort — a hiccup never fails the start.
  command -v wt_bootstrap >/dev/null 2>&1 && wt_bootstrap "$root" "$wt" "$num" || true

  echo "  ✓ effort $(effort_display "$num" "$slug") → $branch  (worktree: $wt)" >&2
  printf '%s|%s|%s\n' "$wt" "$branch" "$num"
}

# effort_pr [<slug|N>] — open the single PR effort/<N> → base. Defaults to the current effort branch.
_EO_PR_USAGE='cckit effort pr [<slug|N>] [--summary S|--summary-file F] [--for-agents A|--for-agents-file F] [--message M] [--title T] [--type T]   open the ONE PR effort/<N> → base'
effort_pr() {
  # The ONE effort-PR implementation (#363). The kit-effort-pr skill calls this; before, the skill
  # carried its own inline copy, so agents hand-copied the script and the copy drifted (a PR missing
  # from the board, a mangled body). Args: [<slug|N>] [--summary S|--summary-file F]
  # [--for-agents A|--for-agents-file F] [--message M] [--title T]. SUMMARY / FOR_AGENTS / COMMIT_MSG env are
  # honoured as fallbacks.
  case "${1:-}" in -h|--help) echo "$_EO_PR_USAGE"; return 0 ;; esac
  _eff_forge || return 1
  local raw="" summary="${SUMMARY:-}" for_agents="${FOR_AGENTS:-}" msg="${COMMIT_MSG:-}" title_override="" ctype=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --summary)          summary="${2:-}"; shift 2 ;;
      --summary-file)     summary="$(cat "${2:-/dev/null}")"; shift 2 ;;
      --for-agents)       for_agents="${2:-}"; shift 2 ;;
      --for-agents-file)  for_agents="$(cat "${2:-/dev/null}")"; shift 2 ;;
      --message|-m)       msg="${2:-}"; shift 2 ;;
      --title)            title_override="${2:-}"; shift 2 ;;
      --type)             ctype="${2:-}"; shift 2 ;;
      -h|--help)          echo "$_EO_PR_USAGE"; return 0 ;;
      *)                  [ -z "$raw" ] && raw="$1"; shift ;;
    esac
  done
  local num repo base branch meta title labels milestone role role_disp name pr_title body url author
  repo="$(_eff_repo)"; base="$(_eff_base)"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ -n "$raw" ]; then
    num="$(effort_slug_resolve "$raw")" || { echo "effort_pr: could not resolve '$raw' to an effort" >&2; return 1; }
  else
    num="$(effort_branch_num "$branch")"
  fi
  [ -n "$num" ] || { echo "effort_pr: not on an effort/<N>-… branch and no <slug|N> given" >&2; return 1; }
  case "$branch" in effort/"$num"-*) : ;; *) echo "effort_pr: current branch ($branch) is not effort/$num-…" >&2; return 1 ;; esac

  # Parent metadata: the PR inherits its labels + milestone, and the role names the title.
  meta="$(gh_rest_issue_json "$repo" "$num" 2>/dev/null)"
  title="$(printf '%s' "$meta" | jq -r '.title // ""' 2>/dev/null)"
  labels="$(printf '%s' "$meta" | jq -r '[.labels[]?.name] | join(",")' 2>/dev/null)"
  milestone="$(printf '%s' "$meta" | jq -r '.milestone.title // ""' 2>/dev/null)"
  role="$(printf '%s' "$labels" | tr ',' '\n' | sed -n 's/^role://p' | sed -n 1p)"
  role_disp=""
  if [ -n "$role" ] && command -v role_display >/dev/null 2>&1; then
    role_disp="$(role_display "$role" 2>/dev/null || true)"
  fi
  name="$(naming_strip_structural "$title")"

  # ONE shared composer (effort.sh) so every surface titles identically, then the naming rule and
  # the effort-token check before the commit, the push or any forge write — refuse rather than open
  # an id-less PR (#121).
  # --title replaces the composed title; it must still carry the effort's token, checked below.
  pr_title="${title_override:-$(effort_pr_title "$num" "${name:-effort}" "$labels" "$ctype" "$role_disp")}"
  effort_pr_title_check "$pr_title" "$num" || { echo "effort_pr: refusing to open a PR without the [E$num] effort token" >&2; return 1; }
  # #237 + E546.1: under pr.titleStyle = conventional (the default) the title becomes the squash
  # commit the commitlint gate checks, so naming_title_lint pr holds it to the Conventional Commit
  # form with a trailing token. issue-title repos run no such gate; the lint passes them through.
  naming_title_lint pr "$pr_title" || { echo "effort_pr: refusing to open a PR whose title breaks the naming rule (pass --type <type> or --title, or set pr.titleStyle to issue-title)" >&2; return 1; }

  # Commit pending changes. Role identity is a Co-authored-by TRAILER, never the git author (some
  # deploy providers refuse commits whose author email matches no account). Every file the local
  # gate saw goes into the commit, as in kto_task_pr (#649, #664): tracked edits AND new files that
  # are not ignored. `git add -A` honours .gitignore, so an ignored .env.local copied into the
  # worktree never reaches the PR; a new file that must stay out belongs in .gitignore. New files
  # are named on stderr, so the commit is never silently larger either.
  local new_files; new_files="$(git ls-files --others --exclude-standard 2>/dev/null)"
  if [ -n "$new_files" ]; then
    echo "effort_pr: new files committed with the tracked changes (add them to .gitignore to keep them out):" >&2
    printf '%s\n' "$new_files" | sed 's/^/  /' >&2
  fi
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    author=""
    git add -A
    if [ -n "$role" ] && command -v role_git_author >/dev/null 2>&1; then
      author="$(role_git_author "$role" 2>/dev/null || true)"
    fi
    if [ -n "$author" ]; then
      git commit -q -m "${msg:-$role: ${name:-effort $num}}" -m "Co-authored-by: ${author%%|*} <${author##*|}>" || return 1
    else
      git commit -q -m "${msg:-${role:-chore}: ${name:-effort $num}}" || return 1
    fi
  fi
  git push -u origin "$branch" >/dev/null 2>&1 || echo "effort_pr: push of $branch failed — continuing (the PR may already be current)" >&2

  body="$(_eff_pr_body "$num" "$summary" "$for_agents" "$role")"

  url="$(gh_rest_pr_create "$repo" "$base" "$branch" "$pr_title" "$body" "$labels" "$milestone")" || return 1
  echo "✓ $url"
  _eff_pr_board "$num" "$url" "$role"
}

# _eff_pr_body <num> <summary> <for-agents> [role] — the effort PR body: the orchestrator header,
# `Closes #N`, a human Summary, the agent-facing For agents block, and a Verification checklist.
# An empty section prints a visible placeholder, never nothing, so a reviewer sees what is missing.
_eff_pr_body() {
  local num="$1" summary="$2" for_agents="$3" role="${4:-}" sig=""
  if [ -n "$role" ] && command -v role_signature >/dev/null 2>&1; then
    sig="$(role_signature "$role" 2>/dev/null || true)"
  fi
  # pr.bodyStyle = content (KIT_PR_BODY_STYLE, #418): draft-and-review wording for content work.
  # `Closes #N`, the Summary and the For agents block are the same in both styles.
  if [ "${KIT_PR_BODY_STYLE:-code}" = "content" ]; then
    printf '## For the orchestrator\n\nEffort #%s — one PR for the whole effort. Review: the summary below and the changed files.\n\nCloses #%s\n\n' "$num" "$num"
    printf '## Summary\n\n%s\n\n' "${summary:-_(no summary given — pass --summary)_}"
    printf '## For agents\n\n%s\n\n' "${for_agents:-See #$num for the goal, scope, and entry points.}"
    printf '## Review\n\n- [ ] Every piece the summary lists is in the changed files\n- [ ] Facts, names, numbers and links are checked\n- [ ] The voice matches the brand guide\n- [ ] Only the files for this work changed\n- [ ] Labels + milestone match the parent issue\n'
    [ -n "$sig" ] && printf '\n%s\n' "$sig"
    return 0
  fi
  printf '## For the orchestrator\n\nEffort #%s — one PR for the whole effort. Review: the summary below + the diff.\n\nCloses #%s\n\n' "$num" "$num"
  printf '## Summary\n\n%s\n\n' "${summary:-_(no summary given — pass --summary)_}"
  printf '## For agents\n\n%s\n\n' "${for_agents:-See #$num for the goal, scope, and entry points.}"
  printf '## Verification\n\n- [ ] Each sub-issue change is present in the diff\n- [ ] No unrelated files in the diff\n- [ ] Labels + milestone match the parent issue\n- [ ] Local lint/typecheck pass\n'
  [ -n "$sig" ] && printf '\n%s\n' "$sig"
  return 0
}

# _eff_pr_board <num> <pr-url> [role] — add the PR to the board at In Review (+ Role) and move the
# parent to In Review. A no-op unless Projects v2 is on; a failed PR add is reported, never silent.
_eff_pr_board() {
  local num="$1" url="$2" role="${3:-}" repo pr_num node item ropt parent
  [ "${KIT_PROJECTS_V2:-}" = "true" ] || return 0
  cckit_board_skipped && return 0
  _eo_source_board
  command -v project_add_item >/dev/null 2>&1 || return 0
  repo="$(_eff_repo)"; pr_num="${url##*/}"
  node="$(forge_rest "repos/$repo/pulls/$pr_num" --jq .node_id 2>/dev/null)" || node=""
  item=""
  [ -n "$node" ] && item="$(project_add_item "$node" "$repo" "$pr_num" PullRequest 2>/dev/null || true)"
  if [ -z "$item" ]; then
    echo "⚠ PR #$pr_num was opened but NOT added to the board — add it by hand" >&2
  else
    if [ -n "${STATUS_FIELD_ID:-}" ] && [ -n "${STATUS_OPT_IN_REVIEW:-}" ]; then
      project_set_single_select "$item" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_REVIEW" >/dev/null 2>&1 || true
    fi
    if [ -n "$role" ] && [ -n "${ROLE_FIELD_ID:-}" ] && command -v role_option_id >/dev/null 2>&1; then
      ropt="$(role_option_id "$role" || true)"
      [ -n "$ropt" ] && { project_set_single_select "$item" "$ROLE_FIELD_ID" "$ropt" >/dev/null 2>&1 || true; }
    fi
  fi
  parent="$(project_find_item_by_issue "$num" 2>/dev/null || true)"
  if [ -n "$parent" ] && [ -n "${STATUS_FIELD_ID:-}" ] && [ -n "${STATUS_OPT_IN_REVIEW:-}" ]; then
    project_set_single_select "$parent" "$STATUS_FIELD_ID" "$STATUS_OPT_IN_REVIEW" >/dev/null 2>&1 || true
  fi
  return 0
}

# _eo_source_metrics — lazily source effort-metrics.sh so effort_close can call the shipped
# capture/judge/sync functions even when only effort-ops is loaded (bin/cckit sources it for the
# effort verb; this makes the composition robust + testable). No-op if already loaded.
_eo_source_metrics() {
  command -v capture_effort_metrics >/dev/null 2>&1 && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/../core/effort-metrics.sh" ] && . "$d/../core/effort-metrics.sh"
}

# _eo_source_gc — lazily source kit-gc.sh so effort_close can collect the effort's `sub/<N>…`
# worktrees + branches through the LANDED prune path (#388) — the ONE classifier, never a second
# `git branch -D` loop here. No-op if already loaded; a missing file degrades to "no sub GC".
_eo_source_gc() {
  command -v kit_gc_prune >/dev/null 2>&1 && return 0
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/kit-gc.sh" ] && . "$d/kit-gc.sh"
}

# _eo_source_board — lazily source the board helpers (gh-project.sh) + captured field ids so
# effort_close can set Status=Done from any shell, with no caller wiring (bin/cckit sources the
# board helpers only for `effort new`). Guarded: a no-op unless Projects v2 is on; a missing
# gh-project.sh or ids file degrades to a no-op (the board steps below are themselves guarded).
_eo_source_board() {
  [ "${KIT_PROJECTS_V2:-}" = "true" ] || return 0
  cckit_board_skipped && return 0
  if ! command -v project_find_item_by_issue >/dev/null 2>&1; then
    local d; d="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    # shellcheck source=/dev/null
    [ -f "$d/../forge/gh-project.sh" ] && . "$d/../forge/gh-project.sh"
  fi
  if [ -z "${STATUS_FIELD_ID:-}" ] && command -v load_project_ids >/dev/null 2>&1; then
    load_project_ids >/dev/null 2>&1 || true
  fi
  return 0
}

# _eo_issue_close_completed <repo> <n> — close as completed on the chosen transport (#396), quietly.
_eo_issue_close_completed() { gh_rest_issue_close "$1" "$2" completed >/dev/null 2>&1; }

# _eo_delete_remote_subs <effort#> <dir> — delete every `sub/<N><letter>-*` branch origin has right
# now (#651), one `✓ deleted remote branch` line each on stderr. Read with `git ls-remote --heads`,
# filtered to one trailing letter, so another effort's `sub/<N>0a-…` is never matched. In a cloud
# session the proxy rejects branch deletion (#396): the branches are listed as kept. A failed
# delete warns; the function always returns 0, because the merge has already landed.
_eo_delete_remote_subs() {
  local num="$1" dir="${2:-.}" refs ref sub
  refs="$(git -C "$dir" ls-remote --heads origin "refs/heads/sub/${num}*" 2>/dev/null \
    | awk '{print $2}' | sed 's|^refs/heads/||' | grep -E "^sub/${num}[a-z]-" || true)"
  [ -n "$refs" ] || return 0
  while IFS= read -r sub; do
    [ -n "$sub" ] || continue
    if cckit_in_cloud; then
      echo "  (remote branch $sub kept — branch deletion is unavailable here; delete it on GitHub)" >&2
    elif git -C "$dir" push origin --delete "$sub" >/dev/null 2>&1; then
      echo "  ✓ deleted remote branch $sub" >&2
    else
      echo "  ⚠ remote branch $sub not deleted — delete it on GitHub" >&2
    fi
  done <<EOF_SUBS
$refs
EOF_SUBS
  return 0
}

# _eo_board_done <issue #> — set the board Status=Done for one issue. Guarded like _eff_board_add:
# a no-op unless Projects v2 is on AND the board helpers + field ids are loaded. Best-effort — a
# board hiccup never fails the close (the merge already landed).
_eo_board_done() {
  local n="$1" item
  [ "${KIT_PROJECTS_V2:-}" = "true" ] || return 0
  cckit_board_skipped && return 0
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
# effort_close's drift check greps against this (was inlined in the kit-effort-close skill, #148),
# and so does the task-merge drift check in the kit-task-pr-merge skill.
# .claude/rules/ is matched by BASENAME, not as a directory (#218): init.sh writes a rule only from
# kit/templates/rules/<name>.md, so any other file there is the project's own and no /kit-update can
# touch it. The list is the kit/templates/rules basenames; effort-ops-test.sh fails when they differ.
_EO_KIT_MANAGED_RE='^(scripts/(lib/|kit$|kit-)|\.claude/(skills|hooks|lib|agents)/|\.claude/rules/(authoring|branch-naming|code-retrieval|communication-style|delegation-brief|design-routing|effort-model|gate-and-review|issue-lifecycle|knowledge-base|merge-safety|naming-and-ids|plain-language|plan-next|plan-output-format|react-annotate|review-pages|risk-tiered-review|shared-checkout|skill-gaps|task-management)\.md$)'

# _eo_kit_manifest_file [<dir>] — the project's ownership manifest (kit-manifest.sh), or nothing:
# `$KIT_MANIFEST` when it names a file, else <dir>/.claude/kit.manifest.json, else the Codex-only
# <dir>/.cckit/kit.manifest.json. Needs jq to be readable; without jq it prints nothing, so the
# caller falls back to the pattern.
_eo_kit_manifest_file() {
  local dir="${1:-.}" mf
  command -v jq >/dev/null 2>&1 || return 0
  for mf in "${KIT_MANIFEST:-}" "$dir/.claude/kit.manifest.json" "$dir/.cckit/kit.manifest.json"; do
    [ -n "$mf" ] && [ -f "$mf" ] && { printf '%s\n' "$mf"; return 0; }
  done
  return 0
}

# _eo_kit_managed_filter [<dir>] — stdin: changed paths, one per line (relative to the project
# root). stdout: the ones the kit manages (#652, decision 96). The manifest is the source: a path
# is kit-managed when it is an entry of <dir>'s kit.manifest.json, which is what `init --upgrade`
# writes and `kit_op_remove` refuses to go beyond — a project's own file under `.claude/skills/` is
# not flagged. With no manifest (a project scaffolded before manifests, or cckit itself) the path
# pattern _EO_KIT_MANAGED_RE decides, and _eo_kit_sync_warn says so.
_eo_kit_managed_filter() {
  local mf; mf="$(_eo_kit_manifest_file "${1:-.}")"
  if [ -n "$mf" ]; then
    grep -xF -f <(jq -r '.entries | keys[]' "$mf" 2>/dev/null; echo '//never//') || true
  else
    grep -E "$_EO_KIT_MANAGED_RE" || true
  fi
}

# _eo_knowledge_ingest <num> <trace_dir> <root> — optional post-close knowledge-ingest hook. Runs a
# project-configured command (github/effort.knowledgeIngestHook, or KIT_EFFORT_KNOWLEDGE_HOOK) with
# the effort number + trace dir, so a project can fold the closed effort's work record into its
# knowledge base. Config-gated: a NO-OP when unset or the hook file is missing/not executable — the
# kit ships no default hook. Best-effort — a hook failure never fails the close.
#
# The config is read AFTER the close removed the effort worktree, and bin/cckit exports KIT_CONFIG as
# the copy inside that worktree (#518). So a KIT_CONFIG that no longer exists falls back to the main
# checkout's config; when that is missing too the close says so — a config that vanished is not the
# same as a project with no hook. The hook's stdout + stderr go to stderr, like the pre-close hook's.
_eo_knowledge_ingest() {
  local num="$1" trace="$2" root="$3" hook="" cfg
  hook="${KIT_EFFORT_KNOWLEDGE_HOOK:-}"
  if [ -z "$hook" ]; then
    cfg="${KIT_CONFIG:-}"
    if [ -z "$cfg" ] || [ ! -f "$cfg" ]; then
      if [ -f "$root/cckit.config.json" ]; then cfg="$root/cckit.config.json"
      elif [ -f "$root/.claude/kit.config.json" ]; then cfg="$root/.claude/kit.config.json"
      elif [ -n "$cfg" ]; then
        echo "effort_close: project config '$cfg' went away with the worktree and the main checkout has none — post-close hook not read" >&2
        return 0
      fi
    fi
    [ -f "$cfg" ] && command -v jq >/dev/null 2>&1 \
      && hook="$(jq -r '.effort.knowledgeIngestHook // empty' "$cfg" 2>/dev/null)"
  fi
  [ -n "$hook" ] || return 0
  case "$hook" in /*) : ;; *) hook="$root/$hook" ;; esac   # resolve a relative hook against the root
  [ -x "$hook" ] || { echo "effort_close: knowledge-ingest hook '$hook' not executable — skipping" >&2; return 0; }
  echo "  → knowledge-ingest hook: $hook $num" >&2
  # Run it from the main checkout (#371): the close has just removed the worktree it was invoked from,
  # so the inherited cwd no longer exists and a hook's relative paths / bare git calls would fail.
  ( cd "${root:-/}" && "$hook" "$num" "$trace" ) 1>&2 || echo "effort_close: knowledge-ingest hook failed (non-fatal)" >&2
}

# _eo_dependent_prs <branch> — pure selector (#358): `gh pr list --json number,baseRefName` on stdin,
# the numbers of the PRs whose base is exactly <branch> on stdout, one per line. Empty stdin prints
# nothing; input that is not a JSON array is rc 1, so the caller can tell "none" from "unreadable".
_eo_dependent_prs() {
  jq -r --arg b "$1" 'if type == "array" then .[] | select(.baseRefName == $b) | .number else error("not a list") end' 2>/dev/null
}

# _eo_retarget_dependents <repo> <branch> <base> — re-target every open PR based on <branch> to
# <base> (#358). GitHub closes a PR, unmerged, the moment its base branch is deleted, and the squash
# below deletes <branch>. rc 1 when the list cannot be read or an edit fails: the caller refuses the
# close, because either one means a PR would be closed by the delete.
_eo_retarget_dependents() {
  local repo="$1" branch="$2" base="$3" json deps dep
  json="$(forge_rest "repos/$repo/pulls" -X GET -f base="$branch" -f state=open -f per_page=100 \
            --jq '[.[] | {number, baseRefName: .base.ref}]' 2>/dev/null)" \
    && deps="$(printf '%s' "$json" | _eo_dependent_prs "$branch")" \
    || { echo "effort_close: could not list the open PRs based on $branch — deleting it would close any that exist. Rerun when GitHub answers (nothing was merged)" >&2; return 1; }
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    forge_rest "repos/$repo/pulls/$dep" -X PATCH -f base="$base" >/dev/null 2>&1 \
      || { echo "effort_close: PR $dep is based on $branch and could not be re-targeted to $base — deleting the branch would close it. Change its base to $base on GitHub, then rerun (nothing was merged)" >&2; return 1; }
    echo "  ↻ PR $dep re-targeted to $base" >&2
  done <<EOF_DEPS
$deps
EOF_DEPS
}

# _eo_pre_close_hook <num> <repo> <root> <cwd> [<subs>] — optional project gate that runs BEFORE the
# close writes anything (#380). Runs a project-configured command (effort.preCloseHook, or
# KIT_EFFORT_PRE_CLOSE_HOOK) as `<hook> <effort#> <sub#…>` with cwd = <cwd> (the effort worktree; the
# checkout the close was run from on the wave path). <subs> is a newline-separated sub list; when
# omitted the native sub-issues are read from GitHub. Returns 1 — the caller refuses the close —
# when the hook exits non-zero, or is configured but not executable: a gate that cannot run must not
# pass. The hook's stdout + stderr go to stderr. KIT_FORCE=1 skips the hook and says so. A NO-OP
# (rc 0, no GitHub read) when no hook is configured — the kit ships no default hook.
_eo_pre_close_hook() {
  local num="$1" repo="$2" root="$3" cwd="$4" subs="${5:-}" hook="" cfg sub rc
  hook="${KIT_EFFORT_PRE_CLOSE_HOOK:-}"
  if [ -z "$hook" ]; then
    cfg="${KIT_CONFIG:-}"; [ -n "$cfg" ] || { [ -f "$root/cckit.config.json" ] && cfg="$root/cckit.config.json" || cfg="$root/.claude/kit.config.json"; }
    [ -f "$cfg" ] && command -v jq >/dev/null 2>&1 \
      && hook="$(jq -r '.effort.preCloseHook // empty' "$cfg" 2>/dev/null)"
  fi
  [ -n "$hook" ] || return 0
  case "$hook" in /*) : ;; *) hook="$root/$hook" ;; esac   # resolve a relative hook against the root
  if [ "${KIT_FORCE:-0}" = "1" ]; then
    echo "effort_close: pre-close hook '$hook' skipped (KIT_FORCE=1)" >&2; return 0
  fi
  [ -x "$hook" ] || { echo "effort_close: pre-close hook '$hook' is configured but not executable — refusing to close #$num (nothing was written). Fix effort.preCloseHook, or set KIT_FORCE=1 to skip it." >&2; return 1; }
  [ "$#" -ge 5 ] || subs="$(forge_rest "repos/$repo/issues/$num/sub_issues" --jq '.[].number' 2>/dev/null)"
  set -- "$num"
  while IFS= read -r sub; do
    [ -n "$sub" ] && set -- "$@" "$sub"
  done <<EOF_SUBS
$subs
EOF_SUBS
  echo "  → pre-close hook: $hook $*" >&2
  ( cd "${cwd:-.}" && "$hook" "$@" ) 1>&2; rc=$?
  [ "$rc" -eq 0 ] && return 0
  echo "effort_close: pre-close hook exited $rc — refusing to close #$num (nothing was written). Fix what it reports, or set KIT_FORCE=1 to skip it." >&2
  return 1
}

# effort_close <N> — the SINGLE close implementation (#148): the /kit-effort-close skill is a thin
# caller of this function, never a second close. Snapshot per-sub diffs + capture metrics BEFORE the
# squash (the squash erases the per-sub history), REFUSE to squash if no work trace was captured
# (KIT_FORCE=1 overrides), squash-merge, judge the metrics, close parent + finished subs, set the board
# Status=Done for each (guarded), GC the worktree/branch, run the optional knowledge-ingest hook,
# and finish with the advisory kit-sync drift check. Destructive: it merges, closes, and prunes.
# First of all it re-reads the parent body and refuses an effort whose `## Spec` fails spec_lint
# (E546.5); --no-spec-check skips that one check and says so on stderr.
_EO_CLOSE_USAGE='cckit effort close <slug|N> [--no-spec-check]   squash-merge the effort PR, close the parent and its finished subs (unfinished subs stay open, linked, and are listed), GC'
effort_close() {
  case "${1:-}" in -h|--help) echo "$_EO_CLOSE_USAGE"; return 0 ;; esac
  _eff_forge || return 1; _eff_need jq || return 1
  local raw="" spec_check=1 num repo base branch root self_wt trace_dir kit_touched kit_manifest
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) echo "$_EO_CLOSE_USAGE"; return 0 ;;
      --no-spec-check) spec_check=0; shift ;;
      -*) echo "effort_close: unknown flag $1" >&2; return 2 ;;
      *)  [ -z "$raw" ] && raw="$1"; shift ;;
    esac
  done
  [ -n "$raw" ] || { echo "effort_close: <slug|effort issue #> required" >&2; return 1; }
  num="$(effort_slug_resolve "$raw")" || { echo "effort_close: could not resolve '$raw' to an effort" >&2; return 1; }
  repo="$(_eff_repo)"; base="$(_eff_base)"
  _eo_spec_check "$repo" "$num" "$spec_check" || return 1
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  case "$branch" in
    effort/"$num"-*) : ;;
    *)
      # Not on the integration branch. If effort/<num>-… exists (locally or on origin), this is
      # just the wrong cwd — keep the instruction. If it exists NOWHERE, this is a WAVE-style
      # effort (#164): the subs shipped as individual task PRs squash-merged straight to base, so
      # there is no branch to run from — close via the merged sub PRs instead.
      if [ -n "$(git branch --list "effort/$num-*" 2>/dev/null)" ] \
         || [ -n "$(git ls-remote --heads origin "effort/$num-*" 2>/dev/null)" ]; then
        echo "effort_close: run from the effort/$num-… branch" >&2; return 1
      fi
      _eo_close_wave "$num" "$repo" "$base"; return $? ;;
  esac
  root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / && !hit {print $2; hit=1}')"
  self_wt="$(git rev-parse --show-toplevel 2>/dev/null)"
  _eo_source_metrics

  # (pre) optional project gate (effort.preCloseHook, #380) — before the snapshot, so a refusal
  # writes nothing: no trace, no metrics row, no merge.
  _eo_pre_close_hook "$num" "$repo" "$root" "$self_wt" || return 1

  # (a) snapshot the per-sub-issue diffs while the unsquashed history still exists (echoes the trace dir).
  trace_dir="$(effort_snapshot_subs "$num" "origin/$base" 2>/dev/null)"

  # (a2) refuse-squash-without-trace backstop: the squash is irreversible and collapses the per-sub
  # commits that ARE the work record. If nothing was snapshotted, refuse — unless KIT_FORCE=1.
  # index.jsonl is the marker, not the presence of a .diff: the snapshot moves it into place only
  # after every record is written, so a non-empty index means a complete trace. The old `ls *.diff`
  # test passed on the empty NN-.diff a collapsed run left behind (#339).
  if [ -z "$trace_dir" ] || [ ! -s "$trace_dir/index.jsonl" ]; then
    if [ "${KIT_FORCE:-0}" = "1" ]; then
      echo "effort_close: no per-sub work trace captured — proceeding anyway (KIT_FORCE=1)" >&2
    else
      echo "effort_close: refusing to squash-merge #$num — no per-sub work trace was captured; the squash would erase the per-sub history irrecoverably. Run from the effort branch with its commits present, or set KIT_FORCE=1 to override." >&2
      return 1
    fi
  fi

  # (a2) refuse a conflicting PR before anything is written (#394). The capture below appends a
  # records.jsonl row and consumes the effort's start marker, so a merge that fails after it leaves a
  # row the retry duplicates with build_seconds null. UNKNOWN (GitHub still computing) proceeds.
  local rest_pr="" rest_meta="" mergeable
  # A failed read, or no open PR, must stop here (#330): carrying on let the capture write its row
  # and consume the start marker before the merge failed.
  rest_pr="$(gh_rest_pr_for_head "$repo" "$branch" 2>/dev/null)" || rest_pr=""
  [ -n "$rest_pr" ] && rest_meta="$(gh_rest_pr_json "$repo" "$rest_pr" 2>/dev/null)" || rest_meta=""
  [ -n "$rest_meta" ] || {
    echo "effort_close: could not read the PR for $branch from GitHub (no PR, or the API is unavailable) — rerun when it answers (nothing was written)" >&2
    return 1
  }
  mergeable="$(printf '%s' "$rest_meta" | jq -r .mergeable)"
  if [ "$mergeable" = "CONFLICTING" ]; then
    echo "effort_close: the PR for $branch conflicts with $base — merge or rebase $base into it, then rerun (nothing was written)" >&2
    return 1
  fi

  # (a3) re-target the open PRs based on this branch before the squash deletes it (#358). Here, not
  # next to the merge, for the same reason as the conflict check: a refusal after the capture leaves
  # a records.jsonl row the retry duplicates. In the cloud the remote branch is kept (the proxy
  # rejects branch deletion), so nothing can close a dependent PR there and the step is skipped.
  if ! cckit_in_cloud; then
    _eo_retarget_dependents "$repo" "$branch" "$base" || return 1
  fi

  # (b) capture effort metrics PRE-squash (needs the live-branch diff + commit signals).
  command -v capture_effort_metrics >/dev/null 2>&1 && capture_effort_metrics "$num" "origin/$base" || true

  # (b2) record which kit-managed files this effort touched, PRE-squash (the branch is GC'd below,
  # so the live-branch diff is the reliable source). The warning itself is emitted last (step h).
  kit_touched="$(git diff --name-only "origin/$base"...HEAD 2>/dev/null \
    | _eo_kit_managed_filter . | sort -u || true)"
  kit_manifest="$(_eo_kit_manifest_file .)"

  # (b3) which subs are finished (#565, decision 52), read PRE-squash while the effort branch's
  # commits still exist. A sub is finished when it is already closed, or a commit on this branch
  # delivers it (_eo_delivered_refs). A sub no commit delivers is not detached: it closes WITH the
  # parent in step (e) (#650) and is listed as such in the close comment and in this output.
  local sub_rows delivered sub_split done_subs="" open_subs="" open_lines=""
  sub_rows="$(forge_rest "repos/$repo/issues/$num/sub_issues" \
    --jq '.[] | "\(.number)|\(.state)|\(.title // "")"' 2>/dev/null)" || sub_rows=""
  delivered="$(_eo_delivered_refs "origin/$base")"
  sub_split="$(printf '%s\n' "$sub_rows" | _eo_partition_subs "$num" "$delivered")"
  done_subs="$(printf '%s\n' "$sub_split" | awk -F'|' '$1 == "done" {print $2 "|" $3}')"
  open_subs="$(printf '%s\n' "$sub_split" | awk -F'|' '$1 == "open" {print $2}')"
  open_lines="$(printf '%s\n' "$sub_split" | awk -F'|' '$1 == "open" {t=$0; sub(/^[^|]*\|[^|]*\|/, "", t); print "- #" $2 (t == "" ? "" : " " t)}')"

  # (c) squash-merge the effort PR, then delete the remote branch (git, not the API). In a cloud
  # session the proxy rejects the deletion (#396): the branch is kept and the close says so.
  { [ -n "$rest_pr" ] && gh_rest_pr_merge "$repo" "$rest_pr" squash >/dev/null 2>&1; } \
    || { echo "effort_close: could not squash-merge the PR for $branch (open? mergeable?)" >&2; return 1; }
  echo "  ✓ merged $branch" >&2
  if cckit_in_cloud; then
    echo "  (remote branch $branch kept — branch deletion is unavailable here; delete it on GitHub)" >&2
  else
    git -C "${root:-.}" push origin --delete "$branch" >/dev/null 2>&1 && echo "  ✓ deleted remote branch $branch" >&2 \
      || echo "  (remote branch $branch not deleted — delete it on GitHub)" >&2
  fi
  # (c2) the effort's sub branches on origin, `sub/<N><letter>-*` (#651): the squash just put their
  # work on base, and step (f2) prunes only what has a local head. Read from origin (ls-remote, not
  # the cached refs), one `push --delete` each; a failed delete warns and never fails the close.
  _eo_delete_remote_subs "$num" "${root:-.}"

  # (d) judge the metrics (reads the durable trace dir; the record stays in the local buffer).
  command -v judge_effort_metrics >/dev/null 2>&1 && judge_effort_metrics "$num" "origin/$base" || true

  # (e) close the FINISHED sub-issues (#565), then the parent, then every sub still open — with the
  # parent's reason and one comment naming it, through the shared gh_rest_close_open_subs (#650) —
  # and set the board Status=Done for each (guarded: a no-op when Projects v2 is off or the board
  # helpers/ids are unavailable). A sub already closed keeps its own close reason (no second
  # PATCH). Board + issue + record state are owned by this ONE op (effort-model.md) — never a
  # separate "mark done".
  _eo_source_board
  local sub sstate done_list="" comment
  while IFS='|' read -r sub sstate; do
    [ -n "$sub" ] || continue
    if [ "$sstate" = closed ]; then
      echo "  ✓ sub #$sub already closed" >&2
    else
      _eo_issue_close_completed "$repo" "$sub" && echo "  ✓ closed sub #$sub" >&2
    fi
    _eo_board_done "$sub"
    done_list="${done_list:+$done_list, }#$sub"
  done <<EOF_DONE
$done_subs
EOF_DONE
  comment="$(_eo_close_comment "$branch" "$done_list" "$open_lines")"
  gh_rest_issue_close "$repo" "$num" completed "$comment" >/dev/null 2>&1 && echo "  ✓ closed effort #$num" >&2
  _eo_board_done "$num"
  if [ -n "$open_subs" ]; then
    local closed_with
    closed_with="$(gh_rest_close_open_subs "$repo" "$num" completed 2>/dev/null)" \
      || echo "  ⚠ could not close every sub-issue of #$num — check them on the forge" >&2
    while IFS= read -r sub; do
      [ -n "$sub" ] || continue
      echo "  ✓ closed sub #$sub with its parent (no commit on the effort branch delivers it)" >&2
      _eo_board_done "$sub"
    done <<EOF_WITH
$closed_with
EOF_WITH
  fi

  # (f) GC: switch the main checkout to base, remove the effort worktree, delete the local branch,
  # prune. The remote branch was deleted in step (c). All via `git -C "$root"` so the
  # caller's cwd is never moved. Best-effort — a GC hiccup never fails the (already-landed) close.
  if [ -n "$root" ]; then
    git -C "$root" checkout "$base" >/dev/null 2>&1 || true
    git -C "$root" pull origin "$base" --quiet >/dev/null 2>&1 || true
    # (f2) the effort's sub worktrees + branches (#388): the squash just put their work on base, so
    # kit_gc_prune's LANDED path deletes them — same classifier and recover-before-prune guards as
    # `cckit cleanup` (a dirty sub worktree, or a sub ahead of its remote, stays). Runs in a subshell
    # from the main checkout, BEFORE this worktree is removed, with the base `origin/<base>` just
    # pulled above. A sub that fails both LANDED checks is left as an ORPHAN for `cckit gc` to show.
    _eo_source_gc
    if command -v kit_gc_prune >/dev/null 2>&1; then
      ( cd "$root" && KIT_GC_REPO="$repo" KIT_BASE_BRANCH="$base" kit_gc_prune --yes --only "^sub/${num}[a-z]-" 2>&1 \
          | grep -E '^  (removed worktree|deleted local branch|SKIP)' | sed 's/^  /  ✓ sub gc: /' >&2 ) || true
    fi
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
  _eo_kit_sync_warn "$kit_touched" "$kit_manifest"

  # (i) the report's last word: the subs that closed with the parent, undelivered (#565, #650).
  if [ -n "$open_lines" ]; then
    echo "" >&2
    echo "  ⚠ #$num closed with sub-issues no commit delivered (closed with it, same reason):" >&2
    printf '%s\n' "$open_lines" | sed 's/^/     /' >&2
  fi
  return 0
}

# _eo_delivered_refs <base_ref> — what the commits in <base_ref>..HEAD deliver, one token per line:
# `#N` for an issue number, `E<n>.<k>` for a sub step id. A commit delivers (1) the LAST `#N` it
# mentions — the same commit→sub pairing effort_snapshot_subs writes to the trace, (2) every `#N`
# after a closing keyword (close/fix/resolve and their forms), and (3) every `[E<n>.<k>]` step tag.
# Pure git; prints nothing when there are no commits.
_eo_delivered_refs() {
  local sha msg
  git rev-list "$1..HEAD" 2>/dev/null | while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    msg="$(git log -1 --format='%s%n%b' "$sha" 2>/dev/null)"
    printf '%s\n' "$msg" | grep -oE '#[0-9]+' | tail -1
    printf '%s\n' "$msg" | grep -oiE '(close[sd]?|fix(e[sd])?|resolve[sd]?):?[[:space:]]+#[0-9]+' | grep -oE '#[0-9]+'
    printf '%s\n' "$msg" | grep -oE '\[E[0-9]+\.[0-9]+\]' | tr -d '[]'
  done | sort -u
}

# _eo_partition_subs <effort#> <delivered-refs> — stdin: "<sub#>|<state>|<title>" rows (state as the
# REST API spells it). stdout: "done|<sub#>|<state>" or "open|<sub#>|<title>", one per sub. A sub is
# done when it is already closed, its `#N` is in <delivered-refs>, or its title carries a step id
# `[E<effort>.<k>]` that a commit tagged. Pure: no forge, no git.
_eo_partition_subs() {
  local eff="$1" refs="$2" n st title step
  while IFS='|' read -r n st title; do
    [ -n "$n" ] || continue
    st="$(printf '%s' "$st" | tr '[:upper:]' '[:lower:]')"
    if [ "$st" = closed ]; then echo "done|$n|closed"; continue; fi
    if grep -qxF "#$n" <<<"$refs"; then echo "done|$n|$st"; continue; fi
    step="$(grep -oE "\[E$eff\.[0-9]+\]" <<<"$title" | sed -n 1p | tr -d '[]')"
    if [ -n "$step" ] && grep -qxF "$step" <<<"$refs"; then echo "done|$n|$st"; continue; fi
    echo "open|$n|$title"
  done
}

# _eo_close_comment <branch> <done-list> <open-lines> — the comment effort_close posts on the parent
# as it closes it: which subs closed with it and which stay open, linked (#565).
_eo_close_comment() {
  printf 'Closed by `cckit effort close` (merged `%s`).\n\n' "$1"
  printf 'Finished sub-issues: %s\n' "${2:-none}"
  if [ -n "${3:-}" ]; then
    printf '\nClosed with the parent, no commit on the effort branch delivers them:\n%s\n' "$3"
  fi
}

# _eo_spec_check <repo> <num> <1|0> — the close-time Spec check (E546.5), shared by both close
# styles because it runs before they split. 1: read the parent body and refuse, with spec_lint's
# reasons, when it has no checkable `## Spec`; a failed read refuses too, since an unread body is not
# a checked one. 0 (--no-spec-check): skip, and print one line recording that the check was skipped.
_eo_spec_check() {
  local repo="$1" num="$2" body
  if [ "${3:-1}" = 0 ]; then
    echo "effort_close: Spec check skipped for #$num (--no-spec-check) — the close does not confirm what done means" >&2
    return 0
  fi
  body="$(_eff_issue_body "$repo" "$num" 2>/dev/null)" || {
    echo "effort_close: could not read #$num's body to check its Spec — rerun when GitHub answers, or pass --no-spec-check (nothing was written)" >&2
    return 1
  }
  spec_lint "$body" && return 0
  echo "effort_close: refusing to close #$num — add a '## Spec' list to its body (what done means), or pass --no-spec-check (nothing was written)" >&2
  return 1
}

# _eo_kit_sync_warn <files> [<manifest>] — the advisory kit-sync drift warning, shared by both close
# styles; with no <manifest> (the path-pattern fallback, #652) it says so in one more line
# (#148/#164). If an effort changed kit-managed files they likely belong upstream (/kit-contribute);
# an un-upstreamed change is a latent regression the next /kit-update can clobber. Never blocks.
_eo_kit_sync_warn() {
  [ -n "${1:-}" ] || return 0
  {
    echo ""
    echo "  ⚠ kit-sync: this effort changed kit-managed files — review for upstream (/kit-contribute):"
    printf '%s\n' "$1" | sed 's/^/     /'
    echo "     kit ⇄ project must stay in sync; an un-upstreamed change can be clobbered by /kit-update."
    if [ -z "${2:-}" ]; then
      echo "     (no kit.manifest.json read: matched by path pattern, so a project-owned file under a kit directory may be listed)"
    fi
  } >&2
}

# _eo_close_wave <num> <repo> <base> — close a WAVE-style effort (#164): every sub was delivered as
# its own task PR squash-merged straight to base (`cckit effort plan --wave` → fan-out → `cckit watch --merge`),
# so no effort/<N> integration branch ever existed. Verifies every sub is CLOSED with a merged
# closing PR (refuses and lists the stragglers otherwise), snapshots the work trace from the merged
# sub PR diffs, then runs the SAME close tail as the branch path: judge the metrics, close the
# parent, board Status=Done for parent + subs, knowledge-ingest hook, kit-sync drift check.
# capture_effort_metrics is intentionally skipped — there is no live branch diff to measure; the
# merged PR diffs in the trace are the work record.
_eo_close_wave() {
  local num="$1" repo="$2" base="$3" root rows bad trace_dir kit_touched kit_manifest sub
  root="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree / && !hit {print $2; hit=1}')"
  _eo_source_metrics

  # (a) read every sub + the merged PR that closed it, one "sub|state|pr|merge-oid|title" line each
  # (title LAST so a stray "|" in it can't shift the fields awk/read split on).
  if cckit_gh_rest; then
    rows="$(gh_rest_wave_rows "$repo" "$num" 2>/dev/null)"
  else
  rows="$(forge_rest graphql -f query='
    query($o:String!,$r:String!,$n:Int!){ repository(owner:$o,name:$r){ issue(number:$n){
      subIssues(first:50){ nodes { number state
        closedByPullRequestsReferences(first:10){ nodes { number merged mergeCommit{oid} title } } } } } } }' \
    -F o="${repo%/*}" -F r="${repo#*/}" -F n="$num" --jq '
      .data.repository.issue.subIssues.nodes[]
      | (((.closedByPullRequestsReferences.nodes // []) | map(select(.merged)) | .[0]) // null) as $pr
      | "\(.number)|\(.state)|\($pr.number // "")|\($pr.mergeCommit.oid // "")|\($pr.title // "")"' 2>/dev/null)"
  fi
  [ -n "$rows" ] || { echo "effort_close: no effort/$num-… branch and no readable sub-issues — nothing to close (wave-style needs merged subs, #164)" >&2; return 1; }

  # (b) every sub must be CLOSED with a merged closing PR — otherwise the effort is not done.
  bad="$(printf '%s\n' "$rows" | awk -F'|' '$2 != "CLOSED" || $3 == "" {
    printf "  #%s (%s%s)\n", $1, tolower($2), ($3 == "" ? ", no merged PR" : "") }')"
  if [ -n "$bad" ]; then
    echo "effort_close: #$num is not done — these subs are still open or lack a merged PR:" >&2
    printf '%s\n' "$bad" >&2
    return 1
  fi

  # (pre) the same optional project gate as the branch path (#380), before the trace is written.
  # There is no effort worktree here, so it runs from the checkout the close was invoked in.
  _eo_pre_close_hook "$num" "$repo" "$root" "$(git rev-parse --show-toplevel 2>/dev/null)" \
    "$(printf '%s\n' "$rows" | cut -d'|' -f1)" || return 1

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

  # (d) judge the metrics off the trace (guarded, best-effort — same as the branch path).
  command -v judge_effort_metrics >/dev/null 2>&1 && judge_effort_metrics "$num" "origin/$base" || true

  # (e) kit-sync drift source: the union of files across the merged sub PR diffs.
  kit_touched="$(awk '/^diff --git /{print $3}' "$trace_dir"/*.diff 2>/dev/null | sed 's#^a/##' \
    | _eo_kit_managed_filter "${root:-.}" | sort -u || true)"
  kit_manifest="$(_eo_kit_manifest_file "${root:-.}")"

  # (f) close the parent + board Status=Done for parent and every sub (subs are already closed).
  _eo_source_board
  for sub in $(printf '%s\n' "$rows" | cut -d'|' -f1); do
    _eo_board_done "$sub"
  done
  _eo_issue_close_completed "$repo" "$num" && echo "  ✓ closed effort #$num" >&2
  _eo_board_done "$num"

  # (g) GC: the sub branches/worktrees were GC'd by their own merges — just prune stragglers.
  [ -n "$root" ] && git -C "$root" worktree prune >/dev/null 2>&1 || true

  # (h) same optional hook + advisory drift check as the branch path.
  _eo_knowledge_ingest "$num" "${trace_dir:-}" "$root"
  _eo_kit_sync_warn "$kit_touched" "$kit_manifest"
}
