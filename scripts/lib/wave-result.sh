#!/usr/bin/env bash
# shellcheck shell=bash
# wave-result.sh — one collected result per worker of an orchestrated wave (E257.6, #263).
#
# `cckit orchestrate` used to return as soon as it had typed a command into each pane: nothing
# recorded how a worker ended, so a captain could not tell a finished worker from a crashed one
# without reading panes. This is the record. The launcher writes one file per issue before a pane
# starts, scripts/wave-worker.sh (the process the pane actually runs) updates it, and
# `cckit orchestrate --results` reads it back.
#
# A result is how the worker PROCESS ended, in three distinct terminal values:
#   success      the agent exited 0
#   failure      the agent exited 1-128
#   interrupted  the agent died on a signal (exit > 128), the wrapper caught HUP/INT/TERM, or the
#                record still says `running` while its pid is gone on the host that wrote it — a
#                killed pane or a SIGKILL leaves no chance to write a final state, so a dead pid IS
#                the evidence
# and three non-terminal ones: `launched` (the pane has not started the worker yet), `running`,
# and `untracked` (Herdr owns the agent process, so cckit has no exit status to collect).
#
# It is the same for every agent kind — claude, codex or any other CLI — because it reads the exit
# status of a process cckit started, not anything the agent says. What the worker CLAIMS it did is
# the stage receipt (stage-receipt.sh); the two are separate records and neither replaces the other.
#
# Records live under the shared state dir (kit-state.sh), so a worker in its own worktree and a
# captain in the main checkout read the same file. One `key<TAB>value` line per field.
#
#   wr_session_name <session>            the session name, reduced to a safe directory name
#   wr_dir <session>                     the session's record directory (does not create it)
#   wr_file <session> <issue>            one record's absolute path
#   wr_set <session> <issue> k=v …       create or update fields of one record (atomic rename)
#   wr_get <session> <issue> <key>       one field ("" when absent)
#   wr_classify_rc <exit-status>         success | failure | interrupted
#   wr_state <session> <issue>           the effective state (a dead `running` pid -> interrupted)
#   wr_rows <session>                    one "issue state rc agent runtime branch worktree" TSV row
#                                        per record, ordered by issue number
#   wr_pending <session>                 how many records are still launched or running
#   wr_clear <session>                   drop the session's records (a relaunch starts clean)
#
# bash 3.2 + zsh compatible: no arrays, and no glob held in a variable.
# errors: mixed — the readers are pure and answer "" for an absent record; wr_set returns 1 when
# the record directory cannot be created or the write fails.

_wr_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
# shellcheck source=/dev/null
command -v kit_state_dir >/dev/null 2>&1 || . "$_wr_dir/kit-state.sh"

wr_session_name() {
  local s; s="$(printf '%s' "${1:-orchestrate}" | tr -c 'A-Za-z0-9._-' '_')"
  printf '%s\n' "${s:-orchestrate}"
}

wr_dir() { printf '%s/wave/%s\n' "$(kit_state_dir)" "$(wr_session_name "${1:-}")"; }

wr_file() { printf '%s/%s.tsv\n' "$(wr_dir "${1:-}")" "${2:-}"; }

wr_set() {
  local session="${1:-}" issue="${2:-}" f d tmp kv
  [ -n "$issue" ] || { echo "wave-result: wr_set needs <session> <issue>" >&2; return 1; }
  shift 2
  f="$(wr_file "$session" "$issue")"; d="$(dirname "$f")"
  mkdir -p "$d" 2>/dev/null || { echo "wave-result: cannot create $d" >&2; return 1; }
  tmp="$f.$$.tmp"
  {
    [ -f "$f" ] && cat "$f"
    for kv in "$@"; do printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}"; done
  } | awk -F'\t' '
      NF < 1 || $1 == "" { next }
      !($1 in seen) { order[++n] = $1 }
      { seen[$1] = 1; v[$1] = $2 }
      END { for (i = 1; i <= n; i++) print order[i] "\t" v[order[i]] }' > "$tmp" \
    && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

wr_get() {
  local f; f="$(wr_file "${1:-}" "${2:-}")"
  [ -f "$f" ] || return 0
  awk -F'\t' -v k="${3:-}" '$1 == k { print $2; exit }' "$f"
}

wr_classify_rc() {
  case "${1:-}" in
    0) printf 'success\n' ;;
    ''|*[!0-9]*) printf 'failure\n' ;;
    *) if [ "$1" -gt 128 ]; then printf 'interrupted\n'; else printf 'failure\n'; fi ;;
  esac
}

# A `running` record is only as true as its process. The pid is checked on the host that wrote it
# and nowhere else: a pid number means nothing on another machine, so a record from a different
# host stays `running` rather than being declared dead on no evidence (branch-owner.sh, same rule).
wr_state() {
  local session="${1:-}" issue="${2:-}" st pid host
  st="$(wr_get "$session" "$issue" state)"
  if [ "$st" = "running" ]; then
    pid="$(wr_get "$session" "$issue" pid)"; host="$(wr_get "$session" "$issue" host)"
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    if [ -n "$pid" ] && [ "$host" = "$(hostname 2>/dev/null)" ] && ! kill -0 "$pid" 2>/dev/null; then
      st="interrupted"
    fi
  fi
  printf '%s\n' "$st"
}

wr_rows() {
  local session="${1:-}" d f issue
  d="$(wr_dir "$session")"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -type f -name '*.tsv' 2>/dev/null | while IFS= read -r f; do
    issue="$(basename "$f" .tsv)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$issue" "$(wr_state "$session" "$issue")" \
      "$(wr_get "$session" "$issue" rc)" "$(wr_get "$session" "$issue" agent)" \
      "$(wr_get "$session" "$issue" runtime)" "$(wr_get "$session" "$issue" branch)" \
      "$(wr_get "$session" "$issue" worktree)"
  done | sort -n
}

wr_pending() {
  wr_rows "${1:-}" | awk -F'\t' '$2 == "launched" || $2 == "running" { n++ } END { print n + 0 }'
}

wr_clear() {
  local d; d="$(wr_dir "${1:-}")"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -type f \( -name '*.tsv' -o -name '*.tmp' \) -exec rm -f {} + 2>/dev/null
  return 0
}
