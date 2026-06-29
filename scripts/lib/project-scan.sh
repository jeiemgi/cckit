#!/usr/bin/env bash
# project-scan.sh — agnostic project detection. Reports what cckit is pointed at, from the
# filesystem only (no baked-in project knowledge). Usage: source it && project_scan [dir]
project_scan() {
  local dir="${1:-$PWD}" root stack=() kit="none"
  root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$dir")"
  [ -f "$root/package.json" ]   && stack+=("node")
  [ -f "$root/pyproject.toml" ] && stack+=("python")
  [ -f "$root/go.mod" ]         && stack+=("go")
  [ -f "$root/Cargo.toml" ]     && stack+=("rust")
  if   [ -f "$root/cckit.config.json" ]; then kit="configured"
  elif [ -d "$root/.cckit" ];            then kit="partial"
  elif [ -d "$root/.claude" ];           then kit="claude-only"; fi
  printf '{"root":"%s","stack":[%s],"kit":"%s"}\n' \
    "$root" "$(printf '"%s",' "${stack[@]:-}" | sed 's/,$//;s/""//')" "$kit"
}
