#!/usr/bin/env bash
# shellcheck shell=bash
# qa-lane.sh — one review stack per lane: launch the command the project declared, then say
# whether the stack is USABLE (#295), then open the screen the change touched (#297), then stop
# it so the ports are actually free (#298), then record the reviewer's verdict against the commit
# that was reviewed (#299).
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
# Two more files exist so `qa stop` can tell the stack from a stranger: `qa/<lane>/started` (the
# launched pid's start time — a recycled pid has another) and `qa/<lane>/pgid` (written only when
# the command was started as its own process-group leader, which needs perl).
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
#   qa_port_tool                            `lsof` or `ss`: what can name a port's holder; rc 1 for neither
#   qa_port_pids <port> [<tool>]            the pids LISTENING on <port>, one per line
#   qa_stop <lane>                          stop the lane's supervisors, then its listeners; rc 1 if a port stays held
#   qa_verdict_state <lane> [<head>]        `pass` · `fail` · `stale` · `none` for the lane's verdict; rc 0 only for pass
#   qa_verdict <lane> <pass|fail> [<pr>] [<head>] [<notes>] [<to>] [<shots>]   record it, post it, mail a fail
#   qa_verdict_show <lane> [<pr>] [<head>]  print that state against the lane's head now
#   qa_cli <up|ready|open|stop|verdict> [--lane N] …   the `cckit qa` verb
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
# a usable lane's URL is handed over (payload: lane, url, route, source, opened), `op.done qa.stop`
# when a stop ran against a lane with a record (payload: lane, stopped, ports, held, freed),
# `op.done qa.verdict` for each recorded verdict (payload: lane, verdict, head, pr, attempt,
# comment, mailed).
#
# Tunables: QA_READY_TIMEOUT (seconds, default 120) · QA_READY_INTERVAL (seconds between rounds,
# default 2) · QA_PROBE_TIMEOUT (seconds per request, default 5) · QA_HOST (default localhost) ·
# QA_OPENER (the command that opens a URL; default `open`, else `xdg-open`) · QA_STOP_GRACE
# (seconds a process gets to exit on TERM before KILL, default 5) · QA_STOP_ROUNDS (how many times
# the port holders are re-resolved to catch a respawn, default 5) · QA_PORT_TOOL (`lsof`, `ss` or
# `none`: force the holder lookup; default is whichever exists).
#
# errors: strict — rc 2 on a usage or config refusal (nothing launched), rc 3 without jq or curl,
# rc 1 when the lane is not usable; every rc-1 message names the launch log to read. For
# `verdict`: rc 2 refuses before any write, rc 1 after a recorded fail whose notes reached no
# mailbox, and reading a verdict is rc 0 only for a pass on the lane's current head.

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
# shellcheck source=/dev/null
command -v sr_record       >/dev/null 2>&1 || . "$_qa_dir/stage-receipt.sh"
# shellcheck source=/dev/null
command -v pr_attach_evidence >/dev/null 2>&1 || . "$_qa_dir/pr-evidence.sh"
# shellcheck source=/dev/null
command -v msg_send        >/dev/null 2>&1 || . "$_qa_dir/kit-msg.sh"
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
  local lane="$1" wt="${2:-}" cfg="" cmd="" stride="" slot="" ports="" d="" log="" pid="" line="" payload="" grouped=0
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
  command -v perl >/dev/null 2>&1 && grouped=1
  (
    cd "$wt" || exit 1
    while IFS= read -r line; do
      # shellcheck disable=SC2163  # $line IS the `NAME=port` assignment to export
      [ -n "$line" ] && export "$line"
    done <<EOF
$ports
EOF
    # Its own process group when perl can make one: `qa stop` then finds every member by group
    # even after this root has died and its children were reparented to pid 1 (#298).
    if [ "$grouped" = 1 ]; then
      if command -v nohup >/dev/null 2>&1; then
        exec perl -e 'setpgrp(0, 0); exec @ARGV; exit 127' nohup sh -c "$cmd"
      else
        exec perl -e 'setpgrp(0, 0); exec @ARGV; exit 127' sh -c "$cmd"
      fi
    fi
    if command -v nohup >/dev/null 2>&1; then exec nohup sh -c "$cmd"; else exec sh -c "$cmd"; fi
  ) >> "$log" 2>&1 < /dev/null &
  pid=$!
  printf '%s\n' "$pid" > "$d/pid"
  rm -f "$d/pgid" "$d/started"
  [ "$grouped" = 1 ] && printf '%s\n' "$pid" > "$d/pgid"
  _qa_pid_started "$pid" > "$d/started" 2>/dev/null || rm -f "$d/started"

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

