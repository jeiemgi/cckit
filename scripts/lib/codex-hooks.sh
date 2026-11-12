#!/usr/bin/env bash
# shellcheck shell=bash
# codex-hooks.sh — register cckit's hooks in a project's `.codex/hooks.json` (E257.5, #262).
#
# Codex reads project hooks from `<repo>/.codex/hooks.json`: event -> matcher group -> handlers, the
# same three levels as Claude Code's settings. The file is the PROJECT's: a user may already keep
# their own hooks there, and Codex ties a hook's trust to its definition, so a rewrite that changes
# nothing still must not touch the file.
#
#   codex_hooks_command <script>              the command string that runs .codex/hooks/<script>
#   codex_hooks_fragment <event> <matcher> <script> <timeout>
#                                             one registration as a hooks.json document ("" = no matcher)
#   codex_hooks_merge <dest> <src>            merge every handler of <src> into <dest>; prints
#                                             created | merged | unchanged
#   codex_hooks_registered <file> <script>    rc 0 when <file> registers .codex/hooks/<script>
#
# The command is relative to the checkout (`git rev-parse --show-toplevel`, the form the Codex hook
# docs use), never an absolute path: hooks.json is tracked, so it has to work in every clone and
# every worktree.
#
# Merge rule: a handler is added only when no handler of the same event already runs the same
# command. Everything else in <dest> — the user's handlers, their order, unknown keys — is kept.
# Requires jq. bash 3.2 + zsh compatible.
# errors: strict — a <dest> or <src> that is not a JSON object is refused (rc 1) and left untouched

codex_hooks_command() {
  # The $(...) is literal text for Codex's shell to expand at hook time, not ours.
  # shellcheck disable=SC2016
  printf 'bash "$(git rev-parse --show-toplevel)/.codex/hooks/%s"\n' "${1:-}"
}

codex_hooks_fragment() {
  local event="${1:-}" matcher="${2:-}" script="${3:-}" timeout="${4:-10}"
  [ -n "$event" ] && [ -n "$script" ] || { echo "codex_hooks_fragment: <event> <matcher> <script> [timeout] required" >&2; return 1; }
  jq -n --arg e "$event" --arg m "$matcher" --arg c "$(codex_hooks_command "$script")" --argjson t "$timeout" \
    '{hooks: {($e): [ (if $m == "" then {} else {matcher: $m} end) + {hooks: [{type: "command", command: $c, timeout: $t}]} ]}}'
}

codex_hooks_merge() {
  local dest="${1:-}" src="${2:-}" have merged
  [ -n "$dest" ] && [ -f "$src" ] || { echo "codex_hooks_merge: <dest> <src> required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "codex_hooks_merge: jq required" >&2; return 1; }
  jq -e 'type == "object" and ((.hooks // {}) | type == "object")' "$src" >/dev/null 2>&1 \
    || { echo "codex_hooks_merge: $src is not a hooks.json object" >&2; return 1; }
  if [ -f "$dest" ]; then
    have="$(jq -c 'if type == "object" and ((.hooks // {}) | type == "object") then . else error("not a hooks.json object") end' "$dest" 2>/dev/null)" \
      || { echo "codex_hooks_merge: $dest is not a JSON hooks.json object — left untouched" >&2; return 1; }
  else
    have='{}'
  fi
  merged="$(printf '%s\n' "$have" | jq -c --slurpfile src "$src" '
    reduce (($src[0].hooks // {}) | to_entries[]) as $ev (.;
      reduce ($ev.value[]) as $g (.;
        ([ (.hooks[$ev.key] // [])[] | (.hooks // [])[] | (.command // empty) ]) as $seen
        | ($g | .hooks = [ (.hooks // [])[] | select((.command // "") as $c | ($seen | index($c)) == null) ]) as $new
        | if ($new.hooks | length) > 0 then .hooks[$ev.key] = ((.hooks[$ev.key] // []) + [$new]) else . end))')" \
    || { echo "codex_hooks_merge: could not merge $src into $dest — left untouched" >&2; return 1; }
  if [ -f "$dest" ] && [ "$merged" = "$have" ]; then echo unchanged; return 0; fi
  mkdir -p "$(dirname "$dest")" || return 1
  printf '%s\n' "$merged" | jq . > "$dest.tmp" && mv "$dest.tmp" "$dest" || { rm -f "$dest.tmp"; return 1; }
  if [ "$have" = '{}' ]; then echo created; else echo merged; fi
}

codex_hooks_registered() {
  local file="${1:-}" want
  [ -f "$file" ] || return 1
  want="$(codex_hooks_command "${2:-}")"
  jq -e --arg c "$want" '[ (.hooks // {})[]?[]? | (.hooks // [])[]? | .command ] | index($c) != null' "$file" >/dev/null 2>&1
}
