#!/usr/bin/env bash
# shellcheck shell=bash
# leak-fence.sh — the leak fence: no private word ships in a tracked file.
#
# cckit is public and is developed next to private repositories. This fence is what keeps a product
# name, a client name, a person's name or a private path from landing in a commit. It is one scan
# with three pattern sources, so there is exactly one place to generalize:
#
#   1. the built-in pattern — the legacy brand name this kit was extracted from (`tedos`). It is
#      always on, so a fresh clone or a fork with no local list still fails on it.
#   2. `.cckit/leak-words` — one extended regex per line, `#` comments and blank lines skipped,
#      matched case-insensitively. The file is gitignored (`.cckit/` as a whole) and MUST stay so:
#      a committed denylist publishes the very words it hides. Resolved through the shared `.cckit/`
#      when kit-state.sh is loaded, so every worktree reads the same list.
#   3. `CCKIT_LEAK_WORDS` — the same patterns for CI, separated by newlines or `|`. Set it from a
#      repository secret; the workflow passes it as an env var to the gate step.
#
# A hit is reported as `file:line` only. The matched text is never printed: in CI the log is
# public, and echoing the line would leak the word the fence exists to hide.
#
# Scope: tracked files (`git grep`), so gitignored runtime state (.cckit/), build output and deps
# never trip it. This file is excluded from its own scan (it names the built-in pattern). Outside a
# git work tree a filtered recursive grep stands in.
#
# Pattern note: `\b` is a GNU extension. git grep -E on macOS compiles patterns with the system
# regcomp, where `\b` matches nothing, so a pattern written with it passes locally and fails in CI.
# Write `([^[:alnum:]]|$)` for a word end instead.
#
# API:
#   leak_fence_patterns        print the active patterns, one per line (built-in first)
#   leak_fence_scan            print `file:line` for every hit; exit 0 when there are hits
#   leak_fence_check           the gate step: 0 clean, 1 hits (file:line list on stderr)
# errors: strict — a missing list file is not an error (built-in word only); a hit returns 1 and names
#         file:line, never the matched text

LEAK_FENCE_BUILTIN='tedos'
LEAK_FENCE_SELF='lib/core/leak-fence.sh'

leak_fence_list_file() {
  if [ -n "${CCKIT_LEAK_WORDS_FILE:-}" ]; then printf '%s\n' "$CCKIT_LEAK_WORDS_FILE"
  elif command -v kit_state_file >/dev/null 2>&1; then kit_state_file leak-words
  else printf '%s\n' ".cckit/leak-words"; fi
}

leak_fence_patterns() {
  local list
  printf '%s\n' "$LEAK_FENCE_BUILTIN"
  list="$(leak_fence_list_file)"
  if [ -f "$list" ]; then
    sed -e 's/^[[:space:]]*#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$list" | grep -v '^$' || true
  fi
  if [ -n "${CCKIT_LEAK_WORDS:-}" ]; then
    # Comment lines are dropped BEFORE the `|` split: a secret set from the list file carries them,
    # and a comment that contains `|` would otherwise split into an unbalanced, invalid pattern.
    printf '%s\n' "$CCKIT_LEAK_WORDS" | sed -e 's/^[[:space:]]*#.*//' | tr '|' '\n' \
      | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true
  fi
}

# Exit: 0 hits printed, 1 no hits, 2 the pattern set did not compile (grep's own rc) — a scan that
# cannot run is not a clean scan, so leak_fence_check fails on 2 instead of passing on empty output.
leak_fence_scan() {
  local pat rc
  pat="$(leak_fence_patterns | paste -sd'|' -)"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git grep -inIE "$pat" -- . ":!$LEAK_FENCE_SELF" | cut -d: -f1,2
    rc=${PIPESTATUS[0]}
  else
    grep -rniIE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.cckit \
      --exclude-dir=dist --exclude=leak-fence.sh "$pat" . | cut -d: -f1,2
    rc=${PIPESTATUS[0]}
  fi
  [ "$rc" -le 1 ] || return 2
  return "$rc"
}

leak_fence_check() {
  local hits n rc
  hits="$(leak_fence_scan 2>/dev/null)"; rc=$?
  if [ "$rc" -ge 2 ]; then
    printf 'x leak fence: the pattern set did not compile (a list or CCKIT_LEAK_WORDS entry is not a valid extended regex); the scan did not run\n' >&2
    return 1
  fi
  [ -z "$hits" ] && return 0
  n="$(printf '%s\n' "$hits" | grep -c .)"
  printf 'x leak fence: %s tracked line(s) contain a private word (file:line; the text is not shown):\n' "$n" >&2
  printf '%s\n' "$hits" | sed -n 1,40p >&2
  return 1
}
