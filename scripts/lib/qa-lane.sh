#!/usr/bin/env bash
# shellcheck shell=bash
# qa-lane.sh — one review stack per lane: launch the command the project declared, then say
# whether the stack is USABLE (#295), then open the screen the change touched (#297).
#
# Launched and usable are different facts. A dev server answers on its port seconds before the
# app behind it can serve a page, and a web process that is up while its API is down renders an
# error screen with a 200. So a lane is usable only when EVERY readiness probe in the `qa` config
# block answers in the same polling round, and only that verdict may open a browser.
#
# cckit does not boot the project by guessing. Everything here reads the `qa` block that
# `kit-add.sh qa` recorded (#294): `qa.command`, `qa.ports` as `{env, base}`, `qa.readiness` as
# `{env, path}`. The launched command gets the project's OWN port variable names — the ones the
# owner said the command honours — each set to `base + slot * stride`, where the slot is this
# lane's row in the port-slot ledger (wt_port_slot, worktree-start.sh). Two lanes hold two slots,
# so their ports are disjoint by allocation.
#
# A lane is keyed by an issue NUMBER: the one in the current branch name, or `--lane <n>`. The
# ledger rows are `<issue> <slot> <worktree>`, so a lane running in an issue's own worktree shares
# the slot `cckit start` already gave that worktree.
#
# Runtime state is per lane under the shared state dir (kit_state_dir — the same directory from
# every worktree): `qa/<lane>/pid`, `qa/<lane>/ports` (one `NAME=port` line per variable, exactly
# what the command was launched with) and `qa/<lane>/launch.log` (the command's stdout + stderr).
#
# What "up" means for one probe: the HTTP status is 2xx or 3xx. Redirects are NOT followed, so a
# 302 to a sign-in page is up — the app answered, and it answered with a decision. A 4xx, a 5xx
# and a refused connection are all "not yet".
#
#   qa_cfg                                  the project config path (rc 1 when there is none)
#   qa_lane_id [<lane>]                     the lane number: the argument, else the branch's issue
#   qa_lane_dir <lane>                      that lane's state directory (does not create it)
#   qa_lane_log <lane>                      that lane's launch log path
#   qa_ports_check <cfg> <stride>           rc 2 + a reason when qa.ports cannot give disjoint lanes
#   qa_lane_ports <cfg> <slot> <stride>     one `NAME=port` line per declared port variable
#   qa_probe_urls <cfg> <ports-file>        one `NAME<TAB>url` line per readiness probe
#   qa_probe <url>                          rc 0 when the url answers 2xx/3xx; echoes the status
#   qa_launch <lane> [<worktree>]           start the declared command with the lane's ports
#   qa_ready <lane> [<timeout-seconds>]     poll every probe until all answer; rc 1 on timeout
#   qa_route_declared                       stdin is a PR body; echo the route its `QA route:` line names
#   qa_route <lane> [<pr>]                  `declared<TAB>route` from the lane's PR, else `configured<TAB>route`
#   qa_usable <lane>                        ONE probe round, no waiting, no event: rc 0 usable · rc 1 not
#   qa_open <lane> [<pr>] [<route>] [<print-only>] [<port-env>]   hand the reviewer the changed screen
#   qa_cli <up|ready|open> [--lane N] …     the `cckit qa` verb
#
# The review route comes from the WORK, not from a smoke list: the builder writes one
# `QA route: /path` line in the PR body (`cckit brief` asks for it when a `qa` block exists) and
# `qa open` lands there. cckit hardcodes no project layout, so it never derives a route from
# changed file paths. With no declared line the configured `qa.route` is the fallback. The URL is
# always `http://<QA_HOST>:<lane port><route>`: the route is appended to a host and port cckit
# chose, so a PR body can pick the screen and nothing else. The port is the FIRST variable in
# `qa.ports` (the one a browser opens) unless `--port-env` names another.
#
# Events (kit-events.jsonl, through emit_event): `op.start qa.launch` when the command starts,
# `op.done qa.ready` when the lane becomes usable, `op.done qa.timeout` when the wait runs out,
# `op.done qa.exited` when the command died before the lane became usable, `op.done qa.open` when
# a usable lane's URL is handed over (payload: lane, url, route, source, opened).
#
# Tunables: QA_READY_TIMEOUT (seconds, default 120) · QA_READY_INTERVAL (seconds between rounds,
# default 2) · QA_PROBE_TIMEOUT (seconds per request, default 5) · QA_HOST (default localhost) ·
# QA_OPENER (the command that opens a URL; default `open`, else `xdg-open`).
#
# errors: strict — rc 2 on a usage or config refusal (nothing launched), rc 3 without jq or curl,
# rc 1 when the lane is not usable; every rc-1 message names the launch log to read.

