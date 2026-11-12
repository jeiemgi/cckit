#!/usr/bin/env bash
# adapter-select-test.sh — self-test for the adapter selection lib (E257.3, #260).
# Runs under bash AND zsh. Run:  bash scripts/lib/adapter-select-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)

if [ -n "${ADAPTER_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($ADAPTER_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($ADAPTER_TEST_INNER): $1"; fi; }

  . "$PLUGIN_DIR/scripts/lib/config-path.sh"
  . "$PLUGIN_DIR/scripts/lib/adapter-select.sh"
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

  # --- normalize ---------------------------------------------------------------------------
  t "claude"                 "$(adapter_normalize claude)"        "claude"
  t "codex"                  "$(adapter_normalize codex)"         "codex"
  t "both"                   "$(adapter_normalize both)"          "claude codex"
  t "comma list, any order"  "$(adapter_normalize codex,claude)"  "claude codex"
  t "case-insensitive"       "$(adapter_normalize Codex)"         "codex"
  t "repeat collapses"       "$(adapter_normalize 'codex codex')" "codex"
  adapter_normalize cursor >/dev/null 2>&1;  t "unknown name refused (rc)" "$?" "1"
  t "unknown name prints nothing on stdout" "$(adapter_normalize cursor 2>/dev/null)" ""
  adapter_normalize "" >/dev/null 2>&1;      t "empty spec refused (rc)"   "$?" "1"

  # --- set ops -----------------------------------------------------------------------------
  t "union adds the second"  "$(adapter_union claude codex)"          "claude codex"
  t "union is idempotent"    "$(adapter_union 'claude codex' codex)"  "claude codex"
  adapter_has "claude codex" codex;  t "has codex in both"    "$?" "0"
  adapter_has "claude" codex;        t "no codex in claude"   "$?" "1"
  adapter_has "codex" claude;        t "no claude in codex"   "$?" "1"
  t "json one"   "$(adapter_json claude)"         '["claude"]'
  t "json both"  "$(adapter_json 'claude codex')" '["claude","codex"]'

  # --- per-adapter layout ------------------------------------------------------------------
  t "claude dir"            "$(adapter_dir claude)"            ".claude"
  t "codex dir"             "$(adapter_dir codex)"             ".agents"
  t "claude instructions"   "$(adapter_instructions claude)"   "CLAUDE.md"
  t "codex instructions"    "$(adapter_instructions codex)"    "AGENTS.md"
  t "hook is tier B"        "$(adapter_tier .claude/hooks/repo-hygiene.sh)"   "B"
  t "claude skill is tier A" "$(adapter_tier .claude/skills/concrete/SKILL.md)" "A"
  t "codex skill is tier A"  "$(adapter_tier .agents/skills/concrete/SKILL.md)" "A"
  adapter_managed AGENTS.md;                          t "AGENTS.md is managed"            "$?" "0"
  adapter_managed .agents/rules/branch-naming.md;     t "codex rule is managed"           "$?" "0"
  adapter_managed .claude/kit.config.json;            t "config is NOT a managed artifact" "$?" "1"
  adapter_managed .claude/settings.local.json;        t "settings.local is NOT managed"   "$?" "1"
  adapter_managed scripts/task-sync.sh;               t "shared script is NOT adapter-managed" "$?" "1"
  adapter_managed .agents/product-marketing.md;       t "user file under .agents is NOT managed" "$?" "1"
  t "codex hook is tier B"  "$(adapter_tier .codex/hooks/kit-mail-check.sh)"  "B"
  adapter_managed .codex/hooks/kit-mail-check.sh;     t "codex hook script is managed"    "$?" "0"
  adapter_managed .codex/hooks.json;                  t "codex hooks.json is managed"     "$?" "0"
  adapter_managed .codex/config.toml;                 t "codex config.toml is NOT managed" "$?" "1"

  # --- stored selection --------------------------------------------------------------------
  printf '{"kitVersion":"1"}' > "$tmp/old.json"
  printf '{"adapters":["codex"]}' > "$tmp/codex.json"
  printf '{"adapters":["codex","claude"]}' > "$tmp/both.json"
  printf '{"adapters":["cursor"]}' > "$tmp/bad.json"
  t "no key means claude"       "$(adapter_list_from_config "$tmp/old.json")"   "claude"
  t "stored codex"              "$(adapter_list_from_config "$tmp/codex.json")" "codex"
  t "stored both, canonical"    "$(adapter_list_from_config "$tmp/both.json")"  "claude codex"
  t "missing config means claude" "$(adapter_list_from_config "$tmp/none.json")" "claude"
  adapter_list_from_config "$tmp/bad.json" >/dev/null 2>&1; t "unknown stored adapter refused" "$?" "1"

  # --- config + manifest location ----------------------------------------------------------
  mkdir -p "$tmp/c/.claude" "$tmp/x" "$tmp/self" "$tmp/new"
  printf '{}' > "$tmp/c/.claude/kit.config.json"
  printf '{"adapters":["codex"]}' > "$tmp/x/cckit.config.json"
  printf '{"github":{}}' > "$tmp/self/cckit.config.json"
  t "claude layout found"        "$(adapter_config_existing "$tmp/c")" "$tmp/c/.claude/kit.config.json"
  t "codex-only layout found"    "$(adapter_config_existing "$tmp/x")" "$tmp/x/cckit.config.json"
  adapter_config_existing "$tmp/self" >/dev/null 2>&1; t "self-host root config is not a scaffold" "$?" "1"
  adapter_config_existing "$tmp/new"  >/dev/null 2>&1; t "no config -> rc 1" "$?" "1"
  t "new claude config path"     "$(adapter_config_default "$tmp/new" claude)"         "$tmp/new/.claude/kit.config.json"
  t "new both config path"       "$(adapter_config_default "$tmp/new" 'claude codex')" "$tmp/new/.claude/kit.config.json"
  t "new codex-only config path" "$(adapter_config_default "$tmp/new" codex)"          "$tmp/new/cckit.config.json"
  t "new claude manifest"        "$(adapter_manifest_rel "$tmp/new" claude)" ".claude/kit.manifest.json"
  t "new codex-only manifest"    "$(adapter_manifest_rel "$tmp/new" codex)"  ".cckit/kit.manifest.json"
  mkdir -p "$tmp/x/.cckit"; printf '{}' > "$tmp/x/.cckit/kit.manifest.json"
  t "manifest does not move when claude is added" "$(adapter_manifest_rel "$tmp/x" 'claude codex')" ".cckit/kit.manifest.json"
  t "project selection read through the resolver" "$(KIT_CONFIG='' adapter_project_list "$tmp/x")" "codex"

  # --- ownership manifest: location + batch record (kit-manifest.sh) --------------------------
  . "$PLUGIN_DIR/scripts/lib/kit-manifest.sh"
  if command -v jq >/dev/null 2>&1; then
    mkdir -p "$tmp/m" && cd "$tmp/m"
    t "manifest default path"            "$(KIT_MANIFEST='' kit_manifest_path)" ".claude/kit.manifest.json"
    mkdir -p .cckit .agents/skills/a; printf '{"schema":1,"entries":{}}' > .cckit/kit.manifest.json
    t "codex-only manifest found by existence" "$(KIT_MANIFEST='' kit_manifest_path)" ".cckit/kit.manifest.json"
    printf 'one\n' > .agents/skills/a/SKILL.md; printf 'two\n' > AGENTS.md
    printf 'A\t.agents/skills/a/SKILL.md\nA\tAGENTS.md\nA\tmissing.md\n' | KIT_MANIFEST='' kit_manifest_record_batch init 1 2026-01-01T00:00:00Z
    t "batch rc"                         "$?" "0"
    t "batch records existing files only" "$(jq -r '.entries | keys | join(",")' .cckit/kit.manifest.json)" ".agents/skills/a/SKILL.md,AGENTS.md"
    t "batch entry verifies intact"      "$(KIT_MANIFEST='' kit_manifest_verify AGENTS.md)" "intact"
    t "batch stamps op + tier"           "$(jq -r '.entries["AGENTS.md"] | .op + "/" + .tier + "/" + .kitVersion' .cckit/kit.manifest.json)" "init/A/1"
    printf 'A\tAGENTS.md\nA\tAGENTS.md\n' | KIT_MANIFEST='' kit_manifest_record_batch init 2 2026-01-02T00:00:00Z
    t "re-recording adds no duplicate"   "$(jq -r '.entries | length' .cckit/kit.manifest.json)" "2"
    printf 'Z\tAGENTS.md\n' | KIT_MANIFEST='' kit_manifest_record_batch init 1 >/dev/null 2>&1
    t "batch refuses an unknown tier"    "$?" "1"
    t "batch made no .claude tree"       "$([ -e .claude ] && echo yes || echo no)" "no"
    mkdir -p .claude; printf '{"schema":1,"entries":{}}' > .claude/kit.manifest.json
    t ".claude manifest wins when both exist" "$(KIT_MANIFEST='' kit_manifest_path)" ".claude/kit.manifest.json"
    cd "$tmp" || exit 1
  fi

  # --- runtime report ----------------------------------------------------------------------
  mkdir -p "$tmp/bin"
  printf '#!/bin/sh\necho "codex-cli 9.9.9"\n' > "$tmp/bin/codex"; chmod +x "$tmp/bin/codex"
  rep="$(PATH="$tmp/bin:/usr/bin:/bin" adapter_runtime_report "claude codex")"
  t "selected runtime absent"  "$(printf '%s\n' "$rep" | sed -n 1p)" "$(printf 'claude\tabsent\t')"
  t "selected runtime present" "$(printf '%s\n' "$rep" | sed -n 2p)" "$(printf 'codex\tpresent\tcodex-cli 9.9.9')"
  t "only selected runtimes are reported" "$(PATH="$tmp/bin:/usr/bin:/bin" adapter_runtime_report codex | wc -l | tr -d ' ')" "1"

  # --- packaging: everything the installer reads ships in the npm artifact -------------------
  if command -v jq >/dev/null 2>&1; then
    for need in templates scripts; do
      t "package.json files[] ships $need/" "$(jq -r --arg n "$need" '.files | index($n) != null' "$PLUGIN_DIR/package.json")" "true"
    done
    t "one instruction source exists" "$([ -f "$PLUGIN_DIR/templates/instructions.md.tmpl" ] && echo yes || echo no)" "yes"
    t "no second instruction source"  "$(ls "$PLUGIN_DIR/templates" | grep -cE '^(CLAUDE|AGENTS)\.md\.tmpl$')" "0"
  fi

  [ "$fail" -eq 0 ] && echo "ALL OK($ADAPTER_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  ADAPTER_TEST_INNER="$sh" PATH="$PATH" PLUGIN_DIR="$PLUGIN_DIR" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
