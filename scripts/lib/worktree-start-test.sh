#!/usr/bin/env bash
# worktree-start-test.sh — wt_start sees live session claims (#384).
#
# The bug: a second `cckit start <N>` from another session got "reusing worktree" and rc 0, so two
# agents wrote one tree. The bar: a LIVE claim by another session refuses the start before any
# fetch, branch or worktree; `--force` / KIT_FORCE=1 proceeds; a dead session's claim is reaped;
# the claimant's own re-run stays a no-op; `cckit claims` lists and writes nothing.
#
# Hermetic: a throwaway repo with a local bare origin, a stubbed `gh` (no network, no auth) and a
# stubbed `zoxide` (so no temp path lands in the developer's jump database). A "session" is a
# background `sleep` whose pid is handed to wt_start through KIT_SESSION_PID.
#
# Run: bash scripts/lib/worktree-start-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
LIB="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$LIB/../.." && pwd)"
# shellcheck source=/dev/null
. "$LIB/test-env.sh" && test_env_seal
command -v jq >/dev/null 2>&1 || { echo "worktree-start-test: jq required" >&2; exit 1; }

fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> missing '$3' in [$2]"; fail=1 ;; esac; }

tmp="$(cd "$(mktemp -d 2>/dev/null || mktemp -d -t wst)" && pwd -P)"
SESS_A=""; SESS_B=""
cleanup() {
  [ -n "$SESS_A" ] && kill "$SESS_A" 2>/dev/null
  [ -n "$SESS_B" ] && kill "$SESS_B" 2>/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

# ── fixture: stubs, a bare origin with `main`, and a clone to start worktrees from ─────────────
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/usr/bin/env bash
# Every call is logged, so a test can assert a refusal made NO GitHub read.
printf '%s\n' "$*" >> "${GH_CALL_LOG:-/dev/null}"
case "$*" in
  *"issue view"*) echo '{"title":"Claimed thing","labels":[{"name":"kind:task"}]}' ;;
  *graphql*)      echo '{"data":{}}' ;;
  *)              echo '[]' ;;
esac
SH
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/zoxide"
chmod +x "$tmp/bin/gh" "$tmp/bin/zoxide"
PATH="$tmp/bin:$PATH"; export PATH
export GH_CALL_LOG="$tmp/gh.calls"; : > "$GH_CALL_LOG"

git init -q --bare "$tmp/origin.git"
git init -q "$tmp/repo"
(
  cd "$tmp/repo" || exit 1
  git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
  git checkout -q -b main
  printf '{ "kitVersion":"9.9.9", "project":{"name":"fx","slug":"fx"},\n  "github":{"repo":"octo/fx","owner":"octo","baseBranch":"main","projectsV2":false} }\n' > cckit.config.json
  git add cckit.config.json && git commit -q -m init
  git remote add origin "$tmp/origin.git" && git push -q origin main
) || { echo "FAIL: fixture repo setup"; exit 1; }
REPO="$tmp/repo"
REG="$REPO/.git/kit-sessions"

export WT_START_REPO="octo/fx" KIT_BASE_BRANCH="main" KIT_WT_INSTALL=0
# shellcheck source=/dev/null
. "$LIB/worktree-start.sh"

sleep 600 & SESS_A=$!
sleep 600 & SESS_B=$!

# start_as <session-pid> <args…> — wt_start from the main checkout, as that session.
start_as() { local sp="$1"; shift; ( cd "$REPO" && KIT_SESSION_PID="$sp" wt_start "$@" ); }
branches() { git -C "$REPO" for-each-ref --format='%(refname:short)' refs/heads | sort | tr '\n' ' '; }
worktrees() { git -C "$REPO" worktree list --porcelain | grep -c '^worktree '; }

# ── 1. first start: creates the worktree and writes the claim ──────────────────────────────────
out="$(start_as "$SESS_A" 7 2>/dev/null)"; rc=$?
t "first start succeeds" "$rc" "0"
WT7="$REPO/.claude/worktrees/task+7-claimed-thing"
t "first start prints path|branch|issue" "$out" "$WT7|task/7-claimed-thing|7"
t "claim file written" "$([ -f "$REG/issue-7.json" ] && echo yes || echo no)" "yes"
t "claim records the session pid" "$(jq -r .pid "$REG/issue-7.json" 2>/dev/null)" "$SESS_A"
t "claim records the worktree"    "$(jq -r .worktree "$REG/issue-7.json" 2>/dev/null)" "$WT7"
t "claim records the branch"      "$(jq -r .branch "$REG/issue-7.json" 2>/dev/null)" "task/7-claimed-thing"
t "claim records the issue"       "$(jq -r .issue "$REG/issue-7.json" 2>/dev/null)" "7"
t "claim records a start time"    "$(jq -r '.started | type' "$REG/issue-7.json" 2>/dev/null)" "number"

