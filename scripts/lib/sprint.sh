#!/usr/bin/env bash
# shellcheck shell=bash
# sprint.sh — `cckit effort sprint`: one week of work, Monday to Monday, as a forge milestone (#570,
# E547). The milestone's title is the ISO week (`2026-W48`), its description the sprint goal, its
# due date the Monday the sprint ends. The issues on it are the sprint backlog; waves run inside it.
# A sub-verb of `effort`, not a top-level verb: the verb count may only go down (scripts/verbs.baseline).
#
#   sprint_name [YYYY-MM-DD]                 the sprint a day falls in (default today): 2026-W48
#   sprint_bounds [YYYY-MM-DD]               its Monday and the next Monday, tab-separated
#   sprint_open [--goal G] [--date D]        create the milestone; an existing one is kept (and its
#                                            goal updated when --goal is given) — safe to re-run
#   sprint_list [--all]                      the sprint milestones: title, state, open, closed, due
#   sprint_close [<name>] [--review T|--review-file F] [--retro T|--retro-file F] [--out F] [--dry-run]
#                                            write the sprint review + retrospective page, then close
#                                            the milestone with a one-line review in its description
#   sprint_cli <name|bounds|open|list|close> …   the `cckit effort sprint` dispatcher
#
# Only `name` and `bounds` run on git alone; the rest read or write the forge (forge_rest).
# bash 3.2 compatible; GNU and BSD `date` both work.
# errors: mixed — name/bounds are pure; open/list/close propagate a forge failure (rc 1)

if ! command -v forge_rest >/dev/null 2>&1 && ! command -v gh_rest_issue_json >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/gh-rest.sh"
fi

SPRINT_TITLE_RE='^[0-9]{4}-W[0-9]{2}$'

# _sprint_date <YYYY-MM-DD> <+%fmt> [<days to add>] — format a day, optionally shifted. GNU first,
# then BSD. rc 1 on a day neither understands.
_sprint_date() {
  local d="$1" fmt="$2" add="${3:-0}" sign="+"
  case "$add" in -*) sign="-"; add="${add#-}" ;; esac
  case "$d" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) return 1 ;; esac
  date -d "$d $sign$add days" "$fmt" 2>/dev/null && return 0
  date -j -v"$sign${add}d" -f '%Y-%m-%d' "$d" "$fmt" 2>/dev/null && return 0
  return 1
}

_sprint_today() { date '+%Y-%m-%d'; }

sprint_bounds() {
  local d="${1:-$(_sprint_today)}" dow start end
  dow="$(_sprint_date "$d" '+%u')" || { echo "sprint: not a YYYY-MM-DD date: '$d'" >&2; return 2; }
  start="$(_sprint_date "$d" '+%Y-%m-%d' "-$((dow - 1))")" || return 1
  end="$(_sprint_date "$start" '+%Y-%m-%d' 7)" || return 1
  printf '%s\t%s\n' "$start" "$end"
}

sprint_name() {
  local d="${1:-$(_sprint_today)}"
  _sprint_date "$d" '+%G-W%V' || { echo "sprint: not a YYYY-MM-DD date: '$d'" >&2; return 2; }
}

_sprint_repo() { printf '%s' "${KIT_REPO:-${EFFORT_REPO:-}}"; }
_sprint_need() {
  forge_need "effort sprint" || return 1
  command -v jq >/dev/null 2>&1 || { echo "effort sprint: jq is required" >&2; return 1; }
  [ -n "$(_sprint_repo)" ] || { echo "effort sprint: no repository (github.repo unset)" >&2; return 1; }
}

# _sprint_milestone <title> — echo the milestone's JSON ({number,title,state,description,…}), or
# nothing when there is none. rc 1 when the read fails.
_sprint_milestone() {
  forge_rest "repos/$(_sprint_repo)/milestones" -X GET -f state=all -f per_page=100 \
    --jq ".[] | select(.title == \"$1\") | tojson" | sed -n 1p
}

