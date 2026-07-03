#!/usr/bin/env bash
# shellcheck shell=bash
# effort-slug.sh — the effort *slug* layer (Effort #93). The GitHub issue NUMBER stays the canonical
# key; the slug is a DERIVED human handle that already lives in the branch name `effort/<N>-<slug>`.
# This file surfaces that handle: derive a slug from a title, render efforts as `slug #N`, and resolve
# a slug (or a number) back to the canonical effort number so commands can take either.
#
# Functions:
#   _eff_slug <text>                 a short branch-safe slug (mirrors wt_start; shared with effort-ops)
#   _eff_title_slug <effort title>   slug derived from an effort title — peels the structural prefix
#                                    ("[Effort] N · " / "[Effort N] M · ") and any leading [Flow] tag so
#                                    the number/flow are NOT duplicated into the slug (#93 doubling fix)
#   effort_display <N> [slug]        render an effort as "slug #N" (or "#N" when no slug is known)
#   effort_slug_resolve <slug|N>     resolve a slug OR a number to the canonical effort number.
#                                    pure-digits → passthrough; otherwise match effort/* branches
#                                    (local + remote), then slug:<slug> labels, then open effort titles.
#                                    no match → rc 1; ambiguous → rc 1; bad input → rc 2.
#
# Number stays canonical: a pure-digits argument is always treated as a number and passed through
# unchanged, so every existing `<N>` call keeps working. bash 3.2 compatible. Requires: git; gh (only
# for the issue-based fallback when no local/remote branch matches).

# Repo for the gh fallback — resolved from the same env effort.sh/kit-config populate.
_eff_slug_repo() { printf '%s' "${EFFORT_REPO:-${KIT_REPO:-}}"; }

# <text> → a short branch-safe slug (lowercase, [a-z0-9-], ≤40 chars). Mirrors wt_start / effort-ops.
_eff_slug() {
  printf '%s' "$1" | sed -E 's/^\[[^]]+\][[:space:]]*//' | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40
}

# <effort title> → the human slug. Peels the structural prefix and one optional leading [Flow] tag
# BEFORE slugifying, so `[Effort] 93 · [Core] Slug handles` → `slug-handles` (not `93-core-slug-handles`,
# the cosmetic doubling that produced branches like `effort/98-98-core-…`). See #93 / sub #96.
_eff_title_slug() {
  local t="$1"
  # structural prefix: "[Effort] N · " (parent) or "[Effort N] M · " (sub)
  t="$(printf '%s' "$t" | sed -E 's/^\[Effort( [0-9]+)?\] [0-9]+ ·? ?//')"
  # one optional leading [Flow] tag
  t="$(printf '%s' "$t" | sed -E 's/^\[[A-Za-z]+\][[:space:]]*//')"
  _eff_slug "$t"
}

# <N> [slug] → "slug #N" for human output (the canonical handle is the number; the slug is the label).
effort_display() {
  local n="$1" s="${2:-}"
  if [ -n "$s" ]; then printf '%s #%s' "$s" "$n"; else printf '#%s' "$n"; fi
}

# effort_slug_resolve <slug|N> → echo the canonical effort number on stdout (rc 0).
#   - pure digits → passthrough (number stays canonical; never re-mapped).
#   - otherwise normalize and match, in order: effort/* branches (local + remote), then (via gh)
#     slug:<slug> labels, then title-derived slugs of open `[Effort]` issues.
#   - no match → rc 1; >1 distinct match → rc 1 (ambiguous, never a wrong guess); empty/unusable → rc 2.
effort_slug_resolve() {
  local input="${1:-}"
  [ -n "$input" ] || { echo "effort_slug_resolve: <slug|N> required" >&2; return 2; }
  case "$input" in
    *[!0-9]*) : ;;                                   # contains a non-digit → treat as a slug
    *) printf '%s\n' "$input"; return 0 ;;           # all digits → canonical number, passthrough
  esac

  local norm; norm="$(_eff_slug "$input")"
  [ -n "$norm" ] || { echo "effort_slug_resolve: '$input' is not a usable slug" >&2; return 2; }

  local matches="" ref n s
  # 1. branches (local refs/heads + remote refs/remotes): effort/<N>-<slug>
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    n="$(printf '%s' "$ref" | sed -nE 's#^(.*/)?effort/([0-9]+)-(.*)$#\2#p')"
    s="$(printf '%s' "$ref" | sed -nE 's#^(.*/)?effort/([0-9]+)-(.*)$#\3#p')"
    [ -n "$n" ] || continue
    [ "$s" = "$norm" ] && matches="$matches$n"$'\n'
  done < <(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes 2>/dev/null \
             | grep -E '(^|/)effort/[0-9]+-' )
  matches="$(printf '%s' "$matches" | grep -E '^[0-9]+$' | sort -un)"

  # 2. gh fallback (only when no branch matched): slug:<slug> label first, then open effort titles.
  if [ -z "$matches" ] && command -v gh >/dev/null 2>&1; then
    local repo; repo="$(_eff_slug_repo)"
    if [ -n "$repo" ]; then
      matches="$(gh issue list --repo "$repo" --state open --label "slug:$norm" \
                   --json number -q '.[].number' 2>/dev/null | grep -E '^[0-9]+$' | sort -un)"
      if [ -z "$matches" ]; then
        local in it
        matches="$(gh issue list --repo "$repo" --state open --search '[Effort] in:title' --limit 200 \
                     --json number,title -q '.[] | "\(.number)\t\(.title)"' 2>/dev/null \
                   | while IFS="$(printf '\t')" read -r in it; do
                       [ "$(_eff_title_slug "$it")" = "$norm" ] && printf '%s\n' "$in"
                     done | grep -E '^[0-9]+$' | sort -un)"
      fi
    fi
  fi

  local count; count="$(printf '%s\n' "$matches" | grep -cE '^[0-9]+$')"
  if [ "$count" -eq 0 ]; then
    echo "effort_slug_resolve: no effort matches slug '$norm' (looked in effort/* branches, slug:* labels, open effort titles)" >&2
    return 1
  elif [ "$count" -gt 1 ]; then
    echo "effort_slug_resolve: slug '$norm' is ambiguous — matches efforts $(printf '%s' "$matches" | tr '\n' ' ')— pass the number" >&2
    return 1
  fi
  printf '%s\n' "$matches"
}
