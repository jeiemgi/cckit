#!/usr/bin/env bash
# self-install-test.sh — cckit's own `.claude/` must match what cckit intends to install for itself
# (#283). cckit is the kit, so it was never `cckit init`'d against a profile: for its whole history
# `templates/skills/` and `templates/rules/` shipped to every consumer and applied to nothing here.
# `concrete` — the anti-slop catalogue `communication-style.md` mandates for every commit, PR and
# issue body — was the sharpest case: it shipped in PR 247 and no body in this repo records a pass.
#
# This is the guard against that rotting again. It is deliberately NOT "install the whole software
# profile": several templates do not apply to this repo, and each is listed below with the reason.
# The manifest is the point — a template that is neither installed nor skipped fails this test, so a
# new template forces a decision instead of drifting into the silent-partial-install state.
#
# Run:  bash scripts/self-install-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd)"

fail=0
t()   { if [ "$2" = "$3" ]; then :; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has() { case "$2" in *"$3"*) : ;; *) echo "FAIL: $1 -> output lacks '$3'"; fail=1 ;; esac; }
bad() { echo "FAIL: $*"; fail=1; }

# ── the manifest ───────────────────────────────────────────────────────────────────────────────
# INSTALLED_SKILLS / INSTALLED_RULES: "<name> <mode>", one per line.
#   verbatim — the installed file is byte-identical to its template.
#   rendered — byte-identical to the template with init.sh's {{VARS}} substituted from
#              cckit.config.json (init templates those files; the installed copy is its output).
#   sections — the template's KIT-OWNED sections are byte-identical; the rest is this project's own
#              content, because the template instructs the project to fill it in.
INSTALLED_SKILLS='concrete verbatim
karpathy-guidelines verbatim'

INSTALLED_RULES='branch-naming verbatim
communication-style rendered
delegation-brief sections
effort-model rendered
naming-and-ids verbatim'

# The kit-owned sections of delegation-brief.md — the transferable instruction `cckit brief` lifts.
# Project-specific sections ("Project specifics", "Gate commands") are filled in for cckit and are
# NOT compared.
DELEGATION_BRIEF_KIT_SECTIONS='Standing gotchas
Durable prose
Effort flow'

# SKIPPED_*: "<name> :: <reason>". Every skip is a decision on the record, not an omission.
SKIPPED_SKILLS='copywriting :: not declared by any profile cckit uses (content profile only); cckit ships no marketing copy
feature-build-refine :: stack-gated on a @refinedev/* dependency; cckit has no package.json dependencies at all
morning-briefing :: reads .claude/kit.config.json, which this repo does not have, and cckit answers the same question with `cckit status` + skills/kit-status
speckit :: the software profile ships it with defaults.speckit = "off", so init would not install it either
supabase-patterns :: cckit has no Supabase; the only matches for "supabase" in the repo are the kit machinery that scaffolds this skill'

SKIPPED_RULES='design-routing :: routes every design question to .claude/agents/designer/AGENT.md; cckit installs no agents, so the rule would dereference a path that does not exist
knowledge-base :: governs a knowledge/ dir with status/owner/updated frontmatter and a knowledge/INDEX.md manifest; cckit knowledge.dir is docs-site/src/content/docs, Starlight title/description frontmatter, no INDEX.md
mempalace :: memory.enabled is false in cckit.config.json, so init.sh own rules loop skips this rule for this config
plan-next :: not in profiles/software.json; it describes the cckit plan-next verb rather than governing work, and its See-also links point at plan-output-format.md, which cckit does not install
plan-output-format :: mandates that a plan is a file in plans.dir; cckit plans.dir is "" and plans.format is "github" — the parent issue IS the plan (effort-model.md)
react-annotate :: no React app here; scripts/annotate-setup.sh installs this rule per-project when annotation is wired
risk-tiered-review :: not in profiles/software.json; it blesses pr-automerge / pr-labeler, and .github/workflows/ has no such workflow and the repo has no risk:* labels
skill-gaps :: records its anti-repeat state in .claude/kit.config.json under skillPrompts; that file does not exist in this repo
task-management :: duplicates the ground rules in AGENTS.md, and renders claims this repo contradicts — the software profile milestones (Foundation/MVP/Beta/GA) while the repo has zero milestones, and eight roles while only role:tech-lead and role:docs exist'

_names() { printf '%s\n' "$1" | grep . | awk '{print $1}' | sort; }
_skipped_names() { printf '%s\n' "$1" | grep . | sed 's/ :: .*//' | sort; }

