#!/usr/bin/env bash
# shellcheck shell=bash
# hook-refresh.sh — tell an unmodified kit hook from a customized one, so `init --upgrade` can
# refresh the first and only report the second (#370).
#
# `init --upgrade` preserves every existing file. That protects a customized hook, but it also
# froze unmodified ones: a hook installed from a template never received later template fixes.
#
#   hook_refresh_state <installed> <template> <kit-root> [manifest] [rel]
#     prints one word:
#       current  the installed hook already equals the template
#       refresh  it equals an EARLIER version of the template (from <kit-root>'s git history,
#                following renames), or the hash the manifest recorded for <rel> — unmodified,
#                safe to overwrite
#       drifted  it matches no version the kit shipped — the repo customized it; keep it, report it
#       missing  no installed file
#
# Templates with {{VARS}} or IF blocks are rendered per project, so their history cannot be
# compared byte for byte; for those only the manifest can prove a file unmodified.
# Requires git, plus shasum or sha256sum.
# errors: pure — prints a verdict, rc 0
# bash 3.2 + zsh compatible.

_hr_hash_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 < "$1" | awk '{print $1}'
  else sha256sum < "$1" | awk '{print $1}'; fi
}
_hr_hash_stdin() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
  else sha256sum | awk '{print $1}'; fi
}

# _hr_history_hashes <kit-root> <template> — the hash of every committed version of <template>,
# one per line, following renames. Prints nothing when <kit-root> is not a git checkout (an npm or
# Homebrew install), which leaves only the manifest as evidence.
_hr_history_hashes() {
  local root="$1" tpl="$2" rel line c=""
  rel="${tpl#"$root"/}"
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$root" log --follow --format='C %H' --name-only -- "$rel" 2>/dev/null | while IFS= read -r line; do
    case "$line" in
      "C "*) c="${line#C }" ;;
      "") : ;;
      *) [ -n "$c" ] && git -C "$root" show "$c:$line" 2>/dev/null | _hr_hash_stdin ;;
    esac
  done
}

hook_refresh_state() {
  local inst="$1" tpl="$2" root="$3" mf="${4:-}" rel="${5:-}" cur h
  [ -f "$inst" ] || { echo missing; return 0; }
  cur="$(_hr_hash_file "$inst")"
  if [ "$cur" = "$(_hr_hash_file "$tpl")" ]; then echo current; return 0; fi
  if [ -n "$mf" ] && [ -n "$rel" ] && [ -f "$mf" ] && command -v jq >/dev/null 2>&1; then
    h="$(jq -r --arg r "$rel" '.entries[$r].hash // empty' "$mf" 2>/dev/null)"
    [ -n "$h" ] && [ "$h" = "$cur" ] && { echo refresh; return 0; }
  fi
  if ! grep -qE '\{\{[A-Za-z_]+\}\}|<!-- IF:' "$tpl" 2>/dev/null; then
    if _hr_history_hashes "$root" "$tpl" | grep -qx "$cur"; then echo refresh; return 0; fi
  fi
  echo drifted
}
