#!/usr/bin/env bash
# shellcheck shell=bash
# integrations-check-test.sh — covers the monthly recipe check (E303.8):
# scripts/integrations-check.sh and the shape of .github/workflows/integrations-check.yml. The
# workflow cannot run before it is merged (`schedule` and `workflow_dispatch` are read from the
# default branch), so the logic lives in the script and is tested here.
#
# Hermetic: every descriptor is a fixture in a throwaway registry whose commands are plain shell
# writing into a throwaway HOME. The schema's `manager` enum is closed, so fixtures name `npm`, and
# a no-op `npm` stub leads PATH: the runner only asks whether the manager exists, then runs the
# descriptor's own command. No shipped descriptor is installed and no package manager runs.
# Run:  bash scripts/integrations-check-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
CHECK="$ROOT/scripts/integrations-check.sh"
WF="$ROOT/.github/workflows/integrations-check.yml"
fail=0
rc()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '$2' want '$3'"; fail=1; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then echo "ok: $1"; else echo "FAIL: $1 -> '$3' not in: $2"; fail=1; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then echo "FAIL: $1 -> '$3' found in: $2"; fail=1; else echo "ok: $1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "integrations-check-test: jq absent — skipping (dependency-light gate)"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
export HOME="$tmp/home"; mkdir -p "$HOME"
fx="$tmp/integrations"; mkdir -p "$fx"
cp "$ROOT/integrations/integration.schema.json" "$fx/"
export KIT_INTEGRATIONS_DIR="$fx"
mkdir -p "$tmp/stubs"; printf '#!/bin/sh\nexit 0\n' > "$tmp/stubs/npm"; chmod +x "$tmp/stubs/npm"
export PATH="$tmp/stubs:$PATH"
# A platform this machine is not, from the schema's closed `os` enum.
other_os="Linux"; [ "$(uname -s)" = "Linux" ] && other_os="Darwin"

