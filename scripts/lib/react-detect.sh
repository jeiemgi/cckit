#!/usr/bin/env bash
# claude-kit — React + framework detection for /kit-annotate.
# Source it, then call `react_detect [target_dir]`; it sets/exports REACT_* vars.
# Specificity-ordered: Next.js → React Router v7 (framework mode) → Vite → generic React.
# (A flat "is vite present?" check is unreliable — Next/RR apps often carry vite for tests.)
# Requires: jq. Safe to source (no `set -e`); never aborts the caller.

react_detect() {
  local dir="${1:-$PWD}" pkg deps
  # defaults
  REACT_DETECTED="false"; REACT_FRAMEWORK=""; REACT_VERSION=""
  REACT_ENTRY_FILE=""; REACT_PKG_MANAGER="npm"; REACT_ROUTER_LIB="false"
  export REACT_DETECTED REACT_FRAMEWORK REACT_VERSION REACT_ENTRY_FILE REACT_PKG_MANAGER REACT_ROUTER_LIB

  pkg="$dir/package.json"
  [[ -f "$pkg" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # merged dependency name list (deps + devDeps); tolerate malformed JSON
  deps="$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | keys[]?' "$pkg" 2>/dev/null)" || return 0
  _has() { printf '%s\n' "$deps" | grep -qx "$1"; }

  _has react || return 0
  REACT_DETECTED="true"
  REACT_VERSION="$(jq -r '(.dependencies.react // .devDependencies.react // "")' "$pkg" 2>/dev/null | tr -d '^~ ')"

  # package manager from lockfile
  if   [[ -f "$dir/pnpm-lock.yaml" ]]; then REACT_PKG_MANAGER="pnpm"
  elif [[ -f "$dir/yarn.lock"      ]]; then REACT_PKG_MANAGER="yarn"
  elif [[ -f "$dir/bun.lockb"      ]]; then REACT_PKG_MANAGER="bun"
  else REACT_PKG_MANAGER="npm"; fi

  local has_next_cfg=false has_vite_cfg=false has_rr_cfg=false
  ls "$dir"/next.config.*          >/dev/null 2>&1 && has_next_cfg=true
  ls "$dir"/vite.config.*          >/dev/null 2>&1 && has_vite_cfg=true
  ls "$dir"/react-router.config.*  >/dev/null 2>&1 && has_rr_cfg=true

  local f
  if _has next || $has_next_cfg; then
    # 1. Next.js (match first — Next apps frequently also list vite/vitest)
    REACT_FRAMEWORK="next"
    for f in app/layout.tsx app/layout.jsx app/layout.js src/app/layout.tsx \
             pages/_app.tsx pages/_app.jsx pages/_app.js src/pages/_app.tsx; do
      [[ -f "$dir/$f" ]] && { REACT_ENTRY_FILE="$f"; break; }
    done
  elif _has @react-router/dev || $has_rr_cfg; then
    # 2. React Router v7 framework mode (Vite-based, but NOT a plain Vite SPA)
    REACT_FRAMEWORK="react-router"
    for f in app/root.tsx app/root.jsx app/root.js src/root.tsx; do
      [[ -f "$dir/$f" ]] && { REACT_ENTRY_FILE="$f"; break; }
    done
  elif _has @vitejs/plugin-react || _has @vitejs/plugin-react-swc || { _has vite && $has_vite_cfg; }; then
    # 3. Vite (plain React SPA)
    REACT_FRAMEWORK="vite"
    for f in src/main.tsx src/main.jsx src/index.tsx src/index.jsx src/main.ts; do
      [[ -f "$dir/$f" ]] && { REACT_ENTRY_FILE="$f"; break; }
    done
  else
    # 4. React present but framework unrecognized (CRA / Gatsby / Preact-compat / custom)
    REACT_FRAMEWORK="react"
  fi

  # react-router(-dom) WITHOUT @react-router/dev = a routing library, not a framework target
  if { _has react-router || _has react-router-dom; } && ! _has @react-router/dev; then
    REACT_ROUTER_LIB="true"
  fi

  unset -f _has
  return 0
}

# Run standalone → print a one-line summary (handy for --dry-run / debugging).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  react_detect "${1:-$PWD}"
  printf 'detected=%s framework=%s version=%s entry=%s pm=%s router_lib=%s\n' \
    "$REACT_DETECTED" "$REACT_FRAMEWORK" "${REACT_VERSION:-?}" \
    "${REACT_ENTRY_FILE:-?}" "$REACT_PKG_MANAGER" "$REACT_ROUTER_LIB"
fi
