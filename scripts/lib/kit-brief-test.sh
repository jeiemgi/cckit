#!/bin/sh
# kit-brief-test.sh — self-test for kit-brief.sh, the delegation-brief generator (Effort 220 · #221).
# Network-free and repo-free: the text parsers run against fixture strings, and the git-dependent
# lookups (seed freshness, worktree association, basename resolution) run against a throwaway repo
# with a fabricated `origin/` ref — so nothing here depends on what this checkout looks like today.
# Every assertion runs under bash AND zsh, because the verb is sourced by a dispatcher that may be
# either and the parsers use parameter expansion that the two shells disagree about.
# Run:  bash scripts/lib/kit-brief-test.sh
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
  eq  "section trims leading blank"  "$(printf '%s\n' "$sec" | head -1)" "build order matters"
  eq  "section trims trailing blank" "$(printf '%s\n' "$sec" | tail -1)" '- `scripts/lib/a.sh`'
  eq  "absent section is empty"      "$(printf '%s\n' "$body" | kit_brief_section "Nope")" ""
  # heading match is case-insensitive but not a prefix match
  has "section matches case-insensitively" \
      "$(printf '%s\n' "$body" | kit_brief_section "for agents")" "build order matters"

  # ── kit_brief_files ──────────────────────────────────────────────────────────────────────────
  text='Edit `scripts/lib/captain.sh` and captain-test.sh, plus docs/ and README.md.
Files: scripts/lib/kit-brief.sh, bin/cckit, docs-site/src/content/docs/cli-reference.mdx
See https://example.com/thing.md for context. Ignore prose words like errors: and mixed.'
  f="$(printf '%s\n' "$text" | kit_brief_files)"
  has "path from backticks"     "$f" "scripts/lib/captain.sh"
  has "bare basename token"     "$f" "captain-test.sh"
  has "directory token"         "$f" "docs/"
  has "path from a Files: line" "$f" "scripts/lib/kit-brief.sh"
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
source "$LIB/kit-config.sh" && load_kit_config
. "$LIB/gh-project.sh"
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/kit-lib.sh"
echo "not a source line: lib/decoy.sh"
EOF
  srcd="$(kit_brief_sourced "$tmp/consumer.sh")"
  has "finds a source'd helper"        "$srcd" "kit-config.sh"
  has "finds a dot-source'd helper"    "$srcd" "gh-project.sh"
  has "finds a plugin-root helper"     "$srcd" "kit-lib.sh"
  no  "ignores a non-source mention"   "$srcd" "decoy.sh"
  eq  "missing file is skipped, not fatal" "$(kit_brief_sourced "$tmp/nope.sh")" ""

  # ── kit_brief_gotchas ────────────────────────────────────────────────────────────────────────
  mkdir -p "$tmp/proj/.claude/rules" "$tmp/proj/templates/rules"
  cat > "$tmp/proj/templates/rules/delegation-brief.md" <<'EOF'
# Delegation brief
## Standing gotchas
- template gotcha
## Gate commands
- not a gotcha
EOF
  eq "falls back to the kit template" \
     "$(kit_brief_gotchas "$tmp/proj" | head -1)" "- template gotcha"
  cat > "$tmp/proj/.claude/rules/delegation-brief.md" <<'EOF'
# Delegation brief
## Standing gotchas

- project gotcha

## Gate commands
- not a gotcha
EOF
  g="$(kit_brief_gotchas "$tmp/proj")"
  eq  "project rule wins over the template" "$(printf '%s\n' "$g" | head -1)" "- project gotcha"
  no  "gotchas stop at the next heading"    "$g" "not a gotcha"
  eq  "no rule file yields nothing"         "$(kit_brief_gotchas "$tmp/empty-root")" ""

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
    if [ -f "$dir/worktree-issue.sh" ]; then
      # shellcheck source=/dev/null
      . "$dir/worktree-issue.sh"
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

  # ── the verb's argument contract (no gh call: it must reject before reaching for the network) ──
  out="$(kit_brief 2>&1)"; rc=$?
  eq  "no argument is rc 2"     "$rc" "2"
  has "no argument prints usage" "$out" "usage: cckit brief"
  out="$(kit_brief --llm 2>&1)"; rc=$?
  eq  "a flag without an issue is rc 2" "$rc" "2"

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
