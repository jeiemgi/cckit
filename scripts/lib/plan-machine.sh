#!/usr/bin/env bash
# plan-machine.sh — the wave plan: turn the board into a deps-ordered, file-disjoint, session-fit
# execution plan the copilot fans out over (Effort 75 · #76).
#
# `cckit plan` reads the open board (or one effort's sub-issues), resolves the native GitHub
# `blocked_by` edges, and layers the issues into WAVES: wave 0 is everything unblocked, wave N is
# everything whose blockers all landed in earlier waves. Every issue in a wave is independent of the
# others in that wave, so a wave is exactly "what N agents can run in parallel right now". Within a
# wave we pack issues into BATCHES under a session ctx budget, starting a new batch when the budget
# would overflow or two issues declare overlapping files (so parallel subagents don't collide).
#
#   cckit plan                 human wave plan for the open board
#   cckit plan --llm           TOON wave plan (uniform rows: wave,batch,number,ctx,blockers,title)
#   cckit plan --effort <N>    plan only effort #N's sub-issues
#   cckit plan --milestone <M> filter to milestone M
#   cckit plan --cap <N>       session ctx budget per batch (default KIT_SESSION_BUDGET or 4)
#
# ctx weights: S=1 · M=2 · L=4 · XL=8. File hints: a "Files:"/"Touches:" line in the issue body
# (comma/space-separated paths) drives intra-wave disjointness; absent → ctx budget alone batches.
#
# Requires: gh, jq. bash 3.2 (no associative arrays — parallel indexed arrays + linear scan; N small).

PLAN_REPO="${PLAN_REPO:-${KIT_REPO:-}}"

_pm_weight() { case "$1" in S) echo 1 ;; M) echo 2 ;; L) echo 4 ;; XL) echo 8 ;; *) echo 2 ;; esac; }

