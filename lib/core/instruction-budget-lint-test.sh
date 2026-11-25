#!/usr/bin/env bash
# instruction-budget-lint-test.sh — behavioral test for the instruction-file budget ratchet (#357).
# Builds a throwaway project in a temp ROOT and asserts the transitions that matter: a `paths:` rule
# leaves the resident sum, a new over-long file fails, a baselined file may sit still but not grow,
# the resident total ratchets the same way, and a project with no instruction files is a no-op.
set -uo pipefail

LINT="$(cd "$(dirname "$0")" && pwd)/instruction-budget-lint.sh"
fails=0
pass() { echo "ok $1"; }
fail() { echo "FAIL $1"; fails=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/scripts"
cp "$LINT" "$TMP/scripts/"

# Capture rather than pipe: `run | grep -q` lets grep exit early and SIGPIPE the lint, which
# pipefail then reports as a failure on a successful match.
run() { ( cd "$TMP" && bash scripts/instruction-budget-lint.sh "$@" 2>&1 ); }
run_out=""; run_rc=0
capture() { run_out="$(run "$@")"; run_rc=$?; }
has() { case "$run_out" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# mk_rule <name> <lines> [paths-glob] — a rule of exactly <lines> lines, each line 10 bytes.
mk_rule() {
  local name="$1" lines="$2" glob="${3:-}" i=0
  mkdir -p "$TMP/.claude/rules"
  {
    if [ -n "$glob" ]; then
      printf -- '---\npaths:\n  - "%s"\n---\n' "$glob"
      i=4
    fi
    while [ "$i" -lt "$lines" ]; do echo "123456789"; i=$(( i + 1 )); done
  } > "$TMP/.claude/rules/$name.md"
}

# --- (d) no CLAUDE.md and no rules dir: exits 0, and --summary prints nothing ------------------
capture
if [ "$run_rc" -eq 0 ] && has "nothing to lint"; then pass "no instruction files exits 0"
else fail "no instruction files exits 0 (rc $run_rc: $run_out)"; fi
capture --summary
if [ "$run_rc" -eq 0 ] && [ -z "$run_out" ]; then pass "--summary is empty with nothing to measure"
else fail "--summary is empty with nothing to measure (rc $run_rc: $run_out)"; fi

# --- --baseline-path names the file init.sh seeds ---------------------------------------------
capture --baseline-path
[ "$run_out" = "scripts/instruction-budget-baseline.txt" ] && pass "--baseline-path prints the baseline path" \
  || fail "--baseline-path prints the baseline path (got $run_out)"

# --- a lean project passes with no baseline ---------------------------------------------------
printf '%s\n' "# project" "one line" > "$TMP/CLAUDE.md"     # 10 + 9 = 19 bytes
mk_rule always 10                                           # 100 bytes
capture
[ "$run_rc" -eq 0 ] && pass "a lean project passes with no baseline" \
                    || fail "a lean project passes with no baseline ($run_out)"

# --- (a) a rule with `paths:` frontmatter is excluded from the resident sum -------------------
capture --summary
has "instruction files: 119 of 150000 bytes resident" && pass "resident sum is CLAUDE.md + unscoped rules (119)" \
  || fail "resident sum is CLAUDE.md + unscoped rules (got: $run_out)"
mk_rule scoped 50 'src/**/*.tsx'
capture --summary
has "instruction files: 119 of 150000 bytes resident" && pass "a paths: rule is excluded from the resident sum" \
  || fail "a paths: rule is excluded from the resident sum (got: $run_out)"
capture --report
if has "resident total: 119 of 150000 bytes" && has "path-scoped: " && has "in 1 file(s)"; then
  pass "--report prints the resident total and the path-scoped cost"
else fail "--report prints the resident total and the path-scoped cost (got: $run_out)"; fi

# A `paths:` line in the BODY is not frontmatter and must not hide a rule from the sum.
printf '%s\n' "# body" "paths: not frontmatter" > "$TMP/.claude/rules/body.md"   # 7 + 23 = 30
capture --summary
has "instruction files: 149 of" && pass "paths: outside frontmatter does not scope a rule" \
  || fail "paths: outside frontmatter does not scope a rule (got: $run_out)"
rm -f "$TMP/.claude/rules/body.md"

# --- --summary names the three largest resident files, largest first --------------------------
mk_rule mid 30; mk_rule big 40; mk_rule small 2
capture --summary
case "$run_out" in
  *"largest: .claude/rules/big.md (400), .claude/rules/mid.md (300), .claude/rules/always.md (100)") \
     pass "--summary lists the three largest resident files" ;;
  *) fail "--summary lists the three largest resident files (got: $run_out)" ;;
esac
capture --report
has "largest resident: .claude/rules/big.md (400)" && pass "--report lists the largest files" \
  || fail "--report lists the largest files (got: $run_out)"
