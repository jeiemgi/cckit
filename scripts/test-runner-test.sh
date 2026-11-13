#!/usr/bin/env bash
# test-runner-test.sh — scripts/test.sh runs files in parallel and still reports correctly (#455).
#
# Copies the runner and scripts/lib/test-env.sh into a throwaway tree with fixture `*-test.sh`
# files, then asserts on the copy's exit code and output:
#   - a failing file fails the run, and its output is printed whole, in one block
#   - two files really run at the same time under -j 2 (each waits for the other's marker file)
#   - a file marked `# test-runner: serial` is held back and run after the parallel phase
#   - --serial, a path pattern, and a bad job count behave as the header of test.sh says
#   - every test is sealed from KIT_* variables and runs with commit signing off
# Run:  bash scripts/test-runner-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> '[$2]' lacks '[$3]'"; fail=1 ;; esac; }
no()  { case "$2" in *"$3"*) echo "FAIL: $1 -> '[$2]' contains '[$3]'"; fail=1 ;; *) echo "ok: $1" ;; esac; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
# The caller's own runner settings must not steer the copy under test.
unset TEST_JOBS TEST_TIMINGS TEST_RUN_DIR
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal

# fixture <name> — a fresh tree holding the runner; echoes its path.
fixture() {
  local d="$tmp/$1"
  mkdir -p "$d/scripts/lib" "$d/bin" "$d/shared"
  cp "$ROOT/scripts/test.sh" "$d/scripts/test.sh"
  cp "$ROOT/scripts/lib/test-env.sh" "$d/scripts/lib/test-env.sh"
  printf '%s' "$d"
}
run() { # run <fixture dir> [runner args…] -> OUT (stdout+stderr), RC
  local d="$1"; shift
  OUT="$(bash "$d/scripts/test.sh" "$@" 2>&1)"; RC=$?
}

# ── 1. pass, fail, and a failing file's output in one block ────────────────────────────────────
F="$(fixture basic)"
printf '#!/usr/bin/env bash\necho "a says ok"\n' > "$F/scripts/a-pass-test.sh"
printf '#!/usr/bin/env bash\necho "b line one"; echo "b line two" >&2; echo "b line three"; exit 3\n' > "$F/scripts/b-fail-test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$F/scripts/lib/c-pass-test.sh"
printf '#!/usr/bin/env bash\necho "not a test"; exit 9\n' > "$F/scripts/helper.sh"

run "$F" -j 3
t   "a failing file fails the run"            "$RC" "1"
has "the header states the file and job count" "$OUT" "3 file(s), 3 at a time"
has "a passing file gets an ok line"           "$OUT" "  ok   scripts/a-pass-test.sh"
has "the failing file gets a FAIL line + rc"   "$OUT" "  FAIL scripts/b-fail-test.sh  (rc=3)"
has "the summary counts both"                  "$OUT" "2 passed, 1 failed"
has "the failed list names the file"           "$OUT" "  - scripts/b-fail-test.sh"
no  "a passing file's output is not printed"   "$OUT" "a says ok"
no  "a script that is not *-test.sh never runs" "$OUT" "not a test"
block="$(printf '%s\n' "$OUT" | grep -A3 -- '^---- FAIL scripts/b-fail-test.sh  (rc=3)$' | sed 's/^ *//' | tr '\n' '|')"
t   "the failing output is whole, in order, stdout and stderr together" "$block" \
    "---- FAIL scripts/b-fail-test.sh  (rc=3)|b line one|b line two|b line three|"

run "$F" --serial
t   "--serial: the failure still fails the run" "$RC" "1"
has "--serial runs one at a time"               "$OUT" "3 file(s), 1 at a time"
order="$(printf '%s\n' "$OUT" | grep -E '^  (ok|FAIL) ' | awk '{print $2}' | tr '\n' ' ')"
t   "--serial runs in sorted order" "$order" "scripts/a-pass-test.sh scripts/b-fail-test.sh scripts/lib/c-pass-test.sh "

run "$F" 'a-pass|c-pass'
t   "a pattern that skips the failing file passes" "$RC" "0"
has "the pattern is named in the header"           "$OUT" "2 file(s) (filter: a-pass|c-pass)"
has "an all-green run says so"                     "$OUT" "PASS all tests"

run "$F" no-such-file
t   "a pattern matching nothing exits 0" "$RC" "0"
has "…and says nothing was found"        "$OUT" "no *-test.sh found matching 'no-such-file'"

run "$F" --timings a-pass
has "--timings prints the per-file table" "$OUT" "wall seconds per file, slowest first"

TEST_JOBS=1 run "$F" a-pass
has "TEST_JOBS sets the job count" "$OUT" "1 at a time"

