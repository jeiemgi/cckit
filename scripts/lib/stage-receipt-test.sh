#!/usr/bin/env bash
# stage-receipt-test.sh — one durable receipt per stage attempt (#322).
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "stage-receipt-test: jq absent — skipping"; exit 0; }

# Every receipt lands in a scratch dir, never the real .cckit/.
KIT_STATE_DIR="$(mktemp -d)/state"; export KIT_STATE_DIR

# The GitHub mirror (#333) is ON by default, and `gh` is authenticated on a developer machine — an
# unguarded `sr_cli` case here would post real comments to the real repo from the test suite. Off
# for every case above; the mirror's own cases below stub `gh` and turn it back on explicitly.
CCKIT_RECEIPT_REMOTE=0; export CCKIT_RECEIPT_REMOTE
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/stage-receipt.sh"

fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
yes() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> missing '$3' in [$2]"; fail=1 ;; esac; }

REPORT="$(cat <<'EOF'
Here is what I did, at some length, which is not part of the receipt.

    outcome:    pr-open
    url:        https://github.com/jeiemgi/cckit/pull/999
    gate:       pass
    blocker:    none
    next stage: review
EOF
)"

# ── parsing E318.5's contract ──────────────────────────────────────────────────────────────────
p="$(printf '%s\n' "$REPORT" | sr_parse)"
t "outcome is parsed"    "$(printf '%s' "$p" | cut -f1)" "pr-open"
t "url is parsed"        "$(printf '%s' "$p" | cut -f2)" "https://github.com/jeiemgi/cckit/pull/999"
t "gate is parsed"       "$(printf '%s' "$p" | cut -f3)" "pass"
t "blocker is parsed"    "$(printf '%s' "$p" | cut -f4)" "none"
t "next stage is parsed" "$(printf '%s' "$p" | cut -f5)" "review"
# The worker's prose around the receipt must not become part of it.
t "surrounding prose is not captured" "$(printf '%s' "$p" | cut -f2)" "https://github.com/jeiemgi/cckit/pull/999"
# A worker that corrects itself means the correction; taking the first would record the retraction.
t "the LAST occurrence of a field wins" \
  "$(printf 'outcome: blocked\noutcome: merged\n' | sr_parse | cut -f1)" "merged"
t "next_stage with an underscore also parses" \
  "$(printf 'next_stage: docs\n' | sr_parse | cut -f5)" "docs"

# ── odd values are NAMED, not silently accepted ────────────────────────────────────────────────
t "a contract-shaped receipt has no invalid fields" "$(sr_invalid_fields pr-open pass review)" ""
t "an invented outcome is named"    "$(sr_invalid_fields shipped pass review)" "outcome"
t "an invented gate is named"       "$(sr_invalid_fields pr-open green review)" "gate"
t "an invented next stage is named" "$(sr_invalid_fields pr-open pass deploy)" "next_stage"
# `gate: fail — the failing check` keeps its detail; the failing check is the useful part.
t "gate detail after a fail is allowed" "$(sr_invalid_fields blocked "fail — shellcheck" none)" ""
sr_validate pr-open pass review 2>/dev/null; t "sr_validate passes a clean receipt" "$?" "0"
sr_validate shipped pass review 2>/dev/null; t "sr_validate is the hard-check form" "$?" "2"
yes "the hard check names the vocabulary" "$(sr_validate shipped pass review 2>&1)" "merged pr-open closed-no-op blocked"

# ── writing ────────────────────────────────────────────────────────────────────────────────────
t "the first attempt is 1" "$(sr_next_attempt 321 build)" "1"
out="$(printf '%s\n' "$REPORT" | sr_record 321 build 1 cheap low agents.default acceptEdits)"
t "the receipt is written where sr_path says" "$out" "$(sr_path 321 build 1)"
j="$(sr_read 321 build 1)"
t "the issue is recorded as a number" "$(printf '%s' "$j" | jq -r '.issue')" "321"
t "the five contract fields survive" \
  "$(printf '%s' "$j" | jq -r '[.outcome,.gate,.blocker,.next_stage] | join("|")')" "pr-open|pass|none|review"
