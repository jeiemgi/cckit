#!/usr/bin/env bash
# publish.sh - cut a cckit release and (optionally) publish to the Homebrew tap + npm.
#
# SAFE BY DEFAULT: a dry run that changes nothing and prints every step. It only acts when you
# pass --publish. Built so you can hand it a version later and ship in one command.
#
# Usage:
#   scripts/publish.sh 0.1.0                 # DRY RUN - show the plan, change nothing
#   scripts/publish.sh 0.1.0 --publish       # execute: tag + GitHub release + formula + npm
#   scripts/publish.sh 0.1.0 --publish --no-npm     # skip npm (brew only)
#   scripts/publish.sh 0.1.0 --publish --no-brew    # skip brew (npm only)
# Env: TAP_DIR=~/Dev/jeiemgi/homebrew-cckit (where the tap repo is cloned)
set -euo pipefail

VERSION="${1:-}"; shift || true
PUBLISH=0; DO_NPM=1; DO_BREW=1
for a in "$@"; do case "$a" in
  --publish) PUBLISH=1 ;; --no-npm) DO_NPM=0 ;; --no-brew) DO_BREW=0 ;;
  *) echo "unknown flag: $a" >&2; exit 2 ;;
esac; done

[ -n "$VERSION" ] || { echo "usage: scripts/publish.sh <version> [--publish] [--no-npm] [--no-brew]" >&2; exit 2; }
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must be X.Y.Z" >&2; exit 2; }

root="$(cd "$(dirname "$0")/.." && pwd)"
repo="jeiemgi/cckit"
tag="v$VERSION"
tarball="https://github.com/$repo/archive/refs/tags/$tag.tar.gz"
tap_dir="${TAP_DIR:-$HOME/Dev/jeiemgi/homebrew-cckit}"

run() { if [ "$PUBLISH" = 1 ]; then echo "+ $*"; "$@"; else echo "DRY: $*"; fi; }

mode="DRY-RUN"; [ "$PUBLISH" = 1 ] && mode="PUBLISH"
echo "== cckit publish $tag  (mode: $mode) =="

if [ "$PUBLISH" = 1 ]; then
  [ -z "$(git -C "$root" status --porcelain)" ] || { echo "x working tree not clean" >&2; exit 1; }
  [ "$(git -C "$root" branch --show-current)" = "main" ] || { echo "x not on main" >&2; exit 1; }
  ! git -C "$root" rev-parse "$tag" >/dev/null 2>&1 || { echo "x tag $tag already exists" >&2; exit 1; }
  command -v gh >/dev/null || { echo "x gh required" >&2; exit 1; }
fi

# 1. Stamp version, tag, and cut the GitHub release (creates the tarball).
run bash -c "cd '$root' && command -v jq >/dev/null && jq '.kitVersion=\"$VERSION\"' cckit.config.json > .v.tmp && mv .v.tmp cckit.config.json || true"
run git -C "$root" add -A
run git -C "$root" commit -m "release: $tag"
run git -C "$root" tag "$tag"
run git -C "$root" push origin main --tags
run gh release create "$tag" --repo "$repo" --title "$tag" --generate-notes

# 2. Compute the tarball sha256 for the stable Homebrew formula.
if [ "$PUBLISH" = 1 ]; then
  echo "+ fetching sha256 of $tarball"
  SHA="$(curl -fsSL "$tarball" | shasum -a 256 | cut -d' ' -f1)"
  echo "  sha256=$SHA"
else
  SHA="<computed-at-publish>"; echo "DRY: curl -fsSL $tarball | shasum -a 256"
fi

# 3. Inject the stable url+sha256 block into the formula (idempotent).
formula="$root/Formula/cckit.rb"
if [ "$PUBLISH" = 1 ]; then
  if grep -q 'url "https' "$formula"; then
    perl -0pi -e "s{url \"https[^\"]*\"}{url \"$tarball\"}; s{sha256 \"[^\"]*\"}{sha256 \"$SHA\"}; s{version \"[^\"]*\"}{version \"$VERSION\"}" "$formula"
  else
    perl -0pi -e "s{(  homepage[^\n]*\n)}{\$1  url \"$tarball\"\n  sha256 \"$SHA\"\n  version \"$VERSION\"\n}" "$formula"
  fi
  echo "+ updated $formula"
else
  echo "DRY: inject url=$tarball sha256=$SHA version=$VERSION into Formula/cckit.rb"
fi

# 4. Homebrew tap: copy the formula into the tap repo and push.
if [ "$DO_BREW" = 1 ]; then
  if [ -d "$tap_dir/.git" ]; then
    run mkdir -p "$tap_dir/Formula"
    run cp "$formula" "$tap_dir/Formula/cckit.rb"
    run git -C "$tap_dir" add Formula/cckit.rb
    run git -C "$tap_dir" commit -m "cckit $VERSION"
    run git -C "$tap_dir" push
    echo "   users: brew tap jeiemgi/cckit && brew install cckit"
  else
    echo "  ! tap repo not at $tap_dir - create it: gh repo create jeiemgi/homebrew-cckit --public"
  fi
fi

# 5. npm publish (scoped, public).
if [ "$DO_NPM" = 1 ]; then
  run npm publish --access public
  echo "   users: npm i -g @jeiemgi/cckit"
fi

done_msg="dry run - nothing changed"; [ "$PUBLISH" = 1 ] && done_msg="published"
echo "== done ($done_msg) =="
