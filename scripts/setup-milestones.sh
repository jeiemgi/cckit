#!/usr/bin/env bash
# Create the project's milestones on the repo. Idempotent.
# Reads repo + milestones from .claude/kit.config.json. Run from project root.
# The forge port (E537): every GitHub call goes through forge_* / gh_rest_* (scripts/lib/gh-rest.sh).
if ! command -v gh_rest_issue_json >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "$0")" && pwd)/lib/gh-rest.sh"
fi

set -euo pipefail
source "$(dirname "$0")/lib/kit-config.sh" && load_kit_config

echo "→ Milestones on $KIT_REPO"
existing=$(forge_rest "repos/$KIT_REPO/milestones?state=all" --jq '.[].title' 2>/dev/null || echo "")
while IFS= read -r m; do
  [[ -z "$m" ]] && continue
  if grep -qxF "$m" <<<"$existing"; then
    echo "  • $m (exists)"
  else
    forge_rest "repos/$KIT_REPO/milestones" -f title="$m" >/dev/null && echo "  ✓ $m"
  fi
done <<< "$KIT_MILESTONES"
echo "✓ done"
