#!/usr/bin/env bash
# kit-promote-test.sh — self-test for kit-promote (#374). Runs under bash AND zsh.
# Run:  bash scripts/kit-promote-test.sh
PLUGIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if [ -n "${KIT_PROMOTE_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_PROMOTE_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_PROMOTE_TEST_INNER): $1"; fi; }

  ws="$(mktemp -d)"; trap 'rm -rf "$ws"' EXIT
  printf '{"workspace":{"name":"w"}}\n' > "$ws/kit.workspace.json"
  mkdir -p "$ws/proj-a/.claude/skills/brand" "$ws/proj-b/.claude/skills/brand" "$ws/proj-a/.claude/skills/solo"
  printf 'SHARED VOICE\n' > "$ws/proj-a/.claude/skills/brand/SKILL.md"
  printf 'SHARED VOICE\n' > "$ws/proj-b/.claude/skills/brand/SKILL.md"   # identical -> dup candidate
  printf 'only here\n'    > "$ws/proj-a/.claude/skills/solo/SKILL.md"

  . "$PLUGIN_DIR/scripts/kit-promote.sh"
  . "$PLUGIN_DIR/scripts/lib/kit-manifest.sh"

  # workspace root detection from inside a project
  t "ws root from project" "$(cd "$ws/proj-a" && kit_workspace_root | sed "s#$ws#WS#")" "WS"
  t "ws root from nested"  "$(cd "$ws/proj-a/.claude/skills" && kit_workspace_root | sed "s#$ws#WS#")" "WS"

  # promote brand/SKILL.md from proj-a up to the commons (assume-yes skips the above-project prompt)
  ( cd "$ws/proj-a" && export KIT_ASSUME_YES=1 && kit_promote "skills/brand/SKILL.md" >/dev/null 2>&1 )
  t "copied to commons"    "$([ -f "$ws/.claude/skills/brand/SKILL.md" ] && echo yes || echo no)" "yes"
  t "commons content"      "$(cat "$ws/.claude/skills/brand/SKILL.md")" "SHARED VOICE"
  t "commons manifest"     "$(cd "$ws" && KIT_MANIFEST=.claude/kit.manifest.json kit_manifest_verify .claude/skills/brand/SKILL.md)" "intact"
  t "project mirror tracked" "$(cd "$ws/proj-a" && kit_manifest_verify .claude/skills/brand/SKILL.md)" "intact"

  # dup detection across the two projects: brand/SKILL.md is identical -> candidate; solo is not
  cands="$(kit_promote_candidates "$ws/proj-a" "$ws/proj-b" 2>/dev/null)"
  t "candidate found"      "$(printf '%s' "$cands" | grep -c 'skills/brand/SKILL.md')" "1"
  t "no false candidate"   "$(printf '%s' "$cands" | grep -c 'skills/solo/SKILL.md')" "0"

  # dry-run promote writes nothing new
  mkdir -p "$ws/proj-b/.claude/skills/new"; printf 'x\n' > "$ws/proj-b/.claude/skills/new/SKILL.md"
  ( cd "$ws/proj-b" && KIT_DRY_RUN=1 kit_promote "skills/new/SKILL.md" >/dev/null 2>&1 )
  t "dry-run no commons write" "$([ -f "$ws/.claude/skills/new/SKILL.md" ] && echo yes || echo no)" "no"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_PROMOTE_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_PROMOTE_TEST_INNER="$sh" PATH="$PATH" PLUGIN_DIR="$PLUGIN_DIR" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
