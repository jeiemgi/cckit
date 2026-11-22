#!/usr/bin/env bash
# terms-check.sh — validate the terms under ontology/terms/ (format: ontology/README.md).
#
#   bash scripts/terms-check.sh [--root <dir>] [--llm]
#
# Every ontology/terms/<Term>.json must hold exactly the seven fields: id (PascalCase, equal to
# the file name), label (a word or a list of words), definition (20+ characters), is_not (one or
# more clauses), avoid (a list, may be empty), home (an object with any of cli, skill, rule) and
# status (seed | sapling | tree). A sapling or a tree needs at least one home.
#
# Prints one `x <file>: <field>: <reason>` line per defect and one line of counts; --llm prints the
# counts as one JSON object. Exit 0 with no defect, 1 with one, 2 when jq is missing or the folder
# is absent. bash + jq only: cckit installs no YAML parser, so terms are JSON.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=human
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --llm|--output=json) OUT=json; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "terms-check: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
cd "$ROOT" || exit 2

command -v jq >/dev/null 2>&1 || { echo "terms-check: jq is required" >&2; exit 2; }
[ -d ontology/terms ] || { echo "terms-check: no ontology/terms/ under $ROOT" >&2; exit 2; }

defects=0
x() { printf 'x %s\n' "$*"; defects=$((defects + 1)); }

# ── 1. every term validates ──────────────────────────────────────────────────────────────────────
TERM_FILTER='
  def is_words: (type == "string" and length > 0)
    or (type == "array" and length > 0 and all(.[]; type == "string" and length > 0));
  def is_list: type == "array" and all(.[]; type == "string" and length > 0);
  [ (if (.id | type) == "string" and (.id | test("^[A-Z][A-Za-z0-9]*$")) then empty
     else "id: not PascalCase" end),
    (if .id == $stem then empty else "id: does not equal the file name \($stem)" end),
    (if .label | is_words then empty else "label: a word, or a list of words" end),
    (if (.definition | type) == "string" and (.definition | length) >= 20 then empty
     else "definition: under 20 characters" end),
    (if (.is_not | type) == "array" and (.is_not | length) >= 1 and (.is_not | is_list) then empty
     else "is_not: needs at least one clause" end),
    (if .avoid | is_list then empty else "avoid: a list of words (may be empty)" end),
    (if (.home | type) == "object" and ((.home | keys) - ["cli", "skill", "rule"] | length) == 0
        and all(.home[]; type == "string" and length > 0) then empty
     else "home: an object with any of cli, skill, rule" end),
    (if (.status | type) == "string" and (.status | IN("seed", "sapling", "tree")) then empty
     else "status: seed, sapling or tree" end),
    (if .status != "seed" and (.home | type) == "object" and (.home | length) == 0
     then "home: a sapling or a tree needs at least one" else empty end),
    ((keys - ["id", "label", "definition", "is_not", "avoid", "home", "status"])[]
     | "unknown field: \(.)")
  ] | .[]'

terms=0
valid_terms=""
for f in ontology/terms/*.json; do
  [ -e "$f" ] || break
  terms=$((terms + 1))
  stem="$(basename "$f" .json)"
  if ! jq -e 'type == "object"' "$f" >/dev/null 2>&1; then
    x "$f: not a JSON object"; continue
  fi
  bad=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    x "$f: $line"; bad=1
  done < <(jq -r --arg stem "$stem" "$TERM_FILTER" "$f")
  [ "$bad" -eq 0 ] && valid_terms="$valid_terms $stem"
done
[ "$terms" -gt 0 ] || x "ontology/terms/: no term file"

# ── counts ───────────────────────────────────────────────────────────────────────────────────────
if [ "$OUT" = json ]; then
  jq -n --argjson terms "$terms" --argjson defects "$defects" \
    '{terms: $terms, defects: $defects, ok: ($defects == 0)}'
else
  printf 'terms-check: %d terms · %d defects\n' "$terms" "$defects"
fi
[ "$defects" -eq 0 ]
