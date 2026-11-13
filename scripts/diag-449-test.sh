#!/usr/bin/env bash
# diag-449-test.sh — TEMPORARY (#449): run the real ports test repeatedly in the serial phase,
# where CI has failed, and print what a collision leaves behind. Removed before the PR is ready.
#
# test-runner: serial
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
echo "env: $(uname -srm) nproc=$(nproc 2>/dev/null) TMPDIR=${TMPDIR:-unset} stdin=$(readlink /proc/$$/fd/0 2>/dev/null)"
echo "env: tmp fs=$(stat -f -c %T /tmp 2>/dev/null) $(grep SigIgn /proc/$$/status 2>/dev/null | tr '\t' ' ')"
echo "env: $(git --version) $(mv --version 2>/dev/null | sed -n 1p) $(bash --version | sed -n 1p)"
echo "env: leftover processes: $(ps -eo pid,etimes,args 2>/dev/null | grep -vE ' (ps|grep|sed|bash scripts/(test|check)\.sh|bash .*diag-449)' | awk '$2 < 600' | wc -l)"
ps -eo pid,ppid,etimes,args 2>/dev/null | awk '$3 < 600' | grep -vE 'ps -eo|awk ' | cut -c1-150 | sed 's/^/  ps: /'
fails=0; it=0; ITERS="${DIAG_ITERS:-70}"
while [ "$it" -lt "$ITERS" ]; do
  it=$((it+1))
  out="$(bash "$dir/lib/worktree-ports-test.sh" 2>&1)" || { fails=$((fails+1)); echo "=== run $it failed"; printf '%s\n' "$out"; }
done
echo "diag-449: $fails failed run(s) of $ITERS"
exit 1   # always shown: the runner prints a file's output only when it fails
