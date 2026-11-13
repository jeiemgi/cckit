#!/usr/bin/env bash
# benchmark/lib/model.sh — the pluggable model backend for the benchmark harness.
#
# Three entry points, all cascade-shaped so the backend is swappable with NO hard dependency on a
# specific provider:
#   bench_ask    "<question>"                 -> prints ONE repo-relative doc path, or "NONE"
#   bench_answer "<question>"                 -> prints the model's full answer from the docs
#   bench_judge  "<claim>" "<answer>" "<must>" -> prints a score in [0,1]
#
# Backend selection (first that applies wins), driven by env so a project overrides without editing:
#   BENCH_BACKEND=mock                  deterministic, offline (tests + --dry); never calls a model
#   BENCH_MODEL_ENDPOINT=<url>          any OpenAI-compat /chat/completions endpoint (curl)
#   (default)                           headless `claude -p` — the $0-API subscription path
#
# Everything is stdout-only + exit-code clean so the runner can capture answers and latency without
# a provider SDK. Source this file; do not execute it.

# ---- portable timeout ------------------------------------------------------
# `timeout(1)` is GNU/coreutils and absent on stock macOS. Fall back to a perl watchdog (perl is a
# kit dependency, see cckit doctor), then to a no-op that just runs the command. Usage:
#   bench_timeout <seconds> <cmd> [args…]
bench_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'my $s=shift; $SIG{ALRM}=sub{exit 124}; alarm $s; exec @ARGV or exit 127;' "$secs" "$@"
  else
    "$@"
  fi
}

BENCH_TIMEOUT_SECS="${BENCH_TIMEOUT_SECS:-90}"

# ---- backend resolution ----------------------------------------------------
bench_backend() {
  if [ -n "${BENCH_BACKEND:-}" ]; then printf '%s' "$BENCH_BACKEND"; return; fi
  if [ -n "${BENCH_MODEL_ENDPOINT:-}" ]; then printf 'openai'; return; fi
  printf 'claude'
}

# Low-level completion: prompt on $1, prints the model's raw text answer. Empty on failure — the
# callers decide what an empty answer means (NONE for ask, 0 for judge).
_bench_complete() {
  local prompt="$1" backend
  backend="$(bench_backend)"
  case "$backend" in
    mock)
      # Deterministic offline stand-in. Never used for scoring — the runner only reaches a real
      # backend when NOT --dry — but keeps the cascade total so sourcing never explodes.
      printf 'NONE' ;;
    openai)
      command -v curl >/dev/null 2>&1 || { return 1; }
      command -v jq   >/dev/null 2>&1 || { return 1; }
      local url="${BENCH_MODEL_ENDPOINT%/}/chat/completions"
      local model="${BENCH_MODEL:-gpt-4o-mini}"
      local body
      body="$(jq -n --arg m "$model" --arg p "$prompt" \
        '{model:$m, temperature:0, messages:[{role:"user",content:$p}]}')"
      bench_timeout "$BENCH_TIMEOUT_SECS" curl -sS "$url" \
        -H 'Content-Type: application/json' \
        ${BENCH_API_KEY:+-H "Authorization: Bearer $BENCH_API_KEY"} \
        -d "$body" </dev/null 2>/dev/null \
        | jq -r '.choices[0].message.content // empty' 2>/dev/null ;;
    claude|*)
      command -v claude >/dev/null 2>&1 || { return 1; }
      # Headless one-shot. `-p` prints the final answer and exits; the model may use its tools to
      # grep the repo, which is exactly the retrieval behavior we want to measure.
      # stdin is /dev/null on purpose: the runners call this inside `while read … done < <(records)`,
      # and a child that inherits that stdin drains it, so every set stopped after its first record.
      bench_timeout "$BENCH_TIMEOUT_SECS" claude -p "$prompt" </dev/null 2>/dev/null ;;
  esac
}

# ---- bench_ask -------------------------------------------------------------
# Ask the model which single canonical doc answers a question. Returns ONE repo-relative path (its
# top hit) or the literal NONE when nothing canonical covers it. $2 = knowledge dir (for the prompt).
bench_ask() {
  local question="$1" kdir="${2:-knowledge}" out
  local prompt
  prompt="You are auditing a project's documentation. Question: \"$question\"

Find the SINGLE canonical document under '$kdir/' that best answers it. Reply with ONLY that
document's repo-relative path on one line (for example: $kdir/releasing.md) and nothing else.
If no document genuinely answers it, reply with exactly: NONE"
  out="$(_bench_complete "$prompt")" || return 1
  # Keep only the last non-empty line, trimmed — models sometimes narrate before the path.
  out="$(printf '%s\n' "$out" | awk 'NF{last=$0} END{print last}')"
  out="$(printf '%s' "$out" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^["`'\'']//; s/["`'\'']$//')"
  [ -n "$out" ] || out="NONE"
  printf '%s' "$out"
}

# ---- bench_answer ----------------------------------------------------------
# Ask the model to ANSWER a question from the docs — the whole answer, every line of it. The quality
# tier grades this text. bench_ask is the wrong call there: it returns one path, and a path covers
# none of a rubric's points. $2 = knowledge dir (for the prompt). Prints nothing when the backend
# fails or times out; the caller scores an empty answer 0.
bench_answer() {
  local question="$1" kdir="${2:-knowledge}" prompt
  prompt="You are answering a question about this project from its own documentation.

QUESTION:
$question

Read the documents under '$kdir/' and answer from what they state. Give the complete answer: every
condition, default, exit code and command the documents give for it. Do not add anything they do not
state. End with one line naming the document(s) you used, as repo-relative paths. If the documents
do not cover the question, say so."
  _bench_complete "$prompt" || return 1
}

# ---- bench_judge -----------------------------------------------------------
# Score a claim-style answer against a `must` rubric (newline-separated points). The rubric de-biases
# the judge: it scores coverage of the required points, not vibes. Prints a float in [0,1].
bench_judge() {
  local claim="$1" answer="$2" must="$3" out score
  local prompt
  prompt="Grade an answer against a rubric. Be strict and objective.

QUESTION/CLAIM:
$claim

ANSWER TO GRADE:
$answer

REQUIRED POINTS (the answer must cover these; ignore style):
$must

Reply with ONLY a number between 0 and 1 (e.g. 0.75) = the fraction of required points the answer
correctly covers. No words."
  out="$(_bench_complete "$prompt")" || { printf '0'; return 0; }
  # BENCH_JUDGE_RAW=<file> keeps the judge's reply as it came back, before the number is cut out of
  # it: a score that looks wrong can then be told apart from a reply that was parsed wrong.
  [ -z "${BENCH_JUDGE_RAW:-}" ] || printf '%s\n' "$out" > "$BENCH_JUDGE_RAW"
  score="$(printf '%s' "$out" | grep -oE '0(\.[0-9]+)?|1(\.0+)?' | head -1)"
  [ -n "$score" ] || score="0"
  printf '%s' "$score"
}
