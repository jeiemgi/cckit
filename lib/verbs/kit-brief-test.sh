#!/bin/sh
# kit-brief-test.sh — self-test for kit-brief.sh, the delegation-brief generator (Effort 220 · #221).
# Network-free and repo-free: the text parsers run against fixture strings, and the git-dependent
# lookups (seed freshness, worktree association, basename resolution) run against a throwaway repo
# with a fabricated `origin/` ref — so nothing here depends on what this checkout looks like today.
# Every assertion runs under bash AND zsh, because the verb is sourced by a dispatcher that may be
# either and the parsers use parameter expansion that the two shells disagree about.
# Run:  bash lib/verbs/kit-brief-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

if [ -n "${KB_TEST_INNER:-}" ]; then
  fail=0
  eq()  { if [ "$2" = "$3" ]; then :; else echo "FAIL($KB_TEST_INNER): $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
  has() { case "$2" in *"$3"*) : ;; *) echo "FAIL($KB_TEST_INNER): $1 -> '$2' lacks '$3'"; fail=1 ;; esac; }
  no()  { case "$2" in *"$3"*) echo "FAIL($KB_TEST_INNER): $1 -> '$2' should not contain '$3'"; fail=1 ;; *) : ;; esac; }

  # shellcheck source=/dev/null
  . "$dir/kit-brief.sh"

  # ── kit_brief_section ────────────────────────────────────────────────────────────────────────
  body='## Goal

why this exists

## For agents

build order matters

- `scripts/lib/a.sh`

## Verification

green'
  sec="$(printf '%s\n' "$body" | kit_brief_section "For agents")"
  has "section body"            "$sec" "build order matters"
  has "section keeps its list"  "$sec" 'scripts/lib/a.sh'
  no  "section stops at the next heading" "$sec" "green"
  no  "section excludes its own heading"  "$sec" "## For agents"
  # the trim runs at both ends, so a lifted section drops in without a stray gap
  eq  "section trims leading blank"  "$(printf '%s\n' "$sec" | sed -n 1p)" "build order matters"
  eq  "section trims trailing blank" "$(printf '%s\n' "$sec" | tail -1)" '- `scripts/lib/a.sh`'
  eq  "absent section is empty"      "$(printf '%s\n' "$body" | kit_brief_section "Nope")" ""
  # heading match is case-insensitive but not a prefix match
  has "section matches case-insensitively" \
      "$(printf '%s\n' "$body" | kit_brief_section "for agents")" "build order matters"

  # ── kit_brief_files ──────────────────────────────────────────────────────────────────────────
  text='Edit `lib/verbs/captain.sh` and captain-test.sh, plus docs/ and README.md.
Files: lib/verbs/kit-brief.sh, bin/cckit, docs-site/src/content/docs/cli-reference.mdx
See https://example.com/thing.md for context. Ignore prose words like errors: and mixed.'
  f="$(printf '%s\n' "$text" | kit_brief_files)"
  has "path from backticks"     "$f" "lib/verbs/captain.sh"
  has "bare basename token"     "$f" "captain-test.sh"
  has "directory token"         "$f" "docs/"
  has "path from a Files: line" "$f" "lib/verbs/kit-brief.sh"
  has "mdx path"                "$f" "docs-site/src/content/docs/cli-reference.mdx"
  has "extensionless is kept when it is a real path token" "$f" "bin/cckit"
  no  "URL is not a path"       "$f" "https"
  no  "prose word is not a path" "$f" "mixed"
  eq  "list is deduped + sorted" "$(printf '%s\n' "$f" | sort -u | wc -l | tr -d ' ')" \
                                 "$(printf '%s\n' "$f" | wc -l | tr -d ' ')"

  # ── kit_brief_sourced ────────────────────────────────────────────────────────────────────────
  tmp="$(mktemp -d)"
  cat > "$tmp/consumer.sh" <<'EOF'
#!/usr/bin/env bash
source "$LIB/core/kit-config.sh" && load_kit_config
. "$LIB/forge/gh-project.sh"
source "${CLAUDE_PLUGIN_ROOT}/lib/verbs/kit-lib.sh"
echo "not a source line: lib/decoy.sh"
EOF
  srcd="$(kit_brief_sourced "$tmp/consumer.sh")"
  has "finds a source'd helper"        "$srcd" "kit-config.sh"
  has "finds a dot-source'd helper"    "$srcd" "gh-project.sh"
  has "finds a plugin-root helper"     "$srcd" "kit-lib.sh"
  no  "ignores a non-source mention"   "$srcd" "decoy.sh"
  eq  "missing file is skipped, not fatal" "$(kit_brief_sourced "$tmp/nope.sh")" ""

  # ── kit_brief_gotchas ────────────────────────────────────────────────────────────────────────
  mkdir -p "$tmp/proj/.claude/rules" "$tmp/proj/kit/templates/rules"
  cat > "$tmp/proj/kit/templates/rules/delegation-brief.md" <<'EOF'
