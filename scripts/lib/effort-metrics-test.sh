#!/usr/bin/env bash
# shellcheck shell=bash
# effort-metrics-test.sh — covers _em_token_sum's branch ∪ time-window attribution (#124). Token
# actuals must count sessions that match the effort BRANCH as well as sessions that fall inside the
# effort's build WINDOW [start,end] — the window recovers sessions logged before the branch field
# existed or from a detached/worktree checkout. Hermetic: a throwaway repo + a stubbed usage log +
# stubbed transcripts under a temp HOME. Run:  bash scripts/lib/effort-metrics-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fi; [ "$2" = "$3" ] || fail=1; }
command -v jq >/dev/null 2>&1 || { echo "effort-metrics-test: jq required — skipping"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "effort-metrics-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; mkdir -p "$HOME/.claude/projects"

# A repo so git-common-dir resolves; kit-usage.jsonl lives under it.
cd "$tmp"; git init -q repo; cd repo; git config user.email t@t; git config user.name t
git commit -q --allow-empty -m init
GCD="$(git rev-parse --git-common-dir)"; case "$GCD" in /*) : ;; *) GCD="$PWD/$GCD" ;; esac

# Usage log: A matches the branch; B matches the window (different branch, ts inside); C matches
# neither (different branch, ts outside the window).
START=1000000000; END=1000000900     # a 900s window
{
  printf '{"session":"AAA","branch":"effort/5-x","ts":"2001-09-09T01:46:20Z"}\n'   # branch match (ts irrelevant)
  printf '{"session":"BBB","branch":"other/9-y","ts":"2001-09-09T01:55:00Z"}\n'    # ~1000000500 — inside window
  printf '{"session":"CCC","branch":"other/9-z","ts":"2020-01-01T00:00:00Z"}\n'    # far outside window
} > "$GCD/kit-usage.jsonl"

# Transcripts: A=100 in, B=50 in, C=999 in. Only A+B should be counted.
printf '{"message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$HOME/.claude/projects/AAA.jsonl"
printf '{"message":{"usage":{"input_tokens":50,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n'  > "$HOME/.claude/projects/BBB.jsonl"
printf '{"message":{"usage":{"input_tokens":999,"output_tokens":99,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}\n' > "$HOME/.claude/projects/CCC.jsonl"

# shellcheck source=/dev/null
source "$LIB/effort-metrics.sh"

# branch only: counts A (100/10); window given but branch alone would miss B if window absent.
read -r i o _ _ <<< "$(_em_token_sum 'effort/5-x' 0 0)"
t "branch-only counts the branch session"      "$i $o" "100 10"

# branch ∪ window: counts A (branch) + B (window) = 150 in / 15 out; C excluded (outside window).
read -r i o _ _ <<< "$(_em_token_sum 'effort/5-x' "$START" "$END")"
t "branch ∪ window counts branch + window sessions" "$i $o" "150 15"

# window only (no branch): counts just B (inside window), never C.
read -r i o _ _ <<< "$(_em_token_sum '' "$START" "$END")"
t "window-only counts the in-window session"   "$i $o" "50 5"

# no branch, no window: nothing attributable.
t "no branch + no window sums to zero"          "$(_em_token_sum '' 0 0)" "0 0 0 0"

# ── #381: helpers resolve from the lib dir, not the caller's — under bash AND zsh ─────────────────
# Inside a zsh FUNCTION `BASH_SOURCE` is unset and `$0` is the function name, so a per-call
# `dirname "${BASH_SOURCE[0]:-$0}"` pointed at the caller's directory: engine-adapter.sh was never
# found and the sync buffered with "engine adapter unavailable". Run from a dir OUTSIDE the repo,
# with no config, so engine.mode reads "off" and the only way to that message is a found adapter.
outside="$tmp/outside"; mkdir -p "$outside"
_helpers_probe() {  # _helpers_probe <shell> [flag] — prints the sync's stderr, then DEFINED|UNDEFINED
  ( cd "$outside" && env -u KIT_CONFIG LIB="$LIB" "$@" -c '
      source "$LIB/effort-metrics.sh"
      sync_effort_metrics 1 2>&1
      if declare -f engine_enabled >/dev/null 2>&1; then echo DEFINED; else echo UNDEFINED; fi
      _em_judge_call s u >/dev/null 2>&1
      if declare -f kit_local_chat >/dev/null 2>&1; then echo LOCAL-DEFINED; else echo LOCAL-UNDEFINED; fi' 2>&1 )
}
_helpers_case() {  # _helpers_case <label> <shell> [flag]
  local label="$1" out; shift
  out="$(CCKIT_MODEL_URL='' KIT_LOCAL_ENABLED=false _helpers_probe "$@")"
  case "$out" in *"engine adapter unavailable"*) t "$label: sync finds the engine adapter" "unavailable" "found" ;;
                 *) t "$label: sync finds the engine adapter" "found" "found" ;; esac
  case "$out" in *"engine off"*) t "$label: sync reaches the engine-off branch" "off" "off" ;;
                 *) t "$label: sync reaches the engine-off branch" "$out" "off" ;; esac
  t "$label: engine_enabled is defined after the sync" "$(printf '%s\n' "$out" | grep -cx 'DEFINED')" "1"
  t "$label: judge fallback finds kit-local.sh"        "$(printf '%s\n' "$out" | grep -cx 'LOCAL-DEFINED')" "1"
}
_helpers_case bash bash
if command -v zsh >/dev/null 2>&1; then _helpers_case zsh zsh --no-rcs
else echo "skip: zsh absent — zsh helper-lookup case not run"; fi

# ── #381: the config names the judge's env vars (model.urlEnv / modelEnv / tokenEnv) ─────────────
# A stubbed curl on PATH records its argv and answers like an OpenAI-compatible endpoint.
stub="$tmp/stub"; mkdir -p "$stub"
cat > "$stub/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CURL_LOG"
printf '{"choices":[{"message":{"content":"VERDICT"}}]}'
STUB
chmod +x "$stub/curl"
export CURL_LOG="$tmp/curl.log"
cfg="$tmp/model.config.json"
printf '{"model":{"urlEnv":"ACME_LLM_URL","modelEnv":"ACME_LLM_NAME","tokenEnv":"ACME_LLM_KEY"}}\n' > "$cfg"
nocfg="$tmp/empty.config.json"; printf '{}\n' > "$nocfg"
_judge_probe() {  # _judge_probe <config> <shell> [flag] — prints "<model_id>\t<reply>"; argv lands in $CURL_LOG
  local c="$1"; shift; : > "$CURL_LOG"
  ( cd "$outside" && PATH="$stub:$PATH" KIT_CONFIG="$c" LIB="$LIB" "$@" -c '
      source "$LIB/effort-metrics.sh"; _em_judge_call sys usr' 2>&1 )
}
_judge_case() {  # _judge_case <label> <shell> [flag]
  local label="$1" out; shift
  out="$(ACME_LLM_URL='http://acme.test/v1/' ACME_LLM_NAME='acme-judge' ACME_LLM_KEY='acme-secret' \
         CCKIT_MODEL_URL='http://default.test/v1' CCKIT_MODEL='default-model' CCKIT_MODEL_TOKEN='default-secret' \
         _judge_probe "$cfg" "$@")"
  t "$label: named urlEnv is the endpoint requested"   "$(grep -c '^http://acme.test/v1/chat/completions$' "$CURL_LOG")" "1"
  t "$label: named modelEnv is the model + model_id"   "$out" "$(printf 'acme-judge\tVERDICT')"
  t "$label: named tokenEnv is the bearer token"       "$(grep -c '^Authorization: Bearer acme-secret$' "$CURL_LOG")" "1"
  t "$label: the default vars are not read when named" "$(grep -c 'default' "$CURL_LOG")" "0"

  out="$(CCKIT_MODEL_URL='http://default.test/v1' CCKIT_MODEL='default-model' CCKIT_MODEL_TOKEN='default-secret' \
         _judge_probe "$nocfg" "$@")"
  t "$label: keys unset → CCKIT_MODEL_URL still works" "$(grep -c '^http://default.test/v1/chat/completions$' "$CURL_LOG")" "1"
  t "$label: keys unset → CCKIT_MODEL names the model" "$out" "$(printf 'default-model\tVERDICT')"
  t "$label: keys unset → CCKIT_MODEL_TOKEN is sent"   "$(grep -c '^Authorization: Bearer default-secret$' "$CURL_LOG")" "1"

  out="$(CCKIT_MODEL_URL='http://default.test/v1' _judge_probe "$nocfg" "$@")"
  t "$label: no token → no Authorization header"       "$(grep -c '^Authorization' "$CURL_LOG")" "0"

  # A name that is not a shell identifier is refused (it would be eval'd): warn, use the default.
  printf '{"model":{"urlEnv":"X; touch %s/pwned"}}\n' "$tmp" > "$tmp/bad.config.json"
  out="$(CCKIT_MODEL_URL='http://default.test/v1' _judge_probe "$tmp/bad.config.json" "$@")"
  t "$label: invalid env name falls back to the default" "$(grep -c '^http://default.test/v1/chat/completions$' "$CURL_LOG")" "1"
  case "$out" in *"model.urlEnv"*) t "$label: invalid env name warns" "warned" "warned" ;;
                 *) t "$label: invalid env name warns" "$out" "warned" ;; esac
  t "$label: invalid env name is never executed" "$([ -e "$tmp/pwned" ] && echo ran || echo safe)" "safe"
}
_judge_case bash bash
if command -v zsh >/dev/null 2>&1; then _judge_case zsh zsh --no-rcs
else echo "skip: zsh absent — zsh judge env-name case not run"; fi

[ "$fail" -eq 0 ] && echo "ALL OK (effort-metrics)" || echo "effort-metrics: FAILURES"
exit "$fail"
