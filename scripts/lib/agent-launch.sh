#!/usr/bin/env bash
# shellcheck shell=bash
# agent-launch.sh — the ONE headless launcher: run an agent CLI with no terminal, under a
# wall-clock bound, and read what the runtime itself reported (E257.7, #264).
#
# Every other launcher cckit has is interactive — `or_herdr_launch` focuses a pane and
# `or_tmux_agent_cmd` types a line into a pane's shell. Nothing could start an agent with nobody
# watching, so the review stage carried a private bounded runner (`_rs_run`) and made the project
# supply the whole command. This file is that runner, shared, plus the two non-interactive forms
# cckit knows:
#
#   claude   `claude -p`      the prompt on stdin, the reply on stdout
#   codex    `codex exec -`   the same; `-` is what makes Codex read the prompt from stdin
#
# Both forms come from each CLI's own `--help` (claude 2.1.322, codex-cli 0.154.0). No live agent
# session was run to write this file: the fixture tests drive stub binaries named `claude` and
# `codex`, which proves the argv cckit builds and the bound it enforces, not that either agent
# behaves. A kind with no known headless form is refused, never guessed at.
#
# cckit adds no permission flag and names no model, so what the agent may do is whatever the CLI's
# own defaults and the user's own settings allow: `codex exec --help` lists `read-only` among its
# sandbox modes and `claude -p` prompts nobody. A run that must write gets its flags from the
# caller (a profile's `args`, or `--agent-arg`); cckit does not verify the result is read-only or
# writable.
#
#   al_supported <kind>                  rc 0 when the kind has a known headless form
#   al_headless_cmd <kind> <text|json> [<args, one per line>]
#                                        echo the shell command line; it reads the prompt on stdin
#   al_run <seconds> <command>           run it on stdin under the bound: rc 124 on expiry (TERM,
#                                        then KILL), else the command's own exit status
#   al_stop                              TERM-then-KILL whatever al_run has running (for a trap)
#   al_pidfile_alive <file>              rc 0 when the pid an earlier al_run recorded in <file>
#                                        (AL_PIDFILE) still names a live process or process group
#   al_usage <kind> <output-file>        echo "<input> <output> <cost-usd>" from the runtime's own
#                                        JSON output; each field is `unknown` when it is not there
#
# bash 3.2 + zsh compatible: no arrays, no glob held in a variable.
# errors: mixed — al_supported/al_headless_cmd/al_usage are pure (al_headless_cmd returns 2 for an
# unsupported kind); al_run returns the command's status, or 124 when it killed it.

# The pid al_run is waiting on, and whether it leads its own process group. Global on purpose: a
# caller's signal trap has to be able to stop the agent, and it cannot reach a local.
AL_PID=""
AL_GROUP=0

# AL_PIDFILE — when a caller sets it, al_run writes "<pid> <group 0|1>" there while a command runs
# and removes it when the command is reaped. It is the only record of the command that outlives the
# calling shell: a caller killed with SIGKILL runs no trap, and its next start needs something to
# check before it puts a second writer on the branch (al_pidfile_alive).
AL_PIDFILE="${AL_PIDFILE:-}"

# The watchdog al_run starts under perl. It leads the command's process group, runs the command as
# its child, and exits with the command's status (128+N when a signal killed it). Every 0.2s it
# compares its parent pid with the one it started under: a different parent means the shell that
# called al_run is gone, so nothing is left to enforce the bound, and it stops the group itself
# with TERM, up to 10s of grace, then KILL. It ignores TERM/INT/HUP so a group-wide TERM from
# al_stop reaches the command while the watchdog stays to report how the command ended. The empty
# CHLD handler is there to cut the 0.2s sleep short: without it the watchdog outlives the command
# by up to one tick, and a start made in that tick is refused for a process that is already over.
_AL_WATCHDOG='
setpgrp(0, 0);
my $parent = getppid();
my $kid = fork();
exit 126 unless defined $kid;
if ($kid == 0) { exec @ARGV; exit 127 }
$SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{CHLD} = sub { };
sub status { my $s = shift; exit(($s & 127) ? 128 + ($s & 127) : $s >> 8) }
while (1) {
  my $r = waitpid($kid, 1);
  status($?) if $r == $kid;
  exit 127 if $r < 0;
  if (getppid() != $parent) {
    kill("-TERM", $$);
    for (my $i = 0; $i < 50; $i++) {
      last if waitpid($kid, 1) != 0;
      select(undef, undef, undef, 0.2);
    }
    kill("-KILL", $$);
    exit 137;
  }
  select(undef, undef, undef, 0.2);
}
'