# #326: a run's effective agent and policy must be auditable after the fact.
t "the resolved profile is recorded" \
  "$(printf '%s' "$j" | jq -r '[.profile,.tier,.profile_source,.permissions] | join("|")')" \
  "cheap|low|agents.default|acceptEdits"

# ── idempotence: a retry must not double the record ────────────────────────────────────────────
printf '%s\n' "$REPORT" | sr_record 321 build 1 cheap low agents.default acceptEdits >/dev/null
t "re-recording one attempt leaves one file" \
  "$(find "$(sr_dir)" -name '321-build-*.json' | wc -l | tr -d ' ')" "1"
t "a rewritten attempt keeps its content" "$(sr_read 321 build 1 | jq -r '.outcome')" "pr-open"

# A genuinely new try takes the next number, and neither attempt is lost.
t "the next attempt is 2" "$(sr_next_attempt 321 build)" "2"
printf 'outcome: blocked\nurl: -\ngate: fail — shellcheck\nblocker: needs a decision\nnext stage: none\n' \
  | sr_record 321 build 2 cheap low agents.default acceptEdits >/dev/null
t "both attempts are on disk" \
  "$(find "$(sr_dir)" -name '321-build-*.json' | wc -l | tr -d ' ')" "2"
t "attempt 1 is untouched by attempt 2" "$(sr_read 321 build 1 | jq -r '.outcome')" "pr-open"
t "sr_latest returns the newest attempt" "$(sr_latest 321 build | jq -r '.outcome')" "blocked"
t "a fail keeps which check failed" "$(sr_read 321 build 2 | jq -r '.gate')" "fail — shellcheck"

# ── an odd value is RECORDED and flagged, never discarded ──────────────────────────────────────
# Refusing would make "agent crashed" and "agent finished but said it oddly" look identical, and
# only the first needs the stage re-run. Keeping the value is what lets a wave keep moving.
printf 'outcome: shipped\nurl: https://x/1\ngate: pass\nblocker: none\nnext stage: review\n' \
  | sr_record 321 review 1 cheap low agents.default '' >/dev/null 2>&1
t "an odd receipt is still written" "$?" "0"
t "the odd value is kept verbatim" "$(sr_read 321 review 1 | jq -r '.outcome')" "shipped"
t "the offending field is named"   "$(sr_read 321 review 1 | jq -r '.invalid | join(",")')" "outcome"
t "a clean receipt flags nothing"  "$(sr_read 321 build 1 | jq -r '.invalid | length')" "0"
yes "sr_list surfaces the flag so a wave scan cannot miss it" "$(sr_list 321)" "invalid: outcome"

# The ONE hard refusal: a report with no outcome line is not an odd receipt, it is no receipt.
printf 'I could not figure this out.\n' | sr_record 321 docs 1 cheap low agents.default '' >/dev/null 2>&1
t "a report with no outcome line is refused" "$?" "2"
t "the refused report left no file" "$([ -f "$(sr_path 321 docs 1)" ] && echo yes || echo no)" "no"

# ── listing ────────────────────────────────────────────────────────────────────────────────────
t "sr_list rows one receipt each" "$(sr_list 321 | wc -l | tr -d ' ')" "3"
yes "sr_list names the outcome" "$(sr_list 321)" "pr-open"
t "sr_list of an unknown issue is empty" "$(sr_list 999 | wc -l | tr -d ' ')" "0"
t "sr_read of a missing receipt is rc 1" "$(sr_read 321 docs 1 >/dev/null 2>&1; echo $?)" "1"
t "sr_latest with no receipts is rc 1" "$(sr_latest 321 docs >/dev/null 2>&1; echo $?)" "1"

# ── the `cckit receipt` verb ───────────────────────────────────────────────────────────────────
# The WORKER records its own receipt: cckit never reads pane output, because #326 requires that
# pane history (off by default, may hold secrets) is never a dependency.
sr_cli 500 --stage build --profile cheap --tier low --source agents.default --permissions plan \
  <<'EOF' >/dev/null
