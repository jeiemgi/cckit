#!/usr/bin/env bash
# ux-ds-audit.sh — deterministic half of /kit-ux-audit's `consistency` lane.
#
# Nothing project-specific: the shared-UI barrel, the custom-class prefix and the theme css are all
# parameters (--primitives / --css-prefix / --css), so it runs against any design system.
#
# Emits RAW occurrence lists the `kit-ux-audit` skill classifies (LAYOUT / VISUAL / BEHAVIOR,
# variant proposals, sibling-screen comparison). Pure grep/perl ($0, no model call, no grep -P),
# scoped to a path, macOS-safe. This script never decides — it only finds.
#
# usage: scripts/ux-ds-audit.sh <path> [--exclude <regex>] [--primitives <index.ts>]
#                               [--css-prefix <prefix>] [--css <file.css>]
#   <path>        file or directory to audit (e.g. apps/web/src, apps/web/src/app/sign-in)
#   --exclude     regex of paths to skip (node_modules/.next/dist always skipped)
#   --primitives  the shared UI barrel to read primitive names from (default packages/ui/src/index.ts)
#   --css-prefix  custom-class prefix to hunt in TSX/JSX (no default; section 8's TSX hunt is
#                 skipped when omitted — the data-* and dead-CSS probes still run)
#   --css         theme css file(s) to cross-check custom classes against (repeatable)
set -eu   # no pipefail: many probes end in a grep that legitimately finds nothing

USAGE="usage: ux-ds-audit.sh <path> [--exclude re] [--primitives index.ts] [--css-prefix p] [--css file]"
TARGET=""; EXCLUDE='__never__'; PRIMS="packages/ui/src/index.ts"; CSS_PREFIX=""; CSS_FILES=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --exclude|--primitives|--css-prefix|--css)
      if [[ $# -lt 2 || -z "$2" ]]; then echo "ux-ds-audit: $1 needs a value" >&2; echo "$USAGE" >&2; exit 2; fi
      case "$1" in
        --exclude) EXCLUDE="$2" ;;
        --primitives) PRIMS="$2" ;;
        --css-prefix) CSS_PREFIX="$2" ;;
        --css) CSS_FILES+=("$2") ;;
      esac
      shift 2 ;;
    -h|--help) sed -n 2,20p "$0"; exit 0 ;;
    *) TARGET="$1"; shift ;;
  esac
done
[[ -n "$TARGET" ]] || { echo "$USAGE" >&2; exit 2; }
[[ -e "$TARGET" ]] || { echo "ux-ds-audit: no such path: $TARGET" >&2; exit 2; }

# The file set — TSX/JSX only, minus build output and the exclude regex.
files() {
  find "$TARGET" \( -name node_modules -o -name .next -o -name dist -o -name build \) -prune -o \
    -type f \( -name '*.tsx' -o -name '*.jsx' \) -print \
    | grep -Ev "$EXCLUDE" | sort
}
FILES=$(files)
COUNT=$(printf '%s\n' "$FILES" | grep -c . || true)
g() { printf '%s\n' "$FILES" | xargs grep -nE "$1" 2>/dev/null || true; }

section() { printf '\n## %s\n' "$1"; }
tally()   { local n; n=$(printf '%s' "$1" | grep -c . || true); printf '(%s hits)\n' "$n"; }

echo "# ux-ds-audit · $TARGET · $COUNT files · $(date +%F)"
[[ "$EXCLUDE" != "__never__" ]] && echo "excluding: $EXCLUDE"
echo "primitives barrel: $PRIMS · custom-class prefix: ${CSS_PREFIX:-(none — pass --css-prefix)}"

