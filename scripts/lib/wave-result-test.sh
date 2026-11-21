#!/bin/sh
# wave-result-test.sh — self-test for wave-result.sh under bash AND zsh, plus the wave-worker.sh
# wrapper that writes the records (E257.6, #263). Hermetic: KIT_STATE_DIR points at a temp dir.
# Run: bash scripts/lib/wave-result-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${WR_TEST_INNER:-}" ]; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  KIT_STATE_DIR="$tmp/state"; export KIT_STATE_DIR
  . "$dir/wave-result.sh"
  fail=0
  t() { if [ "$2" = "$3" ]; then :; else echo "FAIL($WR_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
  worker="$dir/../wave-worker.sh"

  # ── the three terminal values come from the exit status alone ───────────────────────────
  t "rc 0 is success"            "$(wr_classify_rc 0)"   "success"
  t "rc 1 is failure"            "$(wr_classify_rc 1)"   "failure"
  t "rc 128 is failure"          "$(wr_classify_rc 128)" "failure"
  t "rc 130 is interrupted"      "$(wr_classify_rc 130)" "interrupted"
  t "rc 137 is interrupted"      "$(wr_classify_rc 137)" "interrupted"
  t "a non-numeric rc is failure" "$(wr_classify_rc x)"  "failure"

  # ── records: create, update in place, read ────────────────────────────────────────────
  t "session name is made path-safe" "$(wr_session_name 'my wave/1')" "my_wave_1"
  wr_set "s 1" 7 issue=7 state=launched agent=codex "branch=task/7-a=b"
  t "set + get"                  "$(wr_get "s 1" 7 state)" "launched"
  t "a value may contain ="      "$(wr_get "s 1" 7 branch)" "task/7-a=b"
  wr_set "s 1" 7 state=running pid=1
  t "update replaces the field"  "$(wr_get "s 1" 7 state)" "running"
  t "update keeps other fields"  "$(wr_get "s 1" 7 agent)" "codex"
  t "one line per field"         "$(grep -c '^state' "$(wr_file "s 1" 7)")" "1"
  t "an absent record reads empty" "$(wr_get "s 1" 99 state)" ""
  t "an absent session has no rows" "$(wr_rows nope)" ""

  # ── a `running` record is only as true as its pid, on the host that wrote it ───────────────
  sh -c 'exit 0' & dead=$!; wait "$dead" 2>/dev/null
  wr_set "s 1" 8 issue=8 state=running "pid=$dead" "host=$(hostname)"
  t "running + dead pid here is interrupted" "$(wr_state "s 1" 8)" "interrupted"
  wr_set "s 1" 9 issue=9 state=running "pid=$dead" host=some-other-host
  t "running + dead pid elsewhere stays running" "$(wr_state "s 1" 9)" "running"
  wr_set "s 1" 10 issue=10 state=running "pid=$$" "host=$(hostname)"
  t "running + live pid stays running" "$(wr_state "s 1" 10)" "running"
  wr_set "s 1" 11 issue=11 state=success rc=0 "pid=$dead" "host=$(hostname)"
  t "a terminal state is never reread from the pid" "$(wr_state "s 1" 11)" "success"
  t "rows are ordered by issue"  "$(wr_rows "s 1" | cut -f1 | tr '\n' ' ')" "7 8 9 10 11 "
  t "pending counts launched + running" "$(wr_pending "s 1")" "3"
  wr_clear "s 1"
  t "clear drops the session's records" "$(wr_rows "s 1")" ""

  # ── the wrapper: it records the agent's own exit, for any command ────────────────────────
  bash "$worker" w 1 -- sh -c 'exit 0';  t "wrapper returns the agent's rc 0" "$?" "0"
  bash "$worker" w 2 -- sh -c 'exit 4';  t "wrapper returns the agent's rc 4" "$?" "4"
  bash "$worker" w 3 -- sh -c 'kill -9 $$' 2>/dev/null; t "wrapper returns a signal rc" "$?" "137"
  t "exit 0 recorded as success"       "$(wr_state w 1)/$(wr_get w 1 rc)" "success/0"
  t "exit 4 recorded as failure"       "$(wr_state w 2)/$(wr_get w 2 rc)" "failure/4"
  t "SIGKILL recorded as interrupted"  "$(wr_state w 3)/$(wr_get w 3 rc)" "interrupted/137"
  wr_set w 4 issue=4 state=launched agent=claude branch=task/4-x
  bash "$worker" w 4 -- sh -c 'printf "%s|" "$@"' argv0 'two words' "it's" > "$tmp/argv"
  t "argv reaches the agent untouched" "$(cat "$tmp/argv")" "two words|it's|"
  t "wrapper keeps the launcher's fields" "$(wr_get w 4 agent)/$(wr_get w 4 branch)" "claude/task/4-x"
  # A TERM to the wrapper: bash defers the trap until the agent returns, then records interrupted
  # even though the agent itself exited 0.
  bash "$worker" w 5 -- sh -c 'kill -TERM "$PPID"; sleep 1' 2>/dev/null
  t "a TERM to the wrapper is rc 143"  "$?" "143"
  t "a TERM is recorded as interrupted" "$(wr_state w 5)" "interrupted"
  bash "$worker" w >/dev/null 2>&1;     t "wrapper refuses a missing issue" "$?" "2"
  bash "$worker" w 6 -- >/dev/null 2>&1; t "wrapper refuses a missing command" "$?" "2"

  if [ "$fail" -eq 0 ]; then echo "PASS($WR_TEST_INNER): wave result records + worker wrapper"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  WR_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
