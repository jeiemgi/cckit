#!/usr/bin/env bash
# project-scan.sh — agnostic project detection. Reports what cckit is pointed at, from the
# filesystem only (no baked-in project knowledge). Usage: source it && project_scan [dir]
project_scan() {
  local dir="${1:-$PWD}" root stack=() kit="none"
  # ONE shared config discovery (config-path.sh, #69), sourced from this file's own dir when needed.
  if ! command -v kit_config_find >/dev/null 2>&1; then
    local _psd; _psd="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    # shellcheck source=/dev/null
    [ -f "$_psd/config-path.sh" ] && . "$_psd/config-path.sh"
  fi
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$dir")"
  [ -f "$root/package.json" ]   && stack+=("node")
  [ -f "$root/pyproject.toml" ] && stack+=("python")
  [ -f "$root/go.mod" ]         && stack+=("go")
  [ -f "$root/Cargo.toml" ]     && stack+=("rust")
  if   kit_config_find "$root" >/dev/null 2>&1; then kit="configured"
  elif [ -d "$root/.cckit" ];            then kit="partial"
  elif [ -d "$root/.claude" ];           then kit="claude-only"; fi
  printf '{"root":"%s","stack":[%s],"kit":"%s"}\n' \
    "$root" "$(printf '"%s",' "${stack[@]:-}" | sed 's/,$//;s/""//')" "$kit"
}
