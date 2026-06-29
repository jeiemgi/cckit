#!/usr/bin/env bash
# toon.sh - TOON (Token-Oriented Object Notation) encoding for context payloads. A uniform array of
# flat objects collapses to a compact tabular form - one keys header, then one row per element -
# which costs far fewer tokens than repeating every key in JSON. Anything that is not a uniform,
# scalar-only array of objects (or is below the size gate) falls back to compact JSON unchanged.
#
#   toon_encode            read JSON on stdin, write TOON (or JSON fallback) on stdout
#   TOON_MIN_ROWS=N        size gate: arrays shorter than N stay JSON (default 2)

# toon_encode - stdin JSON -> stdout TOON-or-JSON.
toon_encode() {
  command -v jq >/dev/null 2>&1 || { cat; return 0; }
  local json n keys uniform min="${TOON_MIN_ROWS:-2}"
  json="$(cat)"

  n="$(printf '%s' "$json" | jq 'if type=="array" then length else -1 end' 2>/dev/null || echo -1)"
  # not an array, or smaller than the gate -> compact JSON (TOON overhead not worth it).
  if [ "$n" -lt "$min" ]; then printf '%s' "$json" | jq -c . 2>/dev/null || printf '%s\n' "$json"; return 0; fi

  keys="$(printf '%s' "$json" | jq -r '.[0] | (keys_unsorted | join(","))' 2>/dev/null || true)"
  # uniform = every element has the same key order AND only scalar values (tabular-encodable).
  uniform="$(printf '%s' "$json" | jq -r --arg k "$keys" '
    all(.[];
      (keys_unsorted | join(",")) == $k
      and ([.[]] | all(type | . == "string" or . == "number" or . == "boolean" or . == "null")))
  ' 2>/dev/null || echo false)"

  if [ "$uniform" != "true" ] || [ -z "$keys" ]; then
    printf '%s' "$json" | jq -c .          # non-uniform / nested -> JSON fallback
    return 0
  fi

  printf '[%s]{%s}:\n' "$n" "$keys"
  printf '%s' "$json" | jq -r '.[] | [.[]] | @csv'
}
