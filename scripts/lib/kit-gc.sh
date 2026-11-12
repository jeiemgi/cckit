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
#   kit_gc_has_prunable       rc 0 if anything is SAFE or LANDED to delete (for a UI badge / nudge).
#   kit_gc_prune [--yes] [--only <regex>]   delete the SAFE + LANDED rows (dry-run without --yes).
#   kit_gc_cleanup [--yes]    the guided sweep: plan every bucket, then act on SAFE + LANDED + ZOMBIE.
#
# Verdicts: PROTECTED (issue open) · SAFE (own PR merged) · ACTIVE (own PR open / base) · LANDED (no
# PR of its own, work already on base — #388: effort subs, agent isolation worktrees) · ORPHAN ·
# UNKNOWN (a gh read FAILED, so the verdict could not be determined — #330; never deletable).
# A DETACHED worktree has no branch to classify, so it gets its own row (#390): LANDED when it is
# clean and its HEAD is already on the base branch or `main`, ORPHAN otherwise.
#
# Requires: git; gh (degrades to "unknown" issue/PR state without it); scripts/lib/worktree-issue.sh.
# Portable: bash 3.2+ AND zsh.
# errors: mixed — kit_gc_analyze is read-only and forgiving; the prune path propagates

# The GitHub transport switch (#396): rest mode routes the gh calls below through gh-rest.sh.
if ! command -v cckit_gh_rest >/dev/null 2>&1; then
  _ghr_lib="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)/gh-rest.sh"
  # shellcheck source=/dev/null
  [ -f "$_ghr_lib" ] && . "$_ghr_lib"
  unset _ghr_lib
fi
command -v cckit_gh_rest >/dev/null 2>&1 || cckit_gh_rest() { return 1; }

KIT_GC_REPO="${KIT_GC_REPO:-${KIT_REPO:-}}"

_kit_gc_root() { git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2; exit}'; }

# This file's own directory, resolved ONCE at load time — the only point where both shells agree.
# `BASH_SOURCE` is bash-only; inside a zsh *function* it is unset and `$0` is the function name, so
# the old per-call resolution fell back to `$0`="zsh", worktree-issue.sh was never sourced,
# `wt_protected_reason` stayed undefined, and every call site's `2>/dev/null || true` turned the
# resulting "command not found" into an empty reason — i.e. an open issue's branch classified as
# SAFE to delete. At FILE scope zsh sets `$0` to the sourced file's path, so one expansion covers
# bash (source or direct exec) and zsh (interactive or not) with no shell-specific syntax. Prompt
# expansion (`${(%):-%x}`) is deliberately avoided: it is zsh-only, needs `eval` to stay parseable
# under bash, and is unreliable in an INTERACTIVE zsh — the kit's own shell.
#
# `cd`'s own stdout is discarded, not just its stderr: an interactive zsh ECHOES the new directory
# (tilde-abbreviated) after a `cd`, so the bare `$(cd … && pwd)` idiom captured TWO lines and the
# resulting path never existed. `pwd` still writes to the substitution.
_KIT_GC_LIB_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

# Source worktree-issue.sh (wt_issue_number / wt_protected_reason) from the lib dir we live in.
_kit_gc_load_deps() {
  command -v wt_protected_reason >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  [ -n "${_KIT_GC_LIB_DIR:-}" ] && [ -f "$_KIT_GC_LIB_DIR/worktree-issue.sh" ] \
    && . "$_KIT_GC_LIB_DIR/worktree-issue.sh"
  command -v wt_protected_reason >/dev/null 2>&1
}

# Fail LOUD if the protection helper could not be loaded. Without it every issue-open check
# silently returns empty and gc would offer to delete in-progress work — a wrong "safe" is far
# worse than a refusal, so callers must not proceed on a degraded analysis.
_kit_gc_require_deps() {
  _kit_gc_load_deps || :   # never let a load failure abort a `set -e` caller before the FATAL prints
  command -v wt_protected_reason >/dev/null 2>&1 && return 0
  echo "kit-gc: FATAL — worktree-issue.sh not loaded; issue-open protection is unavailable." >&2
  echo "kit-gc: refusing to classify branches: everything would look SAFE to delete." >&2
  return 1
}

