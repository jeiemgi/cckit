#!/usr/bin/env bash
# Build an ILLUSTRATIVE GIF of the interactive `claude > /kit-init` onboarding.
#
# IMPORTANT — this clip is a stylized RE-CREATION, not a live capture:
#   - The real `/kit-init` is an interactive Claude Code slash command whose AskUserQuestion
#     chips can't be captured headlessly (plugin slash commands aren't available in `claude -p`,
#     and the interactive TUI can't be keystroke-driven without a TTY).
#   - So the prompt + the answered "chips" are mocked, while the SCAFFOLD OUTPUT below them is
#     REAL — produced by running `init.sh` with the same test values.
# To capture the genuine interactive flow, record it yourself in a real terminal (see media README).
#
# Requires: agg, jq, awk, bash.  Usage: bash docs/media/build-kit-init.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEDIA="$ROOT/docs/media"; COLS=92; ROWS=30
CAST="$MEDIA/kit-init.cast"; GIF="$MEDIA/kit-init.gif"

# Real scaffold output for the test values (minimal profile, memory off) into a throwaway dir.
OUT="$(bash "$ROOT/scripts/init.sh" --profile minimal --target "$(mktemp -d)/demo-project" \
        --name "Demo Project" --repo acme/demo --owner-login acme 2>&1)"

esc()  { printf '%s' "$1" | jq -Rs .; }
bump() { awk "BEGIN{printf \"%.2f\", $1 + $2}"; }
emit() { printf '[%s, "o", %s]\n' "$1" "$(esc "$2")"; }

{
  printf '{"version":2,"width":%d,"height":%d,"env":{"TERM":"xterm-256color","SHELL":"/bin/zsh"}}\n' "$COLS" "$ROWS"
  # shell prompt + `claude`
  emit 0.00 $'\033[1;36m➜ demo-project\033[0m '
  t=0.40; for c in c l a u d e; do emit "$t" "$c"; t="$(bump "$t" 0.05)"; done
  emit "$t" $'\r\n'; t="$(bump "$t" 0.6)"
  # Claude Code prompt + typed slash command
  emit "$t" $'\033[2m Claude Code \033[0m\r\n'; t="$(bump "$t" 0.4)"
  emit "$t" $'\033[1;35m❯\033[0m '; t="$(bump "$t" 0.2)"
  s='/kit-init'; for ((i=0;i<${#s};i++)); do emit "$t" "${s:$i:1}"; t="$(bump "$t" 0.06)"; done
  emit "$t" $'\r\n\r\n'; t="$(bump "$t" 0.5)"
  # mocked answered chips (test values)
  emit "$t" $'\033[2m  answer the prompts (test values):\033[0m\r\n'; t="$(bump "$t" 0.35)"
  for row in 'Profile          minimal' 'GitHub repo      acme/demo' 'Projects board   off' 'MemPalace        off' 'Language         English'; do
    emit "$t" $'  \033[32m✔\033[0m '"$row"$'\r\n'; t="$(bump "$t" 0.45)"
  done
  emit "$t" $'\r\n'; t="$(bump "$t" 0.4)"
  # REAL scaffold output
  while IFS= read -r line; do emit "$t" "$line"$'\r\n'; t="$(bump "$t" 0.06)"; done <<< "$OUT"
  t="$(bump "$t" 0.5)";  emit "$t" $'\033[1;35m❯\033[0m '
  t="$(bump "$t" 1.8)";  emit "$t" ' '
} > "$CAST"

agg --cols "$COLS" --rows "$ROWS" --font-size 19 --theme asciinema "$CAST" "$GIF"
echo "✓ wrote $GIF"
