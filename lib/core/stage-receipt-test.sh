#!/usr/bin/env bash
# stage-receipt-test.sh — one durable receipt per stage attempt (#322).
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
command -v jq >/dev/null 2>&1 || { echo "stage-receipt-test: jq absent — skipping"; exit 0; }

# Every receipt lands in a scratch dir, never the real .cckit/.
KIT_STATE_DIR="$(mktemp -d)/state"; export KIT_STATE_DIR

# The GitHub mirror (#333) is ON by default, and a forge token is usually at hand on a developer machine — an
# unguarded `sr_cli` case here would post real comments to the real repo from the test suite. Off
# for every case above; the mirror's own cases below put the forge shim on PATH and turn it back on explicitly.
CCKIT_RECEIPT_REMOTE=0; export CCKIT_RECEIPT_REMOTE
# shellcheck source=/dev/null
source "$ROOT/lib/core/stage-receipt.sh"

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
printf 'outcome: pr-open\nurl: -\ngate: pass\nblocker: none\nnext stage: none\n' \
  | sr_cli 501 --stage qa --no-remote >/dev/null 2>&1; t "qa is a stage a receipt can be recorded at" "$?" "0"
t "a qa receipt reads back by its stage" "$(sr_cli show 501 qa | jq -r '.stage')" "qa"
t "qa is a next stage a receipt may name" "$(sr_invalid_fields pr-open pass qa)" ""
# zsh aborts on a glob that matches nothing; the first receipt of a NEW stage for an issue is
# exactly that case once the receipts directory exists (#299 hit it recording a qa verdict).
if command -v zsh >/dev/null 2>&1; then
  out="$(KIT_STATE_DIR="$KIT_STATE_DIR" zsh -c "source '$ROOT/lib/core/stage-receipt.sh'; sr_next_attempt 500 docs; sr_next_attempt 500 build; sr_list 777 | wc -l | tr -d ' '" 2>&1)"
  t "zsh: attempts count with and without a matching receipt, and an empty list is empty" \
    "$(printf '%s' "$out" | tr '\n' ' ')" "1 3 0"
else
  echo "ok: zsh absent — skipping the zsh receipt pass (dependency-light gate)"
fi
yes "the verb help names the stages" "$(sr_cli --help 2>&1)" "build review design docs qa none"

# ── the receipts dir is shared, not per-worktree ───────────────────────────────────────────────
# kit_state_dir anchors a relative override to the repo's shared root, so standing somewhere else
# must resolve to the SAME directory — a receipt a worker writes in its isolation worktree has to
# be readable by the captain.
here="$(sr_dir)"
there="$(cd /tmp && KIT_STATE_DIR="$KIT_STATE_DIR" bash -c "source '$ROOT/lib/core/stage-receipt.sh'; sr_dir")"
t "sr_dir is the same from another directory" "$there" "$here"

# ── the GitHub mirror (#333) ───────────────────────────────────────────────────────────────────
# The forge shim (test-forge-shim.sh) stands in for GitHub: its curl logs every request as
# `METHOD path {json}` and a fixture serves the canned comment list from $GH_COMMENTS (one
# `<id><TAB><json body>` line per comment), so the upsert is exercised end to end with no network and
# no real repo touched. GH_RC=1 makes every request fail (502).
ghtmp="$(mktemp -d)"; mkdir -p "$ghtmp/bin"
# shellcheck source=/dev/null
. "$ROOT/lib/forge/test-forge-shim.sh"; forge_shim_install "$ghtmp/bin"
export GH_LOG="$ghtmp/gh.log"; export GH_COMMENTS="$ghtmp/comments.txt"; export GH_FIXTURE="$ghtmp/fixture"
export GH_TOKEN=test-token CCKIT_FORGE=github SR_REPO=o/r
: > "$GH_LOG"; : > "$GH_COMMENTS"
cat > "$GH_FIXTURE" <<'FIX'
if [ "${GH_RC:-0}" != 0 ]; then code=502; out='{"message":"Server Error"}'
else
  case "$method $ep" in
    "GET repos/o/r/issues/"*"/comments")
      out="$(jq -R 'split("\t") | {id: (.[0] | tonumber), body: (.[1] | fromjson)}' "$GH_COMMENTS" | jq -sc .)" ;;
    "PATCH repos/o/r/issues/comments/"*) out="{\"id\":${ep##*/}}" ;;
  esac
fi
FIX
OLDPATH="$PATH"; PATH="$ghtmp/bin:$PATH"; export PATH
CREATE='^POST repos/o/r/issues/42/comments '

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
yes "and it commented on the issue" "$(cat "$GH_LOG")" "POST repos/o/r/issues/42/comments "
yes "the comment carries the marker" "$(cat "$GH_LOG")" "cckit:receipt key=42-build-1"
t "the lookup read the issue's comments over REST" "$(grep -c '^GET repos/o/r/issues/42/comments' "$GH_LOG")" "1"