# _kit_gc_pr_index [repo] — echo one "<headRefName>\tPR#<num> <STATE>" line per PR in ONE gh call, so
# branch classification is a local lookup instead of a per-branch `gh pr list --head` — an N+1 that
# scaled badly exactly when gc matters most (many stale branches). #124.
#
# A FAILED read is not an empty list (#330): an empty index means "this repo has no PRs", and every
# branch then reads as having none. So a failure warns on stderr and emits ONE sentinel line,
# `?<TAB>UNKNOWN` — `?` cannot be a branch name (git refuses it), so no lookup ever matches it — and
# _kit_gc_classify answers UNKNOWN instead of ORPHAN/LANDED for a branch it finds no PR for. rc 0
# always: kit-status.sh calls this in a bare assignment under `set -e`.
_kit_gc_pr_index() {
  local repo="${1:-$KIT_GC_REPO}" out
  if cckit_gh_rest; then
    out="$(gh api "repos/$repo/pulls" -X GET -f state=all -f per_page=100 \
      --jq '.[] | "\(.head.ref)\tPR#\(.number) \(if .merged_at then "MERGED" else (.state | ascii_upcase) end)"' 2>/dev/null)" \
      || { _kit_gc_pr_index_failed; return 0; }
  else
    out="$(gh pr list --repo "$repo" --state all --limit 200 --json number,state,headRefName \
      --jq '.[] | "\(.headRefName)\tPR#\(.number) \(.state)"' 2>/dev/null)" \
      || { _kit_gc_pr_index_failed; return 0; }
  fi
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

_kit_gc_pr_index_failed() {
  echo "kit-gc: could not read the PR list from GitHub (gh failed) — a branch whose PR is not known is reported UNKNOWN and kept" >&2
  printf '?\tUNKNOWN\n'
}

# _kit_gc_pr_index_unknown <index> — rc 0 when <index> carries the failed-read sentinel.
_kit_gc_pr_index_unknown() {
  printf '%s\n' "$1" | grep -q "^?$(printf '\t')UNKNOWN\$"
}

# _kit_gc_pr_for <index> <branch> — first PR line matching <branch> as head (mirrors the old `.[0]`).
_kit_gc_pr_for() {
  printf '%s\n' "$1" | awk -F'\t' -v want="$2" '$1==want{print $2; exit}'
}

# _kit_gc_base_ref — the ref the LANDED checks compare against: `origin/<base>` when that
# remote-tracking ref exists (the merge target), else the local base branch (a repo with no origin,
# e.g. a test fixture). Empty when neither exists — then nothing can be LANDED.
_kit_gc_base_ref() {
  local base="${KIT_BASE_BRANCH:-main}"
  if git show-ref --verify --quiet "refs/remotes/origin/$base" 2>/dev/null; then printf 'origin/%s' "$base"
  elif git show-ref --verify --quiet "refs/heads/$base" 2>/dev/null; then printf '%s' "$base"
  fi
}

# _kit_gc_landed_reason <branch> <pr_index> [repo] — echo why <branch>'s work is already on the base
# branch, or nothing when it is not. The rows #388 is about: a branch with NO PR of its own whose work
# reached base through someone else's PR — an effort's `sub/<N><letter>` (merged into effort/<N>, then
# squash-merged), an `effort/<N>` whose remote ref is gone, a Claude Code Agent-tool isolation
# worktree (`worktree-agent-<hash>`, merged into the task branch that had the PR). `git cherry` and
# `--is-ancestor` cannot see through a squash (it rewrites the patch ids), so two checks, either of
# which suffices:
#   (a) content — every file the branch changed since its merge base with base now has the same
#       content on base (`git diff --quiet <base> <branch> -- <those files>`): the branch holds no
#       change base lacks, whatever path it took there. A branch with no change at all beyond its
#       merge base (or an ancestor of base) is landed trivially.
#   (b) lineage — the name (`sub/<N>…`, `effort/<N>…`, any `<kind>/<N>-…`) or a `[#N]` in one of its
#       commit subjects names an issue that is CLOSED and whose PR is MERGED: either a head
#       `<kind>/<N>-…` in the PR index, or — when the PR has scrolled out of that 200-PR window — a
#       PR the issue itself reports as having closed it (_kit_gc_issue_merged_pr, cached per issue).
#       Covers a sub whose files base has since changed further, and an agent branch whose `[#N]`
#       names the effort parent while the PR was the effort's.
# A branch failing both stays ORPHAN. Never called for a branch with a PR of its own.
_kit_gc_landed_reason() {
  local b="$1" pr_index="$2" repo="${3:-$KIT_GC_REPO}" base_ref mb files shape="" n state pr
  base_ref="$(_kit_gc_base_ref)"; [ -n "$base_ref" ] || return 0
  case "$b" in worktree-agent-*) shape="agent worktree; " ;; esac
  # (a) content
  if git merge-base --is-ancestor "$b" "$base_ref" 2>/dev/null; then
    printf '%sancestor of %s' "$shape" "$base_ref"; return 0
  fi
  mb="$(git merge-base "$base_ref" "$b" 2>/dev/null)"
  if [ -n "$mb" ]; then
    files="$(git diff --name-only "$mb" "$b" 2>/dev/null)"
    if [ -z "$files" ]; then
      printf '%sno change beyond %s' "$shape" "$base_ref"; return 0
    fi
    # NUL-delimited so a path with spaces survives; xargs exits non-zero if any batch differs.
    if git diff --name-only -z "$mb" "$b" 2>/dev/null | xargs -0 git diff --quiet "$base_ref" "$b" -- 2>/dev/null; then
      printf '%scontent on %s' "$shape" "$base_ref"; return 0
    fi
  fi
  # (b) lineage
  n="$(wt_issue_number "$b")"
  # `[#N]` is the kit's token; `(#N)` is GitHub's own trailing ref (what a squash puts on a PR
  # commit, and what a sub-issue's commit subject carried on a consuming repo's effort). Both name issues.
  [ -n "$n" ] || n="$(git log --format=%s "$base_ref..$b" 2>/dev/null | grep -oE '[[(]#[0-9]+[])]' | head -1 | tr -dc '0-9')"
  [ -n "$n" ] || return 0
  state="$(wt_issue_state "$n" "$repo")"
  [ "$state" = closed ] || return 0
  if printf '%s\n' "$pr_index" | grep -qE "^[a-z]+/${n}-[^	]*	PR#[0-9]+ MERGED\$"; then
    printf '%sissue #%s closed, its PR merged' "$shape" "$n"
  elif pr="$(_kit_gc_issue_merged_pr "$n" "$repo")" && [ -n "$pr" ]; then
    # The index is a 200-PR window; on a repo with hundreds of merged PRs the effort PR that closed
    # #N has scrolled out of it (measured on a consuming repo: the closing PR sat at position 254). The issue itself
    # knows which PR closed it, and that lookup is exact and not window-bound. A sub-issue closes
    # through `effort close`, not a PR, so the answer may come from its parent: "M via P".
    case "$pr" in
      *" via "*) printf '%sissue #%s closed, parent #%s closed by merged PR#%s' "$shape" "$n" "${pr#* via }" "${pr%% *}" ;;
      *)         printf '%sissue #%s closed by merged PR#%s' "$shape" "$n" "$pr" ;;
    esac
  fi
}

# Per-run cache for _kit_gc_issue_merged_pr. A file, not a shell variable: the lookup runs inside
# `$(...)` and `| while read` subshells, where a variable written is lost on return, while `$$` is
# the top shell's PID in every subshell of one verb run. kit_gc_analyze / kit_gc_prune reset it on
# entry so a result never outlives the run that made it (an issue closed since would read stale).
_KIT_GC_CACHE_DIR="${TMPDIR:-/tmp}/kit-gc-cache-$$"
_kit_gc_cache_reset() { rm -rf "$_KIT_GC_CACHE_DIR" 2>/dev/null; mkdir -p "$_KIT_GC_CACHE_DIR" 2>/dev/null || true; }

