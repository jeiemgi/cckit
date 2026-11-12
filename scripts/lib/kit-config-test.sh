#!/usr/bin/env bash
# shellcheck shell=bash
# kit-config-test.sh — covers load_kit_config resolution that adoption depends on. Today: the
# integration-branch fallback chain (#117) — a host project that names its integration branch under
# an alternate key (integrationBranch / flow) must still resolve, not silently fall back to "main".
# Hermetic: throwaway config files pointed at via KIT_CONFIG. Run:  bash scripts/lib/kit-config-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
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
  # env -u: an exported KIT_BASE_BRANCH is an override now (#352), so one inherited from the shell
  # that runs this file directly would answer for the config in every fallback case below.
  env -u KIT_BASE_BRANCH KIT_CONFIG="$d/cckit.config.json" bash -c "source '$LIB/kit-config.sh'; load_kit_config >/dev/null 2>&1; printf '%s' \"\$KIT_BASE_BRANCH\""
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

# ── #352 · KIT_BASE_BRANCH from the environment overrides the config ──────────────────────────
# A sub-issue of an effort is cut from effort/<N>, not from the base, so the caller has to be able
# to name the branch: `KIT_BASE_BRANCH=effort/9-x cckit orchestrate <sub>`. load_kit_config used to
# assign over it. KIT_BASE_BRANCH_CONFIG keeps what the config says, so a caller can tell the two
# apart and say which one it used.
# base_env_for <env value> <json> <var> — load with KIT_BASE_BRANCH preset, print <var>.
base_env_for() {
  local val="$1" json="$2" var="$3" d; d="$(mktemp -d "$tmp/env.XXXXXX")"
  printf '%s' "$json" > "$d/cckit.config.json"
  KIT_BASE_BRANCH="$val" KIT_CONFIG="$d/cckit.config.json" bash -c "source '$LIB/kit-config.sh'; load_kit_config >/dev/null 2>&1; printf '%s' \"\$$var\""
}
t "env KIT_BASE_BRANCH survives the load" \
  "$(base_env_for effort/9-x '{"github":{"baseBranch":"develop"}}' KIT_BASE_BRANCH)" "effort/9-x"
t "config value is kept beside the override" \
  "$(base_env_for effort/9-x '{"github":{"baseBranch":"develop"}}' KIT_BASE_BRANCH_CONFIG)" "develop"
t "empty env KIT_BASE_BRANCH falls back to the config" \
  "$(base_env_for '' '{"github":{"baseBranch":"develop"}}' KIT_BASE_BRANCH)" "develop"
d1="$(mktemp -d "$tmp/plain.XXXXXX")"; printf '%s' '{"github":{"flow":"trunk"}}' > "$d1/cckit.config.json"
t "no override: both name the config value" \
  "$(env -u KIT_BASE_BRANCH KIT_CONFIG="$d1/cckit.config.json" bash -c "source '$LIB/kit-config.sh'; load_kit_config; printf '%s|%s' \"\$KIT_BASE_BRANCH\" \"\$KIT_BASE_BRANCH_CONFIG\"" 2>/dev/null)" "trunk|trunk"
# The override survives a SECOND load in the same process (effort.sh and kit-task-ops.sh each call
# load_kit_config on source, after the dispatcher already did).
d2="$(mktemp -d "$tmp/twice.XXXXXX")"; printf '%s' '{"github":{"baseBranch":"develop"}}' > "$d2/cckit.config.json"
t "override survives a second load" \
  "$(KIT_BASE_BRANCH=effort/9-x KIT_CONFIG="$d2/cckit.config.json" bash -c "source '$LIB/kit-config.sh'; load_kit_config; load_kit_config; printf '%s|%s' \"\$KIT_BASE_BRANCH\" \"\$KIT_BASE_BRANCH_CONFIG\"" 2>/dev/null)" "effort/9-x|develop"

# ── #244 · effort.wipLimit is exported as KIT_EFFORT_WIP_LIMIT ────────────────────────────────
# The effort WIP gate reads this env var when EFFORT_WIP_LIMIT is unset. An UNSET key must export
# an EMPTY string (not the literal "null"), because effort-ops treats non-empty as "configured" and
# would otherwise reject "null" as a bad value on every repo that never set the key.
wip_for() {
  local json="$1" d; d="$(mktemp -d "$tmp/wip.XXXXXX")"
  printf '%s' "$json" > "$d/cckit.config.json"
  KIT_CONFIG="$d/cckit.config.json" bash -c "source '$LIB/kit-config.sh'; load_kit_config >/dev/null 2>&1; printf '%s' \"\$KIT_EFFORT_WIP_LIMIT\""
}
t "effort.wipLimit is exported"        "$(wip_for '{"github":{},"effort":{"wipLimit":3}}')" "3"
t "effort.wipLimit 0 survives export"  "$(wip_for '{"github":{},"effort":{"wipLimit":0}}')" "0"
t "unset effort.wipLimit exports ''"   "$(wip_for '{"github":{}}')" ""

[ "$fail" -eq 0 ] && echo "ALL OK (kit-config)" || echo "kit-config: FAILURES"
exit "$fail"
