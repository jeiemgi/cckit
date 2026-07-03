#!/usr/bin/env bash
# shellcheck shell=bash
# config-path.sh — the ONE project-config-path resolver (#69). Every kit entrypoint discovers the
# project config the SAME way instead of re-deriving it inline: an explicit KIT_CONFIG always wins,
# otherwise walk up from a start dir for a root `cckit.config.json` (self-host / current layout) or a
# `.claude/kit.config.json` (scaffolded layout). Dependency-free pure shell (no jq, no other kit
# libs) so it is safe to source from anywhere — including bin/cckit before anything else loads.
# bash 3.2 + zsh compatible.
#
#   kit_config_find <startdir>   walk startdir -> / for a project config; prints path (rc 0) or rc 1.
#                                Ignores KIT_CONFIG — a pure "is <dir> under a kit project?" answer.
#   kit_config_path [startdir]   KIT_CONFIG wins, else kit_config_find; prints path (rc 0) or rc 1.

kit_config_find() {
  local d="${1:-$PWD}"
  d="$(cd "$d" 2>/dev/null && pwd)" || return 1
  while [ -n "$d" ]; do
    [ -f "$d/cckit.config.json" ]       && { printf '%s\n' "$d/cckit.config.json"; return 0; }
    [ -f "$d/.claude/kit.config.json" ] && { printf '%s\n' "$d/.claude/kit.config.json"; return 0; }
    [ "$d" = "/" ] && break
    d="$(dirname "$d")"
  done
  return 1
}

kit_config_path() {
  if [ -n "${KIT_CONFIG:-}" ]; then printf '%s\n' "$KIT_CONFIG"; return 0; fi
  kit_config_find "${1:-$PWD}"
}