rm -f "$TMP/.claude/rules/mid.md" "$TMP/.claude/rules/big.md" "$TMP/.claude/rules/small.md"

# --- (c) a NEW file over 200 lines fails ------------------------------------------------------
mk_rule long 201
capture
if [ "$run_rc" -ne 0 ] && has "long.md: 201 lines, over the 200-line limit"; then
  pass "a new file over 200 lines is rejected"
else fail "a new file over 200 lines is rejected (rc $run_rc: $run_out)"; fi

# A path-scoped file is held to the line limit too: once loaded it costs the same.
mk_rule scopedlong 230 'docs/**'
capture
has "scopedlong.md: 230 lines" && pass "a path-scoped file over 200 lines is rejected too" \
  || fail "a path-scoped file over 200 lines is rejected too ($run_out)"
rm -f "$TMP/.claude/rules/scopedlong.md"

# --- baselining grandfathers it ---------------------------------------------------------------
run --update >/dev/null
grep -q '^\.claude/rules/long\.md 201$' "$TMP/scripts/instruction-budget-baseline.txt" \
  && pass "--update records the file and its line count" \
  || fail "--update records the file and its line count ($(cat "$TMP/scripts/instruction-budget-baseline.txt"))"
capture
[ "$run_rc" -eq 0 ] && pass "a baselined file that sits still passes" \
                    || fail "a baselined file that sits still passes ($run_out)"

# --- (b) growing a baselined file fails -------------------------------------------------------
mk_rule long 205
capture
if [ "$run_rc" -ne 0 ] && has "long.md: grew to 205 lines (baseline 201)"; then
  pass "growing a baselined file is rejected"
else fail "growing a baselined file is rejected (rc $run_rc: $run_out)"; fi

# --- shrinking under the limit passes and nudges ----------------------------------------------
mk_rule long 150
capture
if [ "$run_rc" -eq 0 ] && has "run --update to drop it from the baseline"; then
  pass "a shrunk file passes and nudges a re-baseline"
else fail "a shrunk file passes and nudges a re-baseline (rc $run_rc: $run_out)"; fi
run --update >/dev/null

# --- the resident total ratchets against the limit --------------------------------------------
# KIT_INSTRUCTION_BUDGET shrinks the limit so the fixture stays small: resident is 19 + 100 + 1500.
runb() { ( cd "$TMP" && KIT_INSTRUCTION_BUDGET=1000 bash scripts/instruction-budget-lint.sh "$@" 2>&1 ); }
run_out="$(runb)"; run_rc=$?
if [ "$run_rc" -ne 0 ] && has "total 1619 bytes, over the 1000-byte limit"; then
  pass "a resident total over the limit is rejected"
else fail "a resident total over the limit is rejected (rc $run_rc: $run_out)"; fi
runb --update >/dev/null
grep -q '^@resident 1619$' "$TMP/scripts/instruction-budget-baseline.txt" \
  && pass "--update records the over-limit resident total" \
  || fail "--update records the over-limit resident total"
run_out="$(runb)"; run_rc=$?
[ "$run_rc" -eq 0 ] && pass "a baselined resident total that sits still passes" \
                    || fail "a baselined resident total that sits still passes ($run_out)"
mk_rule extra 5
run_out="$(runb)"; run_rc=$?
if [ "$run_rc" -ne 0 ] && has "grew to 1669 bytes (baseline 1619"; then
  pass "growing a baselined resident total is rejected"
else fail "growing a baselined resident total is rejected (rc $run_rc: $run_out)"; fi
# Scoping the new rule takes it back out of the resident set, which is the fix the lint asks for.
mk_rule extra 5 'app/**'
run_out="$(runb)"; run_rc=$?
[ "$run_rc" -eq 0 ] && pass "scoping the new rule with paths: clears the growth" \
                    || fail "scoping the new rule with paths: clears the growth ($run_out)"

# --- INSTRUCTION_BUDGET_ROOT measures another directory (how status + doctor call it) ---------
other="$TMP/other"; mkdir -p "$other"
printf '%s\n' "12345" > "$other/CLAUDE.md"
got="$(INSTRUCTION_BUDGET_ROOT="$other" bash "$LINT" --summary 2>&1)"
case "$got" in
  "instruction files: 6 of 150000 bytes resident (0%); largest: CLAUDE.md (6)") \
     pass "INSTRUCTION_BUDGET_ROOT points the lint at another project" ;;
  *) fail "INSTRUCTION_BUDGET_ROOT points the lint at another project (got: $got)" ;;
esac

echo
[ "$fails" -eq 0 ] && echo "PASS instruction-budget-lint" || echo "FAILED instruction-budget-lint"
exit "$fails"
