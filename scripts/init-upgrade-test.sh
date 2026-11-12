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
# E303.10: the code-graph integration is off in this config, so the scaffold carries neither the
# retrieval rule nor its CLAUDE.md line.
t "integration off: no code-retrieval rule" "$([ -e .claude/rules/code-retrieval.md ] && echo present || echo absent)" "absent"
t "integration off: no CLAUDE.md line"      "$(grep -c 'code-retrieval' CLAUDE.md)" "0"
t "no unresolved IF marker in CLAUDE.md"    "$(grep -c 'IF:CODEGRAPH' CLAUDE.md)" "0"
# task-sync.sh sources board-view.sh under `set -e` and effort-plan.sh for --plan (#383).
t "scaffold copied board-view.sh"        "$([ -f scripts/lib/board-view.sh ] && echo yes || echo no)"        "yes"
t "scaffold copied effort-plan.sh"       "$([ -f scripts/lib/effort-plan.sh ] && echo yes || echo no)"       "yes"


# #357: the instruction-budget lint ships with the scaffold, its baseline is seeded once, and the
# scaffold starts green — the two shipped rules over 200 lines are grandfathered, not failures.
t "scaffold copied instruction-budget-lint.sh" "$([ -x scripts/instruction-budget-lint.sh ] && echo yes || echo no)" "yes"
IB_BASELINE="$(bash scripts/instruction-budget-lint.sh --baseline-path 2>/dev/null)"
t "instruction-budget baseline seeded"   "$([ -f "$IB_BASELINE" ] && echo yes || echo no)" "yes"
t "seeded baseline grandfathers effort-model.md" "$(grep -c '^\.claude/rules/effort-model\.md [0-9]*$' "$IB_BASELINE")" "1"
t "scaffolded project passes the instruction-budget lint" "$(bash scripts/instruction-budget-lint.sh >/dev/null 2>&1; echo $?)" "0"
IB_MARKER="# LOCAL-BASELINE-MARKER-#357 (a second init run must not rewrite the baseline)"
printf '%s\n' "$IB_MARKER" >> "$IB_BASELINE"

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

t "instruction-budget baseline not rewritten (marker kept)" "$(grep -cF "$IB_MARKER" "$IB_BASELINE")" "1"

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

# --- E303.10: an upgrade over a config with a code-graph integration ON -----------------
# `"none"` is off; a provider name is on. CLAUDE.md is removed first so the upgrade regenerates it
# (an existing CLAUDE.md is preserved, line or no line).
git add -A && git commit -q -m "settle before code-graph cases"
jq '.kitVersion = "0.0.4" | .codeGraph = {provider: "none"}' .claude/kit.config.json > .claude/kit.config.json.tmp \
  && mv .claude/kit.config.json.tmp .claude/kit.config.json
rm -f CLAUDE.md
git add -A && git commit -q -m "codeGraph none"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$INIT" --upgrade --target "$proj" >/dev/null 2>&1 \
  || { echo "FAIL: codeGraph-none upgrade run exited non-zero"; exit 1; }
t "provider none: no code-retrieval rule" "$([ -e .claude/rules/code-retrieval.md ] && echo present || echo absent)" "absent"
t "provider none: no CLAUDE.md line"      "$(grep -c 'code-retrieval' CLAUDE.md)" "0"

jq '.kitVersion = "0.0.5" | .codeGraph.provider = "graft"' .claude/kit.config.json > .claude/kit.config.json.tmp \
  && mv .claude/kit.config.json.tmp .claude/kit.config.json
rm -f CLAUDE.md
git add -A && git commit -q -m "codeGraph graft"
CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$INIT" --upgrade --target "$proj" >/dev/null 2>&1 \
  || { echo "FAIL: codeGraph-on upgrade run exited non-zero"; exit 1; }
t "provider on: code-retrieval rule added" "$([ -f .claude/rules/code-retrieval.md ] && echo yes || echo no)" "yes"
t "provider on: CLAUDE.md carries the line" "$(grep -c 'rules/code-retrieval.md' CLAUDE.md)" "1"
t "provider on: the key survives the merge" "$(jq -r '.codeGraph.provider' .claude/kit.config.json)" "graft"

