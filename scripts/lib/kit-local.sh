#!/usr/bin/env bash
# kit-local.sh — local model client for claude-kit NL chores (digest, summarize, classify, draft).
# Backed by mlx_lm.server (Apple MLX), an OpenAI-compatible HTTP server on localhost.
#
# Setup (one-time — /kit-doctor does both automatically, #313):
#   uv tool install mlx-lm        # isolated venv, PEP 668-safe (fallback: pipx install mlx-lm)
#   mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8080
#
# Source this from hooks/skills:  source scripts/lib/kit-local.sh
#   kit_local_alive                      -> 0 if the server responds (fast: 1s timeout)
#   kit_local_chat "<system>" "<prompt>" -> prints the model reply; non-zero on any failure
#   kit_local_dismissed                  -> 0 if the "layer down" notice was dismissed
#
# HARD RULE — fallback always: every caller must treat a non-zero exit as "use the current
# (non-local) path". This lib never blocks a hook: alive-check 1s, chat bounded by
# KIT_LOCAL_TIMEOUT (default 90s; hooks should pass lower via env when latency matters).
# Config: .claude/kit.config.json -> .local {enabled, port, model} (KIT_LOCAL_* env wins).

KIT_LOCAL_CONFIG="${KIT_CONFIG:-.claude/kit.config.json}"

_kit_local_cfg() {  # _kit_local_cfg <jq-path> <default>
  local v=""
  if command -v jq >/dev/null 2>&1 && [[ -f "$KIT_LOCAL_CONFIG" ]]; then
    v="$(jq -r "$1 // empty" "$KIT_LOCAL_CONFIG" 2>/dev/null)"
  fi
  printf '%s' "${v:-$2}"
}

KIT_LOCAL_ENABLED="${KIT_LOCAL_ENABLED:-$(_kit_local_cfg '.local.enabled' 'false')}"
KIT_LOCAL_PORT="${KIT_LOCAL_PORT:-$(_kit_local_cfg '.local.port' '8080')}"
KIT_LOCAL_MODEL="${KIT_LOCAL_MODEL:-$(_kit_local_cfg '.local.model' 'mlx-community/Qwen3-8B-4bit')}"
KIT_LOCAL_URL="http://127.0.0.1:${KIT_LOCAL_PORT}"
KIT_LOCAL_TIMEOUT="${KIT_LOCAL_TIMEOUT:-90}"

# 0 if enabled in config AND the server answers /v1/models within 1s.
kit_local_alive() {
  [[ "$KIT_LOCAL_ENABLED" == "true" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  curl -sf -m 1 "$KIT_LOCAL_URL/v1/models" >/dev/null 2>&1
}

# kit_local_chat "<system>" "<user prompt>" [max_tokens]
# Prints the assistant reply (reasoning <think> blocks stripped). Non-zero on any failure.
kit_local_chat() {
  local system="$1" prompt="$2" max_tokens="${3:-1024}"
  kit_local_alive || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local payload reply
  payload="$(jq -n --arg m "$KIT_LOCAL_MODEL" --arg s "$system" --arg p "$prompt" --argjson t "$max_tokens" \
    '{model:$m, messages:[{role:"system",content:$s},{role:"user",content:$p}], max_tokens:$t, temperature:0.2}')" || return 1

  reply="$(curl -sf -m "$KIT_LOCAL_TIMEOUT" "$KIT_LOCAL_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>/dev/null | jq -r '.choices[0].message.content // empty')" || return 1
  [[ -n "$reply" ]] || return 1

  # Qwen3 reasoning models may prefix a <think>...</think> block — strip it.
  printf '%s' "$reply" | perl -0pe 's/<think>.*?<\/think>\s*//gs' 2>/dev/null || printf '%s' "$reply"
}

# Short model tag for banners: "Qwen3-8B-4bit" from "mlx-community/Qwen3-8B-4bit".
kit_local_model_tag() {
  printf '%s' "${KIT_LOCAL_MODEL##*/}"
}

# 0 if the "local layer down" session notice is dismissed (#313). Dismiss channels:
#   - env KIT_LOCAL_DISMISS=1 (this session/shell only)
#   - config .local.dismissed = "<kitVersion at dismissal>" (written by kit-doctor
#     --dismiss-local) — sticks until the kit's x.y core moves past it; "true" = forever
kit_local_dismissed() {
  [[ "${KIT_LOCAL_DISMISS:-}" == "1" ]] && return 0
  local d cur
  d="$(_kit_local_cfg '.local.dismissed' '')"
  [[ -n "$d" ]] || return 1
  [[ "$d" == "true" ]] && return 0
  cur="$(_kit_local_cfg '.kitVersion' '0.0.0')"
  [[ "$(printf '%s' "$d" | cut -d. -f1-2)" == "$(printf '%s' "$cur" | cut -d. -f1-2)" ]]
}