# ── stop: free the ports for real (#298) ───────────────────────────────────────────────────────
#
# A dev stack is a process tree, and the process holding a port is rarely the one that was
# launched: `pnpm dev` starts a runner that starts a watcher that starts the server. Killing the
# listener alone frees the port for as long as its supervisor takes to respawn it. So a stop
# resolves two sets and orders them:
#
#   owned     every descendant of the recorded pid, plus every member of the lane's process group
#             (`qa/<lane>/pgid`) — the group still names them after the root died and its children
#             were reparented to pid 1.
#   holders   whoever LISTENS on each recorded port right now (lsof, else ss), and each holder's
#             ancestors for as long as they share the holder's process group.
#
# Everything that is not a holder is a supervisor and is stopped first, parents before children;
# the holders go last. The holders are then resolved again, because only a port with no listener
# proves the stack is down — a listener that came back names a supervisor the first round missed.
#
# The ancestor climb is bounded on purpose: it never reaches pid 1, this shell, or any ancestor of
# this shell, and it stops at a process-group boundary, so a stranger's server on the lane's port
# costs that server and its own job, not the terminal it was started from.

# _qa_pid_started <pid> — the process start time as ps prints it; identifies a pid across reuse.
_qa_pid_started() {
  local s=""
  s="$(ps -o lstart= -p "$1" 2>/dev/null)" || return 1
  [ -n "$s" ] || return 1
  printf '%s\n' "$s" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

# _qa_alive <pid> — rc 0 when <pid> is a running process. A zombie is not: it holds no port and
# cannot respawn anything, it is only waiting for its parent to read its exit code.
_qa_alive() {
  local st=""
  kill -0 "$1" 2>/dev/null || return 1
  st="$(ps -o stat= -p "$1" 2>/dev/null)" || return 1
  case "$st" in ''|*Z*) return 1 ;; esac
  return 0
}

# qa_port_tool — echo the tool that can name a port's holder: `lsof`, else `ss`. rc 1 when there
# is neither (or QA_PORT_TOOL=none). QA_PORT_TOOL forces one.
qa_port_tool() {
  case "${QA_PORT_TOOL:-}" in
    none) return 1 ;;
    lsof|ss) command -v "$QA_PORT_TOOL" >/dev/null 2>&1 || return 1; printf '%s\n' "$QA_PORT_TOOL"; return 0 ;;
  esac
  if command -v lsof >/dev/null 2>&1; then printf 'lsof\n'
  elif command -v ss >/dev/null 2>&1; then printf 'ss\n'
  else return 1
  fi
}

# qa_port_pids <port> [<tool>] — the pids LISTENING on TCP <port>, one per line, deduplicated.
# Empty output is "no listener this user can see": ss names a pid only for the caller's own
# processes, and so does lsof without root.
qa_port_pids() {
  local port="$1" tool="${2:-}"
  case "$port" in ''|*[!0-9]*) return 0 ;; esac
  [ -n "$tool" ] || tool="$(qa_port_tool)" || return 1
  case "$tool" in
    lsof) lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | grep -E '^[0-9]+$' | sort -un ;;
    ss)   ss -H -ltnp "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -un ;;
    *)    return 1 ;;
  esac
  return 0
}

# _qa_lane_holders <ports-file> <tool> — the pids listening on any recorded port, one per line.
_qa_lane_holders() {
  local pfile="$1" tool="$2" port=""
  [ -n "$tool" ] && [ -f "$pfile" ] || return 0
  cut -d= -f2 "$pfile" 2>/dev/null | while IFS= read -r port; do
    qa_port_pids "$port" "$tool"
  done | sort -un
}

# _qa_stop_plan <root> <group> <holders> — the ordered stop list, one `sup <pid>` or `lis <pid>`
# line each: supervisors parents-first, then the holders. <root> and <group> may be empty;
# <holders> is whitespace-separated pids. Reads one process snapshot; zombies are left out.
_qa_stop_plan() {
  # shellcheck disable=SC2009  # the whole table is the input — pgrep cannot give ppid and pgid
  ps -A -o pid= -o ppid= -o pgid= -o stat= 2>/dev/null | awk -v root="$1" -v grp="$2" -v holders="$3" -v self="$$" '
    $4 !~ /Z/ { pp[$1] = $2; pg[$1] = $3 }
    END {
      mine[1] = 1
      for (a = self; (a in pp) && a > 1 && !(a in mine); a = pp[a]) mine[a] = 1
      for (p in pp) {
        if (p in mine) continue
        if (grp != "" && pg[p] == grp) { own[p] = 1; continue }
        if (root == "") continue
        n = 0
        for (a = p; (a in pp) && a > 1 && n < 200; a = pp[a]) { if (a == root) { own[p] = 1; break }; n++ }
      }
      nh = split(holders, hs, /[ \t\n]+/)
      for (i = 1; i <= nh; i++) {
        h = hs[i]
        if (h == "" || !(h in pp) || (h in mine)) continue
        own[h] = 1; lis[h] = 1
        n = 0
        for (a = pp[h]; (a in pp) && a > 1 && !(a in mine) && pg[a] == pg[h] && n < 200; a = pp[a]) { own[a] = 1; n++ }
      }
      for (p in own) {
        depth = 0
        for (a = p; (a in pp) && a > 1 && depth < 200; a = pp[a]) depth++
        printf "%s %d %s\n", ((p in lis) ? "1 lis" : "0 sup"), depth, p
      }
    }' | sort -k1,1n -k3,3n -k4,4n | awk '{ print $2, $4 }'
}

