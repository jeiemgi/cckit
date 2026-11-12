#!/usr/bin/env bash
# shellcheck shell=bash
# integrations-test.sh — covers the integration descriptor format (E303.1): the schema in
# integrations/integration.schema.json, the validator and the applicability check in
# scripts/lib/integrations.sh, and the two files that have to know the registry exists
# (kit.config.schema.json, package.json). Hermetic: fixture descriptors and repos live in a
# throwaway dir. Run:  bash scripts/lib/integrations-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '$2' want '$3'"; fail=1; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else echo "FAIL: $1 -> '$3' not in: $2"; fail=1; fi; }

command -v jq >/dev/null 2>&1 || { echo "integrations-test: jq absent — skipping (dependency-light gate)"; exit 0; }

# shellcheck source=/dev/null
. "$LIB/integrations.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fx="$tmp/integrations"; mkdir -p "$fx"
cp "$ROOT/integrations/integration.schema.json" "$fx/"

# The fixture carries every field the issue names: label, the config key that turns it on, a
# detect command, ORDERED install candidates, a verify command, a docs link, an attribution block
# with affiliated:false, and the applicability predicate.
cat > "$fx/fixture-tool.json" <<'JSON'
{
  "id": "fixture-tool",
  "label": "Fixture Tool",
  "summary": "A tool that exists only in this test.",
  "config": { "key": "codeGraph.provider", "value": "fixture-tool-provider" },
  "appliesWhen": { "anyExtension": [".ts", ".tsx", ".R"], "note": "No shell grammar." },
  "detect": { "run": "fixture-tool --version" },
  "install": [
    { "manager": "npm",  "run": "npm install -g fixture-tool" },
    { "manager": "pnpm", "run": "pnpm add -g fixture-tool" },
    { "manager": "curl", "run": "curl -fsSL https://example.invalid/install.sh | sh", "note": "last resort" }
  ],
  "wire": {
    "run": "fixture-tool init",
    "declined": { "--no-statusline": "cckit owns the statusline." }
  },
  "verify": { "run": "fixture-tool check" },
  "uninstall": "fixture-tool uninstall -y",
  "docs": "https://example.invalid/fixture-tool#readme",
  "attribution": {
    "author": "Example Org",
    "license": "MIT",
    "homepage": "https://example.invalid/fixture-tool",
    "affiliated": false,
    "notice": "cckit is not affiliated with Example Org."
  }
}
JSON
good="$fx/fixture-tool.json"

# ── 1. the valid descriptor validates ──────────────────────────────────────────────────────────
out="$(integration_validate "$good" 2>&1)"; r=$?
rc "valid descriptor -> rc 0" "$r" "0"
t  "valid descriptor -> no diagnostics" "$out" ""
t  "install candidates keep descriptor order" "$(jq -r '[.install[].manager] | join(",")' "$good")" "npm,pnpm,curl"
t  "attribution carries affiliated:false" "$(jq -r '.attribution.affiliated' "$good")" "false"

# ── 2. a descriptor missing each required field is rejected BY NAME ────────────────────────────
# mutate <jq-filter> -> writes the mutated fixture under the SAME file name (the id must keep
# matching the file stem, or that unrelated error would mask the one under test).
mdir="$tmp/mut"; mkdir -p "$mdir"; cp "$fx/integration.schema.json" "$mdir/"
mutate() { jq "$1" "$good" > "$mdir/fixture-tool.json"; }
missing() {  # <name reported> <jq del() path>
  local name="$1" out r
  mutate "del($2)"
  out="$(KIT_INTEGRATIONS_DIR="$mdir" integration_validate "$mdir/fixture-tool.json" 2>&1)"; r=$?
  rc  "missing $name -> rc 1" "$r" "1"
  has "missing $name -> named" "$out" "$name: required field is missing"
}
missing "id"                     ".id"
missing "label"                  ".label"
missing "summary"                ".summary"
missing "config"                 ".config"
missing "config.key"             ".config.key"
missing "detect"                 ".detect"
missing "detect.run"             ".detect.run"
missing "install"                ".install"
missing "install[1].manager"     ".install[1].manager"
missing "install[0].run"         ".install[0].run"
missing "verify"                 ".verify"
missing "verify.run"             ".verify.run"
missing "docs"                   ".docs"
missing "attribution"            ".attribution"
missing "attribution.author"     ".attribution.author"
missing "attribution.homepage"   ".attribution.homepage"
missing "attribution.affiliated" ".attribution.affiliated"
missing "attribution.notice"     ".attribution.notice"
missing "wire.run"               ".wire.run"

