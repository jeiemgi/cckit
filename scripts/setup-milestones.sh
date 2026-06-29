#!/usr/bin/env bash
# Create the project's milestones on the repo. Idempotent.
# Reads repo + milestones from .claude/kit.config.json. Run from project root.
set -euo pipefail
source "$(dirname "$0")/lib/kit-config.sh" && load_kit_config

echo "→ Milestones on $KIT_REPO"
existing=$(gh api "repos/$KIT_REPO/milestones?state=all" --jq '.[].title' 2>/dev/null || echo "")
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  if echo "$existing" | grep -qxF "$m"; then
    echo "  • $m (exists)"
  else
    gh api "repos/$KIT_REPO/milestones" -f title="$m" >/dev/null && echo "  ✓ $m"
  fi
done <<< "$KIT_MILESTONES"
echo "✓ done"
