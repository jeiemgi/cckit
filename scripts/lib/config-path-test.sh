#!/usr/bin/env bash
# shellcheck shell=bash
# config-path-test.sh — covers the ONE shared config-path resolver (#69): kit_config_find (pure walk)
# and kit_config_path (KIT_CONFIG wins, else walk). Every kit entrypoint discovers the project config
# through these. Hermetic: throwaway dirs. Run:  bash scripts/lib/config-path-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '$2' want '$3'"; fail=1; fi; }

# shellcheck source=/dev/null
. "$LIB/config-path.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# A) root cckit.config.json (self-host / current layout)
mkdir -p "$tmp/a"; printf '{}' > "$tmp/a/cckit.config.json"
t "finds a root cckit.config.json" "$(kit_config_find "$tmp/a")" "$tmp/a/cckit.config.json"

# B) scaffolded .claude/kit.config.json
mkdir -p "$tmp/b/.claude"; printf '{}' > "$tmp/b/.claude/kit.config.json"
t "finds a scaffolded .claude/kit.config.json" "$(kit_config_find "$tmp/b")" "$tmp/b/.claude/kit.config.json"

# C) cckit.config.json wins over .claude/kit.config.json in the same dir
mkdir -p "$tmp/c/.claude"; printf '{}' > "$tmp/c/cckit.config.json"; printf '{}' > "$tmp/c/.claude/kit.config.json"
t "root cckit.config.json wins over .claude/" "$(kit_config_find "$tmp/c")" "$tmp/c/cckit.config.json"

# D) walk up: a nested start dir resolves an ancestor's config
mkdir -p "$tmp/a/deep/nested"
t "walks up to an ancestor config" "$(kit_config_find "$tmp/a/deep/nested")" "$tmp/a/cckit.config.json"

# E) no config anywhere in the (isolated) tree -> rc 1, empty
mkdir -p "$tmp/empty"
out="$(kit_config_find "$tmp/empty" 2>/dev/null)"; r=$?
# (mktemp lives under /var|/tmp with no ancestor kit config, so this is a clean miss)
rc "no config -> rc 1" "$r" "1"
t  "no config -> empty output" "$out" ""

# F) kit_config_path: an explicit KIT_CONFIG always wins, regardless of the start dir
t "KIT_CONFIG wins in kit_config_path" "$(KIT_CONFIG=/explicit/override.json kit_config_path "$tmp/a")" "/explicit/override.json"
# without KIT_CONFIG, kit_config_path delegates to the walk
t "kit_config_path walks when KIT_CONFIG unset" "$(KIT_CONFIG= kit_config_path "$tmp/b")" "$tmp/b/.claude/kit.config.json"

[ "$fail" -eq 0 ] && echo "ALL OK (config-path)" || echo "config-path: FAILURES"
exit "$fail"
