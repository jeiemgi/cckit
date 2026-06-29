#!/usr/bin/env bash
# install.sh — put cckit on your PATH. Symlinks bin/cckit into a bin dir (no copy, no build).
# Usage: ./scripts/install.sh [target-bin-dir]   (default: ~/.local/bin, then /usr/local/bin)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/bin/cckit"
[ -x "$src" ] || { echo "cckit: $src not found or not executable" >&2; exit 1; }

# Pick a writable bin dir on PATH.
target="${1:-}"
if [ -z "$target" ]; then
  for d in "$HOME/.local/bin" "/usr/local/bin" "$HOME/bin"; do
    if [ -d "$d" ] && [ -w "$d" ]; then target="$d"; break; fi
  done
  [ -z "$target" ] && { mkdir -p "$HOME/.local/bin"; target="$HOME/.local/bin"; }
fi

ln -sf "$src" "$target/cckit"
echo "cckit: linked $target/cckit -> $src"
case ":$PATH:" in
  *":$target:"*) echo "cckit: '$target' is on your PATH. Run: cckit help" ;;
  *) echo "cckit: add '$target' to your PATH, then run: cckit help" ;;
esac
