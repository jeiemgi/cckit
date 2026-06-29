#!/usr/bin/env bash
# ui.sh - terminal ergonomics, all detect-or-fallback (never a hard dependency, never required).
# Color is gated on a real TTY + NO_COLOR; optional tools (glow, fzf, gum) enhance output when
# present and degrade silently when not. Keeping this in one place gives every verb consistent,
# pipe-safe behavior: piped or non-tty output is always plain.

# ui_tty - true only when stdout is a real terminal (so pipes/redirects stay plain).
ui_tty() { [ -t 1 ]; }

# ui_color - true when we should emit ANSI color: a TTY, NO_COLOR unset, TERM not "dumb".
ui_color() { ui_tty && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; }

# ui_paint <ansi-code> <text> - color text when ui_color, else plain.
ui_paint() {
  if ui_color; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

# ui_page - pretty-render markdown on stdin with glow when present + interactive; else cat.
ui_page() {
  if ui_tty && command -v glow >/dev/null 2>&1; then glow -; else cat; fi
}

# ui_pick <prompt> - choose one line from stdin: fzf if present + interactive, else first line.
# Echoes the chosen line on stdout.
ui_pick() {
  if ui_tty && command -v fzf >/dev/null 2>&1; then
    fzf --prompt="${1:-pick> }" --height=40% --reverse
  else
    head -n1
  fi
}
