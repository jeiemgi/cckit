#!/usr/bin/env bash
# scripts/lib/kit-events.sh — the kit event bus (append-only JSONL).
#
# A durable, single-writer-safe event stream that kit ops emit to and the kit-ui
# (packages/kit-ui) tails. Lives under $(git rev-parse --git-common-dir) so it is
# WORKTREE-DURABLE and survives ephemeral session mounts (same home as kit-sessions
# / kit-usage.jsonl). No second implementation: every kit op that wants to surface
# progress to the TUI sources this file and calls emit_event.
#
# Event shape (one JSON object per line):
#   { "ts": "<ISO-8601 UTC>", "type": "<type>", "op": "<op-name>", "payload": {…} }
#
# Types (the contract — packages/kit-ui/CONTRACT.md is the source of truth):
#   op.start | op.progress | op.done     — lifecycle of a kit operation
#   notice                               — a SessionStart-style notice (consolidated in the notice feed)
#   collision                            — a worktree/file collision between two flows
#   update-available                     — a kit version update is available
#   flow.status                          — an orchestrate flow changed state
#
# Public API (source this file, then call):
#   emit_event <type> <op> [payload-json]   -> appends one event line; payload defaults to {}
#   kit_events_path                         -> prints the absolute path to kit-events.jsonl
#
# Always non-fatal: a failure to emit (no jq, unwritable dir) never breaks the caller.

# Resolve the durable, absolute path to the event log.
# git-common-dir may be relative (".git") — resolve it against the repo root.
kit_events_path() {
  local gcd
  gcd="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$gcd" in
    /*) : ;;                                   # already absolute
    *)  gcd="$(cd "$gcd" 2>/dev/null && pwd)" || return 1 ;;
  esac
  printf '%s/kit-events.jsonl\n' "$gcd"
}

# emit_event <type> <op> [payload-json]
# payload-json must be a valid JSON object string; defaults to {}.
emit_event() {
  local type="${1:-}" op="${2:-}" payload="${3:-}"
  [[ -n "$type" && -n "$op" ]] || return 0
  [[ -n "$payload" ]] || payload='{}'
  command -v jq >/dev/null 2>&1 || return 0

  local path ts line
  path="$(kit_events_path)" || return 0
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Build the line with jq so payload is validated + the record is well-formed.
  # If payload isn't valid JSON, fall back to wrapping it as a string note.
  line="$(jq -cn \
            --arg ts "$ts" --arg type "$type" --arg op "$op" \
            --argjson payload "$payload" \
            '{ts:$ts, type:$type, op:$op, payload:$payload}' 2>/dev/null)" || \
  line="$(jq -cn \
            --arg ts "$ts" --arg type "$type" --arg op "$op" --arg raw "$payload" \
            '{ts:$ts, type:$type, op:$op, payload:{note:$raw}}' 2>/dev/null)" || return 0

  # Single-writer append; >> is atomic for short lines on local fs.
  printf '%s\n' "$line" >> "$path" 2>/dev/null || return 0
}
