#!/usr/bin/env bash
# kit-mail-check.sh — session-mail delivery hook (#175). Scaffolded by claude-kit.
# One event-aware script wired to FOUR hook events; it reads the event from the hook's stdin JSON:
#   PostToolUse       → unread mail injected between a working session's tool calls (the steer)
#   UserPromptSubmit  → delivery on the next human prompt
#   SessionStart      → cold-start delivery
#   Stop              → blocks the stop ONLY for unread `--steer` mail (redirects a finishing
#                       session); mail is consumed on delivery so it can never block twice
# Silent (no output) when there is no mail — zero noise on the hot path.
# Send with:  cckit msg send <branch|project:branch|all> [--steer] "<text>"
set -u
input="$(cat 2>/dev/null || true)"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)"
[ -n "$event" ] || event="${1:-UserPromptSubmit}"
# Run from the project the hook fired in (hooks provide cwd; fall back to where we are).
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null
# Prefer the project's own bin/cckit (version-matched to this checkout — the dogfood case) over
# the PATH install: a stale PATH cckit without the msg verb would silently no-op delivery (#179).
kit="cckit"
[ -x "./bin/cckit" ] && kit="./bin/cckit"
command -v "$kit" >/dev/null 2>&1 || exit 0
"$kit" msg hook-check "$event" 2>/dev/null || true
exit 0