# al_supported <kind> — matches on the basename, so `--agent /opt/bin/codex` still resolves.
al_supported() {
  case "${1##*/}" in claude|codex) return 0 ;; esac
  return 1
}

_al_quote() {
  local a="${1:-}" esc
  # Escaped in its own assignment — the `'\''` idiom inside a double-quoted concatenation adds a
  # second level of quoting (orchestration-runtime.sh:or_tmux_agent_cmd records the same bug).
  esc=${a//\'/\'\\\'\'}
  printf "'%s'" "$esc"
}

# al_headless_cmd <kind> <text|json> [<args-nl>] — the command line for one non-interactive turn.
#
# `text` is the plain reply (what a reviewer's report is parsed from). `json` asks the runtime for
# its machine-readable output, which is the only place token usage appears: one result object from
# `claude -p --output-format json`, JSONL events from `codex exec --json`.
al_headless_cmd() {
  local kind="${1:-}" mode="${2:-text}" args_nl="${3:-}" cmd tail="" a
  case "${kind##*/}" in
    claude) cmd="$(_al_quote "$kind") -p"
            [ "$mode" = "json" ] && cmd="$cmd --output-format json" ;;
    codex)  cmd="$(_al_quote "$kind") exec"
            [ "$mode" = "json" ] && cmd="$cmd --json"
            tail=" -" ;;
    *) echo "agent-launch: no headless form is known for agent '$kind' (supported: claude, codex)" >&2
       return 2 ;;
  esac
  if [ -n "$args_nl" ]; then
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      cmd="$cmd $(_al_quote "$a")"
    done <<EOF
$args_nl
EOF
  fi
  printf '%s%s\n' "$cmd" "$tail"
}

# _al_signal <SIGNAL> — signal the running command. The whole process group when it has one, so a
# grandchild (the agent's own shell tool, a test runner it started) does not outlive the bound.
_al_signal() {
  local sig="${1:-TERM}"
  [ -n "$AL_PID" ] || return 0
  if [ "$AL_GROUP" = "1" ] && kill -s "$sig" -- "-$AL_PID" 2>/dev/null; then return 0; fi
  kill -s "$sig" "$AL_PID" 2>/dev/null
  return 0
}

# al_stop — SIGTERM, up to 10s of grace, then SIGKILL. TERM first because an agent that traps it
# to clean up should get the chance; KILL after because one that ignores it should not get to stay.
al_stop() {
  local grace=0
  [ -n "$AL_PID" ] || return 0
  _al_signal TERM
  while [ "$grace" -lt 50 ] && kill -0 "$AL_PID" 2>/dev/null; do sleep 0.2; grace=$((grace + 1)); done
  # Unconditional: the leader may be gone while a group member that ignored TERM is not.
  _al_signal KILL
  wait "$AL_PID" 2>/dev/null
  AL_PID=""
  [ -z "$AL_PIDFILE" ] || rm -f "$AL_PIDFILE"
  return 0
}

# al_pidfile_alive <file> — rc 0 when the "<pid> <group>" al_run wrote there is still running.
# The group is probed as well as the pid: the leader can be gone while a member it started is not.
#
# A zombie is not running. `kill -0` succeeds on one, and an orphaned watchdog stays a zombie for
# as long as whatever adopted it does not reap (a container whose pid 1 is not an init), so the
# process state is read from ps when ps is there. When it is not, `kill -0` is the answer: a
# refusal the user can clear by removing the file is the safe side of that doubt.
al_pidfile_alive() {
  local f="${1:-}" p="" g="" rows=""
  [ -n "$f" ] && [ -f "$f" ] || return 1
  read -r p g < "$f" || true
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$g" = "1" ]; then
    kill -0 "$p" 2>/dev/null || kill -0 -- "-$p" 2>/dev/null || return 1
  else
    kill -0 "$p" 2>/dev/null || return 1
  fi
  rows="$(ps -A -o pid=,pgid=,stat= 2>/dev/null)" || rows=""
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | awk -v p="$p" -v g="$g" '
    ($1 == p || (g == "1" && $2 == p)) && $3 !~ /^Z/ { live = 1 }
    END { exit live ? 0 : 1 }'
}

