#!/usr/bin/env bash
# Create the agent:/ctx:/flow:/kind:/priority:/role: label families on the repo. Idempotent.
# Reads repo + roles from .claude/kit.config.json; the flow vocabulary from effort.sh (EFFORT_FLOWS).
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
source "$(_kit_lib kit-config.sh)" && load_kit_config
# shellcheck source=/dev/null
source "$(_kit_lib effort.sh)" 2>/dev/null || true   # for EFFORT_FLOWS (the flow:* vocabulary)
# shellcheck source=/dev/null
source "$(_kit_lib kinds.sh)" 2>/dev/null || true    # for KIT_KINDS (the kind:* vocabulary)

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
ensure_label "effort" "5319e7" "An effort parent issue"
say "kinds:"
# The closed set of rules/branch-naming.md — a kind is also the branch prefix `cckit start` cuts, so
# the two lists are one list. The literal is the fallback for a project without lib/kinds.sh;
# scripts/lib/kinds-test.sh fails if it drifts from KIT_KINDS.
for k in ${KIT_KINDS:-feat fix task chore security scaffold ci adr spike plan}; do ensure_label "kind:$k" "5319e7" "Kind: $k"; done
# Content kinds (#417) — post, campaign, brand, research — are provisioned only for a project whose
# config sets `kinds.content: true` (the content and marketing profiles do). A software project
# would carry four labels that never vary. The literal is the fallback for a project without
# lib/kinds.sh; scripts/lib/kinds-test.sh fails if it drifts from KIT_CONTENT_KINDS.
if [ "${KIT_CONTENT_KINDS_ON:-false}" = "true" ]; then
  for k in ${KIT_CONTENT_KINDS:-post campaign brand research}; do ensure_label "kind:$k" "5319e7" "Kind: $k (content)"; done
fi
say "priorities:"
ensure_label "priority:p0" "8b0000" "Drop everything"
ensure_label "priority:p1" "b60205" "Now / blocking"
ensure_label "priority:p2" "fbca04" "Next"
ensure_label "priority:p3" "0e8a16" "Later"
say "ctx (session weight):"
for c in S M L XL; do ensure_label "ctx:$c" "c5def5" "Session weight: $c"; done
say "flows:"
for f in ${EFFORT_FLOWS:-Core UI API Docs Infra Auth Data Web App}; do
  slug=$(echo "$f" | tr '[:upper:]' '[:lower:]')
  ensure_label "flow:$slug" "0e8a16" "Flow: $f"
done
say "roles:"
while IFS= read -r role; do
  [[ -z "$role" ]] && continue
  slug=$(echo "$role" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  ensure_label "role:$slug" "1d76db" "Role: $role"
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
    ensure_label "agent:$p" "5319e7" "Agent profile: $p"
  done <<< "$(jq -r '(.agents.profiles // {}) | keys[]' "$_al_cfg" 2>/dev/null)"
else
  say "  • no agents.profiles declared — skipping"
fi
say "✓ done"
