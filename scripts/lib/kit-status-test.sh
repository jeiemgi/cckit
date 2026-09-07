#!/bin/sh
# kit-status-test.sh — self-test for kit-status.sh, the three-bucket "where are we?" report (#229).
# Network-free: the PR classifier is pure, so every verdict runs against fixture JSON, and the local
# bucket runs against a throwaway repo with fabricated remote refs. That matters more here than
# elsewhere — these verdicts tell a human what to do next, and a wrong one sends them to the wrong
# place. Every assertion runs under bash AND zsh.
# Run:  bash scripts/lib/kit-status-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KS_TEST_INNER:-}" ]; then
  fail=0
  eq()  { if [ "$2" = "$3" ]; then :; else echo "FAIL($KS_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
  has() { case "$2" in *"$3"*) : ;; *) echo "FAIL($KS_TEST_INNER): $1 -> '$2' lacks '$3'"; fail=1 ;; esac; }
  no()  { case "$2" in *"$3"*) echo "FAIL($KS_TEST_INNER): $1 -> '$2' should not contain '$3'"; fail=1 ;; *) : ;; esac; }

  # shellcheck source=/dev/null
  . "$dir/kit-status.sh"

  command -v jq >/dev/null 2>&1 || { echo "  (jq absent — skipping the PR classifier)"; }

  if command -v jq >/dev/null 2>&1; then
    # ── status_prs_classify: one verdict per PR, most-blocking first ───────────────────────────
    verdict() { printf '%s' "$2" | status_prs_classify "${3:-0}" | awk -F'\t' -v n="$1" '$2==n{print $1}'; }

    fix='[
      {"number":1,"title":"conflicting","draft":false,"mergeable":"CONFLICTING","checks":"PASS","approvals":2,"ai_review":true,"unresolved":0},
      {"number":2,"title":"red checks","draft":false,"mergeable":"MERGEABLE","checks":"FAIL","approvals":2,"ai_review":true,"unresolved":0},
      {"number":3,"title":"a draft","draft":true,"mergeable":"MERGEABLE","checks":"PASS","approvals":0,"ai_review":false,"unresolved":0},
      {"number":4,"title":"still running","draft":false,"mergeable":"MERGEABLE","checks":"PENDING","approvals":0,"ai_review":true,"unresolved":0},
      {"number":5,"title":"open threads","draft":false,"mergeable":"MERGEABLE","checks":"PASS","approvals":1,"ai_review":true,"unresolved":3},
      {"number":6,"title":"no ai pass","draft":false,"mergeable":"MERGEABLE","checks":"PASS","approvals":1,"ai_review":false,"unresolved":0},
      {"number":7,"title":"needs a human","draft":false,"mergeable":"MERGEABLE","checks":"PASS","approvals":0,"ai_review":true,"unresolved":0},
      {"number":8,"title":"good to go","draft":false,"mergeable":"MERGEABLE","checks":"PASS","approvals":1,"ai_review":true,"unresolved":0}
    ]'
    eq "a conflicting PR reads conflict"        "$(verdict 1 "$fix" 1)" "conflict"
    eq "a red check reads checks"               "$(verdict 2 "$fix" 1)" "checks"
    eq "a draft reads draft"                    "$(verdict 3 "$fix" 1)" "draft"
    eq "running checks read wait"               "$(verdict 4 "$fix" 1)" "wait"
    eq "unresolved threads read threads"        "$(verdict 5 "$fix" 1)" "threads"
    eq "a missing AI pass reads ai-review"      "$(verdict 6 "$fix" 1)" "ai-review"
    eq "no approval reads review"               "$(verdict 7 "$fix" 1)" "review"
    eq "green and approved reads ready"         "$(verdict 8 "$fix" 1)" "ready"

    # Precedence is the whole point: a conflicting PR with red checks AND open threads must report
    # the conflict, because the other two cannot be acted on until it is rebased.
    prec='[{"number":9,"title":"all at once","draft":true,"mergeable":"CONFLICTING","checks":"FAIL","approvals":0,"ai_review":false,"unresolved":5}]'
    eq "conflict outranks every other signal"   "$(verdict 9 "$prec" 1)" "conflict"
    prec2='[{"number":10,"title":"red + threads","draft":false,"mergeable":"MERGEABLE","checks":"FAIL","approvals":0,"ai_review":false,"unresolved":5}]'
    eq "red checks outrank open threads"        "$(verdict 10 "$prec2" 1)" "checks"
    prec3='[{"number":11,"title":"threads + no approval","draft":false,"mergeable":"MERGEABLE","checks":"PASS","approvals":0,"ai_review":true,"unresolved":2}]'
    eq "open threads outrank a missing approval" "$(verdict 11 "$prec3" 1)" "threads"

    # With no AI reviewer in the repo, a missing AI pass must NOT be reported — otherwise every PR
    # in a repo that has none reads as needing something it will never get. Same PR, both settings:
    # #6 has an approval already, so it falls through to `ready`; #12 has none, so it needs a human.
    eq "no AI reviewer: an approved PR is ready"   "$(verdict 6 "$fix" 0)" "ready"
    unapproved='[{"number":12,"title":"nobody looked","draft":false,"mergeable":"MERGEABLE","checks":"PASS","approvals":0,"ai_review":false,"unresolved":0}]'
    eq "AI expected: an unreviewed PR asks for the AI pass first" \
       "$(verdict 12 "$unapproved" 1)" "ai-review"
    eq "no AI reviewer: the same PR asks for a human" \
       "$(verdict 12 "$unapproved" 0)" "review"

    # The row carries the number, a trimmed title and a human reason for the verdict.
    row="$(printf '%s' "$fix" | status_prs_classify 1 | awk -F'\t' '$2==5')"
    has "row carries the unresolved count" "$row" "3 unresolved review thread(s)"
    has "row carries the title"            "$row" "open threads"
    eq  "an empty PR set yields no rows"    "$(printf '[]' | status_prs_classify 1)" ""

    # ── status_ai_expected ────────────────────────────────────────────────────────────────────
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/none"
    eq "no config and no AI review: not expected" "$(status_ai_expected "$tmp/none" '[]')" "0"
    mkdir -p "$tmp/cfg"; : > "$tmp/cfg/.coderabbit.yaml"
    eq "a reviewer config means expected"         "$(status_ai_expected "$tmp/cfg" '[]')" "1"
    eq "an AI review already present means expected" \
       "$(status_ai_expected "$tmp/none" '[{"ai_review":true}]')" "1"
    eq "PRs with no AI review keep it unexpected" \
       "$(status_ai_expected "$tmp/none" '[{"ai_review":false}]')" "0"
  else
    tmp="$(mktemp -d)"
  fi

  # ── status_local_rows + status_worktree_rows, against a throwaway repo ───────────────────────
  if command -v git >/dev/null 2>&1; then
    repo="$tmp/r"; mkdir -p "$repo"
    ( cd "$repo" && git init -q . && git config user.email t@t && git config user.name t \
      && echo base > f.txt && git add -A && git commit -q -m init \
      && git branch -M trunk \
      && git update-ref refs/remotes/origin/trunk "$(git rev-parse HEAD)" ) >/dev/null 2>&1

    # A branch whose commit is reachable from a remote ref is NOT undone work, even with no upstream
    # configured — this is the effort-sub case that a naive `@{u}` comparison gets wrong.
    ( cd "$repo" && git branch -q pushed/1-thing \
      && git update-ref refs/remotes/origin/pushed/1-thing "$(git rev-parse HEAD)" ) >/dev/null 2>&1
    rows="$(cd "$repo" && status_local_rows trunk)"
    no "a branch already on a remote is not unpushed" "$rows" "pushed/1-thing"

    # A branch with a commit on no remote at all IS undone work.
    ( cd "$repo" && git checkout -q -b local/2-only && echo more >> f.txt \
      && git commit -qam second && git checkout -q trunk ) >/dev/null 2>&1
    rows="$(cd "$repo" && status_local_rows trunk)"
    has "a commit on no remote is unpushed"     "$rows" "local/2-only"
    has "the row says it is on no remote"       "$rows" "on no remote"
    has "the row counts the commits"            "$rows" "1 commit(s)"

    # The base branch itself is never listed as undone work.
    no  "the base branch is not a row"          "$rows" "$(printf 'unpushed\ttrunk')"

    # A dirty worktree is a row, and its file count is real.
    ( cd "$repo" && echo scratch > untracked.txt ) >/dev/null 2>&1
    rows="$(cd "$repo" && status_local_rows trunk)"
    has "a dirty worktree is a row"             "$rows" "dirty"
    has "the dirty row counts the files"        "$rows" "1 uncommitted file(s)"

    # A clean repo with everything pushed produces no rows at all — the bucket must be able to be
    # empty, or "nothing to do" is indistinguishable from "the check is broken".
    clean="$tmp/c"; mkdir -p "$clean"
    ( cd "$clean" && git init -q . && git config user.email t@t && git config user.name t \
      && echo a > a.txt && git add -A && git commit -q -m init && git branch -M trunk \
      && git update-ref refs/remotes/origin/trunk "$(git rev-parse HEAD)" ) >/dev/null 2>&1
    eq "a clean, fully pushed repo yields no rows" "$(cd "$clean" && status_local_rows trunk)" ""

    # An effort sub not merged into its effort branch is called out.
    eff="$tmp/e"; mkdir -p "$eff"
    ( cd "$eff" && git init -q . && git config user.email t@t && git config user.name t \
      && echo a > a.txt && git add -A && git commit -q -m init && git branch -M trunk \
      && git update-ref refs/remotes/origin/trunk "$(git rev-parse HEAD)" \
      && git checkout -q -b effort/50-thing \
      && git checkout -q -b sub/51-part && echo b > b.txt && git add -A && git commit -q -m sub \
      && git checkout -q trunk ) >/dev/null 2>&1
    rows="$(cd "$eff" && status_local_rows trunk)"
    has "an unmerged sub is reported"    "$rows" "unmerged"
    has "the unmerged row names the effort branch" "$rows" "not in effort/50-thing"
    # …and once merged, it stops being reported.
    ( cd "$eff" && git checkout -q effort/50-thing && git merge -q --no-ff -m merge sub/51-part \
      && git checkout -q trunk ) >/dev/null 2>&1
    rows="$(cd "$eff" && status_local_rows trunk)"
    no  "a merged sub is no longer reported" "$rows" "unmerged"

    # status_worktree_rows lists the checkout itself, with the branch it is on.
    wt="$(cd "$repo" && status_worktree_rows)"
    has "the worktree inventory names the branch" "$wt" "trunk"
    eq  "one row per checked-out worktree" "$(printf '%s\n' "$wt" | grep -c . | tr -d ' ')" "1"

    # status_cleanup_counts must return four integers even with no classifier loaded.
    counts="$(cd "$clean" && status_cleanup_counts)"
    eq "cleanup counts are four fields" \
       "$(printf '%s' "$counts" | awk -F'\t' '{print NF}')" "4"
    case "$counts" in
      *[!0-9$(printf '\t')]*) echo "FAIL($KS_TEST_INNER): cleanup counts must be integers -> '$counts'"; fail=1 ;;
      *) : ;;
    esac
  else
    echo "  (git absent — skipping the local bucket)"
  fi

  # ── the JSON shape an agent reads ───────────────────────────────────────────────────────────
  if command -v jq >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then
    js="$(cd "$clean" && KIT_BASE_BRANCH=trunk KIT_REPO="" status_buckets_json "$clean")"
    eq "JSON is an object"                "$(printf '%s' "$js" | jq -r 'type')" "object"
    eq "JSON carries local_undone"        "$(printf '%s' "$js" | jq -r '.local_undone | type')" "array"
    eq "JSON carries worktrees"           "$(printf '%s' "$js" | jq -r '.worktrees | type')" "array"
    eq "JSON carries prs"                 "$(printf '%s' "$js" | jq -r '.prs | type')" "array"
    eq "JSON carries the cleanup counts"  "$(printf '%s' "$js" | jq -r '.cleanup | keys | join(",")')" \
       "orphan,protected,remote_stale,safe"
    eq "an empty bucket is [] not null"   "$(printf '%s' "$js" | jq -r '.local_undone | length')" "0"
    eq "ai_review_expected is a boolean"  "$(printf '%s' "$js" | jq -r '.ai_review_expected | type')" "boolean"
  fi

  rm -rf "$tmp"
  if [ "$fail" -eq 0 ]; then echo "PASS($KS_TEST_INNER): kit-status buckets + PR verdicts"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  KS_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
