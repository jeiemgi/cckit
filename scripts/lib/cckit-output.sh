#!/usr/bin/env bash
# cckit-output.sh - structured-output helpers for the CLI.
# When CCKIT_OUTPUT=json (set by the --llm / --output=json flag), verbs emit a single JSON
# object on stdout so any agent can parse the result; otherwise they print human-readable text.
# Dependency-light: jq when present (correct escaping), a pure-bash fallback otherwise.

# cckit_is_json - true when the caller asked for machine-readable output.
cckit_is_json() { [ "${CCKIT_OUTPUT:-human}" = "json" ]; }

# _cckit_scalar - true when a value should be emitted unquoted (bool / null / integer).
_cckit_scalar() { case "$1" in true|false|null) return 0 ;; -[0-9]*|[0-9]*) case "$1" in *[!0-9-]*) return 1 ;; *) return 0 ;; esac ;; *) return 1 ;; esac; }

# cckit_json key value [key value ...] - emit a flat JSON object from k/v pairs.
# Values matching true|false|null|<integer> are emitted as JSON scalars; everything else as a string.
cckit_json() {
  if command -v jq >/dev/null 2>&1; then
    local args=()
    while [ "$#" -ge 2 ]; do
      if _cckit_scalar "$2"; then args+=(--argjson "$1" "$2"); else args+=(--arg "$1" "$2"); fi
      shift 2
    done
    jq -nc "${args[@]}" '$ARGS.named'
  else
    local out="{" first=1 k v
    while [ "$#" -ge 2 ]; do
      k="$1"; v="$2"; shift 2
      [ "$first" -eq 1 ] || out="$out,"; first=0
      if _cckit_scalar "$v"; then
        out="$out\"$k\":$v"
      else
        v=${v//\\/\\\\}; v=${v//\"/\\\"}; out="$out\"$k\":\"$v\""
      fi
    done
    printf '%s}\n' "$out"
  fi
}
