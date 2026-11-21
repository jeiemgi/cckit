#!/usr/bin/env bash
# shellcheck shell=bash
# kit-status.sh — "where are we?" as three buckets, from real state (#229).
# errors: mixed — the classifiers are pure; the fetchers degrade to empty, kit_status propagates nothing
#
# The question a session actually opens with is not "what does git say" but three things in order:
#
#   1. LOCAL UNDONE   work that exists only on this machine — a dirty worktree, a branch with
#                     commits nobody else can see, an effort sub not merged into its effort branch.
#   2. PRS TO ATTEND  open PRs that are waiting on a human: no approval, no AI-reviewer pass,
#                     unresolved review threads, red checks, a conflicting merge state.
#   3. CLEANUP        branches and worktrees that can go, local AND remote.
#
# `git status` answers none of them, and answering them by hand takes a dozen commands whose output
# has to be cross-referenced against the board. Each bucket here is a pure classifier over data a
# thin fetcher collected, so the verdicts are unit-tested against fixtures rather than the network.
#
# Source it:  source scripts/lib/kit-status.sh
# Depends on: git; gh + jq for the PR bucket (absent → the bucket says so); kit-gc.sh for cleanup;
#             effort-plan.sh for the next-effort-per-flow section (not loaded → it says so).

# ── bucket 1: local undone work ────────────────────────────────────────────────────────────────