# --- E257.3: adapter selection — claude / codex / both ----------------------------------
# Fresh inits in throwaway projects. KIT_INIT_PREFLIGHT=0 skips the doctor (it installs packages and
# checks gh auth); --repo/--owner-login/KIT_BASE_BRANCH answer every question gh would be asked.
fx="$(mktemp -d)"; trap 'rm -rf "$proj" "$fx"' EXIT
fresh() {  # fresh <dir> <adapter>
  mkdir -p "$fx/$1" && git -C "$fx/$1" init -q \
    && git -C "$fx/$1" config user.email kit-test@example.com && git -C "$fx/$1" config user.name kit-test \
    && KIT_INIT_PREFLIGHT=0 KIT_BASE_BRANCH=main CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$INIT" \
         --profile minimal --adapter "$2" --target "$fx/$1" --repo example/fx --owner-login example \
         >/dev/null 2>&1 </dev/null
}
upgrade() {  # upgrade <dir> [extra init flags…]
  local d="$1"; shift
  CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" bash "$INIT" --upgrade --target "$fx/$d" "$@" >/dev/null 2>&1 </dev/null
}
settle() { git -C "$fx/$1" add -A >/dev/null 2>&1 && git -C "$fx/$1" commit -q -m "$2" >/dev/null 2>&1; }
setver() {  # setver <dir> <config-relpath> <version>
  jq --arg v "$3" '.kitVersion = $v' "$fx/$1/$2" > "$fx/$1/$2.tmp" && mv "$fx/$1/$2.tmp" "$fx/$1/$2"
}
# Every file under an adapter's managed trees (and its instruction file) — what the manifest must list.
managed_files() {  # managed_files <dir> <claude|codex>
  ( cd "$fx/$1" || exit 0
    if [ "$2" = claude ]; then
      find .claude/skills .claude/rules .claude/agents .claude/hooks .claude/lib -type f 2>/dev/null
      [ -f CLAUDE.md ] && echo CLAUDE.md
    else
      find .agents/skills .agents/rules .codex/agents -type f 2>/dev/null
      [ -f AGENTS.md ] && echo AGENTS.md
    fi ) | sed 's|^\./||' | sort
}
unrecorded() {  # unrecorded <dir> <manifest-relpath> <adapter> -> managed files missing from the manifest
  managed_files "$1" "$3" | while IFS= read -r f; do
    jq -e --arg f "$f" '.entries | has($f)' "$fx/$1/$2" >/dev/null 2>&1 || echo "$f"
  done | tr '\n' ' '
}
tree_hash() {  # tree_hash <dir> <path…> -> one hash over every file's path + content
  local d="$1"; shift
  ( cd "$fx/$d" && find "$@" -type f 2>/dev/null | sort | while IFS= read -r f; do
      printf '%s ' "$f"; { shasum -a 256 "$f" 2>/dev/null || sha256sum "$f"; } | awk '{print $1}'
    done ) | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}'
}
has_path() { [ -e "$fx/$1/$2" ] && echo yes || echo no; }

fresh c claude || { echo "FAIL: fresh --adapter claude exited non-zero"; fail=1; }
fresh x codex  || { echo "FAIL: fresh --adapter codex exited non-zero";  fail=1; }
fresh b both   || { echo "FAIL: fresh --adapter both exited non-zero";   fail=1; }

# 6. each selection produces ONLY its adapter's managed files
t "claude: CLAUDE.md written"            "$(has_path c CLAUDE.md)" "yes"
t "claude: .claude skills written"       "$(has_path c .claude/skills/concrete/SKILL.md)" "yes"
t "claude: no AGENTS.md"                 "$(has_path c AGENTS.md)" "no"
t "claude: no .agents tree"              "$(has_path c .agents)" "no"
t "claude: stored selection"             "$(jq -c '.adapters' "$fx/c/.claude/kit.config.json")" '["claude"]'
t "codex: AGENTS.md written"             "$(has_path x AGENTS.md)" "yes"
t "codex: skills under .agents/skills"   "$(has_path x .agents/skills/concrete/SKILL.md)" "yes"
t "codex: rules under .agents/rules"     "$(has_path x .agents/rules/branch-naming.md)" "yes"
t "codex: no CLAUDE.md"                  "$(has_path x CLAUDE.md)" "no"
t "codex: no .claude tree at all"        "$(has_path x .claude)" "no"
t "codex: config at the root"            "$(jq -c '.adapters' "$fx/x/cckit.config.json")" '["codex"]'
t "codex: manifest under .cckit/"        "$(has_path x .cckit/kit.manifest.json)" "yes"
t "codex: manifest is gitignored"        "$(grep -cxF '.cckit/kit.manifest.json' "$fx/x/.gitignore")" "1"
t "codex: no Claude settings ignore line" "$(grep -cF '.claude' "$fx/x/.gitignore")" "0"
t "both: CLAUDE.md + AGENTS.md"          "$(has_path b CLAUDE.md)$(has_path b AGENTS.md)" "yesyes"
t "both: both skill trees"               "$(has_path b .claude/skills/concrete/SKILL.md)$(has_path b .agents/skills/concrete/SKILL.md)" "yesyes"
t "both: stored selection"               "$(jq -c '.adapters' "$fx/b/.claude/kit.config.json")" '["claude","codex"]'
t "both: one manifest, in .claude/"      "$(has_path b .claude/kit.manifest.json)$(has_path b .cckit)" "yesno"

