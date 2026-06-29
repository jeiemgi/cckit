#!/usr/bin/env bash
# engine-adapter.sh — pluggable bridge from the kit CLI to the Plan Engine.
#
# Family 2 of kit-engine-boundary.md: plan/ticket/Deliverable graph ops. The kit CLI is the
# human/Claude surface; the Plan Engine Postgres graph (ADR-004/005) is the source of truth.
# This adapter is the seam between them — and it is PLUGGABLE so the kit stays portable as a
# product: the default mode is "off", meaning the kit runs engine-less (bash + GitHub, today's
# behavior). cckit and clients opt in by setting the engine block in .claude/kit.config.json.
#
# Config (.claude/kit.config.json):
#   "engine": { "mode": "off" | "http", "url": "https://engine.example", "token_env": "CCKIT_ENGINE_TOKEN" }
#
# Source it, then call engine_cmd / engine_call.  Requires: jq, curl (only when mode != off).

_engine_cfg() { echo "${KIT_CONFIG:-.claude/kit.config.json}"; }

engine_mode() { jq -r '.engine.mode // "off"' "$(_engine_cfg)" 2>/dev/null || echo off; }
engine_url()  { jq -r '.engine.url  // ""'    "$(_engine_cfg)" 2>/dev/null; }
engine_enabled() { [[ "$(engine_mode)" != "off" ]]; }

# engine_call <METHOD> <path> [json-body] — returns the engine response on stdout.
# Returns 3 when the engine is not configured (local mode), so callers can fall back to GitHub.
engine_call() {
  # NOTE: `route` not `path` — `path` is a special zsh parameter tied to $PATH; a `local path=…`
  # silently corrupts the command search path under zsh (the session shell), so jq/curl then fail
  # and engine_enabled reads "off". (delegation-brief: status/path are zsh-special.)
  local method="$1" route="$2" body="${3:-}" url tokenvar tok
  engine_enabled || { echo "engine: off (local mode)" >&2; return 3; }
  url="$(engine_url)"; [[ -n "$url" ]] || { echo "engine.url not set in $(_engine_cfg)" >&2; return 3; }
  command -v curl >/dev/null || { echo "curl required for engine mode" >&2; return 1; }
  tokenvar="$(jq -r '.engine.token_env // ""' "$(_engine_cfg)")"
  local -a auth=()
  # Portable indirect expansion — bash's ${!var} is not zsh-compatible (zsh would need ${(P)var}).
  [[ -n "$tokenvar" ]] && eval "tok=\${$tokenvar:-}"
  # Auto-load the engine token from the untracked local secret file when the env var is unset.
  # The token lives in <main-checkout>/scripts/.engine-secret.env (gitignored plaintext) and nothing
  # else sources it — without this the Authorization header silently drops and effort-metrics sync
  # buffers instead of POSTing. The secret is UNTRACKED, so it exists ONLY in the MAIN checkout, not
  # in effort worktrees (where kit-effort-close actually runs). Resolve it via git-common-dir — the
  # shared .git whose parent IS the main checkout, correct from any worktree — then fall back to the
  # current checkout toplevel / this script's location. Missing file = silent no-op. zsh-safe: no
  # `path` local, portable indirect expansion (no ${!var}).
  if [[ -z "${tok:-}" && -n "$tokenvar" ]]; then
    local common main_root secret_file="" cand
    # 1) main checkout via the shared git-common-dir (works from any worktree).
    common="$(git rev-parse --git-common-dir 2>/dev/null)"
    if [[ -n "$common" ]]; then
      case "$common" in /*) : ;; *) common="$PWD/$common" ;; esac
      main_root="$(dirname "$common")"
      [[ -f "$main_root/scripts/.engine-secret.env" ]] && secret_file="$main_root/scripts/.engine-secret.env"
    fi
    # 2) current checkout toplevel, then 3) relative to this script — fallbacks.
    if [[ -z "$secret_file" ]]; then
      for cand in "$(git rev-parse --show-toplevel 2>/dev/null)" \
                  "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)"; do
        [[ -n "$cand" && -f "$cand/scripts/.engine-secret.env" ]] && { secret_file="$cand/scripts/.engine-secret.env"; break; }
      done
    fi
    if [[ -n "$secret_file" ]]; then
      # shellcheck disable=SC1090
      . "$secret_file"
      eval "tok=\${$tokenvar:-}"
    fi
  fi
  [[ -n "${tok:-}" ]] && auth=(-H "Authorization: Bearer $tok")
  if [[ -n "$body" ]]; then
    curl -fsS -X "$method" "${auth[@]}" -H "Content-Type: application/json" --data "$body" "$url$route"
  else
    curl -fsS -X "$method" "${auth[@]}" -H "Content-Type: application/json" "$url$route"
  fi
}

# kit engine <status|ping>
engine_cmd() {
  case "${1:-status}" in
    status)
      local mode; mode="$(engine_mode)"
      if engine_enabled; then
        echo "engine mode: $mode"
        echo "engine url:  $(engine_url)"
      else
        echo "engine mode: off (local mode) - graph ops are GitHub-backed"
        echo "connect: set .engine in $(_engine_cfg) (see scripts/lib/engine-adapter.sh)"
      fi
      ;;
    ping)
      engine_enabled || { echo "engine: off (local mode) - nothing to ping"; return 0; }
      engine_call GET /health && echo "" || { echo "engine unreachable" >&2; return 1; }
      ;;
    *) echo "unknown: kit engine ${1:-}" >&2; return 2 ;;
  esac
}
