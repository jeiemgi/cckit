#!/usr/bin/env bash
# effort-metrics.sh — local-first effort telemetry capture (#796).
#
# Writes ONE record per effort to <git-common-dir>/effort-metrics/records.jsonl. Engine-independent:
# the Plan Engine is off by default (kit-engine-boundary.md), so metrics buffer LOCALLY here; a later
# sync (#811) flushes the buffer to the Postgres graph (schema #810) when the engine is connected.
# The record shape below IS that schema.
#
#   record_effort_start <num>            — stamp start epoch + write the pre-build estimate (#808)
#   capture_effort_metrics <num> [base]  — at close: build-time + signals + token/cost actuals (#807)
#                                          + reconcile vs the estimate → append the record
#
# Cost = metered API; retroactively $ is computed from current Opus-4.8 list price (no per-call bill
# access here) → cost_source="list-price". bash 3.2 compatible. Requires: git, jq.

# Opus 4.8 list price, USD per 1M tokens (correct as of 2026-06; update when prices change).
_EM_PRICE_IN=5.00; _EM_PRICE_OUT=25.00; _EM_PRICE_CACHE_READ=0.50; _EM_PRICE_CACHE_WRITE=6.25

_em_dir() {
  local c; c="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$c" in /*) : ;; *) c="$PWD/$c" ;; esac
  printf '%s/effort-metrics' "$c"
}

record_effort_start() {
  local num="$1" d
  [[ -n "$num" ]] || return 0
  d="$(_em_dir)" || return 0
  mkdir -p "$d" 2>/dev/null || return 0
  date -u +%s > "$d/$num.start" 2>/dev/null || true
  estimate_effort "$num" || true
}

# estimate_effort <num> — pre-build prediction from estimator.json + the effort's scope (#808).
# Predicts changed-lines from the sub-issue count (crude v1), then tokens/cost/difficulty from the
# derived ratios. Writes <num>.est; capture merges it in for est-vs-real reconciliation.
estimate_effort() {
  local num="$1" d est repo subs cpl med_changed med_commits changed_est tok_per_line tokens_est cost_est diff_est
  [[ -n "$num" ]] || return 0
  d="$(_em_dir)" || return 0; mkdir -p "$d" 2>/dev/null || return 0
  est="$d/estimator.json"; [[ -f "$est" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  repo="${EFFORT_REPO:-jeiemgi/cckit}"
  subs="$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){subIssues(first:50){totalCount}}}}' \
        -F o="${repo%/*}" -F r="${repo#*/}" -F n="$num" --jq '.data.repository.issue.subIssues.totalCount' 2>/dev/null)"
  [[ "$subs" =~ ^[0-9]+$ ]] || subs=1; [[ "$subs" -lt 1 ]] && subs=1

  cpl="$(jq -r '.model.cost_per_changed_line_usd // .model.cost_per_changed_line // 0.21' "$est")"
  med_changed="$(jq -r '.model.median_changed_lines // 73' "$est")"
  med_commits="$(jq -r '.model.median_commits // 1' "$est")"
  tok_per_line="$(jq -r '.model.tokens_per_changed_line // 0' "$est")"
  # tokens/cost are emitted ONLY when the estimator has real per-effort token data to calibrate
  # against (#812). Until then `tokens_per_changed_line` is an aggregate UPPER BOUND (windowed
  # transcripts incl. unrelated work ÷ a tiny line count) → wildly inflated (#787 saw ~110M). Emit
  # null instead of a fabricated number; the changed-lines + difficulty estimate stays (reliable).
  local tokens_calibrated; tokens_calibrated="$(jq -r '.model.tokens_calibrated // false' "$est")"
  [[ "$med_commits" =~ ^[0-9]+$ && "$med_commits" -gt 0 ]] || med_commits=1

  # changed-lines ≈ subs scaled against the median effort (median_changed per median_commits).
  changed_est=$(awk -v s="$subs" -v mc="$med_changed" -v mk="$med_commits" 'BEGIN{printf "%d", s*(mc/mk)}')
  diff_est=$(_em_difficulty "$changed_est" 0)
  if [[ "$tokens_calibrated" == "true" ]]; then
    cost_est=$(awk -v c="$changed_est" -v p="$cpl" 'BEGIN{printf "%.2f", c*p}')
    tokens_est=$(awk -v c="$changed_est" -v t="$tok_per_line" 'BEGIN{printf "%d", c*t}')
  else
    cost_est=null; tokens_est=null
  fi

  jq -cn --argjson num "$num" --argjson ce "$changed_est" --argjson te "${tokens_est:-null}" \
        --argjson ce_usd "${cost_est:-null}" --argjson de "$diff_est" \
    '{effort:$num, changed_lines_est:$ce, tokens_est:$te, cost_est_usd:$ce_usd, difficulty_est:$de}' \
    > "$d/$num.est" 2>/dev/null || true
}

