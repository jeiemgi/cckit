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
awk: FNR==1{n=0} /^```/{n++; if(n%2==1 && $0=="```") print FILENAME":"FNR":"$0}
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

# --- 16. missing rule table is a no-op, not a failure ----------------------
rm "$TMP/scripts/review-rules.conf"
capture
[ "$run_rc" -eq 0 ] && pass "missing rule table is a no-op" || fail "missing rule table is a no-op"

[ "$fails" -eq 0 ] && echo "ok review-lint-test passed" || echo "FAIL review-lint-test"
exit "$fails"