# ── 3. wrong shapes are rejected too, each with the field named ────────────────────────────────
rejects() {  # <label> <jq mutation> <expected diagnostic substring>
  local out r
  mutate "$2"
  out="$(KIT_INTEGRATIONS_DIR="$mdir" integration_validate "$mdir/fixture-tool.json" 2>&1)"; r=$?
  rc  "$1 -> rc 1" "$r" "1"
  has "$1 -> diagnostic" "$out" "$3"
}
rejects "empty install list"           '.install = []'                      "install: needs at least 1 item"
rejects "unknown install manager"      '.install[0].manager = "apt"'        "install[0].manager: must be one of"
rejects "affiliated as a string"       '.attribution.affiliated = "no"'     "attribution.affiliated: expected boolean, got string"
rejects "empty label"                  '.label = ""'                        "label: must not be empty"
rejects "extension without a dot"      '.appliesWhen.anyExtension = ["ts"]' "appliesWhen.anyExtension[0]: does not match"
rejects "empty extension list"         '.appliesWhen.anyExtension = []'     "appliesWhen.anyExtension: needs at least 1 item"
rejects "unknown top-level field"      '.lable = "typo"'                    "lable: unknown field"
rejects "config key that is no path"   '.config.key = "codeGraph"'          "config.key: does not match"
rejects "config key named after the vendor" '.config.key = "fixtureTool.enabled"' "config.key: names the tool"
rejects "id that is not the file name" '.id = "other-tool"'                 "id: 'other-tool' must match the file name 'fixture-tool'"
rejects "docs that is not a URL"       '.docs = "see the readme"'           "docs: does not match"

printf '{ not json' > "$mdir/fixture-tool.json"
out="$(integration_validate "$mdir/fixture-tool.json" 2>&1)"; r=$?
rc  "invalid JSON -> rc 1" "$r" "1"
has "invalid JSON -> said so" "$out" "not valid JSON"
out="$(integration_validate "$tmp/nope.json" 2>&1)"; r=$?
rc  "absent file -> rc 1" "$r" "1"

# ── 4. the registry: list, look up, validate all ───────────────────────────────────────────────
export KIT_INTEGRATIONS_DIR="$fx"
t  "list names descriptors, never the schema" "$(integrations_list | tr '\n' ' ')" "fixture-tool "
t  "lookup by id returns the file" "$(integration_file fixture-tool)" "$good"
integration_file nope >/dev/null 2>&1;          rc "unknown id -> rc 1" "$?" "1"
integration_file ../etc/passwd >/dev/null 2>&1; rc "id that climbs out of the dir -> rc 1" "$?" "1"
integrations_validate_all >/dev/null 2>&1;      rc "validate-all over a clean dir -> rc 0" "$?" "0"
jq 'del(.verify)' "$good" > "$fx/broken.json"
out="$(integrations_validate_all 2>&1)"; r=$?
rc  "validate-all with one bad descriptor -> rc 1" "$r" "1"
has "validate-all names the descriptor and the field" "$out" "broken: verify: required field is missing"
rm -f "$fx/broken.json"

# ── 5. applicability: offered only where the tool can work ─────────────────────────────────────
repo="$tmp/repo"; mkdir -p "$repo/scripts/lib"
printf 'echo hi\n' > "$repo/scripts/lib/a.sh"; printf 'echo hi\n' > "$repo/run.sh"
integration_applies "$good" "$repo"; rc "repo holding only .sh files -> does not apply" "$?" "1"
printf 'x\n' > "$repo/notes.ts.bak"; printf 'x\n' > "$repo/.ts"; printf 'x\n' > "$repo/r.r"
integration_applies "$good" "$repo"; rc "look-alike names (.ts.bak, a bare .ts, wrong case) -> still does not apply" "$?" "1"
mkdir -p "$repo/node_modules/dep"; printf 'x\n' > "$repo/node_modules/dep/index.ts"
integration_applies "$good" "$repo"; rc "a .ts file only under node_modules -> does not apply" "$?" "1"
mkdir -p "$repo/src"; printf 'export {}\n' > "$repo/src/app.ts"
integration_applies "$good" "$repo"; rc "a .ts file added -> applies" "$?" "0"

# Inside a git work tree the file list is git's, so an ignored file does not make the tool apply.
if command -v git >/dev/null 2>&1; then
  grepo="$tmp/grepo"; mkdir -p "$grepo/dist"
  git -C "$grepo" init -q 2>/dev/null
  printf 'echo hi\n' > "$grepo/run.sh"; printf 'dist/\n' > "$grepo/.gitignore"
  printf 'x\n' > "$grepo/dist/out.ts"
  integration_applies "$good" "$grepo"; rc "git repo: a gitignored .ts file -> does not apply" "$?" "1"
  printf 'x\n' > "$grepo/untracked.tsx"
  integration_applies "$good" "$grepo"; rc "git repo: an untracked, unignored .tsx file -> applies" "$?" "0"
fi

# No predicate = language-agnostic (the two migrating installers): applies everywhere.
jq 'del(.appliesWhen)' "$good" > "$tmp/agnostic.json"
integration_applies "$tmp/agnostic.json" "$repo/scripts"; rc "no appliesWhen -> applies anywhere" "$?" "0"
integration_applies "$good" "$tmp/does-not-exist";        rc "absent dir -> does not apply" "$?" "1"

