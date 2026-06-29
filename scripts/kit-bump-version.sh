#!/usr/bin/env bash
# Bump the claude-kit plugin version in EVERY place that must stay in sync:
#   <plugin>/.claude-plugin/plugin.json        .version
#   <plugin>/.claude-plugin/version.json        .version + .channels.<beta|stable>.version
#   <plugin>/package.json                       .version
#   <plugin>/.claude-plugin/marketplace.json    .metadata.version + .plugins[claude-kit].version
#   <repo-root>/.claude-plugin/marketplace.json (when present) — same two fields
#
# Usage: kit-bump-version.sh [beta|patch|minor|<explicit-version>]
#   beta  (default)  0.7.0-beta.1 -> 0.7.0-beta.2 ; 0.7.0 -> 0.7.1-beta.1   (-> channels.beta)
#   patch            0.7.0-beta.N -> 0.7.0        ; 0.7.0 -> 0.7.1           (-> channels.stable)
#   minor            0.7.x[-*]    -> 0.8.0                                   (-> channels.stable)
#   1.2.3-rc.1       set verbatim
#
# version.json is the canonical channel descriptor: a `-beta.N` build advances channels.beta,
# a clean release advances channels.stable. /kit-dev ship runs this so the installed plugin
# (deduped by version) sees every release.
set -euo pipefail

# Resolve the plugin dir from this script's location (BASH_SOURCE), so it works run from the
# plugin checkout OR the monorepo. Repo root is best-effort (for the optional root marketplace).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
plugin_dir="$(cd "$script_dir/.." && pwd)"
repo_root="$(git -C "$plugin_dir" rev-parse --show-toplevel 2>/dev/null || true)"

plugin_json="$plugin_dir/.claude-plugin/plugin.json"
version_json="$plugin_dir/.claude-plugin/version.json"
package_json="$plugin_dir/package.json"
sub_marketplace_json="$plugin_dir/.claude-plugin/marketplace.json"
root_marketplace_json="${repo_root:+$repo_root/.claude-plugin/marketplace.json}"
[[ -f $plugin_json ]] || { echo "✗ plugin.json not found at $plugin_json" >&2; exit 1; }

mode="${1:-beta}"
current="$(jq -r .version "$plugin_json")"

core="${current%%-*}"
pre=""; [[ $current == *-* ]] && pre="${current#*-}"
IFS=. read -r maj min pat <<<"$core"

channel="stable"   # which channel this bump advances
case "$mode" in
  beta)
    channel="beta"
    if [[ $pre == beta.* ]]; then
      next="$core-beta.$(( ${pre#beta.} + 1 ))"
    else
      next="$maj.$min.$((pat + 1))-beta.1"
    fi
    ;;
  patch)
    if [[ -n $pre ]]; then next="$core"; else next="$maj.$min.$((pat + 1))"; fi
    ;;
  minor)
    next="$maj.$((min + 1)).0"
    ;;
  *)
    [[ $mode =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || { echo "✗ '$mode' is not beta|patch|minor or a semver" >&2; exit 1; }
    next="$mode"
    [[ $next == *-* ]] && channel="beta"
    ;;
esac

_set() { local f="$1" filter="$2"; [[ -f "$f" ]] || return 0; local t; t="$(mktemp)"; jq "$filter" "$f" >"$t" && mv "$t" "$f"; }

_set "$plugin_json"  '.version = "'"$next"'"'
_set "$package_json" '.version = "'"$next"'"'
# version.json: top-level version + the advancing channel's version.
_set "$version_json" '.version = "'"$next"'" | .channels.'"$channel"'.version = "'"$next"'"'

mkt_bumped=0
for mkt in "$root_marketplace_json" "$sub_marketplace_json"; do
  [[ -n "$mkt" && -f "$mkt" ]] || continue
  t="$(mktemp)"
  jq --arg v "$next" '.metadata.version = $v | (.plugins[] | select(.name == "claude-kit") | .version) = $v' \
    "$mkt" >"$t" && mv "$t" "$mkt"
  mkt_bumped=$((mkt_bumped + 1))
done

echo "✓ claude-kit $current -> $next (channel: $channel; plugin.json + version.json + package.json + $mkt_bumped marketplace.json)"
