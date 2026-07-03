#!/usr/bin/env bash
# init-upgrade-test.sh — self-test for the `init.sh --upgrade` clobber contract (#334).
#
# Reproduces the 2026-06-11 incident in a throwaway project and asserts the fix:
#   1. existing kit-owned files (scripts/) are PRESERVED, never downgraded to older templates;
#   2. paths the project removed/renamed (kit.config.json `upgrade.removed/renamed`) are
#      NEVER re-added by "add missing files";
#   3. the net effect of an upgrade on a converged project is ONLY the kitVersion bump.
#
# Network-free: drives init.sh through the --upgrade path only (skips kit-doctor + gh).
# Run:  bash scripts/init-upgrade-test.sh

set -uo pipefail
PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
INIT="$PLUGIN_DIR/scripts/init.sh"

fail=0
t() {  # t <label> <got> <want>
  if [ "$2" != "$3" ]; then echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok: $1"; fi
}

command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not available";  exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }

PLUGIN_VERSION="$(jq -r '.version // "0.0.0"' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo 0.0.0)"

proj="$(mktemp -d)"; trap 'rm -rf "$proj"' EXIT
cd "$proj"
git init -q
git config user.email kit-test@example.com
git config user.name  kit-test

# --- seed a minimal initialized project so the --upgrade path engages (no doctor/gh) ----
mkdir -p .claude
cat > .claude/kit.config.json <<JSON
{
  "kitVersion": "0.0.1",
  "profile": "software",
  "project": { "name": "UpgradeTest", "slug": "upgrade-test" },
  "github": { "repo": "example/upgrade-test", "owner": "example", "projectsV2": false }
}
JSON

# First upgrade = full scaffold via the upgrade path. --force skips the dirty-tree guard
# (the seed config is still untracked at this point).
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$INIT" --upgrade --target "$proj" --force >/dev/null 2>&1 \
  || { echo "FAIL: initial scaffold (--upgrade) exited non-zero"; exit 1; }

t "scaffold added morning-briefing skill" "$([ -f .claude/skills/morning-briefing/SKILL.md ] && echo yes || echo no)" "yes"
t "scaffold added speckit skill"         "$([ -d .claude/skills/speckit ] && echo yes || echo no)"           "yes"
t "scaffold added task-management rule"  "$([ -f .claude/rules/task-management.md ] && echo yes || echo no)" "yes"
t "scaffold copied task-sync.sh"         "$([ -f scripts/task-sync.sh ] && echo yes || echo no)"             "yes"

git add -A && git commit -q -m "scaffold"

# --- simulate the project's deliberate divergence (the cckit state) --------------------
# rename a scaffolded skill, delete two scaffolded paths, register them in the upgrade block,
# and mark a kit-owned script so a downgrade would be detectable.
git mv .claude/skills/morning-briefing .claude/skills/kit-morning-briefing
git rm -q -r .claude/skills/speckit
git rm -q    .claude/rules/task-management.md
MARKER="# LOCAL-FIX-MARKER-#334 (must survive upgrade)"
printf '\n%s\n' "$MARKER" >> scripts/task-sync.sh

jq --arg k "0.0.1" '
  .kitVersion = $k
  | .upgrade = {
      removed: [ ".claude/skills/speckit", ".claude/rules/task-management.md" ],
      renamed: { ".claude/skills/morning-briefing": ".claude/skills/kit-morning-briefing" }
    }' .claude/kit.config.json > .claude/kit.config.json.tmp && mv .claude/kit.config.json.tmp .claude/kit.config.json

git add -A && git commit -q -m "diverge: rename + delete + register exclusions"

# --- the upgrade under test (clean tree, real un-forced path) --------------------------
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$INIT" --upgrade --target "$proj" >/dev/null 2>&1 \
  || { echo "FAIL: upgrade under test exited non-zero"; exit 1; }

