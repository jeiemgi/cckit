#!/usr/bin/env bash
# shellcheck shell=bash
# install-test.sh — E537.6: lib/verbs/install.sh refuses without git and says how to get it; with git
# it links bin/cckit into the target dir. Hermetic: a stripped PATH with a tools dir, a temp target.
# Run:  bash lib/verbs/install-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/nogit" "$tmp/withgit" "$tmp/target"
# A PATH where git is absent: only the tools install.sh itself needs (ln, dirname, mkdir … from /bin and /usr/bin
# are reached through a `git`-less dir of symlinks, since /usr/bin holds git on macOS).
for c in ln dirname mkdir echo cd pwd basename sed cat uname; do p="$(command -v "$c" 2>/dev/null || true)"; [ -n "$p" ] && [ -x "$p" ] && ln -sf "$p" "$tmp/nogit/$c"; done
out="$(PATH="$tmp/nogit" /bin/bash "$ROOT/lib/verbs/install.sh" "$tmp/target" 2>&1)"; rc=$?
t "without git: rc 1"                         "$rc" "1"
t "without git: nothing is linked"            "$([ -e "$tmp/target/cckit" ] && echo linked || echo none)" "none"
t "without git: the refusal names git and the fix" "$(printf '%s' "$out" | grep -c 'cckit: git is required.*brew install git')" "1"
# With git: the link is made.
out="$(bash "$ROOT/lib/verbs/install.sh" "$tmp/target" 2>&1)"; rc=$?
t "with git: rc 0"                            "$rc" "0"
t "with git: bin/cckit is linked"             "$(readlink "$tmp/target/cckit")" "$ROOT/bin/cckit"
t "with git: the output names the link"      "$(printf '%s' "$out" | grep -c "linked $tmp/target/cckit")" "1"
[ "$fail" -eq 0 ] && echo "ALL OK (install)"
exit "$fail"