# _kit_gc_issue_merged_pr <issue> [repo] [depth] — echo the number of a MERGED PR that closed
# <issue>, or nothing. Reads the issue's `closedByPullRequestsReferences` (exact, not bound to the
# 200-PR index window) and confirms the state of each candidate. When nothing closed <issue> — a
# sub-issue closes through `effort close`, not a PR — climb ONCE to its parent (the sub-issues API;
# 404 = no parent) and answer `<M> via <P>` when the parent was closed by merged PR M. Cached per
# issue number for the run: an effort's subs and agent branches all name the same N, and 21
# branches must not mean 21 gh round trips. A negative answer is cached too. rc 0 with empty output
# when nothing merged closed it or its parent (measured: an effort closed NOT_PLANNED, no PR, no
# parent — a true ORPHAN).
_kit_gc_issue_merged_pr() {
  local n="$1" repo="${2:-$KIT_GC_REPO}" depth="${3:-0}" cache="" cand result="" parent
  [ -n "$n" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  [ -d "$_KIT_GC_CACHE_DIR" ] && cache="$_KIT_GC_CACHE_DIR/issue-$n"
  if [ -n "$cache" ] && [ -f "$cache" ]; then cat "$cache"; return 0; fi
  while IFS= read -r cand; do
    [ -n "$cand" ] || continue
    case "$cand" in *[!0-9]*) continue ;; esac
    if cckit_gh_rest; then
      # REST: the candidate came from a merged cross-reference that closes <n> (gh_rest_wave_rows).
      result="$cand"; break
    elif [ "$(gh pr view "$cand" --repo "$repo" --json state --jq .state 2>/dev/null)" = "MERGED" ]; then
      result="$cand"; break
    fi
  done <<EOF
$(if cckit_gh_rest; then gh_rest_issue_closing_prs "$repo" "$n" 2>/dev/null || true
  else gh issue view "$n" --repo "$repo" --json closedByPullRequestsReferences \
     --jq '.closedByPullRequestsReferences[].number' 2>/dev/null || true; fi)
EOF
  if [ -z "$result" ] && [ "$depth" -eq 0 ]; then
    parent="$(gh api "repos/$repo/issues/$n/parent" --jq .number 2>/dev/null || true)"
    case "$parent" in ''|*[!0-9]*) parent="" ;; esac
    if [ -n "$parent" ]; then
      result="$(_kit_gc_issue_merged_pr "$parent" "$repo" 1)"
      [ -n "$result" ] && result="${result%% *} via $parent"
    fi
  fi
  [ -n "$cache" ] && printf '%s' "$result" > "$cache" 2>/dev/null
  printf '%s' "$result"
}

# _kit_gc_classify <branch> <pr_index> [repo] — the ONE verdict for a branch, exactly as
# kit_gc_analyze prints it after `-> `. kit_gc_prune acts on this same function, so the plan a human
# approved and the delete that follows can never disagree (Family 1, the failure mode #219 was about).
# Order: base branch > PROTECTED (issue open) > UNKNOWN (issue state read failed) > SAFE (own PR
# merged) > ACTIVE (own PR open) > a CLOSED-unmerged PR verbatim > UNKNOWN (PR list read failed) >
# LANDED (no PR, work on base) > ORPHAN.
#
# The two UNKNOWN rungs are #330. A failed issue-state read sits ABOVE SAFE and LANDED because the
# issue may be open: with gh failing, an open issue's branch with no commits beyond base used to
# lose PROTECTED and be classified LANDED by the content check, which needs no gh at all — and
# LANDED is deletable. A failed PR-list read sits above LANDED/ORPHAN because "found no PR" is not
# "has no PR" when the list never arrived. Neither string says "no PR", and neither is deletable
# (_kit_gc_prune_why answers nothing for it).
_kit_gc_classify() {
  local b="$1" pr_index="$2" repo="${3:-$KIT_GC_REPO}" pr n state="" landed
  case "$b" in "${KIT_BASE_BRANCH:-main}"|develop|main) echo "ACTIVE (base branch)"; return 0 ;; esac
  pr="$(_kit_gc_pr_for "$pr_index" "$b")"
  # The same read wt_protected_reason makes, kept as a state so `unknown` is not flattened to "".
  n="$(wt_issue_number "$b" 2>/dev/null || true)"
  [ -n "$n" ] && state="$(wt_issue_state "$n" "$repo" 2>/dev/null || true)"
  if [ "$state" = open ]; then
    echo "PROTECTED: issue #$n still OPEN"
  elif [ "$state" = unknown ]; then
    echo "UNKNOWN (could not determine — the state read for issue #$n failed; kept, never auto-deleted)"
  elif printf '%s' "$pr" | grep -q 'MERGED'; then
    echo "SAFE (${pr}, issue closed/absent — verify level with remote before delete)"
  elif printf '%s' "$pr" | grep -q 'OPEN'; then
    echo "ACTIVE (${pr})"
  elif [ -n "$pr" ]; then
    echo "$pr"
  elif _kit_gc_pr_index_unknown "$pr_index"; then
    echo "UNKNOWN (could not determine — the PR list read failed; kept, never auto-deleted)"
  else
    landed="$(_kit_gc_landed_reason "$b" "$pr_index" "$repo")"
    if [ -n "$landed" ]; then echo "LANDED ($landed)"
    else echo "ORPHAN (no PR — surface, never auto-delete)"; fi
  fi
}

# _kit_gc_detached_verdict <worktree-path> <head-sha> — the ONE verdict for a live worktree whose HEAD
# is detached (#390), exactly as kit_gc_analyze prints it after `-> `. It has no branch, so none of
# the branch checks apply (no name to carry an issue number, no PR head to look up):
#   LANDED  the tree is clean AND HEAD is an ancestor of the base ref or of `main` — every commit it
#           can reach is already there and no file differs, so removing it loses nothing. The shape
#           an agent tool leaves behind when the `claude/*` branch it made the worktree for is gone,
#           and a temp worktree a review built at a base commit.
#   ORPHAN  anything else: uncommitted changes, a status that cannot be read, or a HEAD that is on
#           neither ref. A commit made on a detached HEAD is on no branch, so the worktree is the
#           only handle on it — never deleted, surfaced by path.
# An ignored file does not make the tree dirty (same rule as the branch worktrees above).
_kit_gc_detached_verdict() {
  local wtpath="$1" sha="$2" ref dirt
  dirt="$(git -C "$wtpath" status --porcelain 2>/dev/null)" \
    || { echo "ORPHAN (detached, status unreadable — surface, never auto-delete)"; return 0; }
  if [ -n "$dirt" ]; then
    echo "ORPHAN (detached, uncommitted changes — surface, never auto-delete)"; return 0
  fi
  for ref in "$(_kit_gc_base_ref)" origin/main main; do
    [ -n "$ref" ] || continue
    git rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1 || continue
    if git merge-base --is-ancestor "$sha" "$ref" 2>/dev/null; then
      echo "LANDED (detached; ancestor of $ref)"; return 0
    fi
  done
  echo "ORPHAN (detached, HEAD on neither the base branch nor main — surface, never auto-delete)"
}

