#!/usr/bin/env bash
# Build the "onboarding via claude" demo GIF from a REAL `claude` run.
#
# What it shows: invoking claude-kit's scaffold preview *through the `claude` CLI*
# (`claude -p`), then claude's real output (the --dry-run plan). The capture is a
# genuine claude session recorded headless with asciinema; we only RE-TIME it for a
# watchable GIF (claude's ~16s think time is replaced with a short beat, and the
# burst output is streamed line by line). Content is not faked.
#
# Re-capture + rebuild:   bash docs/media/build-onboarding.sh
# Rebuild from a saved capture only:   ONB_CAST=/path/to.cast bash docs/media/build-onboarding.sh
#
# Requires: claude (authenticated) for capture; agg + jq + awk for rendering.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEDIA="$ROOT/docs/media"
COLS=98; ROWS=38
CAP="${ONB_CAST:-$MEDIA/.onboarding-capture.cast}"
SHOWN='claude -p '\''run init.sh --profile automation --name "Acme Bot" --memory on --dry-run and show the output'\'''

# 1. Capture a real claude run (skipped if ONB_CAST points at an existing capture).
if [[ -z "${ONB_CAST:-}" || ! -s "$CAP" ]]; then
  tmp="$(mktemp -d)"
  asciinema rec --overwrite -c "cd '$tmp' && claude -p 'Run exactly this shell command and show me its raw output verbatim, then stop: bash $ROOT/scripts/init.sh --profile automation --name \"Acme Bot\" --repo acme/bot --owner-login acme --memory on --dry-run' --allowedTools Bash" "$CAP"
fi

# 2. Pull claude's real text out of the capture, strip terminal-reset escapes + ``` fences.
RAW="$(jq -r 'select(type=="array" and .[1]=="o") | .[2]' "$CAP")"
CLEAN="${RAW%%$'\033'*}"
CLEAN="$(printf '%s' "$CLEAN" | tr -d '\r' | awk '!/^```$/')"

# 3. Emit a re-timed asciicast: typed command -> "working" beat -> streamed output.
esc()  { printf '%s' "$1" | jq -Rs .; }
bump() { awk "BEGIN{printf \"%.2f\", $1 + $2}"; }
CAST="$MEDIA/kit-onboarding.cast"; GIF="$MEDIA/kit-onboarding.gif"
{
  printf '{"version":2,"width":%d,"height":%d,"env":{"TERM":"xterm-256color","SHELL":"/bin/zsh"}}\n' "$COLS" "$ROWS"
  printf '[0.00, "o", %s]\n' "$(esc $'\033[1;36m➜ claude-kit\033[0m ')"
  t=0.40
  for ((i=0; i<${#SHOWN}; i++)); do printf '[%s, "o", %s]\n' "$t" "$(esc "${SHOWN:$i:1}")"; t="$(bump "$t" 0.035)"; done
  printf '[%s, "o", %s]\n' "$t" "$(esc $'\r\n')"; t="$(bump "$t" 0.35)"
  printf '[%s, "o", %s]\n' "$t" "$(esc $'\033[90m✳ Working…\033[0m')"; t="$(bump "$t" 1.20)"
  printf '[%s, "o", %s]\n' "$t" "$(esc $'\r\033[K')"; t="$(bump "$t" 0.20)"
  while IFS= read -r line; do printf '[%s, "o", %s]\n' "$t" "$(esc "$line"$'\r\n')"; t="$(bump "$t" 0.05)"; done <<< "$CLEAN"
  t="$(bump "$t" 0.50)"; printf '[%s, "o", %s]\n' "$t" "$(esc $'\033[1;36m➜ claude-kit\033[0m ')"
  t="$(bump "$t" 1.80)"; printf '[%s, "o", " "]\n' "$t"
} > "$CAST"

agg --cols "$COLS" --rows "$ROWS" --font-size 20 --theme asciinema "$CAST" "$GIF"
echo "✓ wrote $GIF"
