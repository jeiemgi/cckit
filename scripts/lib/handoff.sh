#!/usr/bin/env bash
# handoff.sh - the resume-here handoff. A session that ends with unfinished work writes a terse
# "resume here" note; the next session (bare `cckit`) prints it so the operator or agent picks up
# exactly where the last one left off. The note is LOCAL (.cckit/handoff.md, gitignored) - it is
# session state, not a repo artifact.
# errors: best-effort — session state, not a repo artifact

# The note must be the SAME file from the primary checkout and from every worktree. It used to
# resolve via `git rev-parse --show-toplevel`, which returns the WORKTREE's root inside a worktree —
# so a handoff written from the main checkout was invisible from every worktree (and vice versa),
# silently, with `cckit` reporting "no resume-here handoff saved". kit-state.sh resolves the one
# shared .cckit/ via --git-common-dir instead.
if [ -n "${BASH_SOURCE:-}" ]; then
  _ho_self="$BASH_SOURCE"
elif [ -n "${ZSH_VERSION:-}" ]; then
  eval '_ho_self="${(%):-%x}"'
else
  _ho_self="$0"
fi
if [ -f "$(dirname "$_ho_self")/kit-state.sh" ]; then
  # shellcheck source=kit-state.sh
  . "$(dirname "$_ho_self")/kit-state.sh"
fi
unset _ho_self

_handoff_file() {
  if command -v kit_state_file >/dev/null 2>&1; then kit_state_file handoff.md
  else printf '%s/.cckit/handoff.md' "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
}

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
