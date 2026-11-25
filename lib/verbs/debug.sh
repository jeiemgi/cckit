#!/usr/bin/env bash
# debug.sh - OPTIONAL, auto-detected browser-debug capability via chrome-devtools-axi (Kun Chen,
# https://github.com/kunchenguid/chrome-devtools-axi). Token-efficient (TOON output), self-contained
# Chrome bridge. NOT a hard dependency: cckit is pure bash; axi needs Node + Chrome. When present,
# this drives axi; when absent, it prints how to enable it and exits 0 (degrade, never hard-fail an
# unattended run).
#
# Usage:
#   cckit debug <axi-args...>   drive axi (screenshot / a11y / console / network / lighthouse)
#   cckit debug --check         report whether the capability is available, then exit
#
# Resolution order for the axi command:
#   1. $CCKIT_AXI                       explicit command/path override
#   2. chrome-devtools-axi on PATH      (npm i -g chrome-devtools-axi)
#   3. npx -y chrome-devtools-axi       when node + npx are present
set -euo pipefail

have() { command -v "$1" >/dev/null 2>&1; }

chrome_present() {
  have google-chrome || have chromium || have chromium-browser \
    || [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] \
    || [ -x "/Applications/Chromium.app/Contents/MacOS/Chromium" ]
}

# Echo how to invoke axi, or return non-zero if unavailable.
axi_cmd() {
  if [ -n "${CCKIT_AXI:-}" ]; then printf '%s' "$CCKIT_AXI"; return 0; fi
  if have chrome-devtools-axi; then printf 'chrome-devtools-axi'; return 0; fi
  if have npx && have node; then printf 'npx -y chrome-devtools-axi'; return 0; fi
  return 1
}

cmd="$(axi_cmd || true)"

if [ "${1:-}" = "--check" ]; then
  if [ -n "$cmd" ] && chrome_present; then
    echo "cckit debug: AVAILABLE via '$cmd' (Chrome detected)"
  else
    echo "cckit debug: optional capability NOT available."
    [ -n "$cmd" ] || echo "  - axi: install with 'npm i -g chrome-devtools-axi' (or have node+npx)"
    chrome_present || echo "  - Chrome: not detected (install Google Chrome or Chromium)"
  fi
  exit 0
fi

if [ -z "$cmd" ] || ! chrome_present; then
  echo "cckit debug: browser-debug capability unavailable - skipping (optional)." >&2
  [ -n "$cmd" ] || echo "  enable: npm i -g chrome-devtools-axi  (needs Node + Chrome)" >&2
  exit 0   # degrade, do not hard-fail an unattended run
fi

# shellcheck disable=SC2086
exec $cmd "$@"
