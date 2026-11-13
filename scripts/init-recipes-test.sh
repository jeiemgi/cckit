#!/usr/bin/env bash
# shellcheck shell=bash
# init-recipes-test.sh — consistency of the recipe and database registries (#456).
#
# recipes/*.json and databases/*.json are data that `cckit init` offers to a person who cannot
# check them. This test is what keeps the data honest:
#   - every shipped descriptor is valid, and each list has exactly ONE recommended entry;
#   - every database option has its guide page AND its setup test — one without the other fails;
#   - the env variable names agree in three places: the descriptor, the guide page, and the client
#     code the option adds (every declared name is read, and no undeclared name is read);
#   - the guide page carries the descriptor's "last verified" date and one step per descriptor step;
#   - an option missing its guide or its test is not offered at run time.
# Offline. Run:  bash scripts/init-recipes-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
fail=0
t()      { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
yes_if() { if eval "$2"; then echo "ok: $1"; else echo "FAIL: $1 -> not true: $2"; fail=1; fi; }

command -v jq >/dev/null 2>&1 || { echo "init-recipes-test: jq absent — skipping (dependency-light gate)"; exit 0; }
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/init-guide.sh"

# ── recipes ─────────────────────────────────────────────────────────────────────────────────────
t "there is a recipe to offer" "$([ -n "$(recipes_list)" ] && echo yes)" "yes"
rec=0
for id in $(recipes_list); do
  f="$(recipe_file "$id")"
  t "recipe $id: valid" "$(recipe_validate "$f" 2>&1; echo "rc=$?")" "rc=0"
  [ "$(jq -r .recommended "$f")" = "true" ] && rec=$((rec + 1))
  t "recipe $id: its profile exists" "$([ -f "$ROOT/profiles/$(jq -r .profile "$f").json" ] && echo yes)" "yes"
  t "recipe $id: lists its sources" "$(jq -r '(.sources // []) | length > 0' "$f")" "true"
done
t "recipes: exactly one is recommended" "$rec" "1"

# ── databases ───────────────────────────────────────────────────────────────────────────────────
t "there is a database option to offer" "$([ -n "$(databases_list)" ] && echo yes)" "yes"
rec=0
for id in $(databases_list); do
  f="$(database_file "$id")"
  t "database $id: valid" "$(database_validate "$f" 2>&1; echo "rc=$?")" "rc=0"
  [ "$(jq -r .recommended "$f")" = "true" ] && rec=$((rec + 1))
  guide="$(database_path "$f" "$(jq -r .guide "$f")")"; test_file="$(database_path "$f" "$(jq -r .test "$f")")"
  t "database $id: has its guide page" "$([ -f "$guide" ] && echo yes)" "yes"
  t "database $id: has its setup test" "$([ -f "$test_file" ] && echo yes)" "yes"
  t "database $id: the setup test is one the runner discovers" "$(case "$test_file" in */scripts/*-test.sh) echo yes ;; esac)" "yes"
  t "database $id: offered" "$(database_offered "$f"; echo "rc=$?")" "rc=0"
  [ -f "$guide" ] || continue
  # The guide: self-contained, dated, one step per descriptor step, the env file named.
  t "database $id: the guide loads nothing from elsewhere" "$(grep -cE '<(script|link|img|iframe)[^>]*(src|href)=' "$guide")" "0"
  yes_if "database $id: the guide carries the last-verified date" 'grep -q "Last verified: <strong id=\"last-verified\">$(jq -r .lastVerified "$f")</strong>" "$guide"'
  t "database $id: one guide step per descriptor step" "$(grep -c '<li class="step">' "$guide")" "$(jq '.steps | length' "$f")"
  yes_if "database $id: the guide names the env file" 'grep -qF "$(jq -r .envFile "$f")" "$guide"'
  for n in $(jq -r '.env[].name' "$f"); do
    yes_if "database $id: the guide names $n" 'grep -qF "$n" "$guide"'
    yes_if "database $id: the terminal steps name $n" 'grep -qF "$n" <<<"$(database_steps "$f" /p)"'
    yes_if "database $id: the placeholder of $n is not a real key" '! grep -qE "sb_(publishable|secret)_|eyJ" <<<"$(jq -r --arg n "$n" ".env[] | select(.name == \$n) | .placeholder" "$f")"'
  done
  # Guide and descriptor name the same variables: no name in the guide's file sample is undeclared.
  t "database $id: the guide's file sample declares the same names" \
    "$(grep -oE '(^|<pre>)[A-Z][A-Z0-9_]+=' "$guide" | sed 's/<pre>//' | tr -d '=' | sort -u | tr '\n' ' ')" "$(jq -r '.env[].name' "$f" | sort -u | tr '\n' ' ')"
  for s in $(jq -r '.stacks | keys[]' "$f"); do
    read_names=""
    for from in $(jq -r --arg s "$s" '.stacks[$s].files[].from' "$f"); do
      src="$(database_path "$f" "$from")"
      t "database $id/$s: ships $from" "$([ -f "$src" ] && echo yes)" "yes"
      [ -f "$src" ] && read_names="$read_names $(grep -oE 'process\.env\.[A-Z][A-Z0-9_]*' "$src" | sed 's/process\.env\.//' | tr '\n' ' ')"
    done
    t "database $id/$s: the client code reads exactly the declared names" \
      "$(printf '%s\n' $read_names | sort -u | tr '\n' ' ')" "$(jq -r '.env[].name' "$f" | sort -u | tr '\n' ' ')"
    for pk in $(jq -r --arg s "$s" '.stacks[$s].packages[]' "$f"); do
      yes_if "database $id/$s: the install command installs $pk" 'grep -qF -- "$pk" <<<"$(jq -r --arg s "$s" ".stacks[\$s].install" "$f")"'
    done
  done
done
t "databases: exactly one is recommended" "$rec" "1"

# ── an option without its guide or its test is not offered ──────────────────────────────────────
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fx="$tmp/databases"; mkdir -p "$fx/demo"
jq '.id = "demo" | .guide = "demo/guide.html" | .test = "demo-test.sh"' "$ROOT/databases/supabase.json" > "$fx/demo.json"
t "fixture: neither guide nor test -> not offered" "$(database_offered "$fx/demo.json"; echo "rc=$?")" "rc=1"
: > "$fx/demo/guide.html"
t "fixture: guide without test -> not offered" "$(database_offered "$fx/demo.json"; echo "rc=$?")" "rc=1"
rm "$fx/demo/guide.html"; : > "$fx/demo-test.sh"
t "fixture: test without guide -> not offered" "$(database_offered "$fx/demo.json"; echo "rc=$?")" "rc=1"
: > "$fx/demo/guide.html"
t "fixture: both -> offered" "$(database_offered "$fx/demo.json"; echo "rc=$?")" "rc=0"
t "fixture: the registry directory is replaceable" "$(KIT_DATABASES_DIR="$fx" databases_list)" "demo"
jq 'del(.env)' "$fx/demo.json" > "$fx/bad.json"
t "fixture: a descriptor without env is invalid" "$(database_validate "$fx/bad.json" >/dev/null 2>&1; echo "rc=$?")" "rc=1"

[ "$fail" -eq 0 ] && echo "init-recipes-test: PASS" || echo "init-recipes-test: FAIL"
exit "$fail"
