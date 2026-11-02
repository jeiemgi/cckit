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

# --- 7. the measurement does not move with the locale -----------------------
# `${#s}` counts CHARACTERS under a UTF-8 locale and BYTES under C/POSIX. With multibyte text in a
# description, a baseline generated under one locale fires the ratchet under the other — on skills
# nobody touched. The lint pins LC_ALL, so both runs must agree exactly.
rm -rf "$TMP/skills"; mkdir -p "$TMP/skills"; rm -f "$TMP/scripts/skill-frontmatter-baseline.txt"
mkdir -p "$TMP/skills/multibyte"
{
  echo "---"
  echo "name: multibyte"
  printf 'description: %s — %s · %s\n' "$(head -c 200 < /dev/zero | tr '\0' 'd')" \
                                       "$(head -c 200 < /dev/zero | tr '\0' 'e')" \
                                       "$(head -c 200 < /dev/zero | tr '\0' 'f')"
  echo "---"
  echo
  echo "body"
} > "$TMP/skills/multibyte/SKILL.md"
c_out="$( cd "$TMP" && LC_ALL=C            bash scripts/skill-frontmatter-lint.sh --report 2>&1 )"
u_out="$( cd "$TMP" && LC_ALL=en_US.UTF-8  bash scripts/skill-frontmatter-lint.sh --report 2>&1 )"
[ "$c_out" = "$u_out" ] && pass "the count is identical under LC_ALL=C and UTF-8" \
  || fail "the count moves with the locale:
C:    $c_out
UTF8: $u_out"

# A baseline written under one locale must still pass the gate under the other.
( cd "$TMP" && LC_ALL=en_US.UTF-8 bash scripts/skill-frontmatter-lint.sh --update ) >/dev/null 2>&1
lc_out="$( cd "$TMP" && LC_ALL=C bash scripts/skill-frontmatter-lint.sh 2>&1 )"; lc_rc=$?
[ "$lc_rc" -eq 0 ] && pass "a UTF-8 baseline passes under LC_ALL=C" \
  || fail "a UTF-8 baseline passes under LC_ALL=C (rc=$lc_rc: $lc_out)"
rm -f "$TMP/scripts/skill-frontmatter-baseline.txt"

# --- 8. .claude/skills/ is linted too — the layout init.sh actually scaffolds
# Hard-coding `skills` made the shipped lint a permanent no-op in every consumer project.
rm -rf "$TMP/skills"
mkdir -p "$TMP/.claude/skills/scaffolded"
{
  echo "---"
  echo "name: scaffolded"
  printf 'description: %s\n' "$(head -c 700 < /dev/zero | tr '\0' 'd')"
  echo "---"
} > "$TMP/.claude/skills/scaffolded/SKILL.md"
capture
if [ "$run_rc" -ne 0 ] && printf '%s' "$run_out" | grep -q 'scaffolded'; then
  pass ".claude/skills/ is linted"
else
  fail ".claude/skills/ is linted (rc=$run_rc: $run_out)"
fi
rm -rf "$TMP/.claude"

# --- 9. --baseline-path is the one place the filename is spelled ------------
# init.sh used to reconstruct it as "<lint>-baseline.txt", which for THIS lint names a file that
# never exists — so its "seed once" guard never matched and every upgrade re-baselined silently.
bp_out="$( cd "$TMP" && bash scripts/skill-frontmatter-lint.sh --baseline-path 2>&1 )"
[ "$bp_out" = "scripts/skill-frontmatter-baseline.txt" ] \
  && pass "--baseline-path reports the baseline" \
  || fail "--baseline-path reports the baseline (got '$bp_out')"
# It answers even with no skills tree at all — init.sh asks before anything is scaffolded.
[ -d "$TMP/skills" ] && fail "fixture leaked a skills/ dir into the no-tree check"
bp2="$( cd "$TMP" && bash scripts/skill-frontmatter-lint.sh --baseline-path 2>&1 )"
[ "$bp2" = "scripts/skill-frontmatter-baseline.txt" ] \
  && pass "--baseline-path answers with no skills tree" \
  || fail "--baseline-path answers with no skills tree (got '$bp2')"

# --- 10. a repo with no skills tree is a no-op, not a failure ---------------
rm -rf "$TMP/skills"
run >/dev/null 2>&1 && pass "missing skills tree is a no-op" \
                    || fail "missing skills tree is a no-op"

[ "$fails" -eq 0 ] && echo "ok skill-frontmatter-lint-test passed" || echo "FAIL skill-frontmatter-lint-test"
exit "$fails"