# 7. every managed file is in the ownership manifest
t "claude: every managed file recorded"  "$(unrecorded c .claude/kit.manifest.json claude)" ""
t "codex: every managed file recorded"   "$(unrecorded x .cckit/kit.manifest.json codex)" ""
t "both: claude files recorded"          "$(unrecorded b .claude/kit.manifest.json claude)" ""
t "both: codex files recorded"           "$(unrecorded b .claude/kit.manifest.json codex)" ""
t "codex: managed set is not empty"      "$([ "$(managed_files x codex | wc -l | tr -d ' ')" -ge 5 ] && echo yes || echo no)" "yes"
t "config is not a manifest entry"       "$(jq '.entries | has("cckit.config.json") or has(".claude/kit.config.json")' "$fx/x/.cckit/kit.manifest.json")" "false"

# 8. nothing generated on the Codex side carries a machine path or a Claude plugin variable
t "codex: no absolute machine path"      "$(grep -rlF "$fx" "$fx/x/AGENTS.md" "$fx/x/.agents" "$fx/x/cckit.config.json" 2>/dev/null | wc -l | tr -d ' ')" "0"
t "codex: no CLAUDE_PLUGIN_ROOT"         "$(grep -rlE 'CLAUDE_PLUGIN_ROOT|CLAUDE_PROJECT_DIR' "$fx/x/AGENTS.md" "$fx/x/.agents" "$fx/x/cckit.config.json" 2>/dev/null | wc -l | tr -d ' ')" "0"
t "codex: no unrendered placeholder"     "$(grep -rlE '\{\{[A-Z_]+\}\}' "$fx/x/AGENTS.md" "$fx/x/.agents" 2>/dev/null | wc -l | tr -d ' ')" "0"
t "codex: instructions point at .agents" "$(grep -c '\.agents/rules/branch-naming\.md' "$fx/x/AGENTS.md")" "1"
t "codex: instructions name no .claude path" "$(grep -c '\.claude/' "$fx/x/AGENTS.md")" "0"
t "both: codex side has no machine path" "$(grep -rlF "$fx" "$fx/b/AGENTS.md" "$fx/b/.agents" 2>/dev/null | wc -l | tr -d ' ')" "0"

# 9. an unknown adapter refuses before anything is written
mkdir -p "$fx/bad"
KIT_INIT_PREFLIGHT=0 bash "$INIT" --profile minimal --adapter cursor --target "$fx/bad" >/dev/null 2>&1 </dev/null
t "unknown adapter refused (rc)"         "$?" "1"
t "unknown adapter wrote nothing"        "$(ls -A "$fx/bad" | wc -l | tr -d ' ')" "0"

# 10. --upgrade keeps the stored selection and a hand-edited adapter file (Codex-only project)
settle x "scaffold codex"
X_MARKER="# LOCAL-CODEX-EDIT (must survive upgrade)"
printf '\n%s\n' "$X_MARKER" >> "$fx/x/.agents/skills/concrete/SKILL.md"
rm -f "$fx/x/.agents/rules/branch-naming.md"       # a missing file the upgrade should restore
setver x cckit.config.json 0.0.1
settle x "edit a skill, drop a rule, reset version"
x_entries="$(jq '.entries | length' "$fx/x/.cckit/kit.manifest.json")"
upgrade x || { echo "FAIL: codex-only upgrade exited non-zero"; fail=1; }
t "upgrade: selection still codex"       "$(jq -c '.adapters' "$fx/x/cckit.config.json")" '["codex"]'
t "upgrade: kitVersion bumped"           "$(jq -r '.kitVersion' "$fx/x/cckit.config.json")" "$PLUGIN_VERSION"
t "upgrade: still no .claude tree"       "$(has_path x .claude)" "no"
t "upgrade: still no CLAUDE.md"          "$(has_path x CLAUDE.md)" "no"
t "upgrade: hand-edited skill kept"      "$(grep -cF "$X_MARKER" "$fx/x/.agents/skills/concrete/SKILL.md")" "1"
t "upgrade: edited skill reads modified" "$(cd "$fx/x" && . "$PLUGIN_DIR/scripts/lib/kit-manifest.sh" && kit_manifest_verify .agents/skills/concrete/SKILL.md)" "modified"
t "upgrade: missing rule restored"       "$(has_path x .agents/rules/branch-naming.md)" "yes"
t "upgrade: no duplicate manifest entries" "$(jq '.entries | length' "$fx/x/.cckit/kit.manifest.json")" "$x_entries"