# _em_difficulty <changed-lines> <files> — the shared 1–5 bucket.
_em_difficulty() {
  local churn="${1:-0}" files="${2:-0}" d=1
  if   (( churn > 1500 || files > 30 )); then d=5
  elif (( churn > 600  || files > 15 )); then d=4
  elif (( churn > 200  || files > 6  )); then d=3
  elif (( churn > 40   || files > 2  )); then d=2
  fi
  printf '%s' "$d"
}

# effort_ctx_bucket <difficulty-1-5> [subcount] — map the estimate to a session-weight bucket.
# ctx:S fits inline with others; ctx:L / ctx:XL want their subs delegated to sub-agents so the main
# session stays light (the lever that widens a session — rules/agent-execution-routing.md). Echoes
# `ctx:S|M|L|XL` (a ready-to-apply GitHub label).
effort_ctx_bucket() {
  local diff="${1:-1}" subs="${2:-1}" b
  [[ "$diff" =~ ^[0-9]+$ ]] || diff=1
  [[ "$subs" =~ ^[0-9]+$ ]] || subs=1
  if   (( diff >= 5 ));                 then b=XL
  elif (( diff == 4 || subs >= 5 ));    then b=L
  elif (( diff == 3 || subs >= 3 ));    then b=M
  else                                       b=S
  fi
  printf 'ctx:%s' "$b"
}

# _em_token_sum <branch> — sum transcript usage for an effort's sessions (#807). Sessions are looked
# up in <gcd>/kit-usage.jsonl by branch (#784); each session's transcript is found under
# ~/.claude/projects/*/. Echoes "in out cache_read cache_write" (0s when unmappable). Going-forward
# only — the usage log is empty for the past (backtrace left tokens null, by design).
_em_token_sum() {
  local branch="$1" gcd ulog sids sid tx tin=0 tout=0 tcr=0 tcw=0 sums
  local IFS=' '   # force space-split for `set --` (ambient IFS may carry a NUL — see ifs landmine)
  gcd="$(git rev-parse --git-common-dir 2>/dev/null)" || { echo "0 0 0 0"; return 0; }
  ulog="$gcd/kit-usage.jsonl"
  [[ -f "$ulog" && -n "$branch" ]] || { echo "0 0 0 0"; return 0; }
  sids="$(jq -r --arg b "$branch" 'select(.branch==$b and .session!="")|.session' "$ulog" 2>/dev/null | sort -u)"
  [[ -n "$sids" ]] || { echo "0 0 0 0"; return 0; }
  while IFS= read -r sid; do
    [[ -n "$sid" ]] || continue
    tx="$(find "$HOME/.claude/projects" -name "$sid.jsonl" -type f 2>/dev/null | head -1)"
    [[ -n "$tx" ]] || continue
    # -r (raw) is REQUIRED: without it jq wraps the result string in double-quotes, so $a
    # becomes `"1015901` and the `$(( ))` math below dies ("bad math expression") — the #829 bug.
    sums="$(jq -rs '[.[].message.usage // empty] | {i:(map(.input_tokens//0)|add), o:(map(.output_tokens//0)|add), cr:(map(.cache_read_input_tokens//0)|add), cw:(map(.cache_creation_input_tokens//0)|add)} | "\(.i) \(.o) \(.cr) \(.cw)"' "$tx" 2>/dev/null)"
    local a b c cw_; read -r a b c cw_ <<< "$sums"
    tin=$(( tin + ${a:-0} )); tout=$(( tout + ${b:-0} )); tcr=$(( tcr + ${c:-0} )); tcw=$(( tcw + ${cw_:-0} ))
  done <<< "$sids"
  echo "$tin $tout $tcr $tcw"
}

