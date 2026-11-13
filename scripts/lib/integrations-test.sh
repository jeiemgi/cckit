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
rejects "platform os outside the list" '.appliesWhen.platform = {"os":"Plan9"}' "appliesWhen.platform.os: must be one of"
rejects "unknown platform field"       '.appliesWhen.platform = {"cpu":"arm64"}' "appliesWhen.platform.cpu: unknown field"
rejects "bootstrap without a command"  '.install[0].bootstrap = {"manager":"brew"}' "install[0].bootstrap.run: required field is missing"
rejects "bootstrap by an unknown manager" '.install[0].bootstrap = {"manager":"apt","run":"apt install npm"}' "install[0].bootstrap.manager: must be one of"
rejects "empty detect.bin"             '.detect.bin = ""'                   "detect.bin: must not be empty"
rejects "empty afterInstall"           '.afterInstall = ""'                 "afterInstall: must not be empty"

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

# The second kind of condition judges the MACHINE: `platform` is compared to `uname` verbatim. A
# stub `uname` first on PATH makes this the same on every host.
ubin="$tmp/ubin"; mkdir -p "$ubin"
printf '#!/bin/sh\ncase "${1:-}" in -m) echo "$FAKE_ARCH" ;; *) echo "$FAKE_OS" ;; esac\n' > "$ubin/uname"; chmod +x "$ubin/uname"
on_machine() { FAKE_OS="$1" FAKE_ARCH="$2" PATH="$ubin:$PATH" integration_applies "$3" "$4"; }
jq 'del(.appliesWhen) | .appliesWhen = {"platform":{"os":"Darwin","arch":"arm64"}}' "$good" > "$tmp/plat.json"
on_machine Darwin arm64  "$tmp/plat.json" "$repo/scripts"; rc "platform matches -> applies, whatever the repo holds" "$?" "0"
on_machine Darwin x86_64 "$tmp/plat.json" "$repo";         rc "wrong arch -> does not apply" "$?" "1"
on_machine Linux  arm64  "$tmp/plat.json" "$repo";         rc "wrong os -> does not apply" "$?" "1"
jq '.appliesWhen = {"platform":{"os":"Linux"}}' "$good" > "$tmp/os-only.json"
on_machine Linux aarch64 "$tmp/os-only.json" "$repo";      rc "os alone, arch unstated -> any arch applies" "$?" "0"
# Both kinds present: every one must hold.
jq '.appliesWhen.platform = {"os":"Darwin","arch":"arm64"}' "$good" > "$tmp/both.json"
on_machine Darwin arm64  "$tmp/both.json" "$repo";         rc "platform + extension both hold -> applies" "$?" "0"
on_machine Darwin arm64  "$tmp/both.json" "$repo/scripts"; rc "platform holds, no listed extension -> does not apply" "$?" "1"
on_machine Darwin x86_64 "$tmp/both.json" "$repo";         rc "extension holds, wrong platform -> does not apply" "$?" "1"
t "the conditions in words: extensions" "$(integration_applies_needs "$good")" "at least one file ending in: .ts .tsx .R"
t "the conditions in words: platform"   "$(integration_applies_needs "$tmp/plat.json")" "a Darwin arm64 machine"
t "the conditions in words: both"       "$(integration_applies_needs "$tmp/both.json")" "a Darwin arm64 machine, and at least one file ending in: .ts .tsx .R"
t "the conditions in words: none"       "$(integration_applies_needs "$tmp/agnostic.json")" ""

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
# `config.default: true` (#451) = on wherever the config does not hold the key; only an explicit
# other value turns it off. No config file is still "not enabled": there is no project to be on in.
jq '.config = {"key":"memory.enabled","default":true}' "$good" > "$tmp/defon.json"
# Validated under the fixture's own file name: the id must match the stem.
mkdir -p "$tmp/defon" "$tmp/defbad"; cp "$tmp/defon.json" "$tmp/defon/fixture-tool.json"
integration_validate "$tmp/defon/fixture-tool.json" >/dev/null 2>&1; rc "config.default is a valid field" "$?" "0"
integration_enabled "$tmp/defon.json" "$tmp/unset.json";   rc "default-on, key unset -> enabled" "$?" "0"
integration_enabled "$tmp/defon.json" "$tmp/mem-on.json";  rc "default-on, key true -> enabled" "$?" "0"
integration_enabled "$tmp/defon.json" "$tmp/mem-off.json"; rc "default-on, key false -> not enabled" "$?" "1"
integration_enabled "$tmp/defon.json" "$tmp/nope.json";    rc "default-on, no config file -> not enabled" "$?" "1"
integration_default_on "$tmp/defon.json"; rc "integration_default_on: a default-on descriptor" "$?" "0"
integration_default_on "$tmp/bool.json";  rc "integration_default_on: an opt-in descriptor" "$?" "1"
integration_explicit "$tmp/defon.json" "$tmp/unset.json";   rc "integration_explicit: key absent" "$?" "1"
integration_explicit "$tmp/defon.json" "$tmp/mem-off.json"; rc "integration_explicit: key present and false" "$?" "0"
jq '.config = {"key":"memory.enabled","default":"yes"}' "$good" > "$tmp/defbad/fixture-tool.json"
has "config.default must be a boolean" "$(integration_validate "$tmp/defbad/fixture-tool.json" 2>&1)" "config.default: expected boolean"
lav="$ROOT/integrations/lavish.json"
integration_validate "$lav" >/dev/null 2>&1; rc "lavish validates" "$?" "0"
t "lavish: turned off by reviewPages.enabled" "$(integration_config_key "$lav")" "reviewPages.enabled"
integration_default_on "$lav"; rc "lavish: on by default" "$?" "0"
t "lavish: ships the review-pages rule" "$(jq -c '.rules' "$lav")" '["review-pages"]'
t "lavish: its rule template exists" "$([ -f "$ROOT/templates/rules/review-pages.md" ] && echo yes || echo no)" "yes"

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

