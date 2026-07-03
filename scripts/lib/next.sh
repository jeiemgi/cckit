#!/usr/bin/env bash
# next.sh — "what can I pick up right now?" The everyday-dev helper (Effort 75 · #79).
#
# Surfaces the unblocked set (wave 0 of the plan machine) and the single recommended next issue with
# the one command to start it. This is the daily-loop counterpart to `cckit wave`: wave fans a whole
# wave out to subagents; `cckit next` is for a human (or agent) picking up one issue by hand.
#
#   cckit next                  the unblocked issues + the top one's start command
#   cckit next --effort <N>     scope to effort #N's sub-issues
#   cckit next --llm            the unblocked set as TOON rows {number,ctx,title}
#
# Requires gh + jq (via the plan machine). bash 3.2 / zsh compatible.

NEXT_REPO="${NEXT_REPO:-${KIT_REPO:-}}"

next_issue() {
  command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || { echo "next: needs gh + jq" >&2; return 1; }
  local repo="$NEXT_REPO" out="${CCKIT_OUTPUT:-human}" effort="" planargs=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --llm|--output=json) out="json"; shift ;;
      --effort)    effort="$2"; planargs+=(--effort "$2"); shift 2 ;;
      --effort=*)  effort="${1#*=}"; planargs+=(--effort "${1#*=}"); shift ;;
      -h|--help)   sed -n '10,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      *) echo "next: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$repo" ] || { echo "next: no repo (set KIT_REPO / NEXT_REPO)" >&2; return 1; }

  local here; here="$(dirname "${BASH_SOURCE[0]}")"
  # shellcheck source=/dev/null
  . "$here/plan-machine.sh"
  local rows wave0
  rows="$(CCKIT_OUTPUT=tsv plan_machine "${planargs[@]+"${planargs[@]}"}" 2>/dev/null)"
  wave0="$(printf '%s\n' "$rows" | awk -F'\t' '$1==0')"
  if [ -z "$wave0" ]; then
    [ "$out" = "json" ] && echo "[]" || echo "next: nothing unblocked — the board is blocked or empty."
    return 0
  fi

  if [ "$out" = "json" ]; then
    local json
    json="$(printf '%s\n' "$wave0" | awk -F'\t' '{
        t=$6; sub(/^\[Effort( [0-9]+)?\] [0-9]+ · ?/,"",t); sub(/^\[[A-Za-z]+\] /,"",t)
        print $3"\t"$4"\t"t
      }' \
      | jq -R -s '[ split("\n")[] | select(length>0) | split("\t")
                    | {number:(.[0]|tonumber), ctx:.[1], title:.[2]} ]')"
    # shellcheck source=/dev/null
    . "$here/toon.sh"
    printf '%s' "$json" | toon_encode
    return 0
  fi

  # human: the unblocked table + the top issue's start command, through the rendering seam.
  # shellcheck source=/dev/null
  . "$here/render.sh"
  local top topnum toptitle
  top="$(printf '%s\n' "$wave0" | head -1)"
  topnum="$(printf '%s' "$top" | cut -f3)"
  toptitle="$(printf '%s' "$top" | cut -f6 | sed -E 's/^\[Effort( [0-9]+)?\] [0-9]+ · ?//; s/^\[[A-Za-z]+\] //')"
  {
    printf '# Next up — %s%s\n\n' "$repo" "$([ -n "$effort" ] && echo " · effort #$effort")"
    printf '## Unblocked now\n\n'
    printf '| # | ctx | issue |\n|---|-----|-------|\n'
    printf '%s\n' "$wave0" | awk -F'\t' '{
      t=$6; sub(/^\[Effort( [0-9]+)?\] [0-9]+ · ?/,"",t); sub(/^\[[A-Za-z]+\] /,"",t)
      printf "| #%s | %s | %s |\n", $3, $4, t
    }'
    printf '\n## Pick up #%s — %s\n\n' "$topnum" "$toptitle"
    printf 'Start it in an isolated worktree + branch:\n\n'
    printf '```\ncckit start %s\n```\n\n' "$topnum"
    printf 'Or fan the whole unblocked wave out to subagents with `cckit wave%s`.\n' "$([ -n "$effort" ] && echo " --effort $effort")"
  } | cckit_render
}
