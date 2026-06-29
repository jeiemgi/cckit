#!/usr/bin/env bash
# check.sh — cckit local gate. Runs the fast, dependency-light checks that must pass before a PR.
# No CI required; this is the bar. Exit non-zero on the first failure.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

fail=0
note() { printf '%s\n' "$*" >&2; }

# 1. Every shell script parses (bash -n).
note "==> shell syntax (bash -n)"
while IFS= read -r f; do
  bash -n "$f" || { note "x syntax: $f"; fail=1; }
done < <(find bin scripts -type f \( -name '*.sh' -o -perm -u+x \) 2>/dev/null | sort -u)

# 2. The plugin manifest is valid JSON.
note "==> plugin manifest JSON"
if command -v jq >/dev/null 2>&1; then
  jq -e . .claude-plugin/plugin.json >/dev/null || { note "x invalid plugin.json"; fail=1; }
  jq -e . cckit.config.json >/dev/null || { note "x invalid cckit.config.json"; fail=1; }
else
  note "  (jq absent — skipping JSON validation)"
fi

# 3. No tedos branding leaked into the standalone (the de-tedos-ification gate).
note "==> no tedos branding (grep -ri tedos)"
if grep -rniI --exclude-dir=.git --exclude-dir=node_modules --exclude=check.sh tedos . >/dev/null 2>&1; then
  note "x found 'tedos' references — cckit must be tedos-free:"
  grep -rniI --exclude-dir=.git --exclude-dir=node_modules --exclude=check.sh tedos . | head -20 >&2
  fail=1
fi

# 4. Secret + privacy guard — no secrets, keys, env, or private data in anything publishable.
note "==> secret + privacy guard"
if [ -f scripts/lib/secret-guard.sh ]; then
  . scripts/lib/secret-guard.sh
  secret_guard_scan || fail=1
fi

[ "$fail" -eq 0 ] && note "✓ cckit check passed" || note "✗ cckit check FAILED"
exit "$fail"
