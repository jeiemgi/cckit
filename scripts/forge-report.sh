#!/usr/bin/env bash
# forge-report.sh — E537.1: measure where cckit depends on a forge (GitHub through `gh`) and where it
# needs only git. The ratchet source for effort 537 (git apart from GitHub): every later sub reads
# its numbers before and after.
#
#   scripts/forge-report.sh                 summary + the file table + the verb table
#   scripts/forge-report.sh --summary       the two summary lines only
#   scripts/forge-report.sh --files         per file: gh lines · git lines · class
#   scripts/forge-report.sh --verbs         per verb of bin/cckit: needs a forge yes|no · via which files
#   scripts/forge-report.sh --ratchet       ONE integer: files outside the forge layer that call gh
#   scripts/forge-report.sh --json          everything as one JSON object (no jq needed to produce it)
#   scripts/forge-report.sh --root <dir>    measure another checkout (default: this repository)
#
# What is measured (non-test files only: bin/*, scripts/*.sh, scripts/lib/*.sh, never *-test.sh):
#   gh line  — a non-comment line that runs `gh <subcommand>` in command position (line start, after
#              `(`, `$(`, `|`, `;`, `&`, `!`, `{`, or after if/then/else/do/while/exec), a `gh "$…"`
#              form, or a probe (`command -v gh`, `has_cmd gh`, `_eff_need gh`). A message that
#              tells a person to run gh is not a call.
#   git line — a non-comment line that runs `git <subcommand>` or `git -C`.
#   class    — gh-only · git-only · both · neither, from those two counts.
#   verb     — a label of the `case "$cmd"` dispatcher in bin/cckit. A verb needs a forge when its
#              own block, or any file it execs or sources (followed transitively through `source`/`.`
#              of *.sh files under scripts/ and scripts/lib/), has a gh line or calls into the forge
#              layer (forge_*, gh_rest_*; a bare forge_available probe does not count). The forge
#              layer's own files are not attributed to a verb. The preamble before the case is
#              shared by every verb and is not attributed to any.
#   forge layer — scripts/lib/forge.sh, scripts/lib/forge-*.sh and scripts/lib/gh-rest.sh (E537.2):
#              gh runs there only (gh auth token), so --ratchet leaves the layer out.
# errors: strict — set -e; an unreadable root or a bin/cckit without a dispatcher exits 1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mode="all"
while [ $# -gt 0 ]; do
  case "$1" in
    --summary|--files|--verbs|--ratchet|--json) mode="${1#--}"; shift ;;
    --root) ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "forge-report: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -f "$ROOT/bin/cckit" ] || { echo "forge-report: no bin/cckit under $ROOT" >&2; exit 1; }

GH_PRE='(^|[;&|(){!`]|\$\(|(^|[^[:alnum:]_])(if|then|else|elif|do|while|until|exec|time|env|nohup)[[:space:]]+)[[:space:]]*'
GH_RE="${GH_PRE}gh[[:space:]]+(api|pr|issue|repo|run|release|auth|label|project|search|workflow|secret|variable|cache|gist|browse|extension|config|--version)([^[:alnum:]_-]|\$)|(command -v|has_cmd|_eff_need) gh([^[:alnum:]_-]|\$)|${GH_PRE}gh[[:space:]]+\"\\\$"
# A call into the forge layer: the verb needs a forge even though no gh runs (E537.2+).
FORGE_RE='(^|[^[:alnum:]_])(forge_(rest|graphql|api|issue_[a-z]+|pr_[a-z]+|need|login[a-z_]*)|gh_rest_[a-z_]+|_ghr_api)([^[:alnum:]_]|$)'
GIT_RE='(^|[^[:alnum:]_./-])git[[:space:]]+(-C[[:space:]]|-c[[:space:]]|[a-z][a-z-]*([^[:alnum:]_-]|$))'

