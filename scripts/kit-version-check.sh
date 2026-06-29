#!/usr/bin/env bash
# claude-kit — CLI-style update check. Compares a kit-initialized project's recorded kitVersion
# against the installed plugin version, and prints a one-line notice when the project is behind.
# Safe no-op when it can't determine either side. Used by the SessionStart hook and /kit-update.
#
# Usage: kit-version-check.sh [--target DIR] [--plugin-root DIR] [--quiet]
set -uo pipefail

TARGET="$PWD"; PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"; QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --plugin-root) PLUGIN_ROOT="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    *) shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || exit 0
cfg="$TARGET/.claude/kit.config.json"
[[ -f "$cfg" ]] || exit 0

# Locate the installed plugin's plugin.json: explicit root → env → best-effort glob.
pj=""
[[ -n "$PLUGIN_ROOT" && -f "$PLUGIN_ROOT/.claude-plugin/plugin.json" ]] && pj="$PLUGIN_ROOT/.claude-plugin/plugin.json"
if [[ -z "$pj" ]]; then
  pj="$(ls -t "$HOME"/.claude/plugins/*/claude-kit*/.claude-plugin/plugin.json \
            "$HOME"/.claude/plugins/*/*/claude-kit*/.claude-plugin/plugin.json \
            "$HOME"/.claude/plugins/*/*/claude-kit*/*/.claude-plugin/plugin.json \
            "$HOME"/.claude/plugins/*/*/*/claude-kit*/.claude-plugin/plugin.json 2>/dev/null | head -1 || true)"
fi
[[ -n "$pj" && -f "$pj" ]] || exit 0

have="$(jq -r '.kitVersion // "0.0.0"' "$cfg" 2>/dev/null || echo 0.0.0)"
latest="$(jq -r '.version // "0.0.0"' "$pj" 2>/dev/null || echo 0.0.0)"

# Branded one-line status — ALWAYS shown (the banner is never silenced unless --quiet).
# Renders the seed-head sigil when the brand lib is present; plain text otherwise.
SIGIL="$TARGET/.claude/lib/kit-sigil.sh"
banner() {  # banner <skill-slot> <note>
  [[ $QUIET -eq 1 ]] && return 0
  if [[ -f "$SIGIL" ]]; then
    # shellcheck source=/dev/null
    source "$SIGIL"; kit_sigil "$1" "$2"
  else
    echo "claude-kit${1:+ · $1}${2:+ · $2}"
  fi
}

# Up to date — still announce it (no longer a silent no-op).
if [[ "$have" == "$latest" ]]; then
  banner "v$latest" "al día · up to date"
  exit 0
fi

# Is `latest` strictly newer than `have`? We can't lean on `sort -V` for the whole string:
# neither GNU nor BSD `sort -V` implements SemVer pre-release precedence (both rank
# `0.7.0-beta.1` ABOVE `0.7.0`, which is wrong — a pre-release must be LOWER than its release).
# So we split each version into a numeric CORE (x.y.z) and an optional PRE (after the first `-`),
# and compare per SemVer §11:
#   1. cores differ        → the higher core wins (sort -V is reliable on pure numeric cores)
#   2. cores equal:
#        stable  vs pre    → stable is newer (a release outranks any pre-release of same core)
#        pre     vs pre    → compare the pre identifiers (sort -V, e.g. beta.1 < beta.2)
# POSIX-ish: only bash parameter expansion + a tiny `sort -V` on suffix-free strings.
ver_is_newer() {  # ver_is_newer HAVE LATEST → exit 0 if LATEST strictly newer than HAVE
  local h="$1" l="$2"
  [[ "$h" == "$l" ]] && return 1
  local hcore="${h%%-*}" lcore="${l%%-*}" hpre="" lpre="" top
  [[ "$h" == *-* ]] && hpre="${h#*-}"
  [[ "$l" == *-* ]] && lpre="${l#*-}"
  if [[ "$hcore" != "$lcore" ]]; then
    top="$(printf '%s\n%s\n' "$hcore" "$lcore" | sort -V | tail -1)"
    [[ "$top" == "$lcore" ]]; return
  fi
  # cores equal — decide on the pre-release component
  [[ -z "$lpre" && -n "$hpre" ]] && return 0   # latest = release, have = pre  → newer
  [[ -n "$lpre" && -z "$hpre" ]] && return 1   # latest = pre,     have = release → not newer
  # both pre-release on the same core
  top="$(printf '%s\n%s\n' "$hpre" "$lpre" | sort -V | tail -1)"
  [[ "$top" == "$lpre" && "$hpre" != "$lpre" ]]
}

if ver_is_newer "$have" "$latest"; then
  banner "update available" "$have -> $latest · run /kit-update to merge new features (your edits are preserved)"
  exit 10  # signal: behind
fi

# have is NEWER than the installed plugin — local dev ahead of the release.
banner "v$have" "ahead of plugin $latest"
exit 0
