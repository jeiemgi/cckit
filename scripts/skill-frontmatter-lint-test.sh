#!/usr/bin/env bash
# skill-frontmatter-lint-test.sh — behavioral test for the skill frontmatter context-budget ratchet.
# Builds a throwaway skills/ tree in a temp ROOT and asserts the four transitions that matter:
# under budget passes, a new over-budget skill fails, a baselined skill may sit still but not grow,
# and a shrunk skill is reported as re-baselineable.
set -uo pipefail

LINT="$(cd "$(dirname "$0")" && pwd)/skill-frontmatter-lint.sh"
fails=0
pass() { echo "ok $1"; }
fail() { echo "FAIL $1"; fails=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts" "$TMP/skills"
cp "$LINT" "$TMP/scripts/"

# Write skills/<name>/SKILL.md with a description of $2 chars and when_to_use of $3 chars.
mk_skill() {
  local name="$1" dlen="$2" wlen="$3"
  mkdir -p "$TMP/skills/$name"
  {
    echo "---"
    echo "name: $name"
    printf 'description: %s\n' "$(head -c "$dlen" < /dev/zero | tr '\0' 'd')"
    [ "$wlen" -gt 0 ] && printf 'when_to_use: %s\n' "$(head -c "$wlen" < /dev/zero | tr '\0' 'w')"
    echo "---"
    echo
    echo "body"
  } > "$TMP/skills/$name/SKILL.md"
}

# Capture rather than pipe: `run | grep -q` would let grep exit early, kill `run` with SIGPIPE,
# and — under `set -o pipefail` — report the whole pipeline as failed even on a successful match.
run() { ( cd "$TMP" && bash scripts/skill-frontmatter-lint.sh "$@" 2>&1 ); }
run_out=""; run_rc=0
capture() { run_out="$(run "$@")"; run_rc=$?; }

# --- 1. a lean skill passes with no baseline at all -------------------------
mk_skill lean 100 80
run >/dev/null 2>&1 && pass "lean skill passes with no baseline" \
                    || fail "lean skill passes with no baseline"

# --- 2. measurement is correct across a block scalar ------------------------
# description 100 + when_to_use 80 = 180 total.
got="$(run --report | awk '$1=="lean" {print $4}')"
[ "$got" = "180" ] && pass "measures description+when_to_use (got $got)" \
                   || fail "measures description+when_to_use (expected 180, got $got)"

# --- 3. a NEW over-budget skill fails ---------------------------------------
mk_skill bloated 700 200
capture
if [ "$run_rc" -eq 0 ]; then
  fail "new over-budget skill is rejected (exited 0)"
elif printf '%s' "$run_out" | grep -q "over the .*listing budget"; then
  pass "new over-budget skill is rejected"
else
  fail "new over-budget skill is rejected (wrong message: $run_out)"
fi

# --- 4. once baselined, the same skill is grandfathered ---------------------
run --update >/dev/null 2>&1
run >/dev/null 2>&1 && pass "baselined skill is grandfathered" \
                    || fail "baselined skill is grandfathered"

# --- 5. but it may not GROW -------------------------------------------------
mk_skill bloated 900 200
capture
if [ "$run_rc" -eq 0 ]; then
  fail "growth past baseline is rejected (exited 0)"
elif printf '%s' "$run_out" | grep -q "always-resident context may not grow"; then
  pass "growth past baseline is rejected"
else
  fail "growth past baseline is rejected (wrong message: $run_out)"
fi

# --- 6. shrinking under budget passes and nudges a re-baseline -------------
mk_skill bloated 200 100
capture
if [ "$run_rc" -ne 0 ]; then
  fail "shrunk skill passes and nudges --update (exited $run_rc)"
elif printf '%s' "$run_out" | grep -q "now under budget"; then
  pass "shrunk skill passes and nudges --update"
else
  fail "shrunk skill passes but no re-baseline nudge"
fi

# --- 7. a repo with no skills/ is a no-op, not a failure --------------------
rm -rf "$TMP/skills"
run >/dev/null 2>&1 && pass "missing skills/ is a no-op" \
                    || fail "missing skills/ is a no-op"

[ "$fails" -eq 0 ] && echo "ok skill-frontmatter-lint-test passed" || echo "FAIL skill-frontmatter-lint-test"
exit "$fails"