# _qa_kill_wait <pids> — TERM each pid in the order given (one per line), give them QA_STOP_GRACE
# seconds to exit, then KILL what is left. Echoes every pid it signalled.
_qa_kill_wait() {
  local pids="$1" p="" left="" ticks=0 limit=0
  [ -n "$pids" ] || return 0
  limit=$(( ${QA_STOP_GRACE:-5} * 10 ))
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _qa_alive "$p" || continue
    kill -TERM "$p" 2>/dev/null && printf '%s\n' "$p"
  done <<EOF
$pids
EOF
  while :; do
    left=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      _qa_alive "$p" && left="$left$p
"
    done <<EOF
$pids
EOF
    [ -z "$left" ] && return 0
    [ "$ticks" -ge "$limit" ] && break
    sleep 0.1 2>/dev/null || sleep 1
    ticks=$(( ticks + 1 ))
  done
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    kill -KILL "$p" 2>/dev/null || true
  done <<EOF
$left
EOF
  ticks=0
  while [ "$ticks" -lt 20 ]; do
    left=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      _qa_alive "$p" && left=1
    done <<EOF
$pids
EOF
    [ -z "$left" ] && return 0
    sleep 0.1 2>/dev/null || sleep 1
    ticks=$(( ticks + 1 ))
  done
  return 0
}

# qa_stop <lane> — stop the lane's stack and say what actually stopped.
#
# rc 0 when the lane is down: every recorded port has no listener and nothing signalled survived.
# That includes a lane that was already down (or never launched) — "nothing stopped" is a true
# report, not an error, so the op is safe to re-run. rc 1 when a port is still held or a process
# outlived KILL (another user's process, typically); the record is kept so a retry can find it.
#
# With neither lsof nor ss the holders cannot be resolved: the recorded tree and group are still
# stopped, and the report says the ports were NOT checked rather than calling them free.
qa_stop() {
  local lane="$1" d="" pid="" root="" grp="" tool="" holders="" plan="" sups="" liss="" tried="" got=""
  local stopped="" alive="" held="" p="" round=0 rounds="${QA_STOP_ROUNDS:-5}" freed="null" n=0 rc=0
  d="$(qa_lane_dir "$lane")"
  if [ ! -f "$d/ports" ] && [ ! -f "$d/pid" ]; then
    echo "[qa $lane] nothing stopped — the lane has no running stack on record" >&2
    [ "${CCKIT_OUTPUT:-human}" = json ] && printf '{"lane":"%s","stopped":[],"held":[],"freed":null}\n' "$lane"
    return 0
  fi
  case "$rounds" in ''|*[!0-9]*) rounds=5 ;; esac
  tool="$(qa_port_tool)" || tool=""

  # The recorded pid is trusted as the tree root only while it is the SAME process: a pid recycled
  # after a reboot has another start time, and stopping its tree would stop a stranger.
  pid="$(cat "$d/pid" 2>/dev/null)" || pid=""
  case "$pid" in ''|*[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ] && _qa_alive "$pid"; then
    if [ ! -f "$d/started" ] || [ "$(_qa_pid_started "$pid")" = "$(cat "$d/started" 2>/dev/null)" ]; then
      root="$pid"
      [ -f "$d/pgid" ] && grp="$pid"
    fi
  elif [ -n "$pid" ] && [ -f "$d/pgid" ]; then
    # The leader is gone. A pid is not reused while its group has members, so these are ours.
    grp="$pid"
  fi

  while [ "$round" -lt "$rounds" ]; do
    round=$(( round + 1 ))
    holders="$(_qa_lane_holders "$d/ports" "$tool" | tr '\n' ' ')"
    plan="$(_qa_stop_plan "$root" "$grp" "$holders")"
    [ -n "$plan" ] || break
    sups="$(printf '%s\n' "$plan" | awk '$1 == "sup" { print $2 }')"
    liss="$(printf '%s\n' "$plan" | awk '$1 == "lis" { print $2 }')"
    got="$(_qa_kill_wait "$sups")"; [ -z "$got" ] || tried="$tried$got
