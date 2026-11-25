#!/usr/bin/env bash
# Create the project's milestones on the repo. Idempotent.
# Reads repo + milestones from .claude/kit.config.json. Run from project root.
# The forge port (E537): every GitHub call goes through forge_* / gh_rest_* (scripts/lib/gh-rest.sh).
# This script ships to projects as scripts/setup-milestones.sh, beside scripts/lib/; in the cckit repo it lives in
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
