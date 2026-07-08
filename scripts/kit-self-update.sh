#!/usr/bin/env bash
# cckit — self-update the checkout this cckit runs from.
#
# A symlink install (cckit on PATH -> <checkout>/bin, plugin -> <checkout>) means "update"
# is just a fast-forward pull of the checkout. This script does that pull, safely:
#   - resolves its OWN checkout root (works from any caller: hook, cron, by hand)
#   - throttled: at most one network hit per THROTTLE window (stamp file), so a
#     SessionStart hook can call it on every session for free
#   - --ff-only on the checkout's CURRENT branch: never creates merges, never touches
#     a diverged/dirty state -- worst case it silently does nothing
#   - always exits 0: an update failure must never break a session start
#
# Usage: kit-self-update.sh [--force] [--quiet]
#   --force   ignore the throttle stamp
#   --quiet   suppress the "updated" notice
set -uo pipefail

FORCE=0; QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --quiet) QUIET=1; shift ;;
    *) shift ;;
  esac
done

# Resolve the checkout root from this script's real location (scripts/ -> root).
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
ROOT="$(cd -- "$SELF_DIR/.." >/dev/null 2>&1 && pwd)"
[[ -n "$ROOT" ]] || exit 0
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Throttle: one pull per window (default 4h). Stamp lives in the user cache dir.
THROTTLE="${CCKIT_SELF_UPDATE_THROTTLE:-14400}"
STAMP_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/cckit"
STAMP="$STAMP_DIR/self-update.stamp"
if [[ $FORCE -eq 0 && -f "$STAMP" ]]; then
  now=$(date +%s)
  last=$(stat -f %m "$STAMP" 2>/dev/null || stat -c %Y "$STAMP" 2>/dev/null || echo 0)
  (( now - last < THROTTLE )) && exit 0
fi
mkdir -p "$STAMP_DIR" 2>/dev/null && touch "$STAMP" 2>/dev/null

before="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"
# ff-only pull of the current branch; short timeouts so a dead network can't hang a hook.
GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=5 \
  git -C "$ROOT" pull --ff-only --quiet 2>/dev/null || exit 0
after="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"

if [[ $QUIET -eq 0 && -n "$before" && -n "$after" && "$before" != "$after" ]]; then
  ver=""
  command -v jq >/dev/null 2>&1 && ver="$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
  echo "cckit self-updated: $before -> $after${ver:+ (v$ver)}"
fi
exit 0
