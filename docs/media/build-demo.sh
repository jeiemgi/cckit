#!/usr/bin/env bash
# Build deterministic terminal demos for claude-kit and render them to GIFs.
#
# Why generated (not live-recorded): the demo content is fully deterministic
# (it comes from `init.sh`, which is a pure function of its flags — and `--dry-run`
# writes nothing), so we synthesize an asciicast v2 file with a typing effect and
# render it with `agg`. No interactive TTY required, reproducible in CI.
#
# NOTE: only the `init.sh` engine is a real shell command. The /kit-customize and
# /kit-contribute slash commands are skills Claude runs *inside Claude Code*, not
# terminal programs, so they are documented in prose — not faked as terminal GIFs.
#
# Requires: agg (https://github.com/asciinema/agg), jq, awk, bash.
# Usage:    bash docs/media/build-demo.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MEDIA="$ROOT/docs/media"
COLS=98; ROWS=34

esc()  { printf '%s' "$1" | jq -Rs .; }                 # JSON-encode a string
bump() { awk "BEGIN{printf \"%.2f\", $1 + $2}"; }        # add seconds

# make_gif <name> <shown-command> <output-text>
# Renders a typed-command-then-output clip to docs/media/<name>.{cast,gif}.
make_gif() {
  local name="$1" shown="$2" out="$3"
  local cast="$MEDIA/$name.cast" gif="$MEDIA/$name.gif"
  local t i
  {
    printf '{"version":2,"width":%d,"height":%d,"env":{"TERM":"xterm-256color","SHELL":"/bin/zsh"}}\n' "$COLS" "$ROWS"
    printf '[0.00, "o", %s]\n' "$(esc $'\033[1;36m➜ claude-kit\033[0m ')"   # prompt at t=0
    t=0.40
    for ((i=0; i<${#shown}; i++)); do printf '[%s, "o", %s]\n' "$t" "$(esc "${shown:$i:1}")"; t="$(bump "$t" 0.04)"; done
    printf '[%s, "o", %s]\n' "$t" "$(esc $'\r\n')"; t="$(bump "$t" 0.45)"
    while IFS= read -r line; do printf '[%s, "o", %s]\n' "$t" "$(esc "$line"$'\r\n')"; t="$(bump "$t" 0.05)"; done <<< "$out"
    t="$(bump "$t" 0.50)"; printf '[%s, "o", %s]\n' "$t" "$(esc $'\033[1;36m➜ claude-kit\033[0m ')"
    t="$(bump "$t" 1.80)"; printf '[%s, "o", " "]\n' "$t"
  } > "$cast"
  agg --cols "$COLS" --rows "$ROWS" --font-size 20 --theme asciinema "$cast" "$gif"
  echo "  ✓ $name.gif"
}

echo "→ Building demos into $MEDIA"

# 1. Preview a scaffold without writing anything.
make_gif "kit-dry-run" \
  'init.sh --profile automation --name "Acme Bot" --memory on --dry-run' \
  "$(bash "$ROOT/scripts/init.sh" --profile automation --target "$(mktemp -d)/acme-bot" \
       --name "Acme Bot" --repo acme/bot --owner-login acme --memory on --dry-run 2>&1)"

# 2. Scaffold a real project from the `software` profile.
make_gif "kit-init" \
  'init.sh --profile software --name "Acme" --repo acme/acme' \
  "$(bash "$ROOT/scripts/init.sh" --profile software --target "$(mktemp -d)/acme" \
       --name "Acme" --repo acme/acme --owner-login acme 2>&1)"

# 3. Show every flag.
make_gif "kit-help" \
  'init.sh --help' \
  "$(bash "$ROOT/scripts/init.sh" --help 2>&1)"

echo "✓ done"
