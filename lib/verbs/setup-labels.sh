#!/usr/bin/env bash
# Create the agent:/ctx:/flow:/kind:/priority:/role: label families, plus the single labels
# `effort` and `backlog`, on the repo. Idempotent.
# Holds no label list of its own (#639): every set is read from the kit file that owns it —
#   kind:     KIT_KINDS, KIT_CONTENT_KINDS   kinds.sh
#   priority: KIT_PRIORITIES                 kinds.sh
#   ctx:      EFFORT_CTX_BUCKETS             effort-metrics.sh (beside effort_ctx_bucket)
#   flow:     EFFORT_FLOWS, lowercased       effort.sh (config effort.flows[] overrides)
#   role:     KIT_ROLES                      the project config
#   agent:    agents.profiles                the project config
# and every description from kit_label_desc (kinds.sh), the one `cckit effort new|sub` uses too.
# Usage: setup-labels.sh [--dry-run]   --dry-run prints `name<TAB>color<TAB>description` per label
#        and writes nothing (the same list KIT_LABELS_LIST=1 gives `cckit init`).
# These are exactly the labels `cckit effort new` / /kit-effort-new apply — provision them here so a
# fresh repo can create a fully-labeled effort with no manual label creation. Run from project root.
# The families are the ones rules/naming-and-ids.md § Labels documents, each with a reader; `slug:`
# is per-effort and created by `effort new`.
# The forge port (E537): every GitHub call goes through forge_* / gh_rest_* (scripts/lib/gh-rest.sh).
# This script ships to projects as scripts/setup-labels.sh, beside scripts/lib/; in the cckit repo it lives in
# lib/verbs/, beside lib/core/ and lib/forge/ (#602). _kit_lib finds a helper in either layout.
_kit_dir="$(cd "$(dirname "$0")" && pwd)"
case "$_kit_dir" in */lib/verbs) _kit_dir="$(cd "$_kit_dir/.." && pwd)" ;; esac   # scripts/ or lib/
_kit_lib() {
  local c
  for c in "$_kit_dir/lib/$1" "$_kit_dir/core/$1" "$_kit_dir/forge/$1" "$_kit_dir/verbs/$1"; do
    [ -f "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  printf '%s\n' "$_kit_dir/lib/$1"
}
if ! command -v gh_rest_issue_json >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(_kit_lib gh-rest.sh)"
fi

set -euo pipefail
case "${1:-}" in
  --dry-run) KIT_LABELS_LIST=1 ;;
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  "") : ;;
  *) echo "setup-labels: unknown argument '$1' (usage: setup-labels.sh [--dry-run])" >&2; exit 2 ;;
esac
# shellcheck source=/dev/null
source "$(_kit_lib kit-config.sh)" && load_kit_config
# shellcheck source=/dev/null
source "$(_kit_lib effort.sh)" 2>/dev/null || true          # EFFORT_FLOWS (flow:*)
# shellcheck source=/dev/null
source "$(_kit_lib kinds.sh)" 2>/dev/null || true           # KIT_KINDS, KIT_PRIORITIES, kit_label_desc
# shellcheck source=/dev/null
source "$(_kit_lib effort-metrics.sh)" 2>/dev/null || true  # EFFORT_CTX_BUCKETS (ctx:*)
for _sl_need in KIT_KINDS KIT_PRIORITIES EFFORT_CTX_BUCKETS EFFORT_FLOWS; do
  if [ -z "${!_sl_need:-}" ]; then
    echo "setup-labels: $_sl_need is unset — kinds.sh, effort.sh or effort-metrics.sh is missing beside this script" >&2
    exit 1
  fi
done
if ! command -v kit_label_desc >/dev/null 2>&1 || ! command -v kit_label_color >/dev/null 2>&1; then
  echo "setup-labels: kit_label_desc / kit_label_color missing — kinds.sh is out of date" >&2; exit 1
fi

