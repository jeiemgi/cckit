#!/usr/bin/env bash
# shellcheck shell=bash
# session-registry.sh — which live session is working which issue (#384).
#
# `git worktree add` refuses one branch in two worktrees. It cannot see a session in ANOTHER
# checkout, or a second agent started on the same issue from the same checkout a moment later:
# both get a "reusing worktree" success and then write the same tree. This file is the record
# wt_start (worktree-start.sh) consults before it fetches or creates anything.
#
# One JSON file per claimed issue, under the shared git dir so every worktree reads the same set:
#
#   <git-common-dir>/kit-sessions/issue-<N>.json
#   {"issue":N,"branch":"…","worktree":"…","cwd":"…","pid":P,"pstart":"…","host":"…","started":EPOCH}
#
# `cwd` repeats `worktree` on purpose: `_wt_session_owns` (worktree-start.sh) already reads `.pid`
# and `.cwd` from every non-`cache-*` JSON file in this directory, so a claim written here also
# keeps the worktree pool from recycling a tree its session is still using.
#
# WHICH PID. Neither `cckit start`'s own pid nor the shell that ran it outlives the call when an
# agent runs each command in a fresh shell. The claim records the SESSION: `KIT_SESSION_PID` when
# set, else the nearest ancestor that is not a throwaway shell — the agent process, or the
# terminal's own login/tty shell for a person. See sreg_session_pid.
#
# LIVENESS drops a claim only on positive evidence its session is gone:
#   • written on THIS host and the pid is dead, or alive with a different start time (pid reuse);
#   • its worktree no longer exists and the claim is older than SREG_GRACE seconds (the grace covers
#     the window between writing the claim and `git worktree add` creating the directory).
# A claim from another host is never dropped on a pid check — pids do not compare across hosts.
#
#   sreg_dir <root>                              the registry directory (not created)
#   sreg_session_pid                             the pid a claim written now would record
#   sreg_issue_claim <root> <issue>              reap a dead claim; print the live one as TSV, rc 1 if none
#   sreg_claim_mine <root> <issue>               rc 0 when the live claim is this session's own
#   sreg_claim <root> <issue> <branch> <wt> [force]   take the claim; rc 3 when another session holds it
#   sreg_release <root> <issue>                  drop this session's own claim
#   sreg_reap <root>                             drop every claim whose session is provably gone
#   sreg_list <root> [--json]                    live claims; READ-ONLY, never reaps
#
# TSV row: <issue>\t<branch>\t<worktree>\t<pid>\t<host>\t<started-epoch>. No field is ever empty
# (`-` is the absent marker): tab is IFS whitespace, so an empty field would shift the rest.
#
# Requires: git, jq, ps. bash 3.2 compatible; runs under zsh (no glob held in a variable, no
# `status`/`path` variable names).
# errors: strict — a contested claim returns 3 and the caller must not start; an unwritable
# registry returns 1 and the caller decides whether to go on without a claim.

SREG_GRACE="${SREG_GRACE:-300}"   # seconds a claim may name a worktree that does not exist yet

_sreg_now()  { date +%s 2>/dev/null || echo 0; }
_sreg_host() { hostname 2>/dev/null || echo unknown; }

