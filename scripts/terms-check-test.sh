#!/usr/bin/env bash
# shellcheck shell=bash
# terms-check-test.sh — behavioral test of scripts/terms-check.sh. Builds a throwaway project under
# its own mktemp -d (no fixed port, no shared state) and checks that a well-formed term passes and
# that each field rule in ontology/README.md names the file and the field when broken.
# Run:  bash scripts/terms-check-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '$3' not in: $2"; fail=1 ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fx="$tmp/project"; mkdir -p "$fx/ontology/terms" "$fx/skills" "$fx/bin"; : > "$fx/skills/routing.yaml"
printf 'case "$cmd" in\n  effort) ;;\nesac\n' > "$fx/bin/cckit"
check() { bash "$ROOT/scripts/terms-check.sh" --root "$fx" "$@" 2>&1; }
checkj() { bash "$ROOT/scripts/terms-check.sh" --root "$fx" --llm 2>/dev/null; }
term() { # term <Stem> <json>
  printf '%s\n' "$2" > "$fx/ontology/terms/$1.json"
}
good='{"id":"Effort","label":["effort"],"definition":"One parent issue, one branch, one worktree, one PR.","is_not":["A task: a task is one issue with one PR."],"avoid":["epic"],"home":{"cli":"effort"},"status":"sapling"}'

# 1. one well-formed term passes and is counted
term Effort "$good"
out="$(check)"; rc=$?
t "well-formed term: exit 0" "$rc" "0"
has "counts line names 1 term" "$out" "1 terms"
out="$(checkj)"
t "--llm: one JSON object" "$(printf '%s' "$out" | jq -r '.terms, .ok' | tr '\n' ' ')" "1 true "

# 2. an empty folder is a defect
rm "$fx/ontology/terms/Effort.json"
out="$(check)"; rc=$?
t "no term file: exit 1" "$rc" "1"
has "no term file: named" "$out" "no term file"

