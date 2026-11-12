#!/usr/bin/env bash
# kit-interview-test.sh — self-test for kit-interview (#372). Runs under bash AND zsh.
# Run:  bash scripts/lib/kit-interview-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KIT_IV_TEST_INNER:-}" ]; then
  set -u
  . "$dir/kit-interview.sh"
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_IV_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_IV_TEST_INNER): $1"; fi; }

  export KIT_PROFILE_HOME="$(mktemp -d)"
  work="$(mktemp -d)"; trap 'rm -rf "$KIT_PROFILE_HOME" "$work"' EXIT

  # --- catalogs load + tier matches + module routing ---
  t "catalog global tier"   "$(kit_interview_catalog global   | jq -r .tier)" "global"
  t "catalog project tier"  "$(kit_interview_catalog project  | jq -r .tier)" "project"
  t "catalog software tier" "$(kit_interview_catalog software | jq -r .tier)" "software"
  case "$(kit_interview_catalog_file software)" in
    */modules/software.json) t "software routes to modules/" yes yes;;
    *) t "software routes to modules/" "$(kit_interview_catalog_file software)" "*/modules/software.json";;
  esac
  kit_interview_catalog nope >/dev/null 2>&1; t "unknown tier rc" "$?" "1"

  # --- context: repo detection ---
  mkdir -p "$work/proj"; printf '{}' > "$work/proj/package.json"
  ctx="$(kit_interview_context "$work/proj")"
  t "ctx repo.dir"      "$(printf '%s' "$ctx" | jq -r .repo.dir)"      "proj"
  t "ctx repo.language" "$(printf '%s' "$ctx" | jq -r .repo.language)" "javascript"
  t "ctx repo.hasGit"   "$(printf '%s' "$ctx" | jq -r .repo.hasGit)"   "false"

  # --- render: per-project pre-fill from profile + repo ---
  . "$dir/kit-profile.sh"
  kit_profile_set name "Ada" string tester
  kit_profile_set language "es" string tester
  rp="$(KIT_PROFILE_USER=tester kit_interview_render project "$work/proj")"
  t "render name<-repo.dir"   "$(printf '%s' "$rp" | jq -r '.questions[]|select(.key=="name").default')"    "proj"
  t "render owner<-profile"   "$(printf '%s' "$rp" | jq -r '.questions[]|select(.key=="owner").default')"   "Ada"
  t "render lang<-profile"    "$(printf '%s' "$rp" | jq -r '.questions[]|select(.key=="language").default')" "es"

  # --- apply project: text + select targets ---
  printf '%s\n' '{"name":"My App","owner":"Ada","language":"es","mode":"enforced","software":"no"}' > "$work/ans-proj.json"
  ap="$(kit_interview_apply project "$work/ans-proj.json")"
  t "apply project.name" "$(printf '%s' "$ap" | jq -r .project.name)" "My App"
  t "apply mode"         "$(printf '%s' "$ap" | jq -r .mode)"         "enforced"
  t "control no key"     "$(printf '%s' "$ap" | jq -r 'has("software")')" "false"

  # --- apply software wizard: sets + idempotent modules union ---
  printf '%s\n' '{"versioning":"github","deploy":"vercel","ci":"github-actions"}' > "$work/ans-sw.json"
  printf '%s\n' "$ap" > "$work/base.json"
  sw1="$(kit_interview_apply software "$work/ans-sw.json" "$work/base.json")"
  t "sw modules"        "$(printf '%s' "$sw1" | jq -c .modules)"            '["software"]'
  t "sw github"         "$(printf '%s' "$sw1" | jq -r .github.projectsV2)"  "true"
  t "sw deploy"         "$(printf '%s' "$sw1" | jq -r .deploy.target)"      "vercel"
  t "sw ci"             "$(printf '%s' "$sw1" | jq -r .ci.provider)"        "github-actions"
  printf '%s\n' "$sw1" > "$work/base2.json"
  sw2="$(kit_interview_apply software "$work/ans-sw.json" "$work/base2.json")"
  t "sw modules idempotent" "$(printf '%s' "$sw2" | jq -c .modules)" '["software"]'

  # --- apply with missing answer falls back to default ---
  printf '%s\n' '{}' > "$work/ans-empty.json"
  swd="$(kit_interview_apply software "$work/ans-empty.json")"
  t "apply default deploy" "$(printf '%s' "$swd" | jq -r .deploy.target)" "none"

  # --- qa module (#294): how this project boots — lists, pairs, names-only credentials ---
  t "catalog qa tier" "$(kit_interview_catalog qa | jq -r .tier)" "qa"
  case "$(kit_interview_catalog_file qa)" in
    */modules/qa.json) t "qa routes to modules/" yes yes;;
    *) t "qa routes to modules/" "$(kit_interview_catalog_file qa)" "*/modules/qa.json";;
  esac
  printf '%s\n' '{"command":"pnpm dev:stack","ports":"WEB_PORT=3000, API_PORT=4000","readiness":"WEB_PORT=/, API_PORT=/health","route":"/dashboard","credentialEnv":"QA_EMAIL, QA_PASSWORD"}' > "$work/ans-qa.json"
  # The VALUES live in the environment only. Nothing the interview derives may read them.
  qa1="$(QA_EMAIL='reviewer@example.test' QA_PASSWORD='s3cret-value' kit_interview_apply qa "$work/ans-qa.json" "$work/base.json")"
  t "qa command is a string"   "$(printf '%s' "$qa1" | jq -r '.qa.command | type')"        "string"
  t "qa command"               "$(printf '%s' "$qa1" | jq -r .qa.command)"                 "pnpm dev:stack"
  t "qa route is a string"     "$(printf '%s' "$qa1" | jq -r '.qa.route | type')"          "string"
  t "qa route"                 "$(printf '%s' "$qa1" | jq -r .qa.route)"                   "/dashboard"
  t "qa ports is an array"     "$(printf '%s' "$qa1" | jq -r '.qa.ports | type')"          "array"
  t "qa port env names"        "$(printf '%s' "$qa1" | jq -c '[.qa.ports[].env]')"         '["WEB_PORT","API_PORT"]'
  t "qa port bases are numbers" "$(printf '%s' "$qa1" | jq -c '[.qa.ports[].base]')"       '[3000,4000]'
  t "qa readiness: web AND api" "$(printf '%s' "$qa1" | jq -c .qa.readiness)"              '[{"env":"WEB_PORT","path":"/"},{"env":"API_PORT","path":"/health"}]'
  t "qa credentialEnv is an array" "$(printf '%s' "$qa1" | jq -r '.qa.credentialEnv | type')" "array"
  t "qa credential NAMES"      "$(printf '%s' "$qa1" | jq -c .qa.credentialEnv)"           '["QA_EMAIL","QA_PASSWORD"]'
  t "qa in modules, base kept" "$(printf '%s' "$qa1" | jq -c '[.modules, .project.name]')" '[["qa"],"My App"]'
  case "$qa1" in
    *reviewer@example.test*|*s3cret-value*) t "no credential VALUE in merged JSON" leaked clean;;
    *) t "no credential VALUE in merged JSON" clean clean;;
  esac

  # a port var with no base DERIVES one (3000 + its position); a probe with no path probes /
  printf '%s\n' '{"command":"make stack","ports":"WEB_PORT, API_PORT","readiness":"WEB_PORT"}' > "$work/ans-qa-derive.json"
  qad="$(kit_interview_apply qa "$work/ans-qa-derive.json")"
  t "qa derived bases"         "$(printf '%s' "$qad" | jq -c .qa.ports)"     '[{"env":"WEB_PORT","base":3000},{"env":"API_PORT","base":3001}]'
  t "qa derived probe path"    "$(printf '%s' "$qad" | jq -c .qa.readiness)" '[{"env":"WEB_PORT","path":"/"}]'
  t "qa route default"         "$(printf '%s' "$qad" | jq -r .qa.route)"     "/"
  t "qa unanswered list: no key" "$(printf '%s' "$qad" | jq -r '.qa | has("credentialEnv")')" "false"

  # answers given as JSON arrays (what a skill may build) land in the same shape
  printf '%s\n' '{"command":"make stack","ports":[{"env":"WEB_PORT","base":5000}],"credentialEnv":["QA_EMAIL","QA_EMAIL"]}' > "$work/ans-qa-arr.json"
  qaa="$(kit_interview_apply qa "$work/ans-qa-arr.json")"
  t "qa array answer: ports"   "$(printf '%s' "$qaa" | jq -c .qa.ports)"         '[{"env":"WEB_PORT","base":5000}]'
  t "qa array answer: deduped" "$(printf '%s' "$qaa" | jq -c .qa.credentialEnv)" '["QA_EMAIL"]'

  # re-applying onto its own output changes nothing; a shorter answer REPLACES the list
  printf '%s\n' "$qa1" > "$work/base-qa.json"
  qa2="$(kit_interview_apply qa "$work/ans-qa.json" "$work/base-qa.json")"
  t "qa apply idempotent" "$qa2" "$qa1"
  printf '%s\n' '{"command":"pnpm dev:stack","ports":"WEB_PORT=3000","credentialEnv":"QA_EMAIL"}' > "$work/ans-qa-less.json"
  qa3="$(kit_interview_apply qa "$work/ans-qa-less.json" "$work/base-qa.json")"
  t "qa list replaced, not unioned" "$(printf '%s' "$qa3" | jq -c '[(.qa.ports | length), .qa.credentialEnv]')" '[1,["QA_EMAIL"]]'

  # a credential VALUE is refused: rc 1, nothing on stdout, and stderr never echoes the value
  printf '%s\n' '{"command":"make stack","credentialEnv":"QA_EMAIL, QA_PASSWORD=hunter2-value"}' > "$work/ans-qa-leak.json"
  qal="$(kit_interview_apply qa "$work/ans-qa-leak.json" 2>"$work/leak.err")"; t "qa credential value rc" "$?" "1"
  t "qa credential value: no output" "$qal" ""
  t "qa refusal hides the value" "$(grep -c 'hunter2-value' "$work/leak.err")" "0"
  t "qa refusal names the question" "$(grep -c 'credentialEnv' "$work/leak.err" | sed 's/^[1-9][0-9]*$/named/')" "named"
  # malformed pairs and a missing required command are refused too
  printf '%s\n' '{"command":"make stack","ports":"WEB_PORT=abc"}' > "$work/ans-qa-bad.json"
  kit_interview_apply qa "$work/ans-qa-bad.json" >/dev/null 2>&1; t "qa non-numeric base rc" "$?" "1"
  printf '%s\n' '{"command":"make stack","ports":"WEB_PORT=1, WEB_PORT=2"}' > "$work/ans-qa-dup.json"
  kit_interview_apply qa "$work/ans-qa-dup.json" >/dev/null 2>&1; t "qa repeated port var rc" "$?" "1"
  printf '%s\n' '{"command":"make stack","readiness":"/health"}' > "$work/ans-qa-path.json"
  kit_interview_apply qa "$work/ans-qa-path.json" >/dev/null 2>&1; t "qa probe with no port var rc" "$?" "1"
  kit_interview_apply qa "$work/ans-empty.json" >/dev/null 2>&1; t "qa missing command rc" "$?" "1"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_IV_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_IV_TEST_INNER="$sh" PATH="$PATH" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
