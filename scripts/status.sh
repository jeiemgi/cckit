#!/usr/bin/env bash
# status.sh - the "where are we?" dashboard: the board, then the THREE buckets a session actually
# opens with (local undone work · PRs waiting on a human · cleanup available), then the resume
# handoff. The bucket logic lives in scripts/lib/kit-status.sh (kit-engine-boundary: verb logic in a
# sourceable lib, never inline in a script), so every verdict is unit-tested rather than eyeballed. Output is MARKDOWN routed through the rendering seam (#82): rich via glow in a TTY,
# verbatim markdown otherwise (renders natively in Claude Code, always pipe-safe — no escape codes
# leak into a redirect). This is the lightweight cockpit; the rich opentui TUI is an OPTIONAL
# separate adapter — the core stays pure bash and dependency-light, so `cckit status` works anywhere.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/ui.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/render.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/kit-config.sh" && load_kit_config
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/kit-gc.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/kit-status.sh"

# _status_md — compose the whole dashboard as one markdown document on stdout.
_status_md() {
  echo "# cckit status — $KIT_REPO"
  echo "_base ${KIT_BASE_BRANCH:-main}_"
  echo ""

  # Board: open issues, blocked count. Fetch the board as a JSON ARRAY directly (#142) — the
  # `task-sync --llm` output is TOON, not JSON, so piping it into `jq 'length'` mis-parses it (the
  # leading `[N]` header reads as a 1-element array, then jq errors and the `|| echo 0` fallback
  # concatenates onto the partial output, yielding a value like "1\n0" that breaks `[ "$open" -gt 8 ]`
  # with "integer expression expected"). A clean JSON array keeps every count a single integer.
  echo "## Board"
  if command -v jq >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    local board open blocked
    board="$(gh issue list --repo "$KIT_REPO" --state open --limit 200 --json number,title,body 2>/dev/null \
      | jq -c '[.[] | {number, title, blocked: ((.body // "") | test("Blocked by"))}]' 2>/dev/null || echo '[]')"
    [ -n "$board" ] || board='[]'
    open="$(printf '%s' "$board" | jq 'length' 2>/dev/null || echo 0)"
    blocked="$(printf '%s' "$board" | jq '[.[]|select(.blocked)]|length' 2>/dev/null || echo 0)"
    case "$open"    in ''|*[!0-9]*) open=0 ;; esac       # never let a non-integer reach the test below
    case "$blocked" in ''|*[!0-9]*) blocked=0 ;; esac
    echo "open issues: $open   blocked: $blocked"
    echo ""
    printf '%s' "$board" | jq -r '.[:8][] | "- #\(.number)  \(.title[0:56])"' 2>/dev/null || true
    [ "$open" -gt 8 ] && echo "- … and $((open - 8)) more (\`cckit sync\`)"
  else
    echo "_(jq/gh absent — run \`cckit sync\`)_"
  fi
  echo ""

  # The three buckets. Each one names its own emptiness, so a clean bucket and a broken one never
  # look alike — this report is read to decide what to do next.
  status_buckets_md "$ROOT"
  echo ""

  # Resume handoff, if one is saved.
  echo "## Resume handoff"
  echo '```'
  # shellcheck source=/dev/null
  source "$ROOT/scripts/lib/handoff.sh"
  handoff_read
  echo '```'
}

# `--llm` (or CCKIT_OUTPUT=json, set by the dispatcher) emits the buckets as JSON for an agent —
# same classifiers as the markdown path, so the two cannot disagree about a verdict.
for a in "$@"; do
  case "$a" in
    --llm|--output=json) CCKIT_OUTPUT=json ;;
  esac
done
if [ "${CCKIT_OUTPUT:-}" = "json" ]; then
  # Propagate the rc: a report that could not read a bucket must not exit 0, or a caller that only
  # checks the status code acts on a half-known state as if it were clean.
  status_buckets_json "$ROOT"
  exit $?
fi

if command -v cckit_render >/dev/null 2>&1; then _status_md | cckit_render; else _status_md; fi
