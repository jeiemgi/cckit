#!/usr/bin/env bash
# showcase.sh — render the showcase dataset to screenshots + a docs gallery.
#
# Reads docs-site/showcase/showcase.json (the dataset), runs each (read-only / dry-run) cckit
# command through charmbracelet/freeze with forced color, writes one PNG per command to
# docs-site/public/showcase/, and regenerates the gallery page docs-site/src/content/docs/showcase.md.
# The PNGs + page are committed artifacts, so the site builds without freeze; only regenerating
# needs `freeze` (brew install charmbracelet/tap/freeze) and `jq`.
#
#   scripts/showcase.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT/docs-site/showcase/showcase.json"
IMG_DIR="$ROOT/docs-site/public/showcase"
GALLERY="$ROOT/docs-site/src/content/docs/showcase.md"

command -v jq >/dev/null     || { echo "showcase: jq required" >&2; exit 1; }
command -v freeze >/dev/null || { echo "showcase: freeze required (brew install charmbracelet/tap/freeze)" >&2; exit 1; }
[ -f "$MANIFEST" ]           || { echo "showcase: $MANIFEST not found" >&2; exit 1; }

# Use THIS checkout's cckit (so the captured behavior matches the branch), and force color so the
# screenshots show cckit's TTY-gated palette even though freeze captures without a real terminal.
# CCKIT_FORCE_COLOR is cckit-private (see ui.sh) so it never leaks into the gh/jq subprocesses.
export PATH="$ROOT/bin:$PATH"
export CCKIT_FORCE_COLOR=1
mkdir -p "$IMG_DIR"

# Gallery header.
{
  echo '---'
  echo 'title: Showcase'
  echo 'description: Every cckit capability at a glance — real command output captured as screenshots.'
  echo '---'
  echo
  echo 'A live tour of cckit, generated from a dataset (`docs-site/showcase/showcase.json`) by'
  echo '`scripts/showcase.sh`: each command is run for real and its output captured as a screenshot.'
  echo 'Every command here is read-only or a dry-run — safe to run yourself.'
  echo
} > "$GALLERY"

prev_group=""
fail=0
# Stream the dataset as tab-separated rows (no tabs/newlines inside fields).
while IFS=$'\t' read -r name group title cmd show; do
  [ -n "$name" ] || continue
  out="$IMG_DIR/$name.png"
  echo "==> $name : $cmd" >&2
  # </dev/null so freeze never consumes this loop's stdin (the jq dataset stream).
  if ! freeze --window --padding 20 --execute "$cmd" --output "$out" </dev/null >/dev/null 2>&1; then
    echo "    FAILED to render $name" >&2; fail=1; continue
  fi
  if [ "$group" != "$prev_group" ]; then
    printf '## %s\n\n' "$group" >> "$GALLERY"
    prev_group="$group"
  fi
  {
    printf '### %s\n\n' "$title"
    printf '```bash\n%s\n```\n\n' "$show"
    printf '![%s](/showcase/%s.png)\n\n' "$title" "$name"
  } >> "$GALLERY"
done < <(jq -r '.commands[] | [.name, .group, .title, .cmd, (.show // .cmd)] | @tsv' "$MANIFEST")

echo "==> wrote $GALLERY and PNGs to $IMG_DIR" >&2
exit "$fail"
