#!/usr/bin/env bash
# shellcheck shell=bash
# branch-owner-test.sh — the one-writer-per-branch lease (#323). Hermetic: a throwaway git repo and
# a KIT_STATE_DIR of its own, no network and no gh. Run:  bash scripts/lib/branch-owner-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc() { t "$1" "$2" "$3"; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo" && cd "$tmp/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
echo x > f && git add f && git commit -qm init

export KIT_STATE_DIR="$tmp/state"
# shellcheck source=/dev/null
. "$LIB/branch-owner.sh"

WT_A="$tmp/wt-a"; WT_B="$tmp/wt-b"; mkdir -p "$WT_A" "$WT_B"

# ── a first claim is granted, and the ledger says who holds it ─────────────────────────────────
bo_claim feat/1 agent-a "$WT_A" 2>/dev/null; rc "a free branch is claimable" "$?" "0"
t "the owner is recorded" "$(bo_owner feat/1)" "agent-a"
t "one live lease" "$(bo_list | wc -l | tr -d ' ')" "1"

# ── a SECOND owner on the same branch is refused, and the refusal names the holder ─────────────
err="$(bo_claim feat/1 agent-b "$WT_B" 2>&1 >/dev/null)"; second=$?
rc "a second owner is refused"        "$second" "3"
case "$err" in *agent-a*) echo "ok: the refusal names the current owner" ;; *) echo "FAIL: refusal did not name the owner -> '$err'"; fail=1 ;; esac
t "the refusal did not steal the lease" "$(bo_owner feat/1)" "agent-a"

# ── the same owner renews rather than colliding with itself ────────────────────────────────────
bo_claim feat/1 agent-a "$WT_A" 2>/dev/null; rc "the holder may re-claim (idempotent)" "$?" "0"
t "re-claiming does not duplicate the row" "$(bo_list | wc -l | tr -d ' ')" "1"

# ── different branches do not contend ──────────────────────────────────────────────────────────
bo_claim feat/2 agent-b "$WT_B" 2>/dev/null; rc "a different branch is independent" "$?" "0"
t "two live leases" "$(bo_list | wc -l | tr -d ' ')" "2"

# ── release is owner-scoped ────────────────────────────────────────────────────────────────────
bo_release feat/2 agent-a 2>/dev/null; rc "releasing someone else's lease is refused" "$?" "3"
t "and it stays held" "$(bo_owner feat/2)" "agent-b"
bo_release feat/2 agent-b 2>/dev/null; rc "the owner may release"  "$?" "0"
t "released leaves no owner" "$(bo_owner feat/2)" ""
bo_release feat/2 agent-b 2>/dev/null; rc "releasing an unheld branch is a no-op" "$?" "0"

# ── liveness: a lease whose worktree is gone is reclaimable ────────────────────────────────────
# Positive evidence the holder ended — cckit owns worktree creation and removal.
rm -rf "$WT_A"
t "a dead holder is not reported as owner" "$(bo_owner feat/1)" ""
bo_claim feat/1 agent-b "$WT_B" 2>/dev/null; rc "a dead holder's branch is claimable" "$?" "0"
t "the new owner holds it" "$(bo_owner feat/1)" "agent-b"

# ── liveness: a dead pid on THIS host is reclaimable ───────────────────────────────────────────
# Write the row directly so it names a pid that cannot be running. Same host, existing worktree —
# the pid is the only signal, which is exactly what this asserts.
dead=99999; while kill -0 "$dead" 2>/dev/null; do dead=$((dead + 1)); done
printf '%s\t%s\t%s\t%s\t%s\t%s\n' feat/3 ghost "$dead" "$(hostname 2>/dev/null || echo unknown)" "$WT_B" "$(date +%s)" >> "$(bo_file)"
t "a dead pid on this host is not an owner" "$(bo_owner feat/3)" ""
bo_claim feat/3 agent-b "$WT_B" 2>/dev/null; rc "a dead pid's branch is claimable" "$?" "0"