# fixture <id> <install-command> <verify-command> [extra top-level JSON members]
# The tool is a script at ~/.local/bin/<id>-bin: off PATH, where the runner looks for it.
fixture() {
  cat > "$fx/$1.json" <<JSON
{
  "id": "$1",
  "label": "$1",
  "summary": "A tool that exists only in this test.",
  "config": { "key": "fixtureKind.provider", "value": "$1" },
  "detect": { "run": "$1-bin --version" },
  "install": [ { "manager": "npm", "run": "$2" } ],
  "verify": { "run": "$3" },
  ${4:-}
  "docs": "https://example.com/$1",
  "attribution": { "author": "Nobody", "homepage": "https://example.com/$1", "affiliated": false, "notice": "A test fixture." }
}
JSON
}
# The install command a working recipe uses: drop an executable that exits 0.
good_install() { printf "mkdir -p \$HOME/.local/bin && printf '#!/bin/sh\\\\nexit 0\\\\n' > \$HOME/.local/bin/%s-bin && chmod +x \$HOME/.local/bin/%s-bin" "$1" "$1"; }
reset() { rm -rf "$HOME/.local" "$fx"/*.json; cp "$ROOT/integrations/integration.schema.json" "$fx/"; }

# ── a healthy descriptor ───────────────────────────────────────────────────────────────────────
fixture healthy "$(good_install healthy)" "healthy-bin --version"
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "healthy: exit 0" "$r" 0
has "healthy: validate reported" "$out" "ok   healthy: validate"
has "healthy: install reported with its manager" "$out" "ok   healthy: install: npm"
has "healthy: detect reported" "$out" "ok   healthy: detect: healthy-bin --version"
has "healthy: verify reported" "$out" "ok   healthy: verify: healthy-bin --version"
has "healthy: count line" "$out" "integrations-check: 1 checked, 0 failed, 0 skipped"
hasnt "healthy: no FAIL line" "$out" "FAIL"

# The tool is now on the machine: a second run says the install recipe went unexercised.
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "already present: exit 0" "$r" 0
has "already present: says the install recipe was not exercised" "$out" "skip healthy: install: already on this machine"
has "already present: verify still runs" "$out" "ok   healthy: verify"

# ── an install command broken on purpose ───────────────────────────────────────────────────────
reset
fixture healthy "$(good_install healthy)" "healthy-bin --version"
fixture broken-install "exit 3" "broken-install-bin --version"
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "broken install: exit non-zero" "$r" 1
has "broken install: names the descriptor and the step" "$out" "FAIL broken-install: install:"
has "broken install: carries the runner's evidence" "$out" "integration broken-install: npm failed"
has "broken install: the healthy descriptor beside it still passes" "$out" "ok   healthy: verify"
has "broken install: count line" "$out" "integrations-check: 2 checked, 1 failed, 0 skipped"
hasnt "broken install: later steps do not run" "$out" "broken-install: verify"

# An installer that exits 0 and installs nothing is the same failure, not a pass.
reset
fixture lying-install "true" "lying-install-bin --version"
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "lying install: exit non-zero" "$r" 1
has "lying install: named at the install step" "$out" "FAIL lying-install: install:"

# ── verify broken, install fine ────────────────────────────────────────────────────────────────
reset
fixture broken-verify "$(good_install broken-verify)" "echo flag-was-renamed >&2; exit 2"
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "broken verify: exit non-zero" "$r" 1
has "broken verify: install passed first" "$out" "ok   broken-verify: install: npm"
has "broken verify: names the descriptor and the step" "$out" "FAIL broken-verify: verify:"
has "broken verify: carries the command's output" "$out" "flag-was-renamed"

# ── wire ───────────────────────────────────────────────────────────────────────────────────────
reset
fixture wired "$(good_install wired)" "wired-bin --version" \
  '"wire": { "run": "touch wired-here", "declined": { "--": "ends the flags, so the next one is a file name", "also-wired": "a second file" } },'
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "wire: exit 0" "$r" 0
has "wire: reported with the declined flags rendered" "$out" "ok   wired: wire: touch wired-here -- also-wired"
r=0; { [ -e "$ROOT/wired-here" ] || [ -e "$PWD/wired-here" ]; } && r=1
rc  "wire: ran in the scratch repo, not here" "$r" 0

reset
fixture broken-wire "$(good_install broken-wire)" "broken-wire-bin --version" '"wire": { "run": "exit 4" },'
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "broken wire: exit non-zero" "$r" 1
has "broken wire: names the descriptor and the step" "$out" "FAIL broken-wire: wire:"

# ── a descriptor that fails the schema ─────────────────────────────────────────────────────────
reset
printf '{ "id": "bad-shape", "label": "x" }\n' > "$fx/bad-shape.json"
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "invalid descriptor: exit non-zero" "$r" 1
has "invalid descriptor: named at the validate step" "$out" "FAIL bad-shape: validate:"
has "invalid descriptor: names the missing field" "$out" "detect: required field is missing"

# ── platform: a mismatch is a skip, never a failure ────────────────────────────────────────────
reset
fixture other-machine "exit 3" "false" "\"appliesWhen\": { \"platform\": { \"os\": \"$other_os\" } },"
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "platform mismatch: exit 0" "$r" 0
has "platform mismatch: skipped, with what it needs" "$out" "skip other-machine: platform: needs a $other_os machine"
has "platform mismatch: counted as skipped" "$out" "1 checked, 0 failed, 1 skipped"

# An extension predicate judges a repo, and no repo is under test: the recipe still runs.
reset
fixture needs-ext "$(good_install needs-ext)" "needs-ext-bin --version" '"appliesWhen": { "anyExtension": [".zzz"] },'
out="$(bash "$CHECK" --yes 2>/dev/null)"; r=$?
rc  "extension predicate: exit 0" "$r" 0
has "extension predicate: the recipe ran" "$out" "ok   needs-ext: install: npm"

# ── without --yes nothing installs ─────────────────────────────────────────────────────────────
reset
fixture healthy "$(good_install healthy)" "healthy-bin --version"
fixture broken-install "exit 3" "broken-install-bin --version"
out="$(bash "$CHECK" 2>/dev/null)"; r=$?
rc  "plan only: exit 0 even beside a broken recipe" "$r" 0
has "plan only: prints the candidate" "$out" "1. exit 3"
has "plan only: says how to run it" "$out" "skip healthy: install: plan only — pass --yes to run it"
r=0; [ -e "$HOME/.local/bin/healthy-bin" ] && r=1
rc  "plan only: nothing was installed" "$r" 0

# ── arguments ──────────────────────────────────────────────────────────────────────────────────
out="$(bash "$CHECK" --yes healthy 2>/dev/null)"; r=$?
rc  "one id: exit 0, the broken descriptor is not run" "$r" 0
has "one id: only that descriptor is counted" "$out" "integrations-check: 1 checked, 0 failed, 0 skipped"
out="$(bash "$CHECK" --yes no-such-tool 2>/dev/null)"; r=$?
rc  "unknown id: exit non-zero" "$r" 1
has "unknown id: named" "$out" "FAIL no-such-tool: validate: no descriptor with that id"
bash "$CHECK" --bogus >/dev/null 2>&1; rc "unknown flag: usage error" "$?" 2

# An inherited state dir must not receive this run's consent.
reset
fixture healthy "$(good_install healthy)" "healthy-bin --version"
KIT_STATE_DIR="$tmp/real-project-state" bash "$CHECK" --yes >/dev/null 2>&1
r=0; [ -e "$tmp/real-project-state" ] && r=1
rc  "consent: never written to an inherited KIT_STATE_DIR" "$r" 0

# ── every shipped descriptor has what the check runs ───────────────────────────────────────────
unset KIT_INTEGRATIONS_DIR
for f in "$ROOT"/integrations/*.json; do
  [ "$(basename "$f")" = "integration.schema.json" ] && continue
  jq -e '(.detect.run | type == "string") and (.verify.run | type == "string") and (.install | length > 0)' "$f" >/dev/null 2>&1
  rc "shipped $(basename "$f" .json): has detect, install and verify commands" "$?" 0
done
out="$(HOME="$tmp/home" bash "$CHECK" 2>/dev/null)"; r=$?
rc  "shipped descriptors: the plan-only run exits 0" "$r" 0
hasnt "shipped descriptors: none fails validation" "$out" "FAIL"

# ── the workflow ───────────────────────────────────────────────────────────────────────────────
wf="$(cat "$WF" 2>/dev/null)"
has "workflow: schedule trigger" "$wf" "schedule:"
grep -qE '^[[:space:]]*- cron: "[0-9]+ [0-9]+ [0-9]+ \* \*"' <<<"$wf"; rc "workflow: the cron is monthly (fixed day of month, every month)" "$?" 0
has "workflow: manual trigger" "$wf" "workflow_dispatch:"
has "workflow: may write issues" "$wf" "issues: write"
has "workflow: an arm64 macOS runner for mlx-lm" "$wf" "macos-15"
has "workflow: runs the check for real" "$wf" "bash scripts/integrations-check.sh --yes"
has "workflow: the issue step runs only on failure" "$wf" "if: failure()"
has "workflow: opens an issue" "$wf" "gh issue create"
if command -v ruby >/dev/null 2>&1; then
  ruby -ryaml -e 'y = YAML.load_file(ARGV[0]); t = y["on"] || y[true]; exit(t.key?("schedule") && t.key?("workflow_dispatch") && y["permissions"]["issues"] == "write" && y["jobs"]["check"]["strategy"]["matrix"]["os"].include?("macos-15") ? 0 : 1)' "$WF" 2>/dev/null
  rc "workflow: the YAML parses and holds the triggers, permission and runner" "$?" 0
else
  echo "ok: workflow YAML parse — ruby absent, skipped"
fi

if [ "$fail" -eq 0 ]; then echo "PASS integrations-check-test"; else echo "FAIL integrations-check-test"; fi
exit "$fail"