# Delegation brief
## Standing gotchas
- template gotcha
## Gate commands
- not a gotcha
EOF
  eq "falls back to the kit template" \
     "$(kit_brief_gotchas "$tmp/proj" | sed -n 1p)" "- template gotcha"
  cat > "$tmp/proj/.claude/rules/delegation-brief.md" <<'EOF'
# Delegation brief
## Standing gotchas

- project gotcha

## Gate commands
- not a gotcha
EOF
  g="$(kit_brief_gotchas "$tmp/proj")"
  eq  "project rule wins over the template" "$(printf '%s\n' "$g" | sed -n 1p)" "- project gotcha"
  no  "gotchas stop at the next heading"    "$g" "not a gotcha"
  eq  "no rule file yields nothing"         "$(kit_brief_gotchas "$tmp/empty-root")" ""

  # ── kit_brief_durable_prose (#283) ───────────────────────────────────────────────────────────
  # The concrete mandate has to reach the GENERATED brief: an agent applies a skill only when it is
  # told to, so a mandate that lives only in communication-style.md never fires.
  mkdir -p "$tmp/dp/.claude/rules"
  cat > "$tmp/dp/.claude/rules/delegation-brief.md" <<'EOF'
# Delegation brief
## Standing gotchas
- a gotcha
## Durable prose — the concrete pass
- apply the `concrete` catalogue before writing
- O13 unverifiable claim / O14 undecided decision
## Gate commands
- not durable prose
EOF
  dp="$(kit_brief_durable_prose "$tmp/dp")"
  has "durable prose names the skill"    "$dp" 'concrete'
  has "durable prose carries O13/O14"    "$dp" "O13"
  no  "durable prose stops at the next heading" "$dp" "not durable prose"
  no  "durable prose is not the gotchas block"  "$dp" "a gotcha"
  eq  "absent durable-prose section is empty" \
      "$(kit_brief_durable_prose "$tmp/proj")" ""
  eq  "no rule file yields no durable prose" "$(kit_brief_durable_prose "$tmp/empty-root")" ""

  # The kit's OWN template must carry the section, or every project scaffolds a brief without it.
  ktpl="$dir/../../kit/templates/rules/delegation-brief.md"
  if [ -f "$ktpl" ]; then
    tpl_prose="$(awk '/^##[[:space:]]/ { in_s = ($0 ~ /[Dd]urable prose/) ? 1 : 0; next } in_s' "$ktpl")"
    has "kit template has a Durable prose section" "$tpl_prose" 'concrete'
    has "kit template names O13"                   "$tpl_prose" "O13"
    has "kit template names O14"                   "$tpl_prose" "O14"
    has "kit template forbids cutting by length"   "$tpl_prose" "never by length"
    has "kit template cross-refs communication-style" "$tpl_prose" "communication-style.md"
  else
    echo "  (kit/templates/rules/delegation-brief.md absent — skipping the kit-template assertions)"
  fi

  # ── git-dependent lookups, against a throwaway repo ──────────────────────────────────────────
  if command -v git >/dev/null 2>&1; then
    repo="$tmp/r"; mkdir -p "$repo"
    ( cd "$repo" && git init -q . \
      && git config user.email t@t && git config user.name t \
      && mkdir -p scripts/lib && echo base > scripts/lib/only-here.sh \
      && echo dup > scripts/lib/dup.sh && mkdir -p other && echo dup > other/dup.sh \
      && git add -A && git commit -q -m init ) >/dev/null 2>&1

    # kit_brief_resolve — a bare basename must resolve to its tracked path, not read as "new"
    r="$(cd "$repo" && kit_brief_resolve "only-here.sh" "$repo")"
    eq "bare basename resolves to its path" "${r%%	*}" "scripts/lib/only-here.sh"
    eq "resolved basename is marked here"   "${r##*	}" "here"
    r="$(cd "$repo" && kit_brief_resolve "scripts/lib/only-here.sh" "$repo")"
    eq "literal existing path is here"      "${r##*	}" "here"
    r="$(cd "$repo" && kit_brief_resolve "scripts/lib/not-yet.sh" "$repo")"
    eq "literal missing path is new"        "${r##*	}" "new"
    r="$(cd "$repo" && kit_brief_resolve "dup.sh" "$repo")"
    case "${r##*	}" in
      ambiguous*) : ;;
      *) echo "FAIL($KB_TEST_INNER): a basename matching two tracked files must be ambiguous -> '$r'"; fail=1 ;;
    esac

    # kit_brief_seed — fresh vs stale vs unknown, against a fabricated origin ref
    ( cd "$repo" \
      && git branch -q feat/1-fresh \
      && git update-ref refs/remotes/origin/trunk "$(git rev-parse HEAD)" \
      && echo more >> scripts/lib/only-here.sh && git add -A && git commit -q -m second \
      && git update-ref refs/remotes/origin/trunk "$(git rev-parse HEAD)" ) >/dev/null 2>&1
    # feat/1-fresh was cut BEFORE the second commit, so origin/trunk is no longer an ancestor of it
    eq "a branch behind origin is STALE" \
       "$(cd "$repo" && kit_brief_seed feat/1-fresh trunk | cut -d' ' -f1)" "stale"
    ( cd "$repo" && git branch -q feat/2-current ) >/dev/null 2>&1
    eq "a branch cut from the tip is FRESH" \
       "$(cd "$repo" && kit_brief_seed feat/2-current trunk | cut -d' ' -f1)" "fresh"
    eq "an unknown base is reported, not guessed" \
       "$(cd "$repo" && kit_brief_seed feat/2-current no-such-base)" "unknown"
    eq "an absent branch is reported, not guessed" \
       "$(cd "$repo" && kit_brief_seed no-such-branch trunk)" "unknown"
    # the seed check must name a real tip so a reader can verify it
    has "fresh names the base tip" \
        "$(cd "$repo" && kit_brief_seed feat/2-current trunk)" \
        "$(cd "$repo" && git rev-parse --short origin/trunk)"

    # kit_brief_worktree — the association comes from wt_issue_number, the same rule gc uses
    if [ -f "$dir/../core/worktree-issue.sh" ]; then
      # shellcheck source=/dev/null
      . "$dir/../core/worktree-issue.sh"
      ( cd "$repo" && git worktree add -q "$tmp/wt-7" -b task/7-thing ) >/dev/null 2>&1
      w="$(cd "$repo" && kit_brief_worktree 7)"
      has "finds the worktree for an issue" "$w" "task/7-thing"
      eq  "an issue with no worktree yields nothing" "$(cd "$repo" && kit_brief_worktree 999)" ""
    else
      echo "  (worktree-issue.sh absent — skipping the worktree-association assertions)"
    fi
  else
    echo "  (git absent — skipping the git-dependent assertions)"
  fi

  # ── _kb_rows + the helpers-table cap ─────────────────────────────────────────────────────────
  # _kb_rows needs the catalog from kit-lib.sh; skip cleanly where that helper is absent.
  if [ -f "$dir/kit-lib.sh" ]; then
    # shellcheck source=/dev/null
    . "$dir/kit-lib.sh"
    libfix="$tmp/lib"; mkdir -p "$libfix"
    i=1
    while [ "$i" -le 4 ]; do
      cat > "$libfix/h$i.sh" <<EOF