"
    got="$(_qa_kill_wait "$liss")"; [ -z "$got" ] || tried="$tried$got
"
  done

  # Report from what is true NOW, not from what was signalled.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if _qa_alive "$p"; then alive="$alive $p"; else stopped="$stopped $p"; n=$(( n + 1 )); fi
  done <<EOF
$(printf '%s' "$tried" | sort -un)
EOF
  stopped="${stopped# }"; alive="${alive# }"
  if [ -n "$tool" ]; then
    held="$(_qa_lane_holders "$d/ports" "$tool" | tr '\n' ' ')"; held="${held% }"
    if [ -z "$held" ]; then freed=true; else freed=false; fi
  fi
  [ -z "$held" ] && [ -z "$alive" ] || rc=1

  emit_event op.done qa.stop "$(jq -cn --arg lane "$lane" --arg stopped "$stopped" --arg held "$held" \
    --argjson freed "$freed" --argjson ports "$(_qa_ports_json "$d/ports")" \
    '{lane: $lane, stopped: ($stopped | split(" ") | map(tonumber)), ports: $ports,
      held: ($held | split(" ") | map(tonumber)), freed: $freed}' 2>/dev/null)"

  if [ "$n" -eq 0 ]; then
    echo "[qa $lane] nothing stopped — no process of this lane was running" >&2
  else
    echo "[qa $lane] stopped $n process(es): $stopped" >&2
  fi
  if [ -n "$alive" ]; then
    echo "cckit qa: lane $lane — still running after KILL (not yours to signal?): $alive" >&2
  fi
  if [ -n "$held" ]; then
    echo "cckit qa: lane $lane is NOT down — still listening on its ports ($(cut -d= -f2 "$d/ports" 2>/dev/null | tr '\n' ' ')): pid $held" >&2
  elif [ -z "$tool" ]; then
    echo "[qa $lane] ports NOT checked — neither lsof nor ss is installed, so a listener outside the launched tree would go unseen" >&2
  else
    echo "[qa $lane] ports free: $(cut -d= -f2 "$d/ports" 2>/dev/null | tr '\n' ' ')" >&2
  fi
  if [ "${CCKIT_OUTPUT:-human}" = json ]; then
    jq -cn --arg lane "$lane" --arg stopped "$stopped" --arg held "$held" --argjson freed "$freed" \
      '{lane: $lane, stopped: ($stopped | split(" ") | map(tonumber)),
        held: ($held | split(" ") | map(tonumber)), freed: $freed}'
  fi
  # A lane that is down has no record: `ready` and `open` then say "never launched", which is true.
  [ "$rc" -eq 0 ] && rm -f "$d/pid" "$d/pgid" "$d/started" "$d/ports"
  return "$rc"
}

# ── the verdict: pass or fail against the commit that was reviewed (#299) ──────────────────────
#
# A verdict is a `qa` stage receipt (stage-receipt.sh) keyed by the lane number, and its head_sha
# is the commit the reviewer looked at. That one field is what makes it expire: the receipt is
# read back against the lane's head NOW, and any other commit reads `stale`. Nothing has to notice
# the push — the comparison fails on its own.
#
# The commit is resolved locally first, because the stack ran from a local checkout: `--head`,
# else the tip of the PR's branch as this repo has it, else the tip of the lane's own branch, else
# the head GitHub reports for the PR. When the PR's head on GitHub is a different commit the
# verdict is recorded anyway and the mismatch is said out loud — it reads stale against the PR
# until the reviewed commit is pushed.
#
# Three writes follow the receipt, in this order, and none of them can undo it:
#   the PR comment   one comment, upserted through pr_attach_evidence under the caption
#                    `QA verdict`, so a second verdict EDITS it. Each `--shot` file is one more
#                    upserted comment (`QA screenshot <n>`). pr-evidence.sh cannot upload a binary:
#                    a screenshot is a local path reference unless KIT_EVIDENCE_URL_BASE is set.
#   the mail         a FAIL sends its notes to the builder's branch with msg_send --steer, so the
#                    agent that built the change reads them between two tool calls.
#   the event        one `op.done qa.verdict` line.
# The receipt is not mirrored onto the issue: the PR comment is the GitHub copy, and a second
# comment on the lane's issue would say the same thing in another place.

# _qa_pr_meta <ref> — number, url, headRefOid, headRefName of the PR <ref> names, one per line.
# Best-effort: no gh, no PR, or an unreadable answer is rc 1 and prints nothing.
_qa_pr_meta() {
  local out=""
  [ -n "${1:-}" ] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  out="$(gh pr view "$1" --json number,url,headRefOid,headRefName \
           --jq '(.number | tostring), .url, .headRefOid, .headRefName' 2>/dev/null)" || return 1
  case "$(printf '%s\n' "$out" | sed -n 1p)" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$out"
}

