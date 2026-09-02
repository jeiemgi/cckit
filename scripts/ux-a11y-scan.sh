#!/usr/bin/env bash
# ux-a11y-scan.sh — deterministic detector for /kit-ux-audit's `a11y` lane.
#
# Emits RAW occurrence lists of semantic-HTML and accessibility smells the `kit-ux-audit` skill
# classifies (see references/a11y.md). Pure grep/perl ($0, no model call, no grep -P), scoped to a
# path, macOS-safe. It never decides — it only finds. Static regex over TSX/JSX, so it flags
# candidates, not confirmed defects; the model confirms and prioritizes.
#
# usage: scripts/ux-a11y-scan.sh <path> [--exclude <regex>]
set -eu

USAGE="usage: ux-a11y-scan.sh <path> [--exclude <regex>]"
TARGET=""; EXCLUDE='__never__'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "ux-a11y-scan: --exclude needs a value" >&2; exit 2; }
      EXCLUDE="$2"; shift 2 ;;
    -h|--help) sed -n 2,11p "$0"; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || { echo "$USAGE" >&2; exit 2; }
[[ -e "$TARGET" ]] || { echo "ux-a11y-scan: no such path: $TARGET" >&2; exit 2; }

FILES=$(find "$TARGET" \( -name node_modules -o -name .next -o -name dist -o -name build \) -prune -o \
  -type f \( -name '*.tsx' -o -name '*.jsx' \) -print | grep -Ev "$EXCLUDE" | sort)
COUNT=$(printf '%s\n' "$FILES" | grep -c . || true)
g() { printf '%s\n' "$FILES" | xargs grep -nE "$1" 2>/dev/null || true; }
section() { printf '\n## %s\n' "$1"; }
tally()   { local n; n=$(printf '%s' "$1" | grep -c . || true); printf '(%s hits)\n' "$n"; }

echo "# ux-a11y-scan · $TARGET · $COUNT files · $(date +%F)"
[[ "$EXCLUDE" != "__never__" ]] && echo "excluding: $EXCLUDE"

# A1. Non-semantic interactive elements — a click/key handler on a <div>/<span>, or role="button"
#     on a non-button without keyboard support. Should be <button> / <a>.
section "A1 NON_SEMANTIC_INTERACTIVE — onClick/onKeyDown on <div>/<span>, or role=button on a non-button (→ <button>/<a>)"
OUT=$(g '<(div|span|li|tr|td)\b[^>]*\bon(Click|KeyDown|KeyUp|KeyPress)='); tally "$OUT"; printf '%s\n' "$OUT"
printf -- '-- role="button|link|checkbox|tab" on a non-native element:\n'
g '<(div|span|li|a)\b[^>]*\brole="(button|link|checkbox|switch|tab|menuitem)"' || true
printf -- '-- redundant role on a native element (role="button" on <button>, role="link" on <a>):\n'
g '<button\b[^>]*\brole="button"|<a\b[^>]*\brole="link"|<nav\b[^>]*\brole="navigation"|<main\b[^>]*\brole="main"' || true

# A2. Missing text alternatives. (grep -E has no lookahead — filter with a second grep.)
section "A2 MISSING_TEXT_ALT — <img> without alt, decorative alt to confirm, icon-only SVG without a name"
printf -- '-- <img> with NO alt attribute on the line:\n'
g '<img\b' | grep -v 'alt=' || true
printf -- '-- <img alt=""> (decorative — confirm it carries no meaning):\n'
g '<img\b[^>]*\balt=""' || true
printf -- '-- <svg> as an image without aria-label/aria-labelledby/aria-hidden on the line:\n'
g '<svg\b' | grep -vE 'aria-label|aria-labelledby|aria-hidden|<title' || true

# A3. Unlabeled controls.
section "A3 UNLABELED_CONTROL — inputs without a name, icon-only buttons without a name"
printf -- '-- <input|select|textarea> with no id / aria-label / aria-labelledby on the line (needs a <label>):\n'
g '<(input|select|textarea)\b' | grep -vE '\b(id|aria-label|aria-labelledby)=' || true
printf -- '-- <label> without htmlFor on the line (implicit-wrap only if the control is nested — confirm):\n'
g '<label\b' | grep -v 'htmlFor=' || true
printf -- '-- <button> directly wrapping an icon/SVG with no aria-label on the line (same-line case):\n'
g '<button\b[^>]*>[[:space:]]*<([A-Z][A-Za-z]*Icon|svg)\b' | grep -v 'aria-label' || true

# A4. Heading order & landmarks.
section "A4 HEADING_LANDMARK — heading-level jumps, missing/duplicate landmarks, unnamed regions"
printf -- '-- files using <h3>/<h4>/<h5> but no <h1>/<h2> in the same file:\n'
printf '%s\n' "$FILES" | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if grep -qE '<h[345]\b' "$f" && ! grep -qE '<h[12]\b' "$f"; then echo "  $f"; fi
done
printf -- '-- more than one <main> in a file:\n'
printf '%s\n' "$FILES" | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  n=$(grep -oE '<main\b' "$f" | wc -l | tr -d ' '); [[ "${n:-0}" -gt 1 ]] && echo "  $f ($n)"
done
printf -- '-- landmark typed as a styled <div> (className with nav/header/footer/sidebar/main):\n'
g '<div\b[^>]*className="[^"]*\b(navbar|nav-|sidebar|site-header|site-footer|app-header|app-footer|main-content)\b' || true
printf -- '-- <section> / <article> with no accessible name on the line (no aria-label/aria-labelledby):\n'
g '<(section|article)\b' | grep -vE 'aria-label|aria-labelledby' || true

# A5. Focus & keyboard.
section "A5 FOCUS_KEYBOARD — positive tabindex, hover-only handlers, focus removed, aria-hidden on interactives"
printf -- '-- positive tabIndex (creates an unpredictable tab order):\n'
g 'tabIndex=\{[1-9][0-9]*\}|tabindex="[1-9]' || true
printf -- '-- onMouseOver/onMouseEnter without a matching onFocus on the line (keyboard cannot trigger it):\n'
g 'onMouse(Over|Enter)=' | grep -v 'onFocus=' || true
printf -- '-- focus outline removed with no focus-visible replacement in the same file:\n'
printf '%s\n' "$FILES" | while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if grep -qE 'outline-none|outline:\s*none|outline:\s*0' "$f" && ! grep -qE 'focus-visible|focusVisible' "$f"; then echo "  $f"; fi
done
printf -- '-- aria-hidden="true" on an element that also has a handler / tabIndex / href:\n'
g '<[a-zA-Z][^>]*\baria-hidden="true"[^>]*\b(onClick=|tabIndex=|href=)' || true
printf -- '-- autoFocus (moves focus on load — confirm it is wanted):\n'
g '\bautoFocus\b' || true

echo; echo "# end — classify with skills/kit-ux-audit/references/a11y.md"
