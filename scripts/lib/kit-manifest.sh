#!/usr/bin/env bash
# kit-manifest.sh — ownership manifest for everything the kit writes into a project (#368).
#
# THE PROBLEM IT SOLVES: kit-wire / kit-init / kit-promote write files into a project. To update
# or UNINSTALL them safely we must distinguish "the kit wrote this and the user hasn't touched it"
# (safe to overwrite/remove) from "the user edited it" (ask first) from "not ours" (never touch).
# Guessing by filename is how you delete a user's work. The manifest records path + content hash +
# kit version + portability tier for each managed file, so every later op consults facts, not
# heuristics. This is the prerequisite for kit-remove (D12), kit-wire, kit-migrate, kit-promote.
#
# Source it:  source scripts/lib/kit-manifest.sh
# Requires: jq + a sha256 tool (shasum -a 256 | sha256sum).
#
# Manifest shape (.claude/kit.manifest.json):
#   {
#     "schema": 1,
#     "entries": {
#       "<relpath>": { "hash": "<sha256>", "kitVersion": "<v>", "tier": "A|B", "op": "<who>", "ts": "<iso>" }
#     }
#   }
# tier A = portable (Cowork/claude.ai), tier B = CLI-only — see kit-v2 plan §5.

# --- location -------------------------------------------------------------
# Manifest lives at the project root's .claude/kit.manifest.json. Override with KIT_MANIFEST.
kit_manifest_path() {
  if [ -n "${KIT_MANIFEST:-}" ]; then printf '%s\n' "$KIT_MANIFEST"; return 0; fi
  printf '%s\n' ".claude/kit.manifest.json"
}

# --- portable sha256 ------------------------------------------------------
kit_manifest_hash() {
  # hash of file "$1"; empty string if missing
  [ -f "$1" ] || { printf ''; return 0; }
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    echo "kit-manifest: no sha256 tool (shasum/sha256sum)" >&2; return 1
  fi
}

_kit_manifest_require() {
  command -v jq >/dev/null 2>&1 || { echo "kit-manifest: jq is required" >&2; return 1; }
}

# --- lifecycle ------------------------------------------------------------
# Create an empty manifest if none exists. Idempotent.
kit_manifest_init() {
  _kit_manifest_require || return 1
  local mf; mf="$(kit_manifest_path)"
  [ -f "$mf" ] && return 0
  mkdir -p "$(dirname "$mf")"
  printf '{\n  "schema": 1,\n  "entries": {}\n}\n' > "$mf"
}

# kit_manifest_record <relpath> <tier> [op] [kitVersion] [ts]
# Records (or updates) the entry, hashing the CURRENT content of <relpath>.
# ts/kitVersion are injectable so callers in deterministic contexts (tests, resumable workflows)
# can pass stable values instead of reading the clock.
kit_manifest_record() {
  _kit_manifest_require || return 1
  local relpath="$1" tier="${2:-A}" op="${3:-wire}" ver="${4:-${KIT_VERSION:-0.0.0}}" ts="${5:-}"
  [ -n "$relpath" ] || { echo "kit-manifest record: path required" >&2; return 1; }
  case "$tier" in A|B) ;; *) echo "kit-manifest: tier must be A or B (got '$tier')" >&2; return 1;; esac
  local mf hash; mf="$(kit_manifest_path)"; kit_manifest_init || return 1
  hash="$(kit_manifest_hash "$relpath")" || return 1
  if [ -z "$ts" ]; then ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"; fi
  local tmp; tmp="$(mktemp)" || return 1
  jq --arg p "$relpath" --arg h "$hash" --arg t "$tier" --arg o "$op" --arg v "$ver" --arg ts "$ts" \
     '.entries[$p] = {hash:$h, kitVersion:$v, tier:$t, op:$o, ts:$ts}' "$mf" > "$tmp" \
     && mv "$tmp" "$mf" || { rm -f "$tmp"; return 1; }
}

# kit_manifest_get <relpath> -> the entry JSON (or empty + rc 1 if untracked)
kit_manifest_get() {
  _kit_manifest_require || return 1
  local mf; mf="$(kit_manifest_path)"; [ -f "$mf" ] || return 1
  local out; out="$(jq -e --arg p "$1" '.entries[$p] // empty' "$mf" 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# kit_manifest_verify <relpath> -> prints one of: intact | modified | missing | untracked
#   intact    = tracked and current content matches recorded hash (safe to overwrite/remove)
#   modified  = tracked but content changed since the kit wrote it (ASK before touching)
#   missing   = tracked but the file is gone
#   untracked = not in the manifest (NEVER touch on the kit's behalf)
# rc: 0 intact, 1 modified, 2 missing, 3 untracked — so callers can branch on $?.
kit_manifest_verify() {
  _kit_manifest_require || return 1
  local relpath="$1" mf stored cur; mf="$(kit_manifest_path)"
  if [ ! -f "$mf" ] || ! stored="$(jq -er --arg p "$relpath" '.entries[$p].hash // empty' "$mf" 2>/dev/null)" || [ -z "$stored" ]; then
    echo untracked; return 3
  fi
  if [ ! -f "$relpath" ]; then echo missing; return 2; fi
  cur="$(kit_manifest_hash "$relpath")" || return 1
  if [ "$cur" = "$stored" ]; then echo intact; return 0; else echo modified; return 1; fi
}

# kit_manifest_remove_entry <relpath> — drop the entry (does NOT delete the file)
kit_manifest_remove_entry() {
  _kit_manifest_require || return 1
  local mf tmp; mf="$(kit_manifest_path)"; [ -f "$mf" ] || return 0
  tmp="$(mktemp)" || return 1
  jq --arg p "$1" 'del(.entries[$p])' "$mf" > "$tmp" && mv "$tmp" "$mf" || { rm -f "$tmp"; return 1; }
}

# kit_manifest_list [tier] — newline-list of tracked paths, optionally filtered by tier (A|B)
kit_manifest_list() {
  _kit_manifest_require || return 1
  local mf; mf="$(kit_manifest_path)"; [ -f "$mf" ] || return 0
  if [ -n "${1:-}" ]; then
    jq -r --arg t "$1" '.entries | to_entries[] | select(.value.tier==$t) | .key' "$mf"
  else
    jq -r '.entries | keys[]' "$mf"
  fi
}

# kit_manifest_diff — print "<status>\t<path>" for every tracked path (intact/modified/missing)
kit_manifest_diff() {
  _kit_manifest_require || return 1
  local p; while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%s\t%s\n' "$(kit_manifest_verify "$p")" "$p"
  done < <(kit_manifest_list)
}