# _qa_verdict_resolve <lane> [<pr>] [<head>] — set _QA_V_HEAD (the reviewed commit), _QA_V_PR,
# _QA_V_URL, _QA_V_PRHEAD and _QA_V_BRANCH (the builder's branch). Globals, not a tab-separated
# echo: an empty field between two tabs collapses under `read`. rc 2 when no commit can be named.
_qa_verdict_resolve() {
  local lane="$1" pr="${2:-}" head="${3:-}" branch="" meta="" tip=""
  _QA_V_HEAD=""; _QA_V_PR=""; _QA_V_URL=""; _QA_V_PRHEAD=""; _QA_V_BRANCH=""
  branch="$(_qa_lane_branch "$lane")"
  if meta="$(_qa_pr_meta "${pr:-$branch}")"; then
    _QA_V_PR="$(printf '%s\n' "$meta" | sed -n 1p)"
    _QA_V_URL="$(printf '%s\n' "$meta" | sed -n 2p)"
    _QA_V_PRHEAD="$(printf '%s\n' "$meta" | sed -n 3p)"
    _QA_V_BRANCH="$(printf '%s\n' "$meta" | sed -n 4p)"
  fi
  [ -n "$_QA_V_BRANCH" ] || _QA_V_BRANCH="$branch"
  if [ -n "$head" ]; then
    tip="$(git rev-parse --verify -q "$head^{commit}" 2>/dev/null)" || tip=""
    if [ -z "$tip" ]; then
      # A commit this clone does not have is still a commit: accept a full sha as written.
      printf '%s\n' "$head" | grep -qE '^[0-9a-f]{40}$' || {
        echo "cckit qa verdict: --head '$head' is not a commit here and not a full sha" >&2; return 2; }
      tip="$head"
    fi
  else
    [ -z "$_QA_V_BRANCH" ] || tip="$(git rev-parse --verify -q "refs/heads/$_QA_V_BRANCH^{commit}" 2>/dev/null)" || tip=""
    [ -n "$tip" ] || tip="$_QA_V_PRHEAD"
  fi
  [ -n "$tip" ] || {
    echo "cckit qa verdict: no commit to bind lane $lane to — no local branch carries issue $lane and no PR answered; pass --head <sha>" >&2
    return 2; }
  _QA_V_HEAD="$tip"
}

# qa_verdict_state <lane> [<head>] — echo how the lane's latest verdict reads against <head>:
# `pass` (rc 0) · `fail` · `stale` (recorded against another commit, or against none) · `none`
# (no verdict at all). Every answer but `pass` is rc 1. An empty <head> cannot be compared, so it
# reads `stale`: a verdict nobody can check against a commit is not a fresh one.
qa_verdict_state() {
  local lane="$1" head="${2:-}" got="" rhead="" gate=""
  got="$(sr_latest "$lane" qa 2>/dev/null)" || got=""
  [ -n "$got" ] || { printf 'none\n'; return 1; }
  rhead="$(printf '%s' "$got" | jq -r '.head_sha // ""' 2>/dev/null)"
  if [ -z "$head" ] || [ -z "$rhead" ] || [ "$rhead" != "$head" ]; then
    printf 'stale\n'; return 1
  fi
  gate="$(printf '%s' "$got" | jq -r '.gate // ""' 2>/dev/null)"
  gate="${gate%%[[:space:]]*}"
  [ "$gate" = pass ] && { printf 'pass\n'; return 0; }
  printf 'fail\n'; return 1
}

# qa_verdict <lane> <pass|fail> [<pr>] [<head>] [<notes>] [<to-branch>] [<shots>] — record the
# verdict, then upsert it onto the PR, mail a fail's notes to the builder, and emit one event.
# <shots> is one screenshot path per line. Echoes the receipt path (a JSON object under --llm).
#
# Everything that can refuse does so before the receipt is written: an unknown verdict, a fail
# with no notes, a screenshot that is not a file, a commit that cannot be named (all rc 2).
# rc 1 means the receipt IS written and a fail's notes reached no mailbox.
qa_verdict() {
  local lane="$1" verdict="${2:-}" pr="${3:-}" head="${4:-}" notes="${5:-}" to="${6:-}" shots="${7:-}"
  local one="" outcome="" gate="" blocker="" next="" url="" attempt="" prev="" rpath="" d="" file=""
  local comment="no-pr" mailed=false shot="" i=0 nshots=0 rc=0 target=""
  case "$verdict" in pass|fail) ;; *) echo "cckit qa verdict: the verdict is pass or fail, got '${verdict:-nothing}'" >&2; return 2 ;; esac
  command -v jq >/dev/null 2>&1 || { echo "cckit qa: jq is required" >&2; return 3; }
  one="$(printf '%s' "$notes" | tr '\r\n\t' '   ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
  if [ "$verdict" = fail ] && [ -z "$one" ]; then
    echo "cckit qa verdict: a fail needs its notes — --note \"<what is wrong>\" or --notes-file <file>. The builder gets nothing to act on otherwise." >&2
    return 2
  fi
  while IFS= read -r shot; do
    [ -n "$shot" ] || continue
    [ -f "$shot" ] || { echo "cckit qa verdict: --shot '$shot' is not a file" >&2; return 2; }
    nshots=$((nshots + 1))
  done <<EOF