outcome: pr-open
url: https://github.com/x/y/pull/1
gate: pass
blocker: none
next stage: review
EOF
t "the verb allocates the first attempt" "$(sr_read 500 build 1 | jq -r '.attempt')" "1"
t "the verb records the flags it was given" \
  "$(sr_read 500 build 1 | jq -r '[.profile,.tier,.profile_source,.permissions] | join("|")')" \
  "cheap|low|agents.default|plan"

# Retry after an unknown result: the SAME five fields must not become a second attempt.
sr_cli 500 --stage build <<'EOF' >/dev/null
outcome: pr-open
url: https://github.com/x/y/pull/1
gate: pass
blocker: none
next stage: review
EOF
t "an identical re-run rewrites its own attempt" \
  "$(find "$(sr_dir)" -name '500-build-*.json' | wc -l | tr -d ' ')" "1"

# A re-run that says something DIFFERENT is a real second try and keeps both records.
sr_cli 500 --stage build <<'EOF' >/dev/null
outcome: merged
url: https://github.com/x/y/pull/1
gate: pass
blocker: none
next stage: none
EOF
t "a changed re-run takes the next attempt" \
  "$(find "$(sr_dir)" -name '500-build-*.json' | wc -l | tr -d ' ')" "2"
t "the earlier attempt still says what it said" "$(sr_read 500 build 1 | jq -r '.outcome')" "pr-open"
t "show with no attempt gives the latest" "$(sr_cli show 500 build | jq -r '.outcome')" "merged"
t "show with an attempt gives that one" "$(sr_cli show 500 build 1 | jq -r '.outcome')" "pr-open"

sr_cli 500 --stage deploy </dev/null >/dev/null 2>&1; t "an unknown stage is refused" "$?" "2"
sr_cli 500 </dev/null >/dev/null 2>&1;                t "a missing --stage is refused" "$?" "2"
sr_cli abc --stage build </dev/null >/dev/null 2>&1;  t "a non-numeric issue is refused" "$?" "2"
sr_cli 500 --stage build --nope x </dev/null >/dev/null 2>&1; t "an unknown flag is refused" "$?" "2"
yes "the verb help names the stages" "$(sr_cli --help 2>&1)" "build review design docs none"

# ── the receipts dir is shared, not per-worktree ───────────────────────────────────────────────
# kit_state_dir anchors a relative override to the repo's shared root, so standing somewhere else
# must resolve to the SAME directory — a receipt a worker writes in its isolation worktree has to
# be readable by the captain.
here="$(sr_dir)"
there="$(cd /tmp && KIT_STATE_DIR="$KIT_STATE_DIR" bash -c "source '$ROOT/scripts/lib/stage-receipt.sh'; sr_dir")"
t "sr_dir is the same from another directory" "$there" "$here"

# ── the GitHub mirror (#333) ───────────────────────────────────────────────────────────────────
# `gh` is stubbed on PATH: it logs every invocation and serves a canned comment list, so the upsert
# is exercised end to end with no network and no real repo touched.
ghtmp="$(mktemp -d)"; mkdir -p "$ghtmp/bin"
export GH_LOG="$ghtmp/gh.log"; export GH_COMMENTS="$ghtmp/comments.txt"
: > "$GH_LOG"; : > "$GH_COMMENTS"
cat > "$ghtmp/bin/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$*" in
  *"issues/"*"/comments"*) cat "$GH_COMMENTS" ;;   # the listing (--jq is applied by the real gh)
  *) : ;;
esac
exit "${GH_RC:-0}"
SH
chmod +x "$ghtmp/bin/gh"
OLDPATH="$PATH"; PATH="$ghtmp/bin:$PATH"; export PATH

# ── pure: the marker is the identity, and it is per ATTEMPT ────────────────────────────────────
t "the marker keys on issue, stage and attempt" \
  "$(_sr_marker 42 build 2)" "<!-- cckit:receipt key=42-build-2 -->"
yes "a different attempt is a different marker" "$(_sr_marker 42 build 3)" "42-build-3"

# ── pure: matching finds only this receipt's own comment ───────────────────────────────────────
listing="$(printf '%s\t%s\n%s\t%s\n' \
  111 '"<!-- cckit:receipt key=42-build-1 --> other"' \
  222 '"<!-- cckit:receipt key=42-build-2 --> mine"')"