# ── the same attempt again EDITS the one comment, it does not append a second ──────────────────
printf '%s\t%s\n' 777 '"<!-- cckit:receipt key=42-build-1 --> already here"' > "$GH_COMMENTS"
: > "$GH_LOG"
CCKIT_RECEIPT_REMOTE=1 sr_mirror 42 build 1 >/dev/null 2>&1
t "a second identical run edits" "$SR_MIRROR_LAST_RESULT" "updated"
yes "and it PATCHed the existing comment" "$(cat "$GH_LOG")" "PATCH repos/o/r/issues/comments/777 "
t "it did not also create one" "$(grep -c "$CREATE" "$GH_LOG" || true)" "0"

# ── a FAILED lookup must not post: a blind post is how a duplicate appears ─────────────────────
: > "$GH_LOG"
GH_RC=1 CCKIT_RECEIPT_REMOTE=1 sr_mirror 42 build 1 >/dev/null 2>&1
t "a failed lookup does not post" "$SR_MIRROR_LAST_RESULT" "lookup-failed"
t "and nothing was created"       "$(grep -c "$CREATE" "$GH_LOG" || true)" "0"

# ── no forge configured: the receipt stays local, the result says so, nothing is asked ─────────
: > "$GH_LOG"
( unset _FORGE_LOADED; CCKIT_FORGE=none CCKIT_RECEIPT_REMOTE=1 sr_mirror 42 build 1 >/dev/null 2>&1 ); t "no forge exits 0" "$?" "0"
noforge="$(unset _FORGE_LOADED; CCKIT_FORGE=none CCKIT_RECEIPT_REMOTE=1 sr_mirror 42 build 1 2>&1 >/dev/null; printf '|%s' "$SR_MIRROR_LAST_RESULT")"
t "no forge is the recorded result"  "${noforge##*|}" "no-forge"
yes "no forge says the receipt stayed local" "$noforge" "no forge is configured — receipt written locally only"
t "no forge makes no request"        "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

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

t "no gh subcommand ran in the mirror cases" "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"
PATH="$OLDPATH"; export PATH
unset GH_FIXTURE SR_REPO
rm -rf "$ghtmp"


# ── the agent trail (#572): a step report becomes one short comment on its issue ───────────────
# The forge shim records every request with its JSON body. Synthetic leak words only: the real
# list is private and never appears in a test.
trtmp="$(mktemp -d)"; mkdir -p "$trtmp/bin"
forge_shim_install "$trtmp/bin"
export GH_LOG="$trtmp/gh.log" GH_COMMENTS="$trtmp/comments.txt" GH_FIXTURE="$trtmp/fixture"
export GH_TOKEN=test-token CCKIT_FORGE=github SR_REPO=o/r
printf 'zorblaxian\n# a comment line\nquuxcorp\n' > "$trtmp/leak-words"
CCKIT_LEAK_WORDS_FILE="$trtmp/leak-words"; export CCKIT_LEAK_WORDS_FILE; unset CCKIT_LEAK_WORDS
: > "$GH_LOG"; : > "$GH_COMMENTS"
cat > "$GH_FIXTURE" <<'FIX'
case "$method $ep" in
  "GET repos/o/r/issues/"*"/comments")
    out="$(jq -R 'split("\t") | {id: (.[0] | tonumber), body: (.[1] | fromjson)}' "$GH_COMMENTS" | jq -sc .)" ;;
  "PATCH repos/o/r/issues/comments/"*) out="{\"id\":${ep##*/}}" ;;
esac
FIX
PATH="$trtmp/bin:$OLDPATH"; export PATH
# The suite keeps CCKIT_RECEIPT_REMOTE=0 so nothing else can post; the trail cases turn it on over
# the shim, and one case checks that off means not posted.
CCKIT_RECEIPT_REMOTE=1; export CCKIT_RECEIPT_REMOTE
TRAIL_POST='^POST repos/o/r/issues/77/comments '

REP="$trtmp/2026-11-24-1200-build-77.md"
cat > "$REP" <<'EOF'
# Build 77

## Status
Built and gated; PR open.
Second status line.

## Done
- one commit, see https://github.com/o/r/pull/12.
- the issue https://github.com/o/r/issues/77

## Waiting for a yes
- merge the PR

## Numbers
check.sh 120 passed

## Next step
review
EOF

out="$(CCKIT_RECEIPT_REMOTE=0 sr_cli 77 --report "$REP" 2>&1)"
yes "CCKIT_RECEIPT_REMOTE=0 says the comment was not posted" "$out" "the comment was NOT posted to #77"
t "CCKIT_RECEIPT_REMOTE=0 makes no request" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