# _sreg_pstart <pid> — the process start time as ps prints it, or nothing. Compared verbatim, so it
# only has to be stable for one process on one host.
_sreg_pstart() { ps -o lstart= -p "$1" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

sreg_dir() {
  local common
  common="$(git -C "${1:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ -n "$common" ] || return 1
  printf '%s/kit-sessions' "$common"
}

_sreg_file() {
  local d
  [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || return 1
  d="$(sreg_dir "$1")" || return 1
  printf '%s/issue-%s.json' "$d" "$2"
}

# sreg_session_pid — the long-lived process this start belongs to.
#   1. KIT_SESSION_PID, when it is a pid — the explicit override (a harness that knows its own).
#   2. Walking up from this shell's parent: the first ancestor that is NOT a shell (the agent
#      process), or a shell that is the terminal's own — a login shell (`-zsh`), or one whose
#      parent does not share its controlling tty. Intermediate `sh -c` / script shells are skipped.
#   3. The last ancestor reached before pid 1, when nothing above matched.
sreg_session_pid() {
  local cur="${PPID:-0}" comm base tty ptty parent hops=0
  if [[ "${KIT_SESSION_PID:-}" =~ ^[1-9][0-9]*$ ]]; then printf '%s' "$KIT_SESSION_PID"; return 0; fi
  [[ "$cur" =~ ^[1-9][0-9]*$ ]] || { printf '%s' "$$"; return 0; }
  while [ "$hops" -lt 16 ]; do
    hops=$((hops + 1))
    comm="$(ps -o comm= -p "$cur" 2>/dev/null | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$comm" ] || break
    parent="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d '[:space:]')"
    case "$comm" in -*) break ;; esac
    base="${comm##*/}"
    case "$base" in
      sh|bash|zsh|dash|ksh|fish|env|timeout|gtimeout|sudo|nohup|cckit|kit) ;;
      *) break ;;
    esac
    [[ "$parent" =~ ^[0-9]+$ ]] && [ "$parent" -gt 1 ] || break
    tty="$(ps -o tty= -p "$cur" 2>/dev/null | tr -d '[:space:]')"
    ptty="$(ps -o tty= -p "$parent" 2>/dev/null | tr -d '[:space:]')"
    case "$tty" in ''|'?'|'??') ;; *) [ "$tty" = "$ptty" ] || break ;; esac
    cur="$parent"
  done
  printf '%s' "$cur"
}