capture_effort_metrics() {
  local num="$1" base="${2:-origin/develop}" d start now build_s shortstat files added removed commits churn diff_auto branch
  local toks tin tout tcr tcw tokens_real cost_real cost_source tokens_est cost_est rec
  local IFS=' '   # force space-split for `set --` below (ambient IFS may carry a NUL)
  [[ -n "$num" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  d="$(_em_dir)" || return 0; mkdir -p "$d" 2>/dev/null || return 0

  now="$(date -u +%s 2>/dev/null)"; build_s="null"
  if [[ -f "$d/$num.start" ]]; then
    start="$(cat "$d/$num.start" 2>/dev/null)"
    [[ "$start" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ ]] && build_s=$(( now - start ))
  fi

  git fetch origin --quiet 2>/dev/null || true
  shortstat="$(git diff --shortstat "$base"...HEAD 2>/dev/null)"
  files=$(printf '%s' "$shortstat"   | grep -oE '[0-9]+ file'      | grep -oE '[0-9]+' | head -1)
  added=$(printf '%s' "$shortstat"   | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' | head -1)
  removed=$(printf '%s' "$shortstat" | grep -oE '[0-9]+ deletion'  | grep -oE '[0-9]+' | head -1)
  commits=$(git rev-list --count "$base"..HEAD 2>/dev/null)
  files=${files:-0}; added=${added:-0}; removed=${removed:-0}; commits=${commits:-0}
  churn=$(( added + removed )); diff_auto=$(_em_difficulty "$churn" "$files")
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"

  # Post-close footgun guard (#829). capture MUST run PRE-squash (kit-effort-close step a, on the
  # live effort branch). If every signal is zero on a base branch, the effort already merged+GC'd —
  # warn loudly instead of silently recording a meaningless all-zero row (the #787 manual-close bug).
  if [[ "$files" -eq 0 && "$commits" -eq 0 && "$branch" =~ ^(develop|main)$ ]]; then
    echo "effort-metrics: WARN #$num — capture on '$branch' with an empty diff; run it PRE-close (the effort branch is gone). Recording zeros." >&2
  fi

  # token/cost actuals (#807) — going-forward only.
  toks="$(_em_token_sum "$branch")"; read -r tin tout tcr tcw <<< "$toks"
  tin=${tin:-0}; tout=${tout:-0}; tcr=${tcr:-0}; tcw=${tcw:-0}
  if (( tin + tout + tcr + tcw > 0 )); then
    tokens_real=$(( tin + tout + tcr + tcw ))
    cost_real=$(awk -v i="$tin" -v o="$tout" -v cr="$tcr" -v cw="$tcw" \
      -v pi="$_EM_PRICE_IN" -v po="$_EM_PRICE_OUT" -v pcr="$_EM_PRICE_CACHE_READ" -v pcw="$_EM_PRICE_CACHE_WRITE" \
      'BEGIN{printf "%.4f", (i*pi + o*po + cr*pcr + cw*pcw)/1000000}')
    cost_source='"list-price"'
  else
    tokens_real=null; cost_real=null; cost_source=null
  fi

  # estimate (#808) for reconciliation.
  tokens_est=null; cost_est=null
  if [[ -f "$d/$num.est" ]]; then
    tokens_est="$(jq -r '.tokens_est // "null"' "$d/$num.est")"; [[ "$tokens_est" =~ ^[0-9]+$ ]] || tokens_est=null
    cost_est="$(jq -r '.cost_est_usd // "null"' "$d/$num.est")"; [[ "$cost_est" =~ ^[0-9.]+$ ]] || cost_est=null
  fi

  rec="$(jq -cn --argjson num "$num" --arg branch "$branch" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson build "$build_s" --argjson files "$files" --argjson added "$added" \
        --argjson removed "$removed" --argjson commits "$commits" \
        --argjson tokens_real "$tokens_real" --argjson cost_real "$cost_real" --argjson cost_source "$cost_source" \
        --argjson tokens_est "$tokens_est" --argjson cost_est "$cost_est" --argjson diff "$diff_auto" '
    {effort:$num, branch:$branch, captured_at:$at, build_seconds:$build,
     signals:{files:$files, added:$added, removed:$removed, commits:$commits},
     tokens_real:$tokens_real, cost_real_usd:$cost_real, cost_source:$cost_source,
     tokens_est:$tokens_est, cost_est_usd:$cost_est,
     difficulty_auto:$diff, score_auto:null, difficulty_judge:null, score_judge:null,
     synced_to_graph:false}' 2>/dev/null)" || return 0
  [[ -n "$rec" ]] || return 0
  printf '%s\n' "$rec" >> "$d/records.jsonl"
  rm -f "$d/$num.start" "$d/$num.est" 2>/dev/null || true
  echo "[#$num] metrics: build=${build_s}s files=$files +$added/-$removed commits=$commits diff=$diff_auto tokens_real=$tokens_real cost_real=$cost_real est_tokens=$tokens_est → records.jsonl" >&2
  # Self-improving estimator (#812): recalibrate the medians/ratios from the now-larger dataset so the
  # next effort's pre-build estimate reflects reality (flips tokens_calibrated once ≥5 real-token rows).
  recalibrate_estimator >/dev/null 2>&1 || true
}

# ── LLM judge (#809) ─────────────────────────────────────────────────────────────────────────
# judge_effort_metrics <num> [base] — score an effort's quality + difficulty with a model.
#
# Sends the effort GOAL + (truncated) diff/trace to CCKIT_MODEL (OpenAI-compat, PRIMARY) with a
# rubric → STRICT JSON {difficulty_judge:1..5, score_judge:0..1, rationale}. Falls back to the LOCAL
# model (kit_local_chat) when the hosted endpoint is unreachable/empty. If NEITHER is available the
# fields stay null and close is NEVER blocked (logs "skipped (no model)", returns 0). Idempotent:
# re-running overwrites the row's *_judge fields + model_id and re-marks it unsynced so the new
# fields reach the graph on the next sync. Requires: jq, git, curl (for the hosted path).

# Truncate budget for the diff handed to the model (keep the prompt under the context window).
_EM_JUDGE_MAX_CHARS="${EM_JUDGE_MAX_CHARS:-12000}"

# _em_judge_diff <num> <base> — the effort diff for the judge. Prefers the durable trace dir
# (<git-common-dir>/traces/effort-<N>/*.diff, written pre-squash by effort_snapshot_subs) and falls
# back to `git diff <base>...HEAD`. Echoes the (untruncated) diff; truncation happens in the caller.
_em_judge_diff() {
  local num="$1" base="${2:-origin/develop}" common tdir
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || true
  if [[ -n "$common" ]]; then
    case "$common" in /*) : ;; *) common="$PWD/$common" ;; esac
    tdir="$common/traces/effort-$num"
    if [[ -d "$tdir" ]] && ls "$tdir"/*.diff >/dev/null 2>&1; then
      cat "$tdir"/*.diff 2>/dev/null
      return 0
    fi
  fi
  git diff "$base"...HEAD 2>/dev/null
}

# _em_judge_goal <num> — best-effort effort GOAL (the `## Goal` section of the issue body). Empty
# string when gh is unavailable or the section is absent — the judge still runs on the diff alone.
_em_judge_goal() {
  local num="$1" repo body
  command -v gh >/dev/null 2>&1 || { printf ''; return 0; }
  repo="${EFFORT_REPO:-jeiemgi/cckit}"
  body="$(gh issue view "$num" --repo "$repo" --json body --jq '.body' 2>/dev/null)" || { printf ''; return 0; }
  [[ -n "$body" ]] || { printf ''; return 0; }
  # Extract the lines after "## Goal" up to the next "## " heading.
  printf '%s\n' "$body" | awk '
    /^##[ \t]+[Gg]oal[ \t]*$/ { grab=1; next }
    /^##[ \t]/ { if (grab) exit }
    grab { print }' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$' | head -20
}

# _em_judge_call <system> <user> — try CCKIT_MODEL (hosted, OpenAI-compat) then the local model.
# Echoes "<model_id>\t<reply>" on success; non-zero + nothing on total failure. The model_id is the
# hosted model name or the local tag, so the schema's model_id column records who judged.
_em_judge_call() {
  local system="$1" user="$2" url payload reply model

  # PRIMARY: hosted CCKIT_MODEL (OpenAI-compatible chat completions).
  if [[ -n "${CCKIT_MODEL_URL:-}" ]] && command -v curl >/dev/null 2>&1; then
    url="${CCKIT_MODEL_URL%/}/chat/completions"
    model="${CCKIT_MODEL:-default}"
    payload="$(jq -n --arg m "$model" --arg s "$system" --arg p "$user" \
      '{model:$m, messages:[{role:"system",content:$s},{role:"user",content:$p}], max_tokens:512, temperature:0.1}')" || payload=""
    if [[ -n "$payload" ]]; then
      reply="$(curl -sf -m "${EM_JUDGE_TIMEOUT:-60}" "$url" \
        -H 'Content-Type: application/json' \
        ${CCKIT_MODEL_TOKEN:+-H "Authorization: Bearer $CCKIT_MODEL_TOKEN"} \
        -d "$payload" 2>/dev/null | jq -r '.choices[0].message.content // empty' 2>/dev/null)" || reply=""
      if [[ -n "$reply" ]]; then
        printf '%s\t%s' "$model" "$reply"
        return 0
      fi
    fi
  fi

  # FALLBACK: local model via kit-local.sh.
  if ! declare -f kit_local_chat >/dev/null 2>&1; then
    local _ldir; _ldir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    [[ -f "$_ldir/kit-local.sh" ]] && source "$_ldir/kit-local.sh"
  fi
  if declare -f kit_local_chat >/dev/null 2>&1 && kit_local_alive 2>/dev/null; then
    reply="$(kit_local_chat "$system" "$user" 512 2>/dev/null)" || reply=""
    if [[ -n "$reply" ]]; then
      model="$(declare -f kit_local_model_tag >/dev/null 2>&1 && kit_local_model_tag || printf 'local')"
      printf '%s\t%s' "$model" "$reply"
      return 0
    fi
  fi
  return 1
}

judge_effort_metrics() {
  local num="$1" base="${2:-origin/develop}" d f goal diff truncated_note system user out model reply json dj sj
  [[ -n "$num" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  d="$(_em_dir)" || return 0; f="$d/records.jsonl"
  [[ -f "$f" ]] || { echo "[#$num] judge: no records.jsonl — capture must run first; skipping" >&2; return 0; }

  # Gather + truncate the diff.
  diff="$(_em_judge_diff "$num" "$base")"
  if [[ -z "$diff" ]]; then
    echo "[#$num] judge: empty diff — nothing to judge; leaving *_judge null" >&2
    return 0
  fi
  truncated_note=""
  if (( ${#diff} > _EM_JUDGE_MAX_CHARS )); then
    diff="${diff:0:$_EM_JUDGE_MAX_CHARS}"
    truncated_note=$'\n\n[NOTE: the diff above was TRUNCATED to fit the context budget — judge from the visible portion.]'
  fi
  goal="$(_em_judge_goal "$num")"

  # Rubric.
  system='You are a senior engineering reviewer scoring a completed unit of work ("effort") in a software project. Reply with STRICT JSON ONLY (no prose, no markdown fences): {"difficulty_judge": <integer 1-5>, "score_judge": <float 0.0-1.0>, "rationale": "<one sentence>"}.

difficulty_judge (1-5) = how hard the work was, judged from the change:
  1 = trivial (tiny/mechanical edit), 2 = easy (small, localized), 3 = moderate (multi-file or some design), 4 = hard (broad blast radius, non-trivial design), 5 = very hard (cross-cutting, intricate, risky).
score_judge (0.0-1.0) = quality of the work vs its stated goal:
  near 1.0 = clean, complete, idiomatic, matches the goal; ~0.5 = partial or rough; near 0.0 = wrong, incomplete, or off-goal.
Judge only from the evidence given. Output the JSON object and nothing else.'

  user="GOAL:
${goal:-(no goal text available — judge difficulty/quality from the diff alone)}

DIFF (unified):
${diff}${truncated_note}"

  out="$(_em_judge_call "$system" "$user")" || {
    echo "[#$num] judge: skipped (no model) — CCKIT_MODEL unreachable and local model unavailable; *_judge stay null" >&2
    return 0
  }
  model="${out%%$'\t'*}"; reply="${out#*$'\t'}"

  # Extract the first {...} object from the reply (models often wrap it in prose/fences).
  json="$(printf '%s' "$reply" | tr '\n' ' ' | grep -oE '\{[^{}]*\}' | head -1)"
  if [[ -z "$json" ]]; then
    echo "[#$num] judge: model reply had no JSON object — leaving *_judge null (model=$model)" >&2
    return 0
  fi
  dj="$(printf '%s' "$json" | jq -r '.difficulty_judge // empty' 2>/dev/null)"
  sj="$(printf '%s' "$json" | jq -r '.score_judge // empty' 2>/dev/null)"
  # Validate: difficulty integer 1..5, score float 0..1.
  if ! [[ "$dj" =~ ^[0-9]+$ ]] || (( dj < 1 || dj > 5 )); then
    echo "[#$num] judge: difficulty_judge='$dj' out of range — leaving *_judge null (model=$model)" >&2
    return 0
  fi
  if ! printf '%s' "$sj" | grep -qE '^[0-9]+(\.[0-9]+)?$' || ! awk -v s="$sj" 'BEGIN{exit !(s>=0 && s<=1)}'; then
    echo "[#$num] judge: score_judge='$sj' out of range — leaving *_judge null (model=$model)" >&2
    return 0
  fi

  # Update the effort's row: the one with .effort==num that still has a null judge (idempotent — if
  # all rows are already judged, re-judge the most recent one). Re-mark it unsynced so the new fields
  # reach the graph on the next sync.
  local tmp rec; tmp="$f.judge.$$"; : > "$tmp"
  local applied=0
  # Line-wise so we touch exactly ONE row (jq has no cross-line "first match only" state). First
  # choice: a row for this effort that still has a null judge.
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    if (( applied == 0 )) && [[ "$(jq -r '.effort' <<<"$rec" 2>/dev/null)" == "$num" ]] \
       && [[ "$(jq -r '.difficulty_judge' <<<"$rec" 2>/dev/null)" == "null" ]]; then
      rec="$(jq -c --argjson dj "$dj" --argjson sj "$sj" --arg model "$model" \
        '.difficulty_judge=$dj | .score_judge=$sj | .model_id=$model | .synced_to_graph=false' <<<"$rec")"
      applied=1
    fi
    printf '%s\n' "$rec" >> "$tmp"
  done < "$f"
  # Idempotent re-judge: no null-judge row found → overwrite the LAST row for this effort.
  if (( applied == 0 )); then
    : > "$tmp"
    local lastline; lastline="$(grep -n "\"effort\":$num[,}]" "$f" 2>/dev/null | tail -1 | cut -d: -f1)"
    local i=0
    while IFS= read -r rec; do
      i=$((i+1))
      [[ -n "$rec" ]] || { printf '%s\n' "$rec" >> "$tmp"; continue; }
      if [[ -n "$lastline" && "$i" == "$lastline" ]]; then
        rec="$(jq -c --argjson dj "$dj" --argjson sj "$sj" --arg model "$model" \
          '.difficulty_judge=$dj | .score_judge=$sj | .model_id=$model | .synced_to_graph=false' <<<"$rec")"
        applied=1
      fi
      printf '%s\n' "$rec" >> "$tmp"
    done < "$f"
  fi
  if (( applied == 0 )); then
    echo "[#$num] judge: no matching record row to update — leaving file unchanged (model=$model)" >&2
    rm -f "$tmp" 2>/dev/null
    return 0
  fi
  mv "$tmp" "$f"
  echo "[#$num] judge: difficulty_judge=$dj score_judge=$sj model=$model → records.jsonl (re-marked unsynced)" >&2
}

# sync_effort_metrics [num] — push unsynced records.jsonl rows into the Plan Engine graph (#832).
# No-op when the engine is off (engine.mode:"off" → rows stay in the local buffer). Flips
# synced_to_graph=true ONLY on a successful POST, so a re-run retries failures without duplicating
# the successes. Sources the engine adapter itself if the caller didn't. [num] is only for the log.
sync_effort_metrics() {
  command -v jq >/dev/null 2>&1 || return 0
  if ! declare -f engine_call >/dev/null 2>&1; then
    local _adir; _adir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    [[ -f "$_adir/engine-adapter.sh" ]] && source "$_adir/engine-adapter.sh"
  fi
  declare -f engine_enabled >/dev/null 2>&1 || { echo "effort-metrics: engine adapter unavailable — buffered locally" >&2; return 0; }
  engine_enabled || { echo "effort-metrics: engine off — metrics stay in the local buffer" >&2; return 0; }
  local d f tmp rec n=0 fail=0
  d="$(_em_dir)" || return 0; f="$d/records.jsonl"; [[ -f "$f" ]] || return 0
  tmp="$f.sync.$$"; : > "$tmp"
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    if [[ "$(jq -r '.synced_to_graph' <<<"$rec" 2>/dev/null)" == "false" ]]; then
      if engine_call POST /plan/effort-metrics "$rec" >/dev/null 2>&1; then
        rec="$(jq -c '.synced_to_graph=true' <<<"$rec")"; n=$((n+1))
      else
        fail=$((fail+1))
      fi
    fi
    printf '%s\n' "$rec" >> "$tmp"
  done < "$f"
  mv "$tmp" "$f"
  local msg="effort-metrics: synced $n row(s) to the engine"
  (( fail > 0 )) && msg="$msg ($fail failed, kept for retry)"
  echo "$msg" >&2
}

# recalibrate_estimator [stamp] — recompute estimator.json from the real captured dataset
# (records.jsonl), so the pre-build estimate self-improves as efforts accrue (#812). Median signals
# come from rows with real diff signals (0-churn post-GC rows dropped); the token/cost ratios are
# recomputed ONLY from rows with real per-effort token actuals, and `tokens_calibrated` flips true
# once there are >= EM_TOKEN_MIN (default 5) such rows. Merges over the existing estimator.json so
# pricing/notes/token_share are preserved. [stamp] = ISO time (defaults to `date -u`).
recalibrate_estimator() {
  command -v jq >/dev/null 2>&1 || return 0
  local d est f stamp min model
  d="$(_em_dir)" || return 0; f="$d/records.jsonl"; est="$d/estimator.json"
  [[ -f "$f" ]] || { echo "effort-metrics: no records.jsonl to calibrate from" >&2; return 0; }
  stamp="${1:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  min="${EM_TOKEN_MIN:-5}"
  model="$(jq -s --argjson min "$min" --arg stamp "$stamp" '
    def med(a): (a|sort) as $s | ($s|length) as $l
      | if $l==0 then null elif $l%2==1 then $s[($l-1)/2] else (($s[$l/2-1]+$s[$l/2])/2) end;
    [ .[] | { lines:((.signals.added//0)+(.signals.removed//0)), files:(.signals.files//0),
              commits:(.signals.commits//0), build:.build_seconds, tok:.tokens_real, cost:.cost_real_usd } ]
    | map(select(.lines>0)) as $rows
    | ($rows | map(select(.tok!=null and .tok>0))) as $rt
    | ($rt|length) as $nrt
    | { n_efforts:($rows|length), n_real_token_efforts:$nrt, tokens_calibrated:($nrt>=$min),
        median_changed_lines: med([$rows[].lines]), median_files: med([$rows[].files]),
        median_commits: med([$rows[].commits]),
        median_build_seconds: med([$rows[]|select(.build!=null)|.build]),
        tokens_per_changed_line: (if $nrt>=$min then (([$rt[].tok]|add)/([$rt[].lines]|add)) else null end),
        cost_per_changed_line_usd: (if $nrt>=$min then (([$rt[]|(.cost|tonumber? // 0)]|add)/([$rt[].lines]|add)) else null end),
        recalibrated_at:$stamp }' "$f")"
  [[ -n "$model" ]] || { echo "effort-metrics: recalibrate produced nothing" >&2; return 1; }
  if [[ -f "$est" ]]; then
    jq --argjson m "$model" '.model = ((.model // {}) * $m) | .recalibrated_at = $m.recalibrated_at' "$est" > "$est.tmp" && mv "$est.tmp" "$est"
  else
    jq -n --argjson m "$model" '{model:$m, recalibrated_at:$m.recalibrated_at}' > "$est"
  fi
  echo "effort-metrics: recalibrated from $(jq -r '.model.n_efforts' "$est") efforts (tokens_calibrated=$(jq -r '.model.tokens_calibrated' "$est"), real-token efforts=$(jq -r '.model.n_real_token_efforts' "$est"))" >&2
}