out="$(sr_cli 77 --report "$REP" 2>&1)"; rc=$?
t "a report posts with rc 0" "$rc" "0"
yes "the verb says it posted" "$out" "trail comment posted on #77"
posted="$(grep "$TRAIL_POST" "$GH_LOG")"
t "exactly one comment was posted" "$(printf '%s\n' "$posted" | grep -c .)" "1"
yes "the comment carries the Status head"   "$posted" "Built and gated; PR open."
yes "the comment carries the PR URL, trailing dot dropped" "$posted" "- https://github.com/o/r/pull/12\\n"
yes "the comment carries the issue URL"     "$posted" "https://github.com/o/r/issues/77"
yes "the comment carries the waiting items" "$posted" "- merge the PR"
yes "the comment names the report file"     "$posted" 'Full report: `2026-11-24-1200-build-77.md`'
yes "the comment carries its trail marker"  "$posted" "cckit:trail report=2026-11-24-1200-build-77.md"
case "$posted" in *"check.sh 120 passed"*) t "the Numbers section stays in the full report" "present" "absent" ;;
  *) t "the Numbers section stays in the full report" "absent" "absent" ;; esac
case "$posted" in *"$trtmp"*) t "no absolute path reaches the comment" "present" "absent" ;;
  *) t "no absolute path reaches the comment" "absent" "absent" ;; esac

# The same report again edits its comment instead of appending a second.
printf '%s\t%s\n' 901 '"<!-- cckit:trail report=2026-11-24-1200-build-77.md --> earlier"' > "$GH_COMMENTS"
: > "$GH_LOG"
yes "a second post of one report edits" "$(sr_cli 77 --report "$REP" 2>&1)" "updated"
yes "and it PATCHed the existing comment" "$(cat "$GH_LOG")" "PATCH repos/o/r/issues/comments/901 "
t "it did not also create one" "$(grep -c "$TRAIL_POST" "$GH_LOG" || true)" "0"
: > "$GH_COMMENTS"

# No waiting items reads "none".
NOW="$trtmp/no-wait.md"; printf '## Status\nAll done.\n\n## Done\n- x\n' > "$NOW"
yes "no Waiting section reads none" "$(sr_cli 77 --report "$NOW" --dry-run 2>/dev/null)" "$(printf '**Waiting for a yes**\nnone')"

# Truncation: a long report is cut to the cap, says so, and still names the file last.
LONG="$trtmp/long.md"
{ printf '## Status\nlong one\n\n## Waiting for a yes\n'; i=0; while [ "$i" -lt 80 ]; do printf -- '- decision number %s needs an answer from the owner\n' "$i"; i=$((i+1)); done; } > "$LONG"
long="$(sr_cli 77 --report "$LONG" --dry-run 2>/dev/null)"
t "a long comment stays within the cap" "$([ "${#long}" -le 1500 ] && echo yes || echo "no (${#long})")" "yes"
yes "a cut comment says it was truncated" "$long" "Truncated to 1500 characters"
t "a cut comment's last line names the file" "$(printf '%s\n' "$long" | tail -n 1)" 'Full report: `long.md` (local, not on GitHub)'

# A leak-list word refuses the whole comment, posts nothing, and does not echo the word.
LEAK="$trtmp/leak.md"; printf '## Status\nShipped the QuuxCorp import.\n' > "$LEAK"
: > "$GH_LOG"
out="$(sr_cli 77 --report "$LEAK" 2>&1)"; rc=$?
t "a leak word is refused with rc 1" "$rc" "1"
yes "the refusal names the leak list" "$out" "private leak list"
case "$out" in *[Qq]uux[Cc]orp*) t "the refusal does not echo the word" "echoed" "hidden" ;;
  *) t "the refusal does not echo the word" "hidden" "hidden" ;; esac
t "a refused comment posts nothing" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
sr_cli 77 --report "$LEAK" --dry-run >/dev/null 2>&1; t "dry run refuses a leak word too" "$?" "1"