# _kit_gc_detached_rows — echo "<path>\t<head-sha>\t<verdict>" for each LIVE linked worktree whose
# HEAD is detached. The first porcelain record is the main checkout (or a bare repo): it cannot be
# removed as a worktree, so it is never a row. A detached worktree whose directory is gone is a
# ZOMBIE and belongs to _kit_gc_zombies, not here. `substr`, not `$2`: a path may hold a space.
# Writes NOTHING. analyze, prune, cleanup and `cckit status` all read this one list.
_kit_gc_detached_rows() {
  local wtpath sha
  git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /  { n++; w = substr($0, 10); h = ""; next }
           /^HEAD /      { h = substr($0, 6); next }
           /^detached$/  { if (n > 1) print w "\t" h }' \
    | while IFS="$(printf '\t')" read -r wtpath sha; do
        [ -n "$wtpath" ] && [ -d "$wtpath" ] || continue
        printf '%s\t%s\t%s\n' "$wtpath" "$sha" "$(_kit_gc_detached_verdict "$wtpath" "$sha")"
      done
}

# kit_gc_analyze — read-only classification of worktrees, branches, and stashes. Writes NOTHING.
# Each row is tagged PROTECTED / SAFE / ACTIVE / LANDED / ORPHAN / UNKNOWN so a human or UI can
# decide what to prune.
kit_gc_analyze() {
  _kit_gc_require_deps || return 1
  _kit_gc_cache_reset
  # `wtpath`, not `path`: under zsh `path` is tied to PATH (special array), so a bare `path` local
  # here would clobber the command search path on assignment. A namespaced name is inert.
  local repo="$KIT_GC_REPO" b ref wtpath reason
  git fetch origin --prune --quiet 2>/dev/null || true

  echo "# worktrees"
  git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch /{print w" "$2}' \
    | while read -r wtpath ref; do
        b="${ref#refs/heads/}"
        reason="$(wt_protected_reason "$b" "$repo" 2>/dev/null || true)"
        if [ -n "$reason" ]; then echo "  $wtpath [$b] -> PROTECTED: $reason"
        else echo "  $wtpath [$b] -> prunable if PR merged"; fi
      done
  # Detached worktrees: no `branch` line, so the loop above never sees them (#390).
  local dsha dverdict
  while IFS="$(printf '\t')" read -r wtpath dsha dverdict; do
    [ -n "$wtpath" ] || continue
    echo "  $wtpath [detached@$(printf '%.12s' "$dsha")] -> $dverdict"
  done <<EOF
$(_kit_gc_detached_rows)
EOF

  echo "# branches"
  # All PRs in ONE call, indexed locally by head branch (#124). while-read (NOT `for b in $(...)`) so
  # branch iteration survives a NUL-polluted IFS.
  local pr_index; pr_index="$(_kit_gc_pr_index "$repo")"
  git branch --format='%(refname:short)' 2>/dev/null | while IFS= read -r b; do
    [ -n "$b" ] || continue
    echo "  $b -> $(_kit_gc_classify "$b" "$pr_index" "$repo")"
  done

  echo "# stashes"
  git stash list 2>/dev/null | sed 's/^/  /' || true

  echo "# zombies (worktree dir gone, admin metadata lingers)"
  local zname zbranch zstaged found=0
  while IFS="$(printf '\t')" read -r zname zbranch zstaged; do
    [ -n "$zname" ] || continue
    found=1
    if [ "$zstaged" = yes ] && _kit_gc_zombie_detached "$zbranch"; then
      echo "  $zname [$zbranch] -> ZOMBIE with STAGED work, detached — kept, never pruned (no branch to recover onto; recover by hand)"
    elif [ "$zstaged" = yes ]; then
      echo "  $zname [$zbranch] -> ZOMBIE with STAGED work — recover-before-prune (gc --prune --yes recovers it to a commit)"
    else
      echo "  $zname [$zbranch] -> ZOMBIE (no staged delta) — prunable"
    fi
  done <<EOF
$(_kit_gc_zombies)
EOF
  [ "$found" -eq 1 ] || echo "  (none)"
}

# kit_gc_has_prunable — rc 0 if at least one row is deletable: a branch that is SAFE (its own PR
# merged) or LANDED (no PR of its own, work already on base), or a LANDED detached worktree.
kit_gc_has_prunable() {
  kit_gc_analyze 2>/dev/null | grep -qE '> (SAFE|LANDED) '
}