# ── 6. the EXISTING reader sees the claim (it reads .pid + .cwd, skips cache-*) ────────────────
_wt_session_owns "$REPO" "$WT7"; t "_wt_session_owns sees the wt_start claim" "$?" "0"
_wt_session_owns "$REPO" "$REPO/.claude/worktrees/task+8-nope"; t "_wt_session_owns is false for an unclaimed path" "$?" "1"

# ── 1. a second session is refused — and nothing is created, nothing is fetched or read ────────
# A second issue number makes "no new worktree, no new branch" observable: 7 already has both, so
# the refusal case that proves it is a claim on an issue whose worktree does NOT exist yet.
mkdir -p "$REG"
jq -n --argjson pid "$SESS_A" --arg host "$(hostname)" --arg wt "$REPO/.claude/worktrees/task+9-claimed-thing" \
  --argjson started "$(date +%s)" \
  '{issue:9, branch:"task/9-claimed-thing", worktree:$wt, cwd:$wt, pid:$pid, host:$host, started:$started}' \
  > "$REG/issue-9.json"
b_before="$(branches)"; w_before="$(worktrees)"; : > "$GH_CALL_LOG"
fetch_before="$(stat -f %m "$REPO/.git/FETCH_HEAD" 2>/dev/null || stat -c %Y "$REPO/.git/FETCH_HEAD" 2>/dev/null)"
err="$(start_as "$SESS_B" 9 2>&1 >/dev/null)"; rc=$?
t "second session on a claimed issue is refused (rc 1)" "$rc" "1"
has "refusal names the claimant pid" "$err" "pid $SESS_A"
has "refusal names the escape hatch" "$err" "--force"
t "refusal creates no branch"   "$(branches)" "$b_before"
t "refusal creates no worktree" "$(worktrees)" "$w_before"
t "refusal creates no worktree dir" "$([ -e "$REPO/.claude/worktrees/task+9-claimed-thing" ] && echo yes || echo no)" "no"
t "refusal makes no gh call (it runs before the issue read)" "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')" "0"
t "refusal runs before the fetch (FETCH_HEAD untouched)" \
  "$(stat -f %m "$REPO/.git/FETCH_HEAD" 2>/dev/null || stat -c %Y "$REPO/.git/FETCH_HEAD" 2>/dev/null)" "$fetch_before"
t "refusal leaves the claim with its owner" "$(jq -r .pid "$REG/issue-9.json")" "$SESS_A"

# The same refusal on the issue that already has a worktree: no "reusing worktree" success.
out="$(start_as "$SESS_B" 7 2>/dev/null)"; rc=$?
t "second session on a claimed, existing worktree is refused" "$rc" "1"
t "refused start prints no worktree line" "$out" ""

# ── 2. --force and KIT_FORCE=1 proceed ─────────────────────────────────────────────────────────
out="$(start_as "$SESS_B" --force 9 2>/dev/null)"; rc=$?
t "--force starts a claimed issue" "$rc" "0"
t "--force is not taken for the issue number" "$out" "$REPO/.claude/worktrees/task+9-claimed-thing|task/9-claimed-thing|9"
t "--force takes the claim over" "$(jq -r .pid "$REG/issue-9.json")" "$SESS_B"
out="$(start_as "$SESS_B" 7 --force 2>/dev/null)"; rc=$?
t "--force after the issue number also works" "$rc" "0"
t "claim 7 now belongs to the forcing session" "$(jq -r .pid "$REG/issue-7.json")" "$SESS_B"
out="$( cd "$REPO" && KIT_FORCE=1 KIT_SESSION_PID="$SESS_A" wt_start 7 2>/dev/null )"; rc=$?
t "KIT_FORCE=1 starts a claimed issue" "$rc" "0"
t "KIT_FORCE=1 takes the claim over" "$(jq -r .pid "$REG/issue-7.json")" "$SESS_A"
err="$(start_as "$SESS_A" --bogus 7 2>&1 >/dev/null)"; rc=$?
t "an unknown flag is refused, not read as the issue" "$rc" "1"

# ── 4. the claimant's own re-run is a no-op success ────────────────────────────────────────────
before="$(cat "$REG/issue-7.json")"
out="$(start_as "$SESS_A" 7 2>/dev/null)"; rc=$?
t "re-run by the claiming session succeeds" "$rc" "0"
t "re-run by the claiming session leaves the claim untouched" "$(cat "$REG/issue-7.json")" "$before"
# From inside the claim's own worktree, as a session with a DIFFERENT pid (an agent's fresh shell).
out="$( cd "$WT7" && KIT_SESSION_PID="$SESS_B" wt_start 7 2>/dev/null )"; rc=$?
t "re-run from the claim's own worktree succeeds" "$rc" "0"
t "re-run from the claim's own worktree prints the same line" "$out" "$WT7|task/7-claimed-thing|7"
t "re-run from the claim's own worktree leaves the claim untouched" "$(cat "$REG/issue-7.json")" "$before"
t "re-run added no worktree" "$(worktrees)" "3"

