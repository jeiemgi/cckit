#!/usr/bin/env bash
# kit-wire-test.sh — self-test for kit-wire (#369). Runs under bash AND zsh.
# Run:  bash scripts/kit-wire-test.sh
PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${KIT_WIRE_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_WIRE_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_WIRE_TEST_INNER): $1"; fi; }

  proj="$(mktemp -d)"; trap 'rm -rf "$proj"' EXIT
  cd "$proj"
  export CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR"   # so the shim + plugin-root resolve to our statusline
  export KIT_ASSUME_YES=1

  . "$PLUGIN_DIR/scripts/kit-wire.sh"

  # converge
  kit_wire >/dev/null 2>&1
  t "shim created"        "$([ -f .claude/statusline.sh ] && echo yes || echo no)" "yes"
  t "shim is a shim"      "$(grep -c 'claude-kit statusline shim' .claude/statusline.sh)" "1"
  t "settings wired"      "$(jq -r '.statusLine.command' .claude/settings.json 2>/dev/null)" '$CLAUDE_PROJECT_DIR/.claude/statusline.sh'
  t "shim tracked"        "$(. "$PLUGIN_DIR/scripts/lib/kit-manifest.sh"; kit_manifest_verify .claude/statusline.sh)" "intact"
  t "settings tracked"    "$(. "$PLUGIN_DIR/scripts/lib/kit-manifest.sh"; kit_manifest_verify .claude/settings.json)" "intact"

  # idempotent: second converge changes nothing, shim still intact
  kit_wire >/dev/null 2>&1
  t "idempotent shim"     "$(. "$PLUGIN_DIR/scripts/lib/kit-manifest.sh"; kit_manifest_verify .claude/statusline.sh)" "intact"

  # --check is clean after converge (rc 0)
  if kit_wire_check >/dev/null 2>&1; then t "check clean rc" "0" "0"; else t "check clean rc" "$?" "0"; fi

  # hook executability: drop a non-exec hook, converge, assert it became executable
  mkdir -p .claude/hooks; printf '#!/usr/bin/env bash\n:\n' > .claude/hooks/demo.sh; chmod -x .claude/hooks/demo.sh
  kit_wire >/dev/null 2>&1
  t "hook chmod +x"       "$([ -x .claude/hooks/demo.sh ] && echo yes || echo no)" "yes"

  # drift detection: user removes the shim -> --check reports drift (rc 1)
  rm -f .claude/statusline.sh
  if kit_wire_check >/dev/null 2>&1; then t "check detects drift" "0" "1"; else t "check detects drift" "1" "1"; fi

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_WIRE_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_WIRE_TEST_INNER="$sh" PATH="$PATH" PLUGIN_DIR="$PLUGIN_DIR" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