$shots
EOF
  _qa_verdict_resolve "$lane" "$pr" "$head" || return $?
  head="$_QA_V_HEAD"

  url="${_QA_V_URL:--}"
  if [ "$verdict" = pass ]; then
    outcome="pr-open"; gate="pass"; blocker="none"; next="none"
  else
    outcome="blocked"; gate="fail — $one"; blocker="$one"; next="build"
  fi
  # The same verdict on the same commit rewrites its own attempt; anything else is a new one.
  attempt="$(sr_next_attempt "$lane" qa)" || return $?
  if _sr_same_as_latest "$lane" qa "$outcome" "$url" "$gate" "$blocker" "$next"; then
    prev="$(sr_latest "$lane" qa 2>/dev/null | jq -r '.head_sha // ""' 2>/dev/null)"
    [ "$prev" = "$head" ] && attempt=$((attempt - 1))
  fi
  rpath="$(printf 'outcome: %s\nurl: %s\ngate: %s\nblocker: %s\nnext stage: %s\n' \
             "$outcome" "$url" "$gate" "$blocker" "$next" \
           | sr_record "$lane" qa "$attempt" "" "" "cckit qa verdict" "read-only" "$head")" || return $?
  echo "[qa $lane] $verdict recorded against $head (attempt $attempt)" >&2
  if [ -n "$_QA_V_PRHEAD" ] && [ "$_QA_V_PRHEAD" != "$head" ]; then
    echo "[qa $lane] PR #$_QA_V_PR is at $_QA_V_PRHEAD on GitHub — this verdict reads stale against it until $head is pushed" >&2
  fi

  # The comment body carries no timestamp and no attempt number, so repeating a verdict is a
  # byte-identical edit and not timeline churn.
  if [ -n "$_QA_V_PR" ]; then
    d="$(qa_lane_dir "$lane")"; file="$d/verdict.txt"
    if mkdir -p "$d" 2>/dev/null; then
      {
        printf 'verdict: %s\ncommit:  %s\nlane:    %s\n' "$verdict" "$head" "$lane"
        [ -z "$notes" ] || printf '\nnotes:\n%s\n' "$notes"
        if [ "$nshots" -gt 0 ]; then
          printf '\nscreenshots (one comment each, below):\n'
          while IFS= read -r shot; do
            [ -n "$shot" ] || continue
            i=$((i + 1)); printf '  QA screenshot %s: %s\n' "$i" "$(basename "$shot")"
          done <<EOF
$shots
EOF
        fi
        printf '\nA push after %s makes this verdict stale.\n' "$head"
      } > "$file"
      pr_attach_evidence "$_QA_V_PR" "$file" "QA verdict"
      comment="${PR_EVIDENCE_LAST_RESULT:-post-failed}"
      i=0
      while IFS= read -r shot; do
        [ -n "$shot" ] || continue
        i=$((i + 1)); pr_attach_evidence "$_QA_V_PR" "$shot" "QA screenshot $i"
      done <<EOF
$shots
EOF
    else
      comment="post-failed"; echo "[qa $lane] cannot create $d — nothing posted to PR #$_QA_V_PR" >&2
    fi
  else
    echo "[qa $lane] no pull request found for lane $lane — the verdict is recorded locally and posted nowhere (--pr <n> names one)" >&2
  fi

  if [ "$verdict" = fail ]; then
    target="${to:-$_QA_V_BRANCH}"
    if [ -z "$target" ]; then
      echo "[qa $lane] no builder branch to mail — the notes reached nobody; name one with --to <branch>" >&2
      rc=1
    elif msg_send "$target" --steer "QA FAIL on $head (lane $lane${_QA_V_PR:+, PR #$_QA_V_PR}). Fix this before anything else:
