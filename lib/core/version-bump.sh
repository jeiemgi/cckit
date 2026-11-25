#!/usr/bin/env bash
# version-bump.sh - SemVer + Conventional Commits. ONE implementation, shared by `cckit release`
# and the release workflow: compute the next version from the commits since the last tag, or write
# a version into the project's manifests.
#
#   version-bump.sh --next            echo the next version (no side effects)
#   version-bump.sh --emit            echo `bump=<level>` + `next=<version>` (for $GITHUB_OUTPUT)
#   version-bump.sh --write <version> set the version in cckit.config.json + plugin.json + package.json
#
# Bump rules (Conventional Commits): a `feat!:`/`type!:` or a `BREAKING CHANGE` footer -> major,
# or MINOR while the major is 0 (the same rule as `bump-minor-pre-major: true` in
# release-please-config.json: cckit stays below 1.0 until the maintainer decides otherwise);
# `feat:` -> minor; `fix|perf|refactor|revert:` -> patch; non-functional types
# (`docs|chore|style|test|ci|build`) and anything else -> none (no release).
# no commits -> none (no release).
# A `Release-As: x.y.z` footer in the range overrides the computed version, as release-please
# does; with several, the highest wins. `--next` and `--emit`'s `next=` print it.
# errors: strict — set -e; a bad manifest or missing tag propagates
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

vb_current() { git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'; }

vb_level() {
  local range="$1" log
  log="$(git -C "$ROOT" log --format='%s%n%b' $range 2>/dev/null || true)"
  [ -n "$log" ] || { echo none; return; }
  if grep -qE '(^|[[:space:]])BREAKING CHANGE|^[a-z]+(\([^)]*\))?!:' <<<"$log"; then echo major; return; fi
  if grep -qE '^feat(\([^)]*\))?:' <<<"$log"; then echo minor; return; fi
  if grep -qE '^(fix|perf|refactor|revert)(\([^)]*\))?:' <<<"$log"; then echo patch; return; fi
  # Only non-functional commits (docs/chore/style/test/ci/build, or untyped) -> no release.
  echo none
}

vb_release_as() { # <range> -> the highest `Release-As: x.y.z` footer version, or nothing
  git -C "$ROOT" log --format='%b' "$1" 2>/dev/null \
    | sed -nE 's/^[Rr][Ee][Ll][Ee][Aa][Ss][Ee]-[Aa][Ss]:[[:space:]]*v?([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

vb_next() {
  local cur="${1:-0.0.0}" level="$2" M m p rest
  M="${cur%%.*}"; rest="${cur#*.}"; m="${rest%%.*}"; p="${rest#*.}"
  case "$level" in
    major) if [ "$M" -eq 0 ]; then echo "0.$((m+1)).0"; else echo "$((M+1)).0.0"; fi ;;
    minor) echo "$M.$((m+1)).0" ;;
    patch) echo "$M.$m.$((p+1))" ;;
    *)     echo "$cur" ;;
  esac
}

vb_write() {
  local v="$1" f
  command -v jq >/dev/null || { echo "version-bump: jq required to --write" >&2; return 1; }
  for f in cckit.config.json .claude-plugin/plugin.json package.json docs-site/package.json; do
    [ -f "$ROOT/$f" ] || continue
    if [ "$f" = "cckit.config.json" ]; then jq --arg v "$v" '.kitVersion=$v' "$ROOT/$f" > "$ROOT/$f.tmp"
    else jq --arg v "$v" '.version=$v' "$ROOT/$f" > "$ROOT/$f.tmp"; fi
    mv "$ROOT/$f.tmp" "$ROOT/$f" && echo "  set $f -> $v"
  done
}

_range() { local cur; cur="$(vb_current)"; if [ -n "$cur" ]; then echo "v$cur..HEAD"; else echo "HEAD"; fi; }

_next() { # the Release-As footer if the range has one, else the computed bump
  local ra; ra="$(vb_release_as "$(_range)")"
  if [ -n "$ra" ]; then echo "$ra"; else vb_next "$(vb_current)" "$(vb_level "$(_range)")"; fi
}

case "${1:-}" in
  --next)  _next ;;
  --emit)  printf 'bump=%s\n' "$(vb_level "$(_range)")"; printf 'next=%s\n' "$(_next)" ;;
  --write) vb_write "${2:?usage: --write <version>}" ;;
  *) echo "usage: version-bump.sh --next | --emit | --write <version>" >&2; exit 2 ;;
esac
