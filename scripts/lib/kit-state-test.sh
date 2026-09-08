#!/usr/bin/env bash
# kit-state-test.sh — the shared .cckit/ resolver (#280).
#
# The bug: state resolved CWD-relative (captain) or via `git rev-parse --show-toplevel` (handoff,
# secret-guard denylist). Inside a worktree --show-toplevel returns the WORKTREE root, so every
# worktree got its own .cckit/ and none saw the primary one — a handoff written in the main
# checkout read back as "no resume-here handoff saved" from any worktree, silently.
#
# These assertions run against real git worktrees in a temp dir; no network, no gh.
# errors: strict — rc = the number of failed assertions, so a broken resolver fails the gate

set -u
fail=0
t() { # t <name> <got> <want>
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=$((fail+1)); fi
}

LIB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=kit-state.sh
. "$LIB/kit-state.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# a real repo with a real linked worktree
git init -q "$TMP/repo"
git -C "$TMP/repo" config user.email s@e.test
git -C "$TMP/repo" config user.name s
printf 'x\n' > "$TMP/repo/f"; git -C "$TMP/repo" add f
git -C "$TMP/repo" commit -qm init
git -C "$TMP/repo" worktree add -q "$TMP/wt" -b side

# -P: on macOS /var is a symlink to /private/var, and the two entry paths canonicalize differently.
# That is a property of the temp dir, not of the resolver, so compare physical paths.
MAIN="$(cd "$TMP/repo" && pwd -P)"
canon() { ( cd "$(dirname "$1")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$(basename "$1")" ) || printf '%s' "$1"; }

# ── the resolver ──────────────────────────────────────────────────────────────────────────────────
got_main="$(canon "$(cd "$TMP/repo" && kit_state_dir)")"
got_wt="$(canon "$(cd "$TMP/wt" && kit_state_dir)")"
t "state dir from the primary checkout" "$got_main" "$MAIN/.cckit"
t "state dir from a worktree is the SAME"  "$got_wt"   "$MAIN/.cckit"
t "worktree does not get its own .cckit"   "$(cd "$TMP/wt" && kit_state_dir | grep -c '/wt/')" "0"

# --git-common-dir is relative (".git") at the primary checkout and absolute from a worktree; both
# must normalize to the same absolute root.
t "state file path is absolute" "$(cd "$TMP/wt" && kit_state_file captain.state | cut -c1)" "/"
# Composition only — the dir itself is asserted above. Deriving the expectation from kit_state_dir
# keeps this from re-testing path canonicalization on a directory that does not exist yet.
t "state file composes the name" \
  "$(cd "$TMP/repo" && kit_state_file captain.state)" \
  "$(cd "$TMP/repo" && kit_state_dir)/captain.state"

# ── ensure ────────────────────────────────────────────────────────────────────────────────────────
( cd "$TMP/wt" && kit_state_ensure )
t "ensure creates the shared dir from a worktree" "$([ -d "$MAIN/.cckit" ] && echo yes || echo no)" "yes"
t "ensure did not create a worktree-local dir"    "$([ -d "$TMP/wt/.cckit" ] && echo yes || echo no)" "no"

# ── the actual symptom: a handoff written in one place is visible from the other ──────────────────
# shellcheck source=handoff.sh
. "$LIB/handoff.sh"
( cd "$TMP/repo" && handoff_write "note from the primary checkout" >/dev/null 2>&1 )
got="$(cd "$TMP/wt" && handoff_read 2>/dev/null | grep -c 'note from the primary checkout')"
t "handoff written in the checkout is readable from a worktree" "$got" "1"

( cd "$TMP/wt" && handoff_write "note from the worktree" >/dev/null 2>&1 )
got="$(cd "$TMP/repo" && handoff_read 2>/dev/null | grep -c 'note from the worktree')"
t "handoff written in a worktree is readable from the checkout" "$got" "1"

# ── outside a git repo, fall back rather than fail ────────────────────────────────────────────────
mkdir -p "$TMP/bare"
got="$(cd "$TMP/bare" && kit_state_dir)"
case "$got" in */.cckit) t "outside a repo falls back to a .cckit path" ok ok ;;
                      *) t "outside a repo falls back to a .cckit path" "$got" "*/.cckit" ;; esac

# ── KIT_STATE_DIR override wins ───────────────────────────────────────────────────────────────────
t "absolute KIT_STATE_DIR is used verbatim" "$(cd "$TMP/repo" && KIT_STATE_DIR=/tmp/override kit_state_dir)" "/tmp/override"

# A relative override must anchor to the shared root, not the CWD — otherwise it recreates the
# per-worktree split this module removes.
rel_main="$(canon "$(cd "$TMP/repo" && KIT_STATE_DIR=.cckit-alt kit_state_dir)")"
rel_wt="$(canon "$(cd "$TMP/wt" && KIT_STATE_DIR=.cckit-alt kit_state_dir)")"
t "relative KIT_STATE_DIR anchors to the shared root" "$rel_main" "$MAIN/.cckit-alt"
t "relative KIT_STATE_DIR is the SAME from a worktree" "$rel_wt" "$MAIN/.cckit-alt"
t "relative override does not land in the worktree" \
  "$(cd "$TMP/wt" && KIT_STATE_DIR=.cckit-alt kit_state_dir | grep -c '/wt/')" "0"

[ "$fail" -eq 0 ] && echo "ALL OK (kit-state)" || echo "kit-state: FAILURES"
exit "$fail"
