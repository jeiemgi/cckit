#!/usr/bin/env bash
# kit-statusline.sh — Claude Code statusLine with claude-kit identity (#207).
#
# Shows:  ⡶ v<kit> · <dir> git:(<branch>) #<issue> wt ✗ ctx:NN%
#   ⡶        kit sigil (Braille seed-head) — unicode-gated by locale
#   v<kit>   kitVersion from the nearest .claude/kit.config.json (walks up)
#   #<issue> derived from the branch name (<kind>/<N>-<slug>), same rule as
#            scripts/lib/worktree-issue.sh — no network, no gh
#   wt       marker when running inside a linked git worktree
#   ✗        dirty working tree
#   ctx:NN%  context window usage from Claude Code's statusline JSON
#
# Plugin-SERVED (not copied per-project): the kit-wire shim (.claude/statusline.sh) exec's this.
# A plugin bump updates it everywhere with zero local edits (#369).
#
# Degrades gracefully: no git -> dir only; no kit.config.json -> no version;
# NO_COLOR or non-UTF-8 locale -> plain ASCII. Never blocks; always exits 0.

input=$(cat)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""' 2>/dev/null)
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd="$PWD"
dir=$(basename "$cwd")

# --- gates ---------------------------------------------------------------
UNICODE=0
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *UTF-8* | *utf8* | *UTF8*) UNICODE=1 ;;
esac
COLOR=1
[ -n "${NO_COLOR:-}" ] && COLOR=0

c() { # c <ansi-code> <text> — color only when enabled
  if [ "$COLOR" = 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi
}

SIGIL="k/"
[ "$UNICODE" = 1 ] && SIGIL="⡶"

# --- kit version: walk up from cwd to the nearest kit.config.json --------
kitv=""
p="$cwd"
while [ -n "$p" ] && [ "$p" != "/" ]; do
  if [ -f "$p/.claude/kit.config.json" ]; then
    kitv=$(jq -r '.kitVersion // empty' "$p/.claude/kit.config.json" 2>/dev/null)
    break
  fi
  p=$(dirname "$p")
done

# --- git: branch, issue, worktree, dirty ----------------------------------
branch=$(git -C "$cwd" -c core.fsmonitor=false symbolic-ref --short HEAD 2>/dev/null)
issue=""
wt=""
dirty=""
if [ -n "$branch" ]; then
  # <kind>/<N>-<slug> -> #N  (same derivation as scripts/lib/worktree-issue.sh)
  issue=$(printf '%s' "$branch" | sed -nE 's|^[a-z-]+/([0-9]+)-.*|\1|p')
  gd=$(git -C "$cwd" rev-parse --git-dir 2>/dev/null)
  gcd=$(git -C "$cwd" rev-parse --git-common-dir 2>/dev/null)
  [ -n "$gd" ] && [ -n "$gcd" ] && [ "$gd" != "$gcd" ] && wt="wt"
  if ! git -C "$cwd" -c core.fsmonitor=false diff --quiet HEAD 2>/dev/null; then
    if [ "$UNICODE" = 1 ]; then dirty="✗"; else dirty="x"; fi
  fi
fi

# --- compose ---------------------------------------------------------------
out=""
out+="$(c '1;33' "$SIGIL")"
[ -n "$kitv" ] && out+=" $(c '2' "v$kitv")"
out+=" $(c '0;36' "$dir")"
if [ -n "$branch" ]; then
  out+=" $(c '1;34' 'git:(')$(c '0;31' "$branch")$(c '1;34' ')')"
  [ -n "$issue" ] && out+=" $(c '0;32' "#$issue")"
  [ -n "$wt" ] && out+=" $(c '0;35' "$wt")"
  [ -n "$dirty" ] && out+=" $(c '0;33' "$dirty")"
fi
[ -n "$used" ] && out+=" $(c '2' "ctx:$(printf '%.0f' "$used")%")"

printf '%b\n' "$out"
exit 0