for bad in 0 x -3; do
  run "$F" -j "$bad"
  t "-j $bad is refused with rc 2" "$RC" "2"
done
run "$F" --frobnicate
t "an unknown option is refused with rc 2" "$RC" "2"

# ── 2. files really overlap under -j 2 ─────────────────────────────────────────────────────────
# Each file drops its own marker and waits (up to 20 s) for the other's. Run one after the other,
# the first would time out and fail.
F="$(fixture overlap)"
for pair in "one two" "two one"; do
  set -- $pair
  cat > "$F/scripts/$1-test.sh" <<EOF
#!/usr/bin/env bash
: > "$F/shared/$1"
i=0; while [ ! -e "$F/shared/$2" ] && [ "\$i" -lt 200 ]; do sleep 0.1; i=\$((i+1)); done
[ -e "$F/shared/$2" ] || { echo "$1 never saw $2"; exit 1; }
EOF
done
run "$F" -j 2
t "two files run at the same time under -j 2" "$RC" "0"

# ── 3. the serial marker ───────────────────────────────────────────────────────────────────────
# `late` is marked serial and sorts FIRST; it passes only when every unmarked file has finished.
F="$(fixture marker)"
cat > "$F/scripts/a-late-test.sh" <<EOF
#!/usr/bin/env bash
# test-runner: serial
[ -e "$F/shared/p1" ] && [ -e "$F/shared/p2" ] || { echo "ran before the parallel phase ended"; exit 1; }
EOF
for p in p1 p2; do
  printf '#!/usr/bin/env bash\nsleep 0.3\n: > "%s/shared/%s"\n' "$F" "$p" > "$F/scripts/$p-test.sh"
done
run "$F" -j 2
t   "a marked file runs after the parallel phase" "$RC" "0"
has "the runner says how many files were held back" "$OUT" "1 file(s) marked serial, run alone"
last="$(printf '%s\n' "$OUT" | grep -E '^  (ok|FAIL) ' | tail -1)"
t   "the marked file reports last" "$last" "  ok   scripts/a-late-test.sh"
rm -f "$F/shared/p1" "$F/shared/p2"
run "$F" --serial
no  "--serial has no separate serial phase" "$OUT" "marked serial"
t   "…so the marked file runs in sorted order, first, and fails this fixture" "$RC" "1"

# A marked file that fails still fails the run.
F="$(fixture markerfail)"
printf '#!/usr/bin/env bash\n# test-runner: serial\necho "serial broke"; exit 4\n' > "$F/scripts/s-test.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$F/scripts/p-test.sh"
run "$F" -j 2
t   "a failing marked file fails the run" "$RC" "1"
has "…with its rc and output"             "$OUT" "---- FAIL scripts/s-test.sh  (rc=4)"

# ── 4. what every test inherits ────────────────────────────────────────────────────────────────
F="$(fixture env)"
cat > "$F/scripts/env-test.sh" <<'EOF'
#!/usr/bin/env bash
rc=0
[ -z "${KIT_CONFIG:-}" ]   || { echo "KIT_CONFIG leaked: $KIT_CONFIG"; rc=1; }
[ -z "${TEST_RUN_DIR:-}" ] || { echo "TEST_RUN_DIR leaked"; rc=1; }
[ "${KEEP_ME:-}" = 1 ]     || { echo "KEEP_ME was dropped"; rc=1; }
if command -v git >/dev/null 2>&1; then
  [ "$(git config --get commit.gpgsign)" = false ] || { echo "commit.gpgsign is not off"; rc=1; }
  [ "$(git config --get tag.gpgsign)" = false ]    || { echo "tag.gpgsign is not off"; rc=1; }
  [ "$(git config --get test.kept)" = yes ]        || { echo "the caller's own GIT_CONFIG pair was lost"; rc=1; }
fi
exit "$rc"
EOF
OUT="$(KIT_CONFIG=/elsewhere KEEP_ME=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=test.kept GIT_CONFIG_VALUE_0=yes \
       bash "$F/scripts/test.sh" 2>&1)"; RC=$?
t   "a test is sealed, unsigned, and keeps the rest of its environment" "$RC" "0"
[ "$RC" -eq 0 ] || printf '%s\n' "$OUT"
has "the runner reports what it sealed" "$OUT" "sealed 1 inherited"

# ── 5. the result directory is removed ─────────────────────────────────────────────────────────
left="$(TMPDIR="$tmp/td" bash -c 'mkdir -p "$TMPDIR" && bash "$0/scripts/test.sh" >/dev/null 2>&1; ls "$TMPDIR" | wc -l' "$F" | tr -d ' ')"
t "the runner leaves nothing in TMPDIR" "$left" "0"

[ "$fail" -eq 0 ] && echo "test-runner: all passed" || echo "test-runner: FAILURES"
exit "$fail"
