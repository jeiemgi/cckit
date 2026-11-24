#!/usr/bin/env bash
# terms-check.sh — the terms under ontology/terms/, their homes, and the skill routing.
#
#   bash scripts/terms-check.sh [--root <dir>] [--llm]
#
# 1. Every ontology/terms/<Term>.json validates (format: ontology/README.md): exactly the seven
#    fields id, label, definition, is_not, avoid, home, status; a sapling or a tree has a home.
# 2. Every home resolves: `cli` is a top-level verb of bin/cckit (the first word is checked, so
#    `effort plan` resolves through `effort`), `skill` is a folder with a SKILL.md under skills/ or
#    .claude/skills/, `rule` is a file. A seed's unresolved home is printed, not counted a defect.
# 3. skills/routing.yaml parses in its strict subset (stated at the top of that file); every entry
#    names an existing skill and an existing term or `none`; every skill under skills/ is routed;
#    each skill's `terms:` frontmatter line equals its routing terms.
# 4. AGENTS.md's "Which skill does what" table has one row per routed skill, with the same tasks
#    (joined by " · ") and terms (joined by ", ") as routing.yaml.
# 5. docs-site/src/content/docs/skills.mdx, when present, has one row per routed skill under the
#    `## <Label>` heading of one of its terms (`none` → "The kit itself") and no row for an unrouted one.
#
# Prints one `x <where>: <reason>` line per defect and one line of counts; --llm prints the counts
# as one JSON object on stdout and the defect lines on stderr. Exit 0 with no defect, 1 with one, 2 when jq is missing or ontology/terms/ is
# absent. bash + jq + awk only: cckit installs no YAML parser, so terms are JSON and the routing
# file is a flat subset awk reads. scripts/check.sh runs this in warn mode: it prints, never fails.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=human
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --json|--llm|--output=json) OUT=json; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "terms-check: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
cd "$ROOT" || exit 2

command -v jq >/dev/null 2>&1 || { echo "terms-check: jq is required" >&2; exit 2; }
[ -d ontology/terms ] || { echo "terms-check: no ontology/terms/ under $ROOT" >&2; exit 2; }

# Defect lines and notes go to stdout for a person; with --llm they go to stderr so stdout is one JSON object.
defects=0
say() { if [ "$OUT" = json ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi; }
x() { say "x $*"; defects=$((defects + 1)); }

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

# ── 2. every home resolves ───────────────────────────────────────────────────────────────────────
# Top-level verbs: the two-space-indented `label)` lines of the dispatcher's case, `|`-separated.
verbs=""
if [ -f bin/cckit ]; then
  verbs="$(grep -E '^  [a-z][a-z0-9|-]*\)' bin/cckit | sed -E 's/^  ([a-z0-9|-]*)\).*/\1/' | tr '|' '\n' | sort -u)"
fi
skill_dir() { # the folder holding <name>/SKILL.md, or nothing
  for d in skills .claude/skills; do [ -f "$d/$1/SKILL.md" ] && { echo "$d/$1"; return 0; }; done; return 1
}
homes=0; homes_ok=0
for stem in $valid_terms; do
  f="ontology/terms/$stem.json"
  status="$(jq -r .status "$f")"
  while IFS=$'\t' read -r kind value; do
    [ -n "$kind" ] || continue
    homes=$((homes + 1)); ok=0
    case "$kind" in
      cli)   grep -qx -- "${value%% *}" <<< "$verbs" && ok=1 ;;
      skill) skill_dir "$value" >/dev/null && ok=1 ;;
      rule)  [ -f "$value" ] && ok=1 ;;
    esac
    if [ "$ok" -eq 1 ]; then homes_ok=$((homes_ok + 1))
    elif [ "$status" = seed ]; then say "  seed $stem: home $kind $value does not exist yet (allowed)"
    else x "$f: home $kind $value does not exist"
    fi
  done < <(jq -r '.home | to_entries[] | "\(.key)\t\(.value)"' "$f")
done

