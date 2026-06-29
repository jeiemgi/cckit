#!/usr/bin/env bash
# kit-mode-test.sh — self-test for kit-mode (#371). Runs under bash AND zsh.
# Run:  bash scripts/lib/kit-mode-test.sh
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KIT_MODE_TEST_INNER:-}" ]; then
  set -u
  . "$dir/kit-mode.sh"
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_MODE_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_MODE_TEST_INNER): $1"; fi; }

  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/ws/proj/island"
  printf '{"mode":"guided"}\n'   > "$work/ws/kit.workspace.json"
  printf '{"mode":"enforced"}\n' > "$work/ws/proj/kit.config.json"
  printf '{"mode":"draft"}\n'    > "$work/ws/proj/island/kit.config.json"
  mkdir -p "$work/bare"   # no config anywhere

  unset KIT_MODE 2>/dev/null || true
  t "mode workspace"   "$(kit_mode "$work/ws")"             "guided"
  t "mode project"     "$(kit_mode "$work/ws/proj")"        "enforced"
  t "mode island"      "$(kit_mode "$work/ws/proj/island")" "draft"
  t "mode default"     "$(kit_mode "$work/bare")"           "guided"

  t "gate enforced"    "$(kit_gate "$work/ws/proj")"        "block"
  t "gate guided"      "$(kit_gate "$work/ws")"             "warn"
  t "gate draft"       "$(kit_gate "$work/ws/proj/island")" "off"

  # KIT_MODE env overrides the cascade
  t "env override"     "$(KIT_MODE=enforced kit_mode "$work/bare")" "enforced"

  # kit_gate_apply exit codes: enforced -> rc 2 (blocks), guided -> rc 0, draft -> rc 0
  kit_gate_apply "x" "$work/ws/proj"        >/dev/null 2>&1; t "apply enforced rc" "$?" "2"
  kit_gate_apply "x" "$work/ws"             >/dev/null 2>&1; t "apply guided rc"   "$?" "0"
  kit_gate_apply "x" "$work/ws/proj/island" >/dev/null 2>&1; t "apply draft rc"    "$?" "0"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_MODE_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_MODE_TEST_INNER="$sh" PATH="$PATH" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
