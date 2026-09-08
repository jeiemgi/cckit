#!/usr/bin/env bash
# worktree-ports-test.sh — the per-worktree dev-port contract: a port is NEVER handed to two
# worktrees at once. Three separate defects lived here, all of which shipped silently because a
# wrong port looks exactly like a working one until a second lane starts.
#
#   1. CONFIG LAYOUT.  wt_assign_ports read only `<root>/.claude/kit.config.json`, while the sibling
#      `_wt_cfg` in the same file supported both layouts. In a self-hosting repo (root
#      `cckit.config.json` — cckit itself) the whole function was a silent no-op: it reported
#      nothing, wrote nothing, and the ports read as "assigned".
#
#   2. STRIDE == SERVICE COUNT.  port = base + (issue % 40) * <count>. With bases 3001/3003/3004 and
#      count 3, worktree offset k+1's admin port (3004+3k) IS worktree offset k's api port. Two
#      lanes, one port, on the second worktree of every wave.
#
#   3. HASH, NOT ALLOCATION.  `issue % 40` gives two issues 40 apart byte-identical ports. In a repo
#      numbering in the thousands that is routine (#1700 and #1740 in one wave). Slots are now
#      RECORDED under the git-common-dir, so uniqueness is by construction and an issue keeps its
#      slot for as long as its worktree lives.
#
# The bar: N worktrees over arbitrary issue numbers, in either config layout, produce N disjoint
# port sets — and re-running for a live issue never renumbers it.
#
# Run:  bash scripts/lib/worktree-ports-test.sh
# errors: strict — rc 1 on any failed assertion

set -uo pipefail
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=/dev/null
. "$dir/worktree-start.sh"

TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
fail=0; n=0
ok()  { n=$((n+1)); }
bad() { n=$((n+1)); echo "FAIL: $1"; fail=1; }

APPS="admin console api"

mk_project() { # <dir> <root|scaffold>
  local d="$1" layout="$2" cfg
  mkdir -p "$d"; git -C "$d" init -q 2>/dev/null
  if [ "$layout" = scaffold ]; then mkdir -p "$d/.claude"; cfg="$d/.claude/kit.config.json"
  else cfg="$d/cckit.config.json"; fi
  cat > "$cfg" <<'J'
{ "worktree": { "devPorts": [
    { "path": "apps/admin/.env.local",   "base": 3001 },
    { "path": "apps/console/.env.local", "base": 3003 },
    { "path": "apps/api/.env.local",     "base": 3004 } ] } }
J
}
mk_worktree() { local wt="$1" a; for a in $APPS; do mkdir -p "$wt/apps/$a"; : > "$wt/apps/$a/.env.local"; done; }
ports_of()    { local wt="$1" a; for a in $APPS; do grep -hE '^PORT=' "$wt/apps/$a/.env.local" 2>/dev/null | cut -d= -f2; done; }

# ── 1. both config layouts are read ───────────────────────────────────────────────────────────
for layout in root scaffold; do
  P="$TMP/$layout"; mk_project "$P" "$layout"
  W="$P/wt7"; mk_worktree "$W"
  wt_assign_ports "$W" 7 "$P" >/dev/null 2>&1
  got="$(ports_of "$W" | grep -c .)"
  [ "$got" = 3 ] && ok || bad "$layout layout: expected 3 ports written, got $got"
done

# ── 2 + 3. disjoint across worktrees, including the %40-apart pairs ───────────────────────────
P="$TMP/many"; mk_project "$P" scaffold
all=""
for num in 1 2 3 4 5 6 7 8 41 42 1700 1740; do
  W="$P/wt$num"; mk_worktree "$W"
  wt_assign_ports "$W" "$num" "$P" >/dev/null 2>&1
  for p in $(ports_of "$W"); do all="$all$p"$'\n'; done
done
total="$(printf '%s' "$all" | grep -c .)"
uniq_n="$(printf '%s' "$all" | sort -u | grep -c .)"
[ "$total" = 36 ] && ok || bad "expected 36 ports over 12 worktrees, got $total"
if [ "$total" = "$uniq_n" ]; then ok; else
  bad "port collision: $total ports but only $uniq_n distinct ($(printf '%s' "$all" | sort | uniq -d | tr '\n' ' '))"
fi

# ── 4. idempotent: a live issue keeps its slot ────────────────────────────────────────────────
W="$P/wt7"; before="$(ports_of "$W" | tr '\n' ' ')"
wt_assign_ports "$W" 7 "$P" >/dev/null 2>&1
after="$(ports_of "$W" | tr '\n' ' ')"
[ "$before" = "$after" ] && ok || bad "re-run renumbered a live lane: '$before' -> '$after'"

# ── 5. a freed slot is reclaimed, not leaked ──────────────────────────────────────────────────
slots="$(git -C "$P" rev-parse --git-common-dir 2>/dev/null)"
case "$slots" in /*) : ;; *) slots="$(cd "$P" && cd "$slots" && pwd)" ;; esac
rows_before="$(grep -c . "$slots/kit-portslots.tsv" 2>/dev/null || echo 0)"
rm -rf "$P/wt1"                       # that worktree is gone
W="$P/wt999"; mk_worktree "$W"
wt_assign_ports "$W" 999 "$P" >/dev/null 2>&1
rows_after="$(grep -c . "$slots/kit-portslots.tsv" 2>/dev/null || echo 0)"
[ "$rows_after" -le "$rows_before" ] && ok || bad "slot ledger grew instead of reclaiming ($rows_before -> $rows_after)"

echo "worktree-ports-test: $n assertion(s), $([ "$fail" = 0 ] && echo "all passed" || echo "FAILURES")"
exit "$fail"