# pm_waves — pure layered topo-sort. stdin: lines "num<TAB>csvBlockers"; stdout: "num<TAB>wave".
# Only blockers present in the input set constrain layering (out-of-set/closed blockers are the
# caller's concern). Cycle-safe: any leftover after no-progress lands in a final wave.
pm_waves() {
  # dual-shell arrays: ksh_arrays gives zsh 0-based indexing + bash-style subscripting.
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options ksh_arrays sh_word_split 2>/dev/null
  local -a N=() B=() W=()
  local num blk
  while IFS="$(printf '\t')" read -r num blk; do
    [ -n "$num" ] || continue
    N[${#N[@]}]="$num"; B[${#B[@]}]="$blk"; W[${#W[@]}]="-1"
  done
  local n="${#N[@]}" w=0 remaining="${#N[@]}" progress=1 i j b bl ok
  [ "$remaining" -gt 0 ] || return 0
  while [ "$remaining" -gt 0 ] && [ "$progress" -eq 1 ]; do
    progress=0
    local -a ready=()
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${W[$i]}" = "-1" ]; then
        ok=1; bl="${B[$i]}"
        for b in ${bl//,/ }; do
          j=0
          while [ "$j" -lt "$n" ]; do
            if [ "${N[$j]}" = "$b" ] && [ "${W[$j]}" = "-1" ]; then ok=0; fi
            j=$((j + 1))
          done
        done
        [ "$ok" = "1" ] && ready[${#ready[@]}]="$i"
      fi
      i=$((i + 1))
    done
    if [ "${#ready[@]}" -gt 0 ]; then
      for i in "${ready[@]}"; do W[$i]="$w"; done
      remaining=$((remaining - ${#ready[@]})); w=$((w + 1)); progress=1
    fi
  done
  i=0
  while [ "$i" -lt "$n" ]; do [ "${W[$i]}" = "-1" ] && W[$i]="$w"; i=$((i + 1)); done
  i=0
  while [ "$i" -lt "$n" ]; do printf '%s\t%s\n' "${N[$i]}" "${W[$i]}"; i=$((i + 1)); done
}

# pm_batches — pure session-fit + file-disjoint packer for ONE wave (already deps-independent).
# stdin: lines "num<TAB>ctx<TAB>spaceSepFiles"; stdout: "num<TAB>batch". Budget = $1 (default 4).
# New batch when load+weight would overflow the budget OR the issue's files intersect the batch.
pm_batches() {
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options ksh_arrays sh_word_split 2>/dev/null
  local budget="${1:-4}"
  local -a N=() C=() F=()
  local num ctx files
  while IFS="$(printf '\t')" read -r num ctx files; do
    [ -n "$num" ] || continue
    N[${#N[@]}]="$num"; C[${#C[@]}]="$ctx"; F[${#F[@]}]="$files"
  done
  local n="${#N[@]}" batch=0 load=0 batchfiles=" " i w f ff need
  i=0
  while [ "$i" -lt "$n" ]; do
    w="$(_pm_weight "${C[$i]}")"
    need=0
    [ $((load + w)) -gt "$budget" ] && need=1
    ff="${F[$i]}"
    for f in $ff; do
      case "$batchfiles" in *" $f "*) need=1 ;; esac
    done
    if [ "$need" = "1" ] && [ "$load" -gt 0 ]; then
      batch=$((batch + 1)); load=0; batchfiles=" "
    fi
    load=$((load + w))
    for f in $ff; do batchfiles="$batchfiles$f "; done
    printf '%s\t%s\n' "${N[$i]}" "$batch"
    i=$((i + 1))
  done
}

# _pm_files — pull a "Files:" / "Touches:" hint line from an issue body; emit space-separated paths.
_pm_files() {
  printf '%s' "$1" | grep -ioE '^[[:space:]]*(Files|Touches):[[:space:]]*.*' 2>/dev/null \
    | head -1 | sed -E 's/^[[:space:]]*(Files|Touches):[[:space:]]*//I; s/[,]+/ /g' \
    | tr -s ' ' | sed 's/^ //; s/ $//'
}

plan_machine() {
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "plan: needs gh + jq" >&2; return 1; }
  # output mode: the dispatcher strips --llm and exports CCKIT_OUTPUT=json, so honor that env first;
  # --llm/--output=json are kept for direct lib calls / tests.
  local repo="$PLAN_REPO" budget="${KIT_SESSION_BUDGET:-4}" out="${CCKIT_OUTPUT:-human}" effort="" ms=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --llm|--output=json) out="json"; shift ;;
      --effort)    effort="$2"; shift 2 ;;
      --effort=*)  effort="${1#*=}"; shift ;;
      --milestone) ms="$2"; shift 2 ;;
      --milestone=*) ms="${1#*=}"; shift ;;
      --cap)       budget="$2"; shift 2 ;;
      --cap=*)     budget="${1#*=}"; shift ;;
      -h|--help)   sed -n '14,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "plan: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$repo" ] || { echo "plan: no repo (set KIT_REPO / PLAN_REPO)" >&2; return 1; }
  case "$budget" in ''|*[!0-9]*) echo "plan: --cap needs a number (got '$budget')" >&2; return 2 ;; esac

  # 1. the issue set: an effort's sub-issues, or the open board.
  local raw
  if [ -n "$effort" ]; then
    raw="$(gh api "repos/$repo/issues/$effort/sub_issues" --paginate \
      --jq '.[] | select(.state=="open") | [(.number|tostring), .title, .body] | @tsv' 2>/dev/null)" \
      || { echo "plan: failed to read sub-issues of #$effort" >&2; return 1; }
  else
    local mjq='.[]'
    [ -n "$ms" ] && mjq=".[] | select((.milestone.title // \"\") == \"$ms\")"
    raw="$(gh issue list --repo "$repo" --state open --limit 200 --json number,title,body,milestone \
      --jq "$mjq | [(.number|tostring), .title, .body] | @tsv" 2>/dev/null)" \
      || { echo "plan: gh query failed (check gh auth)" >&2; return 1; }
  fi
  [ -n "$raw" ] || { [ "$out" = "json" ] && echo "[]" || echo "plan: no open issues to plan"; return 0; }

  # 2. parallel arrays + per-issue ctx label, file hint, and OPEN blocked_by edges.
  local -a nums=() titles=() ctxs=() files=() blkall=()
  local n t b body lab
  while IFS="$(printf '\t')" read -r n t body; do
    [ -n "$n" ] || continue
    nums+=("$n"); titles+=("$t")
    lab="$(gh issue view "$n" --repo "$repo" --json labels \
      --jq '[.labels[].name|select(startswith("ctx:"))|ltrimstr("ctx:")]|first // "M"' 2>/dev/null)"
    ctxs+=("${lab:-M}")
    files+=("$(_pm_files "$body")")
    # only OPEN blockers gate execution; closed ones are already satisfied.
    b="$(gh api "repos/$repo/issues/$n/dependencies/blocked_by" \
      --jq '[.[]|select(.state=="open")|.number]|join(",")' 2>/dev/null)"
    blkall+=("$b")
  done <<EOF