# In list mode (KIT_LABELS_LIST=1) stdout is the TSV list alone: the section headers go to stderr,
# or `cckit init` would POST them as labels.
say() { if [ "${KIT_LABELS_LIST:-0}" = "1" ]; then echo "$@" >&2; else echo "$@"; fi; }

ensure_label() { # name color description
  # KIT_LABELS_LIST=1: print `name<TAB>color<TAB>description` and call nothing — `cckit init` reads
  # this list to create only the labels a repository lacks (#456).
  if [ "${KIT_LABELS_LIST:-0}" = "1" ]; then printf '%s\t%s\t%s\n' "$1" "$2" "$3"; return 0; fi
  case "$(gh_rest_label_upsert "$KIT_REPO" "$1" "$2" "$3" 2>/dev/null)" in
    created) echo "  ✓ $1" ;; updated) echo "  • $1 (exists)" ;; *) echo "  ✗ $1 (could not be created)" ;;
  esac
}

say "→ Labels on $KIT_REPO"
# The one label that marks a parent AS an effort, and the one `effort_plan` queries. It was read
# and never provisioned, so `cckit effort plan` found nothing on every repo.
say "effort:"
ensure_label "effort" "$(kit_label_color effort)" "$(kit_label_desc effort)"
# `backlog` marks a standalone issue parked on purpose (#647): loose_issues_list skips it when the
# project has no board (github.projectsV2 false). With the board on, Status = Backlog is the marker.
say "backlog:"
ensure_label "backlog" "$(kit_label_color backlog)" "$(kit_label_desc backlog)"
say "kinds:"
# The closed set of rules/branch-naming.md — a kind is also the branch prefix `cckit start` cuts, so
# the two lists are one list.
for k in $KIT_KINDS; do ensure_label "kind:$k" "$(kit_label_color kind)" "$(kit_label_desc kind "$k")"; done
# Content kinds (#417) — post, campaign, brand, research — are provisioned only for a project whose
# config sets `kinds.content: true` (the content and marketing profiles do). A software project
# would carry four labels that never vary.
if [ "${KIT_CONTENT_KINDS_ON:-false}" = "true" ]; then
  for k in ${KIT_CONTENT_KINDS:-}; do ensure_label "kind:$k" "$(kit_label_color kind)" "$(kit_label_desc kind "$k")"; done
fi
say "priorities:"
for p in $KIT_PRIORITIES; do
  ensure_label "priority:$p" "$(kit_label_color priority "$p")" "$(kit_label_desc priority "$p")"
done
say "ctx (session weight):"
for c in $EFFORT_CTX_BUCKETS; do ensure_label "ctx:$c" "$(kit_label_color ctx)" "$(kit_label_desc ctx "$c")"; done
say "flows:"
for f in $EFFORT_FLOWS; do
  slug=$(echo "$f" | tr '[:upper:]' '[:lower:]')
  ensure_label "flow:$slug" "$(kit_label_color flow)" "$(kit_label_desc flow "$slug")"
done
say "roles:"
while IFS= read -r role; do
  [[ -z "$role" ]] && continue
  slug=$(echo "$role" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  ensure_label "role:$slug" "$(kit_label_color role)" "$(kit_label_desc role "$slug")"
done <<< "$KIT_ROLES"

# agent:<profile> — which agent profile a piece of work runs under (#319). Driven by the profiles
# the project actually declares, so the family stays bounded by the config rather than growing one
# label per issue. A project with no `agents.profiles` gets no agent: labels, which is correct:
# nothing reads them until a profile exists to name.
say "agents:"
_al_cfg=""
if command -v kit_config_path >/dev/null 2>&1; then _al_cfg="$(kit_config_path 2>/dev/null || true)"; fi
if [ -n "$_al_cfg" ] && [ -f "$_al_cfg" ] && command -v jq >/dev/null 2>&1; then
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    ensure_label "agent:$p" "$(kit_label_color agent)" "$(kit_label_desc agent "$p")"
  done <<< "$(jq -r '(.agents.profiles // {}) | keys[]' "$_al_cfg" 2>/dev/null)"
else
  say "  • no agents.profiles declared — skipping"
fi
say "✓ done"
