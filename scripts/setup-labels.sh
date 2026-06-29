#!/usr/bin/env bash
# Create the kind:/priority:/role: label families on the repo. Idempotent.
# Reads repo + roles from .claude/kit.config.json. Run from project root.
set -euo pipefail
source "$(dirname "$0")/lib/kit-config.sh" && load_kit_config

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
echo "roles:"
while IFS= read -r role; do
  [[ -z "$role" ]] && continue
  slug=$(echo "$role" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  ensure_label "role:$slug" "1d76db" "Role: $role"
done <<< "$KIT_ROLES"
echo "✓ done"