# fr_files: the measured files, repo-relative, sorted.
fr_files() {
  ( cd "$ROOT" && {
      for f in bin/*; do [ -f "$f" ] && echo "$f"; done
      for f in scripts/*.sh scripts/lib/*.sh; do [ -f "$f" ] && echo "$f"; done
    } | grep -v -- '-test\.sh$' | sort -u )
}
# fr_count <regex> <file>: matching non-comment lines.
fr_count() { grep -vE '^[[:space:]]*#' "$ROOT/$2" 2>/dev/null | grep -cE "$1" || true; }
fr_class() { # <gh> <git>
  if [ "$1" -gt 0 ] && [ "$2" -gt 0 ]; then echo both
  elif [ "$1" -gt 0 ]; then echo gh-only
  elif [ "$2" -gt 0 ]; then echo git-only
  else echo neither; fi
}
fr_is_forge_layer() { case "$1" in scripts/lib/forge.sh|scripts/lib/forge-*.sh|scripts/lib/gh-rest.sh) return 0 ;; *) return 1 ;; esac; }
# fr_calls_forge <file-or-text-on-stdin>: a non-comment, non-definition line that calls the layer.
fr_calls_forge_text() { local t; t="$(grep -vE '^[[:space:]]*#|^[[:space:]]*[a-z_]+\(\)' || true)"; grep -qE "$FORGE_RE" <<<"$t"; }

# fr_resolve <name>: a *.sh basename (or scripts/… path) → repo-relative path, or nothing.
fr_resolve() {
  local n="$1" b
  n="${n#\$ROOT/}"; n="${n#\$LIB/}"; n="${n#\$\{ROOT\}/}"; n="${n#\$\{LIB\}/}"
  b="$(basename "$n")"
  case "$b" in *-test.sh) return 0 ;; esac
  if [ -f "$ROOT/$n" ] && [ "${n#scripts/}" != "$n" ]; then echo "$n"; return; fi
  if [ -f "$ROOT/scripts/lib/$b" ]; then echo "scripts/lib/$b"; return; fi
  if [ -f "$ROOT/scripts/$b" ]; then echo "scripts/$b"; return; fi
}
# fr_refs_in_text: file references in a block of shell (exec/source targets, scripts paths).
fr_refs_in_text() {
  grep -vE '^[[:space:]]*#' | grep -oE '(\$\{?(ROOT|LIB)\}?/[A-Za-z0-9_./-]+|(^|[[:space:]])(source|\.)[[:space:]]+"?[^;&|]*/[A-Za-z0-9_-]+\.sh)' \
    | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+"?//' | sort -u
}
# fr_closure <file…>: the files plus everything they source, transitively (bash 3.2: a list string).
fr_closure() {
  local queue="$*" seen="" f r
  while [ -n "$queue" ]; do
    f="${queue%% *}"; queue="${queue#"$f"}"; queue="${queue# }"
    [ -n "$f" ] || continue
    grep -qxF "$f" <<<"$seen" && continue
    seen="$seen
$f"
    for r in $(fr_refs_in_text < "$ROOT/$f" | while read -r x; do fr_resolve "$x"; done | sort -u); do
      grep -qxF "$r" <<<"$seen" || queue="$queue $r"
    done
  done
  printf '%s\n' "$seen" | sed '/^$/d'
}

# The dispatcher: verb labels and their blocks, from `case "$cmd" in` to its `esac`.
fr_dispatcher() {
  awk '/^case "\$cmd" in/{on=1; next} on && /^esac/{exit} on{print}' "$ROOT/bin/cckit"
}
fr_verb_rows() { # verb<TAB>needs<TAB>via (space-separated files with gh lines)
  local disp block label verbs v needs via files f gh
  disp="$(fr_dispatcher)"
  [ -n "$disp" ] || { echo "forge-report: no 'case \"\$cmd\" in' dispatcher in bin/cckit" >&2; return 1; }
  printf '%s\n' "$disp" | awk '
    /^  [a-z][a-z0-9|_-]*\)/ { if (label != "") { print label "\t" block }; label=$0; sub(/\).*/, "", label); sub(/^  /, "", label); block=$0; next }
    label != "" { block = block "\001" $0 }
    END { if (label != "") print label "\t" block }' | while IFS=$'\t' read -r label block; do
      block="$(printf '%s' "$block" | tr '\001' '\n')"
      verbs="$(printf '%s' "$label" | tr '|' ' ')"
      needs=no; via=""
      blk="$(printf '%s\n' "$block" | grep -vE '^[[:space:]]*#' || true)"
      if grep -qE "$GH_RE" <<<"$blk" || printf '%s\n' "$blk" | fr_calls_forge_text; then needs=yes; via="bin/cckit"; fi
      files="$(printf '%s\n' "$block" | fr_refs_in_text | while read -r x; do fr_resolve "$x"; done | sort -u | tr '\n' ' ')"
      if [ -n "${files// /}" ]; then
        for f in $(fr_closure $files); do
          fr_is_forge_layer "$f" && continue
          gh="$(fr_count "$GH_RE" "$f")"
          if [ "$gh" -gt 0 ] || fr_calls_forge_text < "$ROOT/$f"; then needs=yes; via="$via $f"; fi
        done
      fi
      for v in $verbs; do
        case "$v" in help|--help|-h) continue ;; esac
        printf '%s\t%s\t%s\n' "$v" "$needs" "$(printf '%s' "$via" | sed 's/^ //')"
      done
    done
}

