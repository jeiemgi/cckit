#!/usr/bin/env bash
# shellcheck shell=bash
# branch-owner.sh — one writer per branch, enforced by a lease (#323).
#
# `rules/branch-naming.md` states the invariant: two agents sharing a branch's working tree, index
# and HEAD clobber each other, and git has no locking for it. Git refuses to check one branch out
# in two worktrees, which is NOT the same guarantee — it says nothing about two agent processes
# driving one worktree, or a second wave launching onto a branch a live worker is already pushing.
# `ap_profile_writes` (agent-profile.sh) declares whether a profile MAY write; this file decides
# which single claimant actually does, at any moment.
#
# The lease is a row in a TSV under the shared state dir, so every worktree of the repo reads the
# same ledger (kit-state.sh explains why `--git-common-dir`, not `--show-toplevel`).
#
#   <branch>\t<owner>\t<pid>\t<host>\t<worktree>\t<claimed-epoch>
#
# No field is ever written EMPTY. `read` with IFS=<tab> collapses runs of tabs, because tab is IFS
# whitespace — one blank field would shift every field after it by one, so a pid-less lease would
# parse its timestamp as the worktree path and read as dead. `-` is the absent marker.
#
# LIVENESS is what keeps a crashed worker from wedging a branch forever, and it is deliberately
# conservative — a lease is dropped only on POSITIVE evidence the holder is gone:
#   • the recorded worktree path no longer exists, or
#   • the row was written on THIS host and `kill -0 <pid>` says that pid is gone.
# A row from another host is never reclaimed on a pid check: pids are not comparable across hosts,
# and stealing a live remote worker's branch is the corruption this file exists to prevent. Such a
# row expires on age alone (BO_LEASE_TTL, default 24h) so a decommissioned host cannot wedge a
# branch permanently either.
#
#   bo_file                                  the ledger's absolute path
#   bo_claim <branch> <owner> [<wt>] [<pid>] take or renew the lease (empty <pid> = worktree liveness)
#   bo_release <branch> <owner>              give it up (only your own)
#   bo_owner <branch>                        echo the live owner, or nothing
#   bo_list                                  one `branch owner pid host worktree epoch` row per lease
#   bo_reap                                  drop every lease whose holder is provably gone
#
# Requires: git, awk. bash 3.2 compatible. No jq — this runs on the launch path, before a worktree
# exists, and must not add a dependency to it.
#
# errors: strict — a contested claim returns 3 and a caller must not launch; a state-dir failure
# returns 1. Silently succeeding here means two writers on one branch.

_bo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
command -v kit_state_dir >/dev/null 2>&1 || . "$_bo_dir/kit-state.sh"

BO_LEASE_TTL="${BO_LEASE_TTL:-86400}"   # seconds before a lease is considered expired outright
_BO_LOCK_WAIT="${_BO_LOCK_WAIT:-10}"    # seconds to wait for the ledger lock

bo_file() { kit_state_file branch-owners.tsv; }

_bo_now()  { date +%s 2>/dev/null || echo 0; }
_bo_host() { hostname 2>/dev/null || echo unknown; }

