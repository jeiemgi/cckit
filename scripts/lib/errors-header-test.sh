#!/usr/bin/env bash
# shellcheck shell=bash
# errors-header-test.sh — enforce the `# errors:` header on every scripts/lib helper (#223).
#
# The header says whether a helper propagates a failure or swallows it. Both are correct designs,
# but the difference used to live only in prose, so a caller that mixed a strict helper with a
# best-effort one silently inherited the weaker behavior — and nothing could assert otherwise.
# This test is what makes the header a rule instead of a habit: a new lib file without one, or with
# a value outside the vocabulary, fails here. Run:  bash scripts/lib/errors-header-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }

# The vocabulary. Adding a fifth value is a deliberate change — update this list and the docs table.
VOCAB="pure strict best-effort mixed"

in_vocab() {
  local v="$1" x
  for x in $VOCAB; do [ "$v" = "$x" ] && return 0; done
  return 1
}

# errors_header <file> — the declared value, or empty when the file has no header line.
errors_header() {
  sed -n 's/^# errors:[[:space:]]*\([a-z-]*\).*/\1/p' "$1" | head -1
}

# ── 1. every lib file declares one, and it is in the vocabulary ────────────────────────────────
missing=0 bad=0 n=0
for f in "$LIB"/*.sh; do
  n=$((n + 1))
  v="$(errors_header "$f")"
  if [ -z "$v" ]; then
    echo "FAIL: no '# errors:' header -> $(basename "$f")"
    missing=$((missing + 1)); fail=1
  elif ! in_vocab "$v"; then
    echo "FAIL: '$v' is not in the vocabulary ($VOCAB) -> $(basename "$f")"
    bad=$((bad + 1)); fail=1
  fi
done
[ "$n" -gt 0 ] || { echo "FAIL: found no lib files to check"; fail=1; }
t "every lib file has a header" "$missing" "0"
t "every value is in the vocabulary" "$bad" "0"

# ── 2. the header carries a reason, not just a value ───────────────────────────────────────────
# A bare "# errors: mixed" tells a reader nothing about WHICH half is which, which is the whole
# point for a mixed file. Require the em-dash reason.
noreason=0
for f in "$LIB"/*.sh; do
  grep -qE '^# errors: (pure|strict|best-effort|mixed) — .+' "$f" || {
    echo "FAIL: header has no reason after the em dash -> $(basename "$f")"
    noreason=$((noreason + 1)); fail=1
  }
done
t "every header carries a reason" "$noreason" "0"

# ── 3. the parser itself, on fixtures (pure; no repo files) ────────────────────────────────────
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
printf '#!/usr/bin/env bash\n# x.sh — a thing.\n# errors: best-effort — warns and returns 0\nx() { :; }\n' > "$tmp/a.sh"
printf '#!/usr/bin/env bash\n# y.sh — a thing.\ny() { :; }\n' > "$tmp/b.sh"
t "parses a declared value"        "$(errors_header "$tmp/a.sh")" "best-effort"
t "empty when undeclared"          "$(errors_header "$tmp/b.sh")" ""
if in_vocab "best-effort"; then t "vocabulary accepts best-effort" "yes" "yes"; else t "vocabulary accepts best-effort" "no" "yes"; fi
if in_vocab "silent"; then t "vocabulary rejects an unknown value" "accepted" "rejected"; else t "vocabulary rejects an unknown value" "rejected" "rejected"; fi

# ── 4. a strict file must not claim to be pure ─────────────────────────────────────────────────
# Cheap consistency check: a file declaring `pure` should not carry a `set -e`, which only matters
# when the file shells out to something that can fail.
liars=0
for f in "$LIB"/*.sh; do
  [ "$(errors_header "$f")" = "pure" ] || continue
  grep -qE '^set -[a-z]*e' "$f" && { echo "FAIL: declares pure but sets -e -> $(basename "$f")"; liars=$((liars + 1)); fail=1; }
done
t "no pure file sets -e" "$liars" "0"

if [ "$fail" -eq 0 ]; then echo "errors-header-test: OK ($n lib files)"; else echo "errors-header-test: FAILED"; fi
exit "$fail"