# _kit_gc_zombies — echo "<name>\t<branch>\t<staged:yes|no>" for each ZOMBIE worktree: its working
# dir is gone but its admin metadata (<git-common-dir>/worktrees/<name>/) lingers. staged=yes when
# the admin index holds a tree that differs from the branch tip (staged-but-uncommitted work that
# `git worktree prune` would orphan). A DETACHED zombie (its admin HEAD is a raw commit id, not a
# `ref:`) is compared to THAT commit's tree and labelled `detached@<sha12>` (#390): comparing it to
# an empty branch tip called every clean one "staged". Writes NOTHING. bash 3.2.
_kit_gc_zombies() {
  local common wdir name gitdir wtpath branch tree tip tiptree staged dsha
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common" in /*) : ;; *) common="$(cd "$common" 2>/dev/null && pwd)" || return 0 ;; esac
  [ -d "$common/worktrees" ] || return 0
  for wdir in "$common"/worktrees/*/; do
    [ -d "$wdir" ] || continue
    gitdir="$(cat "$wdir/gitdir" 2>/dev/null)"; wtpath="${gitdir%/.git}"
    # A zombie: the recorded working-tree path is set but no longer exists on disk.
    [ -n "$wtpath" ] && [ ! -e "$wtpath" ] || continue
    name="$(basename "$wdir")"
    branch="$(sed -n 's#^ref: refs/heads/##p' "$wdir/HEAD" 2>/dev/null)"
    tree=""; [ -f "$wdir/index" ] && tree="$(GIT_INDEX_FILE="$wdir/index" git write-tree 2>/dev/null)"
    dsha=""; [ -n "$branch" ] || dsha="$(_kit_gc_zombie_head_sha "$wdir")"
    if [ -n "$dsha" ]; then
      tip="$(git rev-parse --verify --quiet "${dsha}^{commit}" 2>/dev/null)"
      branch="detached@$(printf '%.12s' "$dsha")"
    else
      tip="$(git rev-parse --verify --quiet "refs/heads/${branch}" 2>/dev/null)"
    fi
    tiptree=""; [ -n "$tip" ] && tiptree="$(git rev-parse --verify --quiet "${tip}^{tree}" 2>/dev/null)"
    if [ -n "$tree" ] && [ "$tree" != "$tiptree" ]; then staged=yes; else staged=no; fi
    printf '%s\t%s\t%s\n' "$name" "${branch:-?}" "$staged"
  done
}

# _kit_gc_zombie_head_sha <admin-dir> — echo the commit id a worktree's admin HEAD holds when it is
# DETACHED (a bare 40- or 64-hex line), nothing when HEAD is a `ref:`.
_kit_gc_zombie_head_sha() {
  sed -n '1p' "$1/HEAD" 2>/dev/null | grep -E '^[0-9a-f]{40}([0-9a-f]{24})?$' || true
}

# _kit_gc_zombie_detached <label> — rc 0 when a _kit_gc_zombies branch column names a detached HEAD.
_kit_gc_zombie_detached() {
  case "$1" in detached@*) return 0 ;; *) return 1 ;; esac
}

# kit_gc_recover_zombies <yes> — the recover-before-prune mechanic (#111). For each ZOMBIE worktree
# holding staged-but-uncommitted work, recover that delta to its branch via plumbing BEFORE any
# prune: GIT_INDEX_FILE=<admin>/index git write-tree -> git commit-tree -p <tip> -> update-ref. With
# <yes>=1 it performs the recovery + sweeps that zombie's stale locks; otherwise it reports what it
# WOULD recover (dry-run). Never prunes; that stays with the caller (gated on --yes). bash 3.2.
#
# A DETACHED zombie (#390) has no branch to commit onto. With no staged delta beyond its HEAD's tree
# it is skipped like any clean zombie and the caller's prune drops it. With one, the admin index is
# the only blob->path map and there is nowhere to recover it, so under <yes>=1 the admin dir is
# LOCKED (git's own `locked` file, which `git worktree prune` honors) — the caller's prune then
# leaves that one entry in place while it drops the rest. Before this, the message said "leaving it
# for manual recovery" and the prune that followed deleted the index anyway.
kit_gc_recover_zombies() {
  local yes="${1:-0}" common wdir name gitdir wtpath branch tree tip tiptree newc msg dsha
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 0
  case "$common" in /*) : ;; *) common="$(cd "$common" 2>/dev/null && pwd)" || return 0 ;; esac
  [ -d "$common/worktrees" ] || return 0
  for wdir in "$common"/worktrees/*/; do
    [ -d "$wdir" ] || continue
    gitdir="$(cat "$wdir/gitdir" 2>/dev/null)"; wtpath="${gitdir%/.git}"
    [ -n "$wtpath" ] && [ ! -e "$wtpath" ] || continue    # only dead worktrees
    name="$(basename "$wdir")"
    branch="$(sed -n 's#^ref: refs/heads/##p' "$wdir/HEAD" 2>/dev/null)"
    [ -f "$wdir/index" ] || continue
    tree="$(GIT_INDEX_FILE="$wdir/index" git write-tree 2>/dev/null)" || continue
    [ -n "$tree" ] || continue
    dsha=""; [ -n "$branch" ] || dsha="$(_kit_gc_zombie_head_sha "$wdir")"
    if [ -n "$dsha" ]; then tip="$(git rev-parse --verify --quiet "${dsha}^{commit}" 2>/dev/null)"
    else tip="$(git rev-parse --verify --quiet "refs/heads/${branch}" 2>/dev/null)"; fi
    tiptree=""; [ -n "$tip" ] && tiptree="$(git rev-parse --verify --quiet "${tip}^{tree}" 2>/dev/null)"
    # No staged delta beyond the tip → nothing to recover; the zombie is safe to prune as-is.
    [ "$tree" = "$tiptree" ] && continue
    if [ -z "$branch" ]; then
      if [ "$yes" -ne 1 ]; then
        echo "  would KEEP zombie worktree $name — detached with staged work (staged tree $tree), no branch to recover onto" >&2
        continue
      fi
      [ -e "$wdir/locked" ] \
        || printf '%s\n' "kit gc: detached zombie holds staged work (tree $tree) — recover before pruning" > "$wdir/locked" 2>/dev/null
      if [ -e "$wdir/locked" ]; then
        echo "  KEPT zombie worktree $name — detached with staged work, locked so the prune skips it. Recover: git branch <name> \$(git commit-tree $tree${tip:+ -p $tip} -m recovered); then rm '${wdir%/}/locked' && git worktree prune" >&2
      else
        echo "  gc: could not lock detached zombie $name — its staged work (tree $tree) is NOT protected from the prune" >&2
      fi
      continue
    fi
    if [ "$yes" -ne 1 ]; then
      echo "  would RECOVER staged work from zombie worktree $name -> a commit on $branch (staged tree $tree)" >&2
      continue
    fi
    msg="kit gc: recovered staged work from zombie worktree $name (recover-before-prune)"
    newc="$(printf '%s\n' "$msg" | GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-kit-gc}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-kit-gc@localhost}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-kit-gc}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-kit-gc@localhost}" git commit-tree "$tree" ${tip:+-p "$tip"} 2>/dev/null)"
    if [ -n "$newc" ]; then
      # Compare-and-swap on the tip so a concurrent update is never clobbered.
      if git update-ref "refs/heads/$branch" "$newc" ${tip:+"$tip"} 2>/dev/null; then
        echo "  RECOVERED staged work from zombie $name -> commit ${newc%% *} on $branch" >&2
      else
        echo "  gc: could not update refs/heads/$branch (moved concurrently?) — zombie $name left intact" >&2
      fi
    fi
    # Stale-lock sweep — safe only because this worktree is provably dead.
    rm -f "$wdir/index.lock" "$wdir/HEAD.lock" 2>/dev/null || true
  done
}