# ── 1. every template is either installed or skipped, with a reason ────────────────────────────
# A new template under templates/skills or templates/rules fails here until someone decides.
tpl_skills="$(find templates/skills -mindepth 2 -maxdepth 2 -name SKILL.md -type f 2>/dev/null \
  | while IFS= read -r f; do basename "$(dirname "$f")"; done | sort)"
tpl_rules="$(find templates/rules -maxdepth 1 -type f -name '*.md' 2>/dev/null \
  | while IFS= read -r f; do b="$(basename "$f")"; echo "${b%.md}"; done | sort)"

decided_skills="$( { _names "$INSTALLED_SKILLS"; _skipped_names "$SKIPPED_SKILLS"; } | sort -u)"
decided_rules="$( { _names "$INSTALLED_RULES";  _skipped_names "$SKIPPED_RULES";  } | sort -u)"

t "every skill template is decided (installed or skipped)" \
  "$(comm -23 <(printf '%s\n' "$tpl_skills") <(printf '%s\n' "$decided_skills") | tr '\n' ' ' | sed 's/ *$//')" ""
t "every rule template is decided (installed or skipped)" \
  "$(comm -23 <(printf '%s\n' "$tpl_rules") <(printf '%s\n' "$decided_rules") | tr '\n' ' ' | sed 's/ *$//')" ""
t "no manifest entry names a skill template that is gone" \
  "$(comm -13 <(printf '%s\n' "$tpl_skills") <(printf '%s\n' "$decided_skills") | tr '\n' ' ' | sed 's/ *$//')" ""
t "no manifest entry names a rule template that is gone" \
  "$(comm -13 <(printf '%s\n' "$tpl_rules") <(printf '%s\n' "$decided_rules") | tr '\n' ' ' | sed 's/ *$//')" ""

# Every skip carries a reason after the ` :: ` separator — an unexplained skip recreates the drift.
printf '%s\n' "$SKIPPED_SKILLS" "$SKIPPED_RULES" | grep . | while IFS= read -r line; do
  case "$line" in
    *" :: "?*) : ;;
    *) echo "FAIL: skip without a reason -> '$line'" ;;
  esac
done | grep . && fail=1

# ── 2. what the manifest says is installed is on disk, and nothing else is ─────────────────────
inst_skills="$(find .claude/skills -mindepth 2 -maxdepth 2 -name SKILL.md -type f 2>/dev/null \
  | while IFS= read -r f; do basename "$(dirname "$f")"; done | sort)"
inst_rules="$(find .claude/rules -maxdepth 1 -type f -name '*.md' 2>/dev/null \
  | while IFS= read -r f; do b="$(basename "$f")"; echo "${b%.md}"; done | sort)"

t "installed skills == the manifest" "$(printf '%s\n' "$inst_skills" | tr '\n' ' ')" \
  "$(_names "$INSTALLED_SKILLS" | tr '\n' ' ')"
t "installed rules == the manifest"  "$(printf '%s\n' "$inst_rules" | tr '\n' ' ')" \
  "$(_names "$INSTALLED_RULES" | tr '\n' ' ')"