# The two tools that used to be hardcoded in scripts/kit-doctor.sh (E303.4), one unit test each.
# They are unlike on purpose: the format has to carry both shapes.
t "shipped descriptors" "$(integrations_list | tr '\n' ' ')" "graft lavish mempalace mlx-lm "
mp="$ROOT/integrations/mempalace.json"; mlx="$ROOT/integrations/mlx-lm.json"
integration_validate "$mp" >/dev/null 2>&1;  rc "mempalace validates" "$?" "0"
t "mempalace: turned on by memory.enabled" "$(integration_config_key "$mp")" "memory.enabled"
t "mempalace: pipx first, uv second" "$(jq -r '[.install[].run] | join(" | ")' "$mp")" "pipx install mempalace | uv tool install mempalace"
t "mempalace: bootstrap brings pipx, the FIRST candidate's manager" "$(jq -r '.install[0].bootstrap | "\(.manager): \(.run)"' "$mp")" "brew: brew install pipx"
t "mempalace: no applicability condition" "$(jq -r 'has("appliesWhen")' "$mp")" "false"
on_machine Linux x86_64 "$mp" "$repo/scripts"; rc "mempalace applies on any machine and repo" "$?" "0"
t "mempalace: not affiliated" "$(jq -r '.attribution.affiliated' "$mp")" "false"
integration_validate "$mlx" >/dev/null 2>&1; rc "mlx-lm validates" "$?" "0"
t "mlx-lm: turned on by local.enabled" "$(integration_config_key "$mlx")" "local.enabled"
t "mlx-lm: uv first, pipx second" "$(jq -r '[.install[].run] | join(" | ")' "$mlx")" "uv tool install mlx-lm | pipx install mlx-lm"
t "mlx-lm: bootstrap is brew install uv" "$(jq -r '.install[0].bootstrap | "\(.manager): \(.run)"' "$mlx")" "brew: brew install uv"
on_machine Darwin arm64  "$mlx" "$repo/scripts"; rc "mlx-lm applies on Apple silicon" "$?" "0"
on_machine Darwin x86_64 "$mlx" "$repo";         rc "mlx-lm does not apply on an Intel Mac" "$?" "1"
on_machine Linux  aarch64 "$mlx" "$repo";        rc "mlx-lm does not apply on Linux" "$?" "1"
t "mlx-lm: not affiliated" "$(jq -r '.attribution.affiliated' "$mlx")" "false"
# Neither descriptor may fall back to plain pip: Homebrew's Python is externally managed (PEP 668).
t "no shipped candidate is a plain pip install" \
  "$(jq -r '.install[].run, (.install[].bootstrap.run // empty)' "$mp" "$mlx" | grep -cE '(^| )pip3? install' )" "0"