# 1. removed/renamed are NOT resurrected
t "renamed morning-briefing NOT re-added" "$([ -e .claude/skills/morning-briefing ] && echo present || echo absent)" "absent"
t "removed speckit NOT re-added"         "$([ -e .claude/skills/speckit ] && echo present || echo absent)"         "absent"
t "removed rule NOT re-added"            "$([ -e .claude/rules/task-management.md ] && echo present || echo absent)" "absent"
t "renamed target still present"         "$([ -d .claude/skills/kit-morning-briefing ] && echo yes || echo no)"   "yes"

# 2. kit-owned script PRESERVED (not downgraded — marker survives)
t "script not downgraded (marker kept)"  "$(grep -cF "$MARKER" scripts/task-sync.sh)" "1"

# 3. net effect = ONLY the kitVersion bump
changed="$(git status --porcelain | awk '{print $2}' | sort | tr '\n' ' ' | sed 's/ $//')"
t "only kit.config.json changed"         "$changed" ".claude/kit.config.json"

diff_body="$(git diff -- .claude/kit.config.json | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)')"
only_kitver="$(printf '%s\n' "$diff_body" | grep -vqE '"kitVersion"' && echo no || echo yes)"
t "diff is only the kitVersion line"     "$only_kitver" "yes"
t "kitVersion bumped to plugin version"  "$(jq -r '.kitVersion' .claude/kit.config.json)" "$PLUGIN_VERSION"
t "upgrade block preserved through merge" "$(jq -r '.upgrade.removed | length' .claude/kit.config.json)" "2"

# --- #149: upgrade preserves existing project files -------------------------------------
# 4. feature keys deliberately absent from the config are NOT injected by the merge
#    (the seed config never had plans/specKit/prePush/local/memory — profile defaults must
#    not resurrect them), while REQUIRED structural keys still merge in.
for k in plans specKit prePush local memory; do
  t "feature key '$k' not injected"      "$(jq --arg k "$k" 'has($k)' .claude/kit.config.json)" "false"
done
t "required key 'knowledge' still added" "$(jq -r '.knowledge.dir // "absent"' .claude/kit.config.json)" "knowledge"

# 5. a CUSTOMIZED statusline shim survives the next upgrade (the v0.3.0 clobber: kit-wire
#    replaced a repointed shim with the template on every upgrade).
git add -A && git commit -q -m "settle upgrade under test"
t "statusline shim exists after wire"    "$([ -f .claude/statusline.sh ] && echo yes || echo no)" "yes"
SL_MARKER="# LOCAL-STATUSLINE-EDIT-#149 (must survive upgrade)"
printf '\n%s\n' "$SL_MARKER" >> .claude/statusline.sh
jq '.kitVersion = "0.0.2"' .claude/kit.config.json > .claude/kit.config.json.tmp \
  && mv .claude/kit.config.json.tmp .claude/kit.config.json
git add -A && git commit -q -m "customize statusline + reset version"

CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$INIT" --upgrade --target "$proj" >/dev/null 2>&1 \
  || { echo "FAIL: statusline upgrade run exited non-zero"; exit 1; }
t "customized statusline preserved (tracked: modified)" "$(grep -cF "$SL_MARKER" .claude/statusline.sh)" "1"

# ...and also when the manifest is absent (fresh clone: shim exists but is UNTRACKED).
git add -A && git commit -q -m "settle statusline upgrade"
rm -f .claude/kit.manifest.json
jq '.kitVersion = "0.0.3"' .claude/kit.config.json > .claude/kit.config.json.tmp \
  && mv .claude/kit.config.json.tmp .claude/kit.config.json
git add -A && git commit -q -m "reset version (manifest absent)"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$INIT" --upgrade --target "$proj" >/dev/null 2>&1 \
  || { echo "FAIL: manifest-absent upgrade run exited non-zero"; exit 1; }
t "customized statusline preserved (untracked)" "$(grep -cF "$SL_MARKER" .claude/statusline.sh)" "1"
t "feature keys still absent after repeat upgrades" "$(jq 'has("plans")' .claude/kit.config.json)" "false"

echo ""
[ "$fail" -eq 0 ] && echo "PASS: init.sh --upgrade honors the preserve/exclude contract (#334, #149)" || echo "FAILED"
exit "$fail"
