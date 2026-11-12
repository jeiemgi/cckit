#!/bin/sh
# session-registry-test.sh — the claims registry contract (#384), under bash AND zsh.
#
# worktree-start-test.sh proves wt_start's behaviour end to end; this file pins the registry's own
# rules — which pid a claim records, what counts as dead, who may release — in both shells the lib
# is sourced from.
#
# Run:  bash scripts/lib/session-registry-test.sh
# Without args: re-runs itself under every available shell. With SRT_INNER set: runs the assertions
# in the current interpreter.
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${SRT_INNER:-}" ]; then
  unset KIT_SESSION_PID KIT_FORCE SREG_GRACE
  . "$dir/session-registry.sh"
  fail=0
  t() { if [ "$2" = "$3" ]; then :; else echo "FAIL($SRT_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }

  tmp=$(cd "$(mktemp -d 2>/dev/null || mktemp -d -t srt)" && pwd -P)
  sleep 600 & A=$!
  sleep 600 & B=$!
  trap 'kill "$A" "$B" 2>/dev/null; rm -rf "$tmp"' EXIT INT TERM
  git init -q "$tmp/repo"; R="$tmp/repo"; REG="$R/.git/kit-sessions"
  mkdir -p "$tmp/wt"

  # ── sreg_dir: the shared git dir, the same from a subdirectory ────────────────────────────
  t "sreg_dir is under the git common dir" "$(sreg_dir "$R")" "$REG"
  mkdir -p "$R/sub"; t "sreg_dir from a subdirectory" "$(sreg_dir "$R/sub")" "$REG"
  sreg_dir "$tmp" >/dev/null 2>&1; t "sreg_dir outside a repo fails" "$?" "1"

  # ── sreg_session_pid ──────────────────────────────────────────────────────────────────────
  t "KIT_SESSION_PID overrides" "$(KIT_SESSION_PID=$A sreg_session_pid)" "$A"
  auto=$(sreg_session_pid)
  case "$auto" in ''|*[!0-9]*) t "auto session pid is numeric" "$auto" "<pid>" ;; esac
  kill -0 "$auto" 2>/dev/null; t "auto session pid is a live process" "$?" "0"
  # A throwaway `sh -c` between the session and the call must not become the session: the pid
  # resolved one shell deeper is the same one.
  deeper=$(sh -c ". '$dir/session-registry.sh'; sreg_session_pid")
  t "an intermediate sh -c is skipped" "$deeper" "$auto"

  # ── claim / mine / contested ──────────────────────────────────────────────────────────────
  sreg_issue_claim "$R" 5 >/dev/null; t "no claim yet" "$?" "1"
  sreg_claim "$R" abc b "$tmp/wt" >/dev/null 2>&1; t "a non-numeric issue is rejected" "$?" "1"
  KIT_SESSION_PID=$A sreg_claim "$R" 5 task/5-x "$tmp/wt"; t "first claim" "$?" "0"
  t "claim row" "$(sreg_issue_claim "$R" 5 | cut -f1-4)" "$(printf '5\ttask/5-x\t%s\t%s' "$tmp/wt" "$A")"
  t "cwd mirrors the worktree for _wt_session_owns" "$(jq -r .cwd "$REG/issue-5.json")" "$tmp/wt"
  ( KIT_SESSION_PID=$A; export KIT_SESSION_PID; sreg_claim_mine "$R" 5 ); t "mine for the same session" "$?" "0"
  ( cd "$tmp" && KIT_SESSION_PID=$B sreg_claim_mine "$R" 5 ); t "not mine for another session" "$?" "1"
  ( cd "$tmp/wt" && KIT_SESSION_PID=$B sreg_claim_mine "$R" 5 ); t "mine from inside the claimed worktree" "$?" "0"
  ( cd "$tmp" && KIT_SESSION_PID=$B sreg_claim "$R" 5 task/5-x "$tmp/wt" ); t "contested claim returns 3" "$?" "3"
  t "contested claim wrote nothing" "$(jq -r .pid "$REG/issue-5.json")" "$A"
  ( cd "$tmp" && KIT_SESSION_PID=$B sreg_release "$R" 5 ); t "another session cannot release" "$?" "1"
  t "…and the claim is still there" "$([ -f "$REG/issue-5.json" ] && echo yes || echo no)" "yes"
  ( cd "$tmp" && KIT_SESSION_PID=$B sreg_claim "$R" 5 task/5-x "$tmp/wt" 1 ); t "forced claim returns 0" "$?" "0"
  t "forced claim takes over" "$(jq -r .pid "$REG/issue-5.json")" "$B"
  t "no temp file left behind" "$(ls -a "$REG" | grep -c '\.tmp$')" "0"

  # ── list: read-only, sorted ───────────────────────────────────────────────────────────────
  KIT_SESSION_PID=$A sreg_claim "$R" 12 task/12-y "$tmp/wt"
  KIT_SESSION_PID=$A sreg_claim "$R" 3 task/3-z "$tmp/wt"
  t "list is numerically sorted" "$(sreg_list "$R" | cut -f1 | tr '\n' ' ')" "3 5 12 "
  t "list --json" "$(sreg_list "$R" --json | jq -c '[.[].issue]')" "[3,5,12]"
  t "list --json on an empty registry is []" "$(sreg_list "$tmp/repo/sub/../../nowhere" --json 2>/dev/null)" "[]"

  # ── liveness ──────────────────────────────────────────────────────────────────────────────
  kill "$A" 2>/dev/null; wait "$A" 2>/dev/null
  before=$(ls "$REG" | tr '\n' ' ')
  t "list hides a dead session's claims" "$(sreg_list "$R" | cut -f1 | tr '\n' ' ')" "5 "
  t "list deleted nothing" "$(ls "$REG" | tr '\n' ' ')" "$before"
  sreg_reap "$R"
  t "reap drops only the dead claims" "$(ls "$REG" | tr '\n' ' ')" "issue-5.json "

  # pid reuse: a live pid whose start time is not the recorded one is a different process.
  jq '.pstart = "Thu Jan  1 00:00:00 1970"' "$REG/issue-5.json" > "$REG/x" && mv "$REG/x" "$REG/issue-5.json"
  sreg_issue_claim "$R" 5 >/dev/null; t "a reused pid does not hold the claim" "$?" "1"
  t "…and that claim was reaped" "$([ -f "$REG/issue-5.json" ] && echo yes || echo no)" "no"

  # Another host's claim: its pid means nothing here, so a dead-looking pid must NOT drop it.
  now=$(date +%s)
  printf '{"issue":20,"branch":"task/20-r","worktree":"%s","cwd":"%s","pid":%s,"host":"some-other-host","started":%s}\n' \
    "$tmp/wt" "$tmp/wt" "$A" "$now" > "$REG/issue-20.json"
  sreg_issue_claim "$R" 20 >/dev/null; t "a claim from another host survives a dead local pid" "$?" "0"

  # Worktree gone: live inside the grace window (claim written before `git worktree add`), dead after.
  printf '{"issue":21,"branch":"b","worktree":"%s","cwd":"%s","pid":%s,"host":"%s","started":%s}\n' \
    "$tmp/gone" "$tmp/gone" "$B" "$(hostname)" "$now" > "$REG/issue-21.json"
  sreg_issue_claim "$R" 21 >/dev/null; t "a fresh claim on a not-yet-created worktree is live" "$?" "0"
  printf '{"issue":21,"branch":"b","worktree":"%s","cwd":"%s","pid":%s,"host":"%s","started":%s}\n' \
    "$tmp/gone" "$tmp/gone" "$B" "$(hostname)" "$((now - 4000))" > "$REG/issue-21.json"
  sreg_issue_claim "$R" 21 >/dev/null; t "an old claim on a missing worktree is dead" "$?" "1"

  # Garbage in the directory is ignored, never fatal — the reader shares it with cache-* files.
  echo 'not json' > "$REG/issue-30.json"; echo '{}' > "$REG/cache-x.json"
  t "a corrupt claim file is skipped" "$(sreg_list "$R" | cut -f1 | tr '\n' ' ')" "20 "

  [ "$fail" -eq 0 ] && echo "ok($SRT_INNER): session-registry"
  exit "$fail"
fi

rc=0; ran=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  ran=$((ran + 1))
  SRT_INNER="$sh" "$sh" "$0" || rc=1
done
[ "$ran" -gt 0 ] || { echo "session-registry-test: no bash or zsh found" >&2; exit 1; }
[ "$rc" -eq 0 ] && echo "ALL OK (session-registry)"
exit "$rc"