$notes"; then
      mailed=true
    else
      echo "[qa $lane] the mail to $target was not written — the notes reached nobody" >&2
      rc=1
    fi
  fi

  emit_event op.done qa.verdict "$(jq -cn --arg lane "$lane" --arg verdict "$verdict" --arg head "$head" \
    --arg pr "$_QA_V_PR" --argjson attempt "$attempt" --arg comment "$comment" --argjson mailed "$mailed" \
    '{lane: $lane, verdict: $verdict, head: $head, pr: ($pr | tonumber? // null), attempt: $attempt,
      comment: $comment, mailed: $mailed}' 2>/dev/null)"
  if [ "${CCKIT_OUTPUT:-human}" = json ]; then
    jq -cn --arg lane "$lane" --arg verdict "$verdict" --arg head "$head" --arg pr "$_QA_V_PR" \
      --argjson attempt "$attempt" --arg receipt "$rpath" --arg comment "$comment" --argjson mailed "$mailed" \
      '{lane: $lane, verdict: $verdict, head: $head, pr: ($pr | tonumber? // null), attempt: $attempt,
        receipt: $receipt, comment: $comment, mailed: $mailed}'
  else
    printf '%s\n' "$rpath"
  fi
  return "$rc"
}

# qa_verdict_show <lane> [<pr>] [<head>] — print how the lane's verdict reads against its head
# now (qa_verdict_state's word; an object under --llm). rc 0 only for a fresh pass.
qa_verdict_show() {
  local lane="$1" state="" rc=0 got="" rhead=""
  command -v jq >/dev/null 2>&1 || { echo "cckit qa: jq is required" >&2; return 3; }
  _qa_verdict_resolve "$lane" "${2:-}" "${3:-}" || return $?
  state="$(qa_verdict_state "$lane" "$_QA_V_HEAD")" || rc=1
  got="$(sr_latest "$lane" qa 2>/dev/null)" || got=""
  rhead="$(printf '%s' "$got" | jq -r '.head_sha // ""' 2>/dev/null)"
  case "$state" in
    none)  echo "[qa $lane] no verdict recorded — cckit qa verdict <pass|fail>" >&2 ;;
    stale) echo "[qa $lane] the verdict was recorded against ${rhead:-no commit}; the lane is at $_QA_V_HEAD now — review it again" >&2 ;;
    *)     echo "[qa $lane] $state against $_QA_V_HEAD" >&2 ;;
  esac
  if [ "${CCKIT_OUTPUT:-human}" = json ]; then
    jq -cn --arg lane "$lane" --arg state "$state" --arg head "$_QA_V_HEAD" --arg rhead "$rhead" \
      '{lane: $lane, state: $state, head: $head, verdict_head: (if $rhead == "" then null else $rhead end)}'
  else
    printf '%s\n' "$state"
  fi
  return "$rc"
}

# qa_cli <args> — the `cckit qa` verb.
qa_cli() {
  # Every local gets a value: bin/cckit runs under `set -u`, and a bare `local x` is UNSET.
  local sub="${1:-}" lane="" limit="" pid="" d="" rc=0 pr="" route="" only=0 penv=""
  local verdict="" head="" notes="" nfile="" to="" shots=""
  case "$sub" in
    up|ready|open|stop|verdict) shift ;;
    ''|-h|--help|help)
      cat >&2 <<'EOF'
cckit qa up    [--lane <n>] [--timeout <s>]   launch the declared stack command with this lane's
                                              ports, then wait until every readiness probe answers
cckit qa ready [--lane <n>] [--timeout <s>]   wait on a lane that is already launched
cckit qa open  [--lane <n>] [--pr <n>] [--route </path>] [--port-env <NAME>] [--print]
                                              open the screen the change touched on a usable lane
cckit qa stop  [--lane <n>]                   stop the lane's stack: supervisors first, then
                                              whatever still listens on the lane's ports
cckit qa verdict <pass|fail> [--lane <n>] [--pr <n>] [--head <sha>] [--note <text>]
                 [--notes-file <file>] [--shot <file>]… [--to <branch>]
                                              record the verdict against the reviewed commit
cckit qa verdict [--lane <n>] [--pr <n>] [--head <sha>]
                                              read it back: pass · fail · stale · none

The lane is the issue number in the current branch, or --lane. Exit 0 only when the stack is
USABLE: every qa.readiness probe answered 2xx/3xx in one round (a redirect to sign-in is up).
Exit 1 names the launch log. Reads the `qa` block recorded by kit-add.sh qa.

open lands on http://localhost:<lane port><route>. The route is the `QA route: /path` line in the
lane's PR body (--pr picks another PR), else the configured qa.route; --route overrides both. The
port is the first qa.ports variable, or --port-env. A lane that is not usable right now is refused
(exit 1). --print prints the URL without opening a browser.

