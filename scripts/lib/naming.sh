#!/usr/bin/env bash
# shellcheck shell=bash
# naming.sh — the ONE title convention (rules/naming-and-ids.md, E546.1). Every verb that creates or
# titles an issue or a pull request calls naming_title_lint before it writes to the forge, and every
# verb that reads a title back strips its prefix here, so the generator, the validator and the rule
# say the same thing.
#
#   effort     [E<n>] <name>                   e.g. [E545] Every verb answers a question
#   sub        [E<n>.<step>] <name>            step = the sub's 1-based position in the effort
#   issue      <name>                          a standalone issue: plain outcome, no prefix
#   pr         type(scope): subject [E<n>]     effort · [E<n>.<step>] sub · [#<n>] standalone
#
# The legacy forms `[Effort] N · <name>` and `[Effort N] M · <name>`, with an optional `[Flow] ` tag
# after the prefix, still parse and still lint, so issues opened before the change stay valid until
# `cckit effort retitle --apply` renames them. The flow lives in the `flow:` label; no generator
# writes a `[Flow]` tag any more.
#
# Functions:
#   naming_title_lint <effort|sub|issue|pr> <title>   rc 0 clean · 1 + reasons on stderr · 2 usage
#   naming_effort_title <n> <name>                    echo "[E<n>] <name>"
#   naming_sub_title <n> <step> <name>                echo "[E<n>.<step>] <name>"
#   naming_strip_prefix <title>                       echo the name: new or legacy prefix + [Flow] peeled
#   naming_strip_structural <title>                   the same, with a [Flow] tag kept
#   naming_title_token <title>                        echo E<n> / E<n>.<step> read from the prefix, or rc 1
#   naming_title_parent <title>                       echo <n> when the title is a sub of effort n, or rc 1
#   naming_token_parse <token>                        E545 -> "545" · E545.1 -> "545 1" · else rc 1
#
# bash 3.2 compatible; sourceable under zsh (no BASH_REMATCH, no arrays in the pure helpers).
# errors: strict — a validator: rc 1 on a title that breaks the rule

if ! command -v commitlint_check >/dev/null 2>&1; then
  if [ -n "${BASH_SOURCE:-}" ]; then _nm_dir="${BASH_SOURCE[0]}"
  elif [ -n "${ZSH_VERSION:-}" ]; then eval '_nm_dir="${(%):-%x}"'
  else _nm_dir="$0"; fi
  _nm_dir="$(cd "$(dirname "$_nm_dir")" 2>/dev/null && pwd)"
  # shellcheck source=/dev/null
  [ -n "$_nm_dir" ] && [ -f "$_nm_dir/commitlint.sh" ] && . "$_nm_dir/commitlint.sh"
  unset _nm_dir
fi

# The PR token: the work a PR carries, trailing, in square brackets. `[share-<digits>]` is the one
# documented exception, the title `cckit task share` writes (no issue exists for a share).
NAMING_PR_TOKEN_RE='\[(E[0-9]+(\.[0-9]+)?|#[0-9]+|share-[0-9]+)\][[:space:]]*$'

naming_effort_title() { printf '[E%s] %s' "${1#\#}" "${2:-}"; }
naming_sub_title()    { printf '[E%s.%s] %s' "${1#\#}" "${2:-}" "${3:-}"; }

# naming_token_parse <token> — "E545" -> "545", "E545.1" -> "545 1"; brackets and a lowercase e are
# accepted. rc 1 for anything else.
naming_token_parse() {
  local t="${1:-}" out
  t="${t#\[}"; t="${t%\]}"
  out="$(printf '%s' "$t" | sed -nE -e 's/^[Ee]([0-9]+)\.([0-9]+)$/\1 \2/p' -e 's/^[Ee]([0-9]+)$/\1/p')"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# naming_title_token <title> — the token a title's prefix names: [E545.1] and [Effort 545] 1 · give
# E545.1; [E545] and [Effort] 545 · give E545. rc 1 for a title with neither prefix.
naming_title_token() {
  local out
  out="$(printf '%s' "${1:-}" | sed -nE \
    -e 's/^\[E([0-9]+)\.([0-9]+)\] .*/E\1.\2/p' \
    -e 's/^\[E([0-9]+)\] .*/E\1/p' \
    -e 's/^\[Effort ([0-9]+)\] ([0-9]+) ·.*/E\1.\2/p' \
    -e 's/^\[Effort\] ([0-9]+) ·.*/E\1/p' | sed -n 1p)"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

# naming_title_parent <title> — the effort number of a SUB title, new or legacy. rc 1 otherwise.
naming_title_parent() {
  local tok; tok="$(naming_title_token "${1:-}")" || return 1
  case "$tok" in *.*) tok="${tok%%.*}"; printf '%s\n' "${tok#E}" ;; *) return 1 ;; esac
}

# naming_strip_structural <title> — peel only the structural prefix, new or legacy (including the
# number-less `[Effort] · ` placeholder); a `[Flow] ` tag after it is kept.
naming_strip_structural() {
  printf '%s' "${1:-}" | sed -E \
    -e 's/^\[E[0-9]+(\.[0-9]+)?\] +//' \
    -e 's/^\[Effort( [0-9]+)?\] ([0-9]+ )?· ?//'
}

# naming_strip_prefix <title> — the human name: the structural prefix and then one leading `[Flow] `
# tag are peeled.
naming_strip_prefix() {
  naming_strip_structural "${1:-}" | sed -E 's/^\[[A-Za-z]+\] +//'
}