# 11. a repeated upgrade changes nothing
settle x "settle upgrade"
x_manifest="$(jq -S '.entries | map_values(.hash)' "$fx/x/.cckit/kit.manifest.json")"
setver x cckit.config.json 0.0.2; settle x "reset version again"
upgrade x || { echo "FAIL: repeated codex upgrade exited non-zero"; fail=1; }
t "repeat: same manifest paths + hashes" "$(jq -S '.entries | map_values(.hash)' "$fx/x/.cckit/kit.manifest.json")" "$x_manifest"
t "repeat: only the config changed"      "$(git -C "$fx/x" status --porcelain | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')" "cckit.config.json"
upgrade x; t "same-version upgrade is a no-op (rc 0)" "$?" "0"
t "same-version upgrade wrote nothing"   "$(git -C "$fx/x" status --porcelain | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')" "cckit.config.json"

# 12. enabling the second adapter leaves the first one's files byte-identical
settle c "scaffold claude"
c_before="$(tree_hash c .claude/skills .claude/rules .claude/agents .claude/hooks .claude/lib .claude/settings.json .claude/settings.local.json .claude/statusline.sh CLAUDE.md)"
c_entries="$(jq '.entries | length' "$fx/c/.claude/kit.manifest.json")"
upgrade c --adapter codex || { echo "FAIL: enabling codex on a claude project exited non-zero"; fail=1; }
t "add codex: claude files byte-identical" "$(tree_hash c .claude/skills .claude/rules .claude/agents .claude/hooks .claude/lib .claude/settings.json .claude/settings.local.json .claude/statusline.sh CLAUDE.md)" "$c_before"
t "add codex: selection is both"         "$(jq -c '.adapters' "$fx/c/.claude/kit.config.json")" '["claude","codex"]'
t "add codex: AGENTS.md + skills arrive" "$(has_path c AGENTS.md)$(has_path c .agents/skills/concrete/SKILL.md)" "yesyes"
t "add codex: config did not move"       "$(has_path c cckit.config.json)" "no"
t "add codex: codex files recorded"      "$(unrecorded c .claude/kit.manifest.json codex)" ""
t "add codex: claude entries kept"       "$([ "$(jq '.entries | length' "$fx/c/.claude/kit.manifest.json")" -gt "$c_entries" ] && echo yes || echo no)" "yes"

settle x "settle before enabling claude"
x_before="$(tree_hash x .agents AGENTS.md)"
upgrade x --adapter claude || { echo "FAIL: enabling claude on a codex project exited non-zero"; fail=1; }
t "add claude: codex files byte-identical" "$(tree_hash x .agents AGENTS.md)" "$x_before"
t "add claude: selection is both"        "$(jq -c '.adapters' "$fx/x/cckit.config.json")" '["claude","codex"]'
t "add claude: CLAUDE.md + skills arrive" "$(has_path x CLAUDE.md)$(has_path x .claude/skills/concrete/SKILL.md)" "yesyes"
t "add claude: config stays at the root" "$(has_path x .claude/kit.config.json)" "no"
t "add claude: manifest stays in .cckit/" "$(has_path x .claude/kit.manifest.json)" "no"
t "add claude: claude files recorded"    "$(unrecorded x .cckit/kit.manifest.json claude)" ""

# 13. a project's own AGENTS.md is not replaced by a fresh Codex init
mkdir -p "$fx/own" && printf 'my own contract\n' > "$fx/own/AGENTS.md"
fresh own codex || { echo "FAIL: fresh codex init over an existing AGENTS.md exited non-zero"; fail=1; }
t "existing AGENTS.md kept"              "$(cat "$fx/own/AGENTS.md")" "my own contract"
t "kept AGENTS.md is not claimed as owned" "$(jq '.entries | has("AGENTS.md")' "$fx/own/.cckit/kit.manifest.json")" "false"

