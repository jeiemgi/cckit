#!/usr/bin/env bash
# status.sh - a thin, pure-bash status viewer: the board, active worktrees/branches, and the resume
# handoff on one screen, using native terminal tools (ui.sh: color + TTY gating, glow/fzf when
# present). This is the lightweight cockpit; the rich opentui TUI is an OPTIONAL separate adapter -
# the core stays pure bash and dependency-light, so `cckit status` works in any terminal.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/ui.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/kit-config.sh" && load_kit_config

hr() { printf '%s\n' "----------------------------------------------------------------"; }
sec() { if command -v ui_paint >/dev/null 2>&1; then ui_paint '1;36' "$1"; else printf '%s' "$1"; fi; echo; }

sec "cckit status - $KIT_REPO (base ${KIT_BASE_BRANCH:-main})"
hr

# Board: open issues, blocked count (reuse the read-only board JSON).
sec "Board"
board="$(bash "$ROOT/scripts/task-sync.sh" --llm 2>/dev/null || echo '[]')"
if command -v jq >/dev/null 2>&1; then
  open="$(printf '%s' "$board" | jq 'length' 2>/dev/null || echo 0)"
  blocked="$(printf '%s' "$board" | jq '[.[]|select(.blocked)]|length' 2>/dev/null || echo 0)"
  echo "  open issues: $open   blocked: $blocked"
  printf '%s' "$board" | jq -r '.[:8][] | "  #\(.number)  \(.title[0:56])"' 2>/dev/null || true
  [ "$open" -gt 8 ] && echo "  ... and $((open - 8)) more (cckit sync)"
else
  echo "  (jq absent - run cckit sync)"
fi
hr

# Worktrees + branches: SAFE-to-prune vs active (reuse the gc analysis).
sec "Worktrees and branches"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/kit-gc.sh"
kit_gc_analyze 2>/dev/null | grep -E 'SAFE|ACTIVE|PROTECTED|ORPHAN' | head -12 | sed 's/^/  /' || echo "  (clean)"
hr

# Resume handoff, if one is saved.
sec "Resume handoff"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/handoff.sh"
handoff_read | sed 's/^/  /'
