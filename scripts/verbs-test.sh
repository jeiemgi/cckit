#!/usr/bin/env bash
# shellcheck shell=bash
# verbs-test.sh — #555: scripts/lib/verbs.tsv is the one source for every cckit verb, and nothing that
# lists verbs drifts from it. Checks the table's shape, then compares it with the dispatcher's case
# labels, `cckit help`, `cckit commands` (human, --llm, --json), the completions, the generated block
# of the CLI reference page, skills/routing.yaml and scripts/forge-report.sh --verbs. A fixture table
# checks the readers in scripts/lib/verbs.sh. No network, no port.
# Run:  bash scripts/verbs-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> missing '$3'"; fail=1 ;; esac; }
TSV="$ROOT/scripts/lib/verbs.tsv"
CCKIT="$ROOT/bin/cckit"
command -v jq >/dev/null 2>&1 || { echo "verbs-test: jq required" >&2; exit 1; }
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/verbs.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# ── 1. the table's shape ─────────────────────────────────────────────────────────────────────────
bad="$(awk -F'\t' '!/^#/ && NF && NF != 10 { print NR ": " NF " fields" }' "$TSV")"
t "every row has 10 tab-separated fields" "$bad" ""
bad="$(verbs_rows | awk -F'\t' '$2 !~ /^(group|verb|default|alias)$/ { print $1 }')"
t "every kind is group, verb, default or alias" "$bad" ""
bad="$(verbs_rows | awk -F'\t' '$2 != "group" && $5 !~ /^(git|forge)$/ { print $1 }')"
t "every needs is git or forge" "$bad" ""
bad="$(verbs_rows | awk -F'\t' '$2 != "group" && $2 != "alias" && ($8 == "-" || $9 == "-" || $10 == "-" || $7 !~ /^(yes|no)$/) { print $1 }')"
t "every verb has a question, a prompt, a usage and an ownhelp" "$bad" ""
bad="$(verbs_rows | awk -F'\t' '$2 != "group" && $2 != "alias" && $10 !~ "^cckit" { print $1 }')"
t "every usage starts with cckit" "$bad" ""
bad="$(verbs_rows | awk -F'\t' '$2 != "group" && $9 ~ /#[0-9]|[^a-z-][0-9][0-9][0-9]+/ { print $1 }')"
t "no prompt carries an issue number (authoring.md § 2)" "$bad" ""
t "names are unique" "$(verbs_names verb default alias | sort | uniq -d | tr '\n' ' ')" ""
t "group ids are unique" "$(verbs_names group | sort | uniq -d | tr '\n' ' ')" ""
groups=" $(verbs_names group | tr '\n' ' ') "
bad="$(verbs_rows | awk -F'\t' -v g="$groups" '($2 == "verb" || $2 == "default") && !index(g, " " $4 " ") { print $1 }')"
t "every verb sits in a declared group" "$bad" ""
verbs=" $(verbs_names verb default | tr '\n' ' ') "
bad="$(verbs_rows | awk -F'\t' -v v="$verbs" '$2 == "alias" { split($3, w, " ") } $2 == "alias" && !index(v, " " w[1] " ") { print $1 }')"
t "every alias targets a verb (its first word; later words are arguments)" "$bad" ""
first="$(verbs_names group | sed -n 1p)"
t "git mechanics come first in the help" "$first" "git"
bad="$(verbs_rows | awk -F'\t' '$4 == "git" && $1 !~ /^(start|pr|merge|close|hotfix|task)$/ { print $1 }')"
t "the git group holds the branch-to-merged verbs" "$bad" ""

# ── 2. the dispatcher's case labels are the table's verbs, not its old names ───────────────────────────────────────
labels="$(grep -oE '^  [a-z][a-z|-]*\)' "$CCKIT" | sed 's/[) ]//g' | tr '|' '\n' | grep -vE '^(-|$)' | sort -u)"
table="$(verbs_names verb default | sort -u)"
t "every case label of bin/cckit is a name in the table" "$(comm -23 <(printf '%s\n' "$labels") <(printf '%s\n' "$table") | tr '\n' ' ')" ""
t "every verb in the table has a case label" "$(comm -13 <(printf '%s\n' "$labels") <(printf '%s\n' "$table") | tr '\n' ' ')" ""
bad=""; for a in $(verbs_names alias); do grep -qx "$a" <<<"$labels" && bad="$bad $a"; done
t "no old name has a case label: aliases go through the alias path" "$bad" ""

# ── 3. help, commands and completions read the table ────────────────────────────────────────────
help="$("$CCKIT" help 2>&1)"
missing=""; for v in $(verbs_names verb); do grep -qE "^  $v +" <<<"$help" || missing="$missing $v"; done
t "cckit help lists every verb" "$missing" ""
for q in $(verbs_rows | awk -F'\t' '$2 == "group" { gsub(/ /, "_", $8); print $8 }'); do
  has "cckit help prints the group heading ${q//_/ }" "$help" "${q//_/ }"
