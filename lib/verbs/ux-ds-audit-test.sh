#!/usr/bin/env bash
# shellcheck shell=bash
# ux-ds-audit-test.sh — section 11 of ux-ds-audit.sh finds off-grid values (C7) and raw radii (C8)
# from TSX and CSS fixtures, with the nearest grid value, and reports nothing on an on-grid file (#648).
# Hermetic: the fixtures are written under this test's own mktemp -d; invented names only.
# Run:  bash lib/verbs/ux-ds-audit-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/core/test-env.sh" && test_env_seal
SCRIPT="$ROOT/lib/verbs/ux-ds-audit.sh"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> output lacks '$3'"; fail=1 ;; esac; }
not() { case "$2" in *"$3"*) echo "FAIL: $1 -> output has '$3'"; fail=1 ;; *) echo "ok: $1" ;; esac; }
command -v perl >/dev/null 2>&1 || { echo "ux-ds-audit-test: perl required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/apps/demo/src" "$tmp/apps/clean/src"

# ── fixtures ─────────────────────────────────────────────────────────────────────────────────────
# Off-grid TSX: arbitrary Tailwind values, an inline style, and a nested tag with its parent's radius.
cat > "$tmp/apps/demo/src/card.tsx" <<'TSX'
export function Card() {
  return (
    <div className="p-[13px] gap-[0.8rem] md:w-[50px] rounded-[6px] text-[13px] leading-[18px]">
      <span className="p-[12px] gap-[1rem] rounded-[8px] text-[14px] text-[11px] -mt-[3px] border-[1px]" />
      <div style={{ padding: "13px", borderRadius: "6px", fontSize: "14px", gap: 16 }} />
      <div className="rounded-lg p-4"><img className="rounded-lg" alt="" /></div>
      <div className="rounded-full p-4"><img className="rounded-full" alt="" /></div>
      <div className="rounded-lg p-4"><img className="rounded-md" alt="" /></div>
    </div>
  );
}
TSX
# Theme css: an off-grid radius token, an off-grid type token, a raw radius, several declarations
# on one line, a token use (not a raw radius) and a media query.
cat > "$tmp/theme.css" <<'CSS'
:root {
  --radius-md: 0.375rem;
  --radius-lg: 0.5rem;
  --text-sm: 0.8rem;
  --font-size-base: 1rem;
}
.card { padding: 12px 13px; border-radius: 6px; border: 1px solid; }
.pill { border-radius: var(--radius-md); gap: 1.25rem; font-size: 0.75rem; line-height: 1.5; }
@media (min-width: 768px) { .card { margin: 0 } }
.tbl { border-top-left-radius: 4px; width: 100%; }
CSS
# On-grid TSX and css: nothing to report.
cat > "$tmp/apps/clean/src/tile.tsx" <<'TSX'
export function Tile() {
  return (
    <div className="p-4 gap-[1rem] w-[48px] rounded-md text-[14px] leading-[20px] border-[1px]">
      <div style={{ padding: "12px", fontSize: "16px", gap: 0 }} />
      <div className="rounded-full p-4"><img className="rounded-full" alt="" /></div>
    </div>
  );
}
TSX
cat > "$tmp/clean.css" <<'CSS'
:root { --radius-md: 0.5rem; --text-sm: 0.875rem; }
.tile { padding: 12px 16px; border-radius: var(--radius-md); border: 1px solid; font-size: 0.75rem; }
CSS

# ── off-grid fixture ─────────────────────────────────────────────────────────────────────────────
out="$(bash "$SCRIPT" "$tmp/apps/demo/src" --css "$tmp/theme.css" 2>&1 | sed -n '/^## 11 /,$p')"
s11="$(printf '%s\n' "$out" | sed "s|$tmp/||" | cut -f2-)"
has "section 11 header names C7 and C8" "$out" "## 11 OFF_GRID_RADII"
t   "C7 tally" "$(printf '%s\n' "$out" | grep -c $'\tC7 ')" "13"
t   "C8 tally" "$(printf '%s\n' "$out" | grep -c $'\tC8 ')" "6"
has "tally line C7" "$out" "C7 (13 hits)"
has "tally line C8" "$out" "C8 (6 hits)"
# rows carry file:line
has "row carries file:line" "$out" "apps/demo/src/card.tsx:3	C7 OFF_GRID	p-[13px]	13px	nearest 12px"
has "css row carries file:line" "$out" "theme.css:7	C8 RAW_RADIUS	border-radius: 6px	6px"
# C7: sizes round to a multiple of 4, type to an even px, rem at a 16px root
has "C7 px size → nearest 4px multiple" "$s11" "C7 OFF_GRID	p-[13px]	13px	nearest 12px"
has "C7 rem gap → nearest rem on the grid" "$s11" "C7 OFF_GRID	gap-[0.8rem]	0.8rem	nearest 0.75rem"
has "C7 variant prefix kept in context" "$s11" "C7 OFF_GRID	md:w-[50px]	50px	nearest 52px"
has "C7 odd font size → nearest even" "$s11" "C7 OFF_GRID	text-[13px]	13px	nearest 14px"
has "C7 font size below 12px" "$s11" "C7 OFF_GRID	text-[11px]	11px	nearest 12px"
has "C7 negative margin" "$s11" "C7 OFF_GRID	-mt-[3px]	3px	nearest 4px"
has "C7 inline style padding" "$s11" "C7 OFF_GRID	padding: 13px	13px	nearest 12px"
has "C7 inline style radius" "$s11" "C7 OFF_GRID	borderRadius: 6px	6px	nearest 8px"
has "C7 css radius token off grid" "$s11" "C7 OFF_GRID	--radius-md: 0.375rem	0.375rem	nearest 0.5rem"
has "C7 css type token off grid" "$s11" "C7 OFF_GRID	--text-sm: 0.8rem	0.8rem	nearest 0.75rem"
has "C7 second value of a css shorthand" "$s11" "C7 OFF_GRID	padding: 13px	13px	nearest 12px"
not "C7 on-grid value is no row" "$s11" "p-[12px]"
not "C7 on-grid rem is no row" "$s11" "gap-[1rem]"
not "C7 even font size is no row" "$s11" "text-[14px]"
not "C7 even line height is no row" "$s11" "leading-[18px]"
not "C7 1px hairline is a standing exception" "$s11" "border-[1px]"
not "C7 css hairline is a standing exception" "$s11" "border: 1px"
not "C7 media query is not a declaration" "$s11" "768px"
not "C7 unitless line-height is not a row" "$s11" "line-height: 1.5"
# C8: a literal radius is a row whether or not it is on the grid; a token use is not
has "C8 arbitrary radius off grid" "$s11" "C8 RAW_RADIUS	rounded-[6px]	6px"
has "C8 arbitrary radius on grid" "$s11" "C8 RAW_RADIUS	rounded-[8px]	8px"
has "C8 inline style radius" "$s11" "C8 RAW_RADIUS	borderRadius: 6px	6px"
has "C8 css raw radius" "$s11" "C8 RAW_RADIUS	border-radius: 6px	6px"
has "C8 css corner radius" "$s11" "C8 RAW_RADIUS	border-top-left-radius: 4px	4px"
has "C8 nested tag with the parent's radius" "$s11" "C8 NESTED_EQUAL	rounded-lg on a tag and the tag inside it	rounded-lg"
not "C8 token definition is not a raw radius" "$s11" "C8 RAW_RADIUS	--radius-md"
not "C8 var() use is not a raw radius" "$s11" "var(--radius-md)"
not "C8 rounded-full nests rounded-full" "$s11" "NESTED_EQUAL	rounded-full"
not "C8 different nested radii are left to the model" "$s11" "rounded-md on a tag"

# ── on-grid fixture: zero rows ───────────────────────────────────────────────────────────────────
clean="$(bash "$SCRIPT" "$tmp/apps/clean/src" --css "$tmp/clean.css" 2>&1 | sed -n '/^## 11 /,$p')"
has "clean: C7 tally is zero" "$clean" "C7 (0 hits)"
has "clean: C8 tally is zero" "$clean" "C8 (0 hits)"
t   "clean: no C7 or C8 row" "$(printf '%s\n' "$clean" | grep -c $'\tC[78] ')" "0"

# ── without --css only the TSX rows appear ───────────────────────────────────────────────────────
nocss="$(bash "$SCRIPT" "$tmp/apps/demo/src" 2>&1 | sed -n '/^## 11 /,$p')"
has "no --css: tsx rows still found" "$nocss" "p-[13px]"
not "no --css: no css row" "$nocss" "theme.css"

[ "$fail" -eq 0 ] && echo "ux-ds-audit-test: all passed"
exit "$fail"