# 3. each field rule, one broken file at a time; the defect line names the file and the field
broken() { # broken <label> <Stem> <json> <expected fragment>
  rm -f "$fx"/ontology/terms/*.json; term "$2" "$3"
  out="$(check)"; rc=$?
  t "$1: exit 1" "$rc" "1"
  has "$1: names the field" "$out" "ontology/terms/$2.json: $4"
}
broken "id not PascalCase" effort "$(printf '%s' "$good" | jq -c '.id="effort"')" "id: not PascalCase"
broken "id differs from file name" Task "$good" "id: does not equal the file name Task"
broken "label empty list" Effort "$(printf '%s' "$good" | jq -c '.label=[]')" "label:"
broken "definition short" Effort "$(printf '%s' "$good" | jq -c '.definition="short"')" "definition: under 20"
broken "is_not empty" Effort "$(printf '%s' "$good" | jq -c '.is_not=[]')" "is_not: needs at least one"
broken "avoid not a list" Effort "$(printf '%s' "$good" | jq -c '.avoid="epic"')" "avoid: a list"
broken "home unknown key" Effort "$(printf '%s' "$good" | jq -c '.home={"web":"x"}')" "home: an object with any of cli, skill, rule"
broken "status unknown" Effort "$(printf '%s' "$good" | jq -c '.status="sprout"')" "status: seed, sapling or tree"
broken "sapling with no home" Effort "$(printf '%s' "$good" | jq -c '.home={}')" "home: a sapling or a tree needs at least one"
broken "unknown field" Effort "$(printf '%s' "$good" | jq -c '.owner="core"')" "unknown field: owner"
broken "not JSON" Effort '{not json' "not a JSON object"

# 4. a seed may have an empty home
rm -f "$fx"/ontology/terms/*.json
term Advisor "$(printf '%s' "$good" | jq -c '.id="Advisor" | .label="advisor" | .home={} | .status="seed"')"
out="$(check)"; rc=$?
t "seed with empty home: exit 0" "$rc" "0"

# 5. a missing folder exits 2
out="$(bash "$ROOT/scripts/terms-check.sh" --root "$tmp" 2>&1)"; rc=$?
t "no ontology/terms/: exit 2" "$rc" "2"

# ── homes, routing, the AGENTS.md table ─────────────────────────────────────────────────────────
# A whole small project: a dispatcher with three verbs, two skills, one rule, two terms, a routing
# file and the AGENTS.md table that mirrors it. `fixture` rebuilds it clean before each mutation.
fixture() {
  rm -rf "$fx"; mkdir -p "$fx/ontology/terms" "$fx/bin" "$fx/skills/kit-a" "$fx/skills/kit-b" "$fx/.claude/rules"
  printf '#!/usr/bin/env bash\ncase "$cmd" in\n  effort)\n    case "$1" in\n      new) ;;\n    esac ;;\n  start) ;;\n  pr|close) ;;\nesac\n' > "$fx/bin/cckit"
  printf -- '---\nname: kit-a\nterms: Effort, Task\ndescription: a\n---\n# a\n' > "$fx/skills/kit-a/SKILL.md"
  printf -- '---\nname: kit-b\nterms: none\ndescription: b\n---\n# b\n' > "$fx/skills/kit-b/SKILL.md"
  printf '# r\n' > "$fx/.claude/rules/r.md"
  term Effort "$(printf '%s' "$good" | jq -c '.home={"cli":"effort plan","skill":"kit-a","rule":".claude/rules/r.md"}')"
  term Advisor "$(printf '%s' "$good" | jq -c '.id="Advisor" | .label="advisor" | .home={"skill":"kit-zz"} | .status="seed"')"
  term Task "$(printf '%s' "$good" | jq -c '.id="Task" | .label="task" | .home={"cli":"start"}')"
  cat > "$fx/skills/routing.yaml" <<'YAML'
# comment
- task: "scope a goal"
  skill: kit-a
  term: Effort

- task: "do a second thing"
  skill: kit-a
  term: Task
- task: "set up"
  skill: kit-b
  term: none
YAML
  cat > "$fx/AGENTS.md" <<'MD'
# agents

## Which skill does what

| What you want | Skill | Term |
| --- | --- | --- |
| scope a goal · do a second thing | `kit-a` | Effort, Task |
| set up | `kit-b` | none |

## Next
MD
}
counts() { printf '%s\n' "$1" | grep '^terms-check:' ; }

fixture
out="$(check)"; rc=$?
t "whole fixture: exit 0" "$rc" "0"
has "seed home is noted, not a defect" "$out" "seed Advisor: home skill kit-zz does not exist yet (allowed)"
t "counts line" "$(counts "$out")" "terms-check: 3 terms · 4/5 homes resolved · 2/2 skills routed · 0 unrouted · 1 with no term · 0 defects"
t "--llm counts" "$(checkj | jq -c 'del(.ok)' 2>/dev/null)" '{"terms":3,"homes":5,"homes_resolved":4,"skills":2,"skills_routed":2,"unrouted":0,"skills_no_term":1,"defects":0}'

# homes
fixture; term Effort "$(printf '%s' "$good" | jq -c '.home={"cli":"nope"}')"
out="$(check)"; t "unknown verb home: exit 1" "$?" "1"; has "unknown verb named" "$out" "Effort.json: home cli nope does not exist"
fixture; term Effort "$(printf '%s' "$good" | jq -c '.home={"skill":"kit-zz"}')"
out="$(check)"; t "missing skill home: exit 1" "$?" "1"; has "missing skill named" "$out" "home skill kit-zz does not exist"
fixture; term Effort "$(printf '%s' "$good" | jq -c '.home={"rule":".claude/rules/none.md"}')"
out="$(check)"; t "missing rule home: exit 1" "$?" "1"; has "missing rule named" "$out" "home rule .claude/rules/none.md does not exist"

# routing
fixture; mkdir -p "$fx/skills/kit-c"; printf -- '---\nname: kit-c\nterms: none\ndescription: c\n---\n' > "$fx/skills/kit-c/SKILL.md"
out="$(check)"; t "unrouted skill: exit 1" "$?" "1"; has "unrouted skill named" "$out" "skills/kit-c: not routed"
has "unrouted counted" "$(counts "$out")" "2/3 skills routed · 1 unrouted"
fixture; printf -- '- task: "x"\n  skill: kit-zz\n  term: none\n' >> "$fx/skills/routing.yaml"
out="$(check)"; t "entry with unknown skill: exit 1" "$?" "1"; has "unknown skill named" "$out" "skill kit-zz has no SKILL.md"
fixture; printf -- '- task: "x"\n  skill: kit-b\n  term: Nope\n' >> "$fx/skills/routing.yaml"
out="$(check)"; t "entry with unknown term: exit 1" "$?" "1"; has "unknown term named" "$out" "term Nope is not under ontology/terms/"
fixture; printf -- '- task: "x"\n  skill: kit-b\n  terms: [a, b]\n' >> "$fx/skills/routing.yaml"
out="$(check)"; t "line outside the subset: exit 1" "$?" "1"; has "line number and expectation" "$out" 'skills/routing.yaml:14: expected `  term: <Term>` or `  term: none`'
fixture; printf -- '- task: "x"\n  skill: kit-b\n' >> "$fx/skills/routing.yaml"
out="$(check)"; t "entry cut short: exit 1" "$?" "1"; has "cut short named" "$out" "entry ends before its term line"
fixture; printf -- '---\nname: kit-a\nterms: Task\ndescription: a\n---\n' > "$fx/skills/kit-a/SKILL.md"
out="$(check)"; t "terms: drift: exit 1" "$?" "1"; has "drift names both" "$out" "skills/kit-a/SKILL.md: terms: 'Task' but skills/routing.yaml says 'Effort, Task'"
fixture; rm "$fx/skills/routing.yaml"
out="$(check)"; t "no routing file: exit 1" "$?" "1"; has "no routing named" "$out" "skills/routing.yaml: missing"

# AGENTS.md
fixture; sed -i.bak '/kit-b/d' "$fx/AGENTS.md"
out="$(check)"; t "AGENTS.md row missing: exit 1" "$?" "1"; has "missing row named" "$out" "AGENTS.md: no row for kit-b"
fixture; sed -i.bak 's/| Effort, Task |/| Effort |/' "$fx/AGENTS.md"
out="$(check)"; t "AGENTS.md terms differ: exit 1" "$?" "1"; has "terms drift named" "$out" "AGENTS.md: kit-a terms differ"
fixture; sed -i.bak 's/scope a goal · do a second thing/scope a goal/' "$fx/AGENTS.md"
out="$(check)"; t "AGENTS.md tasks differ: exit 1" "$?" "1"; has "tasks drift named" "$out" "AGENTS.md: kit-a tasks differ"
fixture; printf '| extra | `kit-zz` | none |\n' > "$tmp/row"; sed -i.bak '/kit-b/r '"$tmp/row" "$fx/AGENTS.md"
out="$(check)"; t "AGENTS.md extra row: exit 1" "$?" "1"; has "extra row named" "$out" "AGENTS.md: row for kit-zz, which skills/routing.yaml does not route"
fixture; rm "$fx/AGENTS.md"
out="$(check)"; t "no AGENTS.md: not a defect" "$?" "0"

# the skills page
page() { mkdir -p "$fx/docs-site/src/content/docs"; cat > "$fx/docs-site/src/content/docs/skills.mdx"; }
good_page() { page <<'MDX'
---
title: Skills
---
## Effort

| Skill | Activates | What it does |
| ----- | --------- | ------------ |
| `kit-a` | <Tag kind="skill" /> | a |

## The kit itself

| Skill | Activates | What it does |
| ----- | --------- | ------------ |
| `kit-b` | <Tag kind="skill" /> | b |

## Skills a profile scaffolds

| Skill | Profiles | What it does |
| ----- | -------- | ------------ |
| `concrete` | all | not one of skills/ |
MDX
}
fixture; good_page
out="$(check)"; t "page grouped by term: exit 0" "$?" "0"
fixture; good_page; sed -i.bak '/kit-b/d' "$fx/docs-site/src/content/docs/skills.mdx"
out="$(check)"; t "page row missing: exit 1" "$?" "1"; has "missing page row named" "$out" "skills.mdx: no row for kit-b"
fixture; good_page; sed -i.bak 's/^## Effort$/## Task/' "$fx/docs-site/src/content/docs/skills.mdx"
out="$(check)"; t "page row under its other term: exit 0" "$?" "0"
fixture; good_page; sed -i.bak 's/^## Effort$/## Gate/' "$fx/docs-site/src/content/docs/skills.mdx"
out="$(check)"; t "page row under a wrong heading: exit 1" "$?" "1"; has "wrong heading named" "$out" 'skills.mdx: kit-a is under "Gate", not under a heading of its terms'
fixture; good_page; printf '| `kit-zz` | <Tag kind="skill" /> | zz |\n' > "$tmp/prow"; mkdir -p "$fx/skills/kit-zz"; : > "$fx/skills/kit-zz/SKILL.md"
sed -i.bak '/kit-b/r '"$tmp/prow" "$fx/docs-site/src/content/docs/skills.mdx"; printf -- '- task: "zz"\n  skill: kit-zz\n  term: none\n' >> "$fx/skills/routing.yaml"
printf '| zz | `kit-zz` | none |\n' > "$tmp/arow"; sed -i.bak '/kit-b/r '"$tmp/arow" "$fx/AGENTS.md"; printf -- '---\nname: kit-zz\nterms: none\n---\n' > "$fx/skills/kit-zz/SKILL.md"
out="$(check)"; t "page: a routed skill added everywhere: exit 0" "$?" "0"
fixture; good_page; printf '| `kit-zz` | <Tag kind="skill" /> | zz |\n' > "$tmp/prow"; mkdir -p "$fx/skills/kit-zz"; printf -- '---\nname: kit-zz\nterms: none\n---\n' > "$fx/skills/kit-zz/SKILL.md"
sed -i.bak '/kit-b/r '"$tmp/prow" "$fx/docs-site/src/content/docs/skills.mdx"
out="$(check)"; t "page row for an unrouted skill: exit 1" "$?" "1"; has "unrouted page row named" "$out" "skills.mdx: row for kit-zz, which skills/routing.yaml does not route"

[ "$fail" -eq 0 ] && echo "terms-check-test: all ok" || { echo "terms-check-test: FAILED"; exit 1; }
