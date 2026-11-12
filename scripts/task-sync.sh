#!/usr/bin/env bash
# Read-only board status, grouped by role. Pure gh + jq. bash 3.2 compatible.
# Reads repo from .claude/kit.config.json. Run from project root.
#   ./scripts/task-sync.sh [--role <Name>] [--milestone <label>] [--plan]
#   --raw-json: original issue objects for shell consumers; --llm stays TOON-first.
# The dashboard layer (#383) — one cached JSON document a TUI or statusline polls:
#   --json            one JSON summary: per role, merge queue, stale flags (schema below)
#   --write           write that document atomically to <git-common-dir>/kit-sync-cache.json;
#                     a failed or partial fetch never touches the file
#   --cached [TTL]    print the cache when it is younger than TTL seconds (default 60) — no gh
#                     call — otherwise refresh it, write it, print it
#   --watch [SECS]    refresh + write every SECS seconds (default 30); a failed refresh keeps the
#                     last good cache. KIT_SYNC_WATCH_MAX=<n> stops after n refreshes
#   --plan            inline `effort plan` (a "### Effort plan" section; `plan` in the document)
# Every fetch emits op.start / op.done (op "sync") on the kit-events.jsonl bus.
# --json document: { schema, repo, generatedAt, generatedEpoch, open,
#   roles:[{role, slug, issues:[{number,title,status,priority,milestone,blocked}]}],
#   unassigned:[same rows — issues carrying none of the configured role: labels; [] under --role],
#   blocked:[n], notOnBoard:[n]|null (null = no Projects v2 board), stale:{days, issues:[{number,days}]},
#   mergeQueue:[{number,title,risk,size,state,blocked,draft,agent,conflict,approved}], plan? }
set -euo pipefail
source "$(dirname "$0")/lib/kit-config.sh" && load_kit_config
# Pure board-view helpers (merge queue, stale flag, not-on-board flag, Project Status).
source "$(dirname "$0")/lib/board-view.sh"
# The rendering seam (#82): the human board is markdown, routed through cckit_render — rich via glow
# in a TTY, verbatim markdown otherwise (renders natively in Claude Code, pipe-safe).
source "$(dirname "$0")/lib/ui.sh" 2>/dev/null || true
source "$(dirname "$0")/lib/render.sh" 2>/dev/null || true
# The event bus is best-effort: a scaffold without the lib still syncs, it just emits nothing.
source "$(dirname "$0")/lib/kit-events.sh" 2>/dev/null || true
command -v emit_event >/dev/null 2>&1 || emit_event() { :; }

ROLE_FILTER=""; MS_FILTER=""
# OUT is what goes to stdout: human | json (TOON, the --llm form) | raw-json | doc (--json) | none.
OUT="${CCKIT_OUTPUT:-human}"; OUT_SET=0
case "$OUT" in json|raw-json) ;; *) OUT=human ;; esac
WRITE=0; PLAN=0; CACHED_TTL=""; WATCH_SECS=""
_is_int() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --role) ROLE_FILTER="$2"; shift 2 ;;
    --milestone) MS_FILTER="$2"; shift 2 ;;
    --llm|--output=json) OUT=json; OUT_SET=1; shift ;;
    --raw-json) OUT=raw-json; OUT_SET=1; shift ;;
    --json) OUT=doc; OUT_SET=1; shift ;;
    --write) WRITE=1; shift ;;
    --plan) PLAN=1; shift ;;
    --cached) CACHED_TTL=60; shift; if _is_int "${1:-}"; then CACHED_TTL="$1"; shift; fi ;;
    --watch)  WATCH_SECS=30; shift; if _is_int "${1:-}"; then WATCH_SECS="$1"; shift; fi ;;
    *) echo "unknown flag: $1" >&2; exit 1 ;;
  esac
done

# --cached / --watch both maintain the cache; --cached also prints the document.
if [ -n "$CACHED_TTL" ]; then WRITE=1; OUT=doc; fi
if [ -n "$WATCH_SECS" ]; then WRITE=1; [ "$OUT" = doc ] || OUT=none; fi
# A bare --write is a cache refresh, not a board print.
if [ "$WRITE" = 1 ] && [ "$OUT_SET" = 0 ] && [ "$OUT" = human ]; then OUT=none; fi
# The cache is ONE file every reader shares, so a filtered document must never land in it.
if [ "$WRITE" = 1 ] && [ -n "$ROLE_FILTER$MS_FILTER" ]; then
  echo "sync: --write / --cached / --watch cache the whole board — drop --role / --milestone" >&2
  exit 2
