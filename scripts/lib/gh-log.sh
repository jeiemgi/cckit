# shellcheck shell=bash
# gh-log.sh — log every GitHub API call the kit makes + estimate its secondary
# rate-limit POINT cost, so throttling is diagnosable instead of mysterious.
#
# GitHub secondary rate limit — point model (source, 2026-03-10 API version):
#   https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api#calculating-points-for-the-secondary-rate-limit
#     GraphQL query (no mutation) = 1 point   ·   GraphQL with mutation = 5 points
#     REST GET/HEAD/OPTIONS       = 1 point   ·   REST POST/PATCH/PUT/DELETE = 5 points
#   Ceilings: 900 points/min (REST) · 2,000 points/min (GraphQL) · 100 concurrent
#   (shared) · 90s CPU / 60s real (≤60s GraphQL) · 80 content-gen/min, 500/hour.
#
# Log: one JSON line per call appended to <git-common-dir>/gh-requests.jsonl
#   {ts, kind:"graphql|rest", op:"query|mutation|GET|POST|…", label, points, surface, pid}
# Disable with KIT_GH_LOG=0. Never fails a caller (logging is best-effort).

GH_LOG_FILE="${GH_LOG_FILE:-$(git rev-parse --git-common-dir 2>/dev/null)/gh-requests.jsonl}"

# gh_points <kind> <op> -> integer point cost (the doc's model).
gh_points() {
  case "${1}:${2}" in
    graphql:mutation) echo 5 ;;
    graphql:*)        echo 1 ;;
    rest:POST | rest:PATCH | rest:PUT | rest:DELETE) echo 5 ;;
    rest:GET | rest:HEAD | rest:OPTIONS) echo 1 ;;
    *) echo 1 ;;
  esac
}

# gh_log <kind> <op> <label> [surface]
#   kind = graphql|rest · op = query|mutation|GET|POST|… · label = human tag
#   surface = the caller (e.g. kit-task-sync, gh-project); defaults to ${KIT_GH_SURFACE:-kit}
gh_log() {
  [[ "${KIT_GH_LOG:-1}" == "0" ]] && return 0
  local kind="$1" op="$2" label="$3" surface="${4:-${KIT_GH_SURFACE:-kit}}"
  local pts ts
  pts=$(gh_points "$kind" "$op")
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || ts=""
  printf '{"ts":"%s","kind":"%s","op":"%s","label":"%s","points":%s,"surface":"%s","pid":%s}\n' \
    "$ts" "$kind" "$op" "$label" "$pts" "$surface" "$$" >>"$GH_LOG_FILE" 2>/dev/null || true
}

# gh_log_summary [seconds] — points spent in the last N seconds (default 60),
# split by kind, against the doc's per-minute ceilings. Read-only; for `kit gh-log`.
gh_log_summary() {
  local window="${1:-60}"
  [[ -f "$GH_LOG_FILE" ]] || { echo "no gh request log yet ($GH_LOG_FILE)"; return 0; }
  command -v jq >/dev/null 2>&1 || { echo "jq required for the summary"; return 1; }
  local since
  since=$(date -u -v-"${window}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "-${window} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  jq -rs --arg since "$since" '
    map(select($since == "" or .ts >= $since))
    | { calls: length,
        graphql_points: (map(select(.kind=="graphql") | .points) | add // 0),
        rest_points:    (map(select(.kind=="rest")    | .points) | add // 0) }
    | "last '"$window"'s — calls \(.calls) · GraphQL \(.graphql_points)/2000 pts · REST \(.rest_points)/900 pts"
  ' "$GH_LOG_FILE"
}
