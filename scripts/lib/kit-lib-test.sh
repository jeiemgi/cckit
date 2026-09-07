#!/bin/sh
# kit-lib-test.sh — self-test for kit-lib.sh, the helper catalog (Effort 220 · #222).
# Network-free and repo-free: every parser assertion runs against fixture .sh files written into a
# temp dir, so the test never depends on what scripts/lib happens to contain today. The pure
# parsers run under bash AND zsh; the full kit_lib verb (which sources render/toon via BASH_SOURCE)
# runs under bash, matching how the dispatcher invokes it.
# Run:  bash scripts/lib/kit-lib-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# _kl_fixture <dir> — a small library covering every parse case the catalog has to survive:
#   alpha.sh        em-dash header, `strict`, one public + one private + one nested function
#   beta.sh         hyphen header, `mixed` (the reason is load-bearing), `function name()` form
#   gamma.sh        NO `# errors:` header at all — must degrade, not fail
#   delta.sh        `# shellcheck` directive before the header; a pipe char in the purpose
#   epsilon.sh      no functions at all (constants only)
#   omega-test.sh   a test runner — excluded from the catalog by default
_kl_fixture() {
  r="$1"
  mkdir -p "$r"
  cat > "$r/alpha.sh" <<'EOF'
#!/usr/bin/env bash
# alpha.sh — does the alpha thing for a caller.
# errors: strict — a failed dependency propagates
alpha_go() { _alpha_priv; }
_alpha_priv() {
  alpha_nested() { :; }
}
EOF
  cat > "$r/beta.sh" <<'EOF'
#!/usr/bin/env bash
# beta.sh - the beta half.
# errors: mixed — beta_pure is pure; beta_net needs gh
beta_pure() { :; }
function beta_net() { :; }
EOF
  cat > "$r/gamma.sh" <<'EOF'
#!/usr/bin/env bash
# gamma.sh — predates the header convention.
gamma_run() { :; }
EOF
  cat > "$r/delta.sh" <<'EOF'
#!/usr/bin/env bash
# shellcheck shell=bash
# delta.sh — takes a | pipe in its purpose line.
# errors: best-effort — warns and returns 0
delta_do() { :; }
EOF
  cat > "$r/epsilon.sh" <<'EOF'
#!/usr/bin/env bash
# epsilon.sh — constants only, no callable surface.
# errors: pure — no I/O
EPSILON=1
EOF
  cat > "$r/omega-test.sh" <<'EOF'
#!/usr/bin/env bash
# omega-test.sh — a runner.
# errors: strict — a test runner: rc 1 on any failed assertion
t() { :; }
EOF
}

