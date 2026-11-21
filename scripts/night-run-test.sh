#!/usr/bin/env bash
# night-run-test.sh — the night engine's decisions, evaluated with stubbed agents.
# scripts/night-run.test.mjs loads scripts/night-run.mjs as the Workflow runtime would, with
# agent()/pipeline()/budget faked, and drives every unattended decision. Needs node; skips without.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
command -v node >/dev/null 2>&1 || { echo "night-run-test: node required — skipping"; exit 0; }
exec node --test "$ROOT/scripts/night-run.test.mjs"