t "the matching attempt's comment id"  "$(printf '%s\n' "$listing" | _sr_mirror_match_id "$(_sr_marker 42 build 2)")" "222"
printf '%s\n' "$listing" | _sr_mirror_match_id "$(_sr_marker 42 build 9)" >/dev/null 2>&1
t "no match returns rc 1" "$?" "1"

# The receipt the mirror cases post. Written with the mirror off so this setup step posts nothing.
printf '%s\n' "$REPORT" | CCKIT_RECEIPT_REMOTE=0 sr_cli 42 --stage build --attempt 1 >/dev/null 2>&1

# ── a first mirror CREATES ─────────────────────────────────────────────────────────────────────
CCKIT_RECEIPT_REMOTE=1 sr_mirror 42 build 1 >/dev/null 2>&1
t "a first mirror creates" "$SR_MIRROR_LAST_RESULT" "created"
yes "and it commented on the issue" "$(cat "$GH_LOG")" "issue comment 42"

# ── the same attempt again EDITS the one comment, it does not append a second ──────────────────
printf '%s\t%s\n' 777 '"<!-- cckit:receipt key=42-build-1 --> already here"' > "$GH_COMMENTS"
: > "$GH_LOG"
CCKIT_RECEIPT_REMOTE=1 sr_mirror 42 build 1 >/dev/null 2>&1
t "a second identical run edits" "$SR_MIRROR_LAST_RESULT" "updated"
yes "and it PATCHed the existing comment" "$(cat "$GH_LOG")" "issues/comments/777"
t "it did not also create one" "$(grep -c 'issue comment' "$GH_LOG" || true)" "0"

# ── a FAILED lookup must not post: a blind post is how a duplicate appears ─────────────────────
: > "$GH_LOG"
GH_RC=1 CCKIT_RECEIPT_REMOTE=1 sr_mirror 42 build 1 >/dev/null 2>&1
t "a failed lookup does not post" "$SR_MIRROR_LAST_RESULT" "lookup-failed"
t "and nothing was created"       "$(grep -c 'issue comment' "$GH_LOG" || true)" "0"

# ── an unreachable GitHub still leaves the local file, and exits 0 ─────────────────────────────
GH_RC=1 CCKIT_RECEIPT_REMOTE=1 sr_mirror 42 build 1 >/dev/null 2>&1
t "an unreachable GitHub exits 0" "$?" "0"
t "and the local receipt is still there" "$([ -f "$(sr_path 42 build 1)" ] && echo yes)" "yes"

# ── --no-remote writes the file and posts nothing ──────────────────────────────────────────────
: > "$GH_LOG"
out="$(printf '%s\n' "$REPORT" | CCKIT_RECEIPT_REMOTE=1 sr_cli 43 --stage build --attempt 1 --no-remote 2>/dev/null)"
t "--no-remote still writes the receipt" "$([ -f "$out" ] && echo yes)" "yes"
t "--no-remote posts nothing"            "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
# SR_MIRROR_LAST_RESULT is checked on sr_mirror directly, not through sr_cli: a command
# substitution runs in a subshell, so a variable the callee sets never reaches this shell.

# ── CCKIT_RECEIPT_REMOTE=0 is the same switch, as an env var ───────────────────────────────────
: > "$GH_LOG"
CCKIT_RECEIPT_REMOTE=0 sr_mirror 42 build 1 >/dev/null 2>&1
t "the env var turns the mirror off" "$SR_MIRROR_LAST_RESULT" "no-remote"
t "and posts nothing"                "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

# ── the body carries the receipt verbatim ──────────────────────────────────────────────────────
body="$(_sr_mirror_body 42 build 1 "$(sr_path 42 build 1)")"
yes "the body carries its marker"   "$body" "<!-- cckit:receipt key=42-build-1 -->"
yes "the body names the stage"      "$body" 'stage `build`'
yes "the body embeds the JSON"      "$body" '"outcome": "pr-open"'

PATH="$OLDPATH"; export PATH
rm -rf "$ghtmp"


rm -rf "$(dirname "$KIT_STATE_DIR")"
[ "$fail" -eq 0 ] && echo "ALL OK" || echo "stage receipt: FAILURES"
exit "$fail"
