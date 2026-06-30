#!/bin/sh
# render-test.sh — self-test for render.sh under bash AND zsh.
# Network-free, TTY-free: covers width clamping, the markdown table composers, and the pipe-safety
# guarantee (non-TTY in == verbatim out). Run:  bash scripts/lib/render-test.sh

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${RND_TEST_INNER:-}" ]; then
  . "$dir/ui.sh"
  . "$dir/render.sh"
  fail=0
  eq() { if [ "$2" != "$3" ]; then echo "FAIL($RND_TEST_INNER): $1 -> '[$2]', want '[$3]'"; fail=1; fi; }

  # render_width — clamp to [40,120].
  eq "width clamps high" "$(COLUMNS=999 render_width)" "120"
  eq "width clamps low"  "$(COLUMNS=5 render_width)"   "40"
  eq "width passes mid"  "$(COLUMNS=90 render_width)"  "90"
  eq "width junk -> safe" "$( (COLUMNS=abc; unset TERM; render_width) | grep -qE '^[0-9]+$' && echo ok)" "ok"

  # table composers.
  eq "table row"  "$(render_table_row '#76' 'M' 'plan')" "| #76 | M | plan |"
  eq "table sep"  "$(render_table_sep 3)"                "| --- | --- | --- |"
  eq "h1"         "$(render_h1 'Title')"                 "# Title"

  # pipe-safety: not a TTY here, so cckit_render must pass markdown through byte-for-byte.
  md="$(printf '# H\n\n| a | b |\n')"
  eq "render verbatim when piped" "$(printf '%s' "$md" | cckit_render)" "$md"
  # explicit CCKIT_NO_GLOW also forces verbatim.
  eq "render verbatim NO_GLOW" "$(printf '%s' "$md" | CCKIT_NO_GLOW=1 cckit_render)" "$md"

  if [ "$fail" -eq 0 ]; then echo "PASS($RND_TEST_INNER): render seam"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  RND_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