if [ -n "${KL_TEST_INNER:-}" ]; then
  . "$dir/kit-lib.sh"
  fail=0
  eq()  { if [ "$2" != "$3" ]; then echo "FAIL($KL_TEST_INNER): $1 -> '[$2]', want '[$3]'"; fail=1; fi; }
  has() { case "$2" in *"$3"*) ;; *) echo "FAIL($KL_TEST_INNER): $1 missing '[$3]'"; fail=1 ;; esac; }
  no()  { case "$2" in *"$3"*) echo "FAIL($KL_TEST_INNER): $1 should NOT contain '[$3]'"; fail=1 ;; esac; }

  fix="$(mktemp -d)"; _kl_fixture "$fix"
  empty="$(mktemp -d)"

  # ── purpose: derived from the file's own header, never invented ────────────────────────────
  eq "purpose (em dash)"        "$(kit_lib_purpose "$fix/alpha.sh")"   "does the alpha thing for a caller."
  eq "purpose (hyphen)"         "$(kit_lib_purpose "$fix/beta.sh")"    "the beta half."
  eq "purpose skips shellcheck" "$(kit_lib_purpose "$fix/delta.sh")"   "takes a / pipe in its purpose line."
  eq "purpose of a missing file" "$(kit_lib_purpose "$fix/nope.sh")"   "unknown"
  # a header-less file still yields its first comment rather than a fabricated sentence
  printf '#!/usr/bin/env bash\nfoo() { :; }\n' > "$fix/bare.sh"
  eq "purpose with no header"   "$(kit_lib_purpose "$fix/bare.sh")"    "unknown"
  rm -f "$fix/bare.sh"

  # only the FIRST sentence: a lib header's opening line is usually "<claim>. <elaboration…>".
  printf '#!/usr/bin/env bash\n# two.sh — the claim itself, stated once. Then a long elaboration nobody needs here.\n' > "$fix/two.sh"
  eq "purpose keeps one sentence" "$(kit_lib_purpose "$fix/two.sh")" "the claim itself, stated once."
  # a period too early is an abbreviation, not a sentence end — keep the line
  printf '#!/usr/bin/env bash\n# ab.sh — e.g. the whole line survives because that cut would be absurd.\n' > "$fix/ab.sh"
  has "purpose ignores an early period" "$(kit_lib_purpose "$fix/ab.sh")" "the whole line survives"
  # no sentence end at all and over the cap -> truncated at a word boundary, marked with an ellipsis
  printf '#!/usr/bin/env bash\n# long.sh — %s tail\n' \
    "aaaa bbbb cccc dddd eeee ffff gggg hhhh iiii jjjj kkkk llll mmmm nnnn oooo pppp qqqq rrrr ssss tttt uuuu" > "$fix/long.sh"
  lp="$(kit_lib_purpose "$fix/long.sh")"
  has "over-long purpose is elided" "$lp" "…"
  no  "elision drops the tail"      "$lp" "tail"
  rm -f "$fix/two.sh" "$fix/ab.sh" "$fix/long.sh"

  # ── public functions: `_`-prefixed and nested definitions are not API ─────────────────────
  eq "public functions only"    "$(kit_lib_functions "$fix/alpha.sh")" "alpha_go"
  eq "the 'function' keyword form" "$(kit_lib_functions "$fix/beta.sh")" "beta_net beta_pure"
  eq "no functions -> empty"    "$(kit_lib_functions "$fix/epsilon.sh")" ""

  # ── error contract: read, never guessed; missing is `unknown`, not fatal ──────────────────
  eq "errors strict"            "$(kit_lib_errors "$fix/alpha.sh")"    "strict"
  eq "errors mixed"             "$(kit_lib_errors "$fix/beta.sh")"     "mixed"
  eq "errors best-effort"       "$(kit_lib_errors "$fix/delta.sh")"    "best-effort"
  eq "missing header -> unknown" "$(kit_lib_errors "$fix/gamma.sh")"   "unknown"
  eq "mixed reason"             "$(kit_lib_errors_reason "$fix/beta.sh")" "beta_pure is pure; beta_net needs gh"
  eq "no header -> no reason"   "$(kit_lib_errors_reason "$fix/gamma.sh")" ""

  # ── file listing: test runners are not part of the library ───────────────────────────────
  eq "runners excluded" "$(kit_lib_files "$fix" | while IFS= read -r p; do basename "$p"; done | tr '\n' ',')" \
     "alpha.sh,beta.sh,delta.sh,epsilon.sh,gamma.sh,"
  has "runners included with all=1" "$(kit_lib_files "$fix" 1 | tr '\n' ' ')" "omega-test.sh"
  eq "empty dir -> nothing"     "$(kit_lib_files "$empty")" ""
  eq "missing dir -> nothing"   "$(kit_lib_files "$fix/nope")" ""

  # ── rows: one TSV row per helper, four fields, table-safe ─────────────────────────────────
  rows="$(kit_lib_rows "$fix")"
  eq "one row per helper"  "$(printf '%s\n' "$rows" | grep -c .)" "5"
  eq "four fields per row" "$(printf '%s\n' "$rows" | awk -F'\t' 'NF!=4' | grep -c .)" "0"
  no "no pipe leaks into a cell" "$rows" "|"
  has "mixed row carries its reason" "$rows" "mixed — beta_pure is pure"
  no  "non-mixed reason hidden by default" "$rows" "a failed dependency propagates"
  has "unknown contract is reported" "$rows" "gamma.sh	unknown"
  has "a surface-less helper shows a dash" "$rows" "epsilon.sh	pure	—"
  has "--reasons exposes every reason" "$(kit_lib_rows "$fix" 0 1)" "strict — a failed dependency propagates"
  # the function list is NEVER elided — an agent came here to find a name, not an ellipsis
  printf '#!/usr/bin/env bash\n# many.sh — lots of surface.\n# errors: pure — no I/O\n' > "$fix/many.sh"
  i=1; while [ "$i" -le 12 ]; do printf 'many_function_number_%02d() { :; }\n' "$i" >> "$fix/many.sh"; i=$((i + 1)); done
  has "long function lists keep the last name" "$(kit_lib_rows "$fix")" "many_function_number_12"
  no  "long function lists are not elided"     "$(kit_lib_functions "$fix/many.sh")" "…"
  rm -f "$fix/many.sh"
  eq  "empty dir -> no rows" "$(kit_lib_rows "$empty")" ""

  # ── dir resolution: an explicit root, and never a crash ──────────────────────────────────
  mkdir -p "$fix/proj/scripts/lib"
  eq "--root prefers scripts/lib" "$(KIT_LIB_DIR= kit_lib_dir "$fix/proj")" "$fix/proj/scripts/lib"
  eq "--root falls back to the dir itself" "$(KIT_LIB_DIR= kit_lib_dir "$fix")" "$fix"
  if (KIT_LIB_DIR= kit_lib_dir "$fix/nope" >/dev/null 2>&1); then
    echo "FAIL($KL_TEST_INNER): a nonexistent --root should be rc 1"; fail=1
  fi

  # ── the full verb (bash only — sources render/toon via BASH_SOURCE) ───────────────────────
  if [ "$KL_TEST_INNER" = "bash" ]; then
    hum="$(KIT_LIB_DIR="$fix" CCKIT_NO_GLOW=1 CCKIT_OUTPUT=human kit_lib)"
    has "human has the table header" "$hum" "| file | errors | public functions | purpose |"
    has "human lists a helper"       "$hum" '`alpha.sh`'
    has "human explains the contract" "$hum" "declared failure contract"
    has "human shows how to source"  "$hum" "source $fix/<file>"
    has "human states the exclusion" "$hum" "runner(s) are excluded"
    no  "human omits runners"        "$hum" '`omega-test.sh`'

    aout="$(KIT_LIB_DIR="$fix" CCKIT_NO_GLOW=1 CCKIT_OUTPUT=human kit_lib --all)"
    has "--all includes runners"     "$aout" '`omega-test.sh`'

    # an empty library is a legitimate answer, not a crash
    eout="$(KIT_LIB_DIR="$empty" CCKIT_NO_GLOW=1 CCKIT_OUTPUT=human kit_lib)"; erc=$?
    eq  "empty exits 0"              "$erc" "0"
    has "empty has a graceful state" "$eout" 'no `.sh` helpers'

    eq "help lists the flags" "$(KIT_LIB_DIR="$fix" kit_lib --help | grep -c '^cckit lib')" "5"

    if command -v jq >/dev/null 2>&1; then
      llm="$(KIT_LIB_DIR="$fix" CCKIT_OUTPUT=json kit_lib --llm)"
      has "TOON header"        "$llm" "{file,errors,functions,purpose}"
      has "TOON row"           "$llm" '"alpha.sh"'
      has "TOON keeps unknown" "$llm" '"unknown"'
      eq  "TOON row count"     "$(printf '%s\n' "$llm" | head -1)" "[5]{file,errors,functions,purpose}:"
      # an empty catalog is [] — never an error
      eq  "empty catalog is []" "$(KIT_LIB_DIR="$empty" CCKIT_OUTPUT=json kit_lib --llm)" "[]"
      err="$(KIT_LIB_DIR="$fix" CCKIT_OUTPUT=json kit_lib --llm --bogus)"; brc=$?
      eq  "bad arg rc=2"       "$brc" "2"
      has "structured error"   "$err" '"error"'
    else
      echo "  (jq absent — skipping TOON/JSON assertions)"
    fi
  fi

  rm -rf "$fix" "$empty"
  if [ "$fail" -eq 0 ]; then echo "PASS($KL_TEST_INNER): kit-lib catalog parsers + verb shapes"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  KL_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
