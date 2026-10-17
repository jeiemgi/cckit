#!/usr/bin/env bash
# night-grant-test.sh — the night grant parser, picker and allowlist preflight, offline.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "night-grant-test: jq required — skipping"; exit 0; }
bash "$ROOT/scripts/night-grant.sh" --selftest