# _kit_gc_has_unpushed <branch> — rc 0 when the LOCAL branch holds commits its remote does not, i.e.
# deleting it locally would destroy the only copy. A missing remote ref is NOT unpushed work: the
# branch's PR merged, so the commits reached the base branch and the remote was deleted at merge.
# `git branch -D` is a force delete, so this is the guard that makes it safe (kit-gc SKILL: "verify a
# branch is level with its remote before deleting — an 'ahead' branch may hold orphan work").
_kit_gc_has_unpushed() {
  local b="$1"
  git show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null || return 1
  [ "$(git rev-list --count "origin/$b..$b" 2>/dev/null || echo 1)" != "0" ]
}

# _kit_gc_remote_ahead <branch> — rc 0 when the REMOTE holds commits the local branch does not.
# Containment in one direction is not equality: `origin/<b>..<b>` = 0 only proves local ⊆ remote, so
# a remote-ahead branch would otherwise pass the level check and lose remote-only history on delete.
# Remote deletion requires BOTH directions empty.
_kit_gc_remote_ahead() {
  local b="$1"
  git show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null || return 1
  [ "$(git rev-list --count "$b..origin/$b" 2>/dev/null || echo 1)" != "0" ]
}

# _kit_gc_only_match <regex> <branch> — rc 0 when <regex> is empty or <branch> matches it (ERE).
_kit_gc_only_match() {
  [ -n "$1" ] || return 0
  printf '%s\n' "$2" | grep -qE -- "$1"
}

# _kit_gc_prune_why <verdict> — echo the reason a prune row prints, or nothing when the verdict is
# not a deletable one. SAFE (own PR merged) and LANDED (no PR, work on base — #388) are the only two;
# UNKNOWN (#330, a failed gh read) falls through with every other kept verdict.
_kit_gc_prune_why() {
  case "$1" in
    SAFE*)   echo "PR MERGED" ;;
    LANDED*) echo "$1" ;;
    *)       : ;;
  esac
}

# kit_gc_prune [--yes] [--only <regex>] - remove worktrees + local branches whose PR is MERGED (the
# SAFE rows) or whose work is already on base with no PR of their own (the LANDED rows, #388).
# A detached worktree rated LANDED (#390) goes the same way; one rated ORPHAN never does.
# DRY-RUN by default (lists what it WOULD remove); --yes performs the deletions. Never touches a
# PROTECTED/ACTIVE/ORPHAN branch, and never a DIRTY worktree (recover-before-prune): a worktree with
# staged/unstaged/untracked changes is skipped with a warning, not destroyed. The remote branch is
# already deleted at merge time (gh pr merge --delete-branch); this cleans up the local side.
# `--only <regex>` restricts both loops to branches matching the ERE (effort_close passes
# `^sub/<N>[a-z]-` to collect an effort's subs; a regex, not a glob — zsh does not expand a glob
# held in a variable inside `case`, bash does, and this file is sourced by both); the zombie pass is skipped under --only, since it
# is not scoped to a branch — that stays with a full `gc --prune` / `cleanup`.
kit_gc_prune() {
  _kit_gc_require_deps || return 1
  _kit_gc_cache_reset
  # `wtpath`, not `path`: under zsh `path` is tied to PATH (special array), so assigning to a bare
  # `path` local would clobber the command search path. A namespaced name is inert.
  local repo="$KIT_GC_REPO" yes=0 wtpath ref b pr_index verdict why only=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1 ;;
      --only)   only="${2:-}"; shift ;;
      --only=*) only="${1#--only=}" ;;
    esac
    shift
  done

  # All PRs in ONE call, indexed by head branch (#124) — shared by both loops below instead of a
  # per-branch `gh pr list --head` (the N+1 that scaled badly with many stale branches).
  pr_index="$(_kit_gc_pr_index "$repo")"

  # Worktrees first - a branch's worktree must be removed before the branch can be deleted. The
  # verdict comes from the ONE classifier (_kit_gc_classify), the same function analyze prints.
  git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch /{print w" "$2}' \
    | while read -r wtpath ref; do
        b="${ref#refs/heads/}"
        [ -n "$b" ] || continue
        _kit_gc_only_match "$only" "$b" || continue
        verdict="$(_kit_gc_classify "$b" "$pr_index" "$repo")"
        why="$(_kit_gc_prune_why "$verdict")"; [ -n "$why" ] || continue
        if [ -n "$(git -C "$wtpath" status --porcelain 2>/dev/null)" ]; then
          echo "  SKIP dirty worktree $wtpath [$b] - commit/recover before pruning" >&2; continue
        fi
        if [ "$yes" -eq 1 ]; then
          git worktree remove --force "$wtpath" 2>/dev/null && echo "  removed worktree $wtpath [$b] ($why)"
        else
          echo "  would remove worktree $wtpath [$b] ($why)"
        fi
      done

  # Detached worktrees (#390): only the LANDED ones, by the same verdict analyze printed. No
  # `--force`: the verdict already required a clean tree, so a refusal here means it changed since
  # (or is locked) and the worktree is left exactly as it is. Not branch-scoped, so skipped under
  # --only like the zombie pass below.
  if [ -z "$only" ]; then
    local dsha dlabel
    while IFS="$(printf '\t')" read -r wtpath dsha verdict; do
      [ -n "$wtpath" ] || continue
      why="$(_kit_gc_prune_why "$verdict")"; [ -n "$why" ] || continue
      dlabel="detached@$(printf '%.12s' "$dsha")"
      if [ "$yes" -ne 1 ]; then
        echo "  would remove worktree $wtpath [$dlabel] ($why)"
      elif git worktree remove "$wtpath" 2>/dev/null; then
        echo "  removed worktree $wtpath [$dlabel] ($why)"
      else
        echo "  SKIP worktree $wtpath [$dlabel] - git refused to remove it (locked, or changed since the plan)" >&2
      fi
    done <<EOF
