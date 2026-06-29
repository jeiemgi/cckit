#!/usr/bin/env bash
# cckit remote installer — curl -fsSL <url> | bash
# Clones (or updates) cckit into ~/.cckit and links `cckit` onto your PATH. No build, no npm/brew.
# Works on macOS, Linux, and Windows via WSL / Git Bash. Honors $CCKIT_HOME.
set -euo pipefail

repo="https://github.com/jeiemgi/cckit.git"
dest="${CCKIT_HOME:-$HOME/.cckit}"

command -v git >/dev/null 2>&1 || { echo "cckit: git is required." >&2; exit 1; }

if [ -d "$dest/.git" ]; then
  echo "cckit: updating $dest"
  git -C "$dest" pull --ff-only --quiet || echo "cckit: could not fast-forward; using existing checkout" >&2
else
  echo "cckit: cloning into $dest"
  git clone --depth 1 --quiet "$repo" "$dest"
fi

# Delegate PATH linking to the in-repo installer (single source of truth).
bash "$dest/scripts/install.sh"
echo "cckit: done. Run 'cckit help' to get started."
