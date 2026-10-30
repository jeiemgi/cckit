#!/usr/bin/env bash
# contribute-root-test.sh — `cckit contribute` acts on the cckit checkout containing cwd (#368).
# Hermetic: a fixture "cckit" repo whose scripts/contribute.sh is a stub that reports where it ran,
# so the real gate (scripts/check.sh) never runs from inside the test suite.
# Run: bash scripts/lib/contribute-root-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/contribute-root.sh"

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fx="$tmp/cckit"; plain="$tmp/plain"
git init -q "$fx"
mkdir -p "$fx/bin" "$fx/scripts"
printf '#!/usr/bin/env bash\n' > "$fx/bin/cckit"
printf '#!/usr/bin/env bash\necho "STUB pwd=$(pwd -P) branch=$(git rev-parse --abbrev-ref HEAD) args=$*"\n' > "$fx/scripts/contribute.sh"
chmod +x "$fx/bin/cckit" "$fx/scripts/contribute.sh"
git -C "$fx" add -A && git -C "$fx" -c user.email=t@t -c user.name=t commit -q -m init
wt="$fx/.claude/worktrees/task+1-x"
git -C "$fx" worktree add -q -b task/1-x "$wt"
git init -q "$plain"
wtp="$(cd "$wt" && pwd -P)"

t "a worktree resolves to itself"            "$(cd "$(contribute_root "$wt/scripts" /installed)" && pwd -P)" "$wtp"
t "the main checkout resolves to itself"     "$(contribute_root "$fx" /installed)" "$(git -C "$fx" rev-parse --show-toplevel)"
t "a non-cckit repo falls back to installed" "$(contribute_root "$plain" /installed)" "/installed"
t "outside any repo falls back to installed" "$(contribute_root / /installed)" "/installed"

# End to end through the real dispatcher: run from inside the fixture worktree, the fixture
# worktree's own contribute.sh must run, on the worktree's branch.
out="$(cd "$wt/scripts" && bash "$ROOT/bin/cckit" contribute --dry-run "a summary" 2>/dev/null)"
t "cckit contribute runs in the worktree"    "$(printf '%s' "$out" | sed -n 's/.*pwd=\([^ ]*\).*/\1/p')" "$wtp"
t "on the worktree's branch"                 "$(printf '%s' "$out" | sed -n 's/.*branch=\([^ ]*\).*/\1/p')" "task/1-x"
t "with the caller's arguments"              "$(printf '%s' "$out" | sed -n 's/.*args=//p')" "--dry-run a summary"

[ "$fail" -eq 0 ] && echo "contribute-root: all passed" || echo "contribute-root: FAILURES"
exit "$fail"