# `${BASH_SOURCE[0]:-$0}`: BASH_SOURCE is empty under zsh, and `dirname ""` is "." — the sibling
# sources below would silently miss. Same fix as stage-receipt.sh and kit-gc.sh (#219).
_qa_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
command -v kit_state_dir   >/dev/null 2>&1 || . "$_qa_dir/kit-state.sh"
# shellcheck source=/dev/null
command -v kit_config_path >/dev/null 2>&1 || . "$_qa_dir/config-path.sh"
# shellcheck source=/dev/null
command -v emit_event      >/dev/null 2>&1 || . "$_qa_dir/kit-events.sh"
# shellcheck source=/dev/null
command -v wt_issue_number >/dev/null 2>&1 || . "$_qa_dir/worktree-issue.sh"
# shellcheck source=/dev/null
command -v wt_port_slot    >/dev/null 2>&1 || . "$_qa_dir/worktree-start.sh"
unset _qa_dir

_QA_NAME_RE='^[A-Za-z_][A-Za-z0-9_]*$'
# A route is a path: a leading slash, then URL path/query/fragment characters. No whitespace, no
# quotes, no backticks — it is read out of a PR body and handed to a browser opener as one argument.
_QA_ROUTE_RE='^/[A-Za-z0-9._~%/?#&=:@+,;!*-]*$'

_qa_need() {
  command -v jq   >/dev/null 2>&1 || { echo "cckit qa: jq is required" >&2; return 3; }
  command -v curl >/dev/null 2>&1 || { echo "cckit qa: curl is required to probe readiness" >&2; return 3; }
}

# qa_cfg — the project config, by the one shared resolver. rc 1 when there is none.
qa_cfg() {
  local cfg
  cfg="$(kit_config_path 2>/dev/null)" || return 1
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 1
  printf '%s\n' "$cfg"
}

# qa_lane_id [<lane>] — echo the lane number. An explicit argument must be a number; with none,
# the issue number in the current branch name is the lane. rc 2 when neither yields one.
qa_lane_id() {
  local lane="${1:-}" branch=""
  if [ -z "$lane" ]; then
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch=""
    [ -n "$branch" ] && lane="$(wt_issue_number "$branch" 2>/dev/null)"
  fi
  case "$lane" in
    ''|*[!0-9]*)
      echo "cckit qa: no lane — the branch '${branch:-?}' carries no issue number; pass --lane <number>" >&2
      return 2 ;;
  esac
  printf '%s\n' "$lane"
}

qa_lane_dir() { printf '%s/qa/%s\n' "$(kit_state_dir)" "$1"; }
qa_lane_log() { printf '%s/launch.log\n' "$(qa_lane_dir "$1")"; }