# 1. Shared-UI primitives rendered WITH a className — the variant-candidate pool.
section "1 PRIMITIVE_CLASSNAME — shared primitives carrying a className (classify LAYOUT / VISUAL / BEHAVIOR)"
if [[ -f "$PRIMS" ]]; then
  NAMES=$(perl -0ne 'while(/export\s*\{([^}]*)\}/g){for(split /,/,$1){s/^\s+|\s+$//g; next if /^type\s/; next unless /^[A-Z]/; print "$_\n"}}' "$PRIMS" | sort -u | paste -sd'|' -)
  export NAMES
  OUT=$(printf '%s\n' "$FILES" | while IFS= read -r f; do perl -0ne '
      my $names = $ENV{NAMES};
      while (/<($names)\b((?:(?!(?<!=)>)[\s\S])*?)className=\s*(\{[^}]*\}|"[^"]*")/g) {
        my ($c,$cls)=($1,$3); my $ln = (substr($_,0,$-[0]) =~ tr/\n//)+1;
        $cls =~ s/\s+/ /g; print "$ARGV:$ln\t$c\t$cls\n";
      }' "$f"; done)
  tally "$OUT"; printf '%s\n' "$OUT"
  printf '\nper component:\n'; printf '%s\n' "$OUT" | awk -F'\t' 'NF{c[$2]++} END{for(k in c) printf "  %3d  %s\n", c[k], k}' | sort -rn
else
  echo "(primitives barrel not found: $PRIMS — pass --primitives; section skipped)"
fi

# 2. Hand-rolled page headers: a heading carrying a type-* / display role.
section "2 HEADINGS — <h1-3> with a type-*/display role outside a PageHeader primitive (align? eyebrow? actions? → PageHeader variant)"
OUT=$(g '<h[1-3][^>]*className="[^"]*(type-(hero|section|h1|h2|display|title)|text-(3xl|4xl|5xl))'); tally "$OUT"; printf '%s\n' "$OUT"

# 3. Hand-rolled card surfaces: card chrome typed by hand on a non-Card element.
section "3 CARD_SURFACES — rounded + border + surface/elevated bg typed by hand (→ Card / Card asChild)"
OUT=$(g 'className="[^"]*rounded-(md|lg|xl|2xl)' | grep -E 'className="[^"]*border(-border)?-(default|subtle|muted)?' | grep -E 'className="[^"]*bg-(surface|elevated|card|background)' | grep -v '<Card' || true)
tally "$OUT"; printf '%s\n' "$OUT"

# 4. Hand-rolled skeletons.
section "4 SKELETONS — animate-pulse outside the UI package (→ Skeleton); per file + fill-token drift"
OUT=$(g 'animate-pulse'); tally "$OUT"
printf '%s\n' "$OUT" | cut -d: -f1 | sort | uniq -c | sort -rn | awk '{printf "  %3d  %s\n", $1, $2}'
printf 'fill tokens used: '; printf '%s\n' "$OUT" | grep -oE 'bg-[a-z-]+' | sort | uniq -c | sort -rn | awk '{printf "%s×%s ", $2, $1}'; echo

# 5. Status / live-region lines.
section "5 STATUS_LINES — role=status|alert / aria-live typed by hand (tone drift? → StatusText / Alert)"
OUT=$(g 'role="(status|alert)"|aria-live='); tally "$OUT"; printf '%s\n' "$OUT"

# 6. Raw controls + link-as-text recipes.
section "6 RAW_CONTROLS — raw <button|input|select|textarea> (→ Button/Input/…) and underline link recipes (→ TextLink)"
OUT=$(g '<(button|input|select|textarea)\b' | grep -v 'type="hidden"' || true); tally "$OUT"; printf '%s\n' "$OUT"
printf -- '-- underline links:\n'; OUT=$(g 'className="[^"]*\bunderline\b'); tally "$OUT"; printf '%s\n' "$OUT"

# 7. Card grids — distinct recipes, so page ↔ loading drift shows up.
section "7 CARD_GRIDS — grid grid-cols-* recipes (→ CardGrid variants; page vs loading.tsx must match)"
OUT=$(g 'className="[^"]*\bgrid\b[^"]*grid-cols-'); tally "$OUT"
printf '%s\n' "$OUT" | grep -oE 'className="[^"]*"' | perl -pe 's/\b(m[tbxy]?|p[tbxy]?)-[0-9.]+ ?//g; s/[ \t]+/ /g; s/ "/"/g' | sort | uniq -c | sort -rn | awk '{c=$1; $1=""; printf "  %3d  %s\n", c, $0}'
printf -- '-- occurrences:\n%s\n' "$OUT"

# 8. Custom theme classes + data-* styling hooks in TSX (variants in disguise vs page layout).
section "8 CUSTOM_CSS — custom classes and data-* styling hooks in TSX (restyling a primitive from outside = variant in disguise)"
if [[ -n "$CSS_PREFIX" ]]; then
  OUT=$(g "\b${CSS_PREFIX}[a-z0-9-]+"); tally "$OUT"
  printf '%s\n' "$OUT" | grep -oE "\b${CSS_PREFIX}[a-z0-9-]+" | sort | uniq -c | sort -rn | awk '{printf "  %3d  %s\n", $1, $2}'
  printf -- '-- occurrences:\n%s\n' "$OUT"
else
  echo "(no --css-prefix — skipping the TSX custom-class hunt; pass one to enable)"
fi
printf -- '-- data-* hooks (styling attributes, not Radix state):\n'; g '\bdata-[a-z-]+=(""|\{)' | grep -vE 'data-(slot|state|side|variant|size|orientation|disabled|testid)=' || true
if [[ -n "$CSS_PREFIX" && ${#CSS_FILES[@]} -gt 0 ]]; then
  printf -- '-- defined in css but ZERO tsx references (dead):\n'
  for css in "${CSS_FILES[@]}"; do
    [[ -f "$css" ]] || { echo "  (css not found: $css)"; continue; }
    grep -oE "\.${CSS_PREFIX}[a-z0-9-]+" "$css" | sort -u | tr -d . | while read -r cls; do
      n=$(printf '%s\n' "$FILES" | xargs grep -l "\b$cls\b" 2>/dev/null | wc -l | tr -d ' ')
      if [[ "$n" == "0" ]]; then echo "  $cls  ($css)"; fi
    done
  done
  printf -- '-- css rules that reach INTO a primitive (descendant selector on a data-slot / role):\n'
  grep -nE "\.${CSS_PREFIX}[a-z0-9-]+[^{]*\[data-slot=|\.${CSS_PREFIX}[a-z0-9-]+[^{]*\[role=" "${CSS_FILES[@]}" 2>/dev/null || echo "  (none)"
fi

# 9. Icon size/stroke props — metadata that should live in the primitive.
section "9 ICON_PROPS — <XxxIcon size={N} strokeWidth={S}> repeated tuples (→ the primitive owns icon sizing)"
OUT=$(g '<[A-Z][A-Za-z]*Icon\b'); tally "$OUT"
printf -- '-- occurrences (file:line):\n%s\n' "$OUT"
printf -- '-- size/stroke tuples:\n'
printf '%s\n' "$FILES" | xargs perl -0ne 'while(/<[A-Za-z]*Icon\b((?:(?!\/>)[\s\S])*?)\/>/g){my $a=$1; my ($s)=$a=~/size=\{(\d+)\}/; my ($w)=$a=~/strokeWidth=\{([\d.]+)\}/; printf "size=%s stroke=%s\n", $s//"-", $w//"-"}' 2>/dev/null | sort | uniq -c | sort -rn | awk '{printf "  %3d  %s %s\n", $1, $2, $3}'

# 10. Repeated className literals (3+ times, multi-word) — component candidates, with their locations.
section "10 REPEATED_CLASSNAMES — identical multi-utility className literals appearing 3+ times (→ component or variant)"
REPEATED=$(printf '%s\n' "$FILES" | xargs grep -ohE 'className="[^"]{24,}"' 2>/dev/null | sort | uniq -c | sort -rn | awk '$1>=3{c=$1; $1=""; sub(/^ /,""); printf "%d\t%s\n", c, $0}' | head -30)
printf '%s\n' "$REPEATED" | awk -F'\t' 'NF{printf "  %3d  %s\n", $1, $2}'
printf -- '-- occurrences (file:line) per repeated literal:\n'
printf '%s\n' "$REPEATED" | cut -f2 | while IFS= read -r lit; do
  [[ -n "$lit" ]] || continue
  printf '  %s\n' "$lit"
  printf '%s\n' "$FILES" | xargs grep -nF -- "$lit" 2>/dev/null | cut -d: -f1,2 | sed 's|^|    |'
done

echo; echo "# end — classify with skills/kit-ux-audit/references/consistency.md"