# _bo_lock / _bo_unlock — the same mkdir primitive the port-slot ledger uses (worktree-start.sh):
# a stock macOS has no flock(1), and `set -C` redirection is not atomic on every filesystem.
#
# Unlike the port lock, a caller that CANNOT lock here must NOT proceed. That lock guards an
# allocation whose worst case is a duplicate port; this one guards the answer to "is someone else
# writing this branch?", and answering it without the lock is how both claimants get a yes.
_bo_lock() {
  local d="$1" tries=0 max
  max=$(( _BO_LOCK_WAIT * 10 ))
  while [ "$tries" -lt "$max" ]; do
    mkdir "$d" 2>/dev/null && return 0
    sleep 0.1 2>/dev/null || sleep 1
    tries=$(( tries + 1 ))
  done
  # A lock directory older than a minute is abandoned: the age floor sits well above _BO_LOCK_WAIT,
  # so a slow-but-live holder is never stolen from.
  if [ -n "$(find "$d" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
    rm -rf "$d" 2>/dev/null
    mkdir "$d" 2>/dev/null && { echo "branch-owner: broke an abandoned ledger lock ($d)" >&2; return 0; }
  fi
  return 1
}
_bo_unlock() { rmdir "$1" 2>/dev/null || rm -rf "$1" 2>/dev/null; }

# _bo_alive <pid> <host> <worktree> — rc 0 when the lease holder may still be running.
_bo_alive() {
  local pid="$1" host="$2" wt="$3"
  [ "$pid" = "-" ] && pid=""
  [ "$wt" = "-" ] && wt=""
  # A recorded worktree that is gone is positive evidence: cckit owns worktree creation and removal,
  # so its absence means the flow ended.
  [ -n "$wt" ] && [ ! -d "$wt" ] && return 1
  # pids are only comparable on the host that wrote them.
  if [ "$host" = "$(_bo_host)" ] && [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null || return 1
  fi
  return 0
}

# _bo_rows_live <file> — echo the ledger keeping only rows whose holder is still alive and whose
# lease has not aged out. Pure read; the caller holds the lock and decides what to write.
_bo_rows_live() {
  local f="$1" now br ow pid host wt ts
  [ -f "$f" ] || return 0
  now="$(_bo_now)"
  while IFS="$(printf '\t')" read -r br ow pid host wt ts; do
    [ -n "$br" ] || continue
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    [ "$ts" -gt 0 ] && [ $(( now - ts )) -ge "$BO_LEASE_TTL" ] && continue
    _bo_alive "$pid" "$host" "$wt" || continue
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$br" "$ow" "$pid" "$host" "$wt" "$ts"
  done < "$f"
}

# bo_claim <branch> <owner> [<worktree>] [<pid>] — 0 when <owner> holds the lease on <branch>
# (taken fresh or renewed), 3 when a different LIVE owner holds it (named on stderr), 1 when the
# ledger is unwritable or the lock cannot be taken.
#
# <pid> defaults to this shell. Pass an EMPTY pid when the claimant is not the process that will
# keep writing: a launcher that hands each branch to a pane and then exits would otherwise record
# its own pid and have every lease reclaimed the moment it returns. With no pid, liveness rests on
# the worktree alone — the durable signal for a launched flow, since cckit owns worktree removal.
bo_claim() {
  local branch="${1:-}" owner="${2:-}" wt="${3:-}" pid="${4-$$}" f lock held_owner tmp
  [ -n "$branch" ] && [ -n "$owner" ] || { echo "bo_claim: <branch> and <owner> required" >&2; return 2; }
  kit_state_ensure || { echo "bo_claim: could not create the cckit state directory" >&2; return 1; }
  f="$(bo_file)"; lock="$f.lock"
  _bo_lock "$lock" || { echo "bo_claim: could not lock the branch-owner ledger ($lock)" >&2; return 1; }

  tmp="$(mktemp 2>/dev/null)" || { _bo_unlock "$lock"; echo "bo_claim: no temp file" >&2; return 1; }
  _bo_rows_live "$f" > "$tmp"

  held_owner="$(awk -F"\t" -v b="$branch" '$1==b {print $2; exit}' "$tmp" 2>/dev/null)"
  if [ -n "$held_owner" ] && [ "$held_owner" != "$owner" ]; then
    local held_wt
    held_wt="$(awk -F"\t" -v b="$branch" '$1==b {print $5; exit}' "$tmp" 2>/dev/null)"
    [ "$held_wt" = "-" ] && held_wt=""   # the absent marker is not a path to show a person
    rm -f "$tmp"; _bo_unlock "$lock"
    echo "bo_claim: '$branch' is already owned by '$held_owner'${held_wt:+ (worktree $held_wt)} — refusing a second writer" >&2
    return 3
  fi

  # Take it, or renew our own with a fresh pid/worktree/timestamp.
  awk -F"\t" -v b="$branch" '$1!=b' "$tmp" > "$tmp.keep" 2>/dev/null || : > "$tmp.keep"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$branch" "$owner" "${pid:--}" "$(_bo_host)" "${wt:--}" "$(_bo_now)" >> "$tmp.keep"
  mv "$tmp.keep" "$f" 2>/dev/null || { rm -f "$tmp" "$tmp.keep"; _bo_unlock "$lock"; echo "bo_claim: could not write $f" >&2; return 1; }
  rm -f "$tmp"
  _bo_unlock "$lock"
  return 0
}

# bo_release <branch> <owner> — 0 when the lease is gone (including when it was never held), 3 when
# it belongs to someone else and was left alone, 1 on a ledger failure.
bo_release() {
  local branch="${1:-}" owner="${2:-}" f lock held tmp
  [ -n "$branch" ] && [ -n "$owner" ] || { echo "bo_release: <branch> and <owner> required" >&2; return 2; }
  f="$(bo_file)"; [ -f "$f" ] || return 0
  lock="$f.lock"
  _bo_lock "$lock" || { echo "bo_release: could not lock the branch-owner ledger ($lock)" >&2; return 1; }
  held="$(awk -F"\t" -v b="$branch" '$1==b {print $2; exit}' "$f" 2>/dev/null)"
  if [ -n "$held" ] && [ "$held" != "$owner" ]; then
    _bo_unlock "$lock"
    echo "bo_release: '$branch' is owned by '$held', not '$owner' — left alone" >&2
    return 3
  fi
  tmp="$(mktemp 2>/dev/null)" || { _bo_unlock "$lock"; return 1; }
  awk -F"\t" -v b="$branch" '$1!=b' "$f" > "$tmp" 2>/dev/null || : > "$tmp"
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; _bo_unlock "$lock"; return 1; }
  _bo_unlock "$lock"
  return 0
}

# bo_owner <branch> — echo the live owner's name, or nothing. Read-only: it never reaps, so a
# caller can ask without changing state.
bo_owner() {
  local branch="${1:-}" f
  [ -n "$branch" ] || return 2
  f="$(bo_file)"; [ -f "$f" ] || return 0
  _bo_rows_live "$f" | awk -F"\t" -v b="$branch" '$1==b {print $2; exit}'
}

# bo_list — every live lease, one row per line.
bo_list() {
  local f; f="$(bo_file)"; [ -f "$f" ] || return 0
  _bo_rows_live "$f"
}

# bo_reap — compact the ledger to its live rows. Claim and release already skip dead rows, so this
# is housekeeping (gc), not a correctness step.
bo_reap() {
  local f lock tmp
  f="$(bo_file)"; [ -f "$f" ] || return 0
  lock="$f.lock"
  _bo_lock "$lock" || return 1
  tmp="$(mktemp 2>/dev/null)" || { _bo_unlock "$lock"; return 1; }
  _bo_rows_live "$f" > "$tmp"
  mv "$tmp" "$f" 2>/dev/null || { rm -f "$tmp"; _bo_unlock "$lock"; return 1; }
  _bo_unlock "$lock"
  return 0
}