# 14. doctor reports each SELECTED runtime present / absent (stub binaries; no network)
mkdir -p "$fx/bin"
printf '#!/bin/sh\necho "codex-cli 9.9.9"\n' > "$fx/bin/codex"; chmod +x "$fx/bin/codex"
doc="$(cd "$fx/b" && PATH="$fx/bin:/usr/bin:/bin" KIT_ASCII=1 NO_COLOR=1 bash "$PLUGIN_DIR/scripts/kit-doctor.sh" --agents 2>&1)"; doc_rc=$?
t "doctor: absent runtime exits 1"       "$doc_rc" "1"
t "doctor: codex reported present"       "$(printf '%s\n' "$doc" | grep -c 'codex .*codex-cli 9.9.9')" "1"
t "doctor: claude reported absent"       "$(printf '%s\n' "$doc" | grep -c 'claude .*absent')" "1"
printf '#!/bin/sh\necho "9.9.9 (Claude Code)"\n' > "$fx/bin/claude"; chmod +x "$fx/bin/claude"
( cd "$fx/b" && PATH="$fx/bin:/usr/bin:/bin" KIT_ASCII=1 NO_COLOR=1 bash "$PLUGIN_DIR/scripts/kit-doctor.sh" --agents >/dev/null 2>&1 )
t "doctor: both present exits 0"         "$?" "0"
rm -f "$fx/bin/claude"
doc="$(cd "$fx/own" && PATH="$fx/bin:/usr/bin:/bin" KIT_ASCII=1 NO_COLOR=1 bash "$PLUGIN_DIR/scripts/kit-doctor.sh" --agents 2>&1)"; doc_rc=$?
t "doctor: unselected runtime not checked" "$doc_rc$(printf '%s\n' "$doc" | grep -c 'claude')" "00"

# --- E257.5: hooks and session mail on both adapters ------------------------------------
# shellcheck disable=SC2016
MAILCMD='bash "$CLAUDE_PROJECT_DIR/.claude/hooks/kit-mail-check.sh"'
CXMAIL='bash "$(git rev-parse --show-toplevel)/.codex/hooks/kit-mail-check.sh"'
mail_events() {  # mail_events <file> <command> -> the events that run <command>, sorted
  jq -r --arg c "$2" '[(.hooks // {}) | to_entries[] | select([.value[].hooks[].command] | index($c)) | .key] | sort | join(" ")' "$1" 2>/dev/null
}

# 15. the Claude adapter installs AND wires the mail hook (it shipped as a template only before)
fresh hc claude || { echo "FAIL: fresh claude init (hooks) exited non-zero"; fail=1; }
t "claude: mail hook installed"          "$([ -x "$fx/hc/.claude/hooks/kit-mail-check.sh" ] && echo yes || echo no)" "yes"
t "claude: mail wired on four events"    "$(mail_events "$fx/hc/.claude/settings.json" "$MAILCMD")" "PostToolUse SessionStart Stop UserPromptSubmit"
t "claude: mail hook recorded as owned"  "$(jq '.entries | has(".claude/hooks/kit-mail-check.sh")' "$fx/hc/.claude/kit.manifest.json")" "true"
t "claude: no .codex tree"               "$(has_path hc .codex)" "no"
settle hc "scaffold claude with mail"
# a user-tuned registration survives the upgrade, and nothing is registered twice
jq --arg c "$MAILCMD" '(.hooks.Stop[] | select(.hooks[0].command == $c) | .hooks[0].timeout) = 45' \
  "$fx/hc/.claude/settings.json" > "$fx/hc/s.tmp" && mv "$fx/hc/s.tmp" "$fx/hc/.claude/settings.json"
setver hc .claude/kit.config.json 0.0.1; settle hc "tune the Stop timeout"
upgrade hc || { echo "FAIL: claude upgrade (hooks) exited non-zero"; fail=1; }
t "claude upgrade: tuned timeout kept"   "$(jq --arg c "$MAILCMD" '[.hooks.Stop[].hooks[] | select(.command == $c) | .timeout] | join(",")' "$fx/hc/.claude/settings.json")" '"45"'
t "claude upgrade: one mail handler per event" "$(jq --arg c "$MAILCMD" '[.hooks[][].hooks[] | select(.command == $c)] | length' "$fx/hc/.claude/settings.json")" "4"
t "claude upgrade: only the config changed" "$(git -C "$fx/hc" status --porcelain | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')" ".claude/kit.config.json"

