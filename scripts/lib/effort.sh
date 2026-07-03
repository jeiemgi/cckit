#!/usr/bin/env bash
# effort.sh — shared git-mechanics for the effort-* skill family (the effort model; rules/effort-model.md).
#
# Family 1 of the kit boundary (one bash home per op): consumed by the effort-{new,start,pr,close}
# skills. The skills are thin callers — no second implementation of these ops anywhere.
#
# Functions:
#   effort_link_sub <parent_num> <child_num>            link a native GitHub sub-issue (REST sub-issues API)
#   effort_branch_num                                   echo the effort issue # parsed from the current branch
#   effort_trace_dir <parent_num>                       echo (and mkdir -p) the trace dir under the git-common-dir
#   effort_snapshot_subs <parent_num> [base_ref]        snapshot per-sub-issue diffs BEFORE squash (work trace)
#   effort_title_lint <full-title>                      enforce the concise / no-jargon / flow-tagged title rule
#   effort_set_blocked_by <issue> <blocker>             set a native GitHub blocked_by dependency edge
#
# Requires: gh, jq, git. bash 3.2 compatible.

# Repo resolves from kit.config.json (KIT_REPO) — load it if a caller hasn't already.
if [[ -z "${KIT_REPO:-}" ]]; then
  _eff_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [[ -n "$_eff_root" && -f "$_eff_root/scripts/lib/kit-config.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_eff_root/scripts/lib/kit-config.sh" && load_kit_config >/dev/null 2>&1 || true
  fi
  unset _eff_root
fi
EFFORT_REPO="${EFFORT_REPO:-${KIT_REPO:-}}"

# Link a child issue as a native GitHub sub-issue of a parent.
# The sub-issues REST API takes the child's DATABASE id (not its number):
#   POST /repos/{owner}/{repo}/issues/{parent}/sub_issues  {"sub_issue_id": <child db id>}
effort_link_sub() {
  local parent="$1" child="$2" child_id
  [[ -n "$parent" && -n "$child" ]] || { echo "effort_link_sub: parent + child issue numbers required" >&2; return 1; }
  child_id="$(gh api "repos/$EFFORT_REPO/issues/$child" --jq .id 2>/dev/null)" \
    || { echo "effort_link_sub: could not resolve db id for #$child" >&2; return 1; }
  gh api --method POST "repos/$EFFORT_REPO/issues/$parent/sub_issues" \
    -F sub_issue_id="$child_id" >/dev/null 2>&1 \
    && { echo "  ✓ linked #$child as sub-issue of #$parent" >&2; return 0; } \
    || { echo "  ✗ failed to link #$child under #$parent (already linked? API unavailable?)" >&2; return 1; }
}

# Parse the effort issue number from an `effort/<N>-<slug>` branch. Echoes N (empty if no match).
effort_branch_num() {
  local branch="${1:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null)}"
  echo "$branch" | sed -nE 's#^effort/([0-9]+)-.*#\1#p'
}

# The durable trace dir for an effort: under the SHARED git-common-dir so it survives worktree prune
# and is visible from the main checkout (an exporter can consume it later). Echoes the path.
effort_trace_dir() {
  local parent="$1" common
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in /*) : ;; *) common="$(cd "$common" 2>/dev/null && pwd)" || return 1 ;; esac
  local dir="$common/traces/effort-$parent"
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s' "$dir"
}

# Snapshot per-sub-issue diffs BEFORE the effort PR is squash-merged (squash collapses the per-sub
# commit pairs that ARE the per-unit work record — see effort-model.md "Trace hard rules").
#
# Strategy (simple, exporter-consumable): for each commit on the effort branch that isn't on the
# base, write its diff + metadata to $traces/effort-<N>/<seq>-<shortsha>.{diff,meta}. We map a commit
# to a sub-issue by the LAST "#<num>" reference in its subject/body (the convention: one commit per
# sub-issue mentioning that sub-issue). Commits with no #ref still get snapshotted (sub="").
#
# Args: <parent_num> [base_ref=origin/main]
effort_snapshot_subs() {
  local parent="$1" base="${2:-origin/main}" branch dir shas seq=0
  [[ -n "$parent" ]] || { echo "effort_snapshot_subs: parent issue number required" >&2; return 1; }
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  dir="$(effort_trace_dir "$parent")" || { echo "effort_snapshot_subs: could not create trace dir" >&2; return 1; }

  git fetch origin --quiet 2>/dev/null || true
  # Oldest-first so <seq> increases with history.
  shas="$(git rev-list --reverse "$base..HEAD" 2>/dev/null)"
  if [[ -z "$shas" ]]; then
    echo "effort_snapshot_subs: no commits between $base and HEAD — nothing to snapshot" >&2
    return 0
  fi

  # An index file ties the snapshot together for an exporter.
  local index="$dir/index.jsonl"
  : > "$index"

  local sha sub subj body
  for sha in $shas; do
    seq=$((seq + 1))
    subj="$(git log -1 --format='%s' "$sha")"
    body="$(git log -1 --format='%b' "$sha")"
    # Last #<num> mentioned = the sub-issue this commit closes/implements (effort-model convention).
    sub="$(printf '%s\n%s' "$subj" "$body" | grep -oE '#[0-9]+' | tail -1 | tr -d '#')"
    local stub
    stub="$(printf '%02d-%s' "$seq" "$(git rev-parse --short "$sha")")"
    git show --no-color --format=fuller "$sha" > "$dir/$stub.diff" 2>/dev/null
    # meta: commit→sub-issue pairing + outcome hint for the record.
    jq -n --arg parent "$parent" --arg sub "${sub:-}" --arg sha "$sha" \
          --arg subject "$subj" --arg branch "$branch" --arg file "$stub.diff" \
      '{parent:($parent|tonumber), sub_issue:(if $sub=="" then null else ($sub|tonumber) end),
        commit:$sha, subject:$subject, branch:$branch, diff_file:$file, outcome:"merged"}' \
      > "$dir/$stub.meta"
    cat "$dir/$stub.meta" >> "$index"
  done

  echo "  ✓ snapshotted $seq commit(s) to $dir (index.jsonl)" >&2
  printf '%s' "$dir"
}

# effort_snapshot_merged_subs <parent> <rows> — the WAVE-style trace (#164): the subs were delivered
# as individual task PRs squash-merged to base, so there is no effort branch whose commits
# effort_snapshot_subs could walk. Snapshot each sub's merged PR diff instead. <rows> is the wave
# close's per-sub read, one "sub|state|pr|merge-oid|title" line each. Same layout as
# effort_snapshot_subs — $traces/effort-<N>/<seq>-<key>.{diff,meta} + index.jsonl — so exporters
# and the judge read both styles identically.
effort_snapshot_merged_subs() {
  local parent="$1" rows="$2" dir seq=0
  [[ -n "$parent" && -n "$rows" ]] || { echo "effort_snapshot_merged_subs: parent + sub rows required" >&2; return 1; }
  dir="$(effort_trace_dir "$parent")" || { echo "effort_snapshot_merged_subs: could not create trace dir" >&2; return 1; }

  local index="$dir/index.jsonl"
  : > "$index"

  local sub state pr oid title stub short
  while IFS='|' read -r sub state pr oid title; do
    [[ -n "$pr" ]] || continue
    seq=$((seq + 1))
    short="$(printf '%.7s' "$oid")"; [[ -n "$short" ]] || short="pr$pr"
    stub="$(printf '%02d-%s' "$seq" "$short")"
    gh pr diff "$pr" --repo "$EFFORT_REPO" > "$dir/$stub.diff" 2>/dev/null || rm -f "$dir/$stub.diff"
    [[ -s "$dir/$stub.diff" ]] || { rm -f "$dir/$stub.diff"; seq=$((seq - 1)); continue; }
    jq -n --arg parent "$parent" --arg sub "${sub:-}" --arg sha "${oid:-}" \
          --arg subject "$title" --arg pr "$pr" --arg file "$stub.diff" \
      '{parent:($parent|tonumber), sub_issue:(if $sub=="" then null else ($sub|tonumber) end),
        commit:(if $sha=="" then null else $sha end), pr:($pr|tonumber), subject:$subject,
        branch:null, diff_file:$file, outcome:"merged"}' \
      > "$dir/$stub.meta"
    cat "$dir/$stub.meta" >> "$index"
  done <<EOF_ROWS
$rows
EOF_ROWS

  echo "  ✓ snapshotted $seq merged sub PR diff(s) to $dir (index.jsonl)" >&2
  printf '%s' "$dir"
}

# ── Effort PR title — ONE composer shared by the verb + the skill (#121) ────────────────────────
# `cckit effort pr` (the verb) and /kit-effort-pr (the skill) previously composed different PR
# titles; they now both call effort_pr_title so an effort PR is titled identically no matter who
# opens it. The MANDATORY element is the [#N] effort id — a PR title without it is a review blocker
# (effort-model.md), enforced by effort_pr_title_check.
#
# effort_pr_title <num> <name> [role_display] — compose the canonical title:
#   effort_pr_title 115 "adoption hardening"             -> "[#115] adoption hardening"
#   effort_pr_title 115 "adoption hardening" "Tech Lead" -> "[Tech Lead] [#115] adoption hardening"
# A full parent title ("[Effort] 115 · [Core] adoption hardening") is accepted too — the
# "[Effort] N · " prefix is peeled so the id is never duplicated.
effort_pr_title() {
  local num="${1:-}" name="${2:-}" role="${3:-}"
  num="${num#\#}"
  name="$(printf '%s' "$name" | sed -E 's/^\[Effort\] [0-9]+ · ?//')"
  [ -n "$name" ] || name="effort"
  if [ -n "$role" ]; then printf '[%s] [#%s] %s' "$role" "$num" "$name"
  else printf '[#%s] %s' "$num" "$name"; fi
}

# effort_pr_title_check <title> [num] — rc 0 iff <title> carries the effort id token [#N] (the exact
# [#num] when given, else any [#digits]). Prints the reason + rc 1 when it doesn't, so both the verb
# and the skill can refuse to open a PR whose title lacks the effort id.
effort_pr_title_check() {
  local title="${1:-}" num="${2:-}"
  if [ -n "$num" ]; then
    num="${num#\#}"
    case "$title" in *"[#$num]"*) return 0 ;; esac
    echo "effort_pr_title_check: PR title lacks the [#$num] effort id: '$title'" >&2; return 1
  fi
  printf '%s' "$title" | grep -qE '\[#[0-9]+\]' && return 0
  echo "effort_pr_title_check: PR title lacks a [#N] effort id: '$title'" >&2; return 1
}

# ── Effort-title rule — concise, jargon-free, flow-tagged ──────────────────────────────────────────
# The board must say what an effort delivers and which FLOW it belongs to. So the `<Name>` part of an
# effort/sub title is a short plain-language outcome with an optional leading `[Flow]` tag from a
# controlled vocabulary — never internal jargon, glyphs, code identifiers, parentheticals, em-dash
# sub-clauses, or >6 words (detail goes in the body). See rules/effort-model.md § Titles.

# Controlled flow vocabulary for the optional leading [Flow] title tag. Resolution order (#150):
#   1. an explicit EFFORT_FLOWS env var always wins (per-invocation override)
#   2. the project config `effort.flows[]` — via KIT_EFFORT_FLOWS (exported by load_kit_config) or
#      read straight from the config file, so a configured vocabulary works even for callers that
#      never loaded the config
#   3. the built-in default.
_effort_flows_from_config() {
  if [[ -n "${KIT_EFFORT_FLOWS:-}" ]]; then printf '%s' "$KIT_EFFORT_FLOWS"; return 0; fi
  command -v jq >/dev/null 2>&1 || return 1
  # Locate the project config through the ONE shared resolver (config-path.sh sits next to this lib).
  if ! command -v kit_config_path >/dev/null 2>&1; then
    local _ef_dir; _ef_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
    # shellcheck source=/dev/null
    [[ -n "$_ef_dir" && -f "$_ef_dir/config-path.sh" ]] && . "$_ef_dir/config-path.sh"
  fi
  command -v kit_config_path >/dev/null 2>&1 || return 1
  local _ef_cfg; _ef_cfg="$(kit_config_path 2>/dev/null)" && [[ -f "$_ef_cfg" ]] || return 1
  jq -r '[.effort.flows[]? | tostring] | join(" ")' "$_ef_cfg" 2>/dev/null
}
if [[ -z "${EFFORT_FLOWS:-}" ]]; then EFFORT_FLOWS="$(_effort_flows_from_config 2>/dev/null || true)"; fi
EFFORT_FLOWS="${EFFORT_FLOWS:-Core UI API Docs Infra Auth Data Web App}"
# Jargon denylist — internal terms that read as noise on the board. Override via EFFORT_TITLE_JARGON.
EFFORT_TITLE_JARGON="${EFFORT_TITLE_JARGON:-chrome seam contract claim rescue stash teardown scaffolding shim boilerplate refactor wiring}"

# effort_title_lint <full-title> — 0 if the title is clean; 1 + reasons on stderr otherwise.
# Accepts "[Effort] N · [Flow] short name" or "[Effort N] M · short name".
effort_title_lint() {
  local title="$1" name flow rest
  local -a reasons=()
  [[ -n "$title" ]] || { echo "effort_title_lint: title required" >&2; return 2; }

  # 1. peel the structural prefix → the human name part.  parent: "[Effort] N · "  sub: "[Effort N] M · "
  name="$(printf '%s' "$title" | sed -E 's/^\[Effort( [0-9]+)?\] [0-9]+ · ?//')"
  [[ "$name" == "$title" ]] && reasons+=("missing the '[Effort] N · ' / '[Effort N] M · ' prefix")

  # 2. peel one optional leading [Flow] tag and validate it against the controlled vocabulary.
  if [[ "$name" =~ ^\[([A-Za-z]+)\]\ (.+)$ ]]; then
    flow="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"; name="$rest"
    case " $EFFORT_FLOWS " in
      *" $flow "*) : ;;
      *) reasons+=("flow tag [$flow] is not in the vocabulary ($EFFORT_FLOWS)") ;;
    esac
  fi

  # 3. the remaining name must be a concise, plain outcome phrase.
  case "$name" in *"("*|*")"*) reasons+=("no parentheses — detail goes in the body") ;; esac
  case "$name" in *" — "*|*" · "*|*" / "*) reasons+=("no ' — ' / ' · ' / ' / ' sub-clauses — one clear phrase") ;; esac
  case "$name" in *—*|*▾*|*▸*|*→*|*✓*|*✗*|*…*|*•*) reasons+=("no glyphs (— ▾ ▸ → ✓ ✗ … •) in the title") ;; esac
  # code identifiers: file extensions, snake_case, or a code-dir path.
  if printf '%s' "$name" | grep -qE '\.(sh|ts|tsx|js|mjs|json|css|md|ya?ml)([^A-Za-z0-9]|$)|[a-z0-9]+_[a-z0-9]+|(^|[^A-Za-z])(scripts|apps|packages|src)/'; then
    reasons+=("no code identifiers (file names, paths, snake_case) — name the outcome")
  fi
  # jargon denylist (word-boundary, case-insensitive).
  local w
  for w in $EFFORT_TITLE_JARGON; do
    printf '%s' "$name" | grep -qiwE "$w" && reasons+=("jargon word '$w' — use plain language")
  done
  # word count ≤ 6.
  local wc; wc=$(printf '%s\n' "$name" | wc -w | tr -d ' ')
  [[ "$wc" -gt 6 ]] && reasons+=("name is $wc words — keep it ≤ 6 (detail goes in the body)")

  if [[ "${#reasons[@]}" -gt 0 ]]; then
    { echo "✗ effort title fails the concise / no-jargon rule: $title"
      for w in "${reasons[@]}"; do echo "    - $w"; done
    } >&2
    return 1
  fi
  return 0
}

# effort_set_blocked_by <issue> <blocker-issue> — declare the native GitHub dependency "<issue> is
# blocked_by <blocker>" (the edge GitHub renders on the board). The API takes the blocker's DB id.
effort_set_blocked_by() {
  local issue="$1" blocker="$2" bid
  [[ -n "$issue" && -n "$blocker" ]] || { echo "effort_set_blocked_by: <issue> <blocker> required" >&2; return 1; }
  bid="$(gh api "repos/$EFFORT_REPO/issues/$blocker" --jq .id 2>/dev/null)" \
    || { echo "effort_set_blocked_by: could not resolve db id for #$blocker" >&2; return 1; }
  gh api --method POST "repos/$EFFORT_REPO/issues/$issue/dependencies/blocked_by" -F issue_id="$bid" >/dev/null 2>&1 \
    && { echo "  ✓ #$issue blocked_by #$blocker" >&2; return 0; } \
    || { echo "  ✗ failed to set #$issue blocked_by #$blocker (already set? API unavailable?)" >&2; return 1; }
}

# Self-test: `bash scripts/lib/effort.sh --selftest` exercises effort_title_lint (jargon → reject,
# plain → accept). Runs only when executed directly.
if [[ "${BASH_SOURCE[0]:-}" == "${0:-}" && "${1:-}" == "--selftest" ]]; then
  _et_rc=0
  _et_fail() { if effort_title_lint "$1" >/dev/null 2>&1; then echo "FAIL expected-reject passed: $1"; _et_rc=1; else echo "ok  reject: $1"; fi; }
  _et_pass() { if effort_title_lint "$1" >/dev/null 2>&1; then echo "ok  accept: $1"; else echo "FAIL expected-accept rejected: $1"; effort_title_lint "$1"; _et_rc=1; fi; }
  _et_fail "[Effort] 12 · operator chrome — Settings ▾ dropdown + layout fixes"
  _et_fail "[Effort 12] 4 · Section tables — columns + joins (contract B)"
  _et_fail "[Effort] 12 · refactor scripts/kit + quote-aware free-prompt args"
  _et_pass "[Effort] 12 · [UI] operator navigation"
  _et_pass "[Effort] 12 · effort planning conventions"
  _et_pass "[Effort 12] 4 · module tables"
  exit "$_et_rc"
fi
