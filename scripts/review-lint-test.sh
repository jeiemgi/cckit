#!/usr/bin/env bash
# review-lint-test.sh — behavioral test for the codified-review-findings gate.
# Builds a throwaway repo with its own rule table and asserts the engine contract: scope/exclude
# selection, code_only and ignore filtering, both rule kinds (regex + stateful awk), and the
# per-file ratchet (new hit fails, baselined hit passes, growth fails).
set -uo pipefail

ENGINE="$(cd "$(dirname "$0")" && pwd)/review-lint.sh"
fails=0
pass() { echo "ok $1"; }
fail() { echo "FAIL $1"; fails=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/lib" "$TMP/docs"
cp "$ENGINE" "$TMP/scripts/"

( cd "$TMP" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1

# Capture rather than pipe: `run | grep -q` lets grep exit early, kills `run` with SIGPIPE, and
# under `set -o pipefail` reports the pipeline as failed even on a successful match.
run() { ( cd "$TMP" && bash scripts/review-lint.sh "$@" 2>&1 ); }
run_out=""; run_rc=0
capture() { run_out="$(run "$@")"; run_rc=$?; }
track() { ( cd "$TMP" && git add -A . >/dev/null 2>&1 ); }

cat > "$TMP/scripts/review-rules.conf" <<'CONF'
[T001]
title: no bare TODO markers
why: test rule
scope: lib/*
exclude: *-test.sh
code_only: true
ignore: ALLOWED
pattern: TODO
source: test

[T002]
title: fenced block needs a language
why: test rule
kind: awk
scope: docs/*
awk: FNR==1{inb=0;fence=""} match($0,/^[ \t]*(`{3,}|~{3,})/){m=substr($0,RSTART,RLENGTH);sub(/^[ \t]+/,"",m);rest=substr($0,RSTART+RLENGTH);sub(/^[ \t]+/,"",rest);sub(/[ \t]+$/,"",rest);if(!inb){inb=1;fence=m;if(rest=="")print FILENAME":"FNR":"$0}else if(substr(m,1,1)==substr(fence,1,1)&&length(m)>=length(fence)&&rest==""){inb=0;fence=""}}
source: test
CONF

# --- 1. clean tree passes ----------------------------------------------------
echo 'echo hi' > "$TMP/lib/clean.sh"; track
capture
[ "$run_rc" -eq 0 ] && pass "clean tree passes" || fail "clean tree passes (rc=$run_rc: $run_out)"

# --- 2. scope: a hit OUTSIDE the rule's scope is ignored ---------------------
echo 'x=1 # TODO' > "$TMP/scripts/out-of-scope.sh"; track
capture
[ "$run_rc" -eq 0 ] && pass "out-of-scope file ignored" || fail "out-of-scope file ignored"

# --- 3. a real in-scope hit fails -------------------------------------------
echo 'x=1  TODO' > "$TMP/lib/bad.sh"; track
capture
if [ "$run_rc" -ne 0 ] && printf '%s' "$run_out" | grep -q 'T001.*lib/bad.sh'; then
  pass "in-scope hit fails"
else
  fail "in-scope hit fails (rc=$run_rc: $run_out)"
fi

# --- 4. exclude: same content in an excluded file is ignored ----------------
rm "$TMP/lib/bad.sh"; echo 'x=1  TODO' > "$TMP/lib/thing-test.sh"; track
capture
[ "$run_rc" -eq 0 ] && pass "exclude pattern honored" || fail "exclude pattern honored ($run_out)"

# --- 5. code_only: a FULL-LINE comment is not a hit -------------------------
rm "$TMP/lib/thing-test.sh"; printf '   # TODO later\n' > "$TMP/lib/c.sh"; track
capture
[ "$run_rc" -eq 0 ] && pass "code_only skips full-line comments" || fail "code_only skips full-line comments ($run_out)"

# --- 6. ignore: a line matching the ignore ERE is not a hit -----------------
printf 'x=1 TODO ALLOWED\n' > "$TMP/lib/c.sh"; track
capture
[ "$run_rc" -eq 0 ] && pass "ignore pattern honored" || fail "ignore pattern honored ($run_out)"

# --- 7. awk kind: OPENING bare fence is a hit, closing fence is not ---------
rm "$TMP/lib/c.sh"
printf 'intro\n```\ncode\n```\n' > "$TMP/docs/a.md"; track
n="$(run --rule T002 | grep -c 'docs/a.md:' || true)"
[ "$n" -eq 1 ] && pass "awk rule counts opening fence only (got $n)" \
               || fail "awk rule counts opening fence only (expected 1, got $n)"

# --- 8. awk kind: a LABELLED fence is clean --------------------------------
printf 'intro\n```bash\ncode\n```\n' > "$TMP/docs/a.md"; track
capture
[ "$run_rc" -eq 0 ] && pass "labelled fence is clean" || fail "labelled fence is clean ($run_out)"

# --- 9. awk state resets per file (no parity bleed across files) ------------
printf 'a\n```sh\nx\n```\n' > "$TMP/docs/a.md"
printf 'b\n```sh\ny\n```\n' > "$TMP/docs/b.md"; track
capture
[ "$run_rc" -eq 0 ] && pass "awk state resets per file" || fail "awk state resets per file ($run_out)"

# --- 10. baseline grandfathers an existing hit ------------------------------
printf 'a\n```\nx\n```\n' > "$TMP/docs/a.md"; track
run --update >/dev/null 2>&1
capture
[ "$run_rc" -eq 0 ] && pass "baselined hit is grandfathered" || fail "baselined hit is grandfathered ($run_out)"

# --- 11. ...but growth in that same file fails ------------------------------
printf 'a\n```\nx\n```\n\n```\ny\n```\n' > "$TMP/docs/a.md"; track
capture
if [ "$run_rc" -ne 0 ] && printf '%s' "$run_out" | grep -q 'grew to'; then
  pass "growth past baseline fails"
else
  fail "growth past baseline fails (rc=$run_rc: $run_out)"
fi

# --- 12. a NEW file with a hit fails even while another is baselined --------
printf 'a\n```\nx\n```\n' > "$TMP/docs/a.md"
printf 'c\n```\nz\n```\n' > "$TMP/docs/c.md"; track
capture
if [ "$run_rc" -ne 0 ] && printf '%s' "$run_out" | grep -q 'docs/c.md'; then
  pass "new offending file fails despite baseline"
else
  fail "new offending file fails despite baseline (rc=$run_rc: $run_out)"
fi

# --- 13. untracked files are invisible (git ls-files is the source) --------
rm "$TMP/docs/c.md"; track
printf 'u\n```\nz\n```\n' > "$TMP/docs/untracked.md"   # deliberately NOT added
capture
[ "$run_rc" -eq 0 ] && pass "untracked files are not scanned" || fail "untracked files are not scanned ($run_out)"

# --- 14. the rule table never matches itself -------------------------------
# review-rules.conf quotes the patterns it describes, so scanning it makes every rule self-match.
# Own temp repo: this must assert on WHICH paths are reported, not on the exit code.
TMP3="$(mktemp -d)"; mkdir -p "$TMP3/scripts" "$TMP3/lib"
cp "$ENGINE" "$TMP3/scripts/"
( cd "$TMP3" && git init -q . ) >/dev/null 2>&1
cat > "$TMP3/scripts/review-rules.conf" <<'CONF'
[selfmatch]
title: no SENTINEL_TOKEN
why: the word SENTINEL_TOKEN appears in this very table
scope: scripts/*, lib/*
pattern: SENTINEL_TOKEN
source: test
CONF
echo 'x=SENTINEL_TOKEN' > "$TMP3/lib/real.sh"
out3="$( cd "$TMP3" && bash scripts/review-lint.sh 2>&1 )"
if printf '%s' "$out3" | grep -q 'review-rules.conf'; then
  fail "rule table is not linted against itself (self-matched: $out3)"
elif printf '%s' "$out3" | grep -q 'lib/real.sh'; then
  pass "rule table is skipped while real files still match"
else
  fail "rule table is not linted against itself (real hit missed: $out3)"
fi
rm -rf "$TMP3"

# --- 15. untracked-but-present files are scanned when NOTHING is tracked ---
# A freshly scaffolded project has files on disk and an empty index; the gate must still see them.
TMP2="$(mktemp -d)"; mkdir -p "$TMP2/scripts" "$TMP2/docs"
cp "$ENGINE" "$TMP2/scripts/"; cp "$TMP/scripts/review-rules.conf" "$TMP2/scripts/"
( cd "$TMP2" && git init -q . ) >/dev/null 2>&1
printf 'a\n```\nx\n```\n' > "$TMP2/docs/a.md"     # never `git add`ed
out2="$( cd "$TMP2" && bash scripts/review-lint.sh 2>&1 )"; rc2=$?
if [ "$rc2" -ne 0 ] && printf '%s' "$out2" | grep -q 'docs/a.md'; then
  pass "scans on-disk files when the index is empty"
else
  fail "scans on-disk files when the index is empty (rc=$rc2: $out2)"
fi
rm -rf "$TMP2"

# --- 16. a path containing a space keeps its own baseline row --------------
# `uniq -c | awk '{ print $2, $1 }'` keeps only the first whitespace token, so `docs/my file.md`
# is recorded as `docs/my` — and a second file sharing that prefix lands on the SAME row, so its
# hits are compared against the first file's count and pass unnoticed.
TMP4="$(mktemp -d)"; mkdir -p "$TMP4/scripts" "$TMP4/docs"
cp "$ENGINE" "$TMP4/scripts/"; cp "$TMP/scripts/review-rules.conf" "$TMP4/scripts/"
( cd "$TMP4" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf '```\nx\n```\n'                 > "$TMP4/docs/my file.md"    # 1 bare opener
printf '```\ny\n```\nz\n```\nw\n```\n' > "$TMP4/docs/my other.md"   # 2 bare openers
( cd "$TMP4" && git add -A . ) >/dev/null 2>&1
( cd "$TMP4" && bash scripts/review-lint.sh --update ) >/dev/null 2>&1
bl="$TMP4/scripts/review-lint-baseline.txt"
rows="$(grep -c 'docs/my' "$bl" 2>/dev/null | tr -d ' ')"
if [ "$rows" = 2 ] \
  && grep -q "$(printf 'docs/my file.md\t1')" "$bl" \
  && grep -q "$(printf 'docs/my other.md\t2')" "$bl"; then
  pass "a path with a space keeps its own row and count"
else
  fail "a path with a space keeps its own row and count (rows=$rows: $(grep 'docs/my' "$bl" | tr '\t' '|' | tr '\n' ' '))"
fi
# ...and the gate reads those rows back, so both files stay grandfathered.
out4="$( cd "$TMP4" && bash scripts/review-lint.sh 2>&1 )"; rc4=$?
[ "$rc4" -eq 0 ] && pass "both spaced paths are grandfathered" \
  || fail "both spaced paths are grandfathered (rc=$rc4: $out4)"

# --- 17. a space-separated baseline from an older kit is still readable -----
# Rows are written TAB-separated now. Refusing to read the old format would report every
# grandfathered file as a new hit and turn the gate red the moment a project upgrades.
printf '# legacy\nT002 docs/legacy.md 1\n' > "$TMP4/scripts/review-lint-baseline.txt"
rm -f "$TMP4/docs/my file.md" "$TMP4/docs/my other.md"
printf '```\nx\n```\n' > "$TMP4/docs/legacy.md"
( cd "$TMP4" && git add -A . ) >/dev/null 2>&1
out5="$( cd "$TMP4" && bash scripts/review-lint.sh 2>&1 )"; rc5=$?
[ "$rc5" -eq 0 ] && pass "a space-separated legacy baseline is honored" \
  || fail "a space-separated legacy baseline is honored (rc=$rc5: $out5)"
rm -rf "$TMP4"

# --- 18. a 4-backtick outer fence does not invert parity for the rest -------
# `/^```/` matches ```` too: the counter increments but the line never satisfies $0=="```", so it
# is never reported AND `n` stays odd — every later CLOSING fence is then flagged as a bare opener.
TMP5="$(mktemp -d)"; mkdir -p "$TMP5/scripts" "$TMP5/docs"
cp "$ENGINE" "$TMP5/scripts/"; cp "$TMP/scripts/review-rules.conf" "$TMP5/scripts/"
( cd "$TMP5" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
printf '````md\n```sh\necho hi\n```\n````\n\n```sh\necho ok\n```\n' > "$TMP5/docs/nested.md"
( cd "$TMP5" && git add -A . ) >/dev/null 2>&1
out6="$( cd "$TMP5" && bash scripts/review-lint.sh 2>&1 )"; rc6=$?
[ "$rc6" -eq 0 ] && pass "a 4-backtick outer fence leaves later fences clean" \
  || fail "a 4-backtick outer fence leaves later fences clean (rc=$rc6: $out6)"
# A genuinely bare ~~~ fence is still caught — the rule sees tilde fences at all now.
printf '~~~\nx\n~~~\n' > "$TMP5/docs/tilde.md"
( cd "$TMP5" && git add -A . ) >/dev/null 2>&1
out7="$( cd "$TMP5" && bash scripts/review-lint.sh 2>&1 )"; rc7=$?
if [ "$rc7" -ne 0 ] && printf '%s' "$out7" | grep -q 'docs/tilde.md'; then
  pass "a bare ~~~ fence is caught"
else
  fail "a bare ~~~ fence is caught (rc=$rc7: $out7)"
fi
rm -rf "$TMP5"

# --- 19. KIT_LINT_WALK seeds from disk even when the index is NOT empty -----
# The scaffold case init.sh actually hits: a repo that already has commits, with the kit's files
# freshly written and untracked. Without the walk the baseline comes out empty and the gate goes
# red on the user's first commit of the scaffold.
TMP6="$(mktemp -d)"; mkdir -p "$TMP6/scripts" "$TMP6/docs"
cp "$ENGINE" "$TMP6/scripts/"; cp "$TMP/scripts/review-rules.conf" "$TMP6/scripts/"
( cd "$TMP6" && git init -q . && git config user.email t@t && git config user.name t ) >/dev/null 2>&1
echo readme > "$TMP6/README.md"
( cd "$TMP6" && git add README.md && git commit -qm init ) >/dev/null 2>&1
printf '```\nx\n```\n' > "$TMP6/docs/scaffolded.md"   # written by the scaffold, still untracked
( cd "$TMP6" && KIT_LINT_WALK=1 bash scripts/review-lint.sh --update ) >/dev/null 2>&1
if grep -q 'docs/scaffolded.md' "$TMP6/scripts/review-lint-baseline.txt" 2>/dev/null; then
  pass "KIT_LINT_WALK seeds untracked scaffold files"
else
  fail "KIT_LINT_WALK seeds untracked scaffold files ($(cat "$TMP6/scripts/review-lint-baseline.txt" 2>&1))"
fi
( cd "$TMP6" && git add -A . ) >/dev/null 2>&1
out8="$( cd "$TMP6" && bash scripts/review-lint.sh 2>&1 )"; rc8=$?
[ "$rc8" -eq 0 ] && pass "the seeded scaffold is green once committed" \
  || fail "the seeded scaffold is green once committed (rc=$rc8: $out8)"
# Without the walk the seed is empty — the defect this guards against.
rm -f "$TMP6/scripts/review-lint-baseline.txt"
printf '```\ny\n```\n' > "$TMP6/docs/second.md"
( cd "$TMP6" && bash scripts/review-lint.sh --update ) >/dev/null 2>&1
if grep -q 'docs/second.md' "$TMP6/scripts/review-lint-baseline.txt" 2>/dev/null; then
  fail "an unwalked seed must not see untracked files"
else
  pass "an unwalked seed sees only tracked files"
fi
rm -rf "$TMP6"

# --- 20. --baseline-path is the one place the filename is spelled ----------
out9="$(run --baseline-path)"
[ "$out9" = "scripts/review-lint-baseline.txt" ] \
  && pass "--baseline-path reports the baseline" \
  || fail "--baseline-path reports the baseline (got '$out9')"

# --- 21. missing rule table is a no-op, not a failure ----------------------
rm "$TMP/scripts/review-rules.conf"
capture
[ "$run_rc" -eq 0 ] && pass "missing rule table is a no-op" || fail "missing rule table is a no-op"

[ "$fails" -eq 0 ] && echo "ok review-lint-test passed" || echo "FAIL review-lint-test"
exit "$fails"
