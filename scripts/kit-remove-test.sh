#!/usr/bin/env bash
# kit-remove-test.sh — self-test for kit-remove (#373). Runs under bash AND zsh.
# Run:  bash scripts/kit-remove-test.sh
PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${KIT_REMOVE_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_REMOVE_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_REMOVE_TEST_INNER): $1"; fi; }

  proj="$(mktemp -d)"; trap 'rm -rf "$proj"' EXIT
  cd "$proj"
  export KIT_ASSUME_YES=1
  . "$PLUGIN_DIR/scripts/kit-remove.sh"
  . "$PLUGIN_DIR/scripts/lib/kit-manifest.sh"

  # set up a project the kit "installed": two tracked files + one user-modified + one untracked
  mkdir -p .claude/hooks knowledge
  printf 'a\n' > .claude/statusline.sh;        kit_manifest_record .claude/statusline.sh B wire 1 2026-01-01T00:00:00Z
  printf 'b\n' > .claude/hooks/guard.sh;        kit_manifest_record .claude/hooks/guard.sh B wire 1 2026-01-01T00:00:00Z
  printf 'c\n' > .claude/settings.json;         kit_manifest_record .claude/settings.json B wire 1 2026-01-01T00:00:00Z
  printf 'USER EDITED\n' > .claude/settings.json   # now modified vs manifest
  printf 'my notes\n' > knowledge/doc.md        # NOT tracked — must survive

  t "before: statusline tracked" "$(kit_manifest_verify .claude/statusline.sh)" "intact"
  t "before: settings modified"  "$(kit_manifest_verify .claude/settings.json)" "modified"

  # remove with --yes: intact files deleted, modified kept (assume-yes still declines modified),
  # untracked knowledge/ untouched.
  printf 'n\n' | kit_remove_all >/dev/null 2>&1   # answer 'n' to the modified-file prompt

  t "intact deleted (statusline)" "$([ -f .claude/statusline.sh ] && echo yes || echo no)" "no"
  t "intact deleted (guard)"      "$([ -f .claude/hooks/guard.sh ] && echo yes || echo no)" "no"
  t "modified KEPT (settings)"    "$([ -f .claude/settings.json ] && echo yes || echo no)" "yes"
  t "modified content intact"     "$(cat .claude/settings.json)" "USER EDITED"
  t "untracked knowledge SAFE"    "$([ -f knowledge/doc.md ] && echo yes || echo no)" "yes"
  # manifest kept because one modified entry remained
  t "manifest remains"            "$([ -f .claude/kit.manifest.json ] && echo yes || echo no)" "yes"
  t "only modified entry left"    "$(kit_manifest_list | tr '\n' ',')" ".claude/settings.json,"

  # dry-run never deletes
  proj2="$(mktemp -d)"; cd "$proj2"
  printf 'x\n' > .claude/f.sh 2>/dev/null || { mkdir -p .claude; printf 'x\n' > .claude/f.sh; }
  kit_manifest_record .claude/f.sh B wire 1 2026-01-01T00:00:00Z
  KIT_DRY_RUN=1 kit_remove_all >/dev/null 2>&1
  t "dry-run keeps file"          "$([ -f .claude/f.sh ] && echo yes || echo no)" "yes"
  t "dry-run keeps manifest"      "$([ -f .claude/kit.manifest.json ] && echo yes || echo no)" "yes"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_REMOVE_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_REMOVE_TEST_INNER="$sh" PATH="$PATH" PLUGIN_DIR="$PLUGIN_DIR" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