# 16. a Codex-only project gets the hook scripts and a hooks.json with no machine path
fresh hx codex || { echo "FAIL: fresh codex init (hooks) exited non-zero"; fail=1; }
t "codex: hook scripts installed"        "$(ls "$fx/hx/.codex/hooks" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" "guard-base-branch-commit.sh guard-raw-git-ops.sh kit-mail-check.sh kit_version_check.sh repo-hygiene.sh "
t "codex: hook scripts are executable"   "$(find "$fx/hx/.codex/hooks" -type f ! -perm -u+x | wc -l | tr -d ' ')" "0"
t "codex: mail on four events"           "$(mail_events "$fx/hx/.codex/hooks.json" "$CXMAIL")" "PostToolUse SessionStart Stop UserPromptSubmit"
t "codex: hooks carry no machine path"   "$(grep -rlF "$fx" "$fx/hx/.codex" 2>/dev/null | wc -l | tr -d ' ')" "0"
t "codex: no memory hook installed"      "$(ls "$fx/hx/.codex/hooks" | grep -c mempal)" "0"
t "codex: still no .claude tree"         "$(has_path hx .claude)" "no"
t "codex: hooks recorded as owned"       "$(jq -r '[.entries | keys[] | select(startswith(".codex/hooks"))] | length' "$fx/hx/.cckit/kit.manifest.json")" "6"
settle hx "scaffold codex with hooks"
hx_before="$(tree_hash hx .codex)"
setver hx cckit.config.json 0.0.1; settle hx "reset version"
upgrade hx || { echo "FAIL: codex upgrade (hooks) exited non-zero"; fail=1; }
t "codex upgrade: .codex byte-identical (hook trust kept)" "$(tree_hash hx .codex)" "$hx_before"
t "codex upgrade: only the config changed" "$(git -C "$fx/hx" status --porcelain | awk '{print $2}' | tr '\n' ' ' | sed 's/ $//')" "cckit.config.json"

# 17. a project that already keeps its own .codex/ — entries, a script, config.toml — keeps all of it
mkdir -p "$fx/hu/.codex/hooks"
cat > "$fx/hu/.codex/hooks.json" <<'JSON'
{ "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "python3 my_policy.py", "timeout": 30 } ] } ],
             "SubagentStop": [ { "hooks": [ { "type": "command", "command": "echo mine" } ] } ] } }
JSON
printf '#!/bin/sh\n# my own mail hook\n' > "$fx/hu/.codex/hooks/kit-mail-check.sh"
printf '[mcp_servers.mine]\ncommand = "npx"\n' > "$fx/hu/.codex/config.toml"
fresh hu codex || { echo "FAIL: fresh codex init over an existing .codex exited non-zero"; fail=1; }
t "merge: the user's guard entry is kept, first" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$fx/hu/.codex/hooks.json")" "python3 my_policy.py"
t "merge: the user's other event is kept"  "$(jq -r '.hooks.SubagentStop[0].hooks[0].command' "$fx/hu/.codex/hooks.json")" "echo mine"
t "merge: cckit's guards were added"       "$(jq '.hooks.PreToolUse | length' "$fx/hu/.codex/hooks.json")" "3"
t "merge: cckit's mail was added"          "$(mail_events "$fx/hu/.codex/hooks.json" "$CXMAIL")" "PostToolUse SessionStart Stop UserPromptSubmit"
t "merge: no machine path"                 "$(grep -cF "$fx" "$fx/hu/.codex/hooks.json")" "0"
t "merge: the user's hooks.json is not claimed as owned" "$(jq '.entries | has(".codex/hooks.json")' "$fx/hu/.cckit/kit.manifest.json")" "false"
t "merge: the user's own hook script is kept" "$(sed -n 2p "$fx/hu/.codex/hooks/kit-mail-check.sh")" "# my own mail hook"
t "merge: the kept script is not claimed"  "$(jq '.entries | has(".codex/hooks/kit-mail-check.sh")' "$fx/hu/.cckit/kit.manifest.json")" "false"
t "merge: config.toml untouched"           "$(cat "$fx/hu/.codex/config.toml")" "$(printf '[mcp_servers.mine]\ncommand = "npx"')"
settle hu "scaffold over my own .codex"
hu_before="$(tree_hash hu .codex)"
setver hu cckit.config.json 0.0.1; settle hu "reset version"
upgrade hu || { echo "FAIL: upgrade over a user-edited hooks.json exited non-zero"; fail=1; }
t "merge: upgrade leaves .codex byte-identical" "$(tree_hash hu .codex)" "$hu_before"