# ── 3. content: the installed copy has not drifted from its template ───────────────────────────
# `jq` is REQUIRED here, not optional. A drift guard that skips its content comparison when a tool
# is absent passes for the wrong reason — the one failure mode this test exists to prevent. `jq` is a
# Tier-1 dependency (`scripts/doctor.sh`: "git, gh, jq, perl — hard deps, auto-install via brew") and
# CI installs it, so requiring it costs nothing and removes a silent pass. Same for `perl`, which
# performs the substitution.
# A separate flag, not `$fail`: an earlier assertion failing must not be reported as a missing
# dependency, and must not cut the report short — a reviewer needs every finding in one run.
dep_missing=0
for _dep in jq perl; do
  command -v "$_dep" >/dev/null 2>&1 || {
    bad "$_dep is required to compare an installed rule against its template — refusing to pass without it (Tier-1 dep, see scripts/doctor.sh)"
    dep_missing=1
  }
done
if [ "$dep_missing" -ne 0 ]; then
  echo "FAIL: cckit self-install guard cannot compare content without jq + perl — install them and re-run" >&2
  exit 1
fi

# The values init.sh substitutes, read from the config so a config change is caught rather than
# hard-coded here. BASE_BRANCH uses the same precedence as kit-config.sh's KIT_BASE_BRANCH.
CFG_LANG="$(jq -r '.project.language' cckit.config.json)"
CFG_OWNER="$(jq -r '.project.owner' cckit.config.json)"
CFG_NAME="$(jq -r '.project.name' cckit.config.json)"
CFG_BASE="$(jq -r '.github.baseBranch // .github.integrationBranch // .github.flow // "main"' cckit.config.json)"
for _pair in "project.language:$CFG_LANG" "project.owner:$CFG_OWNER" "project.name:$CFG_NAME" "github.baseBranch:$CFG_BASE"; do
  case "${_pair#*:}" in
    ''|null) bad "cckit.config.json has no ${_pair%%:*} — the rendered comparison would compare against an empty string" ;;
  esac
done

# _render <template> — init.sh's substitution step for the vars these templates actually use.
_render() {
  COMMS_LANG="$CFG_LANG" OWNER_NAME="$CFG_OWNER" PROJECT_NAME="$CFG_NAME" BASE_BRANCH="$CFG_BASE" \
    perl -0777 -pe 's/\{\{(\w+)\}\}/ exists $ENV{$1} ? $ENV{$1} : "{{$1}}" /ge' "$1"
}

# _section <file> <heading-regex> — the lines under a matching `## ` heading, next heading exclusive.
_section() {
  awk -v want="$2" '/^##[[:space:]]/ { in_s = ($0 ~ want) ? 1 : 0; next } in_s' "$1"
}

_compare() {  # <name> <template> <installed> <mode>
  local name="$1" tpl="$2" got="$3" mode="$4" s
  [ -f "$got" ] || { bad "$name: $got is missing"; return; }
  [ -f "$tpl" ] || { bad "$name: template $tpl is missing"; return; }
  case "$mode" in
    verbatim)
      cmp -s "$tpl" "$got" || bad "$name: $got differs from $tpl (mode verbatim)"
      # A verbatim install of a templated file would ship a literal {{VAR}} to this repo.
      grep -q '{{' "$got" && bad "$name: $got still contains a {{VAR}} placeholder"
      ;;
    rendered)
      _render "$tpl" | cmp -s - "$got" \
        || bad "$name: $got is not $tpl rendered with cckit.config.json values (mode rendered)"
      grep -q '{{' "$got" && bad "$name: $got still contains a {{VAR}} placeholder"
      ;;
    sections)
      printf '%s\n' "$DELEGATION_BRIEF_KIT_SECTIONS" | grep . | while IFS= read -r s; do
        if [ "$(_section "$tpl" "$s")" != "$(_section "$got" "$s")" ]; then
          echo "FAIL: $name: kit-owned section '$s' differs between $tpl and $got"
        fi
      done | grep . && fail=1
      grep -q '{{' "$got" && bad "$name: $got still contains a {{VAR}} placeholder"
      ;;
    *) bad "$name: unknown manifest mode '$mode'" ;;
  esac
  return 0
}

