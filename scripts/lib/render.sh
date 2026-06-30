#!/usr/bin/env bash
# render.sh — the rendering seam: cckit's value-add for output (Effort 75 · #82, completes #9).
#
# cckit emits MARKDOWN. Two readers consume it:
#   - Claude Code (and any agent transcript): markdown renders natively — tables, headings, code —
#     so structured markdown IS the value-add. We just make sure verbs emit clean markdown.
#   - A human terminal: `glow` renders that same markdown richly when stdout is a TTY; without glow,
#     or when piped, the markdown passes through verbatim (still perfectly readable, still pipe-safe).
#
# One seam, every verb opts in: compose markdown with the helpers, pipe through `cckit_render`.
#
#   cckit_render          stdin markdown -> glow (TTY + glow) else verbatim (pipe-safe, always plain
#                         when not a terminal so machine consumers never see escape codes).
#   render_h1 <text>      a top sigil heading line.
#   render_table_row …    one markdown table row from N cells.
#   render_rule           a markdown horizontal rule.
#
# Depends on ui.sh (ui_tty). glow is optional; never required.

# render_width — target wrap width: COLUMNS if sane, else `tput cols`, else 100; clamped to [40,120]
# so rendered output fits a docs column / normal terminal and never sprawls.
render_width() {
  local w="${COLUMNS:-}"
  case "$w" in ''|*[!0-9]*) w="$(tput cols 2>/dev/null || echo 100)" ;; esac
  case "$w" in ''|*[!0-9]*) w=100 ;; esac
  [ "$w" -lt 40 ]  && w=40
  [ "$w" -gt 120 ] && w=120
  printf '%s' "$w"
}

# cckit_render — render markdown from stdin. Rich via glow only when interactive; otherwise verbatim.
# CCKIT_NO_GLOW=1 forces verbatim (tests, demos, when the caller wants raw markdown).
cckit_render() {
  if [ -z "${CCKIT_NO_GLOW:-}" ] && command -v ui_tty >/dev/null 2>&1 && ui_tty \
     && command -v glow >/dev/null 2>&1; then
    glow -w "$(render_width)" - 2>/dev/null || cat
  else
    cat
  fi
}

render_h1() { printf '# %s\n' "$1"; }
render_rule() { printf '\n---\n'; }

# render_table_row <cell> [cell …] — a single markdown table row: | a | b | c |
render_table_row() {
  local out="|"
  for cell in "$@"; do out="$out $cell |"; done
  printf '%s\n' "$out"
}

# render_table_sep <n> — the header separator row for an n-column markdown table.
render_table_sep() {
  local n="$1" out="|" i=1
  while [ "$i" -le "$n" ]; do out="$out --- |"; i=$((i + 1)); done
  printf '%s\n' "$out"
}