# status_local_rows [base] — one TSV row per piece of local-only work: `kind<TAB>name<TAB>detail`.
#
#   dirty      a worktree with uncommitted changes        name = path
#   unpushed   a branch whose commits are on no remote    name = branch
#   unmerged   a sub/<N> branch not yet in its effort/<N> name = branch
#
# A branch counts as `unpushed` when it holds commits reachable from NO remote ref — the honest test
# for "only this machine has this". Comparing against the branch's own upstream is not enough: an
# effort sub whose commits were merged into a pushed effort branch has no upstream of its own, yet
# its work is safely on the remote and is not undone. A branch that merely trails its upstream is
# not undone work either, and is deliberately absent. best-effort: without git, no rows.
status_local_rows() {
  local base="${1:-${KIT_BASE_BRANCH:-main}}" wtpath ref b up ahead n effort
  command -v git >/dev/null 2>&1 || return 0

  # dirty worktrees (the main checkout included — it is a worktree too)
  # `substr($0, 10)`, not `$2`: a worktree path may contain spaces, and `$2` silently truncates it
  # at the first one — the row then names a directory that does not exist. ("worktree " is 9 chars.)
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0, 10)}' \
    | while IFS= read -r wtpath; do
        [ -d "$wtpath" ] || continue
        n="$(git -C "$wtpath" status --porcelain 2>/dev/null | grep -c . || true)"
        [ "${n:-0}" -gt 0 ] && printf 'dirty\t%s\t%s uncommitted file(s)\n' "$wtpath" "$n"
      done

  # branches carrying commits no remote has
  git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
    | while IFS= read -r b; do
        [ -n "$b" ] || continue
        case "$b" in "$base"|main|master|develop) continue ;; esac
        # `--not --remotes`: commits on NO remote-tracking ref at all. This is what makes an effort
        # sub already merged into a pushed effort branch correctly absent from the bucket.
        ahead="$(git rev-list --count "$b" --not --remotes 2>/dev/null || echo 0)"
        [ "${ahead:-0}" -gt 0 ] || continue
        up="$(git rev-parse --abbrev-ref "$b@{u}" 2>/dev/null || true)"
        if [ -n "$up" ]; then
          printf 'unpushed\t%s\t%s commit(s) on no remote (upstream %s)\n' "$b" "$ahead" "$up"
        else
          printf 'unpushed\t%s\t%s commit(s) on no remote, no upstream branch\n' "$b" "$ahead"
        fi
      done

  # effort subs not yet merged into their effort branch — the state that looks finished in a
  # worktree and is invisible in the effort PR.
  git for-each-ref --format='%(refname:short)' refs/heads 2>/dev/null \
    | while IFS= read -r b; do
        case "$b" in sub/*) : ;; *) continue ;; esac
        n="${b#sub/}"; n="${n%%[!0-9]*}"
        [ -n "$n" ] || continue
        # Check EVERY effort branch, not `head -1`: picking an arbitrary one reports a sub as
        # unmerged because it is absent from an effort it never belonged to. A sub branch name
        # carries its own issue number, not its parent's, so the mapping cannot be derived — but
        # containment can be tested, and "in no effort branch at all" is the honest verdict.
        local found_in="" e
        while IFS= read -r e; do
          [ -n "$e" ] || continue
          if git merge-base --is-ancestor "$b" "$e" 2>/dev/null; then found_in="$e"; break; fi
        done <<EOT
$(git for-each-ref --format='%(refname:short)' "refs/heads/effort/*" 2>/dev/null)
EOT
        [ -n "$found_in" ] && continue
        effort="$(git for-each-ref --format='%(refname:short)' "refs/heads/effort/*" 2>/dev/null | sed -n 1p)"
        [ -n "$effort" ] || continue
        printf 'unmerged\t%s\tin no effort branch\n' "$b"
      done
}

# status_worktree_rows — one TSV row per checked-out worktree: `path<TAB>branch`. The inventory half
# of "where are we": a clean worktree on an issue branch is still work in progress, and a session
# that cannot see it re-creates it. best-effort: without git, no rows.
status_worktree_rows() {
  command -v git >/dev/null 2>&1 || return 0
  # Same space-safe extraction as status_local_rows: take everything after the key, never `$2`.
  # Emit per RECORD, not per `branch` line: a DETACHED worktree has a `HEAD` but no `branch`, so
  # printing on `branch` alone silently drops it from the inventory — exactly the "in progress" work
  # a session must not re-create. Flush on the next `worktree` and once more at EOF. ("branch " is
  # 7 chars, "HEAD " is 5.)
  git worktree list --porcelain 2>/dev/null \
    | awk 'function emit() { if (seen) print w "\t" (b != "" ? b : "detached@" substr(head, 1, 12)) }
           /^worktree /{ emit(); w=substr($0, 10); b=""; head=""; seen=1; next }
           /^HEAD /    { head=substr($0, 6); next }
           /^branch /  { b=substr($0, 8); sub(/^refs\/heads\//, "", b) }
           END         { emit() }'
}

# status_inprogress_rows — status_worktree_rows minus the detached worktrees gc rates LANDED (#390):
# clean, HEAD already on the base branch or `main`. Nothing is in progress there — `cckit cleanup`
# removes it — so listing it as work under way sends a session to look at an empty checkout. The
# verdict is gc's own (_kit_gc_detached_rows), never re-derived here. A detached worktree gc rates
# ORPHAN (a commit on no branch, or uncommitted changes) stays, and so does every attached one.
# best-effort: without the gc classifier loaded there is no verdict, and every row is kept.
status_inprogress_rows() {
  local rows landed wtpath b
  rows="$(status_worktree_rows)"
  landed=""
  if command -v _kit_gc_detached_rows >/dev/null 2>&1; then
    landed="$(_kit_gc_detached_rows 2>/dev/null | awk -F'\t' '$3 ~ /^LANDED/ {print $1}')"
  fi
  while IFS="$(printf '\t')" read -r wtpath b; do
    [ -n "$wtpath" ] || continue
    case "$b" in
      detached@*) [ -n "$landed" ] && grep -qxF -- "$wtpath" <<<"$landed" && continue ;;
      *) : ;;
    esac
    printf '%s\t%s\n' "$wtpath" "$b"
  done <<EOF
$rows
EOF
}

# ── bucket 2: open PRs waiting on a human ──────────────────────────────────────────────────────

# status_prs_classify [ai_expected] — stdin is a JSON array of shaped PR objects; echo one TSV row
# per PR: `verdict<TAB>number<TAB>title<TAB>detail`. PURE (jq only, no gh), so every verdict below
# is unit-tested against fixtures.
#
# Each object: {number, title, draft, mergeable, checks, approvals, ai_review, unresolved}
#   checks     PASS | FAIL | PENDING | NONE   (already collapsed by status_prs_fetch)
#   approvals  count of APPROVED reviews from non-bot authors
#   ai_review  true when an AI reviewer has reviewed this PR at all
#   unresolved count of unresolved review threads
#
# The verdict is the ONE next action, most-blocking first: a conflict cannot be reviewed around, red
# checks make a review premature, and unresolved threads outrank a missing approval because the
# reviewer already spoke. `ai_expected` (1 when the repo evidently uses an AI reviewer) is what
# keeps `ai-review` from firing on every PR in a repo that has none.
status_prs_classify() {
  local ai_expected="${1:-0}"
  command -v jq >/dev/null 2>&1 || return 0
  jq -r --argjson ai "${ai_expected:-0}" '
    .[] |
    . as $p |
    (if   ($p.mergeable // "") == "CONFLICTING" then "conflict"
     elif ($p.checks // "NONE") == "FAIL"       then "checks"
     elif ($p.draft // false)                    then "draft"
     elif ($p.checks // "NONE") == "PENDING"     then "wait"
     elif ($p.mergeable // "") == "UNKNOWN"      then "wait"
     elif (($p.unresolved // 0) > 0)             then "threads"
     elif ($ai == 1 and (($p.ai_review // false) | not)) then "ai-review"
     elif (($p.approvals // 0) == 0)             then "review"
     else "ready" end) as $v |
    (if   $v == "conflict"  then "merge state is CONFLICTING — rebase onto the base"
     elif $v == "checks"    then "a required check is failing"
     elif $v == "draft"     then "still a draft"
     elif $v == "wait"      then (if ($p.mergeable // "") == "UNKNOWN" and ($p.checks // "NONE") != "PENDING"
                                  then "GitHub is still computing mergeability — re-check before merging"
                                  else "checks still running" end)
     elif $v == "threads"   then "\($p.unresolved) unresolved review thread(s)"
     elif $v == "ai-review" then "no AI-reviewer pass yet"
     elif $v == "review"    then "no human approval yet"
     else "green and approved — mergeable" end) as $d |
    # Escape `|`: the row is rendered into a markdown table, and an unescaped pipe in a PR title
    # silently splits the cell — the title is attacker-adjacent text, not a controlled string.
    [$v, ($p.number|tostring), ($p.title // "" | .[0:58] | gsub("\\|"; "\\|")), $d] | @tsv
  ' 2>/dev/null || true
}

# status_prs_fetch — echo the shaped JSON array status_prs_classify expects, for the repo in
# $KIT_REPO. ONE `gh api graphql` call: open PRs with their reviews, review threads and the head
# commit's check rollup, collapsed to the four scalars the classifier reads.
#
# It always PRINTS a valid JSON array, but the rc distinguishes the two cases a caller must not
# conflate: rc 0 means the query ran (`[]` = genuinely no open PRs), rc 1 means it could not run
# (no gh, no jq, no auth, no network) and `[]` means "unknown", not "none". Reporting an empty
# bucket for an unreachable API is the failure this whole report exists to avoid.
status_prs_fetch() {
  local repo="${1:-${KIT_REPO:-}}" owner name raw
  command -v gh >/dev/null 2>&1 || { echo '[]'; return 1; }
  command -v jq >/dev/null 2>&1 || { echo '[]'; return 1; }
  case "$repo" in */*) owner="${repo%%/*}"; name="${repo##*/}" ;; *) echo '[]'; return 1 ;; esac

  raw="$(gh api graphql -f owner="$owner" -f name="$name" -f query='
    query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        pullRequests(states:OPEN, first:30, orderBy:{field:UPDATED_AT,direction:DESC}){
          nodes{
            number title isDraft mergeable
            reviews(first:60){ nodes{ state author{ login } } }
            reviewThreads(first:60){ nodes{ isResolved } }
            commits(last:1){ nodes{ commit{ statusCheckRollup{
              contexts(first:30){ nodes{
                __typename
                ... on CheckRun{ name conclusion startedAt }
                ... on StatusContext{ context state createdAt }
              } }
            } } } }
          }
        }
      }
    }' 2>/dev/null)" || raw=""
  [ -n "$raw" ] || { echo '[]'; return 1; }

  printf '%s' "$raw" | jq -c '
    def is_bot: test("(?i)(coderabbit|copilot|\\[bot\\]|-bot$|dependabot|renovate|sonar|codex)");
    # Latest run per check name only. A re-run (or a PR retitle re-firing a title gate) leaves the
    # superseded run in the rollup; counting every context then reports a PR as failing on a check
    # that has since passed. Group by name, keep the newest timestamp, read the verdict of that one.
    def rollup:
      [ (.commits.nodes[0].commit.statusCheckRollup.contexts.nodes // [])[]
        | { name: (.name // .context // ""),
            at:   (.startedAt // .createdAt // ""),
            verdict: (.conclusion // .state // "") } ]
      | group_by(.name)
      | map(sort_by(.at) | last | .verdict);
    [ (.data.repository.pullRequests.nodes // [])[]
      | { number, title,
          draft: .isDraft,
          mergeable: .mergeable,
          checks: ( rollup as $r
            | if   ($r | length) == 0                                            then "NONE"
              elif ($r | map(select(. == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED" or . == "ERROR" or . == "ACTION_REQUIRED")) | length) > 0 then "FAIL"
              elif ($r | map(select(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or . == "EXPECTED" or . == "")) | length) > 0 then "PENDING"
              else "PASS" end ),
          approvals: ( [ (.reviews.nodes // [])[]
                         | select(.state == "APPROVED")
                         | select((.author.login // "") | is_bot | not) ] | length ),
          ai_review: ( [ (.reviews.nodes // [])[]
                         | select((.author.login // "") | is_bot) ] | length > 0 ),
          unresolved: ( [ (.reviewThreads.nodes // [])[] | select(.isResolved == false) ] | length )
        } ]
  ' 2>/dev/null || echo '[]'
}

# status_ai_expected [root] [prs-json] — rc 0 (and echo 1) when this repo evidently uses an AI
# reviewer, else echo 0. Two signals, both observable: a reviewer config file in the repo, or an AI
# review already present on one of the open PRs. Without this, `ai-review` would fire on every PR in
# a repo that has no AI reviewer, which is noise, not a finding. Pure given its inputs.
status_ai_expected() {
  local root="${1:-.}" prs="${2:-[]}" f
  for f in .coderabbit.yaml .coderabbit.yml .github/coderabbit.yaml .codex/config.toml; do
    [ -f "$root/$f" ] && { printf '1'; return 0; }
  done
  if command -v jq >/dev/null 2>&1; then
    case "$(printf '%s' "$prs" | jq -r 'map(select(.ai_review == true)) | length' 2>/dev/null)" in
      ''|0) : ;;
      *) printf '1'; return 0 ;;
    esac
  fi
  printf '0'
}

# ── bucket 3: cleanup available ────────────────────────────────────────────────────────────────

# status_cleanup_counts — echo `safe<TAB>orphan<TAB>protected<TAB>remote_stale<TAB>unknown` for the
# current repo. `unknown` (#330) counts the branches gc could not classify because a gh read failed:
# without it a GitHub outage reads as "0 orphan / 0 protected", i.e. as a clean repo.
# The local three come from kit_gc_analyze (the ONE classifier, so status and gc can never disagree);
# `remote_stale` counts remote branches whose PR is merged and which are therefore deletable — the
# half `gc --prune` does not touch and a plain `git branch` view never shows.
# best-effort: an unavailable classifier yields zeros, never a broken bucket.
status_cleanup_counts() {
  local out safe=0 orphan=0 prot=0 rstale=0 unknown=0 r b st
  if command -v kit_gc_analyze >/dev/null 2>&1; then
    out="$(kit_gc_analyze 2>/dev/null || true)"
    safe="$(printf '%s\n'   "$out" | grep -c -- '> SAFE '      || true)"
    orphan="$(printf '%s\n' "$out" | grep -c -- '> ORPHAN'     || true)"
    prot="$(printf '%s\n'   "$out" | grep -c -- '> PROTECTED:' || true)"
    unknown="$(printf '%s\n' "$out" | grep -c -- '> UNKNOWN '  || true)"
  fi
  if command -v git >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    local base="${KIT_BASE_BRANCH:-main}" idx
    # ONE PR query, reusing gc's index (#124) instead of a `gh pr list --head` per branch — an N+1
    # that scales badly exactly when this count matters, i.e. with many stale branches. And
    # `while IFS= read -r`, not `for … in $(…)`: an ambient IFS carrying a NUL breaks word
    # splitting on a bare `for` (a bug this repo has already been bitten by).
    if command -v _kit_gc_pr_index >/dev/null 2>&1; then
      # 2>/dev/null: a failed read already shows as `unknown` rows from kit_gc_analyze above.
      idx="$(_kit_gc_pr_index "${KIT_GC_REPO:-${KIT_REPO:-}}" 2>/dev/null || true)"
    else
      idx="$(gh pr list --repo "${KIT_REPO:-}" --state all --limit 200 \
               --json number,state,headRefName \
               --jq '.[] | "\(.headRefName)\tPR#\(.number) \(.state)"' 2>/dev/null || true)"
    fi
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      b="${r#origin/}"
      case "$b" in "$base"|main|master|develop) continue ;; esac
      st="$(printf '%s\n' "$idx" | awk -F'\t' -v want="$b" '$1==want && !hit {print $2; hit=1}')"
      case "$st" in *MERGED*) rstale=$((rstale + 1)) ;; *) : ;; esac
    done <<EOT
$(git branch -r --format='%(refname:short)' 2>/dev/null | grep -v HEAD || true)
EOT
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "${safe:-0}" "${orphan:-0}" "${prot:-0}" "${rstale:-0}" "${unknown:-0}"
}

# ── instruction-file budget ────────────────────────────────────────────────────────────────────

# status_instruction_budget [kit_root] — one line: the resident instruction-file total against the
# 150k limit and the three largest files, for the project the command is run in (#357). Claude Code
# warns at startup once CLAUDE.md + the rules without `paths:` pass that limit; this puts the number
# in front of the reader before the warning does.
#
# The measurement is scripts/instruction-budget-lint.sh --summary — the ONE implementation, so the
# status line, the doctor row and the gate can never disagree. KIT_INSTRUCTION_LINT overrides where
# it is looked up. best-effort: no lint, or nothing to measure, prints nothing.
status_instruction_budget() {
  local root="${1:-.}" lint proj
  lint="${KIT_INSTRUCTION_LINT:-$root/scripts/instruction-budget-lint.sh}"
  [ -f "$lint" ] || return 0
  proj="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$proj" ] || proj="$PWD"
  INSTRUCTION_BUDGET_ROOT="$proj" bash "$lint" --summary 2>/dev/null || true
}

# ── next effort per flow ───────────────────────────────────────────────────────────────────────

# status_next_efforts_rows [repo] — `flow<TAB>number<TAB>ctx<TAB>title<TAB>waiting`, one row per flow
# that has an open effort: the next effort that can start (no open blocker; p0 → p3, then the lowest
# number), or `-` when every effort in the flow is blocked. The pick is `effort_next_rows`
# (scripts/lib/effort-plan.sh), which the caller sources — status.sh does, next to kit-gc.sh.
# rc 1 when the efforts could not be read, or that lib is not loaded: unknown, not empty.
status_next_efforts_rows() {
  command -v effort_next_rows >/dev/null 2>&1 || return 1
  effort_next_rows "${1:-${KIT_REPO:-}}"
}

# status_next_efforts_md [repo] — the section as markdown. It states its own emptiness, and tells
# "no effort" apart from "could not read", for the same reason the buckets below do.
status_next_efforts_md() {
  local rows ne_rc=0 flow num ctx title waiting
  echo "## Next effort per flow"
  echo ""
  rows="$(status_next_efforts_rows "${1:-}")" || ne_rc=$?
  if [ "$ne_rc" -ne 0 ]; then
    echo "_Could not read the open efforts (gh or jq absent, unauthenticated, or offline). This is NOT"
    echo "the same as having none._"
  elif [ -z "$rows" ]; then
    echo "_No open issue carries the \`effort\` label, so there is no effort to order."
    echo "\`cckit effort new\` applies the label; an effort created without it is invisible here._"
  else
    echo "| flow | next effort | ctx | waiting on a blocker |"
    echo "| --- | --- | --- | --- |"
    while IFS="$(printf '\t')" read -r flow num ctx title waiting; do
      [ -n "$flow" ] || continue
      if [ "$num" = "-" ]; then
        printf '| %s | _none can start — every open effort has an open blocker_ | — | %s |\n' "$flow" "$waiting"
      else
        printf '| %s | **E%s** — %s | %s | %s |\n' "$flow" "$num" "$title" "$ctx" "$waiting"
      fi
    done <<EOF
$rows
EOF
    echo ""
    echo "_\`cckit effort start <N>\` starts one; \`cckit effort plan\` shows each flow's full order._"
  fi
  if command -v effort_cadence_md >/dev/null 2>&1; then
    echo ""
    effort_cadence_md
  fi
}

# ── light tasks (#487) ─────────────────────────────────────────────────────────────────────────
# A project whose work is tracked with `cckit task` has no GitHub issue per task, so the board
# section reads "open issues: 0" while five tasks are open. These read the task source
# (task-source.sh) — local git only: no fetch, no gh call.

# status_light_task_rows — every light task as the source's TSV rows
# (`id<TAB>state<TAB>priority<TAB>kind<TAB>created<TAB>branch<TAB>title`). Empty when the project
# has none, when it is not a git repository, or when task-source.sh is not there to load.
status_light_task_rows() {
  if ! command -v task_source_call >/dev/null 2>&1; then
    local _ks_dir
    _ks_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
    # shellcheck source=task-source.sh
    [ -f "$_ks_dir/task-source.sh" ] && . "$_ks_dir/task-source.sh"
  fi
  command -v task_source_call >/dev/null 2>&1 || return 0
  git rev-parse --show-toplevel >/dev/null 2>&1 || return 0
  task_source_call list 2>/dev/null || true
}

# status_light_task_counts — stdin: those rows. stdout: one line,
# `draft<TAB>todo<TAB>shared<TAB>doing<TAB>review<TAB>done<TAB>dropped`.
status_light_task_counts() {
  awk -F'\t' '
    NF >= 2 { n[$2]++ }
    END { printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\n", n["draft"], n["todo"], n["shared"], n["doing"], n["review"], n["done"], n["dropped"] }'
}

# status_light_task_attention — stdin: those rows. stdout: `id<TAB>state<TAB>title<TAB>needs` for
# the tasks somebody has to act on: review first (a pull request is waiting), then doing, then
# draft and shared (not on the shared list yet). `todo` is only counted: nothing is wrong with it.
status_light_task_attention() {
  awk -F'\t' '
    BEGIN { r["review"] = 1; r["doing"] = 2; r["draft"] = 3; r["shared"] = 4 }
    ($2 in r) {
      if ($2 == "review")      needs = "waiting for review: its pull request is open from " $6
      else if ($2 == "doing")  needs = "in progress on " $6 "; when ready: cckit task finish " $1 " \"<summary>\" --all"
      else if ($2 == "draft")  needs = "only in this checkout; start it (cckit task start " $1 ") or share the list (cckit task share)"
      else                     needs = "in a share pull request (" $6 ") that has not merged"
      print r[$2] "\t" $1 "\t" $2 "\t" $7 "\t" needs
    }' | sort -t "$(printf '\t')" -k1,1n -k2,2 | cut -f2-
}

# status_light_tasks_md — the section as markdown; prints nothing when the project has no light task.
status_light_tasks_md() {
  local rows counts c_draft c_todo c_shared c_doing c_review c_done c_dropped att id state title needs
  rows="$(status_light_task_rows)"
  [ -n "$rows" ] || return 0
  counts="$(printf '%s\n' "$rows" | status_light_task_counts)"
  IFS="$(printf '\t')" read -r c_draft c_todo c_shared c_doing c_review c_done c_dropped <<EOF
$counts
EOF
  echo "## Light tasks"
  echo ""
  printf 'review: %s   doing: %s   todo: %s   draft: %s   shared: %s   done: %s\n' \
    "$c_review" "$c_doing" "$c_todo" "$c_draft" "$c_shared" "$c_done"
  echo ""
  att="$(printf '%s\n' "$rows" | status_light_task_attention)"
  if [ -n "$att" ]; then
    echo "| task | state | title | what it needs |"
    echo "| --- | --- | --- | --- |"
    while IFS="$(printf '\t')" read -r id state title needs; do
      [ -n "$id" ] || continue
      printf '| `%s` | **%s** | %s | %s |\n' "$id" "$state" "$title" "$needs"
    done <<EOF
$att
EOF
  elif [ "$c_todo" -gt 0 ]; then
    echo "_Nothing is waiting on anyone. \`cckit next\` names the task to take._"
  else
    echo "_Every task is done._"
  fi
  echo ""
}

# ── the three-bucket report ────────────────────────────────────────────────────────────────────

# status_buckets_md [root] — the three buckets as markdown on stdout. Each bucket states its own
# emptiness explicitly ("nothing local-only", "no open PRs"), because a silently missing bucket is
# indistinguishable from a clean one and this report is read to decide what to do next.
status_buckets_md() {
  local root="${1:-.}" base="${KIT_BASE_BRANCH:-main}" rows prs ai prrows counts safe orphan prot rstale unknown
  local kind name detail verdict num title n_local budget_line

  echo "## 1 · Local undone work"
  echo ""
  rows="$(status_local_rows "$base")"
  n_local="$(printf '%s' "$rows" | grep -c . || true)"
  if [ "${n_local:-0}" -gt 0 ]; then
    while IFS="$(printf '\t')" read -r kind name detail; do
      [ -n "$kind" ] || continue
      case "$kind" in
        dirty)    printf -- '- **dirty** `%s` — %s\n' "$name" "$detail" ;;
        unpushed) printf -- '- **unpushed** `%s` — %s\n' "$name" "$detail" ;;
        unmerged) printf -- '- **unmerged sub** `%s` — %s\n' "$name" "$detail" ;;
        *)        printf -- '- %s `%s` — %s\n' "$kind" "$name" "$detail" ;;
      esac
    done <<EOF
$rows
EOF
  else
    echo "_Nothing local-only: every worktree is clean and every branch's commits are pushed._"
  fi

  local wt_rows n_wt n_all
  wt_rows="$(status_inprogress_rows)"
  n_wt="$(printf '%s' "$wt_rows" | grep -c . || true)"
  n_all="$(status_worktree_rows | grep -c . || true)"
  if [ "${n_wt:-0}" -gt 0 ]; then
    echo ""
    printf -- '**In progress** — %s worktree(s) checked out:\n\n' "${n_wt:-0}"
    while IFS="$(printf '\t')" read -r name detail; do
      [ -n "$name" ] || continue
      printf -- '- `%s` — `%s`\n' "${name##*/}" "$detail"
    done <<EOF
$wt_rows
EOF
  fi
  if [ "${n_all:-0}" -gt "${n_wt:-0}" ]; then
    echo ""
    printf -- '_%s detached worktree(s) hold nothing to lose (clean, HEAD on the base branch) and are not listed — `cckit cleanup` removes them._\n' \
      "$((n_all - n_wt))"
  fi

  echo ""
  echo "## 2 · PRs waiting on a human"
  echo ""
  if command -v gh >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    local pr_rc=0
    prs="$(status_prs_fetch)" || pr_rc=$?
    ai="$(status_ai_expected "$root" "$prs")"
    prrows="$(printf '%s' "$prs" | status_prs_classify "$ai")"
    if [ "$pr_rc" -ne 0 ]; then
      echo "_Could not read the open PRs (gh unavailable, unauthenticated, or offline). This is NOT"
      echo "the same as having none — re-run once \`gh auth status\` is clean._"
    elif [ -n "$prrows" ]; then
      echo "| PR | what it needs | title |"
      echo "| --- | --- | --- |"
      while IFS="$(printf '\t')" read -r verdict num title detail; do
        [ -n "$num" ] || continue
        printf '| #%s | **%s** — %s | %s |\n' "$num" "$verdict" "$detail" "$title"
      done <<EOF
$prrows
EOF
      [ "$ai" = "1" ] || echo ""
      [ "$ai" = "1" ] || echo "_This repo shows no AI reviewer, so a missing AI pass is not reported._"
    else
      echo "_No open PRs._"
    fi
  else
    echo "_gh or jq absent — this bucket needs both._"
  fi

  echo ""
  echo "## 3 · Cleanup available"
  echo ""
  counts="$(status_cleanup_counts)"
  safe="${counts%%	*}"; counts="${counts#*	}"
  orphan="${counts%%	*}"; counts="${counts#*	}"
  prot="${counts%%	*}"; counts="${counts#*	}"
  rstale="${counts%%	*}"; unknown="${counts##*	}"
  if [ "${safe:-0}" -gt 0 ] || [ "${rstale:-0}" -gt 0 ]; then
    printf -- '- **%s** local branch(es) SAFE to delete — merged PR, issue closed\n' "${safe:-0}"
    printf -- '- **%s** remote branch(es) whose PR merged\n' "${rstale:-0}"
    printf -- '- kept: %s orphan (commits not on the base remote), %s protected (issue still open)\n' \
      "${orphan:-0}" "${prot:-0}"
    echo ""
    echo "_\`cckit cleanup\` shows the plan; \`--yes\` acts on it._"
  else
    printf -- '_Nothing to clean. %s orphan / %s protected branch(es) are kept by design._\n' \
      "${orphan:-0}" "${prot:-0}"
  fi
  if [ "${unknown:-0}" -gt 0 ]; then
    echo ""
    printf -- '- **%s** branch(es) could not be classified — a GitHub read failed. They are kept; the counts above are incomplete until `cckit gc` can read GitHub.\n' "${unknown:-0}"
  fi

  # Not a fourth bucket — nothing here is work to do — so it is one line, and absent when there is
  # nothing to measure.
  budget_line="$(status_instruction_budget "$root")"
  if [ -n "$budget_line" ]; then
    echo ""
    echo "## Instruction files"
    echo ""
    printf -- '- %s\n' "$budget_line"
  fi
}

# status_buckets_json [root] — the same three buckets as one JSON object, for an agent. Same
# classifiers as the markdown path, so the two can never disagree about a verdict.
status_buckets_json() {
  local root="${1:-.}" base="${KIT_BASE_BRANCH:-main}" rows prs ai prrows counts safe orphan prot rstale unknown
  # No jq means no JSON at all. Emitting `{}` with rc 0 would hand an agent an empty report that
  # reads as "nothing to do" — the exact confusion the markdown path is careful to avoid.
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' '{"error":"jq is required for --llm output","deps":{"jq":false}}'; return 1; }
  local pr_rc=0 has_gh=false has_git=false
  command -v gh  >/dev/null 2>&1 && has_gh=true
  command -v git >/dev/null 2>&1 && has_git=true
  rows="$(status_local_rows "$base")"
  local wt_rows; wt_rows="$(status_worktree_rows)"
  prs="$(status_prs_fetch)" || pr_rc=$?
  ai="$(status_ai_expected "$root" "$prs")"
  prrows="$(printf '%s' "$prs" | status_prs_classify "$ai")"
  counts="$(status_cleanup_counts)"
  safe="${counts%%	*}"; counts="${counts#*	}"
  orphan="${counts%%	*}"; counts="${counts#*	}"
  prot="${counts%%	*}"; counts="${counts#*	}"
  rstale="${counts%%	*}"; unknown="${counts##*	}"
  # `instruction files: <resident> of <limit> bytes resident …` — fields 3 and 5 are the numbers.
  local budget_line budget_resident budget_limit
  budget_line="$(status_instruction_budget "$root")"
  budget_resident="$(printf '%s' "$budget_line" | awk '{print $3}')"
  budget_limit="$(printf '%s' "$budget_line" | awk '{print $5}')"
  case "$budget_resident" in ''|*[!0-9]*) budget_resident=0; budget_line="" ;; esac
  case "$budget_limit"    in ''|*[!0-9]*) budget_limit=0 ;; esac
  local ne_rows ne_rc=0
  ne_rows="$(status_next_efforts_rows)" || ne_rc=$?
  local lt_rows lt_counts="" lt_att=""
  lt_rows="$(status_light_task_rows)"
  if [ -n "$lt_rows" ]; then
    lt_counts="$(printf '%s\n' "$lt_rows" | status_light_task_counts)"
    lt_att="$(printf '%s\n' "$lt_rows" | status_light_task_attention)"
  fi

  jq -n \
    --arg lt_counts "$lt_counts" --arg lt_att "$lt_att" \
    --arg ne_rows "$ne_rows" \
    --argjson ne_read "$([ "$ne_rc" -eq 0 ] && echo true || echo false)" \
    --arg local_rows "$rows" \
    --arg wt_rows "$wt_rows" \
    --arg pr_rows "$prrows" \
    --argjson safe "${safe:-0}" --argjson orphan "${orphan:-0}" \
    --argjson protected "${prot:-0}" --argjson remote_stale "${rstale:-0}" \
    --argjson unknown "${unknown:-0}" \
    --argjson ai_expected "${ai:-0}" \
    --argjson prs_read "$([ "$pr_rc" -eq 0 ] && echo true || echo false)" \
    --argjson has_gh "$has_gh" --argjson has_git "$has_git" \
    --arg budget_line "$budget_line" \
    --argjson budget_resident "$budget_resident" --argjson budget_limit "$budget_limit" '
    def rows($s): if ($s | length) == 0 then [] else ($s | rtrimstr("\n") | split("\n") | map(select(length > 0) | split("\t"))) end;
    { local_undone: (rows($local_rows) | map({kind: .[0], name: .[1], detail: .[2]})),
      worktrees:    (rows($wt_rows)    | map({path: .[0], branch: .[1]})),
      prs:          (rows($pr_rows)    | map({verdict: .[0], number: (.[1]|tonumber?), title: .[2], detail: .[3]})),
      # `unknown` > 0 means a GitHub read failed and those branches are unclassified, not clean (#330).
      cleanup:      { safe: $safe, orphan: $orphan, protected: $protected, remote_stale: $remote_stale, unknown: $unknown },
      # null means nothing was measured (no CLAUDE.md and no rules, or the lint is absent) — not zero.
      instruction_budget: (if $budget_line == "" then null else
        { resident_bytes: $budget_resident, limit_bytes: $budget_limit, summary: $budget_line } end),
      # One row per flow with an open effort. `number: null` = every effort in that flow has an open
      # blocker. The whole key is `null` (not `[]`) when the efforts could not be read.
      next_efforts: (if $ne_read then (rows($ne_rows) | map({flow: .[0], number: (.[1] | tonumber? // null),
                        ctx: (if .[2] == "-" then null else .[2] end),
                        title: (if .[3] == "-" then null else .[3] end),
                        waiting: (.[4] | tonumber? // 0)})) else null end),
      # null = the project has no light task. `attention` holds the tasks somebody has to act on
      # (review, doing, draft, shared); `todo` and `done` are only counted. Read from local git.
      light_tasks: (if $lt_counts == "" then null else
        ($lt_counts | split("\t") | map(tonumber? // 0)) as $c
        | { counts: { draft: $c[0], todo: $c[1], shared: $c[2], doing: $c[3], review: $c[4], done: $c[5], dropped: $c[6] },
            attention: (rows($lt_att) | map({id: .[0], state: .[1], title: .[2], needs: .[3]})) } end),
      ai_review_expected: ($ai_expected == 1),
      # `prs_read: false` means the PR bucket is UNKNOWN, not empty — never treat its `[]` as "none".
      prs_read: $prs_read,
      deps: { git: $has_git, gh: $has_gh, jq: true } }
  ' 2>/dev/null || { printf '%s\n' '{"error":"could not compose the status report"}'; return 1; }
  # A report that could not read the PR bucket is not a clean report: signal it in the exit status
  # too, so a caller that only checks rc does not act on a half-known state.
  [ "$pr_rc" -eq 0 ]
}
