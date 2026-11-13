#!/usr/bin/env bash
# test.sh — cckit behavioral test runner. Discovers every `*-test.sh` under bin/ and scripts/ and
# runs each as a self-contained test (a test exits non-zero on failure, prints its own ok/FAIL
# lines). Exits non-zero if any test fails. bash 3.2 compatible (no mapfile/associative arrays,
# no `wait -n`).
#
#   scripts/test.sh                 run every discovered test, several files at a time
#   scripts/test.sh <pattern>       run only tests whose path matches <pattern> (grep -E)
#   scripts/test.sh -j <N>          run at most N files at once (also: --jobs N, TEST_JOBS=N)
#   scripts/test.sh --serial        one file at a time, in sorted order (same as -j 1)
#   scripts/test.sh --timings       print wall seconds per file, slowest first (also: TEST_TIMINGS=1)
#
# Parallelism (#455). Test files are independent: each builds its fixtures under its own `mktemp -d`
# and none binds a fixed port, so files run N at a time. N defaults to the CPU count, capped at 8.
# A file whose first 30 lines carry the marker `# test-runner: serial` is held back and run alone
# after the parallel phase — for a test that measures a race or a timeout and would read CPU
# contention as a failure.
#
# Output. One `ok` / `FAIL` line per file as it finishes (completion order when N > 1). Each file's
# output is captured to its own file, so the output of a failing test is printed whole, after the
# run, in sorted order — never interleaved with another file's.
#
# Folded into scripts/check.sh and run in CI (.github/workflows/test.yml).
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

note() { printf '%s\n' "$*" >&2; }

# ── worker: run ONE test file, record its result ──────────────────────────────────────────────
# Invoked by the pool below as `test.sh --run-one <index> <file>`. Writes <dir>/<index>.out (the
# test's combined output), .rc (exit code) and .sec (wall seconds), then prints the one status
# line. A status line is a single short write, so concurrent workers do not interleave.
if [ "${1:-}" = "--run-one" ]; then
  idx="$2"; t="$3"; dir="${TEST_RUN_DIR:?--run-one is internal: TEST_RUN_DIR is not set}"
  # Seal the test from the caller's kit environment (#369): a shell that ran load_kit_config, or
  # set KIT_CONFIG, exports KIT_*/CCKIT_*/EFFORT_* that would point a test at the developer's
  # project instead of its own fixture. Each test still sets whatever it needs itself.
  # shellcheck source=/dev/null
  . scripts/lib/test-env.sh
  seal=(-u TEST_RUN_DIR)
  while IFS= read -r a; do [ -n "$a" ] && seal+=("$a"); done < <(test_env_unset_args)
  # Fixture commits are never signed (#455). A developer whose global git config sets
  # commit.gpgsign pays one gpg call per fixture commit (measured: 60 commits took 12.9 s signed,
  # 2.8 s unsigned), and gpg-agent refuses concurrent requests ("signing failed: Cannot allocate
  # memory"), which fails a fixture at random once files run in parallel. GIT_CONFIG_COUNT is git's
  # environment form of `-c`: it overrides these two keys and leaves the rest of the developer's
  # config, identity included, as it is. Appended after any pairs the caller already exported.
  gc_n="${GIT_CONFIG_COUNT:-0}"; case "$gc_n" in ''|*[!0-9]*) gc_n=0 ;; esac
  start=$SECONDS
  env "${seal[@]}" \
    GIT_CONFIG_COUNT="$((gc_n + 2))" \
    "GIT_CONFIG_KEY_$gc_n=commit.gpgsign" "GIT_CONFIG_VALUE_$gc_n=false" \
    "GIT_CONFIG_KEY_$((gc_n + 1))=tag.gpgsign" "GIT_CONFIG_VALUE_$((gc_n + 1))=false" \
    bash "$t" > "$dir/$idx.out" 2>&1; rc=$?
  sec=$((SECONDS - start))
  printf '%s\n' "$sec" > "$dir/$idx.sec"
  printf '%s\n' "$rc" > "$dir/$idx.rc"
  if [ "$rc" -eq 0 ]; then note "  ok   $t"; else note "  FAIL $t  (rc=$rc)"; fi
  exit 0   # the result is in .rc; a non-zero exit here would make xargs stop feeding the pool
fi

# ── arguments ─────────────────────────────────────────────────────────────────────────────────
PATTERN=""; JOBS="${TEST_JOBS:-}"; TIMINGS="${TEST_TIMINGS:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -j|--jobs) [ "$#" -ge 2 ] || { note "test: $1 needs a number"; exit 2; }; JOBS="$2"; shift 2 ;;
    --jobs=*)  JOBS="${1#--jobs=}"; shift ;;
    -j[0-9]*)  JOBS="${1#-j}"; shift ;;
    --serial)  JOBS=1; shift ;;
    --timings) TIMINGS=1; shift ;;
    -*)        note "test: unknown option '$1'"; exit 2 ;;
    *)         PATTERN="$1"; shift ;;
  esac