# ---- gather -----------------------------------------------------------------------------------
file_rows="$(for f in $(fr_files); do gh="$(fr_count "$GH_RE" "$f")"; git="$(fr_count "$GIT_RE" "$f")"; printf '%s\t%s\t%s\t%s\n' "$f" "$gh" "$git" "$(fr_class "$gh" "$git")"; done)"
n_files="$(printf '%s\n' "$file_rows" | sed '/^$/d' | wc -l | tr -d ' ')"
n_gh_only="$(printf '%s\n' "$file_rows" | awk -F'\t' '$4=="gh-only"' | wc -l | tr -d ' ')"
n_git_only="$(printf '%s\n' "$file_rows" | awk -F'\t' '$4=="git-only"' | wc -l | tr -d ' ')"
n_both="$(printf '%s\n' "$file_rows" | awk -F'\t' '$4=="both"' | wc -l | tr -d ' ')"
n_neither="$(printf '%s\n' "$file_rows" | awk -F'\t' '$4=="neither"' | wc -l | tr -d ' ')"
n_gh_lines="$(printf '%s\n' "$file_rows" | awk -F'\t' '{s+=$2} END{print s+0}')"
n_git_lines="$(printf '%s\n' "$file_rows" | awk -F'\t' '{s+=$3} END{print s+0}')"
ratchet="$(printf '%s\n' "$file_rows" | awk -F'\t' '$2>0 {print $1}' | while read -r f; do fr_is_forge_layer "$f" || echo "$f"; done | wc -l | tr -d ' ')"

if [ "$mode" = "ratchet" ]; then echo "$ratchet"; exit 0; fi

verb_rows="$(fr_verb_rows)"
n_verbs="$(printf '%s\n' "$verb_rows" | sed '/^$/d' | wc -l | tr -d ' ')"
n_forge="$(printf '%s\n' "$verb_rows" | awk -F'\t' '$2=="yes"' | wc -l | tr -d ' ')"

# ---- print ------------------------------------------------------------------------------------
print_summary() {
  printf 'forge report · %s\n' "$ROOT"
  printf 'files %s · gh-only %s · git-only %s · both %s · neither %s · gh lines %s · git lines %s · files calling gh outside the forge layer %s\n' \
    "$n_files" "$n_gh_only" "$n_git_only" "$n_both" "$n_neither" "$n_gh_lines" "$n_git_lines" "$ratchet"
  printf 'verbs %s · needs a forge %s · git only %s\n' "$n_verbs" "$n_forge" "$((n_verbs - n_forge))"
}
print_files() { printf 'file\tgh\tgit\tclass\n%s\n' "$file_rows" | column -t -s $'\t'; }
print_verbs() { printf 'verb\tneeds-forge\tvia\n%s\n' "$verb_rows" | column -t -s $'\t'; }
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
print_json() {
  printf '{"root":"%s","summary":{"files":%s,"gh_only":%s,"git_only":%s,"both":%s,"neither":%s,"gh_lines":%s,"git_lines":%s,"files_calling_gh_outside_forge":%s,"verbs":%s,"verbs_needing_forge":%s},' \
    "$(json_str "$ROOT")" "$n_files" "$n_gh_only" "$n_git_only" "$n_both" "$n_neither" "$n_gh_lines" "$n_git_lines" "$ratchet" "$n_verbs" "$n_forge"
  printf '"files":['
  printf '%s\n' "$file_rows" | sed '/^$/d' | awk -F'\t' 'NR>1{printf ","} {printf "{\"path\":\"%s\",\"gh\":%s,\"git\":%s,\"class\":\"%s\"}", $1, $2, $3, $4}'
  printf '],"verbs":['
  printf '%s\n' "$verb_rows" | sed '/^$/d' | awk -F'\t' 'NR>1{printf ","} { n=split($3, v, " "); printf "{\"verb\":\"%s\",\"needs_forge\":%s,\"via\":[", $1, ($2=="yes"?"true":"false"); for(i=1;i<=n;i++){ if(v[i]!=""){ printf "%s\"%s\"", (i>1?",":""), v[i] } } printf "]}" }'
  printf ']}\n'
}

case "$mode" in
  summary) print_summary ;;
  files)   print_files ;;
  verbs)   print_verbs ;;
  json)    print_json ;;
  all)     print_summary; echo; print_files; echo; print_verbs ;;
esac
