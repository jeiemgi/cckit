#!/usr/bin/env bash
# config-path-test.sh — scan/config recognize BOTH a root cckit.config.json AND a
# .claude/kit.config.json as a configured project (#65, #69). Hermetic, no network.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "config-path-test: jq required" >&2; exit 1; }
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/project-scan.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mk() { mkdir -p "$1"; ( cd "$1" && git init -q ); }

# A) root cckit.config.json (cckit self-host layout) -> configured
mk "$tmp/a"; echo '{}' > "$tmp/a/cckit.config.json"
t "root cckit.config.json -> configured"       "$(project_scan "$tmp/a" | jq -r .kit)" "configured"

# B) .claude/kit.config.json (consuming-project layout) -> configured (was the #65 bug)
mk "$tmp/b"; mkdir -p "$tmp/b/.claude"; echo '{}' > "$tmp/b/.claude/kit.config.json"
t ".claude/kit.config.json -> configured"      "$(project_scan "$tmp/b" | jq -r .kit)" "configured"

# C) bare .claude/ with no kit config -> claude-only (not falsely "configured")
mk "$tmp/c"; mkdir -p "$tmp/c/.claude"
t "bare .claude/ -> claude-only"               "$(project_scan "$tmp/c" | jq -r .kit)" "claude-only"

# D) nothing -> none
mk "$tmp/d"
t "greenfield -> none"                         "$(project_scan "$tmp/d" | jq -r .kit)" "none"

[ "$fail" -eq 0 ] && echo "ALL OK (config-path)" || echo "config-path: FAILURES"
exit "$fail"
