#!/usr/bin/env bash
# agent-skills-lint-test.sh — behavioral test for the agent `skills:` resolver.
# Runs the lint against the real tree (it must be green), then against throwaway trees in a temp
# ROOT to assert each way an entry resolves and the one way it does not.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LINT="$HERE/agent-skills-lint.sh"
fails=0
pass() { echo "ok $1"; }
fail() { echo "FAIL $1"; fails=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A fresh temp ROOT holding the lint, one kit skill, one template skill and a one-name allowlist.
new_root() {
  rm -rf "$TMP/r"
  mkdir -p "$TMP/r/scripts" "$TMP/r/templates/agents" \
           "$TMP/r/skills/kit-task-sync" "$TMP/r/templates/skills/morning-briefing"
  cp "$LINT" "$TMP/r/scripts/"
  : > "$TMP/r/skills/kit-task-sync/SKILL.md"
  : > "$TMP/r/templates/skills/morning-briefing/SKILL.md"
  printf '# third-party\ndeep-research\n' > "$TMP/r/scripts/agent-skills-external.txt"
}

# mk_agent <name> <frontmatter skills block...> — each remaining arg is one frontmatter line.
mk_agent() {
  local name="$1"; shift
  {
    echo "---"
    echo "name: $name"
    for l in "$@"; do printf '%s\n' "$l"; done
    echo "---"
    echo
    echo "Body mentions \`task-sync\` in prose and a list:"
    echo "  - not-a-skill"
  } > "$TMP/r/templates/agents/$name.md"
}

# Capture rather than pipe: `run | grep -q` lets grep exit early and SIGPIPE the lint, which
# `pipefail` then reports as a failure even on a match.
run_out=""; run_rc=0
capture() { run_out="$( cd "$TMP/r" && bash scripts/agent-skills-lint.sh 2>&1 )"; run_rc=$?; }

# --- 1. the real tree is green ----------------------------------------------
real_out="$(bash "$LINT" 2>&1)"; real_rc=$?
[ "$real_rc" -eq 0 ] && pass "real templates/agents resolve" \
                     || fail "real templates/agents resolve (rc=$real_rc: $real_out)"

# --- 2. every resolving form passes -----------------------------------------
new_root
mk_agent good "skills:" \
  "  - kit-task-sync # shipped under skills/" \
  "  - morning-briefing" \
  "  - deep-research" \
  "  - agent-skills:context7" \
  "tools: [Bash]"
mk_agent empty "skills: []"
mk_agent inline "skills: [kit-task-sync, chrome-devtools-mcp:a11y-debugging]"
mk_agent none "tools: [Read]"
capture
[ "$run_rc" -eq 0 ] && pass "kit, template, allowlisted and plugin:skill entries resolve" \
                    || fail "kit, template, allowlisted and plugin:skill entries resolve ($run_out)"

# --- 3. a bare name nothing ships fails, naming file + entry ----------------
new_root
mk_agent pm "skills:" "  - task-sync" "  - morning-briefing"
capture
if [ "$run_rc" -eq 0 ]; then
  fail "dead bare skill is rejected (exited 0)"
elif grep -q "templates/agents/pm.md:4: task-sync" <<<"$run_out"; then
  pass "dead bare skill is rejected with file:line + entry"
else
  fail "dead bare skill is rejected (wrong message: $run_out)"
fi
grep -q "morning-briefing" <<<"$run_out" \
  && fail "a resolving entry is not reported ($run_out)" \
  || pass "a resolving entry is not reported"

# --- 4. the inline list form is checked too ---------------------------------
new_root
mk_agent inl "skills: [kit-task-sync, task-new]"
capture
if [ "$run_rc" -ne 0 ] && grep -q "templates/agents/inl.md:3: task-new" <<<"$run_out"; then
  pass "dead entry in an inline list is rejected"
else
  fail "dead entry in an inline list is rejected (rc=$run_rc: $run_out)"
fi

# --- 5. the regression this lint exists for: pm.md with the pre-rename name --
# Real agents + real skill names + real allowlist, with `task-sync` put back into pm.md.
new_root
cp "$REPO"/templates/agents/*.md "$TMP/r/templates/agents/"
cp "$REPO/scripts/agent-skills-external.txt" "$TMP/r/scripts/"
for d in "$REPO"/skills/*/ "$REPO"/templates/skills/*/; do
  [ -f "$d/SKILL.md" ] || continue
  case "$d" in
    "$REPO"/skills/*) mkdir -p "$TMP/r/skills/$(basename "$d")"; : > "$TMP/r/skills/$(basename "$d")/SKILL.md" ;;
    *) mkdir -p "$TMP/r/templates/skills/$(basename "$d")"; : > "$TMP/r/templates/skills/$(basename "$d")/SKILL.md" ;;
  esac
done
capture
[ "$run_rc" -eq 0 ] && pass "copied real tree is green before the mutation" \
                    || fail "copied real tree is green before the mutation ($run_out)"
sed 's/^  - kit-task-sync.*$/  - task-sync/' "$REPO/templates/agents/pm.md" > "$TMP/r/templates/agents/pm.md"
capture
if [ "$run_rc" -ne 0 ] && grep -qE "templates/agents/pm\.md:[0-9]+: task-sync" <<<"$run_out"; then
  pass "re-adding task-sync to pm.md fails the lint"
else
  fail "re-adding task-sync to pm.md fails the lint (rc=$run_rc: $run_out)"
fi

# --- 6. an allowlisted name the kit now ships is flagged --------------------
new_root
mkdir -p "$TMP/r/skills/deep-research"; : > "$TMP/r/skills/deep-research/SKILL.md"
mk_agent r "skills:" "  - deep-research"
capture
if [ "$run_rc" -ne 0 ] && grep -q "agent-skills-external.txt: deep-research" <<<"$run_out"; then
  pass "allowlisted name that the kit ships is rejected"
else
  fail "allowlisted name that the kit ships is rejected (rc=$run_rc: $run_out)"
fi

# --- 7. no templates/agents: self-disables ----------------------------------
new_root; rm -rf "$TMP/r/templates/agents"
capture
[ "$run_rc" -eq 0 ] && pass "no templates/agents exits 0" || fail "no templates/agents exits 0 ($run_out)"

exit "$fails"
