#!/usr/bin/env bash
# kit-profile-test.sh — self-test for kit-profile (#372). Runs under bash AND zsh.
# Run:  bash scripts/lib/kit-profile-test.sh
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KIT_PROFILE_TEST_INNER:-}" ]; then
  set -u
  . "$dir/kit-profile.sh"
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_PROFILE_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_PROFILE_TEST_INNER): $1"; fi; }
  tt() { if [ "$2" = "$3" ]; then echo "FAIL($KIT_PROFILE_TEST_INNER): $1 -> '[$2]' should differ from '[$3]'"; fail=1; else echo "ok($KIT_PROFILE_TEST_INNER): $1"; fi; }

  export KIT_PROFILE_HOME="$(mktemp -d)"; trap 'rm -rf "$KIT_PROFILE_HOME"' EXIT

  # slug normalization (O8)
  t "slug spaces+case"  "$(KIT_PROFILE_USER='Jose Gutierrez' kit_profile_user_slug)" "jose-gutierrez"
  t "slug explicit arg" "$(kit_profile_user_slug 'Ada Lovelace')"                    "ada-lovelace"
  t "slug all-symbols -> user" "$(kit_profile_user_slug '!!!')" "user"

  # path encodes the slug
  case "$(kit_profile_path tester)" in
    *"/kit.profile.tester.json") t "path encodes slug" yes yes;;
    *) t "path encodes slug" "$(kit_profile_path tester)" "*/kit.profile.tester.json";;
  esac

  # exists is false before, true after init; init idempotent
  kit_profile_exists tester; t "exists before" "$?" "1"
  kit_profile_init tester;   t "init rc" "$?" "0"
  kit_profile_exists tester; t "exists after" "$?" "0"
  h1="$(cat "$(kit_profile_path tester)")"; kit_profile_init tester; h2="$(cat "$(kit_profile_path tester)")"
  t "init idempotent" "$h1" "$h2"

  # set / get scalar + nested
  kit_profile_set name "Jose" string tester
  t "get name"        "$(kit_profile_get .name tester)"          "Jose"
  kit_profile_set defaults.mode guided string tester
  t "get nested mode" "$(kit_profile_get .defaults.mode tester)" "guided"
  kit_profile_set defaults.memory_on true bool tester
  t "get bool"        "$(kit_profile_get .defaults.memory_on tester)" "true"

  # read returns {} for an unknown user; get empty for unset path
  t "read unknown"    "$(kit_profile_read nobody)" "{}"
  t "get unset empty" "$(kit_profile_get .nope tester)" ""

  # the $PATH-tied 'path' var regression: a set must NOT break later jq calls (zsh)
  kit_profile_set a.b.c "deep" string tester
  t "deep set survives PATH" "$(kit_profile_get .a.b.c tester)" "deep"
  t "jq still found after set" "$(command -v jq >/dev/null 2>&1 && echo ok)" "ok"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_PROFILE_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_PROFILE_TEST_INNER="$sh" PATH="$PATH" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
