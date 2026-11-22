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
fx="$tmp/project"; mkdir -p "$fx/ontology/terms"
check() { bash "$ROOT/scripts/terms-check.sh" --root "$fx" "$@" 2>&1; }
term() { # term <Stem> <json>
  printf '%s\n' "$2" > "$fx/ontology/terms/$1.json"
}
good='{"id":"Effort","label":["effort"],"definition":"One parent issue, one branch, one worktree, one PR.","is_not":["A task: a task is one issue with one PR."],"avoid":["epic"],"home":{"cli":"effort"},"status":"sapling"}'

# 1. one well-formed term passes and is counted
term Effort "$good"
out="$(check)"; rc=$?
t "well-formed term: exit 0" "$rc" "0"
has "counts line names 1 term" "$out" "1 terms"
out="$(check --llm)"
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

[ "$fail" -eq 0 ] && echo "terms-check-test: all ok" || { echo "terms-check-test: FAILED"; exit 1; }
