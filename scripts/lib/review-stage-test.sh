#!/usr/bin/env bash
# review-stage-test.sh — the review DISPATCH contract (#346).
#
# Hermetic. The configured `review.command` is a shell script in a temp dir, so a real dispatch runs
# end to end — brief on stdin, report on stdout, receipt on disk — with no agent, no gh and no
# network. The one thing stubbed is ap_pr_context, which is the gh-touching half of resolution and
# already has its own coverage in agent-resolve-test.sh.
# Run:  bash scripts/lib/review-stage-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

command -v jq >/dev/null 2>&1 || { echo "review-stage-test: jq absent — skipping"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Point the receipt store at the temp dir BEFORE sourcing, so nothing writes into the real .cckit/.
export KIT_STATE_DIR="$tmp/state"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/review-stage.sh"

fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '[$2]' want '[$3]'"; fail=1; fi; }
has(){ case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '[$2]' lacks '$3'"; fail=1 ;; esac; }

CFG="$tmp/kit.config.json"
cat > "$CFG" <<'JSON'
{
  "review": { "command": "cat > /dev/null; printf 'outcome: pr-open\nurl: u\ngate: pass — read the diff\nblocker: none\nnext stage: none\n'" },
  "agents": {
    "default": "builder",
    "profiles": {
      "builder": { "kind": "claude", "stages": ["build"], "write": true },
      "critic":  { "kind": "codex",  "stages": ["review"], "tier": "low" },
      "writer":  { "kind": "claude", "stages": ["review"], "write": true }
    }
  }
}
JSON

# ── the off switch ─────────────────────────────────────────────────────────────────────────────
echo '{}' > "$tmp/none.json"
t  "no review.command is empty"        "$(rs_command "$tmp/none.json")" ""
rs_enabled "$tmp/none.json"; rc "a config with no review.command is off" "$?" "1"
rs_enabled "$CFG";           rc "a configured command is on"             "$?" "0"
t  "a missing config file is empty"    "$(rs_command "$tmp/absent.json")" ""

# ── when a PR earns a reviewer (pure) ──────────────────────────────────────────────────────────
rs_needs_dispatch merge 0;  rc "a mergeable PR with no receipt gets one" "$?" "0"
rs_needs_dispatch merge 1;  rc "a PR already reviewed does not"          "$?" "1"
rs_needs_dispatch verify 0; rc "a PR still verifying does not"           "$?" "1"
rs_needs_dispatch hold 0;   rc "a PR held by a policy floor does not"    "$?" "1"
rs_needs_dispatch rebase 0; rc "a conflicting PR does not"               "$?" "1"
rs_needs_dispatch '' 0;     rc "an empty action does not"                "$?" "1"

# ── the brief carries its three invariants ─────────────────────────────────────────────────────
b="$(rs_brief 'o/r' 7 42)"
has "the brief says no human is there" "$b" "HEADLESS"
has "the brief forbids writing"        "$b" "READ ONLY"
has "the brief names the PR"           "$b" "pull request #7"
has "the brief names the issue"        "$b" "issue #42"
# Without the closing block in sr_parse's shape, sr_record finds no outcome: and refuses the report.
for f in "outcome:" "gate:" "blocker:" "next stage:"; do
  has "the brief spells out '$f'" "$b" "$f"
done
# The brief must offer words sr_invalid_fields accepts. Telling a reviewer to say `shipped` records
# a receipt flagged invalid — recorded, but carrying a flag the captain then has to interpret.
for w in pr-open blocked pass fail; do
  has "the brief offers the real vocabulary word '$w'" "$b" "$w"
done

# ── dispatch ───────────────────────────────────────────────────────────────────────────────────
# The mirror is a network call. Off for the run so nothing here touches GitHub; the cases at the end
# assert that a dispatch still records a verdict with the mirror unavailable.
export CCKIT_RECEIPT_REMOTE=0
# ap_pr_context is the gh half; agent-resolve-test.sh covers it. Here it is fixed so the rest is real.
FX_CTX="42\t\t"
ap_pr_context() { printf "$FX_CTX\n"; }

rs_dispatch "$tmp/none.json" 'o/r' 7 42 >/dev/null 2>&1
rc "no configured command dispatches nothing" "$?" "4"

rs_dispatch "$CFG" 'o/r' 7 '' >/dev/null 2>&1
rc "a PR with no linked issue is refused" "$?" "2"

# agents.default is `builder`, which does not list the review stage — a build agent must not be
# handed a review just because it is the default.
rs_dispatch "$CFG" 'o/r' 7 42 >/dev/null 2>&1
rc "a default barred from the review stage refuses" "$?" "2"

# An agent: label naming a review profile that CAN write is refused before it ever runs.
FX_CTX="42\tagent:writer\t"
rs_dispatch "$CFG" 'o/r' 7 42 >/dev/null 2>&1
rc "a write:true review profile is refused" "$?" "2"

# The real path: a read-only review profile, the configured command, a receipt on disk.
FX_CTX="42\tagent:critic\t"
p="$(rs_dispatch "$CFG" 'o/r' 7 42)"
rc "a read-only review profile dispatches" "$?" "0"
[ -f "$p" ] && echo "ok: the receipt exists on disk" || { echo "FAIL: no receipt at '$p'"; fail=1; }
t "the receipt is at stage review"     "$(jq -r .stage       "$p")" "review"
t "the receipt names the profile"      "$(jq -r .profile     "$p")" "critic"
t "the receipt records the verdict"    "$(jq -r .outcome     "$p")" "pr-open"
t "the receipt records the gate"       "$(jq -r .gate        "$p" | cut -d' ' -f1)" "pass"
t "the receipt records read-only"      "$(jq -r .permissions "$p")" "read-only"
t "the receipt names the issue"        "$(jq -r .issue       "$p")" "42"
t "nothing is flagged invalid"         "$(jq -r '.invalid | length' "$p")" "0"

# The receipt is now findable, which is what closes the dispatch loop: a second pass must not
# re-review a PR that already has a verdict.
rs_have_receipt 42; rc "the verdict is findable afterwards" "$?" "0"
rs_have_receipt 99; rc "an unreviewed issue has none"       "$?" "1"
have=0; rs_have_receipt 42 && have=1
rs_needs_dispatch merge "$have"; rc "a reviewed PR is not dispatched twice" "$?" "1"

# A command that exits non-zero writes NO receipt — a failed reviewer must not look like a verdict.
cat > "$tmp/fail.json" <<'JSON'
{ "review": { "command": "exit 9" },
  "agents": { "default": "critic",
    "profiles": { "critic": { "kind": "codex", "stages": ["review"] } } } }
JSON
before="$(ls "$KIT_STATE_DIR/receipts" 2>/dev/null | wc -l | tr -d ' ')"
rs_dispatch "$tmp/fail.json" 'o/r' 8 55 >/dev/null 2>&1
rc "a failing review command is rc 3" "$?" "3"
t "a failing review command writes no receipt" \
  "$(ls "$KIT_STATE_DIR/receipts" 2>/dev/null | wc -l | tr -d ' ')" "$before"

# A command that succeeds but reports nothing parseable is sr_record's refusal, not a silent pass.
cat > "$tmp/mute.json" <<'JSON'
{ "review": { "command": "cat > /dev/null; echo 'looks fine to me'" },
  "agents": { "default": "critic",
    "profiles": { "critic": { "kind": "codex", "stages": ["review"] } } } }
JSON
rs_dispatch "$tmp/mute.json" 'o/r' 8 55 >/dev/null 2>&1
rc "a report with no outcome: line is refused" "$?" "2"
t "and it writes no receipt either" \
  "$(ls "$KIT_STATE_DIR/receipts" 2>/dev/null | wc -l | tr -d ' ')" "$before"

# ── the mirror never costs the verdict (#347) ──────────────────────────────────────────────────
# sr_mirror is best-effort: an unmirrored receipt is still the receipt the merge gate reads. Failing
# a dispatch on an offline mirror would stall every PR at `verify` over a visibility problem.
FX_CTX="42\tagent:critic\t"
# NOT a command substitution: SR_MIRROR_LAST_RESULT is set by sr_mirror in whatever shell runs it,
# and `$(rs_dispatch …)` would set it in a subshell that then exits. Redirect to a file instead.
rs_dispatch "$CFG" 'o/r' 7 42 > "$tmp/p2"
rc "a dispatch succeeds with the mirror off" "$?" "0"
p2="$(cat "$tmp/p2")"
t  "sr_mirror reported why it did not post" "$SR_MIRROR_LAST_RESULT" "no-remote"
[ -f "$p2" ] && echo "ok: the receipt is on disk anyway" || { echo "FAIL: no receipt at '$p2'"; fail=1; }
t  "and it is a second attempt, not an overwrite" "$(jq -r .attempt "$p2")" "2"
[ "$p2" != "$p" ] && echo "ok: the two attempts are separate files" || { echo "FAIL: attempt 2 reused $p"; fail=1; }

[ "$fail" -eq 0 ] && echo "review-stage-test: PASS" || echo "review-stage-test: FAILED"
exit "$fail"
