#!/usr/bin/env bash
# kit-export-project-test.sh — self-test for kit-export-project (#376). Runs under bash AND zsh.
# Run:  bash scripts/kit-export-project-test.sh
PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${KIT_EXPORT_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_EXPORT_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_EXPORT_TEST_INNER): $1"; fi; }

  proj="$(mktemp -d)"; trap 'rm -rf "$proj"' EXIT
  cd "$proj"
  . "$PLUGIN_DIR/scripts/kit-export-project.sh"
  . "$PLUGIN_DIR/scripts/lib/kit-manifest.sh"

  # A kit project: CLAUDE.md importing a tier-A rule + a tier-B hook; a knowledge corpus.
  mkdir -p .claude/rules .claude/hooks .claude/agents knowledge
  printf '# My Project\n\nRules:\n@.claude/rules/branch-naming.md\n\nHooks:\n@.claude/hooks/guard.sh\n' > CLAUDE.md
  printf 'BRANCH RULE BODY\n'  > .claude/rules/branch-naming.md
  printf '#!/bin/sh\nguard\n'  > .claude/hooks/guard.sh
  printf 'AGENT BODY\n'        > .claude/agents/pm.md
  printf 'KNOWLEDGE DOC\n'     > knowledge/doc.md

  # Tier classification: rule = A, hook = B (heuristic, no manifest yet).
  t "rule is tier A"  "$(kit_export_tier .claude/rules/branch-naming.md)" "A"
  t "hook is tier B"  "$(kit_export_tier .claude/hooks/guard.sh)" "B"

  # --verify: a tier-B import that CLAUDE.md requires is a portability defect -> rc 1.
  kit_export_verify CLAUDE.md >/dev/null 2>&1
  t "verify flags tier-B require (rc 1)" "$?" "1"

  # Flattened instructions: inline the tier-A rule body, SKIP the tier-B hook (note it).
  flat="$(kit_export_flatten_instructions CLAUDE.md)"
  t "inlines tier-A rule body"     "$(printf '%s' "$flat" | grep -c 'BRANCH RULE BODY')" "1"
  t "marks tier-A inline"          "$(printf '%s' "$flat" | grep -c 'tier A')" "1"
  t "skips tier-B hook body"       "$(printf '%s' "$flat" | grep -c 'guard$')" "0"
  t "notes tier-B skip"            "$(printf '%s' "$flat" | grep -c 'tier B')" "1"
  t "keeps non-import prose"       "$(printf '%s' "$flat" | grep -c 'My Project')" "1"

  # dry-run writes nothing.
  KIT_DRY_RUN=1 kit_export_all .kit-export knowledge >/dev/null 2>&1
  t "dry-run writes no out dir" "$([ -d .kit-export ] && echo yes || echo no)" "no"

  # real export: instructions + knowledge copy + matrix all present; knowledge content carried.
  kit_export_all .kit-export knowledge >/dev/null 2>&1
  t "instructions written"  "$([ -f .kit-export/claude-instructions.md ] && echo yes || echo no)" "yes"
  t "matrix written"        "$([ -f .kit-export/SUPPORT-MATRIX.md ] && echo yes || echo no)" "yes"
  t "knowledge copied"      "$([ -f .kit-export/project-knowledge/knowledge/doc.md ] && echo yes || echo no)" "yes"
  t "tier-A agents copied"  "$([ -f .kit-export/project-knowledge/agents/pm.md ] && echo yes || echo no)" "yes"
  t "tier-B hook NOT in instructions" "$(grep -c 'guard$' .kit-export/claude-instructions.md)" "0"

  # matrix has the three surfaces.
  m="$(kit_export_matrix)"
  t "matrix names claude.ai"  "$(printf '%s' "$m" | grep -qi 'claude.ai' && echo yes || echo no)" "yes"
  t "matrix names Cowork"     "$(printf '%s' "$m" | grep -qi 'Cowork'    && echo yes || echo no)" "yes"
  t "matrix names Terminal"   "$(printf '%s' "$m" | grep -qi 'Terminal'  && echo yes || echo no)" "yes"

  # Now make the hook tier-A via the manifest: --verify should pass (portable).
  kit_manifest_record .claude/rules/branch-naming.md A wire >/dev/null 2>&1
  kit_manifest_record .claude/hooks/guard.sh A wire >/dev/null 2>&1   # force A to simulate a portable file
  t "manifest tier wins over heuristic" "$(kit_export_tier .claude/hooks/guard.sh)" "A"
  kit_export_verify CLAUDE.md >/dev/null 2>&1
  t "verify passes when all imports tier-A (rc 0)" "$?" "0"

  # A missing import is a defect on every surface.
  printf '\n@.claude/rules/gone.md\n' >> CLAUDE.md
  kit_export_verify CLAUDE.md >/dev/null 2>&1
  t "verify flags a missing import (rc 1)" "$?" "1"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_EXPORT_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_EXPORT_TEST_INNER="$sh" PATH="$PATH" PLUGIN_DIR="$PLUGIN_DIR" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
