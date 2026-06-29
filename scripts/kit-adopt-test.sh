#!/usr/bin/env bash
# kit-adopt-test.sh — self-test for kit-adopt (#373). Runs under bash AND zsh.
# Run:  bash scripts/kit-adopt-test.sh
PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${KIT_ADOPT_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_ADOPT_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_ADOPT_TEST_INNER): $1"; fi; }

  proj="$(mktemp -d)"; trap 'rm -rf "$proj"' EXIT
  cd "$proj"
  . "$PLUGIN_DIR/scripts/kit-adopt.sh"
  . "$PLUGIN_DIR/scripts/lib/kit-manifest.sh"

  # A project that imported kit files by hand: skills + a rule + statusline (unmanaged) + user content.
  mkdir -p .claude/skills/kit-task-pr .claude/rules knowledge
  printf 'pr skill\n'   > .claude/skills/kit-task-pr/SKILL.md
  printf 'a rule\n'     > .claude/rules/branch-naming.md
  printf '#!/bin/sh\n'  > .claude/statusline.sh
  printf 'my notes\n'   > knowledge/doc.md     # user content — must NEVER be a candidate

  # --check: 3 kit-shaped files unmanaged -> rc 1, knowledge/ excluded.
  out="$(kit_adopt_check 2>&1)"; rc=$?
  t "check rc=1 when unmanaged exist" "$rc" "1"
  t "check counts the 3 kit files"    "$(printf '%s' "$out" | grep -c '?')" "3"
  t "check never lists knowledge/"    "$(printf '%s' "$out" | grep -c 'knowledge/')" "0"

  # dry-run records nothing.
  KIT_DRY_RUN=1 kit_adopt_all >/dev/null 2>&1
  t "dry-run writes no manifest" "$([ -f .claude/kit.manifest.json ] && echo yes || echo no)" "no"

  # real adopt (assume-yes): all 3 recorded, knowledge untouched.
  KIT_ASSUME_YES=1 kit_adopt_all >/dev/null 2>&1
  t "skill now tracked"     "$(kit_manifest_verify .claude/skills/kit-task-pr/SKILL.md)" "intact"
  t "rule now tracked"      "$(kit_manifest_verify .claude/rules/branch-naming.md)" "intact"
  t "statusline now tracked" "$(kit_manifest_verify .claude/statusline.sh)" "intact"
  t "statusline tier=B"     "$(kit_manifest_get .claude/statusline.sh | jq -r .tier)" "B"
  t "skill tier=A"          "$(kit_manifest_get .claude/skills/kit-task-pr/SKILL.md | jq -r .tier)" "A"
  t "op=adopt"              "$(kit_manifest_get .claude/rules/branch-naming.md | jq -r .op)" "adopt"
  t "knowledge NOT tracked" "$(kit_manifest_verify knowledge/doc.md)" "untracked"

  # idempotent: a second adopt finds nothing new; --check is clean (rc 0).
  out2="$(KIT_ASSUME_YES=1 kit_adopt_all 2>&1)"
  t "2nd adopt no-op"  "$(printf '%s' "$out2" | grep -c 'nothing to adopt')" "1"
  kit_adopt_check >/dev/null 2>&1
  t "check clean after adopt rc=0" "$?" "0"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_ADOPT_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_ADOPT_TEST_INNER="$sh" PATH="$PATH" PLUGIN_DIR="$PLUGIN_DIR" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
