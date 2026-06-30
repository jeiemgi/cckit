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
# Verbs that render markdown (plan/next/copilot) must show their verbatim markdown in the gallery,
# not shell out to glow — keeps every screenshot deterministic regardless of the local toolchain.
export CCKIT_NO_GLOW=1
mkdir -p "$IMG_DIR"

# Normalized capture preset — EVERY screenshot is the SAME fixed size (920×400) with the same wrap,
# font, and line height, so the gallery is one coherent series that fits the docs column. The
# showcase is a small VISUAL teaser; the full command list lives on the CLI reference page as
# copyable text. Only include short, visual commands here so nothing clips at height 400.
FREEZE_PRESET=(--window --padding 20 --width 920 --height 400 --wrap 90 --font.size 14 --line-height 1.25)

# Gallery header.
{
  echo '---'
  echo 'title: Showcase'
  echo 'description: Every cckit capability at a glance — real command output captured as screenshots.'
  echo '---'
  echo
  echo 'A short visual tour of cckit — each shot is a real command run for real, captured at the same'
  echo 'size. For the **full command list** (copyable), see the [CLI reference](/cli-reference/); to'
  echo 'see how the verbs fit together, start with [the GitHub cycle](/github-cycle/).'
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
  if ! freeze "${FREEZE_PRESET[@]}" --execute "$cmd" --output "$out" </dev/null >/dev/null 2>&1; then
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
