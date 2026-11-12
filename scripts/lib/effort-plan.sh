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
# `effort_plan` itself is bash-only; effort_open_rows / effort_next_pick / effort_next_rows hold no
# arrays and run under zsh too, because `cckit status` reads them (scripts/lib/kit-status.sh).
# errors: strict — refuses to plan without gh + jq

EFFORT_REPO="${EFFORT_REPO:-${KIT_REPO:-}}"

_ep_weight() { case "$1" in S) echo 1 ;; M) echo 2 ;; L) echo 4 ;; XL) echo 8 ;; *) echo 2 ;; esac; }

# effort_open_rows [repo] — one TSV row per OPEN effort (label:effort), the single read both
# `effort_plan` and `cckit status` build on:
#
#   number<TAB>flow<TAB>ctx<TAB>priority<TAB>blockers<TAB>open-blockers<TAB>title
#
# `blockers` is every native `blocked_by` number, `open-blockers` only the ones whose issue is still
# OPEN; each is a csv, or `-` when empty (a tab-separated `read` collapses an empty field, so no
# column is ever left blank). flow falls back to `—`, ctx to `?`, priority to `-`.
# rc 1 when gh/jq are absent, no repo is known, or the issue query fails — "could not read" must not
# look like "no efforts". No open effort is rc 0 with no rows. A blocked_by read that fails for one
# effort degrades to `-` for that effort (the dependency API is optional on older GitHub hosts).
# Costs one `gh issue list` plus one `gh api` per open effort.
effort_open_rows() {
  local repo="${1:-${EFFORT_REPO:-${KIT_REPO:-}}}" raw n f c p t b tab
  tab="$(printf '\t')"
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  [ -n "$repo" ] || return 1
  raw="$(gh issue list --repo "$repo" --label effort --state open --limit 100 --json number,title,labels 2>/dev/null)" || return 1
  raw="$(printf '%s' "$raw" | jq -r '.[] | [ (.number|tostring),
                  ([.labels[].name|select(startswith("flow:"))|ltrimstr("flow:")]|first // "—"),
                  ([.labels[].name|select(startswith("ctx:"))|ltrimstr("ctx:")]|first // "?"),
                  ([.labels[].name|select(startswith("priority:"))|ltrimstr("priority:")]|first // "-"),
                  .title ] | @tsv' 2>/dev/null)" || return 1
  [ -n "$raw" ] || return 0
  while IFS="$tab" read -r n f c p t; do
    [ -n "$n" ] || continue
    b="$(gh api "repos/$repo/issues/$n/dependencies/blocked_by" 2>/dev/null \
      | jq -r '[ ([.[].number|tostring]|join(",")),
                 ([.[]|select((.state // "open")|ascii_downcase == "open")|.number|tostring]|join(",")) ]
               | map(if . == "" then "-" else . end) | @tsv' 2>/dev/null)"
    [ -n "$b" ] || b="-$tab-"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$f" "$c" "$p" "$b" "$t"
  done <<EOT
$raw
EOT
}

# effort_next_pick — pure. stdin: `effort_open_rows` rows; stdout: ONE row per flow, sorted by flow:
#
#   flow<TAB>number<TAB>ctx<TAB>title<TAB>waiting
#
# `number` is the next effort that can start: among the flow's efforts with NO open blocker, the
# most urgent `priority:pN` (p0 → p3, unlabeled last), then the lowest issue number. `waiting` counts
# the flow's efforts that still have an open blocker. A flow where every effort is blocked keeps its
# row with `-` for number/ctx/title, so a stuck flow is visible instead of silently absent.
#
# What blocks: ANY open blocker — an effort in the same flow, an effort in another flow, or a plain
# issue. A closed blocker does not. (`effort_plan` orders a flow by its in-flow blockers only; that
# is a layout question. "Can this start now" is stricter: the work it waits on is not done.)
# The title drops the `[Effort] N · ` prefix and a leading `[Flow] ` tag, as `effort_plan` does.
effort_next_pick() {
  awk -F'\t' '
    function rank(p) { return (p ~ /^p[0-3]$/) ? substr(p, 2) + 0 : 9 }
    NF >= 7 {
      f = $2; seen[f] = 1
      if ($6 != "-") { waiting[f]++; next }
      r = rank($4); n = $1 + 0
      if (!(f in bn) || r < br[f] || (r == br[f] && n < bn[f])) {
        t = $7; sub(/^\[Effort( [0-9]+)?\] [0-9]+ · ?/, "", t); sub(/^\[[A-Za-z]+\] /, "", t)
        bn[f] = n; br[f] = r; bc[f] = $3; bt[f] = t
      }
    }
    END {
      for (f in seen) {
        if (f in bn) printf "%s\t%s\t%s\t%s\t%d\n", f, bn[f], bc[f], bt[f], waiting[f] + 0
        else         printf "%s\t-\t-\t-\t%d\n", f, waiting[f] + 0
      }
    }' | LC_ALL=C sort -t "$(printf '\t')" -k1,1
}

# effort_next_rows [repo] — the next startable effort per flow, from live state. rc 1 when the
# efforts could not be read (see effort_open_rows); no rows + rc 0 when no open effort exists.
effort_next_rows() {
  local rows
  rows="$(effort_open_rows "${1:-}")" || return 1
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | effort_next_pick
}

# effort_cadence_md — the weekly cadence as ONE markdown line. `cckit next` and `cckit status` both
# print this function's output, so the two verbs cannot drift apart on what the cadence is.
# Every verb named here runs as written. `cckit digest` is deliberately absent: it summarises one
# <path|url> with a local model, it does not report on the week.
effort_cadence_md() {
  printf '%s\n' '**Weekly cadence** — Monday: `cckit plan` orders the week · daily: `cckit next` picks up one issue · Friday: `cckit gc` reports what can be pruned.'
}

effort_plan() {
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "effort plan: needs gh + jq" >&2; return 1; }
  local repo="$EFFORT_REPO" budget="${KIT_SESSION_BUDGET:-4}"
  [[ -n "$repo" ]] || { echo "effort plan: no repo (set KIT_REPO / EFFORT_REPO)" >&2; return 1; }

  # 1. open efforts + their flow:/ctx: labels and blocked_by numbers (effort_open_rows).
  local raw
  raw="$(effort_open_rows "$repo")" \
    || { echo "effort plan: gh query failed (check gh auth)" >&2; return 1; }
  [[ -n "$raw" ]] || { echo "effort plan: no open efforts found" >&2; return 0; }

  # 2. read into parallel arrays (small N). `-` is the empty-blockers placeholder.
  local -a nums=() flows=() ctxs=() titles=() blocks=()
  local n f c p b ob t
  while IFS=$'\t' read -r n f c p b ob t; do
    [[ -n "$n" ]] || continue
    [[ "$b" == "-" ]] && b=""
    nums+=("$n"); flows+=("$f"); ctxs+=("$c"); titles+=("$t"); blocks+=("$b")
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
