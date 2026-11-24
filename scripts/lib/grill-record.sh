#!/usr/bin/env bash
# shellcheck shell=bash
# grill-record.sh — the `## Grilling` record on an effort body (the advisor's grill stage, E547.2).
# The grill stage runs one interview, plays the understanding back, and the owner confirms it. What
# lands in the effort body is the confirmed record, never the raw interview. `cckit effort new
# --grilling T | --grilling-file F` runs grill_record_lint before any forge write, so an effort
# never carries a record that names nobody or holds no decision.
#
# A record passes in one of two shapes:
#   1. a waiver: the single line `waived: <reason>`, the reason not empty.
#   2. a confirmed record:
#      - its first non-blank line starts `Grilled:` and names who was grilled
#        (`Grilled: the maintainer, 2026-11-22, in session.`);
#      - a `YYYY-MM-DD` date somewhere in the record;
#      - at least 3 decisions as column-0 `1.` or `1)` items, or a link to the forge comment that
#        holds them (`…/issues/<n>#issuecomment-<id>`). An indented item continues the one above.
# An unattended run that assumed the decisions writes `Grilled: <agent> (assumed)`; it passes the
# lint, and the word `assumed` stays in the record so a reader sees no conversation happened.
#
# Functions:
#   grill_record_lint <text|->    rc 0 clean · 1 + reasons on stderr · 2 usage (no argument)
#   grill_record_section <text>   echo "## Grilling", a blank line, then the text (blank edges cut)
#
# bash 3.2 compatible; sourceable under zsh (awk does the parsing, no arrays).
# errors: strict — a validator: rc 1 on a record that is not one

GRILL_MIN_DECISIONS="${GRILL_MIN_DECISIONS:-3}"

# _grill_scan — read a record on stdin, print "<waiver 0|1|2> <grilled 0|1> <date 0|1> <decisions> <link 0|1>".
# waiver: 0 none, 1 a valid waiver, 2 `waived:` with no reason.
_grill_scan() {
  tr -d '\r' | awk '
    BEGIN { first = ""; waiver = 0; date = 0; dec = 0; link = 0; nonblank = 0 }
    {
      line = $0
      if (line ~ /^[ \t]*$/) next
      nonblank++
      if (first == "") first = line
      if (line ~ /[0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]/) date = 1
      if (line ~ /^[0-9]+[.)][ \t]+[^ \t]/) dec++
      if (line ~ /\/issues\/[0-9]+#issuecomment-[0-9]+/) link = 1
    }
    END {
      f = first; sub(/^[ \t]+/, "", f)
      if (nonblank == 1 && tolower(f) ~ /^waived:/) {
        r = f; sub(/^[^:]*:[ \t]*/, "", r)
        waiver = (r == "") ? 2 : 1
      }
      grilled = (f ~ /^Grilled:[ \t]*[^ \t]/) ? 1 : 0
      printf "%d %d %d %d %d\n", waiver, grilled, date, dec, link
    }'
}

grill_record_lint() {
  [ $# -ge 1 ] || { echo "grill_record_lint: usage: grill_record_lint <text|->" >&2; return 2; }
  local scan waiver grilled date dec link reasons=""
  if [ "$1" = "-" ]; then scan="$(_grill_scan)"
  else scan="$(printf '%s\n' "$1" | _grill_scan)"; fi
  read -r waiver grilled date dec link <<EOF_SCAN
$scan
EOF_SCAN
  case "${waiver:-0}" in
    1) return 0 ;;
    2) reasons="'waived:' needs a reason after it" ;;
    *)
      [ "${grilled:-0}" = 1 ] || reasons="${reasons}the first line must start 'Grilled:' and name who was grilled
"
      [ "${date:-0}" = 1 ] || reasons="${reasons}no YYYY-MM-DD date — say when the grill happened
"
      if [ "${link:-0}" != 1 ] && [ "${dec:-0}" -lt "$GRILL_MIN_DECISIONS" ]; then
        reasons="${reasons}${dec:-0} decision(s) — record at least $GRILL_MIN_DECISIONS as column-0 '1.' items, or link the comment that holds them
"
      fi ;;
  esac
  [ -n "$reasons" ] || return 0
  {
    echo "✗ the Grilling record is not one (skills/kit-advisor/references/grill.md):"
    printf '%s' "$reasons" | sed '/^$/d; s/^/    - /'
    echo "    (or write the single line 'waived: <reason>')"
  } >&2
  return 1
}

grill_record_section() {
  echo "## Grilling"
  echo
  printf '%s\n' "${1:-}" | tr -d '\r' | awk 'NF { started = 1 } started { buf[++n] = $0 } END { while (n > 0 && buf[n] ~ /^[ \t]*$/) n--; for (i = 1; i <= n; i++) print buf[i] }'
}
