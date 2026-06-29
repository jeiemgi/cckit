#!/usr/bin/env bash
# kit-cli-test.sh — self-test for kit-cli (#383). Runs under bash AND zsh.
# Run:  bash scripts/lib/kit-cli-test.sh
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KIT_CLI_TEST_INNER:-}" ]; then
  set -u
  . "$dir/kit-cli.sh"
  fail=0
  t() { if [ "$2" != "$3" ]; then echo "FAIL($KIT_CLI_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok($KIT_CLI_TEST_INNER): $1"; fi; }

  # IO helpers go to stderr (stdout stays clean)
  t "kit_say -> stderr"   "$(kit_say hi 2>/dev/null)"            ""
  t "kit_say content"     "$(kit_say hi 2>&1 1>/dev/null)"       "hi"
  t "kit_warn prefix"     "$(kit_warn boom 2>&1 1>/dev/null)"    "kit: boom"

  # kit_is_main: build a throwaway consumer that sources kit-cli and reports, then run it
  # executed-directly vs sourced. Use the SAME interpreter we're running under.
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  cp "$dir/kit-cli.sh" "$tmp/kit-cli.sh"
  cat > "$tmp/consumer.sh" <<'C'
d=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)
. "$d/kit-cli.sh"
kit_is_main && echo MAIN || echo SOURCED
C
  sh="$KIT_CLI_TEST_INNER"
  t "is_main: executed" "$("$sh" "$tmp/consumer.sh")"          "MAIN"
  t "is_main: sourced"  "$("$sh" -c ". '$tmp/consumer.sh'")"   "SOURCED"

  [ "$fail" -eq 0 ] && echo "ALL OK($KIT_CLI_TEST_INNER)"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran+1)); echo "--- $sh ---"
  rcflag=""; [ "$sh" = "zsh" ] && rcflag="--no-rcs"
  KIT_CLI_TEST_INNER="$sh" PATH="$PATH" "$sh" $rcflag "$0" || rc=1
done
[ "$ran" -eq 0 ] && { echo "no shell"; exit 1; }
exit "$rc"