done
t "cckit --help is cckit help" "$("$CCKIT" --help 2>&1)" "$help"
t "cckit commands lists every name" "$("$CCKIT" commands | tr ' ' '\n' | sed '/^$/d' | sort -u)" "$(verbs_names | sort -u)"
t "cckit commands --llm keeps the array of names" "$("$CCKIT" commands --llm | jq -r '.[]' | sort -u)" "$(verbs_names | sort -u)"
json="$("$CCKIT" commands --json)"
t "cckit commands --json is valid JSON with one object per name" "$(jq length <<<"$json")" "$(verbs_names | wc -l | tr -d ' ')"
t "commands --json: start's question" "$(jq -r '.[] | select(.name=="start") | .question' <<<"$json")" "$(verbs_get start 8)"
t "commands --json: an alias carries its target" "$(jq -r '.[] | select(.name=="copilot") | .target' <<<"$json")" "wave"
t "commands --json: a multi-line usage is an array" "$(jq -r '.[] | select(.name=="effort") | .usage | length' <<<"$json")" "$(verbs_get effort 10 | awk -F'\\\\n' '{print NF}')"
has "the completions read cckit commands" "$("$CCKIT" completions bash)" 'cckit commands'

# ── 4. the CLI reference page ───────────────────────────────────────────────────────────────────
out="$(bash "$ROOT/scripts/verbs-gen.sh" --check 2>&1)"; rc=$?
t "the CLI reference block matches the table" "$rc" "0"
[ "$rc" -eq 0 ] || printf '%s\n' "$out" | sed -n 1,20p
page="$ROOT/docs-site/src/content/docs/cli-reference.mdx"
missing=""; for v in $(verbs_names verb); do grep -qE "\`cckit $v( |\`)" "$page" || missing="$missing $v"; done
t "the CLI reference names every verb" "$missing" ""
# The check sees drift: a fixture table with one more verb no longer matches the page.
mkdir -p "$tmp/fx/scripts/lib" "$tmp/fx/docs-site/src/content/docs"
cp "$ROOT/scripts/verbs-gen.sh" "$tmp/fx/scripts/"
cp "$ROOT/scripts/lib/verbs.sh" "$tmp/fx/scripts/lib/"
cp "$page" "$tmp/fx/docs-site/src/content/docs/"
{ cat "$TSV"; printf 'zzz\tverb\t-\tcatalog\tgit\t-\tno\tA new question?\tA new prompt.\tcckit zzz\n'; } > "$tmp/fx/scripts/lib/verbs.tsv"
bash "$tmp/fx/scripts/verbs-gen.sh" --check >/dev/null 2>&1; t "a verb added to the table fails the page check" "$?" "1"
bash "$tmp/fx/scripts/verbs-gen.sh" >/dev/null 2>&1
bash "$tmp/fx/scripts/verbs-gen.sh" --check >/dev/null 2>&1; t "regenerating the page clears it" "$?" "0"
has "the regenerated page carries the new verb" "$(cat "$tmp/fx/docs-site/src/content/docs/cli-reference.mdx")" '| `cckit zzz` | A new question? |'

# ── 5. skills/routing.yaml ──────────────────────────────────────────────────────────────────────
routed=" $(grep -E '^[[:space:]]+skill:' "$ROOT/skills/routing.yaml" | awk '{print $2}' | sort -u | tr '\n' ' ') "
bad=""; for s in $(verbs_rows | awk -F'\t' '$6 != "-" && $2 != "group" { print $6 }' | sort -u); do
  [ -f "$ROOT/skills/$s/SKILL.md" ] || bad="$bad $s(no-skill)"
  case "$routed" in *" $s "*) ;; *) bad="$bad $s(not-routed)" ;; esac
done
t "every skill the table names exists and is routed in skills/routing.yaml" "$bad" ""

# ── 6. needs matches scripts/forge-report.sh --verbs ────────────────────────────────────────────
report="$(bash "$ROOT/scripts/forge-report.sh" --verbs | awk 'NR > 1 { print $1 "\t" $2 }')"
bad=""
while IFS=$'\t' read -r v yn; do
  [ -n "$v" ] || continue
  want="$(verbs_get "$v" 5 2>/dev/null)" || { bad="$bad $v(not-in-table)"; continue; }
  have=git; [ "$yn" = yes ] && have=forge
  [ "$have" = "$want" ] || bad="$bad $v(table=$want,report=$have)"
done <<<"$report"
t "every verb's needs matches forge-report" "$bad" ""

# ── 7. the readers, on a fixture table ──────────────────────────────────────────────────────────
printf '# c\n\ng\tgroup\t-\t-\t-\t-\t-\tWhat now?\t-\t-\none\tverb\t-\tg\tgit\t-\tno\tQ one?\tP "one".\tcckit one\\ncckit one more\nold\talias\tone\t-\tgit\t-\t-\t-\t-\t-\n' > "$tmp/v.tsv"
t "fixture: verbs_count counts verb rows only" "$(VERBS_FILE="$tmp/v.tsv" verbs_count)" "1"
t "fixture: verbs_names default kinds" "$(VERBS_FILE="$tmp/v.tsv" verbs_names | tr '\n' ' ')" "one old "
t "fixture: verbs_get reads a field" "$(VERBS_FILE="$tmp/v.tsv" verbs_get one 8)" "Q one?"
VERBS_FILE="$tmp/v.tsv" verbs_get nothing 8 >/dev/null; t "fixture: verbs_get on an unknown name rc 1" "$?" "1"
t "fixture: verbs_json escapes quotes and splits usage" "$(VERBS_FILE="$tmp/v.tsv" verbs_json | jq -c '.[0] | [.prompt, .usage]')" '["P \"one\".",["cckit one","cckit one more"]]'
has "fixture: help prints the group, then the verb" "$(VERBS_FILE="$tmp/v.tsv" verbs_help)" "$(printf 'What now?\n  one             Q one?')"

[ "$fail" -eq 0 ] && echo "ALL OK (verbs)" || echo "verbs: FAILURES"
exit "$fail"
