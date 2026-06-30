#!/usr/bin/env bash
# kit-gc.sh — the canonical "garbage-collect the repo" git-mechanic (#373 / #419 extraction).
#
# Plugin mirror of the canonical scripts/lib/kit-gc.sh (#370 self-contained). Same op, one home.
# Family 1 of kit-engine-boundary.md (rule #1/#2): ONE bash home for the gc op, consumed by the
# kit-gc skill, `kit gc`, and the kit-ui Run cockpit (#816 — it shells `scripts/kit gc`). No second
# implementation. This extracts the read-only ANALYSIS — branch/worktree/stash classification with
# the issue-open protection — out of the skill so a UI can run a REAL verb (not just preview text).
#
# The DESTRUCTIVE prune stays interactive (the skill / a human drives the confirmed deletes); a
# headless surface only ever runs the analysis. That split is deliberate: `kit_gc_analyze` is safe
# to run anywhere, anytime (it writes nothing), so the cockpit can flip its `gc` verb to runnable.
#
#   kit_gc_analyze            print the classification table (read-only). rc 0 always.
#   kit_gc_has_prunable       rc 0 if anything is safe to delete (for a UI badge / nudge).
#
# Requires: git; gh (degrades to "unknown" issue/PR state without it); scripts/lib/worktree-issue.sh.
# Portable: bash 3.2+ AND zsh.

KIT_GC_REPO="${KIT_GC_REPO:-${KIT_REPO:-}}"

_kit_gc_root() { git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}'; }

# Source worktree-issue.sh (wt_issue_number / wt_protected_reason) from whatever lib dir we live in.
_kit_gc_load_deps() {
  command -v wt_protected_reason >/dev/null 2>&1 && return 0
  local d; d="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
  # shellcheck source=/dev/null
  [ -f "$d/worktree-issue.sh" ] && . "$d/worktree-issue.sh"
}

# kit_gc_analyze — read-only classification of worktrees, branches, and stashes. Writes NOTHING.
# Each row is tagged PROTECTED / SAFE / ACTIVE / ORPHAN so a human or UI can decide what to prune.
kit_gc_analyze() {
  _kit_gc_load_deps
  local repo="$KIT_GC_REPO" b ref path reason pr prot
  git fetch origin --prune --quiet 2>/dev/null || true

  echo "# worktrees"
  git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch /{print w" "$2}' \
    | while read -r path ref; do
        b="${ref#refs/heads/}"
        reason="$(wt_protected_reason "$b" "$repo" 2>/dev/null || true)"
        if [ -n "$reason" ]; then echo "  $path [$b] -> PROTECTED: $reason"
        else echo "  $path [$b] -> prunable if PR merged"; fi
      done

  echo "# branches"
  for b in $(git branch --format='%(refname:short)' 2>/dev/null); do
    case "$b" in "${KIT_BASE_BRANCH:-main}"|develop|main) echo "  $b -> ACTIVE (base branch)"; continue;; esac
    pr="$(gh pr list --repo "$repo" --head "$b" --state all --json number,state --jq '.[0]|"PR#\(.number) \(.state)"' 2>/dev/null || true)"
    prot="$(wt_protected_reason "$b" "$repo" 2>/dev/null || true)"
    if [ -n "$prot" ]; then
      echo "  $b -> PROTECTED: $prot"
    elif printf '%s' "$pr" | grep -q 'MERGED'; then
      echo "  $b -> SAFE (${pr}, issue closed/absent — verify level with remote before delete)"
    elif printf '%s' "$pr" | grep -q 'OPEN'; then
      echo "  $b -> ACTIVE (${pr})"
    else
      echo "  $b -> ${pr:-ORPHAN (no PR — surface, never auto-delete)}"
    fi
  done

  echo "# stashes"
  git stash list 2>/dev/null | sed 's/^/  /' || true
}

# kit_gc_has_prunable — rc 0 if at least one branch is SAFE to delete (a merged, unprotected branch).
kit_gc_has_prunable() {
  kit_gc_analyze 2>/dev/null | grep -q '> SAFE '
}

# kit_gc_prune [--yes] - remove worktrees + local branches whose PR is MERGED (the SAFE rows).
# DRY-RUN by default (lists what it WOULD remove); --yes performs the deletions. Never touches a
# PROTECTED/ACTIVE/ORPHAN branch, and never a DIRTY worktree (recover-before-prune): a worktree with
# staged/unstaged/untracked changes is skipped with a warning, not destroyed. The remote branch is
# already deleted at merge time (gh pr merge --delete-branch); this cleans up the local side.
kit_gc_prune() {
  _kit_gc_load_deps
  local repo="$KIT_GC_REPO" yes=0 a path ref b pr
  for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; esac; done

  # Worktrees first - a branch's worktree must be removed before the branch can be deleted.
  git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch /{print w" "$2}' \
    | while read -r path ref; do
        b="${ref#refs/heads/}"
        case "$b" in "${KIT_BASE_BRANCH:-main}"|develop|main|"") continue ;; esac
        [ -n "$(wt_protected_reason "$b" "$repo" 2>/dev/null || true)" ] && continue
        pr="$(gh pr list --repo "$repo" --head "$b" --state all --json state --jq '.[0].state' 2>/dev/null || true)"
        [ "$pr" = "MERGED" ] || continue
        if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
          echo "  SKIP dirty worktree $path [$b] - commit/recover before pruning" >&2; continue
        fi
        if [ "$yes" -eq 1 ]; then
          git worktree remove --force "$path" 2>/dev/null && echo "  removed worktree $path [$b]"
        else
          echo "  would remove worktree $path [$b] (PR MERGED)"
        fi
      done
  git worktree prune 2>/dev/null || true

  # Then local branches whose PR merged (worktree now gone).
  for b in $(git branch --format='%(refname:short)' 2>/dev/null); do
    case "$b" in "${KIT_BASE_BRANCH:-main}"|develop|main) continue ;; esac
    [ -n "$(wt_protected_reason "$b" "$repo" 2>/dev/null || true)" ] && continue
    pr="$(gh pr list --repo "$repo" --head "$b" --state all --json state --jq '.[0].state' 2>/dev/null || true)"
    [ "$pr" = "MERGED" ] || continue
    if [ "$yes" -eq 1 ]; then
      git branch -D "$b" >/dev/null 2>&1 && echo "  deleted local branch $b (PR MERGED)"
    else
      echo "  would delete local branch $b (PR MERGED)"
    fi
  done
  [ "$yes" -eq 1 ] && echo "gc prune: done" || echo "gc prune: DRY RUN - pass --yes to delete"
}