_sprint_description() { # <goal> <start> <end>
  printf 'Sprint goal: %s\n\nMonday %s to Monday %s.' "${1:-not set}" "$2" "$3"
}

sprint_open() {
  local goal="" d="" name start end ms num desc
  while [ $# -gt 0 ]; do
    case "$1" in
      --goal) goal="${2:-}"; shift 2 ;;
      --date) d="${2:-}"; shift 2 ;;
      *) echo "effort sprint open: unknown argument '$1'" >&2; return 2 ;;
    esac
  done
  d="${d:-$(_sprint_today)}"
  name="$(sprint_name "$d")" || return 2
  IFS="$(printf '\t')" read -r start end <<EOF_B
$(sprint_bounds "$d")
EOF_B
  _sprint_need || return 1
  ms="$(_sprint_milestone "$name")" || { echo "effort sprint: could not read the milestones" >&2; return 1; }
  desc="$(_sprint_description "$goal" "$start" "$end")"
  if [ -n "$ms" ]; then
    num="$(printf '%s' "$ms" | jq -r .number)"
    if [ -n "$goal" ]; then
      forge_rest "repos/$(_sprint_repo)/milestones/$num" -X PATCH -f "description=$desc" --silent \
        || { echo "effort sprint: could not update the goal of $name" >&2; return 1; }
      echo "  ✓ sprint $name is open; goal updated" >&2
    else
      echo "  ✓ sprint $name is already open (milestone $num)" >&2
    fi
  else
    num="$(forge_rest "repos/$(_sprint_repo)/milestones" -X POST -f "title=$name" -f "description=$desc" \
      -f "due_on=${end}T00:00:00Z" --jq .number)" || { echo "effort sprint: could not create $name" >&2; return 1; }
    echo "  ✓ sprint $name opened (milestone $num): Monday $start to Monday $end" >&2
  fi
  printf '%s\n' "$name"
}

sprint_list() {
  local state=open
  case "${1:-}" in --all) state=all ;; '') ;; *) echo "effort sprint list: unknown argument '$1'" >&2; return 2 ;; esac
  _sprint_need || return 1
  local rows
  rows="$(forge_rest "repos/$(_sprint_repo)/milestones" -X GET -f "state=$state" -f per_page=100 \
    --jq ".[] | select(.title | test(\"$SPRINT_TITLE_RE\")) | [.title, .state, (.open_issues|tostring), (.closed_issues|tostring), ((.due_on // \"-\") | .[0:10])] | @tsv")" \
    || { echo "effort sprint: could not read the milestones" >&2; return 1; }
  if [ -z "$rows" ]; then echo "no $state sprint — open one with: cckit effort sprint open --goal \"<goal>\""; return 0; fi
  printf 'sprint\tstate\topen\tclosed\tdue\n%s\n' "$(printf '%s\n' "$rows" | sort)"
}

# _sprint_text <inline> <file> — the inline text, else the file's, else nothing.
_sprint_text() {
  if [ -n "$1" ]; then printf '%s\n' "$1"; elif [ -n "$2" ]; then cat "$2"; fi
}

