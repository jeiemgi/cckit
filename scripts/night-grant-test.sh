#!/usr/bin/env bash
# night-grant-test.sh — the night grant parser, picker and allowlist preflight, offline.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "night-grant-test: jq required — skipping"; exit 0; }
bash "$ROOT/scripts/night-grant.sh" --selftest || exit 1

# ── the docs contract: night mode is launchable and documented outside this checkout ──────────
fails=0
t() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}
SKILL="$ROOT/skills/kit-autopilot/SKILL.md"
# A consuming project has no scripts/ checkout: every night script path in the skill must start at
# the plugin root, as every other plugin-direct skill's paths do.
# shellcheck disable=SC2016
bare="$(grep -oE '.{0,22}scripts/night-(grant\.sh|run\.mjs)' "$SKILL" \
  | grep -vcF '${CLAUDE_PLUGIN_ROOT}/scripts/night-')"
t "skill: no night script path without the plugin root" 0 "$bare"
# shellcheck disable=SC2016
t "skill: it names the grant reader under the plugin root" 1 \
  "$(grep -cF 'bash "${CLAUDE_PLUGIN_ROOT}/scripts/night-grant.sh" read' "$SKILL")"
t "skill: it documents the WIP-limit interaction" yes \
  "$(grep -q 'effort.wipLimit' "$SKILL" && grep -q -- '--force' "$SKILL" && echo yes || echo no)"
t "skill: it does not demand an approval marker nothing writes" 0 \
  "$(grep -ciE 'grill|## Assumed' "$SKILL")"
t "schema: night declares its five keys" '["floors","gate","grantors","neverWaivable","refuseLabels"]' \
  "$(jq -c '.properties.night.properties | keys' "$ROOT/kit.config.schema.json" 2>/dev/null)"
for doc in README.md AGENTS.md docs-site/src/content/docs/config-and-permissions.mdx \
  docs-site/src/content/docs/skills.mdx docs-site/src/content/docs/tutorials/run-claude-code-unattended.mdx; do
  t "docs: $doc covers night mode" yes "$(grep -qi 'night mode' "$ROOT/$doc" && echo yes || echo no)"
done
t "docs: the config page documents who may grant" yes \
  "$(grep -q 'night.grantors' "$ROOT/docs-site/src/content/docs/config-and-permissions.mdx" && echo yes || echo no)"
[ "$fails" -eq 0 ] || { printf 'night-grant docs contract FAILED (%s)\n' "$fails"; exit 1; }
printf 'night-grant docs contract OK\n'