# ── a live row from ANOTHER host is NOT pid-reclaimed ──────────────────────────────────────────
# pids are not comparable across hosts; stealing a live remote worker's branch is the corruption
# this lib exists to prevent. It may expire on age, never on a pid check.
printf '%s\t%s\t%s\t%s\t%s\t%s\n' feat/4 remote "$dead" other-host "$WT_B" "$(date +%s)" >> "$(bo_file)"
t "a remote host's lease survives a dead-pid check" "$(bo_owner feat/4)" "remote"
bo_claim feat/4 agent-b "$WT_B" 2>/dev/null; rc "and it still refuses a second writer" "$?" "3"

# ── but it expires on age ──────────────────────────────────────────────────────────────────────
old=$(( $(date +%s) - 90000 ))
printf '%s\t%s\t%s\t%s\t%s\t%s\n' feat/5 stale "$dead" other-host "$WT_B" "$old" >> "$(bo_file)"
t "a lease past BO_LEASE_TTL is not an owner" "$(bo_owner feat/5)" ""
t "a longer TTL keeps it" "$(BO_LEASE_TTL=999999 bo_owner feat/5)" "stale"

# ── an empty pid means worktree-only liveness (what orchestrate relies on) ─────────────────────
# The launcher exits while its panes keep writing. Recording the launcher's own pid would have the
# lease reclaimed the instant it returns — the claim would enforce nothing.
WT_C="$tmp/wt-c"; mkdir -p "$WT_C"
( bo_claim feat/6 launcher "$WT_C" "" 2>/dev/null )   # subshell: its pid is gone afterwards
t "a pid-less lease survives its claimant exiting" "$(bo_owner feat/6)" "launcher"
bo_claim feat/6 other "$WT_C" "" 2>/dev/null; rc "and it still refuses a second writer" "$?" "3"
rm -rf "$WT_C"
t "removing the worktree releases it" "$(bo_owner feat/6)" ""


# ── reap compacts the ledger to live rows only ─────────────────────────────────────────────────
bo_reap; rc "reap succeeds" "$?" "0"
t "reap dropped the expired row" "$(grep -c 'stale' "$(bo_file)" 2>/dev/null || true)" "0"
t "reap kept the live remote row" "$(grep -c 'remote' "$(bo_file)" 2>/dev/null || true)" "1"

# ── a branch name with a slash survives the TSV round-trip ─────────────────────────────────────
bo_claim effort/318-agents-run-by-profile-in-herdr agent-c "$WT_B" 2>/dev/null
t "a slashed branch name round-trips" "$(bo_owner effort/318-agents-run-by-profile-in-herdr)" "agent-c"

# ── the ledger lock excludes: of eight simultaneous attempts exactly one wins (#449) ───────────
# The lock was `mkdir`, and the `mkdir` of uutils coreutils 0.10.0 (Ubuntu 26.04) exits 0 for the
# loser of a race, so two claimants held the lock together. Each process makes ONE attempt on the
# same path, released together by a start file; a check-then-create primitive reports several
# winners in most rounds.
L="$tmp/prim.lock"; go="$tmp/prim.go"; won="$tmp/prim.won"; lock_bad=0; r=0
while [ "$r" -lt 25 ]; do
  r=$((r+1)); rm -rf "$L" "$go"; : > "$won"; pids=""
  for k in 1 2 3 4 5 6 7 8; do
    (
      waited=0
      while [ ! -e "$go" ] && [ "$waited" -lt 20000 ]; do waited=$((waited+1)); done
      _bo_lock_try "$L" && echo "$k" >> "$won"
    ) &
    pids="$pids $!"
  done
  : > "$go"
  for pid in $pids; do wait "$pid"; done
  [ "$(grep -c . "$won")" = 1 ] || lock_bad=$((lock_bad+1))
done
t "the ledger lock has exactly one winner in each of 25 races" "$lock_bad" "0"
_bo_unlock "$L"; t "_bo_unlock removes the lock" "$([ -e "$L" ] && echo left || echo gone)" "gone"
# A cckit from before #449 leaves a lock DIRECTORY at the same path: it must still block.
mkdir "$L"; _bo_lock_try "$L"; rc "a lock directory from an older cckit still blocks" "$?" "1"
_bo_unlock "$L"; t "_bo_unlock removes an older lock directory" "$([ -e "$L" ] && echo left || echo gone)" "gone"

[ "$fail" -eq 0 ] && echo "ALL OK (branch-owner)" || echo "branch-owner: FAILURES"
exit "$fail"