# qa_ports_check <cfg> <stride> — rc 2 with the reason on stderr when `qa.ports` cannot hand every
# lane a disjoint port set. A lane's port is `base + slot * stride` over 40 slots, so two bases
# that differ by a multiple of the stride, fewer than 40 strides apart, are the SAME port in two
# different lanes (bases 3000 and 3100 at stride 10: lane 10's first port is lane 0's second).
# Refused here, before anything launches — a shared port looks like a working stack until the
# second lane starts.
qa_ports_check() {
  local cfg="$1" stride="$2" why=""
  why="$(jq -r --argjson stride "$stride" --arg re "$_QA_NAME_RE" '
    (.qa.ports // []) as $p
    | if ($p | type) != "array" or ($p | length) == 0 then
        "qa.ports is empty — the stack command must honour at least one port env var"
      elif any($p[]; (.env | type) != "string" or (.env | test($re) | not)) then
        "qa.ports has an entry whose env is not a variable name"
      elif any($p[]; (.base | type) != "number" or .base < 1 or (.base + 39 * $stride) > 65535) then
        "qa.ports has a base that leaves the port range within 40 lanes at stride \($stride)"
      else
        ([ range(0; $p | length) as $i | range($i + 1; $p | length) as $j
           | { a: $p[$i], b: $p[$j], d: (($p[$i].base - $p[$j].base) | fabs) }
           | select(.a.env == .b.env or ((.d % $stride) == 0 and (.d / $stride) < 40)) ] | .[0]) as $c
        | if $c == null then ""
          elif $c.a.env == $c.b.env then "qa.ports declares \($c.a.env) twice"
          else "qa.ports bases \($c.a.env)=\($c.a.base) and \($c.b.env)=\($c.b.base) are \($c.d) apart, a multiple of the stride \($stride): two lanes would share a port. Move one base off the multiple (or 40 strides away), or change worktree.devPortStride"
          end
      end' "$cfg" 2>/dev/null)" || why="the qa block in $cfg could not be read"
  [ -z "$why" ] && return 0
  echo "cckit qa: $why" >&2
  return 2
}

# qa_lane_ports <cfg> <slot> <stride> — one `NAME=port` line per declared port variable.
qa_lane_ports() {
  jq -r --argjson slot "$2" --argjson stride "$3" \
    '(.qa.ports // [])[] | "\(.env)=\(.base + $slot * $stride)"' "$1" 2>/dev/null
}

# qa_probe_urls <cfg> <ports-file> — one `NAME<TAB>url` line per readiness probe, built from the
# ports the lane was actually LAUNCHED with (the recorded file), not recomputed from config: a
# config edited after launch must not move the probes off the running stack. rc 2 when there is no
# probe, or a probe names a variable the lane has no port for.
qa_probe_urls() {
  local cfg="$1" pfile="$2" host="${QA_HOST:-localhost}" rows="" name="" rpath="" port="" out="" tab
  tab="$(printf '\t')"
  rows="$(jq -r '(.qa.readiness // [])[] | "\(.env // "")\t\(.path // "/")"' "$cfg" 2>/dev/null)"
  if [ -z "$rows" ]; then
    echo "cckit qa: qa.readiness is empty — with no probe, launched cannot be told from usable. Declare one path per service (kit-add.sh qa)" >&2
    return 2
  fi
  while IFS="$tab" read -r name rpath; do
    [ -n "$name" ] || continue
    port="$(awk -F= -v n="$name" '$1 == n { print $2; exit }' "$pfile" 2>/dev/null)"
    case "$port" in
      ''|*[!0-9]*)
        echo "cckit qa: qa.readiness probes $name, which is not a port variable in qa.ports" >&2
        return 2 ;;
    esac
    case "$rpath" in /*) : ;; *) rpath="/$rpath" ;; esac
    out="$out$name$tab""http://$host:$port$rpath
"
  done <<EOF
$rows
EOF
  printf '%s' "$out"
}

# qa_probe <url> — echo the HTTP status; rc 0 when it is 2xx or 3xx. Redirects are not followed:
# a 302 to sign-in is the app answering. A refused connection reads as 000.
qa_probe() {
  local code=""
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${QA_PROBE_TIMEOUT:-5}" "$1" 2>/dev/null)" || true
  case "$code" in [0-9][0-9][0-9]) : ;; *) code="000" ;; esac
  printf '%s' "$code"
  case "$code" in 2??|3??) return 0 ;; esac
  return 1
}

# _qa_pid_live <lane> — rc 0 when the lane's recorded command is still running.
_qa_pid_live() {
  local pid=""
  pid="$(cat "$(qa_lane_dir "$1")/pid" 2>/dev/null)" || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# _qa_ports_json <ports-file> — the recorded ports as one JSON object, for event payloads.
_qa_ports_json() {
  jq -Rn '[inputs | select(length > 0) | split("=") | { key: .[0], value: (.[1] | tonumber) }] | from_entries' \
    < "$1" 2>/dev/null || printf '{}'
}

# qa_launch <lane> [<worktree>] — start the declared command in <worktree> (default: the current
# checkout) with every declared port variable set to this lane's port. Echoes the pid.
#
# Idempotent: a lane whose recorded command is still running is left alone and its pid is echoed —
# a second `up` must never start a second stack on the same ports.
qa_launch() {
  local lane="$1" wt="${2:-}" cfg="" cmd="" stride="" slot="" ports="" d="" log="" pid="" line="" payload=""
  _qa_need || return $?
  cfg="$(qa_cfg)" || { echo "cckit qa: no kit config found — run cckit init, then kit-add.sh qa" >&2; return 2; }
  cmd="$(jq -r '.qa.command // empty' "$cfg" 2>/dev/null)"
  if [ -z "$cmd" ]; then
    echo "cckit qa: no qa.command in $cfg — cckit does not guess how a project boots. Record it with kit-add.sh qa" >&2
    return 2
  fi
  [ -n "$wt" ] || wt="$(git rev-parse --show-toplevel 2>/dev/null)" || wt="$PWD"

  stride="$(wt_port_stride "$cfg")"
  qa_ports_check "$cfg" "$stride" || return $?
  d="$(qa_lane_dir "$lane")"; log="$d/launch.log"

  if _qa_pid_live "$lane"; then
    pid="$(cat "$d/pid")"
    echo "[qa $lane] already launched (pid $pid) — not starting a second stack" >&2
    printf '%s\n' "$pid"
    return 0
  fi

  slot="$(wt_port_slot "$wt" "$lane" "$wt")"
  case "$slot" in ''|*[!0-9]*) echo "cckit qa: could not allocate a port slot for lane $lane" >&2; return 1 ;; esac
  ports="$(qa_lane_ports "$cfg" "$slot" "$stride")"
  # Probe wiring is a config fact — refuse a stack nothing could ever call usable BEFORE starting it.
  mkdir -p "$d" 2>/dev/null || { echo "cckit qa: cannot create $d" >&2; return 1; }
  printf '%s\n' "$ports" > "$d/ports"
  # A lane with a ports file reads as launched, so a refusal here must not leave one behind.
  qa_probe_urls "$cfg" "$d/ports" >/dev/null || { rm -f "$d/ports"; return 2; }

  : > "$log"
  (
    cd "$wt" || exit 1
    while IFS= read -r line; do
      # shellcheck disable=SC2163  # $line IS the `NAME=port` assignment to export
      [ -n "$line" ] && export "$line"
    done <<EOF
$ports
EOF
    if command -v nohup >/dev/null 2>&1; then exec nohup sh -c "$cmd"; else exec sh -c "$cmd"; fi
  ) >> "$log" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$d/pid"

  payload="$(jq -cn --arg lane "$lane" --argjson pid "$pid" --arg log "$log" --arg wt "$wt" \
               --argjson ports "$(_qa_ports_json "$d/ports")" \
               '{lane: $lane, pid: $pid, log: $log, worktree: $wt, ports: $ports}' 2>/dev/null)"
  emit_event op.start qa.launch "$payload"
  echo "[qa $lane] launched (pid $pid) · $(tr '\n' ' ' < "$d/ports")· log: $log" >&2
  printf '%s\n' "$pid"
}

# qa_ready <lane> [<timeout-seconds>] — poll every readiness probe until ALL answer in one round.
# rc 0 usable · rc 1 not usable (timed out, or the command exited first) · rc 2 config refusal.
# Never reports usable on a partial round: a web 200 with the API probe failing is not usable.
qa_ready() {
  local lane="$1" limit="${2:-${QA_READY_TIMEOUT:-120}}" every="${QA_READY_INTERVAL:-2}"
  local cfg="" d="" log="" urls="" name="" url="" code="" pending="" start="" now="" waited=0 tab
  tab="$(printf '\t')"
  _qa_need || return $?
  case "$limit" in ''|*[!0-9]*) echo "cckit qa: --timeout takes whole seconds, got '$limit'" >&2; return 2 ;; esac
  cfg="$(qa_cfg)" || { echo "cckit qa: no kit config found" >&2; return 2; }
  d="$(qa_lane_dir "$lane")"; log="$d/launch.log"
  if [ ! -f "$d/ports" ]; then
    echo "cckit qa: lane $lane was never launched (no $d/ports) — run cckit qa up" >&2
    return 2
  fi
  urls="$(qa_probe_urls "$cfg" "$d/ports")" || return $?

  start="$(date +%s)"
  while :; do
    pending=""
    while IFS="$tab" read -r name url; do
      [ -n "$name" ] || continue
      code="$(qa_probe "$url")" || pending="$pending $name $url -> $code;"
    done <<EOF
$urls
EOF
    now="$(date +%s)"; waited=$(( now - start ))
    if [ -z "$pending" ]; then
      emit_event op.done qa.ready "$(jq -cn --arg lane "$lane" --argjson s "$waited" \
        --argjson ports "$(_qa_ports_json "$d/ports")" '{lane: $lane, seconds: $s, ports: $ports}' 2>/dev/null)"
      echo "[qa $lane] usable after ${waited}s — every readiness probe answered" >&2
      return 0
    fi
    # A recorded command that has exited will never answer; say so now rather than at the timeout.
    if [ -f "$d/pid" ] && ! _qa_pid_live "$lane"; then
      emit_event op.done qa.exited "$(jq -cn --arg lane "$lane" --arg log "$log" --arg pending "${pending# }" \
        '{lane: $lane, log: $log, pending: $pending}' 2>/dev/null)"
      echo "cckit qa: lane $lane is NOT usable — the stack command exited before it was ready." >&2
      echo "  not answering:${pending%;}" >&2
      echo "  read the launch log: $log" >&2
      return 1
    fi
    if [ "$waited" -ge "$limit" ]; then
      emit_event op.done qa.timeout "$(jq -cn --arg lane "$lane" --arg log "$log" --argjson s "$limit" \
        --arg pending "${pending# }" '{lane: $lane, timeout: $s, log: $log, pending: $pending}' 2>/dev/null)"
      echo "cckit qa: lane $lane is NOT usable — timed out after ${limit}s." >&2
      echo "  not answering:${pending%;}" >&2
      echo "  read the launch log: $log" >&2
      return 1
    fi
    sleep "$every" 2>/dev/null || sleep 1
  done
}

# ── the route: declared by the work, else configured (#297) ────────────────────────────────────

# qa_route_valid <route> — rc 0 when <route> is one line matching _QA_ROUTE_RE.
qa_route_valid() {
  case "${1:-}" in *'
'*) return 1 ;; esac
  printf '%s\n' "${1:-}" | grep -qE "$_QA_ROUTE_RE"
}

# qa_route_declared — stdin is a PR body; echo the route its first usable `QA route:` line names.
# Tolerates the shapes people write: a list bullet, bold markers, backticks around the value, any
# letter case. A line whose value is not a route (a template's `QA route: <path>` placeholder) is
# skipped, so an unfilled template reads as "none declared". rc 1 when there is none. Pure.
qa_route_declared() {
  local r=""
  r="$(tr -d '\r' \
        | sed -nE 's/^[[:space:]]*([-*][[:space:]]+)?\**[Qq][Aa] [Rr][Oo][Uu][Tt][Ee]\**:\**[[:space:]]*`?([^`[:space:]]*).*$/\2/p' \
        | grep -E "$_QA_ROUTE_RE" | head -n 1)"
  [ -n "$r" ] || return 1
  printf '%s\n' "$r"
}

# _qa_lane_branch <lane> — the local branch whose issue number is <lane>: the current branch when
# it matches, else the first local head that does. Echoes nothing when there is none.
_qa_lane_branch() {
  local lane="$1" b=""
  b="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || b=""
  if [ -n "$b" ] && [ "$(wt_issue_number "$b" 2>/dev/null)" = "$lane" ]; then
    printf '%s\n' "$b"; return 0
  fi
  git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null | while IFS= read -r b; do
    [ "$(wt_issue_number "$b" 2>/dev/null)" = "$lane" ] || continue
    printf '%s\n' "$b"; break
  done
}

# qa_route <lane> [<pr>] — echo `<source>\t<route>`: `declared` when the lane's PR body carries a
# `QA route:` line, else `configured` with `qa.route` (`/` when the config has none). The PR is
# <pr> when given, else the one open from the lane's branch. Reading the PR is best-effort — no
# gh, no PR yet, or an unreadable body all fall back to the configured route. rc 2 only when the
# CONFIGURED route is not a route, since then there is nothing valid to fall back to.
qa_route() {
  local lane="$1" pr="${2:-}" cfg="" ref="" body="" route="" tab
  tab="$(printf '\t')"
  ref="$pr"
  [ -n "$ref" ] || ref="$(_qa_lane_branch "$lane")"
  if [ -n "$ref" ] && command -v gh >/dev/null 2>&1; then
    body="$(gh pr view "$ref" --json body --jq '.body // ""' 2>/dev/null)" || body=""
    if [ -n "$body" ] && route="$(printf '%s\n' "$body" | qa_route_declared)"; then
      printf 'declared%s%s\n' "$tab" "$route"
      return 0
    fi
  fi
  cfg="$(qa_cfg)" || { echo "cckit qa: no kit config found" >&2; return 2; }
  route="$(jq -r '.qa.route // "/"' "$cfg" 2>/dev/null)"
  [ -n "$route" ] || route="/"
  if ! qa_route_valid "$route"; then
    echo "cckit qa: qa.route in $cfg is not a route — it must start with / and hold no spaces" >&2
    return 2
  fi
  printf 'configured%s%s\n' "$tab" "$route"
}

# qa_usable <lane> — ONE probe round against a launched lane: rc 0 when every readiness probe
# answers now, rc 1 (the probes still failing on stderr) when one does not, rc 2 when the lane was
# never launched. Unlike qa_ready it does not wait and emits no event — it is a question, not a wait.
qa_usable() {
  local lane="$1" cfg="" d="" urls="" name="" url="" code="" pending="" tab
  tab="$(printf '\t')"
  cfg="$(qa_cfg)" || { echo "cckit qa: no kit config found" >&2; return 2; }
  d="$(qa_lane_dir "$lane")"
  if [ ! -f "$d/ports" ]; then
    echo "cckit qa: lane $lane was never launched (no $d/ports) — run cckit qa up" >&2
    return 2
  fi
  urls="$(qa_probe_urls "$cfg" "$d/ports")" || return $?
  while IFS="$tab" read -r name url; do
    [ -n "$name" ] || continue
    code="$(qa_probe "$url")" || pending="$pending $name $url -> $code;"
  done <<EOF
$urls
EOF
  [ -z "$pending" ] && return 0
  echo "  not answering:${pending%;}" >&2
  return 1
}

# qa_open <lane> [<pr>] [<route>] [<print-only>] [<port-env>] — hand the reviewer the screen the
# change touched: `http://<host>:<lane port><route>` on stdout, and opened in a browser unless
# <print-only> is 1. An explicit <route> wins over the PR's declared one.
#
# Refuses a lane that is not usable RIGHT NOW (one probe round): a browser on a stack that is
# still booting shows a connection error the reviewer reads as a broken change. rc 1 not usable ·
# rc 2 never launched or a bad route/port variable. With no opener on the machine the URL is still
# printed and the rc is 0 — the URL is the hand-over, the browser is a convenience.
qa_open() {
  local lane="$1" pr="${2:-}" route="${3:-}" only="${4:-0}" penv="${5:-}"
  local d="" row="" src="" port="" url="" opener="" opened=false why="" rc=0 tab
  tab="$(printf '\t')"
  _qa_need || return $?
  d="$(qa_lane_dir "$lane")"
  # qa_usable writes only to stderr, so its whole output is the reason.
  why="$(qa_usable "$lane" 2>&1)" || rc=$?
  if [ "$rc" -eq 1 ]; then
    echo "cckit qa: lane $lane is NOT usable — refusing to open a browser on it." >&2
    [ -z "$why" ] || printf '%s\n' "$why" >&2
    echo "  wait for it with: cckit qa ready --lane $lane · launch log: $d/launch.log" >&2
    return 1
  elif [ "$rc" -ne 0 ]; then
    [ -z "$why" ] || printf '%s\n' "$why" >&2
    return "$rc"
  fi

  if [ -n "$route" ]; then
    qa_route_valid "$route" || { echo "cckit qa: --route '$route' is not a route — it must start with / and hold no spaces" >&2; return 2; }
    src="flag"
  else
    row="$(qa_route "$lane" "$pr")" || return $?
    src="${row%%"$tab"*}"; route="${row#*"$tab"}"
  fi

  if [ -n "$penv" ]; then
    port="$(awk -F= -v n="$penv" '$1 == n { print $2; exit }' "$d/ports" 2>/dev/null)"
  else
    port="$(awk -F= 'NF > 1 { print $2; exit }' "$d/ports" 2>/dev/null)"
  fi
  case "$port" in
    ''|*[!0-9]*)
      echo "cckit qa: lane $lane has no port for '${penv:-the first qa.ports variable}' — its variables: $(cut -d= -f1 "$d/ports" | tr '\n' ' ')" >&2
      return 2 ;;
  esac
  url="http://${QA_HOST:-localhost}:$port$route"

  if [ "$only" != 1 ]; then
    opener="${QA_OPENER:-}"
    if [ -z "$opener" ]; then
      if command -v open >/dev/null 2>&1; then opener=open
      elif command -v xdg-open >/dev/null 2>&1; then opener=xdg-open
      fi
    fi
    if [ -z "$opener" ]; then
      echo "[qa $lane] no browser opener here (open, xdg-open, or QA_OPENER) — open the URL by hand" >&2
    elif "$opener" "$url" >/dev/null 2>&1; then
      opened=true
    else
      echo "[qa $lane] '$opener' could not open the URL — open it by hand" >&2
    fi
  fi

  emit_event op.done qa.open "$(jq -cn --arg lane "$lane" --arg url "$url" --arg route "$route" \
    --arg source "$src" --argjson opened "$opened" \
    '{lane: $lane, url: $url, route: $route, source: $source, opened: $opened}' 2>/dev/null)"
  echo "[qa $lane] $src route $route" >&2
  if [ "${CCKIT_OUTPUT:-human}" = json ]; then
    jq -cn --arg lane "$lane" --arg url "$url" --arg route "$route" --arg source "$src" \
      --argjson opened "$opened" '{lane: $lane, url: $url, route: $route, source: $source, opened: $opened}'
  else
    printf '%s\n' "$url"
  fi
}

# qa_cli <args> — the `cckit qa` verb.
qa_cli() {
  # Every local gets a value: bin/cckit runs under `set -u`, and a bare `local x` is UNSET.
  local sub="${1:-}" lane="" limit="" pid="" d="" rc=0 pr="" route="" only=0 penv=""
  case "$sub" in
    up|ready|open) shift ;;
    ''|-h|--help|help)
      cat >&2 <<'EOF'
cckit qa up    [--lane <n>] [--timeout <s>]   launch the declared stack command with this lane's
                                              ports, then wait until every readiness probe answers
cckit qa ready [--lane <n>] [--timeout <s>]   wait on a lane that is already launched
cckit qa open  [--lane <n>] [--pr <n>] [--route </path>] [--port-env <NAME>] [--print]
                                              open the screen the change touched on a usable lane

The lane is the issue number in the current branch, or --lane. Exit 0 only when the stack is
USABLE: every qa.readiness probe answered 2xx/3xx in one round (a redirect to sign-in is up).
Exit 1 names the launch log. Reads the `qa` block recorded by kit-add.sh qa.

open lands on http://localhost:<lane port><route>. The route is the `QA route: /path` line in the
lane's PR body (--pr picks another PR), else the configured qa.route; --route overrides both. The
port is the first qa.ports variable, or --port-env. A lane that is not usable right now is refused
(exit 1). --print prints the URL without opening a browser.
EOF
      return 2 ;;
    *) echo "cckit qa: unknown subcommand '$sub' — cckit qa <up|ready|open>" >&2; return 2 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lane)      lane="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
      --lane=*)    lane="${1#*=}"; shift ;;
      --timeout)   limit="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
      --timeout=*) limit="${1#*=}"; shift ;;
      --pr|--route|--port-env|--print|--pr=*|--route=*|--port-env=*)
        [ "$sub" = open ] || { echo "cckit qa $sub: '${1%%=*}' belongs to cckit qa open" >&2; return 2; }
        case "$1" in
          --print)      only=1; shift ;;
          --pr)         pr="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --pr=*)       pr="${1#*=}"; shift ;;
          --route)      route="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --route=*)    route="${1#*=}"; shift ;;
          --port-env)   penv="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --port-env=*) penv="${1#*=}"; shift ;;
        esac ;;
      *) echo "cckit qa $sub: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  lane="$(qa_lane_id "$lane")" || return $?
  if [ "$sub" = open ]; then
    [ -z "$limit" ] || { echo "cckit qa open: --timeout belongs to up and ready — open does not wait" >&2; return 2; }
    case "$pr" in *[!0-9]*) echo "cckit qa open: --pr takes a pull request number, got '$pr'" >&2; return 2 ;; esac
    qa_open "$lane" "$pr" "$route" "$only" "$penv"
    return $?
  fi
  [ -n "$limit" ] || limit="${QA_READY_TIMEOUT:-120}"

  if [ "$sub" = up ]; then
    pid="$(qa_launch "$lane")" || return $?
  fi
  qa_ready "$lane" "$limit" || rc=$?
  case "$rc" in 2|3) return "$rc" ;; esac

  d="$(qa_lane_dir "$lane")"
  [ -n "$pid" ] || pid="$(cat "$d/pid" 2>/dev/null)" || pid=""
  if [ "${CCKIT_OUTPUT:-human}" = json ]; then
    jq -cn --arg lane "$lane" --arg pid "$pid" --arg log "$d/launch.log" --argjson usable "$([ "$rc" -eq 0 ] && echo true || echo false)" \
      --argjson ports "$(_qa_ports_json "$d/ports")" \
      '{lane: $lane, usable: $usable, pid: ($pid | tonumber? // null), ports: $ports, log: $log}'
  elif [ "$rc" -eq 0 ]; then
    printf 'lane %s usable · %s\n' "$lane" "$(tr '\n' ' ' < "$d/ports" | sed 's/ $//')"
  fi
  return "$rc"
}
