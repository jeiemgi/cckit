#!/usr/bin/env bash
# kit-add-test.sh — self-test for kit-add module stacking (#372). Runs under bash AND zsh.
# Run:  bash scripts/kit-add-test.sh
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KIT_ADD_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_ADD_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_ADD_TEST_INNER): $1"; fi; }
  ADD="$dir/kit-add.sh"

  export KIT_PROFILE_HOME="$(mktemp -d)"
  export KIT_ASSUME_YES=1 KIT_VERSION=9.9.9
  ws="$(mktemp -d)"; trap 'rm -rf "$KIT_PROFILE_HOME" "$ws"' EXIT
  mkdir -p "$ws/myapp"
  printf '%s\n' '{"workspace":{"name":"ws"},"mode":"guided"}' > "$ws/kit.workspace.json"
  parent_before="$(cat "$ws/kit.workspace.json")"

  # unknown module fails
  "$ADD" doesnotexist --dir "$ws/myapp" >/dev/null 2>&1; t "unknown module rc" "$?" "1"

  # add software (defaults) — island config created
  "$ADD" software --dir "$ws/myapp" >/dev/null 2>&1; t "add rc" "$?" "0"
  cfg="$ws/myapp/.claude/kit.config.json"
  t "island created"   "$([ -f "$cfg" ] && echo yes)"                  "yes"
  t "modules"          "$(jq -c .modules "$cfg")"                      '["software"]'
  t "github wizard"    "$(jq -r .github.projectsV2 "$cfg")"            "true"
  t "ci wizard"        "$(jq -r .ci.provider "$cfg")"                  "github-actions"
  t "manifest tracks"  "$(jq -r '.entries["'.claude/kit.config.json'"] | has("hash")' "$ws/myapp/.claude/kit.manifest.json")" "true"

  # parent workspace untouched
  t "parent untouched" "$(cat "$ws/kit.workspace.json")" "$parent_before"

  # idempotent: a 2nd identical run leaves the file byte-identical
  before="$(cat "$cfg")"
  "$ADD" software --dir "$ws/myapp" >/dev/null 2>&1
  t "idempotent file"  "$(cat "$cfg")" "$before"

  # --set override changes only that field; modules stay deduped
  "$ADD" software --dir "$ws/myapp" --set deploy=vercel >/dev/null 2>&1
  t "override deploy"  "$(jq -r .deploy.target "$cfg")" "vercel"
  t "modules still one" "$(jq -c .modules "$cfg")" '["software"]'

  # dry-run writes nothing new
  fresh="$(mktemp -d)"; mkdir -p "$fresh/app"
  KIT_DRY_RUN=1 "$ADD" software --dir "$fresh/app" >/dev/null 2>&1
  t "dry-run no write" "$([ -f "$fresh/app/.claude/kit.config.json" ] && echo wrote || echo clean)" "clean"
  rm -rf "$fresh"

  # ── integrations (E303.2): the same entry lists descriptors and switches one on ────────────
  has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok($KIT_ADD_TEST_INNER): $1"; else echo "FAIL($KIT_ADD_TEST_INNER): $1 -> '$3' not in: $2"; fail=1; fi; }
  CCKIT="$dir/../bin/cckit"
  reg="$ws/integrations"; mkdir -p "$reg"
  cp "$dir/../integrations/integration.schema.json" "$reg/"
  # desc <id> <config json> <appliesWhen json|null> -> a valid fixture descriptor
  desc() {
    jq -n --arg id "$1" --argjson c "$2" --argjson a "$3" '
      { id: $id, label: ("Fixture " + $id), summary: ("Summary of " + $id + "."), config: $c,
        detect: {run: "true"}, install: [{manager: "npm", run: "npm install -g x"}],
        verify: {run: "true"}, docs: "https://example.invalid/docs",
        attribution: {author: "Example Org", homepage: "https://example.invalid", affiliated: false,
                      notice: "cckit is not affiliated with Example Org."} }
      + (if $a == null then {} else {appliesWhen: $a} end)' > "$reg/$1.json"
  }
  desc alpha '{"key":"codeGraph.provider","value":"alpha-graph"}' '{"anyExtension":[".ts"]}'
  desc beta  '{"key":"memory.enabled"}' null
  export KIT_INTEGRATIONS_DIR="$reg"

  # no argument: every descriptor is listed, rc 0 — through the dispatcher, not only the script
  out="$(cd "$ws" && "$CCKIT" add 2>/dev/null)"; t "cckit add (no arg) rc" "$?" "0"
  has "list names alpha"      "$out" "alpha"
  has "list names beta"       "$out" "beta"
  has "list carries summary"  "$out" "Summary of beta."
  has "list names the module" "$out" "software"
  t "list --llm ids" "$(cd "$ws" && "$CCKIT" add --llm 2>/dev/null | jq -c '[.integrations[].id]')" '["alpha","beta"]'
  t "list --llm modules" "$(cd "$ws" && "$CCKIT" add --llm 2>/dev/null | jq -c '[.modules[].id] | index("software") != null')" 'true'
  # an empty registry is an answer, not an error
  emp="$ws/empty-reg"; mkdir -p "$emp"
  out="$(KIT_INTEGRATIONS_DIR="$emp" "$ADD" 2>/dev/null)"; t "empty registry rc" "$?" "0"
  has "empty registry says so" "$out" "none described yet"

  # the module path still works through the dispatcher
  mkdir -p "$ws/viacli"
  ( cd "$ws/viacli" && "$CCKIT" add software --set versioning=github >/dev/null 2>&1 ); t "cckit add software rc" "$?" "0"
  t "cckit add software wrote the island" "$(jq -r .github.projectsV2 "$ws/viacli/.claude/kit.config.json" 2>/dev/null)" "true"

  # a real add changes ONLY that integration's key
  proj="$ws/proj"; mkdir -p "$proj/.claude" "$proj/src"; : > "$proj/src/a.ts"
  printf '%s\n' '{"project":{"name":"p"},"github":{"repo":"o/r","projectsV2":false},"memory":{"enabled":false}}' > "$proj/.claude/kit.config.json"
  pcfg="$proj/.claude/kit.config.json"; before="$(jq -S . "$pcfg")"
  # dry-run first: nothing is written
  raw_before="$(cat "$pcfg")"
  KIT_DRY_RUN=1 "$ADD" alpha --dir "$proj" >/dev/null 2>&1; t "integration dry-run rc" "$?" "0"
  t "integration dry-run writes nothing" "$(cat "$pcfg")" "$raw_before"
  t "dry-run leaves no temp file" "$(ls -A "$proj/.claude" | tr '\n' ' ')" "kit.config.json "
  # declining writes nothing
  "$ADD" alpha --dir "$proj" --set enable=no >/dev/null 2>&1; t "decline rc" "$?" "0"
  t "decline writes nothing" "$(cat "$pcfg")" "$raw_before"
  "$ADD" alpha --dir "$proj" >/dev/null 2>&1; t "integration add rc" "$?" "0"
  t "key is set"              "$(jq -r .codeGraph.provider "$pcfg")" "alpha-graph"
  t "every other key kept"    "$(jq -S 'del(.codeGraph)' "$pcfg")"   "$before"
  t "only one key added"      "$(jq -c '.codeGraph' "$pcfg")"        '{"provider":"alpha-graph"}'
  t "no temp file left"       "$(ls -A "$proj/.claude" | tr '\n' ' ')" "kit.config.json "
  # idempotent: a second run leaves the file byte-identical
  again="$(cat "$pcfg")"
  "$ADD" alpha --dir "$proj" >/dev/null 2>&1; t "second add rc" "$?" "0"
  t "second add is a no-op" "$(cat "$pcfg")" "$again"
  # a descriptor with no config.value sets boolean true, and touches only its own key
  mid="$(jq -S . "$pcfg")"
  "$ADD" beta --dir "$proj" >/dev/null 2>&1
  t "boolean key set to true" "$(jq -c .memory.enabled "$pcfg")" "true"
  t "beta changed only memory.enabled" "$(jq -S '.memory.enabled = false' "$pcfg")" "$mid"
  # the self-host layout: a root cckit.config.json is the config kit_config_path resolves
  selfp="$ws/selfhost"; mkdir -p "$selfp"; printf '%s\n' '{"kitVersion":"1.0.0"}' > "$selfp/cckit.config.json"
  "$ADD" beta --dir "$selfp" >/dev/null 2>&1
  t "self-host config gets the key" "$(jq -c . "$selfp/cckit.config.json")" '{"kitVersion":"1.0.0","memory":{"enabled":true}}'
  t "self-host: no .claude config invented" "$([ -e "$selfp/.claude/kit.config.json" ] && echo made || echo none)" "none"

  # a repo the tool cannot work on: declined, rc 0, nothing written
  shp="$ws/shonly"; mkdir -p "$shp/.claude"; : > "$shp/run.sh"
  printf '%s\n' '{"project":{"name":"s"}}' > "$shp/.claude/kit.config.json"
  out="$("$ADD" alpha --dir "$shp" 2>&1)"; t "not-applicable rc" "$?" "0"
  has "not-applicable says why" "$out" ".ts"
  t "not-applicable writes nothing" "$(jq -c . "$shp/.claude/kit.config.json")" '{"project":{"name":"s"}}'

  # no project config: refused, and none is invented
  bare="$ws/bare"; mkdir -p "$bare"
  out="$(KIT_CONFIG="" "$ADD" beta --dir "$bare" 2>&1)"; t "no config rc" "$?" "1"
  has "no config names the fix" "$out" "cckit init"
  t "no config invented" "$([ -e "$bare/.claude" ] && echo made || echo none)" "none"

  # an invalid descriptor is refused before any write
  jq 'del(.verify)' "$reg/beta.json" > "$reg/gamma.json"
  out="$("$ADD" gamma --dir "$proj" 2>&1)"; t "invalid descriptor rc" "$?" "1"
  has "invalid descriptor names the field" "$out" "verify"
  rm -f "$reg/gamma.json"

  # a module wins a name it shares with an integration
  desc software '{"key":"codeGraph.provider","value":"clash"}' null
  mkdir -p "$ws/clash"
  "$ADD" software --dir "$ws/clash" >/dev/null 2>&1
  t "module wins a shared name" "$(jq -c .modules "$ws/clash/.claude/kit.config.json" 2>/dev/null)" '["software"]'
  rm -f "$reg/software.json"
  unset KIT_INTEGRATIONS_DIR

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_ADD_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_ADD_TEST_INNER="$sh" PATH="$PATH" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
