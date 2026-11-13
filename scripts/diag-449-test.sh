#!/usr/bin/env bash
# diag-449-test.sh — TEMPORARY (#449): section 6 of worktree-ports-test.sh in a loop on the CI
# runner, with every lock and allocation event logged. Removed before this PR is ready.
set -uo pipefail
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$dir/lib/worktree-start.sh"
eval "$(declare -f _wt_lock | sed '1s/_wt_lock/_o_wt_lock/')"
eval "$(declare -f _wt_unlock | sed '1s/_wt_unlock/_o_wt_unlock/')"
eval "$(declare -f _wt_slot_alloc | sed '1s/_wt_slot_alloc/_o_wt_slot_alloc/')"
ev() { printf '%s %s %s\n' "$(date +%s.%N)" "$BASHPID" "$*" >> "$DLOG"; }
_wt_lock()   { local rc; ev "lock-try"; _o_wt_lock "$@"; rc=$?; ev "lock rc=$rc"; return $rc; }
_wt_unlock() { ev "unlock"; _o_wt_unlock "$@"; }
_wt_slot_alloc() { local o; ev "alloc-in num=$2 ledger=[$(cut -f1,2 "$1" 2>&1 | tr '\t\n' ': ')]"; o="$(_o_wt_slot_alloc "$@")"; ev "alloc-out num=$2 slot=$o ledger=[$(cut -f1,2 "$1" 2>&1 | tr '\t\n' ': ')]"; printf '%s' "$o"; }
lines_in() { local c; c="$(grep -c . "$1" 2>/dev/null)"; [ -n "$c" ] || c=0; printf '%s' "$c"; }
echo "env: $(uname -srm) nproc=$(nproc 2>/dev/null) TMPDIR=${TMPDIR:-unset} _WT_LOCK_WAIT=$_WT_LOCK_WAIT"
echo "env: $(type mkdir rmdir sleep mktemp mv awk 2>&1 | tr '\n' ';')"
echo "env: tmpfs=$(stat -f -c %T /tmp 2>/dev/null) sigpipe=$(trap -p PIPE) $(grep SigIgn /proc/$$/status 2>/dev/null)"
APPS="admin console api"; fails=0; it=0; ITERS="${DIAG_ITERS:-150}"
while [ "$it" -lt "$ITERS" ]; do
  it=$((it+1))
  P="$(mktemp -d)"; git -C "$P" init -q 2>/dev/null; mkdir -p "$P/.claude"; DLOG="$P/dlog"
  printf '%s' '{ "worktree": { "devPorts": [ {"path":"apps/admin/.env.local","base":3001},{"path":"apps/console/.env.local","base":3003},{"path":"apps/api/.env.local","base":3004} ] } }' > "$P/.claude/kit.config.json"
  barrier="$P/.barrier"; : > "$barrier"; pids=""
  for num in 101 102 103 104 105 106 107 108; do
    W="$P/wt$num"; for a in $APPS; do mkdir -p "$W/apps/$a"; : > "$W/apps/$a/.env.local"; done
    (
      echo ready >> "$barrier"; waited=0
      while [ "$(lines_in "$barrier")" -lt 8 ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited+1)); done
      ev "start num=$num"
      wt_assign_ports "$W" "$num" "$P" >/dev/null 2>"$P/err.$num"
      ev "done num=$num port=$(grep -h '^PORT=' "$W/apps/admin/.env.local" | tr '\n' ' ')"
    ) &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid"; done
  dup="$(grep -h '^PORT=' "$P"/wt*/apps/admin/.env.local | sort | uniq -d | tr '\n' ' ')"
  if [ -n "$dup" ] || [ "$(lines_in "$P/.git/kit-portslots.tsv")" != 8 ] || grep -q . "$P"/err.* 2>/dev/null && grep -qv 'PORT=' "$P"/err.* 2>/dev/null; then
    fails=$((fails+1))
    echo "=== iteration $it: dup=[$dup]"; echo "-- ledger"; cat "$P/.git/kit-portslots.tsv"
    echo "-- stderr"; grep -hv 'PORT=' "$P"/err.* 2>/dev/null
    echo "-- events"; sort -n "$DLOG"
  fi
  rm -rf "$P"
done
echo "diag-449: $fails anomalous iteration(s) of $ITERS"
[ "$fails" = 0 ]
