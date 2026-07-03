#!/usr/bin/env bash
# shellcheck shell=bash
# effort-flows-test.sh — #150: the flow vocabulary resolves from the project config, so
# `cckit effort new --flow X` works out of the box in any configured repo. Resolution order:
#   explicit EFFORT_FLOWS env var (wins) -> effort.flows[] in the project config -> built-in default.
# Hermetic: throwaway configs pointed at via KIT_CONFIG (no network, no gh).
# Run:  bash scripts/lib/effort-flows-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
command -v jq >/dev/null 2>&1 || { echo "effort-flows-test: jq required — skipping"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '%s' '{"github":{"repo":"o/r"},"effort":{"flows":["Growth","Checkout","Platform"]}}' > "$tmp/flows.json"
printf '%s' '{"github":{"repo":"o/r"}}' > "$tmp/noflows.json"

# flows_for <cfg> [VAR=val …] — source effort.sh under a given config + env; print resolved EFFORT_FLOWS.
# KIT_REPO is pre-set so effort.sh's own config bootstrap is skipped — this isolates the #150 resolver.
flows_for() {
  local cfg="$1"; shift
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" KIT_CONFIG="$cfg" KIT_REPO="o/r" "$@" \
    bash -c "source '$LIB/effort.sh' 2>/dev/null; printf '%s' \"\$EFFORT_FLOWS\""
}

# 1. effort.flows[] in the config replaces the built-in default.
t "effort.flows[] resolves from the project config" \
  "$(flows_for "$tmp/flows.json")" "Growth Checkout Platform"
# 2. an explicit EFFORT_FLOWS env var still wins over the config.
t "EFFORT_FLOWS env var wins over the config" \
  "$(flows_for "$tmp/flows.json" EFFORT_FLOWS="Alpha Beta")" "Alpha Beta"
# 3. no effort.flows in the config -> the built-in default.
t "no effort.flows -> built-in default" \
  "$(flows_for "$tmp/noflows.json")" "Core UI API Docs Infra Auth Data Web App"
# 4. an already-exported KIT_EFFORT_FLOWS (load_kit_config) is honored without re-reading the file.
t "exported KIT_EFFORT_FLOWS is honored" \
  "$(flows_for "$tmp/noflows.json" KIT_EFFORT_FLOWS="Ops Sales")" "Ops Sales"

# 5. the title lint enforces the CONFIGURED vocabulary.
lint_rc() {
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" KIT_CONFIG="$tmp/flows.json" KIT_REPO="o/r" \
    bash -c "source '$LIB/effort.sh' 2>/dev/null; effort_title_lint \"\$1\" >/dev/null 2>&1" _ "$1"
}
lint_rc "[Effort] 9 · [Growth] faster onboarding"; t "lint accepts a config flow" "$?" "0"
lint_rc "[Effort] 9 · [Core] faster onboarding";   t "lint rejects a flow outside the config vocabulary" "$?" "1"

# 6. load_kit_config exports KIT_EFFORT_FLOWS (space-joined) for every downstream consumer.
t "load_kit_config exports KIT_EFFORT_FLOWS" \
  "$(env -i PATH="$PATH" HOME="${HOME:-/tmp}" KIT_CONFIG="$tmp/flows.json" \
       bash -c "source '$LIB/kit-config.sh'; load_kit_config >/dev/null 2>&1; printf '%s' \"\$KIT_EFFORT_FLOWS\"")" \
  "Growth Checkout Platform"

[ "$fail" -eq 0 ] && echo "ALL OK (effort-flows)" || echo "effort-flows: FAILURES"
exit "$fail"
