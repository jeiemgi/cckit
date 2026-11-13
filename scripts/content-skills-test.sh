#!/usr/bin/env bash
# shellcheck shell=bash
# content-skills-test.sh — the content skills cckit scaffolds follow the skill conventions (E415).
#
# For each skill in CONTENT_SKILLS (templates/skills/<name>/SKILL.md):
#   - `name:` equals the directory name;
#   - `when_to_use` quotes conversational phrasings and carries an explicit SKIP clause;
#   - description + when_to_use fit the 500-byte listing budget. The template is not under
#     skill-frontmatter-lint.sh here, but its scaffolded copy is in every project that installs it;
#   - the only `{{…}}` in the file are variables init exports (PLANS_DIR, PROJECT_SLUG) — init
#     renders SKILL.md through the template engine, so any other brace pair would be left in the
#     project as a broken placeholder;
#   - every `cckit <verb>` it tells the agent to run is a verb `cckit commands` lists.
# Plus the contract between the skills: the headings brand-voice writes are the ones its template
# has and the ones copywriting and campaign are told to read.
# Offline: no network, no gh, nothing written outside mktemp.
# Run:  bash scripts/content-skills-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> lacks '[$3]'"; fail=1 ;; esac; }

CONTENT_SKILLS="brand-voice campaign"

# _field <file> <key> — a frontmatter scalar, folded (`key: >`) or inline, on one line.
_field() {
  awk -v k="$2" '
    NR == 1 && $0 == "---" { infm = 1; next }
    infm && $0 == "---" { exit }
    !infm { next }
    $0 ~ "^" k ":" { on = 1; sub("^" k ":[ ]*>?[ ]*", ""); if (length($0)) printf "%s ", $0; next }
    on && /^[a-zA-Z_]+:/ { on = 0 }
    on { sub(/^[ ]+/, ""); printf "%s ", $0 }
  ' "$1" | sed 's/ *$//'
}

verbs="$(CCKIT_OUTPUT=human "$ROOT/bin/cckit" commands 2>/dev/null)"
has "cckit commands lists the task verb" " $verbs " " task "

for s in $CONTENT_SKILLS; do
  f="$ROOT/templates/skills/$s/SKILL.md"
  t "$s: the template exists" "$([ -f "$f" ] && echo yes)" "yes"
  [ -f "$f" ] || continue
  t "$s: name matches its directory" "$(_field "$f" name)" "$s"
  desc="$(_field "$f" description)"; when="$(_field "$f" when_to_use)"
  t "$s: has a description" "$([ -n "$desc" ] && echo yes)" "yes"
  has "$s: when_to_use carries a SKIP clause" "$when" "SKIP"
  t "$s: when_to_use quotes at least three phrasings" "$([ "$(printf '%s' "$when" | grep -o '"[^"]*"' | grep -c .)" -ge 3 ] && echo yes)" "yes"
  bytes="$(printf '%s%s' "$desc" "$when" | LC_ALL=C wc -c | tr -d ' ')"
  t "$s: description + when_to_use within 500 bytes ($bytes)" "$([ "$bytes" -le 500 ] && echo yes)" "yes"
  t "$s: no template variable init does not export" \
    "$(sed -e 's/{{PLANS_DIR}}//g' -e 's/{{PROJECT_SLUG}}//g' "$f" | grep -c '{{' | tr -d ' ')" "0"
  # every `cckit <verb>` named in the skill is a real verb
  used="$(grep -oE 'cckit [a-z][a-z-]*' "$f" | awk '{print $2}' | sort -u)"
  for v in $used; do
    case " $verbs " in *" $v "*) echo "ok: $s: cckit $v is a verb" ;; *) echo "FAIL: $s names 'cckit $v', which cckit commands does not list"; fail=1 ;; esac
  done
done

# ── brand-voice ↔ its template ↔ copywriting ────────────────────────────────────────────────────
bv="$ROOT/templates/skills/brand-voice/SKILL.md"
tpl="$ROOT/templates/skills/brand-voice/references/voice-template.md"
cw="$ROOT/templates/skills/copywriting/SKILL.md"
t "brand-voice: ships its template" "$([ -f "$tpl" ] && echo yes)" "yes"
has "brand-voice: names the file it writes" "$(cat "$bv")" '`brand/voice.md`'
has "brand-voice: points at its template" "$(cat "$bv")" 'references/voice-template.md'
for h in "Audience" "Voice" "Key messages" "Banned phrasings" "Words we use" "Examples" "Changes"; do
  t "voice template has ## $h" "$(grep -c "^## $h\$" "$tpl" | tr -d ' ')" "1"
done
has "copywriting reads brand/voice.md" "$(cat "$cw")" 'If `brand/voice.md` exists'
for h in "Voice" "Key messages" "Banned phrasings" "Words we use"; do
  has "copywriting reads the section ## $h" "$(cat "$cw")" "\`## $h\`"
done
# The task verbs the Change flow names take the flags it gives them.
help="$("$ROOT/bin/cckit" task --help 2>&1)"
has "cckit task new takes --kind" "$help" "cckit task new [--priority p0|p1|p2|p3] [--kind K]"
has "cckit task finish takes --all" "$help" 'cckit task finish [<id>] "<summary>" [--all]'

# ── campaign ↔ its template ↔ the verbs it names ────────────────────────────────────────────────
cp="$ROOT/templates/skills/campaign/SKILL.md"
ptpl="$ROOT/templates/skills/campaign/references/plan-template.md"
t "campaign: ships its plan template" "$([ -f "$ptpl" ] && echo yes)" "yes"
for h in "Goal" "Audience" "Message" "Channels" "Pieces" "Timeline" "Measure" "Deliverables" "Result"; do
  t "plan template has ## $h" "$(grep -c "^## $h\$" "$ptpl" | tr -d ' ')" "1"
done
has "campaign reads brand/voice.md" "$(cat "$cp")" '`brand/voice.md`'
has "campaign asks which list the project uses" "$(cat "$cp")" 'cckit task default'
has "campaign has the light lane" "$(cat "$cp")" 'cckit task new --kind campaign "Campaign plan: <name>"'
has "campaign has the effort lane" "$(cat "$cp")" 'cckit effort new "<name>"'
has "campaign waits for approval" "$(cat "$cp")" "Record nothing"
# Every `cckit task finish` the skill names carries --all: a piece's draft is a new file, and
# without --all the review opens without it.
t "campaign: no task finish line without --all" "$(grep -c 'cckit task finish' "$cp")" "$(grep -c 'cckit task finish <id> "[^"]*" --all' "$cp")"
has "cckit task has the default verb" "$help" "cckit task default"
# The effort lane's flags are ones `effort new` parses.
eo="$(cat "$ROOT/scripts/lib/effort-ops.sh")"
for fl in --kind --goal --scope --verification; do
  has "effort new parses $fl" "$eo" "      $fl)"
done
# Every kind the skills tell the agent to pass is a kind `--kind` accepts.
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/kinds.sh"
for k in post campaign brand research; do
  kit_kind_label_valid "$k"; t "kind $k is accepted" "$?" "0"
done

[ "$fail" -eq 0 ] && echo "ALL OK (content skills)" || echo "content skills: FAILURES"
exit "$fail"
