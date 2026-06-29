#!/usr/bin/env bash
# portable-test.sh — cckit must operate on the project it is INVOKED in, not its install dir (#41).
# Regression test for the bug where `cckit sync` in another repo read cckit's own config and so
# reported an empty board `[]`. Hermetic: stubs `gh` (no network/auth). Run: bash scripts/portable-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CCKIT="$ROOT/bin/cckit"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }

command -v jq >/dev/null 2>&1 || { echo "portable-test: jq required" >&2; exit 1; }

# Stub gh on PATH: record the --repo it is asked for (to stderr), return an empty JSON array.
stub="$(mktemp -d)"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  [ "$prev" = "--repo" ] && printf 'REPO=%s\n' "$a" >&2
  prev="$a"
done
echo "[]"
SH
chmod +x "$stub/gh"

# A foreign project with its own config pointing at a DISTINCT repo.
fix="$(mktemp -d)"
cat > "$fix/cckit.config.json" <<'JSON'
{ "kitVersion": "9.9.9", "project": {"name":"fixture"}, "github": {"repo":"octo/fixture-repo","owner":"octo","baseBranch":"main"} }
JSON
( cd "$fix" && git init -q ) 2>/dev/null

# 1) From the fixture, sync resolves the fixture's config → targets the fixture's repo.
got_repo="$(cd "$fix" && PATH="$stub:$PATH" "$CCKIT" sync --llm 2>&1 >/dev/null | sed -n 's/^REPO=//p' | tail -1)"
t "sync targets the invoking project's repo" "$got_repo" "octo/fixture-repo"

# 2) From the fixture, scan reports the fixture as root (no cd to the install dir).
got_root="$(cd "$fix" && "$CCKIT" scan --llm 2>/dev/null | jq -r .root)"
t "scan root is the invoking dir" "$got_root" "$(cd "$fix" && pwd -P)"

# 3) Self-hosting: from the cckit repo, sync still targets cckit's own repo.
own_repo="$(jq -r '.github.repo' "$ROOT/cckit.config.json")"
got_own="$(cd "$ROOT" && PATH="$stub:$PATH" "$CCKIT" sync --llm 2>&1 >/dev/null | sed -n 's/^REPO=//p' | tail -1)"
t "self-host sync targets cckit's repo" "$got_own" "$own_repo"

# 4) `version` is the INSTALLED version regardless of where it is invoked.
inst_ver="$(jq -r '.kitVersion' "$ROOT/cckit.config.json")"
got_ver="$(cd "$fix" && "$CCKIT" version | awk '{print $2}')"
t "version is the install version, not the project's" "$got_ver" "$inst_ver"

rm -rf "$stub" "$fix"
[ "$fail" -eq 0 ] && echo "ALL OK (portable)" || echo "portable: FAILURES"
exit "$fail"
