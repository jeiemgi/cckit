#!/usr/bin/env bash
# shellcheck shell=bash
# advisor-test.sh — the kit-advisor skill (E547): the router stays short, every stage reference
# ends with the step report in its one order plus the trail command, and every `cckit` verb the
# skill names is one the kit has. Text checks only; no forge, no network.
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SK="$ROOT/kit/skills/kit-advisor"
fail=0
ok()  { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }
# shellcheck source=/dev/null
. "$ROOT/lib/verbs/kit-brief.sh"

ORDER='Status · Done · Waiting for a yes · Numbers · Failing or risky · Open questions · Next step'
# flat <file> — the file on one line, whitespace and markdown emphasis collapsed, so a sentence the
# editor wrapped still matches.
flat() { tr '\n' ' ' < "$1" | sed 's/\*\*//g; s/[[:space:]][[:space:]]*/ /g'; }

[ -f "$SK/SKILL.md" ] || { echo "FAIL: no skills/kit-advisor/SKILL.md"; exit 1; }
lines="$(wc -l < "$SK/SKILL.md" | tr -d ' ')"
if [ "$lines" -le 80 ]; then ok "SKILL.md is a router ($lines lines, at most 80)"; else bad "SKILL.md has $lines lines (at most 80)"; fi
case "$(flat "$SK/SKILL.md")" in *"$ORDER"*) ok "SKILL.md states the report order" ;; *) bad "SKILL.md lacks the report order" ;; esac

for stage in grill plan orchestrate review close; do
  f="$SK/references/$stage.md"
  [ -f "$f" ] || { bad "no references/$stage.md"; continue; }
  grep -q "references/$stage.md" "$SK/SKILL.md" && ok "SKILL.md routes to $stage" || bad "SKILL.md does not route to $stage"
  body="$(flat "$f")"
  case "$body" in *"$ORDER"*) ok "$stage states the report order" ;; *) bad "$stage lacks the report order" ;; esac
  case "$body" in *'cckit agent receipt <'*'--report .cckit/reports/'*) ok "$stage states the trail command" ;; *) bad "$stage lacks the trail command" ;; esac
  case "$body" in *'references/step-report.md'*) ok "$stage points to the template" ;; *) bad "$stage does not point to step-report.md" ;; esac
done
case "$(flat "$SK/references/step-report.md")" in *"$ORDER"*) ok "the template states the order" ;; *) bad "the template lacks the order" ;; esac

# The template's seven headings, in order.
got="$(grep '^## ' "$SK/references/step-report.md" | sed -n '/^## Status$/,/^## Next step$/p' | sed 's/^## //' | paste -sd'|' -)"
want="$(printf '%s' "$ORDER" | sed 's/ · /|/g')"
[ "$got" = "$want" ] && ok "the template's headings follow the order" || bad "template headings '$got' != '$want'"

# Every `cckit <verb> [<sub>]` the skill names in code (a code line or a backtick span) resolves (an `effort` sub-verb against the dispatcher).
verbs="$(cat "$SK/SKILL.md" "$SK"/references/*.md | grep -oE '(^|`)cckit [a-z][a-z-]*( [a-z][a-z-]*)?' | sed 's/^`//; s/^cckit //' | sort -u)"
n=0
while IFS= read -r v; do
  [ -n "$v" ] || continue
  n=$((n + 1))
  kit_brief_verb_ok "$v" || bad "the skill names an unknown verb: cckit $v"
done <<EOF_V
$verbs
EOF_V
[ "$n" -gt 5 ] && ok "every one of the $n verbs the skill names resolves" || bad "found only $n verbs in the skill"

[ "$fail" -eq 0 ] && echo "ALL OK (advisor)"
exit "$fail"
