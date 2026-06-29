#!/usr/bin/env bash
# kit-migrate-test.sh — self-test for kit-migrate (#373). Runs under bash AND zsh.
# Asserts the acceptance gate: migrate twice = no-op; old paths registered (survives /kit-update);
# manifest re-keyed; docs rewritten; .claude/ backed up.
# Run:  bash scripts/kit-migrate-test.sh
PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${KIT_MIGRATE_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_MIGRATE_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_MIGRATE_TEST_INNER): $1"; fi; }

  proj="$(mktemp -d)"; trap 'rm -rf "$proj"' EXIT
  cd "$proj"
  export KIT_ASSUME_YES=1
  . "$PLUGIN_DIR/scripts/kit-migrate.sh"
  . "$PLUGIN_DIR/scripts/lib/kit-manifest.sh"

  # Old-layout project: task-* skills, a CLAUDE.md referencing /task-pr, a manifest tracking the old
  # skill path, a kit.config.json with no upgrade map yet.
  mkdir -p .claude/skills/task-pr .claude/skills/task-gc .claude/rules
  printf 'pr skill body\n' > .claude/skills/task-pr/SKILL.md
  printf 'gc skill body\n' > .claude/skills/task-gc/SKILL.md
  printf 'Run /task-pr then /task-pr-merge; sweep with /task-gc.\n' > CLAUDE.md
  printf '{ "schema":1 }\n' > .claude/kit.config.json
  kit_manifest_record .claude/skills/task-pr/SKILL.md A wire 1 2026-01-01T00:00:00Z

  # --- run 1: the real migration ---
  kit_migrate_all >/dev/null 2>&1

  t "old task-pr gone"          "$([ -e .claude/skills/task-pr ] && echo yes || echo no)" "no"
  t "new kit-task-pr present"   "$([ -f .claude/skills/kit-task-pr/SKILL.md ] && echo yes || echo no)" "yes"
  t "content preserved"         "$(cat .claude/skills/kit-task-pr/SKILL.md)" "pr skill body"
  t "task-gc -> kit-gc"         "$([ -f .claude/skills/kit-gc/SKILL.md ] && echo yes || echo no)" "yes"
  t "backup taken"              "$(find . -maxdepth 1 -name ".claude.bak.*" 2>/dev/null | grep -c .)" "1"

  # resurrection guard: old path registered in upgrade.renamed{} -> /kit-update skips it.
  t "rename registered"         "$(jq -r '.upgrade.renamed[".claude/skills/task-pr"] // "MISS"' .claude/kit.config.json)" ".claude/skills/kit-task-pr"
  t "gc rename registered"      "$(jq -r '.upgrade.renamed[".claude/skills/task-gc"] // "MISS"' .claude/kit.config.json)" ".claude/skills/kit-gc"

  # manifest re-keyed to the v2 path.
  t "manifest re-keyed"         "$(kit_manifest_verify .claude/skills/kit-task-pr/SKILL.md)" "intact"
  t "old manifest entry dropped" "$(kit_manifest_verify .claude/skills/task-pr/SKILL.md)" "untracked"

  # CLAUDE.md surgery: /task-pr -> /kit-task-pr (no bare /task- left).
  t "doc rewritten kit-task-pr" "$(grep -c '/kit-task-pr' CLAUDE.md)" "1"
  t "doc rewritten kit-gc"      "$(grep -c '/kit-gc' CLAUDE.md)" "1"
  t "no bare /task- left"       "$(grep -Ec '/task-(pr|gc|new)' CLAUDE.md)" "0"

  # --- run 2: idempotency — migrate twice = no-op (nothing moves, no second backup) ---
  out2="$(kit_migrate_all 2>&1)"
  t "2nd run is no-op"          "$(printf '%s' "$out2" | grep -c 'already on v2')" "1"
  t "still ONE backup"          "$(find . -maxdepth 1 -name ".claude.bak.*" 2>/dev/null | grep -c .)" "1"
  t "kit-task-pr still there"   "$([ -f .claude/skills/kit-task-pr/SKILL.md ] && echo yes || echo no)" "yes"
  t "old still absent"          "$([ -e .claude/skills/task-pr ] && echo yes || echo no)" "no"

  # --- dry-run on a fresh old project moves nothing ---
  proj2="$(mktemp -d)"; cd "$proj2"
  mkdir -p .claude/skills/task-pr
  printf 'x\n' > .claude/skills/task-pr/SKILL.md
  printf '{ "schema":1 }\n' > .claude/kit.config.json
  KIT_DRY_RUN=1 kit_migrate_all >/dev/null 2>&1
  t "dry-run does not move"     "$([ -e .claude/skills/task-pr ] && echo yes || echo no)" "yes"
  t "dry-run no new dir"        "$([ -e .claude/skills/kit-task-pr ] && echo yes || echo no)" "no"
  t "dry-run no backup"         "$(find . -maxdepth 1 -name ".claude.bak.*" 2>/dev/null | grep -c .)" "0"
  t "dry-run no registry write" "$(jq -r '.upgrade // "NONE"' .claude/kit.config.json)" "NONE"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_MIGRATE_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_MIGRATE_TEST_INNER="$sh" PATH="$PATH" PLUGIN_DIR="$PLUGIN_DIR" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