# _sreg_row <file> — the claim as one TSV row plus a trailing <pstart> field, or rc 1 if unreadable.
_sreg_row() {
  [ -f "$1" ] || return 1
  jq -r '[(.issue // 0), (.branch // "" | if . == "" then "-" else . end),
          (.worktree // "" | if . == "" then "-" else . end), (.pid // 0),
          (.host // "" | if . == "" then "-" else . end), (.started // 0),
          (.pstart // "" | if . == "" then "-" else . end)] | @tsv' "$1" 2>/dev/null
}

# _sreg_live <file> — rc 0 while the claim's session is not provably gone. Pure: deletes nothing.
_sreg_live() {
  local row issue branch wt opid host started pstart now
  row="$(_sreg_row "$1")" || return 1
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r issue branch wt opid host started pstart <<EOF
$row
EOF
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  if [ "$host" = "$(_sreg_host)" ]; then
    [[ "$opid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$opid" 2>/dev/null || return 1
    if [ "$pstart" != "-" ] && [ "$(_sreg_pstart "$opid")" != "$pstart" ]; then return 1; fi
  fi
  if [ "$wt" != "-" ] && [ ! -d "$wt" ]; then
    now="$(_sreg_now)"
    [[ "$started" =~ ^[0-9]+$ ]] || started=0
    [ $((now - started)) -le "$SREG_GRACE" ] || return 1
  fi
  return 0
}

# _sreg_files <root> — every claim file, one absolute path per line.
_sreg_files() {
  local d f
  d="$(sreg_dir "$1")" || return 0
  [ -d "$d" ] || return 0
  ls "$d" 2>/dev/null | grep -E '^issue-[1-9][0-9]*\.json$' | while IFS= read -r f; do
    printf '%s/%s\n' "$d" "$f"
  done
}

# sreg_issue_claim <root> <issue> — print the live claim's TSV row (rc 0), or reap a dead one and
# return 1. This is the write-capable read wt_start uses; sreg_list is the read-only one.
sreg_issue_claim() {
  local f row
  f="$(_sreg_file "$1" "${2:-}")" || return 1
  [ -f "$f" ] || return 1
  if ! _sreg_live "$f"; then rm -f "$f" 2>/dev/null; return 1; fi
  row="$(_sreg_row "$f")" || return 1
  printf '%s\n' "${row%	*}"
}

# sreg_claim_mine <root> <issue> — the live claim belongs to this session: same host and session
# pid, or the caller is standing inside the claimed worktree (re-running start from the worktree
# the claim names is the claimant by construction, whatever shell it runs in).
sreg_claim_mine() {
  local row issue branch wt opid host started here
  row="$(sreg_issue_claim "$1" "${2:-}")" || return 1
  IFS=$'\t' read -r issue branch wt opid host started <<EOF
$row
EOF
  if [ "$host" = "$(_sreg_host)" ] && [ "$opid" = "$(sreg_session_pid)" ]; then return 0; fi
  if [ "$wt" != "-" ] && [ -d "$wt" ]; then
    here="$(pwd -P 2>/dev/null)"; wt="$(cd "$wt" 2>/dev/null && pwd -P)"
    case "$here" in "$wt"|"$wt"/*) return 0 ;; esac
  fi
  return 1
}

# sreg_claim <root> <issue> <branch> <worktree> [force] — take the claim for this session.
#   rc 0  claimed (or already this session's — the existing record is left untouched)
#   rc 3  another live session holds it and force is not 1 — nothing written
#   rc 1  the registry could not be written
# The first writer wins by `ln`, which fails when the target exists — atomic without a lock.
sreg_claim() {
  local root="$1" issue="${2:-}" branch="${3:-}" wt="${4:-}" force="${5:-0}" d f tmp spid
  f="$(_sreg_file "$root" "$issue")" || return 1
  d="${f%/*}"
  mkdir -p "$d" 2>/dev/null || return 1
  if sreg_issue_claim "$root" "$issue" >/dev/null; then
    sreg_claim_mine "$root" "$issue" && return 0
    [ "$force" = "1" ] || return 3
  fi
  spid="$(sreg_session_pid)"
  tmp="$d/.issue-$issue.$$.tmp"
  jq -n --argjson issue "$issue" --arg branch "$branch" --arg wt "$wt" --argjson pid "$spid" \
        --arg pstart "$(_sreg_pstart "$spid")" --arg host "$(_sreg_host)" --argjson started "$(_sreg_now)" \
    '{issue:$issue, branch:$branch, worktree:$wt, cwd:$wt, pid:$pid, pstart:$pstart, host:$host, started:$started}' \
    > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  if [ "$force" = "1" ]; then
    mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
  fi
  if ln "$tmp" "$f" 2>/dev/null; then rm -f "$tmp" 2>/dev/null; return 0; fi
  rm -f "$tmp" 2>/dev/null
  # Lost the race to a claim written between the check and the link.
  [ -f "$f" ] && return 3
  return 1
}

# sreg_release <root> <issue> — drop the claim, but only this session's own.
sreg_release() {
  local f
  f="$(_sreg_file "$1" "${2:-}")" || return 1
  [ -f "$f" ] || return 0
  sreg_claim_mine "$1" "$2" || return 1
  rm -f "$f" 2>/dev/null
}

# sreg_reap <root> — drop every claim whose session is provably gone.
sreg_reap() {
  local f
  _sreg_files "$1" | while IFS= read -r f; do
    _sreg_live "$f" || rm -f "$f" 2>/dev/null
  done
  return 0
}

# sreg_list <root> [--json] — the live claims. Read-only: a dead claim is skipped, never deleted.
#   default: one TSV row per claim · --json: one JSON array of the claim records.
sreg_list() {
  local root="${1:-.}" mode="${2:-}" f row
  if [ "$mode" = "--json" ]; then
    _sreg_files "$root" | while IFS= read -r f; do
      _sreg_live "$f" && jq -c 'del(.pstart)' "$f" 2>/dev/null
    done | jq -s -c 'sort_by(.issue)'
    return 0
  fi
  _sreg_files "$root" | while IFS= read -r f; do
    _sreg_live "$f" || continue
    row="$(_sreg_row "$f")" || continue
    printf '%s\n' "${row%	*}"
  done | sort -n
}
