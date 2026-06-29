#!/usr/bin/env bash
# check.sh - cckit local gate. Runs the fast, dependency-light checks that must pass before a PR.
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

# 1b. shellcheck at error severity — static analysis when available, skipped if not installed
# (like jq below) so the gate stays dependency-light. CI installs shellcheck so this always runs there.
note "==> shellcheck (errors)"
if command -v shellcheck >/dev/null 2>&1; then
  find bin scripts -type f \( -name '*.sh' -o -name 'cckit' \) -print0 \
    | xargs -0 shellcheck --severity=error || fail=1
else
  note "  (shellcheck absent - skipping)"
fi

# 2. The plugin manifest is valid JSON.
note "==> plugin manifest JSON"
if command -v jq >/dev/null 2>&1; then
  jq -e . .claude-plugin/plugin.json >/dev/null || { note "x invalid plugin.json"; fail=1; }
  jq -e . cckit.config.json >/dev/null || { note "x invalid cckit.config.json"; fail=1; }
else
  note "  (jq absent - skipping JSON validation)"
fi

# 3. No tedos branding leaked into what SHIPS (the de-tedos-ification gate). Scans TRACKED files
# only (git grep) so gitignored runtime state (.cckit/), build output (dist/), and deps never trip
# a false positive - only committed content must be tedos-free. Falls back to a filtered recursive
# grep outside a git work tree.
note "==> no tedos branding (tracked files)"
_tedos_scan() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git grep -inI tedos -- . ':!scripts/check.sh'
  else
    grep -rniI --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.cckit \
      --exclude-dir=dist --exclude=check.sh tedos .
  fi
}
if _tedos_scan >/dev/null 2>&1; then
  note "x found 'tedos' references - cckit must be tedos-free:"
  _tedos_scan | head -20 >&2
  fail=1
fi

# 4. Secret + privacy guard - no secrets, keys, env, or private data in anything publishable.
note "==> secret + privacy guard"
if [ -f scripts/lib/secret-guard.sh ]; then
  . scripts/lib/secret-guard.sh
  secret_guard_scan || fail=1
fi

# 5. Behavioral tests - run every *-test.sh through the test runner.
note "==> behavioral tests"
bash scripts/test.sh || fail=1

[ "$fail" -eq 0 ] && note "PASS cckit check passed" || note "FAIL cckit check FAILED"
exit "$fail"
