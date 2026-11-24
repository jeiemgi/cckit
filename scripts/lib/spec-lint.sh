#!/usr/bin/env bash
# shellcheck shell=bash
# spec-lint.sh — the `## Spec` check on an effort body (rules/effort-model.md, E546.5). The Spec says
# what "done" means as a checkable list. `cckit effort new` runs spec_lint on the body it composed
# before any forge write, and `cckit effort close` runs it on the parent body it reads back, so an
# effort cannot be filed or closed without one.
#
# A body passes when it has a `## Spec` heading followed, before the next `## ` heading, by at least
# one list item (`- `, `* `, `+ `, `1. `, `1) `; a `[ ]` checkbox is allowed) whose text is not a
# placeholder. Placeholders: TODO, TBD, TBA, FIXME, XXX, WIP, n/a (alone or leading the item), and
# items made only of `.`, `…`, `?` or `-`. HTML comments are ignored, so the template hint
# `<!-- … -->` alone does not count.
#
# Functions:
#   spec_lint <body|->      rc 0 clean · 1 + reasons on stderr · 2 usage (no argument)
#   spec_section <text>     echo "## Spec" + the items: plain lines become `- ` bullets; text that
#                           already holds a list item is kept as written; blank lines are dropped
#
# bash 3.2 compatible; sourceable under zsh (awk does the parsing, no arrays).
# errors: strict — a validator: rc 1 on a body without a checkable Spec

# _spec_scan — read a body on stdin, print "<heading 0|1> <items> <real items>".
_spec_scan() {
  tr -d '\r' | awk '
    BEGIN { head = 0; inside = 0; done = 0; items = 0; real = 0; cmt = 0 }
    {
      line = $0
      if (!head) {
        if (line ~ /^##[ \t]+Spec[ \t]*$/) { head = 1; inside = 1 }
        next
      }
      if (!inside || done) next
      if (line ~ /^##[ \t]/) { done = 1; next }
      # Drop HTML comments, including ones that span lines.
      out = ""
      while (length(line) > 0) {
        if (cmt) {
          e = index(line, "-->")
          if (e == 0) { line = ""; break }
          line = substr(line, e + 3); cmt = 0
        } else {
          s = index(line, "<!--")
          if (s == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, s - 1); line = substr(line, s + 4); cmt = 1
        }
      }
      line = out
      if (line !~ /^[ \t]*([-*+]|[0-9]+[.)])([ \t]|$)/) next
      items++
      text = line
      sub(/^[ \t]*([-*+]|[0-9]+[.)])[ \t]*/, "", text)
      sub(/^\[[ xX]\][ \t]*/, "", text)
      sub(/[ \t]+$/, "", text)
      if (text == "") next
      low = tolower(text)
      if (low ~ /^(todo|tbd|tba|fixme|xxx|wip|n\/a)([^a-z0-9]|$)/) next
      if (low ~ /^(\.|\?|-|…)+$/) next
      real++
    }
    END { printf "%d %d %d\n", head, items, real }'
}

spec_lint() {
  [ $# -ge 1 ] || { echo "spec_lint: usage: spec_lint <body|->" >&2; return 2; }
  local scan head items real reasons=""
  if [ "$1" = "-" ]; then scan="$(_spec_scan)"
  else scan="$(printf '%s\n' "$1" | _spec_scan)"; fi
  read -r head items real <<EOF_SCAN
$scan
EOF_SCAN
  head="${head:-0}"; items="${items:-0}"; real="${real:-0}"
  if [ "$head" != 1 ]; then
    reasons="no '## Spec' section — add one: what done means, as a checkable list"
  elif [ "$items" = 0 ]; then
    reasons="the '## Spec' section has no list item — write at least one '- ' or '1. ' item"
  elif [ "$real" = 0 ]; then
    reasons="every '## Spec' item is empty or a placeholder (TODO, TBD, …) — say what done means"
  fi
  [ -n "$reasons" ] || return 0
  {
    echo "✗ the effort body has no checkable Spec (rules/effort-model.md):"
    printf '    - %s\n' "$reasons"
  } >&2
  return 1
}

spec_section() {
  local text="${1:-}"
  echo "## Spec"
  if grep -qE '^[[:space:]]*([-*+]|[0-9]+[.)])([[:space:]]|$)' <<<"$text"; then
    printf '%s\n' "$text" | grep -v '^[[:space:]]*$' || true
  else
    printf '%s\n' "$text" | grep -v '^[[:space:]]*$' | sed 's/^[[:space:]]*/- /' || true
  fi
}
