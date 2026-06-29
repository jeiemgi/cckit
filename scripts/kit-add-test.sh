#!/usr/bin/env bash
# kit-add-test.sh — self-test for kit-add module stacking (#372). Runs under bash AND zsh.
# Run:  bash scripts/kit-add-test.sh
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KIT_ADD_TEST_INNER:-}" ]; then
  set -u
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_ADD_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_ADD_TEST_INNER): $1"; fi; }
  ADD="$dir/kit-add.sh"

  export KIT_PROFILE_HOME="$(mktemp -d)"
  export KIT_ASSUME_YES=1 KIT_VERSION=9.9.9
  ws="$(mktemp -d)"; trap 'rm -rf "$KIT_PROFILE_HOME" "$ws"' EXIT
  mkdir -p "$ws/myapp"
  printf '%s\n' '{"workspace":{"name":"ws"},"mode":"guided"}' > "$ws/kit.workspace.json"
  parent_before="$(cat "$ws/kit.workspace.json")"

  # unknown module fails
  "$ADD" doesnotexist --dir "$ws/myapp" >/dev/null 2>&1; t "unknown module rc" "$?" "1"

  # add software (defaults) — island config created
  "$ADD" software --dir "$ws/myapp" >/dev/null 2>&1; t "add rc" "$?" "0"
  cfg="$ws/myapp/.claude/kit.config.json"
  t "island created"   "$([ -f "$cfg" ] && echo yes)"                  "yes"
  t "modules"          "$(jq -c .modules "$cfg")"                      '["software"]'
  t "github wizard"    "$(jq -r .github.projectsV2 "$cfg")"            "true"
  t "ci wizard"        "$(jq -r .ci.provider "$cfg")"                  "github-actions"
  t "manifest tracks"  "$(jq -r '.entries["'.claude/kit.config.json'"] | has("hash")' "$ws/myapp/.claude/kit.manifest.json")" "true"

  # parent workspace untouched
  t "parent untouched" "$(cat "$ws/kit.workspace.json")" "$parent_before"

  # idempotent: a 2nd identical run leaves the file byte-identical
  before="$(cat "$cfg")"
  "$ADD" software --dir "$ws/myapp" >/dev/null 2>&1
  t "idempotent file"  "$(cat "$cfg")" "$before"

  # --set override changes only that field; modules stay deduped
  "$ADD" software --dir "$ws/myapp" --set deploy=vercel >/dev/null 2>&1
  t "override deploy"  "$(jq -r .deploy.target "$cfg")" "vercel"
  t "modules still one" "$(jq -c .modules "$cfg")" '["software"]'

  # dry-run writes nothing new
  fresh="$(mktemp -d)"; mkdir -p "$fresh/app"
  KIT_DRY_RUN=1 "$ADD" software --dir "$fresh/app" >/dev/null 2>&1
  t "dry-run no write" "$([ -f "$fresh/app/.claude/kit.config.json" ] && echo wrote || echo clean)" "clean"
  rm -rf "$fresh"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_ADD_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_ADD_TEST_INNER="$sh" PATH="$PATH" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