# 18. an unparseable hooks.json is left alone, reported, and repairable at the same version
mkdir -p "$fx/hb/.codex" && printf '{ not json\n' > "$fx/hb/.codex/hooks.json"
fresh hb codex; t "bad hooks.json: init still completes (rc)" "$?" "0"
t "bad hooks.json: file untouched"         "$(cat "$fx/hb/.codex/hooks.json")" "{ not json"
doc="$(cd "$fx/hb" && PATH="$fx/bin:$PATH" KIT_ASCII=1 NO_COLOR=1 bash "$PLUGIN_DIR/scripts/kit-doctor.sh" --agents 2>&1)"
t "doctor: unregistered codex hooks reported" "$(printf '%s\n' "$doc" | grep -c 'codex hooks .*not registered')" "1"
printf '{}\n' > "$fx/hb/.codex/hooks.json"; settle hb "fix hooks.json"
upgrade hb; t "repair: same-version upgrade runs (rc)" "$?" "0"
t "repair: hooks now registered"           "$(mail_events "$fx/hb/.codex/hooks.json" "$CXMAIL")" "PostToolUse SessionStart Stop UserPromptSubmit"
doc="$(cd "$fx/hb" && PATH="$fx/bin:$PATH" KIT_ASCII=1 NO_COLOR=1 bash "$PLUGIN_DIR/scripts/kit-doctor.sh" --agents 2>&1)"
t "doctor: registered codex hooks reported" "$(printf '%s\n' "$doc" | grep -c 'codex hooks .*registered in .codex/hooks.json')" "1"
t "doctor: says trust is not readable"     "$(printf '%s\n' "$doc" | grep -c 'trust is not readable')" "1"

# 19. enabling Codex on a Claude project adds the Codex hooks and leaves the Claude ones alone
settle hc "settle before enabling codex"
hc_before="$(tree_hash hc .claude/hooks .claude/settings.json .claude/settings.local.json)"
upgrade hc --adapter codex || { echo "FAIL: enabling codex (hooks) exited non-zero"; fail=1; }
t "add codex: claude hooks byte-identical" "$(tree_hash hc .claude/hooks .claude/settings.json .claude/settings.local.json)" "$hc_before"
t "add codex: codex hooks registered"    "$(mail_events "$fx/hc/.codex/hooks.json" "$CXMAIL")" "PostToolUse SessionStart Stop UserPromptSubmit"
t "add codex: one mail script, same bytes" "$(cmp -s "$fx/hc/.claude/hooks/kit-mail-check.sh" "$fx/hc/.codex/hooks/kit-mail-check.sh" && echo same || echo differs)" "same"