$raw
EOF

  # 3. split blockers into in-set (gate the wave layering) vs external-open (issue can't start yet).
  local -a inset=() ext=()
  local i j bb keepin keepext present
  for i in "${!nums[@]}"; do
    keepin=""; keepext=""
    for bb in ${blkall[$i]//,/ }; do
      present=0
      for j in "${!nums[@]}"; do [ "${nums[$j]}" = "$bb" ] && present=1; done
      if [ "$present" = "1" ]; then keepin="$keepin,$bb"; else keepext="$keepext,$bb"; fi
    done
    inset+=("${keepin#,}"); ext+=("${keepext#,}")
  done

  # 4. layer into waves (in-set deps only).
  local wavetsv waves
  wavetsv="$(for i in "${!nums[@]}"; do printf '%s\t%s\n' "${nums[$i]}" "${inset[$i]}"; done | pm_waves)"
  # map number -> wave (linear; N small)
  _wave_of() { printf '%s' "$wavetsv" | awk -F'\t' -v k="$1" '$1==k{print $2; exit}'; }
  waves="$(printf '%s' "$wavetsv" | awk -F'\t' '{print $2}' | sort -n | uniq)"

  # 5. within each wave, pack into batches (ctx budget + file overlap), then emit.
  emit_rows() { # writes "wave<TAB>batch<TAB>number<TAB>ctx<TAB>blockers<TAB>title"
    local wv batchtsv num bt
    for wv in $waves; do
      # gather this wave's issues as "num<TAB>ctx<TAB>files" in array order
      batchtsv="$(for i in "${!nums[@]}"; do
        [ "$(_wave_of "${nums[$i]}")" = "$wv" ] || continue
        printf '%s\t%s\t%s\n' "${nums[$i]}" "${ctxs[$i]}" "${files[$i]}"
      done | pm_batches "$budget")"
      while IFS="$(printf '\t')" read -r num bt; do
        [ -n "$num" ] || continue
        for i in "${!nums[@]}"; do
          if [ "${nums[$i]}" = "$num" ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$wv" "$bt" "$num" "${ctxs[$i]}" "${inset[$i]}" "${titles[$i]}"
          fi
        done
      done <<EOF2
$batchtsv
EOF2
    done
  }

  # raw rows (wave<TAB>batch<TAB>number<TAB>ctx<TAB>blockers<TAB>title) — the copilot driver (#78)
  # consumes this; not a public output mode.
  if [ "$out" = "tsv" ]; then emit_rows; return 0; fi

  if [ "$out" = "json" ]; then
    # TOON-encode a uniform row array (wave,batch,number,ctx,blockers,title) for the copilot.
    local json
    json="$(emit_rows | jq -R -s '
      [ split("\n")[] | select(length>0) | split("\t")
        | {wave:(.[0]|tonumber), batch:(.[1]|tonumber), number:(.[2]|tonumber),
           ctx:.[3], blockers:.[4], title:.[5]} ]')"
    # route through the TOON encoder (uniform array -> tabular; falls back to JSON under the gate).
    local here; here="$(dirname "${BASH_SOURCE[0]}")"
    # shellcheck source=/dev/null
    . "$here/toon.sh"
    printf '%s' "$json" | toon_encode
    return 0
  fi

  # human render (rich rendering polish lands in #82; this is the clean default).
  # Render with awk -F'\t': unlike `read` with a whitespace IFS, awk never collapses the empty
  # blockers field, so the columns stay aligned when an issue has no blockers.
  printf '\n  cckit plan — %s  (session budget %s · ctx S=1 M=2 L=4 XL=8)\n' "$repo" "$budget"
  emit_rows | awk -F'\t' '
    BEGIN { lw=""; lb="" }
    {
      wv=$1; bt=$2; num=$3; ctx=$4; blk=$5; title=$6
      if (wv != lw) { printf "\n  Wave %s — runs in parallel:\n", wv; lw=wv; lb="" }
      if (bt != lb) { printf "    batch %s:\n", bt; lb=bt }
      sub(/^\[Effort( [0-9]+)?\] [0-9]+ · ?/, "", title)
      sub(/^\[[A-Za-z]+\] /, "", title)
      dep=""
      if (blk != "") { gsub(/,/, ", #", blk); dep="   (after #" blk ")" }
      printf "      #%-4s [%-2s] %s%s\n", num, ctx, title, dep
    }'
  # externally-blocked issues never enter a wave — surface them so they aren't silently dropped.
  local anyext=0
  for i in "${!nums[@]}"; do [ -n "${ext[$i]}" ] && anyext=1; done
  if [ "$anyext" = "1" ]; then
    printf '\n  Blocked by open issues outside this set (not scheduled):\n'
    for i in "${!nums[@]}"; do
      [ -n "${ext[$i]}" ] && printf '      #%-4s waits on #%s\n' "${nums[$i]}" "${ext[$i]//,/, #}"
    done
  fi
  printf '\n'
}