fi

# <git-common-dir>/kit-sync-cache.json — worktree-durable, the same home as kit-events.jsonl.
sync_cache_path() {
  local gcd
  gcd="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$gcd" in /*) : ;; *) gcd="$(cd "$gcd" 2>/dev/null && pwd)" || return 1 ;; esac
  printf '%s/kit-sync-cache.json\n' "$gcd"
}

ISSUES="[]"; STATUS_MAP="{}"; PRS_JSON="[]"; PLAN_TEXT=""; DOC=""

# sync_fetch <strict|lenient> — read the board into ISSUES / STATUS_MAP / PRS_JSON. Returns non-zero
# when the issue list cannot be read. `strict` is the data path (--json / --write): there an
# unreadable PR list or Project board fails the fetch too, because a document with an empty merge
# queue it could not read is a partial result. `lenient` is the human board: it degrades to an
# empty queue / "—" Status and still renders, as it always has.
sync_fetch() {
  local mode="${1:-lenient}" raw
  raw="$(gh issue list --repo "$KIT_REPO" --state open --limit 200 \
    --json number,title,labels,milestone,assignees,updatedAt,body)" || return 1
  # Only the data path validates: --raw-json hands gh's bytes to its caller verbatim, and the
  # caller (autopilot) owns the "invalid board data" diagnosis.
  if [ "$mode" = strict ]; then
    printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  fi
  ISSUES="$raw"
  # The two shell-consumer forms read the issue list and nothing else.
  case "$OUT" in raw-json|json) [ "$WRITE" = 1 ] || return 0 ;; esac

  # Project Status map {"<number>":"<status>"} — from the Projects v2 board when it is enabled, so
  # each issue row shows its board Status and we can flag issues that never got added
  # (no-board-entry). Config-guarded: with projectsV2 off the map stays {} and every row shows "—".
  STATUS_MAP="{}"
  if [ "${KIT_PROJECTS_V2:-false}" = "true" ] && [ -n "${KIT_PROJECT_NUMBER:-}" ] && [ -n "${KIT_OWNER:-}" ]; then
    local root map
    case "${KIT_PROJECT_OWNER_TYPE:-user}" in org|organization) root=organization ;; *) root=user ;; esac
    map="$(gh api graphql -f query="
      query(\$login:String!,\$number:Int!){
        $root(login:\$login){ projectV2(number:\$number){ items(first:200){ nodes{
          content{ ... on Issue { number } ... on PullRequest { number } }
          fieldValueByName(name:\"Status\"){ ... on ProjectV2ItemFieldSingleSelectValue { name } }
        }}}}}" -f login="$KIT_OWNER" -F number="$KIT_PROJECT_NUMBER" 2>/dev/null \
      | jq -c "[.data.${root}.projectV2.items.nodes[]
          | select(.content.number != null)
          | {key:(.content.number|tostring), value:(.fieldValueByName.name // \"—\")}]
        | from_entries" 2>/dev/null)" || map=""
    if [ -n "$map" ]; then STATUS_MAP="$map"; elif [ "$mode" = strict ]; then return 1; fi
  fi

  # Open PRs for the merge queue (fetched once; risk/size labels + draft/review state drive the order).
  if raw="$(gh pr list --repo "$KIT_REPO" --state open --limit 100 \
       --json number,title,labels,isDraft,headRefName,reviewDecision,mergeable 2>/dev/null)" \
     && printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    PRS_JSON="$raw"
  elif [ "$mode" = strict ]; then
    return 1
  else
    PRS_JSON="[]"
  fi
  return 0
}

# sync_plan — fill PLAN_TEXT with `effort plan` output. Non-zero when the plan cannot be produced.
sync_plan() {
  local lib; lib="$(dirname "$0")/lib/effort-plan.sh"
  [ -f "$lib" ] || { echo "sync: --plan needs scripts/lib/effort-plan.sh" >&2; return 1; }
  # shellcheck source=/dev/null
  source "$lib" || return 1
  PLAN_TEXT="$(effort_plan)" || return 1
}

# sync_doc — build the --json document into DOC from the fetched state. Non-zero on any jq failure,
# so a malformed input can never become a cached document.
sync_doc() {
  local roles mq stale
  roles="$(printf '%s\n' "${ROLE_FILTER:-$KIT_ROLES}" | jq -Rn '[inputs | select(length > 0)]')" || return 1
  mq="$(board_merge_queue_data "$PRS_JSON")" || return 1
  stale="$(board_stale_data "$ISSUES" 14)" || return 1
  [ -n "$mq" ] && [ -n "$stale" ] || return 1
  DOC="$(printf '%s' "$ISSUES" | jq -c \
      --arg repo "$KIT_REPO" --arg ms "$MS_FILTER" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson epoch "$(date -u +%s)" --argjson roles "$roles" --argjson st "$STATUS_MAP" \
      --argjson mq "$mq" --argjson stale "$stale" \
      --argjson board "$([ "${KIT_PROJECTS_V2:-false}" = "true" ] && echo true || echo false)" \
      --argjson filtered "$([ -n "$ROLE_FILTER" ] && echo true || echo false)" \
      --argjson withplan "$PLAN" --arg plan "$PLAN_TEXT" '
    . as $all
    | def row: { number, title,
        status: ($st[(.number|tostring)] // "—"),
        priority: ([.labels[].name | select(startswith("priority:")) | sub("priority:";"")][0] // ""),
        milestone: (.milestone.title // ""),
        blocked: ((.body // "") | test("Blocked by")) };
      { schema: 1, repo: $repo, generatedAt: $at, generatedEpoch: $epoch,
        open: ($all | length),
        roles: [ $roles[] as $r
          | ($r | ascii_downcase | gsub(" "; "-")) as $slug
          | { role: $r, slug: $slug,
              issues: [ $all[]
                | select(any(.labels[]; .name == ("role:" + $slug)))
                | select($ms == "" or (.milestone.title // "") == $ms)
                | row ] } ],
        unassigned: [ $all[]
          | select($filtered | not)
          | select(([.labels[].name] - ($roles | map("role:" + (ascii_downcase | gsub(" "; "-"))))) == [.labels[].name])
          | select($ms == "" or (.milestone.title // "") == $ms)
          | row ],
        blocked: [ $all[] | select((.body // "") | test("Blocked by")) | .number ],
        notOnBoard: (if $board
          then [ $all[] | select(($st[(.number|tostring)] // null) == null) | .number ]
          else null end),
        stale: { days: 14, issues: $stale },
        mergeQueue: $mq }
      + (if $withplan == 1 then { plan: $plan } else {} end)')" || return 1
  [ -n "$DOC" ]
}

# sync_write — put DOC in the cache atomically: write a sibling temp file, re-validate it as one
# JSON object, then rename over the cache. A reader sees the old document or the new one, never half.
sync_write() {
  local cache tmpf
  cache="$(sync_cache_path)" || { echo "sync: --write needs a git repository (no git-common-dir)" >&2; return 1; }
  tmpf="$cache.$$.tmp"
  printf '%s\n' "$DOC" > "$tmpf" 2>/dev/null || { rm -f "$tmpf"; return 1; }
  jq -e 'type == "object" and (.mergeQueue | type == "array")' "$tmpf" >/dev/null 2>&1 \
    || { rm -f "$tmpf"; return 1; }
  mv -f "$tmpf" "$cache" || { rm -f "$tmpf"; return 1; }
}

# sync_refresh — one full data refresh: fetch (strict), plan if asked, build DOC, write if asked.
# Emits op.start / op.done around it. Non-zero leaves the cache exactly as it was.
sync_refresh() {
  local ok=1
  emit_event op.start sync "{\"mode\":\"$OUT\",\"write\":$WRITE}"
  sync_fetch strict || ok=0
  if [ "$ok" = 1 ] && [ "$PLAN" = 1 ]; then sync_plan || ok=0; fi
  if [ "$ok" = 1 ]; then sync_doc || ok=0; fi
  if [ "$ok" = 1 ] && [ "$WRITE" = 1 ]; then sync_write || ok=0; fi
  if [ "$ok" = 1 ]; then
    emit_event op.done sync "{\"ok\":true,\"open\":$(printf '%s' "$ISSUES" | jq 'length' 2>/dev/null || echo 0)}"
    return 0
  fi
  emit_event op.done sync '{"ok":false}'
  return 1
}

# ── --watch: refresh in a loop; a failed refresh keeps the last good cache ──────────────────────
if [ -n "$WATCH_SECS" ]; then
  _n=0; _last=0
  while :; do
    _n=$((_n + 1))
    if sync_refresh; then
      _last=0
      [ "$OUT" = doc ] && printf '%s\n' "$DOC"
      echo "sync: watch refresh $_n ok ($(date -u +%H:%M:%SZ))" >&2
    else
      _last=1
      echo "sync: watch refresh $_n failed — kept the last good cache" >&2
    fi
    if _is_int "${KIT_SYNC_WATCH_MAX:-}" && [ "$_n" -ge "$KIT_SYNC_WATCH_MAX" ]; then exit "$_last"; fi
    sleep "$WATCH_SECS"
  done
fi

# ── --cached: serve the cache inside its TTL with no gh call, else refresh ──────────────────────
if [ -n "$CACHED_TTL" ]; then
  _cache="$(sync_cache_path)" || { echo "sync: --cached needs a git repository (no git-common-dir)" >&2; exit 1; }
  if [ -f "$_cache" ]; then
    # Fresh = younger than the TTL, and carrying a plan when one was asked for.
    _epoch="$(jq -r --argjson p "$PLAN" 'if $p == 1 and (has("plan") | not) then 0 else (.generatedEpoch // 0) end' "$_cache" 2>/dev/null || echo 0)"
    if _is_int "$_epoch" && [ $(( $(date -u +%s) - _epoch )) -lt "$CACHED_TTL" ]; then
      cat "$_cache"; exit 0
    fi
  fi
  sync_refresh || { echo "sync: refresh failed — the cache at $_cache was left as it was" >&2; exit 1; }
  printf '%s\n' "$DOC"; exit 0
fi

# ── --json / --write: one strict refresh ────────────────────────────────────────────────────────
if [ "$OUT" = doc ] || [ "$WRITE" = 1 ]; then
  sync_refresh || { echo "sync: could not read the board — no document written" >&2; exit 1; }
  if [ "$WRITE" = 1 ]; then echo "sync: wrote $(sync_cache_path)" >&2; fi
  [ "$OUT" = doc ] && { printf '%s\n' "$DOC"; exit 0; }
  [ "$OUT" = none ] && exit 0
else
  emit_event op.start sync "{\"mode\":\"$OUT\",\"write\":0}"
  sync_fetch lenient || { emit_event op.done sync '{"ok":false}'; echo "sync: could not read the board" >&2; exit 1; }
  emit_event op.done sync "{\"ok\":true,\"open\":$(printf '%s' "$ISSUES" | jq 'length' 2>/dev/null || echo 0)}"
fi

# Keep shell consumers out of the agent-oriented TOON encoding and flattened label shape.
if [ "$OUT" = "raw-json" ]; then
  printf '%s\n' "$ISSUES"
  exit 0
fi

# Structured output for agents: emit the open board and stop (--llm / CCKIT_OUTPUT). The board is a
# uniform list, so it goes out as TOON — far cheaper in tokens than JSON — via the shared encoder,
# which falls back to JSON for a non-uniform/empty result. labels + assignees are flattened to
# space-joined strings (and priority is lifted out) so every row is scalar-only and TOON-eligible.
if [ "$OUT" = "json" ]; then
  board="$(echo "$ISSUES" | jq -c '[.[] | {
      number,
      title,
      priority: ([.labels[].name | select(startswith("priority:")) | sub("priority:";"")][0] // ""),
      labels: ([.labels[].name] | join(" ")),
      milestone: (.milestone.title // ""),
      assignees: ([.assignees[].login] | join(" ")),
      blocked: ((.body // "") | test("Blocked by"))
    }]')"
  # shellcheck source=/dev/null
  . "$(dirname "$0")/lib/toon.sh"
  printf '%s' "$board" | toon_encode
  exit 0
fi

# All human output is composed as markdown inside this function, then piped once through
# cckit_render (below) so the whole board — tables, headings, flags — renders as one document.
_board_human() {
echo "## Board — $KIT_REPO"
echo ""

# Roles come from config; iterate in declared order, plus an "unlabeled" bucket.
print_role() {
  local role="$1" slug rows
  slug=$(echo "$role" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  rows=$(echo "$ISSUES" | jq -r --arg slug "role:$slug" --arg ms "$MS_FILTER" --argjson st "$STATUS_MAP" '
    .[] | select(any(.labels[]; .name == $slug))
        | select($ms == "" or (.milestone.title // "") == $ms)
        | { n:.number, t:.title,
            s:($st[(.number|tostring)] // "—"),
            p:([.labels[].name | select(startswith("priority:"))][0] // "—" | sub("priority:";"")),
            m:(.milestone.title // "—"),
            blocked:(.body // "" | test("Blocked by")) }
        | "| #\(.n) | \(.s) | \(.t) | \(.p) | \(.m) | \(if .blocked then "! blocked" else "—" end) |"')
  [[ -z "$rows" ]] && return
  echo "### $role"
  echo "| # | Status | Title | Pri | Milestone | Flag |"
  echo "| - | ------ | ----- | --- | --------- | ---- |"
  echo "$rows"
  echo ""
}

if [[ -n "$ROLE_FILTER" ]]; then
  print_role "$ROLE_FILTER"
else
  while IFS= read -r role; do [[ -n "$role" ]] && print_role "$role"; done <<< "$KIT_ROLES"
fi

# ── Flags: blocked / not-on-board / stale ───────────────────────────────────────────────────────
BLOCKED_LIST=$(echo "$ISSUES" | jq -r '[.[] | select((.body // "") | test("Blocked by")) | "#\(.number)"] | join(" ")')
NOT_ON_BOARD=$(board_not_on_board "$ISSUES" "$STATUS_MAP")
STALE_LIST=$(board_stale_list "$ISSUES" 14)
echo "**Blocked:** ${BLOCKED_LIST:-none ✓}"
# Only surface no-board-entry when a board is actually configured (otherwise every issue trivially
# has no entry — noise, not signal).
if [ "${KIT_PROJECTS_V2:-false}" = "true" ]; then
  echo "**Not on board:** ${NOT_ON_BOARD:-none ✓}"
fi
echo "**Stale (>14 days no activity):** ${STALE_LIST:-none ✓}"
OPEN_TOTAL=$(echo "$ISSUES" | jq -r 'length')
echo "**Open total:** ${OPEN_TOTAL}"
echo ""

# ── Merge Queue: open PRs ordered ready → draft → blocked (risk asc, size asc) ───────────────────
board_merge_queue "$PRS_JSON"

# ── Effort plan (--plan): `effort plan` inline, fenced so its column layout survives markdown ────
if [ "$PLAN" = 1 ]; then
  echo ""
  echo "### Effort plan"
  if sync_plan 2>/dev/null && [ -n "$PLAN_TEXT" ]; then
    printf '```text\n%s\n```\n' "$PLAN_TEXT"
  else
    echo "_(no effort plan — no open efforts, or \`effort plan\` could not read them)_"
  fi
fi

# ── Optional local-model digest — only when the local endpoint is alive (zero API cost) ──────────
# A 3–5 line executive read of the board (merge order, blockers, staleness). Best-effort: absent or
# offline local model → nothing appended, the board view above stands on its own.
if [ -f "$(dirname "$0")/lib/kit-local.sh" ]; then
  # shellcheck source=/dev/null
  if source "$(dirname "$0")/lib/kit-local.sh" 2>/dev/null && kit_local_alive 2>/dev/null; then
    echo ""
    echo "### Local digest"
    kit_local_chat \
      "You are a release captain. In 3–5 lines, summarize the merge order, blockers, and staleness for a busy maintainer." \
      "Blocked: ${BLOCKED_LIST:-none}. Stale: ${STALE_LIST:-none}. Merge queue follows the ready→draft→blocked order." \
      2>/dev/null || echo "_(local digest unavailable)_"
  fi
fi
}

# Emit the composed markdown through the rendering seam. cckit_render is rich (glow) only on a TTY;
# piped or in the Claude Code transcript it passes the markdown through verbatim (pipe-safe, no
# escape codes). Fall back to a plain call if render.sh was unavailable.
if command -v cckit_render >/dev/null 2>&1; then _board_human | cckit_render; else _board_human; fi