# --- E257.6: one role source, one agent definition per runtime ---------------------------
# `x` is the Codex-only project and `b` selects both, each on the minimal profile (pm, generalist).
toml_get() {  # toml_get <file> <key> -> the value of a single-line `key = "…"` entry, unescaped
  sed -n "s/^$2 = \"\(.*\)\"\$/\1/p" "$1" | sed 's/\\"/"/g; s/\\\\/\\/g'
}
# 20. Codex gets one agent definition per role, and a Claude-only project gets none
t "codex: one agent per profile role"    "$(ls "$fx/x/.codex/agents" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" "generalist.toml pm.toml "
t "both: same roles on both runtimes"    "$(ls "$fx/b/.claude/agents" | LC_ALL=C sort | tr '\n' ' ')|$(ls "$fx/b/.codex/agents" | sed 's/\.toml$//' | LC_ALL=C sort | tr '\n' ' ')" "generalist pm |generalist pm "
fresh ac claude || { echo "FAIL: fresh claude init (agents) exited non-zero"; fail=1; }
t "claude: no .codex/agents"             "$(has_path ac .codex)$(has_path ac .claude/agents/pm/AGENT.md)" "noyes"
t "codex: agent has the three required keys" "$(grep -cE '^(name|description|developer_instructions) = ' "$fx/x/.codex/agents/pm.toml")" "3"
# 21. the two definitions are the same role: description and body come from one template
b_desc="$(sed -n 's/^description: //p' "$fx/b/.claude/agents/generalist/AGENT.md") $(sed -n 's/^when_to_use: //p' "$fx/b/.claude/agents/generalist/AGENT.md")"
t "same role: description + when_to_use"      "$(toml_get "$fx/b/.codex/agents/generalist.toml" description)" "$b_desc"
b_body="$(awk 'c>=2{print} /^---$/{c++}' "$fx/b/.claude/agents/generalist/AGENT.md" | sed '/./,$!d')"
x_body="$(awk '/^developer_instructions = """$/{on=1;next} /^"""$/{on=0} on' "$fx/b/.codex/agents/generalist.toml" | sed 's/\\"/"/g; s/\\\\/\\/g')"
t "same role: instructions are the role body" "$x_body" "$b_body"
t "codex: Claude tool allowlist is not a key" "$(grep -cE '^tools' "$fx/x/.codex/agents/pm.toml")" "0"
t "codex: untranslated allowlist is stated" "$(grep -c '^# Not translated — Claude Code tool allowlist' "$fx/x/.codex/agents/pm.toml")" "1"
t "codex: pm names the skills that exist" "$(grep -cE '^- kit-task-(sync|new|close)$' "$fx/x/.codex/agents/pm.toml")" "3"
if command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' 2>/dev/null; then
  t "codex: every agent file parses as TOML" "$(python3 -c '
import sys, tomllib
for f in sys.argv[1:]:
    d = tomllib.load(open(f, "rb"))
    assert d["name"] and d["description"] and d["developer_instructions"], f
print("ok")' "$fx"/x/.codex/agents/*.toml "$fx"/b/.codex/agents/*.toml 2>&1)" "ok"
fi
# 22. nothing Claude-specific or machine-specific leaks into a Codex-only project's agents
t "codex agents: no .claude path"        "$(grep -rl '\.claude/' "$fx/x/.codex/agents" 2>/dev/null | wc -l | tr -d ' ')" "0"
t "codex agents: no machine path"        "$(grep -rlF "$fx" "$fx/x/.codex/agents" "$fx/b/.codex/agents" 2>/dev/null | wc -l | tr -d ' ')" "0"
t "codex agents: no unrendered placeholder" "$(grep -rlE '\{\{[A-Z_]+\}\}|IF:ADAPTER' "$fx/x/.codex/agents" 2>/dev/null | wc -l | tr -d ' ')" "0"
t "codex: AGENTS.md lists the roles"     "$(grep -cE '^\| `(pm|generalist)` \|' "$fx/x/AGENTS.md")" "2"
t "codex agents: recorded as owned"      "$(jq -r '[.entries | keys[] | select(startswith(".codex/agents/"))] | length' "$fx/x/.cckit/kit.manifest.json")" "2"
# 23. a hand-edited agent survives an upgrade; a deleted one is restored; the user's own is kept
A_MARKER="# LOCAL-AGENT-EDIT (must survive upgrade)"
printf '%s\n' "$A_MARKER" >> "$fx/x/.codex/agents/pm.toml"
rm -f "$fx/x/.codex/agents/generalist.toml"
setver x cckit.config.json 0.0.4; settle x "edit one agent, drop another"
upgrade x || { echo "FAIL: codex upgrade (agents) exited non-zero"; fail=1; }
t "upgrade: hand-edited agent kept"      "$(grep -cF "$A_MARKER" "$fx/x/.codex/agents/pm.toml")" "1"
t "upgrade: missing agent restored"      "$(has_path x .codex/agents/generalist.toml)" "yes"
mkdir -p "$fx/au/.codex/agents" && printf 'name = "pm"\n# mine\n' > "$fx/au/.codex/agents/pm.toml"
fresh au codex || { echo "FAIL: fresh codex init over an existing agent exited non-zero"; fail=1; }
t "own agent: the user's file is kept"   "$(sed -n 2p "$fx/au/.codex/agents/pm.toml")" "# mine"
t "own agent: not claimed as owned"      "$(jq '.entries | has(".codex/agents/pm.toml")' "$fx/au/.cckit/kit.manifest.json")" "false"
t "own agent: the other role still arrives" "$(has_path au .codex/agents/generalist.toml)" "yes"
# 24. enabling Codex on a Claude project adds its agents without touching the Claude ones
t "add codex: agents arrive"             "$(ls "$fx/hc/.codex/agents" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" "generalist.toml pm.toml "

echo ""
[ "$fail" -eq 0 ] && echo "PASS: init.sh --upgrade honors the preserve/exclude contract (#334, #149), adapter selection (E257.3), hook registration (E257.5) and per-runtime agents (E257.6)" || echo "FAILED"
exit "$fail"
