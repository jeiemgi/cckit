#!/usr/bin/env bash
# shellcheck shell=bash
# version-bump-test.sh — #173: version-bump.sh --write is the ONE version stamper, and every
# version surface it owns must agree. The release path (publish.sh) used an inline jq that wrote
# only cckit.config.json.kitVersion, shipping releases whose .claude-plugin/plugin.json and
# package.json lagged behind. Guards: (1) vb_write stamps all four files, (2) publish.sh calls the
# shared bumper (no second implementation), (3) the repo's four version files currently agree.
# Run:  bash scripts/lib/version-bump-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "version-bump-test: jq required" >&2; exit 1; }

# (1) vb_write stamps every surface — exercised against a throwaway copy of the four files.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/.claude-plugin" "$tmp/docs-site" "$tmp/scripts/lib"
echo '{"kitVersion":"0.0.1"}' > "$tmp/cckit.config.json"
echo '{"version":"0.0.1"}'    > "$tmp/.claude-plugin/plugin.json"
echo '{"version":"0.0.1"}'    > "$tmp/package.json"
echo '{"version":"0.0.1"}'    > "$tmp/docs-site/package.json"
cp "$ROOT/scripts/lib/version-bump.sh" "$tmp/scripts/lib/version-bump.sh"
(cd "$tmp" && bash scripts/lib/version-bump.sh --write 9.9.9 >/dev/null 2>&1)
t "vb_write stamps cckit.config.json"       "$(jq -r .kitVersion "$tmp/cckit.config.json")"          "9.9.9"
t "vb_write stamps plugin.json"             "$(jq -r .version "$tmp/.claude-plugin/plugin.json")"    "9.9.9"
t "vb_write stamps package.json"            "$(jq -r .version "$tmp/package.json")"                  "9.9.9"
t "vb_write stamps docs-site/package.json"  "$(jq -r .version "$tmp/docs-site/package.json")"        "9.9.9"

# (2) publish.sh delegates to the shared bumper — a reintroduced inline kitVersion jq is the drift.
t "publish.sh calls version-bump.sh --write" \
  "$(grep -c 'version-bump.sh. --write' "$ROOT/scripts/publish.sh")" "1"
t "publish.sh has no inline kitVersion bump" \
  "$(grep -c 'kitVersion=' "$ROOT/scripts/publish.sh")" "0"

# (3) the repo's four version surfaces agree RIGHT NOW (catches a drifted release after the fact).
v="$(jq -r .kitVersion "$ROOT/cckit.config.json")"
t "plugin.json matches kitVersion ($v)"            "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" "$v"
t "package.json matches kitVersion ($v)"           "$(jq -r .version "$ROOT/package.json")"               "$v"
t "docs-site/package.json matches kitVersion ($v)" "$(jq -r .version "$ROOT/docs-site/package.json")"     "$v"

[ "$fail" -eq 0 ] && echo "ALL OK (version-bump)"
exit "$fail"
