#!/usr/bin/env bash
# Create the ctx:/flow:/kind:/priority:/role: label families on the repo. Idempotent.
# Reads repo + roles from .claude/kit.config.json; the flow vocabulary from effort.sh (EFFORT_FLOWS).
# These are exactly the labels `cckit effort new` / /kit-effort-new apply — provision them here so a
# fresh repo can create a fully-labeled effort with no manual label creation. Run from project root.
set -euo pipefail
source "$(dirname "$0")/lib/kit-config.sh" && load_kit_config
# shellcheck source=/dev/null
source "$(dirname "$0")/lib/effort.sh" 2>/dev/null || true   # for EFFORT_FLOWS (the flow:* vocabulary)

ensure_label() { # name color description
  gh label create "$1" --repo "$KIT_REPO" --color "$2" --description "$3" --force >/dev/null 2>&1 \
    && echo "  ✓ $1" || echo "  • $1 (exists)"
}

echo "→ Labels on $KIT_REPO"
echo "kinds:"
for k in task plan adr scaffold spike; do ensure_label "kind:$k" "5319e7" "Kind: $k"; done
echo "priorities:"
ensure_label "priority:p1" "b60205" "Now / blocking"
ensure_label "priority:p2" "fbca04" "Next"
ensure_label "priority:p3" "0e8a16" "Later"
echo "ctx (session weight):"
for c in S M L XL; do ensure_label "ctx:$c" "c5def5" "Session weight: $c"; done
echo "flows:"
for f in ${EFFORT_FLOWS:-Core UI API Docs Infra Auth Data Web App}; do
  slug=$(echo "$f" | tr '[:upper:]' '[:lower:]')
  ensure_label "flow:$slug" "0e8a16" "Flow: $f"
done
echo "roles:"
while IFS= read -r role; do
  [[ -z "$role" ]] && continue
  slug=$(echo "$role" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  ensure_label "role:$slug" "1d76db" "Role: $role"
done <<< "$KIT_ROLES"
echo "✓ done"
