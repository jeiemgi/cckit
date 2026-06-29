#!/usr/bin/env bash
# effort-plan.sh — the session-fit view (`kit effort plan` when the project ships the kit CLI).
#
# Reads the open efforts (label:effort), groups them by their `flow:` tag, orders each flow by the
# native `blocked_by` edges, and packs the efforts into session-sized batches under a context budget.
# Answers "which efforts fit in one session before the context window fills, and in what order?".
#
# ctx weights: S=1 · M=2 · L=4 · XL=8. The budget (KIT_SESSION_BUDGET, default 4) is how much one
# session holds. L/XL efforts are flagged "→ delegate subs" — delegating an effort's sub-issues to
# sub-agents in their own worktrees keeps the MAIN session light (a sub-agent's file reading happens
# in its own context; only a summary returns), which is the real lever that widens a session
# (rules/agent-execution-routing.md).
#
# Requires: gh, jq. bash 3.2 (no associative arrays — parallel indexed arrays + linear scan; N small).

EFFORT_REPO="${EFFORT_REPO:-${KIT_REPO:-}}"

_ep_weight() { case "$1" in S) echo 1 ;; M) echo 2 ;; L) echo 4 ;; XL) echo 8 ;; *) echo 2 ;; esac; }

effort_plan() {
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "effort plan: needs gh + jq" >&2; return 1; }
  local repo="$EFFORT_REPO" budget="${KIT_SESSION_BUDGET:-4}"
  [[ -n "$repo" ]] || { echo "effort plan: no repo (set KIT_REPO / EFFORT_REPO)" >&2; return 1; }

  # 1. open efforts + their flow:/ctx: labels (one query).
  local raw
  raw="$(gh issue list --repo "$repo" --label effort --state open --limit 100 \
    --json number,title,labels \
    --jq '.[] | [ (.number|tostring),
                  ([.labels[].name|select(startswith("flow:"))|ltrimstr("flow:")]|first // "—"),
                  ([.labels[].name|select(startswith("ctx:"))|ltrimstr("ctx:")]|first // "?"),
                  .title ] | @tsv' 2>/dev/null)" \
    || { echo "effort plan: gh query failed (check gh auth)" >&2; return 1; }
  [[ -n "$raw" ]] || { echo "effort plan: no open efforts found" >&2; return 0; }

  # 2. read into parallel arrays + fetch blocked_by per effort (small N).
  local -a nums=() flows=() ctxs=() titles=() blocks=()
  local n f c t
  while IFS=$'\t' read -r n f c t; do
    [[ -n "$n" ]] || continue
    nums+=("$n"); flows+=("$f"); ctxs+=("$c"); titles+=("$t")
    blocks+=("$(gh api "repos/$repo/issues/$n/dependencies/blocked_by" --jq '[.[].number]|join(",")' 2>/dev/null)")
  done <<< "$raw"

  # 3. distinct flows, first-seen order.
  local -a flowlist=()
  for f in "${flows[@]}"; do
    case " ${flowlist[*]-} " in *" $f "*) ;; *) flowlist+=("$f") ;; esac
  done

  printf '\n  kit effort plan — session budget %s  (ctx S=1 M=2 L=4 XL=8 · L/XL → delegate subs)\n' "$budget"

  local i j b
  for f in "${flowlist[@]}"; do
    printf '\n  Flow: %s\n' "$f"

    # indices in this flow
    local -a idxs=()
    for i in "${!nums[@]}"; do [[ "${flows[$i]}" == "$f" ]] && idxs+=("$i"); done

    # 4. order: Kahn-lite — emit an effort once all its in-flow blockers are placed (roots first).
    local -a order=()
    local placed=" " progress=1
    while [[ "${#order[@]}" -lt "${#idxs[@]}" && "$progress" -eq 1 ]]; do
      progress=0
      for i in "${idxs[@]}"; do
        case "$placed" in *" $i "*) continue ;; esac
        local ready=1
        for b in ${blocks[$i]//,/ }; do
          for j in "${idxs[@]}"; do
            if [[ "${nums[$j]}" == "$b" ]]; then
              case "$placed" in *" $j "*) ;; *) ready=0 ;; esac
            fi
          done
        done
        if [[ "$ready" -eq 1 ]]; then order+=("$i"); placed="$placed$i "; progress=1; fi
      done
    done
    # cycle / leftover safety: append anything not yet placed.
    for i in "${idxs[@]}"; do case "$placed" in *" $i "*) ;; *) order+=("$i"); placed="$placed$i " ;; esac; done

    # 5. greedy-pack into sessions: new session when budget would overflow OR the next effort is
    #    blocked by one already in the current batch (a blocker and its dependent can't share a session).
    local sess=1 load=0 batch=" "
    printf '    Session %s:\n' "$sess"
    for i in "${order[@]}"; do
      local w; w="$(_ep_weight "${ctxs[$i]}")"
      local neednew=0
      (( load + w > budget )) && neednew=1
      for b in ${blocks[$i]//,/ }; do case "$batch" in *" $b "*) neednew=1 ;; esac; done
      if [[ "$neednew" -eq 1 && "$load" -gt 0 ]]; then
        sess=$((sess + 1)); load=0; batch=" "
        printf '    Session %s:\n' "$sess"
      fi
      load=$((load + w)); batch="$batch${nums[$i]} "
      local note=""; case "${ctxs[$i]}" in L|XL) note="   → delegate subs" ;; esac
      local dep=""; [[ -n "${blocks[$i]}" ]] && dep="   (after #${blocks[$i]//,/, #})"
      # strip the "[Effort] N · " prefix + a leading "[Flow] " tag — #N and the flow are already shown.
      local disp; disp="$(printf '%s' "${titles[$i]}" | sed -E 's/^\[Effort( [0-9]+)?\] [0-9]+ · ?//; s/^\[[A-Za-z]+\] //')"
      printf '      #%-4s [%-2s] %s%s%s\n' "${nums[$i]}" "${ctxs[$i]}" "$disp" "$dep" "$note"
    done
  done
  printf '\n'
}
