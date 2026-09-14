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
rs_needs_dispatch CLEAN merge 0;  rc "a mergeable PR with no receipt gets one" "$?" "0"
rs_needs_dispatch CLEAN merge 1;  rc "a PR already reviewed does not"          "$?" "1"
rs_needs_dispatch CHECKS_MISSING verify 0; rc "a PR still verifying does not"  "$?" "1"
rs_needs_dispatch HELD hold 0;    rc "a PR held by a policy floor does not"    "$?" "1"
rs_needs_dispatch CONFLICTING rebase 0; rc "a conflicting PR does not"         "$?" "1"
rs_needs_dispatch '' '' 0;        rc "an empty state and action does not"      "$?" "1"

# The deadlock (#351 review). REVIEW_MISSING is `verify`, not `merge`: a merge-only predicate meant
# that once review.command turned the requirement on, the FIRST pass classified every unreviewed PR
# REVIEW_MISSING, the reviewer never ran, and the PR sat at `verify` for good.
rs_needs_dispatch REVIEW_MISSING verify 0; rc "a PR blocked ON the missing review gets one" "$?" "0"
# Unless it already has a verdict — then REVIEW_MISSING means the verdict is stale, and a receipt
# the head check rejected sets have=0, so this case only arises from a caller that lost track.
rs_needs_dispatch REVIEW_MISSING verify 1; rc "but never twice for the same verdict" "$?" "1"
# A recorded FAIL is not re-reviewed on its own: the author acts on it and pushes, which changes the
# head, which makes the verdict stale, which is what earns the next review.
rs_needs_dispatch REVIEW_FAILING fix 1;    rc "a failing review is not re-run"       "$?" "1"

# The display placeholder must never reach receipt storage.
t "a real issue number passes through" "$(rs_issue_num 42)" "42"
t "the em-dash placeholder is empty"   "$(rs_issue_num '—')" ""
t "an empty field stays empty"         "$(rs_issue_num '')" ""
t "a non-numeric field is empty"       "$(rs_issue_num 'main')" ""

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
rs_needs_dispatch CLEAN merge "$have"; rc "a reviewed PR is not dispatched twice" "$?" "1"

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

# ── the PR review findings (#351) ──────────────────────────────────────────────────────────────

# The timeout bound. review.timeoutSeconds, with a default and a refusal to honour "no limit".
t "the default bound is 900s"        "$(rs_timeout "$CFG")" "900"
cat > "$tmp/to.json" <<'JSON'
{ "review": { "command": "true", "timeoutSeconds": 30 } }
JSON
t "a configured bound is used"       "$(rs_timeout "$tmp/to.json")" "30"
cat > "$tmp/tobad.json" <<'JSON'
{ "review": { "command": "true", "timeoutSeconds": "none" } }
JSON
# "none" reads like a request for NO limit. Honouring it would hand an unattended captain the hang
# the bound exists to prevent, so it falls back to the default instead.
t "a non-numeric bound falls back"   "$(rs_timeout "$tmp/tobad.json" 2>/dev/null)" "900"
cat > "$tmp/tozero.json" <<'JSON'
{ "review": { "command": "true", "timeoutSeconds": 0 } }
JSON
t "a zero bound falls back"          "$(rs_timeout "$tmp/tozero.json" 2>/dev/null)" "900"

# _rs_run actually kills a hung command, on whichever path this system takes.
start=$(date +%s)
printf 'ignored
' | _rs_run 2 'sleep 60' >/dev/null 2>&1
rc "a command past its bound is rc 124" "$?" "124"
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 30 ] && echo "ok: it was killed in ${elapsed}s, not left running" \
  || { echo "FAIL: still ran ${elapsed}s after a 2s bound"; fail=1; }
t "a command inside its bound returns its output" "$(printf '' | _rs_run 10 'echo alive' 2>/dev/null)" "alive"
printf '' | _rs_run 10 'exit 7' >/dev/null 2>&1
rc "a command's own exit code survives" "$?" "7"

# A dispatch whose reviewer hangs writes NO receipt — a killed reviewer is not a verdict.
cat > "$tmp/hang.json" <<'JSON'
{ "review": { "command": "sleep 60", "timeoutSeconds": 2 },
  "agents": { "default": "critic",
    "profiles": { "critic": { "kind": "codex", "stages": ["review"] } } } }
JSON
FX_CTX="77\t\t"
before2="$(ls "$KIT_STATE_DIR/receipts" 2>/dev/null | wc -l | tr -d ' ')"
rs_dispatch "$tmp/hang.json" 'o/r' 9 77 >/dev/null 2>&1
rc "a hung reviewer is rc 3" "$?" "3"
t "a hung reviewer writes no receipt" \
  "$(ls "$KIT_STATE_DIR/receipts" 2>/dev/null | wc -l | tr -d ' ')" "$before2"

# The resolved profile reaches the command. Without this an agent: label named a profile that only
# labelled the receipt, while the fixed command ran something else.
cat > "$tmp/env.json" <<'JSON'
{ "review": { "command": "cat > /dev/null; printf 'outcome: pr-open\nurl: u\ngate: pass — %s/%s\nblocker: none\nnext stage: none\n' $CCKIT_REVIEW_PROFILE $CCKIT_REVIEW_KIND" },
  "agents": { "default": "critic",
    "profiles": { "critic": { "kind": "codex", "stages": ["review"] } } } }
JSON
FX_CTX="78\t\t"
pe="$(rs_dispatch "$tmp/env.json" 'o/r' 9 78)"
t "the command sees the resolved profile and kind" \
  "$(jq -r .gate "$pe" | sed 's/^pass — //')" "critic/codex"

# head_sha binds a verdict to a revision (the stale-PASS hole).
FX_CTX="80\tagent:critic\t"
ph="$(rs_dispatch "$CFG" 'o/r' 9 80 'abc123')"
t "the receipt records the head it reviewed" "$(jq -r .head_sha "$ph")" "abc123"
rs_have_receipt 80 'abc123'; rc "the verdict counts for that head"        "$?" "0"
rs_have_receipt 80 'def456'; rc "it does NOT count for a later commit"    "$?" "1"
rs_have_receipt 80;          rc "with no head given, the issue alone counts" "$?" "0"

# A receipt written before head_sha existed has an empty field. Asked about a head it cannot match,
# it reads as absent — which is correct, and is why the gate skips the check on an empty head.
rs_have_receipt 42 'abc123'; rc "a head-less receipt does not cover a head" "$?" "1"
rs_have_receipt 42;          rc "but still counts when no head is asked"     "$?" "0"

[ "$fail" -eq 0 ] && echo "review-stage-test: PASS" || echo "review-stage-test: FAILED"
exit "$fail"