# ── 3. the routing table ─────────────────────────────────────────────────────────────────────────
# routing.yaml → `task<TAB>skill<TAB>term` rows, or `!<line>: <reason>` for a line outside the subset.
routes=""
if [ -f skills/routing.yaml ]; then
  routes="$(awk '
    function bad(why) { printf "!%d: %s\n", NR, why; expect = 0; next_ok = 0 }
    BEGIN { expect = 0 }
    /^[[:space:]]*(#|$)/ { next }
    expect == 0 {
      if ($0 ~ /^- task: "[^"]+"$/) { task = $0; sub(/^- task: "/, "", task); sub(/"$/, "", task); expect = 1; next }
      bad("expected `- task: \"...\"`")
    }
    expect == 1 {
      if ($0 ~ /^  skill: [a-z][a-z0-9-]*$/) { skill = $2; expect = 2; next }
      bad("expected `  skill: <name>`")
    }
    expect == 2 {
      if ($0 ~ /^  term: ([A-Z][A-Za-z0-9]*|none)$/) { printf "%s\t%s\t%s\n", task, skill, $2; expect = 0; next }
      bad("expected `  term: <Term>` or `  term: none`")
    }
    END { if (expect != 0) printf "!%d: entry ends before its term line\n", NR }
  ' skills/routing.yaml)"
  while IFS= read -r line; do
    case "$line" in '!'*) x "skills/routing.yaml:${line#!}" ;; esac
  done <<< "$routes"
  routes="$(printf '%s\n' "$routes" | grep -v '^!' || true)"
else
  x "skills/routing.yaml: missing"
fi

all_terms="$(for f in ontology/terms/*.json; do [ -e "$f" ] && basename "$f" .json; done)"
routed_skills="$(printf '%s\n' "$routes" | awk -F'\t' 'NF==3{print $2}' | sort -u | grep . || true)"
no_term_skills="$(printf '%s\n' "$routes" | awk -F'\t' 'NF==3 && $3=="none"{print $2}' | sort -u | grep . || true)"
while IFS=$'\t' read -r task skill term; do
  [ -n "$skill" ] || continue
  skill_dir "$skill" >/dev/null || x "skills/routing.yaml: skill $skill has no SKILL.md"
  [ "$term" = none ] || grep -qx -- "$term" <<< "$all_terms" || x "skills/routing.yaml: term $term is not under ontology/terms/"
done <<< "$routes"

skills_total=0; unrouted=0; routed=0
for d in skills/*/; do
  [ -f "${d}SKILL.md" ] || continue
  s="$(basename "$d")"; skills_total=$((skills_total + 1))
  if grep -qx -- "$s" <<< "$routed_skills"; then
    routed=$((routed + 1))
    want="$(printf '%s\n' "$routes" | awk -F'\t' -v s="$s" '$2==s{print $3}' | sort -u | awk '{a = (a ? a ", " : "") $0} END{print a}')"
    have="$(awk '/^---/{c++; if (c==2) exit; next} c==1 && /^terms:/{sub(/^terms:[[:space:]]*/, ""); print; exit}' "${d}SKILL.md" \
            | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep . | sort -u | awk '{a = (a ? a ", " : "") $0} END{print a}')"
    [ "$have" = "$want" ] || x "${d}SKILL.md: terms: '$have' but skills/routing.yaml says '$want'"
  else
    unrouted=$((unrouted + 1)); x "skills/$s: not routed in skills/routing.yaml"
  fi
done

