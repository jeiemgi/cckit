#!/usr/bin/env bash
# kit-engine-test.sh — self-test for the kit engine core (manifest + resolver + operate), #368.
# Libs are sourced into whatever shell the session runs (zsh on macOS), so they must behave
# identically under bash AND zsh. Run:  bash scripts/lib/kit-engine-test.sh
# Re-runs itself under every available shell; set KIT_ENGINE_TEST_INNER to run assertions in-process.

set -u
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KIT_ENGINE_TEST_INNER:-}" ]; then
  . "$dir/kit-manifest.sh"
  . "$dir/kit-config-resolve.sh"
  . "$dir/kit-operate.sh"
  fail=0
  t() { # t <label> <got> <want>
    if [ "$2" != "$3" ]; then echo "FAIL($KIT_ENGINE_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1
    else echo "ok($KIT_ENGINE_TEST_INNER): $1"; fi
  }

  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

  # --- cascade fixture: workspace -> project -> island ---------------------
  mkdir -p "$work/ws/proj/island/.claude" "$work/ws/proj/.claude" "$work/ws"
  printf '{"project":{"language":"en"},"mode":"guided","roles":["pm","tech-lead"]}\n' > "$work/ws/kit.workspace.json"
  printf '{"project":{"language":"es","name":"proj"},"mode":"enforced"}\n' > "$work/ws/proj/kit.config.json"
  printf '{"mode":"enforced","roles":["backend"]}\n' > "$work/ws/proj/island/kit.config.json"

  # layers far->near from island: workspace, project, island
  layers="$(kit_resolve_layers "$work/ws/proj/island" | sed "s#$work/##g" | tr '\n' '|')"
  t "layers order" "$layers" "ws/kit.workspace.json|ws/proj/kit.config.json|ws/proj/island/kit.config.json|"

  # scalar override: language es (project) beats en (workspace)
  t "scalar override (language)" "$(kit_resolve_get '.project.language' "$work/ws/proj/island")" "es"
  # deep-merge keeps project name even though island doesn't mention project
  t "deep-merge keeps name"      "$(kit_resolve_get '.project.name' "$work/ws/proj/island")" "proj"
  # array replace: island roles replace workspace roles (replace mode)
  t "array replace (roles)"      "$(kit_resolve_get '.roles | join(",")' "$work/ws/proj/island")" "backend"
  # at project level (no island), roles come from workspace
  t "array inherit at project"   "$(kit_resolve_get '.roles | join(",")' "$work/ws/proj")" "pm,tech-lead"
  # mode: enforced at island
  t "mode at island"             "$(kit_resolve_get '.mode' "$work/ws/proj/island")" "enforced"

  # --explain origin: language is set by the project config (nearest definer)
  origin="$(kit_resolve_explain '.project.language' "$work/ws/proj/island" | awk -F': ' '/^set by/{print $2}' | sed "s#$work/##")"
  t "explain origin (language)"  "$origin" "ws/proj/kit.config.json"

  # concat mode: arrays concatenate
  cm="$(KIT_MERGE_MODE=concat kit_resolve_get '.roles | join(",")' "$work/ws/proj/island")"
  t "concat mode (roles)"        "$cm" "pm,tech-lead,backend"

  # --- manifest ------------------------------------------------------------
  proj="$work/p"; mkdir -p "$proj/.claude"; cd "$proj"
  export KIT_MANIFEST=".claude/kit.manifest.json"
  printf 'hello\n' > tracked.txt
  kit_manifest_record "tracked.txt" "A" "init" "1.0.0" "2026-01-01T00:00:00Z"
  t "verify intact"     "$(kit_manifest_verify tracked.txt)" "intact"
  printf 'changed\n' > tracked.txt
  t "verify modified"   "$(kit_manifest_verify tracked.txt)" "modified"
  rm -f tracked.txt
  t "verify missing"    "$(kit_manifest_verify tracked.txt)" "missing"
  t "verify untracked"  "$(kit_manifest_verify other.txt)"   "untracked"
  printf 'x\n' > b.txt; kit_manifest_record "b.txt" "B" "wire" "1.0.0" "2026-01-01T00:00:00Z"
  t "list tier B"       "$(kit_manifest_list B | tr '\n' ',')" "b.txt,"
  kit_manifest_remove_entry "b.txt"
  t "remove entry"      "$(kit_manifest_verify b.txt)" "untracked"

  # --- operate -------------------------------------------------------------
  printf 'SRC v1\n' > src.txt
  # dry-run writes nothing
  KIT_DRY_RUN=1 kit_op_write src.txt dst.txt A wire >/dev/null 2>&1
  t "dry-run no write"  "$([ -f dst.txt ] && echo yes || echo no)" "no"
  # real write with assume-yes
  KIT_ASSUME_YES=1 kit_op_write src.txt dst.txt A wire >/dev/null 2>&1
  t "op write created"  "$([ -f dst.txt ] && echo yes || echo no)" "yes"
  t "op write tracked"  "$(kit_manifest_verify dst.txt)" "intact"
  # idempotent: same content, no error, still intact
  KIT_ASSUME_YES=1 kit_op_write src.txt dst.txt A wire >/dev/null 2>&1
  t "op write idempotent" "$(kit_manifest_verify dst.txt)" "intact"
  # conffiles: user edits dst, then op WITHOUT assume-yes must not clobber (declined => exit 10)
  printf 'USER EDIT\n' > dst.txt
  KIT_ASSUME_YES= kit_op_write src.txt dst.txt A wire </dev/null >/dev/null 2>&1
  t "conffiles keeps edit" "$(cat dst.txt)" "USER EDIT"
  # remove untracked refuses
  printf 'z\n' > untracked2.txt
  KIT_ASSUME_YES=1 kit_op_remove untracked2.txt >/dev/null 2>&1
  t "remove refuses untracked" "$([ -f untracked2.txt ] && echo yes || echo no)" "yes"
  # remove tracked-intact deletes (record fresh first to match current content)
  printf 'SRC v1\n' > dst.txt; kit_manifest_record dst.txt A wire 1.0.0 2026-01-01T00:00:00Z
  KIT_ASSUME_YES=1 kit_op_remove dst.txt >/dev/null 2>&1
  t "remove intact deletes" "$([ -f dst.txt ] && echo yes || echo no)" "no"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_ENGINE_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1))
  echo "--- $sh ---"
  # -f / --no-rcs: skip user startup files (they can reset PATH); pass PATH explicitly so the
  # subshell finds jq + coreutils regardless of the invoked shell's default environment.
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_ENGINE_TEST_INNER="$sh" PATH="$PATH" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell found"; exit 1; }
exit "$rc"
