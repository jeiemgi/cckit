#!/usr/bin/env bash
# shellcheck shell=bash
# verbs-ratchet-test.sh — #557: renames by ratchet. The top-level verb count may only go down
# (scripts/verbs-ratchet.sh against scripts/verbs.baseline), and an old name still works: it prints a
# one-line notice and runs the verb it was renamed to. Fixture tables check the ratchet; the real
# dispatcher checks the alias path. No network, no port.
# Run:  bash scripts/verbs-ratchet-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> missing '$3'"; fail=1 ;; esac; }
CCKIT="$ROOT/bin/cckit"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/verbs.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# ── 1. the ratchet on the real table ──────────────────────────────────────────────────────────
out="$(bash "$ROOT/scripts/verbs-ratchet.sh" 2>&1)"; rc=$?
t "the real table holds the baseline" "$rc" "0"
t "the baseline is the table's verb count" "$(awk '!/^#/ && NF { print $1; exit }' "$ROOT/scripts/verbs.baseline")" "$(verbs_count)"
has "the ratchet says it only goes down" "$out" "it may only go down"

# ── 2. the ratchet on fixtures ────────────────────────────────────────────────────────────────
mkdir -p "$tmp/fx/scripts/lib"
cp "$ROOT/scripts/verbs-ratchet.sh" "$tmp/fx/scripts/"
cp "$ROOT/scripts/lib/verbs.sh" "$tmp/fx/scripts/lib/"
row() { printf '%s\tverb\t-\tg\tgit\t-\tno\tQ?\tP.\tcckit %s\n' "$1" "$1"; }
{ printf 'g\tgroup\t-\t-\t-\t-\t-\tWhat?\t-\t-\n'; row one; row two; } > "$tmp/fx/scripts/lib/verbs.tsv"
ratchet() { bash "$tmp/fx/scripts/verbs-ratchet.sh" --root "$tmp/fx" 2>&1; }

printf '# c\n2\n' > "$tmp/fx/scripts/verbs.baseline"
ratchet >/dev/null; t "fixture: count equal to the baseline passes" "$?" "0"
row three >> "$tmp/fx/scripts/lib/verbs.tsv"
out="$(ratchet)"; rc=$?
t "fixture: a new top-level verb fails" "$rc" "1"
has "fixture: the refusal says where a new verb goes" "$out" "goes under an existing one"
printf '# c\n4\n' > "$tmp/fx/scripts/verbs.baseline"
out="$(ratchet)"; rc=$?
t "fixture: a count below the baseline fails until the baseline drops" "$rc" "1"
has "fixture: the refusal names the number to write" "$out" "Lower scripts/verbs.baseline to 3"
printf 'old\talias\tone\t-\tgit\t-\t-\t-\t-\t-\n' >> "$tmp/fx/scripts/lib/verbs.tsv"
printf '3\n' > "$tmp/fx/scripts/verbs.baseline"
ratchet >/dev/null; t "fixture: an alias row does not count" "$?" "0"
printf '# no number\n' > "$tmp/fx/scripts/verbs.baseline"
ratchet >/dev/null; t "fixture: a baseline with no number is rc 2" "$?" "2"

# ── 3. the alias readers ──────────────────────────────────────────────────────────────────────
printf 'g\tgroup\t-\t-\t-\t-\t-\tWhat?\t-\t-\none\tverb\t-\tg\tgit\t-\tno\tQ?\tP.\tcckit one\nold\talias\tone\t-\tgit\t-\t-\t-\t-\t-\n' > "$tmp/v.tsv"
t "fixture: verbs_alias_target reads the target" "$(VERBS_FILE="$tmp/v.tsv" verbs_alias_target old)" "one"
VERBS_FILE="$tmp/v.tsv" verbs_alias_target one >/dev/null; t "fixture: a verb is not an alias (rc 1)" "$?" "1"
t "the notice is one line naming both names" "$(verbs_alias_notice old new)" "cckit: 'old' is an old name for 'new'; it still works. Use 'cckit new'."

# ── 4. every old name runs its verb, with the notice on stderr only ───────────────────────────
for a in $(verbs_names alias); do
  target="$(verbs_alias_target "$a")"
  err="$("$CCKIT" "$a" --help 2>&1 >/dev/null)"
  t "cckit $a: one notice line on stderr" "$err" "$(verbs_alias_notice "$a" "$target")"
  t "cckit $a --help is cckit $target --help on stdout" "$("$CCKIT" "$a" --help 2>/dev/null)" "$("$CCKIT" "$target" --help 2>/dev/null)"
done

[ "$fail" -eq 0 ] && echo "ALL OK (verbs-ratchet)" || echo "verbs-ratchet: FAILURES"
exit "$fail"
