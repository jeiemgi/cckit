#!/usr/bin/env bash
# shellcheck shell=bash
# init-content-test.sh — what `cckit init` writes for content work (E415).
#
#   - the content profile: the content-work config keys (kinds.content, pr.bodyStyle), the editor
#     agent with the copywriting skill, and NO plain-language rule (its switch is off by default);
#   - `--plain-language on|off`: the rule and `plainLanguage.enabled` follow the switch on any
#     profile, and `--upgrade` keeps a switch the project turned off;
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

# ── software profile: none of it ────────────────────────────────────────────────────────────────
s="$tmp/software"; mkdir -p "$s"
init "$s" --profile software >/dev/null 2>&1; t "software: init exits 0" "$?" "0"
t "software: no content-work keys" "$(cfg "$s" '[has("kinds"), has("pr"), has("plainLanguage"), has("tasks")]')" "[false,false,false,false]"
t "software: no plain-language rule" "$([ -e "$s/.claude/rules/plain-language.md" ] && echo yes || echo no)" "no"
labels="$( cd "$s" && KIT_LABELS_LIST=1 bash "$ROOT/scripts/setup-labels.sh" 2>/dev/null )"
t "software: no content kind label" "$(printf '%s\n' "$labels" | grep -c -E '^kind:(post|campaign|brand|research)	')" "0"

[ "$fail" -eq 0 ] && echo "ALL OK (init content)" || echo "init content: FAILURES"
exit "$fail"