$(_kit_gc_detached_rows)
EOF
  fi

  # recover-before-prune (#111): a zombie worktree (working dir gone, admin metadata lingers) may
  # hold staged-but-uncommitted work in its admin index — the ONLY blob->path map. `git worktree
  # prune` deletes that index, orphaning the blobs for a later `git gc` to reap — real data loss in a
  # documented incident. Recover any staged delta to its branch FIRST, and gate the prune sweep
  # behind --yes so it NEVER runs in a dry-run (the previous unconditional prune was the hazard).
  if [ -z "$only" ]; then
    kit_gc_recover_zombies "$yes"
    [ "$yes" -eq 1 ] && { git worktree prune 2>/dev/null || true; }
  fi

  # Then local branches whose PR merged, or whose work landed (worktree now gone). while-read (NOT
  # `for b in $(...)`) so branch iteration survives a NUL-polluted IFS (#124).
  git branch --format='%(refname:short)' 2>/dev/null | while IFS= read -r b; do
    [ -n "$b" ] || continue
    _kit_gc_only_match "$only" "$b" || continue
    verdict="$(_kit_gc_classify "$b" "$pr_index" "$repo")"
    why="$(_kit_gc_prune_why "$verdict")"; [ -n "$why" ] || continue
    # A merged PR (or landed content) is not on its own sufficient: the local ref may carry commits
    # that were never pushed, and `git branch -D` would be their last rites.
    if _kit_gc_has_unpushed "$b"; then
      echo "  SKIP $b — ahead of origin/$b (unpushed commits); recover before pruning" >&2; continue
    fi
    if [ "$yes" -eq 1 ]; then
      git branch -D "$b" >/dev/null 2>&1 && echo "  deleted local branch $b ($why)"
    else
      echo "  would delete local branch $b ($why)"
    fi
  done
  [ "$yes" -eq 1 ] && echo "gc prune: done" || echo "gc prune: DRY RUN - pass --yes to delete"
}

# _kit_gc_names <analysis> <section> <verdict-regex> — echo one bare name per matching row inside a
# `# <section>` block of a kit_gc_analyze dump. The analysis is the SINGLE classifier (Family 1):
# cleanup reads its verdicts rather than re-deriving them, so the two can never disagree about what
# is safe to delete — the failure mode #219 was about.
_kit_gc_names() {
  printf '%s\n' "$1" | awk -v sect="$2" -v want="$3" '
    /^# /     { in_s = ($0 == "# " sect); next }
    !in_s     { next }
    $0 ~ want { sub(/^  /, ""); sub(/ ->.*/, ""); print }
  '
}

# kit_gc_cleanup [--yes] — the ONE guided destructive sweep over the gc analysis.
#
# PLAN FIRST, always: print every bucket with its counts and names, then execute only the SAFE rows,
# and only with --yes. Without --yes nothing is written — the plan IS the output. Every row the plan
# omits is a deletion the user did not get to veto, so the plan must name EVERYTHING --yes can touch:
# worktrees as well as branches.
#
# What --yes deletes: SAFE and LANDED worktrees and local branches (via kit_gc_prune, which also runs
# the recover-before-prune zombie pass) — SAFE = its own PR merged, LANDED = no PR of its own but its
# work is already on base (#388: effort subs, agent isolation worktrees) — and the REMOTE ref of such
# a branch when it is exactly level with it. What it NEVER deletes: an ORPHAN branch (local commits
# not on the base remote), a PROTECTED branch (its issue is still open), or a stash. Those three are
# irreversible or hold the only copy of work, so they are surfaced BY NAME for a human and left
# exactly where they are.
#
# NOTE: the underlying kit_gc_analyze refreshes remote-tracking refs (`git fetch --prune`) so the
# classification is not made against a stale view of the remote. That is the only write a plan-only
# run performs, and it touches no branch, worktree, stash, or commit of yours.
kit_gc_cleanup() {
  _kit_gc_require_deps || return 1
  local repo="$KIT_GC_REPO" yes=0 a out b n_safe n_orphan n_prot n_stash n_wt rc=0 n_rfail=0
  local zname zbranch zstaged
  local safe_list landed_list orphan_list prot_list stash_list wt_list zomb_list level_ok n_zomb n_landed
  local unknown_list n_unknown
  local det_rows det_wt det_orphan wtpath dsha dverdict n_zkept
  for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; esac; done

  out="$(kit_gc_analyze)" || return 1
  safe_list="$(_kit_gc_names "$out" branches ' -> SAFE ')"
  # LANDED rows keep their reason (`name (reason)`) so the plan says WHY each one may go (#388).
  landed_list="$(printf '%s\n' "$out" | awk '
    /^# /              { in_s = ($0 == "# branches"); next }
    in_s && / -> LANDED / { sub(/^  /, ""); sub(/ -> LANDED /, " "); print }')"
  orphan_list="$(_kit_gc_names "$out" branches ' -> ORPHAN')"
  prot_list="$(_kit_gc_names "$out" branches ' -> PROTECTED:')"
  unknown_list="$(_kit_gc_names "$out" branches ' -> UNKNOWN ')"
  stash_list="$(printf '%s\n' "$out" | awk '/^# /{in_s=($0=="# stashes"); next} in_s && NF' | sed 's/^  //')"

  # Worktrees kit_gc_prune would remove: the ones whose branch is itself SAFE or LANDED (the same
  # verdicts prune acts on). Derived from those lists so the two cannot diverge.
  wt_list="$(git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch /{print w" "$2}' \
    | while read -r wtpath ref; do
        b="${ref#refs/heads/}"
        printf '%s\n' "$safe_list" | grep -qxF "$b" \
          || printf '%s\n' "$landed_list" | sed 's/ (.*//' | grep -qxF "$b" || continue
        if [ -n "$(git -C "$wtpath" status --porcelain 2>/dev/null)" ]; then
          echo "$wtpath [$b] (DIRTY — will be skipped, not destroyed)"
        else
          echo "$wtpath [$b]"
        fi
      done)"

  # Detached worktrees (#390) have no branch, so neither list above carries them. The LANDED ones
  # join the worktrees --yes removes; the ORPHAN ones join the kept rows, named by path. Same helper
  # as the analyze report and the prune pass, so the three cannot diverge.
  det_rows="$(_kit_gc_detached_rows)"
  det_wt="$(printf '%s\n' "$det_rows" | while IFS="$(printf '\t')" read -r wtpath dsha dverdict; do
        case "$dverdict" in LANDED*) echo "$wtpath [detached@$(printf '%.12s' "$dsha")] ${dverdict#LANDED }" ;; *) : ;; esac
      done)"
  det_orphan="$(printf '%s\n' "$det_rows" | while IFS="$(printf '\t')" read -r wtpath dsha dverdict; do
        case "$dverdict" in ORPHAN*) echo "$wtpath [detached@$(printf '%.12s' "$dsha")] ${dverdict#ORPHAN }" ;; *) : ;; esac
      done)"
  [ -n "$det_wt" ] && wt_list="$(printf '%s\n%s' "$wt_list" "$det_wt" | grep . || true)"
  [ -n "$det_orphan" ] && orphan_list="$(printf '%s\n%s' "$orphan_list" "$det_orphan" | grep . || true)"

  # ZOMBIE worktrees (dir gone, admin metadata lingers). kit_gc_prune --yes acts on these two ways
  # — kit_gc_recover_zombies commits any staged delta to the branch, then `git worktree prune`
  # drops the metadata — so the plan MUST name them or --yes would touch a row nobody approved
  # (#227 review). Same helper as the analyze report, so the two cannot diverge.
  zomb_list="$(while IFS="$(printf '\t')" read -r zname zbranch zstaged; do
        [ -n "$zname" ] || continue
        if [ "$zstaged" = yes ] && _kit_gc_zombie_detached "$zbranch"; then
          echo "$zname [$zbranch] (STAGED work, detached — kept, not pruned: no branch to recover onto)"
        elif [ "$zstaged" = yes ]; then
          echo "$zname [$zbranch] (STAGED work — recovered to a commit on $zbranch, then metadata pruned)"
        else
          echo "$zname [$zbranch] (no staged delta — metadata pruned)"
        fi
      done <<ZEOF
