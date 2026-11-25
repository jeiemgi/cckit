#!/usr/bin/env bash
# shellcheck shell=bash
# leak-fence-test.sh — selftest of the leak fence (lib/core/leak-fence.sh, gate step 3).
# Builds a throwaway git repository under its own mktemp -d and checks:
#   - a tracked file containing a list word fails the fence; removing the file passes it
#   - with no list present, the built-in word still fails (fresh clone, fork)
#   - CCKIT_LEAK_WORDS (CI) is read, `|`-separated, and a hit prints file:line only — never the word
#   - comments and blank lines in the list are skipped
# The built-in word is spelled in two halves below so this test file itself never trips the fence.
# Run:  bash scripts/leak-fence-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
repo="$tmp/repo"; mkdir -p "$repo/lib/core" "$repo/.cckit"
cp "$ROOT/lib/core/leak-fence.sh" "$repo/lib/core/leak-fence.sh"
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false add -A
git -C "$repo" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -qm init
printf '.cckit/\n' > "$repo/.gitignore"

# The fence under test runs inside the fixture repo, with the fixture's own list file.
fence() { ( cd "$repo" && CCKIT_LEAK_WORDS_FILE="$repo/.cckit/leak-words" bash -c '. lib/core/leak-fence.sh; leak_fence_check' 2>&1 ); }
track() { printf '%s\n' "$2" > "$repo/$1"; git -C "$repo" add "$1"; }
untrack() { git -C "$repo" rm -q --cached "$repo/$1"; rm -f "$repo/$1"; }

builtin_word="te""dos"
word="zorblax"

# 1. no list, clean tree → passes
out="$(fence)"; rc=$?
t "clean tree, no list: passes" "$rc" "0"

# 2. no list present → the built-in word still fails
track "README.md" "powered by $builtin_word"
out="$(fence)"; rc=$?
t "no list: built-in word fails" "$rc" "1"
case "$out" in *"README.md:1"*) echo "ok: hit reported as file:line" ;; *) echo "FAIL: hit not reported: $out"; fail=1 ;; esac
case "$out" in *"$builtin_word"*) echo "FAIL: output echoes the word: $out"; fail=1 ;; *) echo "ok: output does not echo the word" ;; esac
untrack "README.md"

# 3. a list word in a tracked file fails; removing the file passes (fail → pass)
printf '# private words\n\n%s\n' "$word" > "$repo/.cckit/leak-words"
track "docs/note.md" "the $word launch" 2>/dev/null || { mkdir -p "$repo/docs"; track "docs/note.md" "the $word launch"; }
out="$(fence)"; rc=$?
t "list word in a tracked file: fails" "$rc" "1"
case "$out" in *"docs/note.md:1"*) echo "ok: list hit reported as file:line" ;; *) echo "FAIL: list hit not reported: $out"; fail=1 ;; esac
case "$out" in *"$word"*) echo "FAIL: output echoes the list word: $out"; fail=1 ;; *) echo "ok: output does not echo the list word" ;; esac
untrack "docs/note.md"
out="$(fence)"; rc=$?
t "file removed: passes" "$rc" "0"

# 4. case-insensitive, and the list itself is never scanned (it is untracked)
track "docs/caps.md" "$(printf '%s' "$word" | tr a-z A-Z)"
out="$(fence)"; rc=$?
t "list word in caps: fails (case-insensitive)" "$rc" "1"
untrack "docs/caps.md"
out="$(fence)"; rc=$?
t "untracked list file is not itself a hit" "$rc" "0"

# 5. CI: CCKIT_LEAK_WORDS, `|`-separated, with no list file
rm -f "$repo/.cckit/leak-words"
track "docs/ci.md" "mentions quuxcorp here"
out="$( cd "$repo" && CCKIT_LEAK_WORDS='frobnic|quuxcorp' bash -c '. lib/core/leak-fence.sh; leak_fence_check' 2>&1 )"; rc=$?
t "CCKIT_LEAK_WORDS hit: fails" "$rc" "1"
case "$out" in *"quuxcorp"*) echo "FAIL: output echoes the env word: $out"; fail=1 ;; *) echo "ok: output does not echo the env word" ;; esac
out="$( cd "$repo" && CCKIT_LEAK_WORDS='frobnic' bash -c '. lib/core/leak-fence.sh; leak_fence_check' 2>&1 )"; rc=$?
t "CCKIT_LEAK_WORDS without the word: passes" "$rc" "0"
untrack "docs/ci.md"

# 5b. a secret set from the list file carries its comment lines, one with `|`: comments are dropped
# before the split, so the scan still runs and still catches the word
track "docs/ci.md" "mentions quuxcorp here"
out="$( cd "$repo" && CCKIT_LEAK_WORDS=$'# words (a|b), see docs\nfrobnic|quuxcorp' bash -c '. lib/core/leak-fence.sh; leak_fence_check' 2>&1 )"; rc=$?
t "CCKIT_LEAK_WORDS with a comment line containing |: comment skipped, word caught" "$rc" "1"
case "$out" in *"docs/ci.md:1"*) echo "ok: hit reported with the comment present" ;; *) echo "FAIL: scan did not run: $out"; fail=1 ;; esac
# 5c. a pattern that does not compile fails the gate instead of passing on an empty scan
out="$( cd "$repo" && CCKIT_LEAK_WORDS='(unbalanced' bash -c '. lib/core/leak-fence.sh; leak_fence_check' 2>&1 )"; rc=$?
t "invalid pattern: the gate fails, it does not pass silently" "$rc" "1"
case "$out" in *"did not compile"*) echo "ok: names the cause" ;; *) echo "FAIL: cause not named: $out"; fail=1 ;; esac
untrack "docs/ci.md"

# 6. the fence file itself names the built-in word and is excluded from its own scan
out="$(fence)"; rc=$?
t "the fence source is not a hit" "$rc" "0"

[ "$fail" -eq 0 ] && echo "leak-fence-test: PASS" || { echo "leak-fence-test: FAIL"; exit 1; }
