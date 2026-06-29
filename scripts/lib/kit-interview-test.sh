#!/usr/bin/env bash
# kit-interview-test.sh — self-test for kit-interview (#372). Runs under bash AND zsh.
# Run:  bash scripts/lib/kit-interview-test.sh
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
