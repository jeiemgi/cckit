#!/usr/bin/env bash
# shellcheck shell=bash
# loose-issues-test.sh — the loose-issue count (E546.2) over the forge shim: lib/core/loose-issues.sh
# and `cckit doctor --loose [--ratchet]`. Fixture: an effort, a sub-issue (parent_issue_url), a
# standalone issue, a pull request and a standalone issue labelled `backlog` -> one loose issue with
# the board off (the label parks it, #647). Then the board marker (Status = Backlog; the label is
# ignored with the board on),
# the ratchet (pass, fail, not judged), the forge-less run (a skip line, never a silent pass), the
# `cckit doctor` plumbing and the captain's wave close (captain_wave_close: over -> open, else advance).
# Run: bash lib/core/loose-issues-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/core/test-env.sh" && test_env_seal
DOCTOR="$ROOT/lib/verbs/kit-doctor.sh"
fail=0
t()     { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()   { if grep -qF -- "$3" <<<"$2"; then echo "ok: $1"; else echo "FAIL: $1 -> '$3' not in: $2"; fail=1; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then echo "FAIL: $1 -> '$3' found in: $2"; fail=1; else echo "ok: $1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "loose-issues-test: jq absent — skipping (dependency-light gate)"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"
# shellcheck source=/dev/null
. "$ROOT/lib/forge/test-forge-shim.sh"; forge_shim_install "$tmp/bin"
export PATH="$tmp/bin:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github
export GH_LOG="$tmp/gh.log"; : > "$GH_LOG"
export GH_ISSUES='[
  {"number":10,"title":"[Effort] 10 · demo","state":"open","labels":[{"name":"effort"}]},
  {"number":11,"title":"[Effort 10] 1 · a sub","state":"open","labels":[],"parent_issue_url":"https://api.github.com/repos/o/r/issues/10"},
  {"number":12,"title":"Fix the login","state":"open","labels":[{"name":"kind:fix"}],"parent_issue_url":null},
  {"number":13,"title":"a pull request","state":"open","labels":[],"pull_request":{}},
  {"number":14,"title":"Found during the demo","state":"open","labels":[],"body":"Found mid-wave.\n\n## Relations\n- Extends #10"},
  {"number":15,"title":"Parked for later","state":"open","labels":[{"name":"backlog"}],"parent_issue_url":null}
]'

# project <name> <config-json> -> a throwaway project (git repo, root cckit.config.json); echoes its dir.
project() {
  mkdir -p "$tmp/$1"
  git -C "$tmp/$1" init -q 2>/dev/null
  printf '%s\n' "$2" > "$tmp/$1/cckit.config.json"
  printf '%s\n' "$tmp/$1"
}
off="$(project off '{"github":{"repo":"o/r","projectsV2":false}}')"
on="$(project on '{"github":{"repo":"o/r","projectsV2":true,"projectNumber":3}}')"
doctor() { local d="$1"; shift; ( cd "$d" && KIT_ASCII=1 NO_COLOR=1 LC_ALL=C bash "$DOCTOR" "$@" </dev/null 2>"$tmp/err" ); }

# ── the library ───────────────────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$ROOT/lib/core/loose-issues.sh"
t   "repo: read from github.repo" "$(loose_repo "$off/cckit.config.json")" "o/r"
t   "board off: projectsV2 false" "$(loose_board_on "$off/cckit.config.json" && echo on || echo off)" "off"
t   "board off: an issue with a relation line is not loose" "$(loose_issues_list o/r "$off/cckit.config.json")" "$(printf '12\tFix the login')"
t   "board on: projectsV2 true + a number" "$(loose_board_on "$on/cckit.config.json" && echo on || echo off)" "on"
out="$(loose_issues_list o/r "$off/cckit.config.json")"
t   "effort, sub-issue, PR and backlog-labelled issue excluded -> the standalone issue alone" "$out" "$(printf '12\tFix the login')"
hasnt "board off: the backlog label parks #15" "$out" "15"
has "the read is GET repos/o/r/issues (open)" "$(cat "$GH_LOG")" "GET repos/o/r/issues?state=open&per_page=100"
t   "a read only: no write request" "$(grep -cvE '^GET ' "$GH_LOG")" "0"
GH_FAIL_EP='repos/o/r/issues' loose_issues_list o/r "$off/cckit.config.json" >/dev/null 2>&1; rc=$?
t   "a failed read -> rc 1, never zero loose" "$rc" "1"

# The board holds the Backlog marker: an issue whose Status is Backlog is not loose.
backlog='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":3},"fieldValueByName":{"name":"Backlog"}}]}}}}}'
todo='{"data":{"repository":{"issue":{"projectItems":{"nodes":[{"project":{"number":3},"fieldValueByName":{"name":"Todo"}}]}}}}}'
t   "board on, Status Backlog -> not loose" "$(GH_GRAPHQL="$backlog" loose_issues_list o/r "$on/cckit.config.json")" ""
t   "board on, Status Todo -> loose; the backlog label is ignored, #15 counts too" \
    "$(GH_GRAPHQL="$todo" loose_issues_list o/r "$on/cckit.config.json")" "$(printf '12\tFix the login\n15\tParked for later')"

# ── cckit doctor --loose ──────────────────────────────────────────────────────────────────────
out="$(doctor "$off" --loose)"; rc=$?
has "--loose: one row with the count" "$out" "warn  loose issues"
has "--loose: the count is 1" "$out" "1 in o/r"
has "--loose, board off: the label is the marker, and says so" "$out" "the Backlog marker is the backlog label"
hasnt "--loose, board off: the backlog-labelled issue is not listed" "$out" "#15 "
has "--loose: the list names #N title" "$out" "#12 Fix the login"
hasnt "--loose: the sub-issue is not listed" "$out" "#11 "
t   "--loose: exit 0 (a count, not a gate)" "$rc" "0"
out="$(GH_GRAPHQL="$backlog" doctor "$on" --loose)"
has "--loose, board on + Backlog: zero" "$out" "ok   loose issues                 0 in o/r"
out="$(GH_GRAPHQL="$todo" doctor "$on" --loose)"
has "--loose, board on + Todo: the backlog label does not park #15" "$out" "#15 Parked for later"
has "--loose, board on + Todo: the count is 2" "$out" "2 in o/r"

# ── the ratchet ───────────────────────────────────────────────────────────────────────────────
printf '# notes\n1\n' > "$tmp/at1"; printf '0\n' > "$tmp/at0"; printf '3\n' > "$tmp/at3"
out="$(doctor "$off" --loose --ratchet --baseline="$tmp/at1")"; rc=$?
t   "ratchet: count = baseline -> exit 0" "$rc" "0"
has "ratchet: says equal" "$out" "1 loose = baseline 1"
out="$(doctor "$off" --ratchet --baseline="$tmp/at0")"; rc=$?
t   "ratchet: count above baseline -> exit 1" "$rc" "1"
has "ratchet: names the rise" "$out" "1 loose > baseline 0"
out="$(doctor "$off" --ratchet --baseline="$tmp/at3")"; rc=$?
t   "ratchet: count below baseline -> exit 0" "$rc" "0"
has "ratchet: asks to lower the baseline" "$out" "lower the number in $tmp/at3 to 1"
out="$(doctor "$off" --ratchet --baseline="$tmp/none")"; rc=$?
t   "ratchet: no baseline -> exit 2, not judged" "$rc" "2"
has "ratchet: no baseline -> says so" "$out" "not judged — no number in"
t   "ratchet: the repo's own baseline file holds a number" \
    "$(loose_baseline_read "$ROOT/lib/core/loose-issues.baseline" | grep -cE '^[0-9]+$')" "1"

# ── no forge: skipped, said out loud ──────────────────────────────────────────────────────────
: > "$GH_LOG"
out="$(CCKIT_FORGE=none GH_TOKEN= doctor "$off" --loose)"; rc=$?
has "no forge: a skip line" "$out" "loose issues                 skipped — no forge"
t   "no forge: no request" "$(grep -c . "$GH_LOG")" "0"
t   "no forge, --loose: exit 0" "$rc" "0"
out="$(CCKIT_FORGE=none GH_TOKEN= doctor "$off" --ratchet --baseline="$tmp/at1")"; rc=$?
t   "no forge, --ratchet: exit 2, never a pass" "$rc" "2"
has "no forge, --ratchet: not judged" "$out" "not judged — the count was not read"

# ── bin/cckit plumbing: the flags reach kit-doctor.sh, and the default baseline is the repo's own ──
mkdir -p "$off/lib/core"; printf '# notes\n0\n' > "$off/lib/core/loose-issues.baseline"
out="$( cd "$off" && KIT_ASCII=1 NO_COLOR=1 LC_ALL=C bash "$ROOT/bin/cckit" doctor --loose --ratchet </dev/null 2>"$tmp/err" )"; rc=$?
t   "cckit doctor --loose --ratchet: default baseline lib/core/loose-issues.baseline -> exit 1" "$rc" "1"
has "cckit doctor --loose --ratchet: reads the default baseline" "$out" "1 loose > baseline 0"
out="$( cd "$off" && KIT_ASCII=1 NO_COLOR=1 LC_ALL=C bash "$ROOT/bin/cckit" doctor --loose --ratchet --baseline="$tmp/at1" </dev/null 2>"$tmp/err" )"; rc=$?
t   "cckit doctor --baseline=FILE reaches kit-doctor.sh -> exit 0" "$rc" "0"
rm -rf "$off/lib"

# ── the captain closes a wave through the ratchet (E632.5) ───────────────────────────────────
# captain_wave_close runs the real doctor over the shim: rc 1 = the wave stays open, rc 0 = advance.
close() { ( cd "$off" && . "$ROOT/lib/verbs/captain.sh" && KIT_ASCII=1 NO_COLOR=1 LC_ALL=C captain_wave_close ); }
out="$(CAPTAIN_LOOSE_BASELINE="$tmp/at0" close)"; rc=$?
t   "wave close: over the baseline -> rc 1, the wave stays open" "$rc" "1"
has "wave close: over -> says the wave stays open" "$out" "the wave stays open"
has "wave close: over -> lists the loose issue" "$out" "#12 Fix the login"
has "wave close: over -> says how to file it" "$out" "cckit effort sub"
out="$(CAPTAIN_LOOSE_BASELINE="$tmp/at1" close)"; rc=$?
t   "wave close: at the baseline -> rc 0, advances" "$rc" "0"
hasnt "wave close: at -> silent" "$out" "stays open"
out="$(CAPTAIN_LOOSE_BASELINE="$tmp/at3" close)"; rc=$?
t   "wave close: under the baseline -> rc 0, advances" "$rc" "0"
out="$(CCKIT_FORGE=none GH_TOKEN= CAPTAIN_LOOSE_BASELINE="$tmp/at0" close)"; rc=$?
t   "wave close: not judged (no forge) -> rc 0, advances" "$rc" "0"
has "wave close: not judged -> a note" "$out" "loose ratchet not judged"

[ "$fail" = "0" ] && echo "ALL OK (loose-issues)" || { echo "loose-issues: FAILURES"; exit 1; }