#!/usr/bin/env bash
# h$i.sh — helper number $i.
# errors: pure
pub_$i() { :; }
EOF
      i=$((i + 1))
    done
    rows="$(_kb_rows "$libfix" "$(printf 'h2.sh
h4.sh
')")"
    eq  "_kb_rows returns one row per requested helper" \
        "$(printf '%s\n' "$rows" | grep -c . | tr -d ' ')" "2"
    has "_kb_rows renders the purpose"   "$rows" "helper number 2"
    has "_kb_rows renders the contract"  "$rows" "pure"
    no  "_kb_rows omits helpers nobody asked for" "$rows" "h1.sh"
    eq  "_kb_rows with an empty set is empty" "$(_kb_rows "$libfix" "")" ""
    eq  "_kb_rows ignores a name that is not in the catalog" \
        "$(_kb_rows "$libfix" "nope.sh")" ""
  else
    echo "  (kit-lib.sh absent — skipping the helpers-table assertions)"
  fi

  # ── the helpers-table overflow count (#230 review) ───────────────────────────────────────────
  # `grep -c` on empty input PRINTS 0 and exits 1, so a `|| echo 0` fallback yields "0\n0" and the
  # arithmetic that consumes it dies — the same bug class as the #142 board-counter regression.
  # An empty sourced set is the case that triggers it, so pin the arithmetic on empty input.
  if [ -f "$dir/kit-lib.sh" ]; then
    n_over_probe="$(( $(printf '' | grep -c . || true) - $(printf '' | grep -c . || true) ))"
    eq "an empty count stays a single integer" "$n_over_probe" "0"
  fi

  # ── the whole brief renders under `set -eu` (#283) ───────────────────────────────────────────
  # `bin/cckit` runs `set -eu`, and a while loop's rc is its LAST iteration's: an issue whose file
  # list ended in a non-file token (`templates/skills/` — the parser keeps directory tokens) made
  # the sourced-helpers assignment rc 1 and killed the brief mid-render. Every section after the
  # helpers table — standing gotchas, the durable-prose mandate — was silently absent. The forge
  # shim (test-forge-shim.sh) answers the issue read so this stays network-free; jq and git are
  # real, because the verb requires both.
  if command -v git >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && [ -f "$dir/kit-lib.sh" ]; then
    ghstub="$tmp/ghbin"
    . "$dir/../forge/test-forge-shim.sh"; forge_shim_install "$ghstub"
    export GH_LOG="$tmp/gh.log" GH_TOKEN=test-token CCKIT_FORGE=github KIT_REPO=o/r
    export GH_TITLE="t" GH_BODY="Files: scripts/lib/only-here.sh, templates/skills/"
    : > "$GH_LOG"
    mkdir -p "$repo/.claude/rules"
    cat > "$repo/.claude/rules/delegation-brief.md" <<'EOF'
# Delegation brief
## Standing gotchas
- fixture gotcha
## Durable prose — the concrete pass
- apply the `concrete` catalogue before writing
EOF
    # A subshell, not `sh -c`: kit_brief is a function in THIS shell, and `set -eu` has to apply
    # to it exactly as `bin/cckit` applies it. And NO trailing `|| true` — bash suppresses errexit
    # for a command that is part of a `||` list, and the suppression reaches into the subshell, so
    # a `|| true` here would make these assertions pass against the very bug they pin.
    brief_out="$(cd "$repo" && export PATH="$ghstub:$PATH" && ( set -eu; kit_brief 5 ) 2>&1)"
    has "the brief reaches the helpers table"   "$brief_out" "## Helpers you already have"
    has "the brief reaches the standing gotchas" "$brief_out" "fixture gotcha"
    has "the brief reaches the durable-prose mandate" "$brief_out" 'concrete'
    eq  "the brief reads the issue once, over REST" "$(grep -c '^GET repos/o/r/issues/5 ' "$GH_LOG")" "1"
    eq  "the brief runs no gh subcommand" "$(grep -c '^GH-SUBCOMMAND' "$GH_LOG")" "0"
    # No forge configured: the verb refuses with the one forge_need line, before any read.
    : > "$GH_LOG"
    noforge="$(cd "$repo" && export PATH="$ghstub:$PATH" && ( CCKIT_FORGE=none; export CCKIT_FORGE; unset _FORGE_LOADED; kit_brief 5 ) 2>&1)"; rc=$?
    eq  "no forge: rc 1" "$rc" "1"
    has "no forge: the refusal names the verb" "$noforge" "cckit brief: needs a forge (GitHub) and none is configured"
    has "no forge: the refusal names the fix" "$noforge" "Set forge.provider to github and a token in GH_TOKEN, or sign in with gh"
    eq  "no forge: nothing was read" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"
    # An issue the forge does not have: the read fails and the verb says which issue, rc 1.
    missing="$(cd "$repo" && export PATH="$ghstub:$PATH" && ( GH_FAIL_EP="repos/o/r/issues/404"; export GH_FAIL_EP; kit_brief 404 ) 2>&1)"; rc=$?
    eq  "a failed issue read is rc 1" "$rc" "1"
    has "a failed issue read names the issue" "$missing" "could not read issue #404 from o/r"

    # ── --skills / --verbs: the worker's toolset, exactly as named (#582) ──────────────────────
    : > "$GH_LOG"
    tool_out="$(cd "$repo" && export PATH="$ghstub:$PATH" && ( set -eu; kit_brief 5 --skills kit-advisor --verbs 'effort start, cckit brief' ) 2>&1)"
    has "toolset: the section is there"        "$tool_out" "## Your toolset"
    has "toolset: the skill is listed"         "$tool_out" '- skill `kit-advisor`'
    has "toolset: a two-word verb is listed"   "$tool_out" '- verb `cckit effort start`'
    has "toolset: a leading cckit is dropped"  "$tool_out" '- verb `cckit brief`'
    eq  "toolset: lists exactly what was named" "$(printf '%s\n' "$tool_out" | grep -c '^- \(skill\|verb\) `')" "3"
    has "toolset: the brief still renders"     "$tool_out" "## Standing gotchas"
    : > "$GH_LOG"
    bad_out="$(cd "$repo" && export PATH="$ghstub:$PATH" && ( kit_brief 5 --skills kit-advisor,no-such-skill --verbs 'effort fly,frobnicate' ) 2>&1)"; rc=$?
    eq  "toolset: an unknown name is rc 2"     "$rc" "2"
    has "toolset: names the unknown skill"     "$bad_out" "unknown skill 'no-such-skill'"
    has "toolset: names the unknown sub-verb"  "$bad_out" "unknown verb 'cckit effort fly'"
    has "toolset: names the unknown verb"      "$bad_out" "unknown verb 'cckit frobnicate'"
    eq  "toolset: refused before any forge read" "$(wc -l < "$GH_LOG" | tr -d ' ')" "0"

    # ── the QA route ask appears only when a `qa` block is configured (#297) ───────────────────
    # `cckit qa open` reads a `QA route:` line out of the PR body; the brief is where the builder
    # is told to write it. With no review stack nothing reads the line, so the brief stays silent.
    # KIT_CONFIG is unset so the config is found by the walk-up from the repo root, as in a project.
    no  "no qa block: the brief does not ask for a route" "$brief_out" "QA route"
    eq  "no config: the route ask is empty" "$(unset KIT_CONFIG; kit_brief_qa_route "$repo")" ""
    printf '%s' '{"qa":{"route":"/dashboard"}}' > "$repo/cckit.config.json"
    eq  "a qa block with no command is not a review stack" \
        "$(unset KIT_CONFIG; kit_brief_qa_route "$repo")" ""
    printf '%s' '{"qa":{"command":"pnpm dev:stack","route":"/dashboard"}}' > "$repo/cckit.config.json"
    brief_qa="$(cd "$repo" && unset KIT_CONFIG && export PATH="$ghstub:$PATH" && ( set -eu; kit_brief 5 ) 2>&1)"
    has "qa block: the brief has the route section"  "$brief_qa" "## QA route"
    has "qa block: the brief shows the line to write" "$brief_qa" "QA route: /path/of/the/changed/screen"
    has "qa block: the brief names the fallback route" "$brief_qa" '`/dashboard`'
    has "qa block: the brief names the verb that reads it" "$brief_qa" 'cckit qa open'
    has "the route section comes after the durable-prose mandate" \
        "$(printf '%s\n' "$brief_qa" | sed -n '/^## Durable prose/,$p')" "## QA route"
    rm -f "$repo/cckit.config.json"
  else
    echo "  (git, jq or kit-lib.sh absent — skipping the full-render assertions)"
  fi

  # ── the verb's argument contract (no forge call: it must reject before reaching for the network) ──
  out="$(kit_brief 2>&1)"; rc=$?
  eq  "no argument is rc 2"     "$rc" "2"
  has "no argument prints usage" "$out" "usage: cckit brief"
  out="$(kit_brief --llm 2>&1)"; rc=$?
  eq  "a flag without an issue is rc 2" "$rc" "2"
  out="$(kit_brief 5 --skills 2>&1)"; rc=$?
  eq  "--skills with no list is rc 2" "$rc" "2"
  out="$(kit_brief 5 --bogus 2>&1)"; rc=$?
  eq  "an unknown flag is rc 2" "$rc" "2"
  eq  "verb_ok: an alias row counts" "$(kit_brief_verb_ok status && echo y)" "y"
  eq  "verb_ok: effort with no sub counts" "$(kit_brief_verb_ok effort && echo y)" "y"
  eq  "skill_ok: a path is never a skill" "$(kit_brief_skill_ok ../x || echo n)" "n"
  # The sub-verbs a brief accepts are the ones the dispatcher routes.
  usage_line="$(grep -o 'cckit effort <[a-z|]*>' "$dir/../../bin/cckit" | sed -n 1p)"
  for s in $(printf '%s' "$KB_EFFORT_SUBS" | tr ' ' '\n'); do
    has "effort sub-verb '$s' is in the dispatcher" "$usage_line" "$s"
  done

  rm -rf "$tmp"
  if [ "$fail" -eq 0 ]; then echo "PASS($KB_TEST_INNER): kit-brief parsers + real-state lookups"; fi
  exit "$fail"
fi

rc=0
for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || continue
  KB_TEST_INNER="$sh" "$sh" "$0" || rc=1
done
exit "$rc"