while IFS=' ' read -r name mode; do
  [ -n "$name" ] || continue
  _compare "skills/$name" "templates/skills/$name/SKILL.md" ".claude/skills/$name/SKILL.md" "$mode"
done <<EOF
$(printf '%s\n' "$INSTALLED_SKILLS" | grep .)
EOF

while IFS=' ' read -r name mode; do
  [ -n "$name" ] || continue
  _compare "rules/$name" "templates/rules/$name.md" ".claude/rules/$name.md" "$mode"
done <<EOF
$(printf '%s\n' "$INSTALLED_RULES" | grep .)
EOF

# ── 4. the mandate chain the issue is about actually connects ──────────────────────────────────
# communication-style mandates the pass · the brief carries it into a delegated agent · the skill
# file is present so the agent can read the catalogue. Break any link and the pass stops firing.
has "communication-style mandates the concrete pass" \
    "$(cat .claude/rules/communication-style.md 2>/dev/null)" 'the `concrete` skill'
has "communication-style points at the brief as the carrier" \
    "$(cat .claude/rules/communication-style.md 2>/dev/null)" 'delegation-brief.md'
t "the concrete skill file an agent has to read is installed" \
  "$([ -f .claude/skills/concrete/SKILL.md ] && echo yes || echo no)" "yes"

prose="$(_section .claude/rules/delegation-brief.md '[Dd]urable prose' 2>/dev/null)"
has "the brief tells a delegated agent to run the concrete pass" "$prose" '`concrete`'
has "the brief names the durable artifacts"     "$prose" "commit message"
has "the brief forbids cutting by length"       "$prose" "never by length"
has "the brief carries O13"                     "$prose" "O13"
has "the brief carries O14"                     "$prose" "O14"
has "the brief lists the untouchable evidence"  "$prose" "Untouchable"

# ── 5. no installed rule names an integration branch this repo does not use ────────────────────
# The review finding on PR 284: `.claude/rules/effort-model.md` told agents to branch from and open
# their PR against `main` while `github.baseBranch` is `develop`. It was byte-identical to its
# template, which is precisely why it went unnoticed — for a template that hard-codes a value the
# project overrides, byte-identical IS the bug. The template is parameterized on {{BASE_BRANCH}}
# now; these assertions fail if either half regresses.
for _pat in '(from main)' '──►  main' '→ main (rich body'; do
  grep -qF -- "$_pat" templates/rules/effort-model.md \
    && bad "templates/rules/effort-model.md hard-codes the integration branch ('$_pat') — use {{BASE_BRANCH}} so each project renders its own"
  grep -qF -- "$_pat" .claude/rules/effort-model.md \
    && bad ".claude/rules/effort-model.md names 'main' as the integration branch; this repo integrates on '$CFG_BASE'"
done
has "installed effort-model branches from this repo's base"   "$(cat .claude/rules/effort-model.md)" "(from $CFG_BASE)"
has "installed effort-model targets this repo's base"          "$(cat .claude/rules/effort-model.md)" "ONE PR ──►  $CFG_BASE"
has "the task-management template parameterizes its base too"  "$(cat templates/rules/task-management.md)" '{{BASE_BRANCH}}'

# ── 6. #218: every installed rule is a template basename ───────────────────────────────────────
# effort_close's kit-sync drift check (_EO_KIT_MANAGED_RE) matches the whole .claude/rules/ dir, so
# it flags project-OWNED rules as kit-managed. That false positive cannot arise here: every file in
# this repo's .claude/rules/ IS a kit template, so the warning is accurate for cckit even before
# #218 narrows the regex. This assertion is what keeps that true.
find .claude/rules -maxdepth 1 -type f -name '*.md' 2>/dev/null | while IFS= read -r f; do
  b="$(basename "$f")"
  [ -f "templates/rules/$b" ] || echo "FAIL: $f has no templates/rules/$b — a project-owned rule here would trip the #218 drift false positive"
done | grep . && fail=1

if [ "$fail" -eq 0 ]; then echo "PASS: cckit self-install matches its manifest"; fi
exit "$fail"
