#!/usr/bin/env bash
# version-bump.sh - SemVer + Conventional Commits. ONE implementation, shared by `cckit release`
# and the release workflow: compute the next version from the commits since the last tag, or write
# a version into the project's manifests.
#
#   version-bump.sh --next            echo the next version (no side effects)
#   version-bump.sh --emit            echo `bump=<level>` + `next=<version>` (for $GITHUB_OUTPUT)
#   version-bump.sh --write <version> set the version in cckit.config.json + plugin.json + package.json
#
# Bump rules (Conventional Commits): a `feat!:`/`type!:` or a `BREAKING CHANGE` footer -> major;
# `feat:` -> minor; `fix|perf|refactor|revert:` -> patch; non-functional types
# (`docs|chore|style|test|ci|build`) and anything else -> none (no release).
# no commits -> none (no release).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

vb_current() { git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'; }

vb_level() {
  local range="$1" log
  log="$(git -C "$ROOT" log --format='%s%n%b' $range 2>/dev/null || true)"
  [ -n "$log" ] || { echo none; return; }
  if printf '%s\n' "$log" | grep -qE '(^|[[:space:]])BREAKING CHANGE|^[a-z]+(\([^)]*\))?!:'; then echo major; return; fi
  if printf '%s\n' "$log" | grep -qE '^feat(\([^)]*\))?:'; then echo minor; return; fi
  if printf '%s\n' "$log" | grep -qE '^(fix|perf|refactor|revert)(\([^)]*\))?:'; then echo patch; return; fi
  # Only non-functional commits (docs/chore/style/test/ci/build, or untyped) -> no release.
  echo none
}

vb_next() {
  local cur="${1:-0.0.0}" level="$2" M m p rest
  M="${cur%%.*}"; rest="${cur#*.}"; m="${rest%%.*}"; p="${rest#*.}"
  case "$level" in
    major) echo "$((M+1)).0.0" ;;
    minor) echo "$M.$((m+1)).0" ;;
    patch) echo "$M.$m.$((p+1))" ;;
    *)     echo "$cur" ;;
  esac
}

vb_write() {
  local v="$1" f
  command -v jq >/dev/null || { echo "version-bump: jq required to --write" >&2; return 1; }
  for f in cckit.config.json .claude-plugin/plugin.json package.json; do
    [ -f "$ROOT/$f" ] || continue
    if [ "$f" = "cckit.config.json" ]; then jq --arg v "$v" '.kitVersion=$v' "$ROOT/$f" > "$ROOT/$f.tmp"
    else jq --arg v "$v" '.version=$v' "$ROOT/$f" > "$ROOT/$f.tmp"; fi
    mv "$ROOT/$f.tmp" "$ROOT/$f" && echo "  set $f -> $v"
  done
}

_range() { local cur; cur="$(vb_current)"; if [ -n "$cur" ]; then echo "v$cur..HEAD"; else echo "HEAD"; fi; }

case "${1:-}" in
  --next)  vb_next "$(vb_current)" "$(vb_level "$(_range)")" ;;
  --emit)  printf 'bump=%s\n' "$(vb_level "$(_range)")"; printf 'next=%s\n' "$(vb_next "$(vb_current)" "$(vb_level "$(_range)")")" ;;
  --write) vb_write "${2:?usage: --write <version>}" ;;
  *) echo "usage: version-bump.sh --next | --emit | --write <version>" >&2; exit 2 ;;
esac
