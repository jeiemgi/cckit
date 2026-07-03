#!/bin/sh
# plan-next-test.sh — self-test for plan-next.sh (Effort 86 · #91).
# Network-free, filesystem-only: builds a throwaway fixture project and asserts the inventory
# scanners, the proposal shape (TOON + JSON + human), empty states, the structured error, and the
# invariant that EVERY plan carries the mandatory docs + README step. The pure scanners + proposals
# run under bash AND zsh; the full plan_next verb (which sources render/toon via BASH_SOURCE) runs
# under bash, matching how the dispatcher invokes it. Run:  bash scripts/lib/plan-next-test.sh

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# _pn_fixture <root> — a small capability tree. docs mention alpha-skill + the 'foo' verb but NOT
# beta-skill or 'bar', so those two become the coverage-gap proposals.
_pn_fixture() {
  local r="$1"
  mkdir -p "$r/skills/alpha-skill" "$r/skills/beta-skill" "$r/rules" "$r/docs" "$r/commands"
  : > "$r/skills/alpha-skill/SKILL.md"; : > "$r/skills/beta-skill/SKILL.md"
  : > "$r/rules/r1.md"; : > "$r/rules/r2.md"
  : > "$r/commands/foo.md"; : > "$r/commands/bar.md"
  printf 'see the alpha-skill skill and the foo verb.\n' > "$r/docs/intro.md"
}

if [ -n "${PN_TEST_INNER:-}" ]; then
  . "$dir/plan-next.sh"
  fail=0
  eq()  { if [ "$2" != "$3" ]; then echo "FAIL($PN_TEST_INNER): $1 -> '[$2]', want '[$3]'"; fail=1; fi; }
  has() { case "$2" in *"$3"*) ;; *) echo "FAIL($PN_TEST_INNER): $1 missing '[$3]'"; fail=1 ;; esac; }
  no()  { case "$2" in *"$3"*) echo "FAIL($PN_TEST_INNER): $1 should NOT contain '[$3]'"; fail=1 ;; esac; }

  fix="$(mktemp -d)"; _pn_fixture "$fix"
  empty="$(mktemp -d)"

  # --- pure scanners (bash + zsh) ---
  eq "skills scanner" "$(plan_next_skills "$fix" | tr '\n' ',')" "alpha-skill,beta-skill,"
  eq "verbs scanner (commands fallback)" "$(plan_next_verbs "$fix" | tr '\n' ',')" "bar,foo,"
  eq "rules scanner" "$(plan_next_rules "$fix" | tr '\n' ',')" "r1,r2,"
  eq "docs scanner" "$(plan_next_docs "$fix" | tr '\n' ',')" "intro,"
  eq "empty skills -> nothing" "$(plan_next_skills "$empty")" ""

  # --- proposals shape (bash + zsh) ---
  props="$(_pn_proposals "$fix")"
  first="$(printf '%s\n' "$props" | head -1)"
  has "rank 1 is docs"            "$first" "1	docs"
  has "mandatory docs+README"     "$first" "README"
  has "undocumented skill gap"    "$props" "beta-skill"
  has "undocumented verb gap"     "$props" "bar"
  no  "documented skill not flagged as gap" "$props" "Document the alpha-skill"
  # EVERY plan carries the docs + README step — also on a bare project.
  has "empty plan still has docs+README" "$(_pn_proposals "$empty")" "README"

  # --- full verb (bash only — sources render/toon via BASH_SOURCE) ---
  if [ "$PN_TEST_INNER" = "bash" ]; then
    hum="$(PLAN_NEXT_ROOT="$fix" CCKIT_NO_GLOW=1 CCKIT_OUTPUT=human plan_next)"
    has "human shows capabilities"  "$hum" "Current capabilities"
    has "human shows docs+README"   "$hum" "README"
    has "human states context rule" "$hum" "context-anxiety"

    # empty/host project: graceful, exits 0, still carries the docs step.
    eout="$(PLAN_NEXT_ROOT="$empty" CCKIT_NO_GLOW=1 CCKIT_OUTPUT=human plan_next)"; erc=$?
    eq  "empty exits 0" "$erc" "0"
    has "empty has graceful banner" "$eout" "No kit capabilities found"
    has "empty still has docs+README" "$eout" "README"

    if command -v jq >/dev/null 2>&1; then
      llm="$(PLAN_NEXT_ROOT="$fix" CCKIT_OUTPUT=json plan_next --llm)"
      has "TOON header"        "$llm" "{rank,area,proposal,next}"
      has "TOON has docs row"  "$llm" "README"
      has "TOON has next col"  "$llm" "/kit-effort-new"
      # structured error on a bad arg.
      err="$(PLAN_NEXT_ROOT="$fix" CCKIT_OUTPUT=json plan_next --llm --bogus)"; brc=$?
      eq  "bad arg rc=2"        "$brc" "2"
      has "structured error"   "$err" '"error"'
    else
      echo "  (jq absent — skipping TOON/JSON assertions)"
    fi
  fi

  rm -rf "$fix" "$empty"
  if [ "$fail" -eq 0 ]; then echo "PASS($PN_TEST_INNER): plan-next inventory + plan shapes"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  PN_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