stop resolves who listens on each of the lane's ports (lsof, else ss) and stops the supervisors
before the listeners, so nothing respawns. It reports only the processes that are actually gone.
Exit 0 when the ports are free, including on a lane that was already down; exit 1 names the pid
still listening.

verdict writes a `qa` receipt (cckit receipt show <lane> qa) bound to the reviewed commit: --head,
else the local tip of the lane's branch, else the PR's head. It upserts ONE comment on the lane's
PR (a second verdict edits it) plus one per --shot; a screenshot is a path reference unless
KIT_EVIDENCE_URL_BASE is set, because gh cannot upload an image. A fail needs notes and mails them
to the builder's branch as a steer (--to names another branch); exit 1 when they reached nobody.
With no pass|fail it prints how the verdict reads against the lane's head now and exits 0 only for
a pass on that commit — a push since the verdict reads `stale`.
EOF
      return 2 ;;
    *) echo "cckit qa: unknown subcommand '$sub' — cckit qa <up|ready|open|stop|verdict>" >&2; return 2 ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --lane)      lane="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
      --lane=*)    lane="${1#*=}"; shift ;;
      --timeout)   limit="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
      --timeout=*) limit="${1#*=}"; shift ;;
      pass|fail)
        [ "$sub" = verdict ] && [ -z "$verdict" ] || { echo "cckit qa $sub: unknown argument '$1'" >&2; return 2; }
        verdict="$1"; shift ;;
      --head|--note|--notes-file|--shot|--to|--head=*|--note=*|--notes-file=*|--shot=*|--to=*)
        [ "$sub" = verdict ] || { echo "cckit qa $sub: '${1%%=*}' belongs to cckit qa verdict" >&2; return 2; }
        case "$1" in
          --head)         head="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --head=*)       head="${1#*=}"; shift ;;
          --note)         notes="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --note=*)       notes="${1#*=}"; shift ;;
          --notes-file)   nfile="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --notes-file=*) nfile="${1#*=}"; shift ;;
          --to)           to="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --to=*)         to="${1#*=}"; shift ;;
          --shot)         shots="$shots${2:-}
"; shift; [ "$#" -gt 0 ] && shift ;;
          --shot=*)       shots="$shots${1#*=}
"; shift ;;
        esac ;;
      --pr|--pr=*)
        case "$sub" in open|verdict) ;; *) echo "cckit qa $sub: '--pr' belongs to cckit qa open and verdict" >&2; return 2 ;; esac
        case "$1" in
          --pr)   pr="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --pr=*) pr="${1#*=}"; shift ;;
        esac ;;
      --route|--port-env|--print|--route=*|--port-env=*)
        [ "$sub" = open ] || { echo "cckit qa $sub: '${1%%=*}' belongs to cckit qa open" >&2; return 2; }
        case "$1" in
          --print)      only=1; shift ;;
          --route)      route="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --route=*)    route="${1#*=}"; shift ;;
          --port-env)   penv="${2:-}"; shift; [ "$#" -gt 0 ] && shift ;;
          --port-env=*) penv="${1#*=}"; shift ;;
        esac ;;
      *) echo "cckit qa $sub: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  lane="$(qa_lane_id "$lane")" || return $?
  if [ "$sub" = stop ]; then
    [ -z "$limit" ] || { echo "cckit qa stop: --timeout belongs to up and ready — the stop grace is QA_STOP_GRACE" >&2; return 2; }
    command -v jq >/dev/null 2>&1 || { echo "cckit qa: jq is required" >&2; return 3; }
    qa_stop "$lane"
    return $?
  fi
  if [ "$sub" = verdict ]; then
    [ -z "$limit" ] || { echo "cckit qa verdict: --timeout belongs to up and ready" >&2; return 2; }
    case "$pr" in *[!0-9]*) echo "cckit qa verdict: --pr takes a pull request number, got '$pr'" >&2; return 2 ;; esac
    if [ -z "$verdict" ]; then
      if [ -n "$notes$nfile$to$shots" ]; then
        echo "cckit qa verdict: say pass or fail to record one — notes, screenshots and --to belong to a recorded verdict" >&2
        return 2
      fi
      qa_verdict_show "$lane" "$pr" "$head"
      return $?
    fi
    if [ -n "$nfile" ]; then
      [ -z "$notes" ] || { echo "cckit qa verdict: --note and --notes-file are two sources for one text — pass one" >&2; return 2; }
      [ -f "$nfile" ] || { echo "cckit qa verdict: --notes-file '$nfile' is not a file" >&2; return 2; }
      notes="$(cat "$nfile")"
    fi
    qa_verdict "$lane" "$verdict" "$pr" "$head" "$notes" "$to" "$shots"
    return $?
  fi
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
