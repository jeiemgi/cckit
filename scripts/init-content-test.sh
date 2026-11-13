#!/usr/bin/env bash
# shellcheck shell=bash
# init-content-test.sh — what `cckit init` writes for content work (E415).
#
#   - the content profile: the content-work config keys (kinds.content, pr.bodyStyle), the editor
#     agent with the copywriting skill, and NO plain-language rule (its switch is off by default);
#   - `--plain-language on|off`: the rule and `plainLanguage.enabled` follow the switch on any
#     profile, and `--upgrade` keeps a switch the project turned off;
#   - the marketing profile: content plus light tasks as the default list, plain language on, the
#     brand-voice and campaign skills and the effort-model rule; selectable with `--profile
#     marketing` and through the guided setup's `profile` answer; nothing rendered with a leftover
#     placeholder; `--upgrade` keeps a stored tasks.default;
#   - the software profile gains none of the content keys;
#   - the label list (`KIT_LABELS_LIST=1 setup-labels.sh`) of a content project carries the four
#     content kind labels.
# Hermetic: every project is a mktemp directory, gh is a stub that fails, no network.
# Run:  bash scripts/init-content-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
INIT="$ROOT/scripts/init.sh"
fail=0
t()     { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()   { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> output lacks '[$3]'"; fail=1 ;; esac; }
hasnt() { case "$2" in *"$3"*) echo "FAIL: $1 -> output has '[$3]'"; fail=1 ;; *) echo "ok: $1" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "init-content-test: jq absent — skipping (dependency-light gate)"; exit 0; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH"
export KIT_INIT_PREFLIGHT=0   # the doctor preflight needs an authenticated gh; this test has none

# init <dir> <args…> — a scaffold-only run: nothing outside <dir>, no question asked.
init() {
  local d="$1"; shift
  bash "$INIT" --target "$d" --no-github --owner-login o --repo o/r "$@" < /dev/null
}
cfg() { jq -c "$2" "$1/.claude/kit.config.json" 2>/dev/null; }

# ── content profile ─────────────────────────────────────────────────────────────────────────────
c="$tmp/content"; mkdir -p "$c"
out="$(init "$c" --profile content 2>&1)"; t "content: init exits 0" "$?" "0"
t "content: kinds.content is on"          "$(cfg "$c" '.kinds.content')" "true"
t "content: pr.bodyStyle is content"      "$(cfg "$c" '.pr.bodyStyle')" '"content"'
t "content: no plainLanguage key"         "$(cfg "$c" 'has("plainLanguage")')" "false"
t "content: no tasks key"                 "$(cfg "$c" 'has("tasks")')" "false"
# The config is committed by the guided setup: it must not record where the folder lives (#490).
t "content: no project.path key"          "$(cfg "$c" '.project | has("path")')" "false"
cfgtxt="$(cat "$c/.claude/kit.config.json")"
t "content: the config names no absolute path of the project" "$(case "$cfgtxt" in *"$c"*) echo yes ;; *) echo no ;; esac)" "no"
t "content: no plain-language rule"       "$([ -e "$c/.claude/rules/plain-language.md" ] && echo yes || echo no)" "no"
t "content: no effort-model rule"         "$([ -e "$c/.claude/rules/effort-model.md" ] && echo yes || echo no)" "no"
t "content: the editor agent lists copywriting" "$(sed -n '/^skills:/,/^---/p' "$c/.claude/agents/editor/AGENT.md" | grep -c '^  - copywriting$')" "1"
t "content: the copywriting skill is installed" "$([ -f "$c/.claude/skills/copywriting/SKILL.md" ] && echo yes)" "yes"
t "content: roles are unchanged"          "$(cfg "$c" '.roles')" '["PM","Editor","Designer","Researcher"]'

labels="$( cd "$c" && KIT_LABELS_LIST=1 bash "$ROOT/scripts/setup-labels.sh" 2>/dev/null )"
for k in post campaign brand research; do
  t "content: label list has kind:$k" "$(printf '%s\n' "$labels" | grep -c "^kind:$k	")" "1"
done
t "content: label list has role:editor" "$(printf '%s\n' "$labels" | grep -c '^role:editor	')" "1"

dry="$(init "$tmp/content-dry" --profile content --dry-run 2>&1)"
has "content dry run: names the content kinds" "$dry" "Content : kind labels post · campaign · brand · research"
has "content dry run: names the PR text"       "$dry" "PR text : content"
hasnt "content dry run: no plain-language line" "$dry" "Wording :"
t "content dry run: wrote nothing" "$([ -e "$tmp/content-dry" ] && echo yes || echo no)" "no"

# ── the plain-language switch ───────────────────────────────────────────────────────────────────
p="$tmp/plain"; mkdir -p "$p"
init "$p" --profile content --plain-language on >/dev/null 2>&1; t "plain on: init exits 0" "$?" "0"
t "plain on: plainLanguage.enabled is true" "$(cfg "$p" '.plainLanguage.enabled')" "true"
t "plain on: the rule is installed" "$([ -f "$p/.claude/rules/plain-language.md" ] && echo yes)" "yes"
rule="$(cat "$p/.claude/rules/plain-language.md" 2>/dev/null)"
hasnt "plain on: the rule has no unrendered placeholder" "$rule" "{{"
has "plain on: the rule names this project's config" "$rule" '`.claude/kit.config.json`'
has "plain on: the rule says draft, review, approve" "$rule" "Say draft, review, approve."
dry="$(init "$tmp/plain-dry" --profile software --plain-language on --dry-run 2>&1)"
has "plain on: a profile that does not list the rule still plans it" "$dry" ".claude/rules/plain-language.md"
has "plain on: the dry run says so" "$dry" "Wording : plain language"

# --upgrade keeps a switch the project turned off: the rule is not written back.
jq '.plainLanguage.enabled = false | .kitVersion = "0.0.1"' "$p/.claude/kit.config.json" > "$tmp/cfg.new" \
  && mv "$tmp/cfg.new" "$p/.claude/kit.config.json"
rm -f "$p/.claude/rules/plain-language.md"
CLAUDE_PLUGIN_ROOT="$ROOT" bash "$INIT" --upgrade --target "$p" --force >/dev/null 2>&1 < /dev/null; t "upgrade exits 0" "$?" "0"
t "upgrade: a switch turned off stays off"  "$(cfg "$p" '.plainLanguage.enabled')" "false"
t "upgrade: the rule is not written back"   "$([ -e "$p/.claude/rules/plain-language.md" ] && echo yes || echo no)" "no"
# …and re-adds the rule to a project whose switch is on and whose rule file went missing.
jq '.plainLanguage.enabled = true | .kitVersion = "0.0.1"' "$p/.claude/kit.config.json" > "$tmp/cfg.new" \
  && mv "$tmp/cfg.new" "$p/.claude/kit.config.json"
CLAUDE_PLUGIN_ROOT="$ROOT" bash "$INIT" --upgrade --target "$p" --force >/dev/null 2>&1 < /dev/null
t "upgrade: a switch that is on restores a missing rule" "$([ -f "$p/.claude/rules/plain-language.md" ] && echo yes || echo no)" "yes"
# page-design follows tasks.design the same way (#504): absent from a content project, added by an
# upgrade once the project config sets the key.
t "content: no page-design without tasks.design" "$([ -e "$p/.claude/skills/page-design" ] && echo yes || echo no)" "no"
jq '.tasks.design = true | .kitVersion = "0.0.1"' "$p/.claude/kit.config.json" > "$tmp/cfg.new" \
  && mv "$tmp/cfg.new" "$p/.claude/kit.config.json"
CLAUDE_PLUGIN_ROOT="$ROOT" bash "$INIT" --upgrade --target "$p" --force >/dev/null 2>&1 < /dev/null
t "upgrade: tasks.design adds the page-design skill" "$([ -f "$p/.claude/skills/page-design/SKILL.md" ] && echo yes || echo no)" "yes"
t "upgrade: tasks.design is kept" "$(cfg "$p" '.tasks.design')" "true"

# ── marketing profile ───────────────────────────────────────────────────────────────────────────
m="$tmp/marketing"; mkdir -p "$m"
out="$(init "$m" --profile marketing 2>&1)"; t "marketing: init exits 0" "$?" "0"
t "marketing: profile is recorded"        "$(cfg "$m" '.profile')" '"marketing"'
t "marketing: light tasks are the default" "$(cfg "$m" '.tasks.default')" '"light"'
t "marketing: plain language is on"       "$(cfg "$m" '.plainLanguage.enabled')" "true"
t "marketing: kinds.content is on"        "$(cfg "$m" '.kinds.content')" "true"
t "marketing: pr.bodyStyle is content"    "$(cfg "$m" '.pr.bodyStyle')" '"content"'
t "marketing: the four roles"             "$(cfg "$m" '.roles')" '["PM","Editor","Designer","Researcher"]'
for a in pm editor designer researcher; do
  t "marketing: agent $a" "$([ -f "$m/.claude/agents/$a/AGENT.md" ] && echo yes)" "yes"
done
for r in plain-language effort-model task-management review-pages plan-output-format; do
  t "marketing: rule $r" "$([ -f "$m/.claude/rules/$r.md" ] && echo yes)" "yes"
done
for s in copywriting brand-voice campaign page-design concrete; do
  t "marketing: skill $s" "$([ -f "$m/.claude/skills/$s/SKILL.md" ] && echo yes)" "yes"
done
t "marketing: brand-voice ships its template" "$([ -f "$m/.claude/skills/brand-voice/references/voice-template.md" ] && echo yes)" "yes"
t "marketing: page-design ships its references" "$(ls "$m/.claude/skills/page-design/references" 2>/dev/null | tr '\n' ' ')" "design-file-template.md generic-page-patterns.md minimum-rules.md "
has "marketing: the three design integrations are offered" "$out" "cckit add impeccable && cckit add emil-design-eng && cckit add web-design-guidelines && cckit doctor --fix"
for s in impeccable emil-design-eng web-design-guidelines; do
  t "marketing: init installs no third-party skill ($s)" "$([ -e "$m/.claude/skills/$s" ] && echo yes || echo no)" "no"
done
t "marketing: campaign ships its plan template" "$([ -f "$m/.claude/skills/campaign/references/plan-template.md" ] && echo yes)" "yes"
left="$(grep -rlE '\{\{|IF:[A-Z_]+' "$m/CLAUDE.md" "$m/.claude/rules" "$m/.claude/skills" "$m/.claude/agents" 2>/dev/null | sed "s#^$m/##" | tr '\n' ' ')"
t "marketing: nothing rendered with a leftover placeholder" "$left" ""
has "marketing: the campaign skill names this project's plans folder" "$(cat "$m/.claude/skills/campaign/SKILL.md")" '`docs/plans/marketing-pm-campaign-<name>.md`'
has "marketing: CLAUDE.md opens the task section with light tasks" "$(cat "$m/CLAUDE.md")" "## Work is tracked as light tasks"
has "marketing: CLAUDE.md names the finish verb, with --all for new files" "$(cat "$m/CLAUDE.md")" 'cckit task finish <id> "<summary>" --all'
has "marketing: task-management says the default list is light" "$(cat "$m/.claude/rules/task-management.md")" "default list is light tasks"
has "marketing: the closing summary says so" "$out" "Tasks   : light tasks are the default list"
has "marketing: the closing summary names the first command" "$out" 'Add the first task:  cckit task new "<title>"'
# #487: the next steps of a light-task project do not send the reader to the label scripts.
hasnt "marketing: no label or milestone script in the next steps" "$out" "setup-labels.sh"
has "software keeps them" "$(init "$tmp/sw-steps" --profile software 2>&1)" "./scripts/setup-labels.sh && ./scripts/setup-milestones.sh"
# #487: the instruction file. A folded `description: >` is read; the base branch is the project's;
# the task section does not contradict the light-task section; the credit names this repository.
md="$(cat "$m/CLAUDE.md")"
has   "marketing CLAUDE.md: brand-voice has its description" "$md" '| `brand-voice` | Record the brand'
has   "marketing CLAUDE.md: campaign has its description" "$md" '| `campaign` | Turn one marketing goal'
hasnt "marketing CLAUDE.md: no bare > in the skills table" "$md" '| > |'
has   "marketing CLAUDE.md: the task files are the source of truth" "$md" '**Source of truth:** the task files under `tasks/`'
hasnt "marketing CLAUDE.md: does not call GitHub issues the source of truth" "$md" "**Source of truth:** GitHub issues"
hasnt "marketing CLAUDE.md: does not forbid task lists in markdown" "$md" "maintain task lists in markdown"
has   "marketing CLAUDE.md: credits the kit's repository" "$md" "[cckit](https://github.com/jeiemgi/cckit)"
has   "content CLAUDE.md: GitHub issues stay the source of truth" "$(cat "$c/CLAUDE.md")" "**Source of truth:** GitHub issues"
bb="$tmp/base"; mkdir -p "$bb"
KIT_BASE_BRANCH=develop init "$bb" --profile marketing >/dev/null 2>&1
has   "CLAUDE.md names the project's base branch" "$(cat "$bb/CLAUDE.md")" 'lands on `develop` through a Pull Request'
hasnt "CLAUDE.md does not say main when the base is develop" "$(cat "$bb/CLAUDE.md")" '`main`'
t "no template names the old repository" "$(grep -rl 'tuempresadigital' "$ROOT/templates" "$ROOT/kit.config.schema.json" 2>/dev/null | wc -l | tr -d ' ')" "0"
# #487: every state `cckit task list` can print has a plain wording in the rule.
rule="$(cat "$m/.claude/rules/plain-language.md")"
for st in draft todo shared doing review 'done' dropped; do
  has "plain-language: names the task state $st" "$rule" "\`$st\`"
done
has "plain-language: says what the draft state is" "$rule" "nobody has started the task and it is not on the shared list"
hasnt "content: CLAUDE.md has no light-task section" "$(cat "$c/CLAUDE.md")" "Work is tracked as light tasks"
hasnt "content: task-management does not mention light tasks" "$(cat "$c/.claude/rules/task-management.md")" "light tasks"
t "marketing: the installed cckit reads the default" "$(cd "$m" && "$ROOT/bin/cckit" task default)" "light"

dry="$(init "$tmp/marketing-dry" --profile marketing --dry-run 2>&1)"
for line in "Profile : marketing" "Tasks   : light tasks are the default list" "Wording : plain language" \
            ".claude/rules/plain-language.md" ".claude/rules/effort-model.md" \
            ".claude/skills/brand-voice/SKILL.md" ".claude/skills/campaign/SKILL.md" ".claude/skills/copywriting/SKILL.md" \
            ".claude/agents/pm/AGENT.md" ".claude/agents/editor/AGENT.md" ".claude/agents/designer/AGENT.md" ".claude/agents/researcher/AGENT.md"; do
  has "marketing dry run: $line" "$dry" "$line"
done
t "marketing dry run: wrote nothing" "$([ -e "$tmp/marketing-dry" ] && echo yes || echo no)" "no"

# --plain-language off wins over the profile default.
mo="$tmp/marketing-off"; mkdir -p "$mo"
init "$mo" --profile marketing --plain-language off >/dev/null 2>&1
t "marketing --plain-language off: no key" "$(cfg "$mo" 'has("plainLanguage")')" "false"
t "marketing --plain-language off: no rule" "$([ -e "$mo/.claude/rules/plain-language.md" ] && echo yes || echo no)" "no"
t "marketing --plain-language off: light tasks stay the default" "$(cfg "$mo" '.tasks.default')" '"light"'

# The guided setup: the `profile` answer selects it, with no --profile flag.
g="$tmp/guided"; mkdir -p "$g"; echo "notes" > "$g/notes.md"
echo '{"profile":"marketing"}' > "$tmp/answers.json"
gout="$(bash "$INIT" "$g" --answers "$tmp/answers.json" --no-github --owner-login o --repo o/r 2>&1 < /dev/null)"; t "guided: init exits 0" "$?" "0"
has "guided: the profile question was answered from the file" "$gout" "What kind of work is this project? -> marketing (answers file)"
t "guided: the marketing profile was installed" "$(cfg "$g" '[.profile, .tasks.default, .plainLanguage.enabled]')" '["marketing","light",true]'
bad="$(bash "$INIT" --target "$tmp/nope" --no-github --profile nope 2>&1 < /dev/null)"; t "an unknown profile is refused" "$?" "1"
has "the refusal lists marketing" "$bad" "marketing"

# --upgrade keeps the stored default list: a project that moved to issues is not moved back.
jq '.tasks.default = "issues" | .kitVersion = "0.0.1"' "$m/.claude/kit.config.json" > "$tmp/cfg.new" \
  && mv "$tmp/cfg.new" "$m/.claude/kit.config.json"
CLAUDE_PLUGIN_ROOT="$ROOT" bash "$INIT" --upgrade --target "$m" --force >/dev/null 2>&1 < /dev/null; t "marketing upgrade exits 0" "$?" "0"
t "upgrade: a stored tasks.default is kept" "$(cfg "$m" '.tasks.default')" '"issues"'
t "upgrade: plain language stays on"        "$(cfg "$m" '.plainLanguage.enabled')" "true"

# The data form: marketing has the keys every profile has, and is content plus named additions.
keys() { jq -c 'keys' "$ROOT/profiles/$1.json"; }
t "marketing has the same top-level keys as content" "$(keys marketing)" "$(keys content)"
t "marketing agents == content agents" "$(jq -c .agents "$ROOT/profiles/marketing.json")" "$(jq -c .agents "$ROOT/profiles/content.json")"
t "marketing skills = content + brand-voice + campaign + page-design" \
  "$(jq -c '.skills - ["brand-voice","campaign","page-design"]' "$ROOT/profiles/marketing.json")" "$(jq -c '.skills' "$ROOT/profiles/content.json")"
t "marketing rules = content + plain-language + effort-model" \
  "$(jq -c '.rules - ["plain-language","effort-model"]' "$ROOT/profiles/marketing.json")" "$(jq -c '.rules' "$ROOT/profiles/content.json")"
for f in "$ROOT"/profiles/*.json; do
  n="$(basename "$f" .json)"
  miss=""
  for s in $(jq -r '.skills[]' "$f"); do [ -f "$ROOT/templates/skills/$s/SKILL.md" ] || miss="$miss skill:$s"; done
  for r in $(jq -r '.rules[]' "$f");  do [ -f "$ROOT/templates/rules/$r.md" ] || miss="$miss rule:$r"; done
  for a in $(jq -r '.agents[]' "$f"); do [ -f "$ROOT/templates/agents/$a.md" ] || miss="$miss agent:$a"; done
  t "profile $n: every skill, rule and agent it lists has a template" "$miss" ""
done

# ── software profile: none of it ────────────────────────────────────────────────────────────────
s="$tmp/software"; mkdir -p "$s"
init "$s" --profile software >/dev/null 2>&1; t "software: init exits 0" "$?" "0"
t "software: no content-work keys" "$(cfg "$s" '[has("kinds"), has("pr"), has("plainLanguage"), has("tasks")]')" "[false,false,false,false]"
t "software: no plain-language rule" "$([ -e "$s/.claude/rules/plain-language.md" ] && echo yes || echo no)" "no"
labels="$( cd "$s" && KIT_LABELS_LIST=1 bash "$ROOT/scripts/setup-labels.sh" 2>/dev/null )"
t "software: no content kind label" "$(printf '%s\n' "$labels" | grep -c -E '^kind:(post|campaign|brand|research)	')" "0"

[ "$fail" -eq 0 ] && echo "ALL OK (init content)" || echo "init content: FAILURES"
exit "$fail"
