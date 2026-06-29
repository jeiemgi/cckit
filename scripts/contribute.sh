#!/usr/bin/env bash
# contribute.sh - open a contribution PR to cckit, GATED on the local checks. The checks gate
# (scripts/check.sh: shell syntax, valid manifests, no stray branding, secret/privacy guard) MUST
# pass before anything is pushed - a red gate stops here. This is the agent-agnostic CLI half of
# the kit-contribute skill.
#
# Usage:
#   cckit contribute "<one-line summary>"   # gate -> push branch -> open PR to the upstream base
#   cckit contribute --dry-run "<summary>"  # run the gate + preconditions, push/PR nothing
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/kit-config.sh" && load_kit_config
repo="$KIT_REPO"; base="${KIT_BASE_BRANCH:-main}"

dry=0; summary=""
for a in "$@"; do
  case "$a" in --dry-run) dry=1 ;; *) summary="${summary:+$summary }$a" ;; esac
done

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
case "$branch" in
  ""|main|develop|"$base") echo "contribute: start a feature branch first (cckit start <issue>)." >&2; exit 2 ;;
esac

echo "==> contribute: checks gate (scripts/check.sh)"
if ! bash "$ROOT/scripts/check.sh"; then
  echo "contribute: checks gate FAILED - fix it before contributing (a green gate is the bar)." >&2
  exit 1
fi

git fetch origin "$base" --quiet 2>/dev/null || true
if [ -z "$(git log --oneline "origin/$base..$branch" 2>/dev/null)" ]; then
  echo "contribute: no commits ahead of $base on '$branch' - commit your change first." >&2; exit 2
fi

[ -n "$summary" ] || { echo "contribute: pass a one-line summary: cckit contribute \"<what + why>\"" >&2; exit 2; }

if [ "$dry" -eq 1 ]; then
  echo "contribute: DRY RUN - gate green, '$branch' has commits ahead of $base."
  echo "            would: push '$branch' + open a PR to $repo ($base) titled: $summary"
  exit 0
fi

git push -u origin "$branch" 2>&1 | tail -1
gh pr create --repo "$repo" --base "$base" --head "$branch" \
  --title "$summary" \
  --body "$(printf '## Contribution\n\n%s\n\nChecks gate (scripts/check.sh): green.\nDual-licensed MIT OR Apache-2.0 per CONTRIBUTING.md.\n' "$summary")"