sprint_close() {
  local name="" review="" review_f="" retro="" retro_f="" out="" dry=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --review) review="${2:-}"; shift 2 ;;
      --review-file) review_f="${2:-}"; [ -r "$review_f" ] || { echo "effort sprint close: cannot read '$review_f'" >&2; return 2; }; shift 2 ;;
      --retro) retro="${2:-}"; shift 2 ;;
      --retro-file) retro_f="${2:-}"; [ -r "$retro_f" ] || { echo "effort sprint close: cannot read '$retro_f'" >&2; return 2; }; shift 2 ;;
      --out) out="${2:-}"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      -*) echo "effort sprint close: unknown flag '$1'" >&2; return 2 ;;
      *) name="$1"; shift ;;
    esac
  done
  name="${name:-$(sprint_name)}"
  grep -qE "$SPRINT_TITLE_RE" <<<"$name" || { echo "effort sprint close: '$name' is not a sprint name (YYYY-Www)" >&2; return 2; }
  _sprint_need || return 1
  local ms num desc goal issues done_rows open_rows n_done n_open
  ms="$(_sprint_milestone "$name")" || { echo "effort sprint: could not read the milestones" >&2; return 1; }
  [ -n "$ms" ] || { echo "effort sprint close: no milestone named $name — nothing to close" >&2; return 1; }
  num="$(printf '%s' "$ms" | jq -r .number)"
  desc="$(printf '%s' "$ms" | jq -r '.description // ""')"
  goal="$(printf '%s\n' "$desc" | sed -n 's/^Sprint goal:[[:space:]]*//p' | sed -n 1p)"
  issues="$(forge_rest "repos/$(_sprint_repo)/issues" -X GET -f "milestone=$num" -f state=all -f per_page=100 \
    --jq '[.[] | select(.pull_request | not) | {number, title, state}]')" || { echo "effort sprint: could not read the issues of $name" >&2; return 1; }
  done_rows="$(printf '%s' "$issues" | jq -r '.[] | select(.state == "closed") | "- #\(.number) \(.title)"')"
  open_rows="$(printf '%s' "$issues" | jq -r '.[] | select(.state != "closed") | "- #\(.number) \(.title)"')"
  n_done="$(printf '%s' "$issues" | jq '[.[] | select(.state == "closed")] | length')"
  n_open="$(printf '%s' "$issues" | jq '[.[] | select(.state != "closed")] | length')"

  local page review_txt retro_txt
  review_txt="$(_sprint_text "$review" "$review_f")"
  retro_txt="$(_sprint_text "$retro" "$retro_f")"
  page="$(cat <<EOF_PAGE
# Sprint $name · review and retrospective

## Sprint goal
${goal:-not set}

## Sprint review
${review_txt:-<!-- what was shown, what the owner said, what changes in the backlog -->}

### Done ($n_done)
${done_rows:-none}

### Carried over ($n_open)
${open_rows:-none}

## Retrospective
${retro_txt:-<!-- what went well · what to change · the one change the next sprint makes -->}
EOF_PAGE
)"
  if [ -n "$dry" ]; then
    printf '%s\n' "$page"
    echo "effort sprint close: --dry-run — no file written, $name left open" >&2
    return 0
  fi
  if [ -z "$out" ]; then
    local root; root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    out="$root/.cckit/reports/$(date '+%Y-%m-%d')-sprint-$name.md"
  fi
  mkdir -p "$(dirname "$out")" || return 1
  printf '%s\n' "$page" > "$out" || return 1
  local line
  line="$(printf '## Review\n%s done, %s carried over. Review and retrospective: %s' "$n_done" "$n_open" "$(basename "$out")")"
  forge_rest "repos/$(_sprint_repo)/milestones/$num" -X PATCH -f state=closed -f "description=$desc

$line" --silent || { echo "effort sprint close: wrote $out but could not close milestone $num" >&2; return 1; }
  echo "  ✓ sprint $name closed: $n_done done, $n_open carried over" >&2
  printf '%s\n' "$out"
}

sprint_cli() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    name)   sprint_name "$@" ;;
    bounds) sprint_bounds "$@" ;;
    open)   sprint_open "$@" ;;
    list)   sprint_list "$@" ;;
    close)  sprint_close "$@" ;;
    ''|-h|--help)
      cat <<'EOF_H'
cckit effort sprint name [YYYY-MM-DD]        the sprint a day falls in (ISO week, Monday to Monday)
cckit effort sprint bounds [YYYY-MM-DD]      its Monday and the next Monday
cckit effort sprint open [--goal G] [--date D]   create the sprint milestone; re-running keeps it
cckit effort sprint list [--all]             the sprint milestones with their open and closed counts
cckit effort sprint close [<YYYY-Www>] [--review T|--review-file F] [--retro T|--retro-file F] [--out F] [--dry-run]
                                             write the review + retrospective page, close the milestone
EOF_H
      [ -n "$sub" ] || return 2 ;;
    *) echo "cckit effort sprint <name|bounds|open|list|close>" >&2; return 2 ;;
  esac
}