# ── 5. `cckit claims` lists the live claims and writes nothing ─────────────────────────────────
snap() { ( cd "$REG" && ls -la . && cat issue-*.json ) 2>/dev/null; }
before="$(snap)"
human="$( cd "$REPO" && "$ROOT/bin/cckit" claims 2>/dev/null )"; rc=$?
t "cckit claims exits 0" "$rc" "0"
has "cckit claims lists issue 7" "$human" "#7"
has "cckit claims lists the branch" "$human" "task/7-claimed-thing"
json="$( cd "$REPO" && "$ROOT/bin/cckit" claims --llm 2>/dev/null )"
t "cckit claims --llm is a JSON array of both live claims" "$(printf '%s' "$json" | jq -c '[.[].issue]' 2>/dev/null)" "[7,9]"
t "cckit claims --llm carries the pid" "$(printf '%s' "$json" | jq -r '.[0].pid' 2>/dev/null)" "$SESS_A"
t "cckit claims works from inside a worktree" "$( cd "$WT7" && "$ROOT/bin/cckit" claims --llm 2>/dev/null | jq -c '[.[].issue]' )" "[7,9]"
t "cckit claims writes nothing" "$(snap)" "$before"

# ── 3. a dead session's claim is reaped and the start proceeds ─────────────────────────────────
kill "$SESS_A" 2>/dev/null; wait "$SESS_A" 2>/dev/null; DEAD="$SESS_A"; SESS_A=""
before="$(snap)"
t "cckit claims hides a dead session's claim" "$( cd "$REPO" && "$ROOT/bin/cckit" claims --llm 2>/dev/null | jq -c '[.[].issue]' )" "[9]"
t "cckit claims does not reap it (read-only)" "$(snap)" "$before"
_wt_session_owns "$REPO" "$WT7"; t "_wt_session_owns is false once the session died" "$?" "1"
out="$(start_as "$SESS_B" 7 2>/dev/null)"; rc=$?
t "start over a dead session's claim proceeds" "$rc" "0"
t "the dead claim was replaced by the new session's" "$(jq -r .pid "$REG/issue-7.json")" "$SESS_B"
t "the dead pid is gone from the registry" "$(grep -l "\"pid\": *$DEAD\b" "$REG"/issue-*.json 2>/dev/null | wc -l | tr -d ' ')" "0"

# A claim whose worktree was removed (the PR merged, cleanup ran) is dead even with a live pid,
# once it is older than the grace that covers the claim→`worktree add` window.
jq -n --argjson pid "$SESS_B" --arg host "$(hostname)" --arg wt "$tmp/gone" --argjson started "$(( $(date +%s) - 4000 ))" \
  '{issue:11, branch:"task/11-x", worktree:$wt, cwd:$wt, pid:$pid, host:$host, started:$started}' > "$REG/issue-11.json"
start_as "$$" 11 >/dev/null 2>&1; rc=$?
t "a claim whose worktree is long gone does not block" "$rc" "0"

# ── a failed start does not leave a claim behind ───────────────────────────────────────────────
# `git worktree add -B` fails when the branch is checked out in the main checkout.
git -C "$REPO" checkout -q -b task/12-claimed-thing
start_as "$SESS_B" 12 >/dev/null 2>&1; rc=$?
t "a start whose worktree add fails returns 1" "$rc" "1"
t "…and releases the claim it had just taken" "$([ -e "$REG/issue-12.json" ] && echo yes || echo no)" "no"
git -C "$REPO" checkout -q main

# ── 7. the CLI reports the ISSUE, not the flag ─────────────────────────────────────────────────
json="$( cd "$REPO" && KIT_SESSION_PID="$$" "$ROOT/bin/cckit" start --force 9 --llm 2>/dev/null )"
t "cckit start --force N --llm reports issue N" "$(printf '%s' "$json" | jq -r '.issue' 2>/dev/null)" "9"
t "cckit start --force N --llm is ok"           "$(printf '%s' "$json" | jq -r '.ok' 2>/dev/null)" "true"
json="$( cd "$REPO" && KIT_SESSION_PID="$SESS_B" "$ROOT/bin/cckit" start 9 --llm 2>/dev/null )"; rc=$?
t "cckit start on a claimed issue exits 1" "$rc" "1"
t "cckit start on a claimed issue reports ok:false" "$(printf '%s' "$json" | jq -r '.ok' 2>/dev/null)" "false"
err="$( cd "$REPO" && KIT_SESSION_PID="$SESS_B" "$ROOT/bin/cckit" start 9 2>&1 >/dev/null )"; rc=$?
t "cckit start (human mode) on a claimed issue exits 1" "$rc" "1"
has "cckit start (human mode) prints the refusal" "$err" "refused: a live session already claims this issue"

[ "$fail" -eq 0 ] && echo "ALL OK (worktree-start)" || echo "worktree-start: FAILURES"
exit "$fail"