# A link to the DESTINATION repository is not a leak, even when its owner/repo carries a leak-list
# word: the comment lands on that repository, so the link reveals nothing it does not hold (#672).
# Synthetic destination `o/zorblaxian`; the exemption covers a URL and an `owner/repo#N` reference,
# and nothing else — the same word in prose, in another repository's URL or in a path segment
# after `owner/repo` still refuses.
OWN="$trtmp/own.md"
printf '## Status\nShipped; see https://github.com/o/Zorblaxian/pull/12 and o/zorblaxian#5.\n' > "$OWN"
: > "$GH_LOG"
out="$(SR_REPO=o/zorblaxian sr_cli 77 --report "$OWN" --dry-run 2>&1)"; rc=$?
t "a link to the destination repo is not refused" "$rc" "0"
yes "the comment carries the destination repo URL" "$out" "- https://github.com/o/Zorblaxian/pull/12"
yes "the comment carries the destination repo ref" "$out" "o/zorblaxian#5"
OWNER="$trtmp/owner.md"; printf '## Status\nSee https://github.com/quuxcorp/r/issues/3\n' > "$OWNER"
SR_REPO=quuxcorp/r sr_cli 77 --report "$OWNER" --dry-run >/dev/null 2>&1
t "a leak word as the destination OWNER is not refused" "$?" "0"
out="$(SR_REPO=o/r sr_cli 77 --report "$OWN" 2>&1)"; rc=$?
t "the same link to ANOTHER repo is refused" "$rc" "1"
yes "and the refusal names the leak list" "$out" "private leak list"
t "and it posts nothing" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
PROSE="$trtmp/prose.md"
printf '## Status\nzorblaxian shipped; see https://github.com/o/zorblaxian/pull/12\n' > "$PROSE"
out="$(SR_REPO=o/zorblaxian sr_cli 77 --report "$PROSE" 2>&1)"; rc=$?
t "the destination repo word in prose is refused" "$rc" "1"
case "$out" in *[Zz]orblaxian*) t "the prose refusal does not echo the word" "echoed" "hidden" ;;
  *) t "the prose refusal does not echo the word" "hidden" "hidden" ;; esac
t "the prose refusal posts nothing" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
SEG="$trtmp/segment.md"; printf '## Status\nSee https://github.com/o/r/blob/main/zorblaxian.md\n' > "$SEG"
SR_REPO=o/r sr_cli 77 --report "$SEG" --dry-run >/dev/null 2>&1
t "the word in a path segment after owner/repo is refused" "$?" "1"
GLUED="$trtmp/glued.md"; printf '## Status\nSee https://github.com/o/zorblaxian-private/pull/1\n' > "$GLUED"
SR_REPO=o/zorblaxian sr_cli 77 --report "$GLUED" --dry-run >/dev/null 2>&1
t "a repo whose name merely starts with the destination is refused" "$?" "1"

# An absolute home path is refused the same way.
HOMEP="$trtmp/home.md"; printf '## Status\nlog at /Users/alice/work/log.txt\n' > "$HOMEP"
out="$(sr_cli 77 --report "$HOMEP" 2>&1)"; rc=$?
t "a home path is refused with rc 1" "$rc" "1"
yes "the refusal names the home path" "$out" "absolute home path"
t "a home-path comment posts nothing" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

# --dry-run prints and writes nothing.
: > "$GH_LOG"
dry="$(sr_cli 77 --report "$REP" --dry-run 2>/dev/null)"; rc=$?
t "dry run exits 0" "$rc" "0"
yes "dry run prints the comment" "$dry" "Built and gated; PR open."
t "dry run makes no request" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

# No forge: the comment is not posted, the verb says so and prints it.
: > "$GH_LOG"
out="$(unset _FORGE_LOADED; CCKIT_FORGE=none sr_cli 77 --report "$REP" 2>&1)"; rc=$?
t "no forge exits 0" "$rc" "0"
yes "no forge says the comment was not posted" "$out" "the comment was NOT posted to #77"
yes "no forge still prints the comment" "$out" "Built and gated; PR open."
t "no forge makes no request" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

# Usage errors.
NOST="$trtmp/nostatus.md"; printf '## Done\n- x\n' > "$NOST"
sr_cli 77 --report "$NOST" --dry-run >/dev/null 2>&1; t "a report with no Status is refused" "$?" "2"
sr_cli 77 --report "$trtmp/missing.md" >/dev/null 2>&1; t "a missing report is refused" "$?" "2"
sr_cli 77 --report </dev/null >/dev/null 2>&1;  t "--report with no file is refused" "$?" "2"
sr_cli 77 --stage build --dry-run </dev/null >/dev/null 2>&1; t "--dry-run without --report is refused" "$?" "2"
yes "the help names the trail mode" "$(sr_cli --help 2>&1)" "--report <file> [--dry-run]"

t "no gh subcommand ran in the trail cases" "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG" || true)" "0"
PATH="$OLDPATH"; export PATH
unset GH_FIXTURE SR_REPO CCKIT_LEAK_WORDS_FILE
CCKIT_RECEIPT_REMOTE=0; export CCKIT_RECEIPT_REMOTE
rm -rf "$trtmp"

rm -rf "$(dirname "$KIT_STATE_DIR")"
[ "$fail" -eq 0 ] && echo "ALL OK" || echo "stage receipt: FAILURES"
exit "$fail"
