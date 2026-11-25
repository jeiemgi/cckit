#!/usr/bin/env bash
# shellcheck shell=bash
# force-push-fence-test.sh — #592: the fence fails the gate on a force push in a non-test file, names
# the offender, ignores comments and test files, and --write records the count. Fixture tree under
# mktemp -d; the real tree is at its baseline of 0.
# Run:  bash lib/core/force-push-fence-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
F="$ROOT/lib/core/force-push-fence.sh"

bash "$F" >/dev/null; t "the real tree is at baseline" "$?" "0"
t "the real baseline is 0" "$(cat "$ROOT/lib/core/force-push-fence.baseline")" "force=0"

fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
mkdir -p "$fx/bin" "$fx/scripts/lib" "$fx/lib/core"
printf 'echo hi\n' > "$fx/bin/cckit"
printf 'sync() { git push origin "$1"; }\n' > "$fx/scripts/lib/clean.sh"
printf 'force=0\n' > "$fx/lib/core/force-push-fence.baseline"
bash "$F" --root "$fx" >/dev/null; t "a clean tree passes" "$?" "0"

for bad in 'git push --force origin x' 'git push -f origin x' 'git push origin x --force' 'git push --force-with-lease origin x' 'push_it() { git push origin x --force-with-lease; }'; do
  printf '%s\n' "$bad" > "$fx/scripts/lib/stray.sh"
  out="$(bash "$F" --root "$fx")"; rc=$?
  t "fails on: $bad" "$rc" "1"
  t "  names the offender" "$(printf '%s' "$out" | grep -c 'scripts/lib/stray.sh:1:')" "1"
done

printf '# never git push --force here\nx=1\n' > "$fx/scripts/lib/stray.sh"
bash "$F" --root "$fx" >/dev/null; t "a comment is not a call" "$?" "0"
printf 'git push --force origin x\n' > "$fx/scripts/lib/stray-test.sh"
bash "$F" --root "$fx" >/dev/null; t "a test file is skipped" "$?" "0"
rm "$fx/scripts/lib/stray-test.sh"

printf 'git push --force origin x\n' > "$fx/scripts/lib/stray.sh"
bash "$F" --root "$fx" --write >/dev/null
t "--write records the count" "$(cat "$fx/lib/core/force-push-fence.baseline")" "force=1"
bash "$F" --root "$fx" >/dev/null; t "at the baseline passes" "$?" "0"
rm "$fx/lib/core/force-push-fence.baseline"
bash "$F" --root "$fx" >/dev/null 2>&1; t "no baseline is rc 1" "$?" "1"

exit "$fail"
