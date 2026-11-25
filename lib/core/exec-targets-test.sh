#!/usr/bin/env bash
# shellcheck shell=bash
# exec-targets-test.sh — #534: every `exec "$ROOT/<path>"` target in bin/cckit is executable in the
# index. `cckit release --next` failed with Permission denied because lib/core/version-bump.sh was
# mode 100644 while bin/cckit:476 exec'd it; the mode is read from the index, so a local chmod that
# is not committed does not count.
# Run:  bash lib/core/exec-targets-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0; n=0
while IFS= read -r p; do
  n=$((n+1))
  mode="$(git -C "$ROOT" ls-files -s -- "$p" | cut -d' ' -f1)"
  if [ "$mode" = "100755" ]; then echo "ok: $p is 100755"
  else echo "FAIL: $p is '${mode:-untracked}', want 100755 (git update-index --chmod=+x $p)"; fail=1; fi
done < <(grep -oE 'exec "\$ROOT/[^"]+"' "$ROOT/bin/cckit" | sed -E 's/^exec "\$ROOT\/(.*)"$/\1/' | sort -u)
[ "$n" -gt 0 ] || { echo "FAIL: no exec \"\$ROOT/…\" target found in bin/cckit"; fail=1; }
[ "$fail" -eq 0 ] && echo "ALL OK (exec-targets, $n targets)"
exit "$fail"
