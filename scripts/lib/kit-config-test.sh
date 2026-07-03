#!/usr/bin/env bash
# shellcheck shell=bash
# kit-config-test.sh — covers load_kit_config resolution that adoption depends on. Today: the
# integration-branch fallback chain (#117) — a host project that names its integration branch under
# an alternate key (integrationBranch / flow) must still resolve, not silently fall back to "main".
# Hermetic: throwaway config files pointed at via KIT_CONFIG. Run:  bash scripts/lib/kit-config-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "kit-config-test: jq required — skipping"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# base_branch_for <json> — resolve KIT_BASE_BRANCH for a given github config, hermetically.
base_branch_for() {
  local json="$1" d; d="$(mktemp -d "$tmp/cfg.XXXXXX")"
  printf '%s' "$json" > "$d/cckit.config.json"
  KIT_CONFIG="$d/cckit.config.json" bash -c "source '$LIB/kit-config.sh'; load_kit_config >/dev/null 2>&1; printf '%s' \"\$KIT_BASE_BRANCH\""
}

# baseBranch is canonical and wins over the alternate keys.
t "baseBranch wins" \
  "$(base_branch_for '{"github":{"baseBranch":"develop","integrationBranch":"x","flow":"y"}}')" "develop"
# integrationBranch is honored when baseBranch is absent (older/alternate host config).
t "integrationBranch fallback" \
  "$(base_branch_for '{"github":{"integrationBranch":"integration","flow":"y"}}')" "integration"
# flow is the last named fallback before the default.
t "flow fallback" \
  "$(base_branch_for '{"github":{"flow":"trunk"}}')" "trunk"
# nothing set -> "main", the safe default.
t "default main when unset" \
  "$(base_branch_for '{"github":{}}')" "main"

[ "$fail" -eq 0 ] && echo "ALL OK (kit-config)" || echo "kit-config: FAILURES"
exit "$fail"
