#!/usr/bin/env bash
# verbs.sh — read lib/core/verbs.tsv, the one source for every cckit verb (#555): the grouped
# `cckit help`, the entry `cckit <verb> --help` prints, the `cckit commands` catalog and the alias
# path. Every reader of the verb list goes through these functions, so the file format lives here.
#
#   verbs_file                 the path of the table (VERBS_FILE overrides, for tests)
#   verbs_rows                 the data rows, tab-separated, comments and blanks dropped
#   verbs_get <name> <col>     one field of the non-group row named <name> (col 1-10); rc 1 if none
#   verbs_names [kinds…]       names of the rows of those kinds (default: verb default alias)
#   verbs_count                the number of `verb` rows (the ratchet in lib/core/verbs.baseline)
#   verbs_help                 the grouped help: one line per verb under each group's question
#   verbs_entry <name>         usage, question, prompt, needs and skill of one verb; rc 1 if none
#   verbs_alias_target <name>  the verb an old name runs, with any words after it; rc 1 when not an alias
#   verbs_alias_notice <old> <new>  the one-line notice an old name prints on stderr (#557)
#   verbs_json                 every non-group row as a JSON array of objects (no jq needed)
#   verbs_reference_md         the CLI reference page's generated block: one table per group
# errors: pure — reads one file; a missing table prints nothing and returns 1
# bash 3.2 compatible: awk only, no associative arrays.

verbs_file() {
  if [ -n "${VERBS_FILE:-}" ]; then printf '%s\n' "$VERBS_FILE"; return 0; fi
  printf '%s\n' "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/verbs.tsv"
}

verbs_rows() {
  local f; f="$(verbs_file)"
  [ -f "$f" ] || return 1
  awk -F'\t' '/^#/ || NF == 0 { next } { print }' "$f"
}

verbs_get() {
  local name="$1" col="$2"
  verbs_rows | awk -F'\t' -v n="$name" -v c="$col" '$1 == n && $2 != "group" { print $c; found = 1; exit } END { exit !found }'
}

verbs_names() {
  local kinds="${*:-verb default alias}"
  verbs_rows | awk -F'\t' -v k=" $kinds " 'index(k, " " $2 " ") { print $1 }'
}

verbs_count() { verbs_rows | awk -F'\t' '$2 == "verb" { n++ } END { print n + 0 }'; }

verbs_help() {
  printf 'cckit — every verb answers a question.\n'
  printf '  cckit <verb> --help    one verb: its usage, its question and a prompt to paste\n'
  printf '  cckit commands --json  every verb as data: question, prompt to paste, usage, needs\n'
  verbs_rows | awk -F'\t' '
    $2 == "group" { printf "\n%s\n", $8; next }
    $2 == "verb"  { printf "  %-15s %s\n", $1, $8 }
    $2 == "default" { printf "  %-15s %s\n", "(no verb)", $8 }'
  local aliases
  aliases="$(verbs_rows | awk -F'\t' '$2 == "alias" { printf "%s%s -> %s", sep, $1, $3; sep = " · " }')"
  [ -z "$aliases" ] || printf '\nOld names that still work: %s\n' "$aliases"
}

verbs_entry() {
  local row
  row="$(verbs_rows | awk -F'\t' -v n="$1" '$1 == n && ($2 == "verb" || $2 == "default") { print; exit }')"
  [ -n "$row" ] || return 1
  printf '%s\n' "$row" | awk -F'\t' '{
    u = $10; gsub(/\\n/, "\n", u); print u
    print ""
    printf "  Answers: %s\n", $8
    printf "  Paste:   \"%s\"\n", $9
    if ($5 == "forge") print "  Needs:   git; reads or writes the forge (GitHub) when one is configured"
    else               print "  Needs:   git only"
    if ($6 != "-") printf "  Skill:   %s\n", $6
  }'
}

verbs_alias_target() {
  verbs_rows | awk -F'\t' -v n="$1" '$1 == n && $2 == "alias" { print $3; found = 1; exit } END { exit !found }'
}

verbs_alias_notice() {
  printf "cckit: '%s' is an old name for '%s'; it still works. Use 'cckit %s'.\n" "$1" "$2" "$2"
}

verbs_json() {
  verbs_rows | awk -F'\t' '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); return s }
    function nul(s) { return s == "-" ? "null" : "\"" esc(s) "\"" }
    $2 == "group" { next }
    {
      u = $10; n = split(u, parts, /\\n/); us = ""
      for (i = 1; i <= n; i++) us = us (i > 1 ? "," : "") "\"" esc(parts[i]) "\""
      printf "%s{\"name\":\"%s\",\"kind\":\"%s\",\"target\":%s,\"group\":%s,\"needs\":\"%s\",\"skill\":%s,\"question\":%s,\"prompt\":%s,\"usage\":[%s]}",
        sep, esc($1), $2, nul($3), nul($4), $5, nul($6), nul($8), nul($9), (u == "-" ? "" : us)
      sep = ","
    }
    BEGIN { printf "[" } END { print "]" }'
}

verbs_reference_md() {
  verbs_rows | awk -F'\t' '
    function cell(s) { gsub(/\|/, "\\|", s); return s }
    $2 == "group" { printf "%s### %s\n\n| Verb | Answers | Paste | Needs | Skill |\n| --- | --- | --- | --- | --- |\n", (n++ ? "\n" : ""), $8; next }
    $2 == "verb" || $2 == "default" {
      v = ($2 == "default") ? "`cckit` (no verb)" : "`cckit " $1 "`"
      printf "| %s | %s | %s | %s | %s |\n", v, cell($8), cell($9), ($5 == "forge" ? "git + forge" : "git"), ($6 == "-" ? "—" : "`" $6 "`")
    }'
  local aliases
  aliases="$(verbs_rows | awk -F'\t' '$2 == "alias" { printf "%s`cckit %s` runs `cckit %s`", sep, $1, $3; sep = " · " }')"
  [ -z "$aliases" ] || printf '\nOld names that still work: %s.\n' "$aliases"
}
