#!/usr/bin/env bash
# shellcheck shell=bash
# kit-version-check-test.sh — covers `cckit update` self-version resolution (#124). The check must
# resolve the RUNNING install's plugin.json from the script's own dir (it ships at <install>/scripts/)
# — not only via a ~/.claude/plugins glob that matched claude-kit* and never a cckit install, so
# `cckit update` silently no-op'd. Hermetic: a throwaway target config; CLAUDE_PLUGIN_ROOT unset so
# only the self-resolution can find the version. Run:  bash scripts/kit-version-check-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/kit-version-check.sh"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "kit-version-check-test: jq required — skipping"; exit 0; }

INSTALLED="$(jq -r '.version // "0.0.0"' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo 0.0.0)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# A project recorded BEHIND the installed cckit → the check must self-resolve the install version and
# signal "behind" (exit 10), instead of exiting 0 because a plugin-dir glob found nothing.
printf '{"kitVersion":"0.0.1"}' > "$tmp/cckit.config.json"
out="$(env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPT" --target "$tmp" 2>&1)"; rc=$?
t "behind project → exit 10 (self-resolved, not a silent no-op)" "$rc" "10"
case "$out" in *"$INSTALLED"*) echo "ok: notice names the resolved install version ($INSTALLED)" ;; *) echo "FAIL: notice lacks install version: $out"; fail=1 ;; esac

# A project recorded AT the installed version → up to date (exit 0), still self-resolved.
printf '{"kitVersion":"%s"}' "$INSTALLED" > "$tmp/cckit.config.json"
env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPT" --target "$tmp" >/dev/null 2>&1
t "at-version project → exit 0 (up to date)" "$?" "0"

# No config at the target → safe no-op (exit 0), never an error.
rm -f "$tmp/cckit.config.json"
env -u CLAUDE_PLUGIN_ROOT bash "$SCRIPT" --target "$tmp" >/dev/null 2>&1
t "no config → safe no-op (exit 0)" "$?" "0"

[ "$fail" -eq 0 ] && echo "ALL OK (kit-version-check)" || echo "kit-version-check: FAILURES"
exit "$fail"