# ── 6. the config key that turns it on ─────────────────────────────────────────────────────────
t "config key is read from the descriptor" "$(integration_config_key "$good")" "codeGraph.provider"
printf '{"codeGraph":{"provider":"fixture-tool-provider"}}' > "$tmp/on.json"
printf '{"codeGraph":{"provider":"none"}}'                  > "$tmp/off.json"
printf '{"codeGraph":"oops"}'                               > "$tmp/odd.json"
printf '{}'                                                 > "$tmp/unset.json"
integration_enabled "$good" "$tmp/on.json";    rc "key holds the descriptor's value -> enabled" "$?" "0"
integration_enabled "$good" "$tmp/off.json";   rc "key holds another value -> not enabled" "$?" "1"
integration_enabled "$good" "$tmp/unset.json"; rc "key unset -> not enabled" "$?" "1"
integration_enabled "$good" "$tmp/odd.json";   rc "key path runs through a non-object -> not enabled" "$?" "1"
integration_enabled "$good" "$tmp/nope.json";  rc "no config file -> not enabled" "$?" "1"
# No `value` in the descriptor = a boolean switch (memory.enabled / local.enabled).
jq '.config = {"key":"memory.enabled"}' "$good" > "$tmp/bool.json"
printf '{"memory":{"enabled":true}}'  > "$tmp/mem-on.json"
printf '{"memory":{"enabled":false}}' > "$tmp/mem-off.json"
integration_enabled "$tmp/bool.json" "$tmp/mem-on.json";  rc "boolean key true -> enabled" "$?" "0"
integration_enabled "$tmp/bool.json" "$tmp/mem-off.json"; rc "boolean key false -> not enabled" "$?" "1"

# ── 7. the CLI form other scripts call ─────────────────────────────────────────────────────────
t "--list" "$(bash "$LIB/integrations.sh" --list)" "fixture-tool"
bash "$LIB/integrations.sh" --validate >/dev/null 2>&1;                  rc "--validate (all) -> rc 0" "$?" "0"
bash "$LIB/integrations.sh" --validate fixture-tool >/dev/null 2>&1;     rc "--validate <id> -> rc 0" "$?" "0"
bash "$LIB/integrations.sh" --applies fixture-tool "$repo" >/dev/null 2>&1;         rc "--applies on a .ts repo -> rc 0" "$?" "0"
bash "$LIB/integrations.sh" --applies fixture-tool "$repo/scripts" >/dev/null 2>&1; rc "--applies on a .sh-only dir -> rc 1" "$?" "1"
bash "$LIB/integrations.sh" --bogus >/dev/null 2>&1;                     rc "unknown flag -> rc 2" "$?" "2"

# ── 8. the same functions under zsh (scripts/lib is sourced from zsh too) ──────────────────────
if command -v zsh >/dev/null 2>&1; then
  zsh -fc "source '$LIB/integrations.sh'; integration_validate '$good' && integration_applies '$good' '$repo' && [ \"\$(integrations_list)\" = fixture-tool ]" >/dev/null 2>&1
  rc "zsh: source + validate + applies + list" "$?" "0"
  zsh -fc "source '$LIB/integrations.sh'; integration_applies '$good' '$repo/scripts'" >/dev/null 2>&1
  rc "zsh: .sh-only dir does not apply" "$?" "1"
fi
unset KIT_INTEGRATIONS_DIR

# ── 9. what actually ships ─────────────────────────────────────────────────────────────────────
jq -e . "$ROOT/integrations/integration.schema.json" >/dev/null 2>&1; rc "integration.schema.json is valid JSON" "$?" "0"
out="$(integrations_validate_all 2>&1)"; r=$?
rc "every shipped descriptor validates${out:+ ($out)}" "$r" "0"
jq -e . "$ROOT/kit.config.schema.json" >/dev/null 2>&1; rc "kit.config.schema.json is valid JSON" "$?" "0"
t "kit.config.schema.json declares codeGraph.provider" \
  "$(jq -r '.properties.codeGraph.properties.provider.type // "absent"' "$ROOT/kit.config.schema.json")" "string"
# Every key a shipped descriptor turns on needs a row in the config schema (E303 "For agents").
for id in $(integrations_list); do
  top="$(integration_config_key "$(integration_file "$id")" | cut -d. -f1)"
  t "config schema has a property for $id's key ($top)" \
    "$(jq -r --arg k "$top" '.properties | has($k)' "$ROOT/kit.config.schema.json")" "true"
done
t "package.json ships integrations/ in the npm tarball" \
  "$(jq -r '.files | index("integrations") != null' "$ROOT/package.json")" "true"

[ "$fail" -eq 0 ] && echo "ALL OK (integrations)" || echo "integrations: FAILURES"
exit "$fail"
