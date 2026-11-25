#!/usr/bin/env bash
# shellcheck shell=bash
# forge-fence-test.sh — E537.5: the fence fails the gate when a file outside the forge layer calls
# gh or names api.github.com, passes at or under the baseline, names the offenders, and --write
# records the current counts. Fixture tree under mktemp -d; the real tree is at its baseline.
# Run:  bash lib/core/forge-fence-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
F="$ROOT/lib/core/forge-fence.sh"

fx="$(mktemp -d)"; trap 'rm -rf "$fx"' EXIT
mkdir -p "$fx/bin" "$fx/scripts/lib" "$fx/lib/core"
cp "$ROOT/lib/core/forge-report.sh" "$fx/lib/core/forge-report.sh"
cat > "$fx/bin/cckit" <<'CCKIT'
#!/usr/bin/env bash
LIB="$ROOT/lib"
cmd="${1:-}"; shift || true
case "$cmd" in
  a) source "$LIB/clean.sh"; clean_run ;;
esac
CCKIT
printf 'clean_run() { git status; forge_rest repos/o/r; }\n' > "$fx/scripts/lib/clean.sh"
printf 'forge_rest() { curl -sS "https://api.github.com/$1"; }\ngh auth token\n' > "$fx/scripts/lib/forge-github.sh"
printf 'gh_rest_issue_json() { forge_rest "repos/$1/issues/$2"; }\n' > "$fx/scripts/lib/gh-rest.sh"
printf 'gh api never-counted\n' > "$fx/scripts/lib/noise-test.sh"

printf 'gh=0\napi=0\n' > "$fx/lib/core/forge-fence.baseline"
out="$(bash "$F" --root "$fx")"; rc=$?
t "a clean tree passes at baseline 0"            "$rc" "0"
t "the pass line carries both counts"            "$(printf '%s' "$out" | grep -c '^ok forge fence: gh 0/0 · api 0/0')" "1"

printf 'read_it() { gh issue view "$1" --json title; }\n' > "$fx/scripts/lib/stray.sh"
out="$(bash "$F" --root "$fx")"; rc=$?
t "a gh call outside the layer fails"            "$rc" "1"
t "the offender is named"                        "$(printf '%s' "$out" | grep -c '    scripts/lib/stray.sh')" "1"
t "the message says what to call instead"        "$(printf '%s' "$out" | grep -c 'Call the layer (forge_\*, gh_rest_\*) instead')" "1"

rm "$fx/scripts/lib/stray.sh"
printf 'fetch() { curl -sS https://api.github.com/repos/o/r; }\n' > "$fx/scripts/lib/direct.sh"
out="$(bash "$F" --root "$fx")"; rc=$?
t "a curl to the API outside the layer fails"    "$rc" "1"
t "the api offender is named"                    "$(printf '%s' "$out" | grep -c '    scripts/lib/direct.sh')" "1"
printf '# a comment that names api.github.com is not a call\nx=1\n' > "$fx/scripts/lib/direct.sh"
bash "$F" --root "$fx" >/dev/null; t "a comment naming the host is not a call" "$?" "0"
rm "$fx/scripts/lib/direct.sh"

printf 'read_it() { gh issue view "$1"; }\n' > "$fx/scripts/lib/stray.sh"
printf 'gh=1\napi=0\n' > "$fx/lib/core/forge-fence.baseline"
bash "$F" --root "$fx" >/dev/null; t "at the baseline passes"  "$?" "0"
rm "$fx/scripts/lib/stray.sh"
out="$(bash "$F" --root "$fx")"
t "under the baseline passes and asks for the ratchet" "$(printf '%s' "$out" | grep -c 'ratchet it: lib/core/forge-fence.sh --write')" "1"
bash "$F" --root "$fx" --write >/dev/null
t "--write records the current counts"          "$(tr '\n' ' ' < "$fx/lib/core/forge-fence.baseline")" "gh=0 api=0 "

rm "$fx/lib/core/forge-fence.baseline"
bash "$F" --root "$fx" >/dev/null 2>&1; t "no baseline is rc 1" "$?" "1"
printf 'gh=x\n' > "$fx/lib/core/forge-fence.baseline"
bash "$F" --root "$fx" >/dev/null 2>&1; t "a malformed baseline is rc 1" "$?" "1"

# The real tree is at its baseline.
bash "$F" >/dev/null; t "the repository passes its own fence" "$?" "0"
t "the repository's baseline is 0/0" "$(tr '\n' ' ' < "$ROOT/lib/core/forge-fence.baseline")" "gh=0 api=0 "

[ "$fail" -eq 0 ] && echo "ALL OK (forge-fence)"
exit "$fail"