done

# Default job count: the CPU count, capped at 8 (past that the git-heavy fixtures contend on disk).
if [ -z "$JOBS" ]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)"
  case "$JOBS" in ''|*[!0-9]*) JOBS=2 ;; esac
  [ "$JOBS" -le 8 ] || JOBS=8
fi
case "$JOBS" in
  ''|*[!0-9]*|0) note "test: job count must be a positive integer, got '$JOBS'"; exit 2 ;;
esac

# ── discovery ─────────────────────────────────────────────────────────────────────────────────
# Deterministic: newline-separated, sorted, optionally filtered. `par` runs in the pool; `ser` is
# held back for the serial phase (see the marker in the header).
tests=(); par=(); ser=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -z "$PATTERN" ] || grep -qE "$PATTERN" <<<"$f" || continue
  tests+=("$f")
  if [ "$JOBS" -gt 1 ] && grep -qE '^# test-runner: serial([[:space:]]|$)' <<<"$(head -n 30 "$f")"; then
    ser+=("$f")
  else
    par+=("$f")
  fi
done < <(find bin scripts -type f -name '*-test.sh' 2>/dev/null | sort)

if [ "${#tests[@]}" -eq 0 ]; then
  note "test: no *-test.sh found${PATTERN:+ matching '$PATTERN'}"
  exit 0
fi

# shellcheck source=/dev/null
. scripts/lib/test-env.sh
sealed="$(test_env_unset_args | grep -c -- '^-u$')"

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cckit-test.XXXXXX")" || { note "test: mktemp failed"; exit 1; }
trap 'rm -rf "$RUN_DIR"' EXIT
export TEST_RUN_DIR="$RUN_DIR"

note "==> cckit tests — ${#tests[@]} file(s)${PATTERN:+ (filter: $PATTERN)}, $JOBS at a time"
[ "$sealed" -eq 0 ] || note "==> sealed $sealed inherited KIT_*/CCKIT_*/EFFORT_* variable(s)"

# ── run ───────────────────────────────────────────────────────────────────────────────────────
# The pool is xargs -P: it is in POSIX-era BSD and GNU alike, and bash 3.2 has no `wait -n` to
# build one from. Each line fed to it is "<index> <file>"; the index keys the result files, so a
# result is found again without a map (test paths under bin/ and scripts/ hold no whitespace).
began=$SECONDS
i=0; list=""
for t in ${par[@]+"${par[@]}"}; do list="$list$i $t"$'\n'; i=$((i+1)); done
if [ -n "$list" ]; then
  printf '%s' "$list" | xargs -P "$JOBS" -n 2 bash scripts/test.sh --run-one
fi
if [ "${#ser[@]}" -gt 0 ]; then
  note "==> ${#ser[@]} file(s) marked serial, run alone"
  for t in "${ser[@]}"; do bash scripts/test.sh --run-one "$i" "$t"; i=$((i+1)); done
fi
took=$((SECONDS - began))

# ── collect ───────────────────────────────────────────────────────────────────────────────────
# Read the results back in the order they were queued (sorted, parallel files then serial ones).
# A file with no .rc never reported — its worker was killed — and counts as a failure.
pass=0; failn=0; failed=""; i=0
for t in ${par[@]+"${par[@]}"} ${ser[@]+"${ser[@]}"}; do
  rc="$(cat "$RUN_DIR/$i.rc" 2>/dev/null)"; [ -n "$rc" ] || rc="no result"
  if [ "$rc" = 0 ]; then
    pass=$((pass+1))
  else
    failn=$((failn+1)); failed="$failed$t"$'\n'
    note ""
    note "---- FAIL $t  (rc=$rc)"
    [ ! -f "$RUN_DIR/$i.out" ] || sed 's/^/        /' "$RUN_DIR/$i.out" >&2
  fi
  i=$((i+1))
done

if [ "$TIMINGS" = 1 ]; then
  note ""
  note "==> wall seconds per file, slowest first"
  i=0
  for t in ${par[@]+"${par[@]}"} ${ser[@]+"${ser[@]}"}; do
    printf '%s\t%s\n' "$(cat "$RUN_DIR/$i.sec" 2>/dev/null || echo '?')" "$t"; i=$((i+1))
  done | sort -t "$(printf '\t')" -k1,1nr -k2,2 | sed 's/^/  /' >&2
fi

note ""
note "==> $pass passed, $failn failed in ${took}s"
if [ "$failn" -ne 0 ]; then
  note "failed:"; printf '%s' "$failed" | sed 's/^/  - /' >&2
  exit 1
fi
note "PASS all tests"