# al_run <seconds> <command> — run the command with this shell's stdin, stdout and stderr, bounded.
#
# One code path on every system. `timeout(1)` is absent on macOS, so a "use timeout when present"
# design leaves the platform this is most run from on the untested branch — and a foreground
# `timeout` also defers a caller's signal trap until the command returns, which is exactly when an
# interrupted unattended run needs it to fire. The command is a background job polled every 0.2s.
#
# `<&0` is load-bearing: a background job in a non-interactive shell gets /dev/null as stdin unless
# it is redirected explicitly, and the prompt arrives on stdin.
#
# perl puts the command in its own process group so the bound can signal the group, and stays as
# that group's watchdog (_AL_WATCHDOG) so the command cannot outlive the shell that bounds it: a
# caller killed with SIGKILL takes the bound with it, and the watchdog then stops the group.
# Without perl only the direct child is signalled, a grandchild that ignores a closed pipe can
# survive, and a command whose caller was killed keeps running — AL_PIDFILE is what a later start
# checks in that case.
al_run() {
  local secs="${1:-900}" cmd="${2:-}" ticks=0 limit rc=0
  case "$secs" in ''|*[!0-9]*) secs=900 ;; esac
  limit=$((secs * 5))
  if command -v perl >/dev/null 2>&1; then
    perl -e "$_AL_WATCHDOG" sh -c "$cmd" <&0 &
    AL_PID=$!; AL_GROUP=1
  else
    sh -c "$cmd" <&0 &
    AL_PID=$!; AL_GROUP=0
  fi
  [ -z "$AL_PIDFILE" ] || printf '%s %s\n' "$AL_PID" "$AL_GROUP" > "$AL_PIDFILE"
  while kill -0 "$AL_PID" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      al_stop
      return 124
    fi
    sleep 0.2; ticks=$((ticks + 1))
  done
  wait "$AL_PID" 2>/dev/null; rc=$?
  AL_PID=""
  [ -z "$AL_PIDFILE" ] || rm -f "$AL_PIDFILE"
  return "$rc"
}

# al_usage <kind> <output-file> — "<input-tokens> <output-tokens> <cost-usd>" for one turn.
#
# Read from what the runtime printed, never computed. Claude's result object carries `usage` and
# `total_cost_usd`; Codex's `turn.completed` events carry `usage` and no cost. Input counts every
# input token the runtime reported, cached or not. A field that is not in the output is the word
# `unknown` — a list price applied to a token count is an estimate, and one priced for a different
# provider is a wrong number (effort-metrics.sh prices Claude transcripts only, and stays that way).
#
# The field names are the documented ones; no live run confirmed them. A runtime that prints a
# different shape yields `unknown`, never a guess.
al_usage() {
  local kind="${1:-}" f="${2:-}" got=""
  if [ -s "$f" ] && command -v jq >/dev/null 2>&1; then
    case "${kind##*/}" in
      claude)
        got="$(jq -rs '
          [ .[] | .. | objects | select(.type? == "result" and ((.usage? | type) == "object")) ] | last
          | if . == null then empty else
              ( [ .usage.input_tokens, .usage.cache_creation_input_tokens, .usage.cache_read_input_tokens ]
                | map(numbers) ) as $in
              | "\(if ($in | length) == 0 then "unknown" else ($in | add) end) \(.usage.output_tokens | if type == "number" then . else "unknown" end) \(.total_cost_usd | if type == "number" then . else "unknown" end)"
            end' "$f" 2>/dev/null)" || got=""
        ;;
      codex)
        got="$(jq -rRs '
          [ split("\n")[] | fromjson? | objects
            | select(.type? == "turn.completed" and ((.usage? | type) == "object")) | .usage ]
          | if length == 0 then empty else
              "\([.[].input_tokens | numbers] | if length == 0 then "unknown" else add end) \([.[].output_tokens | numbers] | if length == 0 then "unknown" else add end) unknown"
            end' "$f" 2>/dev/null)" || got=""
        ;;
    esac
  fi
  [ -n "$got" ] || got="unknown unknown unknown"
  printf '%s\n' "$got"
}