$(_kit_gc_zombies)
ZEOF
)"

  n_safe="$(printf '%s' "$safe_list"   | grep -c . || true)"
  n_landed="$(printf '%s' "$landed_list" | grep -c . || true)"
  n_orphan="$(printf '%s' "$orphan_list" | grep -c . || true)"
  n_prot="$(printf '%s' "$prot_list"   | grep -c . || true)"
  n_unknown="$(printf '%s' "$unknown_list" | grep -c . || true)"
  n_stash="$(printf '%s' "$stash_list" | grep -c . || true)"
  n_wt="$(printf '%s' "$wt_list"       | grep -c . || true)"
  n_zomb="$(printf '%s' "$zomb_list"   | grep -c . || true)"
  n_zkept="$(printf '%s' "$zomb_list"  | grep -c 'kept, not pruned' || true)"

  echo "# cleanup plan"
  printf '  SAFE branches     %3s  merged PR, issue closed/absent\n' "$n_safe"
  printf '%s\n' "$safe_list" | grep . | sed 's/^/      /' || true
  printf '  SAFE worktrees    %3s  removed with their branch (SAFE or LANDED)\n' "$n_wt"
  printf '%s\n' "$wt_list" | grep . | sed 's/^/      /' || true
  printf '  ZOMBIE worktrees  %3s  staged work recovered to its branch, then metadata pruned\n' "$n_zomb"
  printf '%s\n' "$zomb_list" | grep . | sed 's/^/      /' || true
  printf '  LANDED branches   %3s  no PR of its own, work already on the base branch\n' "$n_landed"
  printf '%s\n' "$landed_list" | grep . | sed 's/^/      /' || true
  printf '  ORPHAN kept       %3s  commits not on the base remote — never auto-deleted\n' "$n_orphan"
  printf '%s\n' "$orphan_list" | grep . | sed 's/^/      /' || true
  printf '  PROTECTED kept    %3s  issue still OPEN\n' "$n_prot"
  printf '%s\n' "$prot_list" | grep . | sed 's/^/      /' || true
  printf '  UNKNOWN kept      %3s  a GitHub read failed — could not determine, rerun when gh answers\n' "$n_unknown"
  printf '%s\n' "$unknown_list" | grep . | sed 's/^/      /' || true
  printf '  stashes kept      %3s  irreversible — drop by hand after reading each diff\n' "$n_stash"
  printf '%s\n' "$stash_list" | grep . | sed 's/^/      /' || true

  if [ "$yes" -ne 1 ]; then
    echo "cleanup: PLAN ONLY — nothing deleted. Pass --yes to delete the SAFE and LANDED rows and prune the ZOMBIE rows."
    return 0
  fi
  [ "$n_safe" -eq 0 ] && [ "$n_landed" -eq 0 ] && [ "$n_wt" -eq 0 ] && [ "$n_zomb" -eq 0 ] \
    && { echo "cleanup: nothing SAFE or LANDED to delete."; return 0; }

  # Which SAFE / LANDED branches may have their REMOTE deleted — decided BEFORE the local prune,
  # because once the local ref is gone there is nothing left to compare. Requires exact equality in
  # BOTH directions: local ⊆ remote alone would let a remote-ahead branch lose remote-only history.
  level_ok=""
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    git show-ref --verify --quiet "refs/remotes/origin/$b" 2>/dev/null || continue
    _kit_gc_has_unpushed  "$b" && { echo "  SKIP remote $b — local is ahead of origin/$b" >&2; continue; }
    _kit_gc_remote_ahead  "$b" && { echo "  SKIP remote $b — origin/$b is ahead of local" >&2; continue; }
    level_ok="$level_ok$b
"
  done <<EOF
$safe_list
$(printf '%s\n' "$landed_list" | sed 's/ (.*//')
EOF

  kit_gc_prune --yes || rc=1

  # Remote side last: only branches proven exactly level above, so nothing unpushed or remote-only
  # is dropped. A failed delete is reported AND counted (this loop is heredoc-fed, not piped, so it
  # runs in the current shell and the counter survives), never retried blindly.
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if git push origin --delete "$b" >/dev/null 2>&1; then
      echo "  deleted remote branch $b"
    else
      echo "  SKIP remote $b — delete failed (protected ref or already gone)" >&2
      n_rfail=$((n_rfail + 1)); rc=1
    fi
  done <<EOF
$level_ok
EOF
  printf '  remote deletes failed %3s\n' "$n_rfail"
  echo "cleanup: done — $n_safe safe + $n_landed landed deleted / $((n_zomb - n_zkept)) zombie pruned / $n_orphan orphan / $n_prot protected / $n_unknown unknown / $n_stash stash left untouched."
  return "$rc"
}