# Graft (E303.10): the first descriptor that judges the REPO (anyExtension), wires into it, and
# ships a rule. The wire flags below are the ones the hook-merge test ran with.
gr="$ROOT/integrations/graft.json"
integration_validate "$gr" >/dev/null 2>&1; rc "graft validates" "$?" "0"
t "graft: turned on by codeGraph.provider" "$(integration_config_key "$gr")" "codeGraph.provider"
t "graft: ON value names the provider" "$(jq -r '.config.value' "$gr")" "graft"
t "graft: npm before pnpm" "$(jq -r '[.install[].manager] | join(" ")' "$gr")" "npm pnpm"
t "graft: every candidate leaves a binary (the wire step needs one)" "$(jq -r '[.install[] | select(.resident == false)] | length' "$gr")" "0"
t "graft: wire flags decline the statusline and every out-of-repo write" \
  "$(jq -r '.wire.declined | keys_unsorted | join(" ")' "$gr")" "--no-statusline --no-global"
t "graft: hooks are NOT declined" "$(jq -r '.wire.declined | has("--no-hooks")' "$gr")" "false"
has "graft: the hook decision records its test" "$(jq -r '.wire.kept.hooks' "$gr")" "All four entries survived"
t "graft: never auto-runs the LLM build" "$(jq -r '.build.deep.auto' "$gr")" "false"
t "graft: not affiliated" "$(jq -r '.attribution.affiliated' "$gr")" "false"
on_machine Darwin arm64 "$gr" "$repo/scripts"; rc "graft does not apply to a .sh-only repo" "$?" "1"
on_machine Linux x86_64 "$gr" "$repo";         rc "graft applies once a .ts file exists" "$?" "0"
# Every rule a descriptor ships must exist as a template, or `cckit add` would write nothing.
for id in $(integrations_list); do
  for r in $(jq -r '.rules // [] | .[]' "$(integration_file "$id")"); do
    t "$id: rule template $r exists" "$([ -f "$ROOT/templates/rules/$r.md" ] && echo yes || echo no)" "yes"
  done
done
t "graft: ships the code-retrieval rule" "$(jq -c '.rules' "$gr")" '["code-retrieval"]'
rule="$ROOT/templates/rules/code-retrieval.md"
# `cckit add` copies the rule verbatim, so it must hold nothing init.sh would have to resolve.
t "code-retrieval: no template variable or IF block" "$(grep -cE '\{\{|<!-- /?IF:' "$rule")" "0"
t "code-retrieval: names no machine-specific search tool" "$(grep -ciE '(^|[^a-z])fff([^a-z]|$)' "$rule")" "0"
for verb in 'graft ask' 'graft grep' 'graft skeleton' 'graft callers' 'graft map' 'graft blast --base'; do
  has "code-retrieval routes: $verb" "$(cat "$rule")" "$verb"
done
has "code-retrieval: the fallback is silent" "$(cat "$rule")" "Fall back to Grep/Glob silently"
has "code-retrieval: the vendor numbers are attributed" "$(cat "$rule")" "cckit has not reproduced them"
bad="$(jq '.rules = ["Not A Rule"]' "$gr" > "$tmp/graft.json"; integration_validate "$tmp/graft.json" 2>&1)"
has "a rule name outside the grammar is refused" "$bad" "rules[0]"
bad="$(jq '.wire.kept = "yes"' "$gr" > "$tmp/graft.json"; integration_validate "$tmp/graft.json" 2>&1)"
has "wire.kept must be an object" "$bad" "wire.kept: expected object"

t "kit.config.schema.json declares local.enabled" \
  "$(jq -r '.properties.local.properties.enabled.type // "absent"' "$ROOT/kit.config.schema.json")" "boolean"
t "package.json ships integrations/ in the npm tarball" \
  "$(jq -r '.files | index("integrations") != null' "$ROOT/package.json")" "true"

[ "$fail" -eq 0 ] && echo "ALL OK (integrations)" || echo "integrations: FAILURES"
exit "$fail"