# ── 4. the same table in AGENTS.md ───────────────────────────────────────────────────────────────
if [ -f AGENTS.md ]; then
  # rows of the section, as `skill<TAB>tasks<TAB>terms`
  agents_rows="$(awk -F' \\| ' '
    /^## Which skill does what/ { in_sec = 1; next }
    in_sec && /^## / { exit }
    in_sec && /^\| / && !/^\| What you want/ && !/^\| ---/ {
      line = $0; sub(/^\| /, "", line); sub(/ \|$/, "", line); n = split(line, c, / \| /)
      if (n == 3) { gsub(/`/, "", c[2]); printf "%s\t%s\t%s\n", c[2], c[1], c[3] }
    }' AGENTS.md)"
  if [ -z "$agents_rows" ]; then
    x 'AGENTS.md: no "Which skill does what" table'
  else
    for s in $routed_skills; do
      want_tasks="$(printf '%s\n' "$routes" | awk -F'\t' -v s="$s" '$2==s{a = (a ? a " · " : "") $1} END{print a}')"
      want_terms="$(printf '%s\n' "$routes" | awk -F'\t' -v s="$s" '$2==s{a = (a ? a ", " : "") $3} END{print a}')"
      row="$(printf '%s\n' "$agents_rows" | awk -F'\t' -v s="$s" '$1==s{print; exit}')"
      if [ -z "$row" ]; then x "AGENTS.md: no row for $s"; continue; fi
      [ "$(printf '%s' "$row" | cut -f2)" = "$want_tasks" ] || x "AGENTS.md: $s tasks differ from skills/routing.yaml"
      [ "$(printf '%s' "$row" | cut -f3)" = "$want_terms" ] || x "AGENTS.md: $s terms differ from skills/routing.yaml"
    done
    while IFS=$'\t' read -r s _; do
      [ -n "$s" ] || continue
      grep -qx -- "$s" <<< "$routed_skills" || x "AGENTS.md: row for $s, which skills/routing.yaml does not route"
    done <<< "$agents_rows"
  fi
fi

# ── 5. the skills page, grouped by term ─────────────────────────────────────────────────────────
# docs-site/src/content/docs/skills.mdx (when present): every routed skill has one row, each row sits
# under the `## <Label>` heading of one of its terms (the term's preferred label, first letter
# upper-cased; `none` → "The kit itself"), and no row names a skill routing.yaml does not route.
PAGE=docs-site/src/content/docs/skills.mdx
if [ -f "$PAGE" ]; then
  heading_of() { # heading_of <Term|none>
    if [ "$1" = none ]; then echo "The kit itself"; return; fi
    jq -r '(if (.label | type) == "array" then .label[0] else .label end) | (.[:1] | ascii_upcase) + .[1:]' "ontology/terms/$1.json"
  }
  # rows as `skill<TAB>heading`, H2 headings only
  page_rows="$(awk '
    /^## / { h = $0; sub(/^## /, "", h); next }
    /^\| `[a-z][a-z0-9-]*` \|/ { s = $2; gsub(/`/, "", s); printf "%s\t%s\n", s, h }' "$PAGE")"
  for s in $routed_skills; do
    found="$(printf '%s\n' "$page_rows" | awk -F'\t' -v s="$s" '$1==s{print $2}')"
    n_rows="$(printf '%s\n' "$found" | grep -c . || true)"
    if [ "$n_rows" -eq 0 ]; then x "$PAGE: no row for $s"; continue; fi
    [ "$n_rows" -eq 1 ] || x "$PAGE: $s has $n_rows rows"
    ok=0
    for term in $(printf '%s\n' "$routes" | awk -F'\t' -v s="$s" '$2==s{print $3}' | sort -u); do
      [ "$found" = "$(heading_of "$term")" ] && ok=1
    done
    [ "$ok" -eq 1 ] || x "$PAGE: $s is under \"$found\", not under a heading of its terms"
  done
  while IFS=$'\t' read -r s _; do
    [ -n "$s" ] || continue
    [ -f "skills/$s/SKILL.md" ] || continue          # a scaffolded template skill, not one of skills/
    grep -qx -- "$s" <<< "$routed_skills" || x "$PAGE: row for $s, which skills/routing.yaml does not route"
  done <<< "$page_rows"
fi

# ── counts ───────────────────────────────────────────────────────────────────────────────────────
no_term=$(printf '%s\n' "$no_term_skills" | grep -c . || true)
if [ "$OUT" = json ]; then
  jq -n --argjson terms "$terms" --argjson homes "$homes" --argjson homes_ok "$homes_ok" \
    --argjson skills "$skills_total" --argjson routed "$routed" --argjson unrouted "$unrouted" \
    --argjson no_term "$no_term" --argjson defects "$defects" \
    '{terms: $terms, homes: $homes, homes_resolved: $homes_ok, skills: $skills, skills_routed: $routed,
      unrouted: $unrouted, skills_no_term: $no_term, defects: $defects, ok: ($defects == 0)}'
else
  printf 'terms-check: %d terms · %d/%d homes resolved · %d/%d skills routed · %d unrouted · %d with no term · %d defects\n' \
    "$terms" "$homes_ok" "$homes" "$routed" "$skills_total" "$unrouted" "$no_term" "$defects"
fi
[ "$defects" -eq 0 ]
