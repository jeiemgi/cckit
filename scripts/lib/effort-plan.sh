#!/usr/bin/env bash
# effort-plan.sh — the session-fit view (`kit effort plan` when the project ships the kit CLI).
#
# Reads the open efforts — from GitHub (label:effort), or from the local executable named by
# `effort.planSource` when one is configured (falling back to GitHub when it fails or prints
# nothing; the output names the source used) — groups them by their `flow:` tag, orders each flow by the
# native `blocked_by` edges, and packs the efforts into session-sized batches under a context budget.
# Answers "which efforts fit in one session before the context window fills, and in what order?".
#
# ctx weights: S=1 · M=2 · L=4 · XL=8. The budget (KIT_SESSION_BUDGET, default 4) is how much one
# session holds. L/XL efforts are flagged "→ delegate subs" — delegating an effort's sub-issues to
# sub-agents in their own worktrees keeps the MAIN session light (a sub-agent's file reading happens
# in its own context; only a summary returns), which is the real lever that widens a session
# (rules/agent-execution-routing.md).
#
# Requires: gh, jq for the GitHub read; a local source that answers needs neither. bash 3.2 (no associative arrays — parallel indexed arrays + linear scan; N small).
# errors: strict — refuses to plan from GitHub without gh + jq

EFFORT_REPO="${EFFORT_REPO:-${KIT_REPO:-}}"

_ep_weight() { case "$1" in S) echo 1 ;; M) echo 2 ;; L) echo 4 ;; XL) echo 8 ;; *) echo 2 ;; esac; }

# Rows travel between the readers and the planner as five fields joined by the ASCII unit
# separator: number, flow, ctx, title, blockers (comma-separated issue numbers). Not TAB — TAB is
# IFS whitespace, so `read` collapses two adjacent tabs and an empty column shifts every later one.
_EP_SEP=$'\037'

# _ep_rows_github <repo> — the open efforts from GitHub: one listing, then one blocked_by call per
# effort (small N). rc 1 when the listing fails; prints nothing when there are no open efforts.
_ep_rows_github() {
  local repo="$1" raw n f c t
  raw="$(gh issue list --repo "$repo" --label effort --state open --limit 100 \
    --json number,title,labels \
    --jq '.[] | [ (.number|tostring),
                  ([.labels[].name|select(startswith("flow:"))|ltrimstr("flow:")]|first // "—"),
                  ([.labels[].name|select(startswith("ctx:"))|ltrimstr("ctx:")]|first // "?"),
                  .title ] | @tsv' 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 0
  while IFS=$'\t' read -r n f c t; do
    [[ -n "$n" ]] || continue
    printf '%s\037%s\037%s\037%s\037%s\n' "$n" "$f" "$c" "$t" \
      "$(gh api "repos/$repo/issues/$n/dependencies/blocked_by" --jq '[.[].number]|join(",")' 2>/dev/null)"
  done <<< "$raw"
}

# _ep_project_root — the directory a relative `effort.planSource` resolves against: the project
# root the config file belongs to (config-path.sh), else the current directory.
_ep_project_root() {
  local cfg=""
  command -v kit_config_path >/dev/null 2>&1 && cfg="$(kit_config_path 2>/dev/null || true)"
  [[ -n "$cfg" && -f "$cfg" ]] || { pwd; return 0; }
  case "$cfg" in
    */.claude/kit.config.json) (cd "$(dirname "$cfg")/.." 2>/dev/null && pwd) || pwd ;;
    *)                         (cd "$(dirname "$cfg")" 2>/dev/null && pwd) || pwd ;;
  esac
}

