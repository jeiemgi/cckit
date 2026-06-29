#!/usr/bin/env bash
# handoff.sh - the resume-here handoff. A session that ends with unfinished work writes a terse
# "resume here" note; the next session (bare `cckit`) prints it so the operator or agent picks up
# exactly where the last one left off. The note is LOCAL (.cckit/handoff.md, gitignored) - it is
# session state, not a repo artifact.

_handoff_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
_handoff_file() { printf '%s/.cckit/handoff.md' "$(_handoff_root)"; }

# handoff_write [text] - save the resume note from "$*" or, if none, stdin.
handoff_write() {
  local f text
  f="$(_handoff_file)"; mkdir -p "$(dirname "$f")"
  if [ "$#" -gt 0 ]; then text="$*"; else text="$(cat)"; fi
  [ -n "$text" ] || { echo "handoff: nothing to write (pass text or pipe stdin)" >&2; return 1; }
  {
    echo "# cckit resume-here"
    echo "_saved $(date -u +%Y-%m-%dT%H:%M:%SZ) on branch $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')_"
    echo
    printf '%s\n' "$text"
  } > "$f"
  echo "handoff: saved -> $f" >&2
}

# handoff_read - print the resume note, or a friendly prompt when there is none.
handoff_read() {
  local f; f="$(_handoff_file)"
  if [ -s "$f" ]; then
    cat "$f"
  else
    echo "cckit: no resume-here handoff saved."
    echo "Run 'cckit sync' for the board, or save one with:"
    echo "  cckit handoff \"<what's pending, the next step, any PR/issue refs>\""
  fi
}
