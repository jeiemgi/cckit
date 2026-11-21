#!/usr/bin/env bash
# shellcheck shell=bash
# board-view.sh — pure helpers for the read-only board view (`cckit sync`). Each takes JSON and
# emits markdown/text, or JSON for the two `_data` forms; none call gh, so they are unit-testable with canned fixtures (#122).
# Ported from the host project's board view: a merge-ordered open-PR queue, a stale-issue flag, a
# not-on-board flag, and Project Status per issue. bash 3.2 + zsh safe. Requires jq.
# errors: pure — JSON in, text or JSON out; no gh, no network

# board_merge_queue_data <prs-json> — the open-PR merge queue as a JSON array, in merge order.
# <prs-json> is `gh pr list --json number,title,labels,isDraft,headRefName,reviewDecision,mergeable`
# output. Ordering answers "in what order do I merge?": ready(1) -> draft(2) -> blocked(3); within a
# tier, risk:low first, then smaller size, then issue number. Risk/size come from risk:/size: labels
# (size is "" when unlabeled); a `blocked` label marks blocked. An agent branch (agent|claude|auto/*)
# or an agent:auto label sets `agent`, so a human checks the row before starting overlapping work.
# `state` is one of blocked | draft | conflict | ready | needs-review. This is the ONE place the
# order is computed: board_merge_queue renders these rows, and `cckit sync --json` emits them.
board_merge_queue_data() {
  printf '%s' "${1:-[]}" | jq -c '
    def lbl($p): (($p.labels // []) | map(.name));
    def risk($l): ($l | map(select(startswith("risk:"))) | first // "risk:med" | ltrimstr("risk:"));
    def size($l): ($l | map(select(startswith("size:"))) | first // "" | ltrimstr("size:"));
    def riskRank($r): if $r=="low" then 0 elif $r=="med" then 1 else 2 end;
    def sizeRank($s): ({"XS":0,"S":1,"M":2,"L":3,"XL":4}[$s] // 2);
    map( . as $p | lbl($p) as $l
      | (risk($l)) as $risk | (size($l)) as $size
      | (any($l[]; . == "blocked")) as $blocked
      | (((($p.headRefName // "") | test("^(agent|claude|auto)/")) or (any($l[]; . == "agent:auto")))) as $agent
      | (if $blocked then 3 elif ($p.isDraft // false) then 2 else 1 end) as $ready
      | { number:$p.number, title:$p.title, risk:$risk, size:$size,
          blocked:$blocked, draft:($p.isDraft // false), agent:$agent,
          conflict:($p.mergeable == "CONFLICTING"), approved:($p.reviewDecision == "APPROVED"),
          ready:$ready, rr:riskRank($risk), sr:sizeRank($size) } )
    | sort_by(.ready, .rr, .sr, .number)
    | map( . + { state: (if .blocked then "blocked" elif .draft then "draft"
                         elif .conflict then "conflict" elif .approved then "ready"
                         else "needs-review" end) }
           | del(.ready, .rr, .sr) )'
}

# board_merge_queue <prs-json> — render board_merge_queue_data as a markdown table (same input).
board_merge_queue() {
  local prs="${1:-[]}" rows tab; tab="$(printf '\t')"
  rows="$(board_merge_queue_data "$prs" | jq -r '
    .[]
    | [ ("#" + (.number|tostring)), .risk, (if .size=="" then "—" else .size end),
        ({"blocked":"▪ blocked","draft":"· draft","conflict":"◆ conflict","ready":"● ready"}[.state]
         // "· needs review"),
        (if .agent then "● agent" else "·" end),
        (if (.title|length) > 48 then (.title[0:48] + "…") else .title end) ] | @tsv')"
  printf '### Merge Queue (open PRs — merge top-down)\n'
  printf '| PR | Risk | Size | State | Who | Title |\n|---|---|---|---|---|---|\n'
  if [ -z "$rows" ]; then
    printf '| — | | | no open PRs ✓ | | |\n'
  else
    while IFS="$tab" read -r pr risk size state who title; do
      [ -z "$pr" ] && continue
      printf '| %s | %s | %s | %s | %s | %s |\n' "$pr" "$risk" "$size" "$state" "$who" "$title"
    done <<EOF
$rows
EOF
  fi
  printf '\n_Order: ready → draft → blocked; within that, risk:low first, then smaller size. ● agent = a bot branch — check it before starting overlapping work._\n'
}

# board_stale_data <issues-json> [days] — JSON array [{number, days}] of open issues untouched for
# more than [days] (default 14), most-stale first; [] when none. <issues-json> is
# `gh issue list --json number,updatedAt`. The data form of the stale flag (`cckit sync --json`).
board_stale_data() {
  local issues="${1:-[]}" days="${2:-14}" now
  now="$(date -u +%s 2>/dev/null || echo 0)"
  printf '%s' "$issues" | jq -c --argjson now "$now" --argjson d "$days" '
    [ .[]
      | (($now - ((.updatedAt // "1970-01-01T00:00:00Z") | fromdateiso8601)) / 86400 | floor) as $age
      | select($age > $d) | {number:.number, days:$age} ]
    | sort_by(-.days)'
}

# board_stale_list <issues-json> [days] — board_stale_data as space-joined "#N(Dd)" tokens. Empty
# when none; the caller renders the "none ✓" fallback.
board_stale_list() {
  board_stale_data "${1:-[]}" "${2:-14}" | jq -r 'map("#\(.number)(\(.days)d)") | join(" ")'
}

# board_not_on_board <issues-json> <status-map-json> — space-joined "#N" for open issues that have
# NO Project Status (absent from the board map), so an adopter sees which issues never got added to
# the board. <status-map-json> is {"<number>":"<status>", …}. Empty when all issues are on the board.
board_not_on_board() {
  local issues="${1:-[]}" map="${2:-{\}}"
  printf '%s' "$issues" | jq -r --argjson m "$map" '
    [ .[] | select(($m[(.number|tostring)] // null) == null) | "#\(.number)" ] | join(" ")'
}

# board_status_for <number> <status-map-json> — echo the issue's Project Status, or "—" when the
# issue is not on the board (or the board is off). Used to annotate each issue row with its Status.
board_status_for() {
  printf '%s' "${2:-{\}}" | jq -r --arg n "$1" '.[$n] // "—"'
}