# _naming_name_reasons <name> — the name rules, one failed rule per line on stdout (none = clean).
# The body of the former effort_title_lint: a short plain-language outcome, ≤ 6 words, no
# parentheses, sub-clauses, glyphs, code identifiers or words from the jargon list.
_naming_name_reasons() {
  local name="$1" w wc
  local jargon="${EFFORT_TITLE_JARGON:-chrome seam contract claim rescue stash teardown scaffolding shim boilerplate refactor wiring}"
  [ -n "$(printf '%s' "$name" | tr -d '[:space:]')" ] || { echo "the name is empty — say the outcome"; return 0; }
  case "$name" in *"("*|*")"*) echo "no parentheses — detail goes in the body" ;; esac
  case "$name" in *" — "*|*" · "*|*" / "*) echo "no ' — ' / ' · ' / ' / ' sub-clauses — one clear phrase" ;; esac
  case "$name" in *—*|*▾*|*▸*|*→*|*✓*|*✗*|*…*|*•*) echo "no glyphs (— ▾ ▸ → ✓ ✗ … •) in the title" ;; esac
  if grep -qE '\.(sh|ts|tsx|js|mjs|json|css|md|ya?ml)([^A-Za-z0-9]|$)|[a-z0-9]+_[a-z0-9]+|(^|[^A-Za-z])(scripts|apps|packages|src)/' <<<"$name"; then
    echo "no code identifiers (file names, paths, snake_case) — name the outcome"
  fi
  # One word per line, read back: zsh does not word-split an unquoted expansion.
  printf '%s\n' "$jargon" | tr ' ' '\n' | while IFS= read -r w; do
    [ -n "$w" ] || continue
    grep -qiwE "$w" <<<"$name" && echo "jargon word '$w' — use plain language"
  done
  wc=$(printf '%s\n' "$name" | wc -w | tr -d ' ')
  [ "$wc" -gt 6 ] && echo "name is $wc words — keep it ≤ 6 (detail goes in the body)"
  return 0
}

# naming_title_lint <effort|sub|issue|pr> <title> — rc 0 when <title> follows the rule for <kind>;
# rc 1 with every failed rule on stderr; rc 2 on a usage error.
naming_title_lint() {
  local kind="${1:-}" title="${2:-}" name="" reasons="" flow flows
  [ -n "$title" ] || { echo "naming_title_lint: a title is required" >&2; return 2; }
  case "$kind" in
    effort)
      name="$(printf '%s' "$title" | sed -E -e 's/^\[E[0-9]+\] +//' -e 's/^\[Effort\] [0-9]+ · ?//')"
      [ "$name" = "$title" ] && reasons="missing the '[E<n>] ' prefix" ;;
    sub)
      name="$(printf '%s' "$title" | sed -E -e 's/^\[E[0-9]+\.[0-9]+\] +//' -e 's/^\[Effort [0-9]+\] [0-9]+ · ?//')"
      [ "$name" = "$title" ] && reasons="missing the '[E<n>.<step>] ' prefix" ;;
    issue)
      name="$title"
      case "$title" in "["*) reasons="no prefix — a standalone issue title is a plain outcome (an effort is '[E<n>] <name>')" ;; esac ;;
    pr)
      # pr.titleStyle = issue-title: the PR title IS the issue title, and the repo runs no
      # Conventional Commit gate, so only an empty title is refused here.
      [ "${KIT_PR_TITLE_STYLE:-conventional}" = "issue-title" ] && return 0
      if command -v commitlint_check >/dev/null 2>&1; then
        commitlint_check "$title" >/dev/null 2>&1 || reasons="not a Conventional Commit subject — type(scope): subject"
      else
        grep -qE '^[a-z]+(\([a-z0-9][a-z0-9._/-]*\))?!?: [^[:space:]]' <<<"$title" \
          || reasons="not a Conventional Commit subject — type(scope): subject"
      fi
      if ! grep -qE "$NAMING_PR_TOKEN_RE" <<<"$title"; then
        reasons="${reasons:+$reasons
}no trailing token — end with [E<n>] (effort), [E<n>.<step>] (sub) or [#<n>] (standalone issue)"
      fi ;;
    *) echo "naming_title_lint: kind must be effort, sub, issue or pr (got '$kind')" >&2; return 2 ;;
  esac

  if [ "$kind" != pr ]; then
    # One optional [Flow] tag is tolerated after an effort or sub prefix (legacy titles carry one);
    # it must come from the flow vocabulary.
    if [ "$kind" != issue ]; then
      flow="$(printf '%s' "$name" | sed -nE 's/^\[([A-Za-z]+)\] +.*/\1/p')"
      if [ -n "$flow" ]; then
        name="$(printf '%s' "$name" | sed -E 's/^\[[A-Za-z]+\] +//')"
        flows="${EFFORT_FLOWS:-Core UI API Docs Infra Auth Data Web App}"
        case " $flows " in
          *" $flow "*) : ;;
          *) reasons="${reasons:+$reasons
}flow tag [$flow] is not in the vocabulary ($flows)" ;;
        esac
      fi
    fi
    local more; more="$(_naming_name_reasons "$name")"
    [ -n "$more" ] && reasons="${reasons:+$reasons
}$more"
  fi

  [ -n "$reasons" ] || return 0
  {
    echo "✗ $kind title breaks the naming rule (rules/naming-and-ids.md): $title"
    printf '%s\n' "$reasons" | sed 's/^/    - /'
  } >&2
  return 1
}