# _ep_source_rows — normalize a plan source's stdout (stdin here) to the internal row format.
# The source contract (effort.planSource):
#   number<TAB>flow<TAB>ctx<TAB>title[<TAB>blockers]   one line per open effort
#   # age: <text>                                       optional, anywhere; how old the snapshot is
# `blockers` is a comma-separated list of issue numbers (a leading # is accepted). Lines that start
# with # are metadata, and a line whose first column is not a number is ignored. An empty flow
# becomes "—" and an empty ctx "?", the same defaults the GitHub reader uses.
_ep_source_rows() {
  awk -F'\t' -v sep="$_EP_SEP" '
    /^#/ { next }
    $1 ~ /^[0-9]+$/ {
      f = ($2 == "" ? "—" : $2); c = ($3 == "" ? "?" : $3); b = $5; gsub(/[^0-9,]/, "", b)
      printf "%s%s%s%s%s%s%s%s%s\n", $1, sep, f, sep, c, sep, $4, sep, b
    }'
}

effort_plan() {
  local repo="$EFFORT_REPO" budget="${KIT_SESSION_BUDGET:-4}"
  [[ -n "$repo" ]] || { echo "effort plan: no repo (set KIT_REPO / EFFORT_REPO)" >&2; return 1; }

  # 1. rows. A configured local source (effort.planSource, or EFFORT_PLAN_SOURCE per invocation)
  #    is tried first; if it is not executable, exits non-zero or prints no rows, the plan falls
  #    back to GitHub and says so. `srcline` is printed under the header either way — a plan that
  #    does not say what it was built from can be stale without anyone noticing.
  local rows="" srcline="" fellback=""
  local src="${EFFORT_PLAN_SOURCE:-${KIT_EFFORT_PLAN_SOURCE:-}}"
  if [[ -n "$src" ]]; then
    local root srcpath srcout src_rc=0 age
    root="$(_ep_project_root)"
    case "$src" in /*) srcpath="$src" ;; *) srcpath="$root/$src" ;; esac
    if [[ ! -x "$srcpath" || -d "$srcpath" ]]; then
      fellback="planSource $src is not executable"
    else
      srcout="$(cd "$root" 2>/dev/null && "$srcpath" "$repo")" || src_rc=$?
      if [[ "$src_rc" -ne 0 ]]; then
        fellback="planSource $src failed (exit $src_rc)"
      else
        rows="$(printf '%s\n' "$srcout" | _ep_source_rows)"
        if [[ -z "$rows" ]]; then
          fellback="planSource $src printed no rows"
        else
          age="$(printf '%s\n' "$srcout" | sed -n 's/^#[[:space:]]*age:[[:space:]]*//p' | head -1)"
          srcline="planSource $src"
          [[ -n "$age" ]] && srcline="$srcline · age $age"
        fi
      fi
    fi
    [[ -n "$fellback" ]] && echo "effort plan: $fellback — falling back to GitHub" >&2
  fi
  if [[ -z "$srcline" ]]; then
    command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "effort plan: needs gh + jq" >&2; return 1; }
    srcline="GitHub ($repo)"
    [[ -n "$fellback" ]] && srcline="$srcline — $fellback, fell back"
    rows="$(_ep_rows_github "$repo")" \
      || { echo "effort plan: gh query failed (check gh auth)" >&2; return 1; }
    [[ -n "$rows" ]] || { echo "effort plan: no open efforts found (source: $srcline)" >&2; return 0; }
  fi

  # 2. read into parallel arrays.
  local -a nums=() flows=() ctxs=() titles=() blocks=()
  local n f c t bl
  while IFS="$_EP_SEP" read -r n f c t bl; do
    [[ -n "$n" ]] || continue
    nums+=("$n"); flows+=("$f"); ctxs+=("$c"); titles+=("$t"); blocks+=("$bl")
  done <<< "$rows"

  # 3. distinct flows, first-seen order.
  local -a flowlist=()
  for f in "${flows[@]}"; do
    case " ${flowlist[*]-} " in *" $f "*) ;; *) flowlist+=("$f") ;; esac
  done

  printf '\n  kit effort plan — session budget %s  (ctx S=1 M=2 L=4 XL=8 · L/XL → delegate subs)\n' "$budget"
  printf '  source: %s\n' "$srcline"

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
