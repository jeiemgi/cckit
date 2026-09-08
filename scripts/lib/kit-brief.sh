#!/usr/bin/env bash
# shellcheck shell=bash
# kit-brief.sh — generate an issue's delegation brief from real repo state (Effort 220 · #221).
# errors: mixed — the parsers are pure; kit_brief propagates a gh failure
#
# A hand-written delegation brief drops whatever its author forgot, and what gets forgotten is the
# part the agent then rediscovers by hand — the worktree it should work in, the base tip that says
# whether its seed is stale, the helper that already does the thing it is about to reimplement.
# This verb reads all of that out of the repo instead: `gh` for the issue, `git worktree list` for
# the isolation, `origin/<base>` for the seed, `kit_lib_rows` (#222) for the helpers, and the
# project's own delegation-brief rule for the standing gotchas + the durable-prose (`concrete`)
# mandate. Nothing here is remembered.
#
# Source it:  source scripts/lib/kit-brief.sh
# Depends on: kit-lib.sh (the helper catalog), and for the verb body: gh, git, the project config.

# ── pure parsers (no gh, no git; every one is unit-tested against fixture text) ─────────────────

# _kb_rtrim — drop leading AND trailing blank lines from stdin, so a section lifted out of a
# markdown body drops straight into the brief without a stray gap. awk, not the sed label idiom,
# because BSD sed (macOS) and GNU sed disagree about `{$d;N;ba}` inside -e fragments.
_kb_rtrim() {
  awk '{ a[NR] = $0 }
       END {
         first = 0; last = 0
         for (i = 1; i <= NR; i++) if (a[i] !~ /^[[:space:]]*$/) { if (!first) first = i; last = i }
         for (i = first; i <= last; i++) print a[i]
       }'
}

# kit_brief_section <heading> — stdin is an issue body; echo the lines under `## <heading>` up to
# the next `## ` heading (the heading line itself excluded), trailing blanks trimmed. Empty output
# means the section is absent, which is a fact the brief reports rather than papering over.
kit_brief_section() {
  local want="$1"
  awk -v want="$want" '
    /^##[[:space:]]/ {
      line = $0; sub(/^##[[:space:]]*/, "", line)
      # compare case-insensitively without gawk-only tolower() on both sides being a problem
      in_s = (tolower(line) == tolower(want)) ? 1 : 0
      next
    }
    in_s { print }
  ' | _kb_rtrim
}

# kit_brief_files — stdin is any issue text; echo one repo-relative path per line, sorted, unique.
# Recognises both shapes the kit's own issues use: an `## For agents` prose section that names
# paths, and the `Files: a, b, c` line `cckit effort new` writes into a sub-issue. A token counts
# as a path when it has a known source/doc extension, ends in `/` (a directory the issue owns), or
# is a slash-bearing extensionless token — `bin/cckit`, the kit's own entry point, has no extension.
# Being permissive here is safe because the verb resolves every token against the repo and drops an
# extensionless one that does not exist, so prose like `and/or` never reaches the brief.
# Surrounding backticks, quotes and trailing sentence punctuation are stripped. Pure.
kit_brief_files() {
  tr -s ' \t,;()<>"' '\n' \
    | sed -e 's/^`*//' -e 's/`*$//' -e "s/^'*//" -e "s/'*$//" -e 's/[.:]*$//' \
    | grep -E '^[A-Za-z0-9_][A-Za-z0-9_./-]*(\.(sh|md|mdx|json|jsonc|ya?ml|ts|tsx|js|jsx|css|html|bash|zsh)|/|/[A-Za-z0-9_-]+)$' \
    | grep -v '^https\?:' \
    | sort -u
}

# kit_brief_sourced <file>… — echo the helper basenames those files actually `source`, sorted and
# unique. Basenames, not paths, because the kit's own source lines go through a variable
# (`source "$LIB/kit-config.sh"`) — matching a literal `lib/` prefix would find none of them. Derived from the source lines in the files themselves, so the brief names the helpers the
# work genuinely sits on top of rather than guessing from a filename. Missing files are skipped.
kit_brief_sourced() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || continue
    # Two anchored greps, not one sed: BSD sed (macOS) has no `\|` alternation in a basic regex, so
    # the single-expression form silently matched nothing there. Anchoring `source` / `.` to the
    # line start also keeps a prose line that merely mentions a helper out of the result.
    grep -E '^[[:space:]]*(source|\.)[[:space:]]' "$f" 2>/dev/null \
      | grep -Eo '[A-Za-z0-9_.-]+\.sh'
  done | sort -u
}

# kit_brief_rule_section <heading-regex> [root] — echo one `## ` block of the project's own
# delegation-brief rule (`.claude/rules/delegation-brief.md`), falling back to the kit's template.
# The blocks are transferable instruction the project already maintains; re-typing them into a
# brief is how they go stale. <heading-regex> is an ERE matched against the whole heading line, so
# it must tolerate the heading's own suffixes ("Standing gotchas (transferable — …)"). Echoes
# nothing when no rule file exists — the caller says so.
# The FIRST file that exists wins for every section, so a project that owns the rule owns all of it.
kit_brief_rule_section() {
  local want="$1" root="${2:-.}" f
  for f in "$root/.claude/rules/delegation-brief.md" \
           "$root/templates/rules/delegation-brief.md" \
           "${CCKIT_ROOT:-$root}/templates/rules/delegation-brief.md"; do
    [ -f "$f" ] || continue
    awk -v want="$want" '
      /^##[[:space:]]/ { in_s = ($0 ~ want) ? 1 : 0; next }
      in_s { print }
    ' "$f" | _kb_rtrim
    return 0
  done
}

# kit_brief_gotchas [root] — the "Standing gotchas" block. Thin caller of kit_brief_rule_section.
kit_brief_gotchas() { kit_brief_rule_section '[Ss]tanding gotchas' "${1:-.}"; }

# kit_brief_durable_prose [root] — the "Durable prose" block: the instruction that an agent about to
# write a durable artifact (issue body, PR body, commit message, rule, ADR, knowledge doc) applies
# the `concrete` catalogue first. It is in the GENERATED brief, not only in the rule, because a
# sub-agent applies a skill only when it is told to — an installed skill no brief mentions does not
# fire (that is why `concrete` shipped in PR 247 and no body records a pass; see #283).
kit_brief_durable_prose() { kit_brief_rule_section '[Dd]urable prose' "${1:-.}"; }

# ── real-state lookups ─────────────────────────────────────────────────────────────────────────

# kit_brief_worktree <issue> — echo "<path>\t<branch>" for the worktree that belongs to this issue,
# or nothing. The association is DERIVED from the branch name via wt_issue_number (worktree-issue.sh),
# the same rule gc uses to decide what is protected, so the brief and gc can never disagree about
# which worktree an issue owns. best-effort: no git, no output.
kit_brief_worktree() {
  local want="$1" wtpath ref b n
  command -v git >/dev/null 2>&1 || return 0
  command -v wt_issue_number >/dev/null 2>&1 || return 0
  git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{w=$2} /^branch /{print w"\t"$2}' \
    | while IFS="$(printf '\t')" read -r wtpath ref; do
        b="${ref#refs/heads/}"
        n="$(wt_issue_number "$b")"
        [ "$n" = "$want" ] || continue
        printf '%s\t%s\n' "$wtpath" "$b"
      done | head -1
}

# kit_brief_resolve <token> — echo the repo path a token refers to, plus a tab and a status word:
# `here` (the path exists), `new` (it does not), or `ambiguous` (a bare basename matching several
# tracked files — the brief prints the count instead of picking one). A bare basename is resolved
# against `git ls-files` so a token lifted from prose ("captain-test.sh") is not reported as a new
# file when it plainly exists under scripts/lib. best-effort: without git only literal paths resolve.
kit_brief_resolve() {
  local tok="$1" root="${2:-.}" hits n
  case "$tok" in
    */*) if [ -e "$root/$tok" ]; then printf '%s\there' "$tok"; else printf '%s\tnew' "$tok"; fi; return 0 ;;
  esac
  if [ -e "$root/$tok" ]; then printf '%s\there' "$tok"; return 0; fi
  command -v git >/dev/null 2>&1 || { printf '%s\tnew' "$tok"; return 0; }
  hits="$(git -C "$root" ls-files 2>/dev/null | grep -E "(^|/)$(printf '%s' "$tok" | sed 's/[.[\*^$]/\\&/g')$" | head -5)"
  n="$(printf '%s' "$hits" | grep -c . || true)"
  case "$n" in
    0) printf '%s\tnew' "$tok" ;;
    1) printf '%s\there' "$hits" ;;
    *) printf '%s\tambiguous %s' "$tok" "$n" ;;
  esac
}

# kit_brief_seed <branch> <base> — echo "fresh <tip>" when origin/<base> is already an ancestor of
# <branch>, "stale <tip>" when it is not (the branch was seeded from an older commit and needs a
# rebase before anyone trusts a green check on it), or "unknown" when either ref is missing. This
# is the check a hand-written brief always omits and the one that silently wastes a whole session.
kit_brief_seed() {
  local branch="$1" base="$2" tip
  command -v git >/dev/null 2>&1 || { printf '%s' "unknown"; return 0; }
  tip="$(git rev-parse --short "origin/$base" 2>/dev/null)" || tip=""
  [ -n "$tip" ] || { printf '%s' "unknown"; return 0; }
  git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null 2>&1 \
    || { printf '%s' "unknown"; return 0; }
  if git merge-base --is-ancestor "origin/$base" "$branch" 2>/dev/null; then
    printf 'fresh %s' "$tip"
  else
    printf 'stale %s' "$tip"
  fi
}

# _kb_rows <libdir> <names> — the catalog rows for a newline-separated set of helper basenames, in
# catalog order. One implementation for both halves of the helpers table.
_kb_rows() {
  local libdir="$1" want="$2" row _e _fn _p
  [ -n "$want" ] || return 0
  kit_lib_rows "$libdir" | while IFS="$(printf '\t')" read -r row _e _fn _p; do
    printf '%s\n' "$want" | grep -qxF "$row" || continue
    printf '| `%s` | %s | %s |\n' "$row" "$_e" "$_p"
  done
}

# ── the verb ───────────────────────────────────────────────────────────────────────────────────

# kit_brief <issue> — print the delegation brief for an issue as markdown. strict about its one
# hard dependency: a gh failure (no auth, no such issue) propagates rather than yielding a brief
# with an empty issue in it. Every other section degrades to an explicit "not found" line, because
# a brief that silently omits a section is the failure mode this verb exists to remove.
kit_brief() {
  local n="${1:-}" root base repo body title state labels foragents files files_from wt wtpath wtbranch
  local seed gotchas prose libdir row f gate
  case "$n" in
    ''|--*) echo "usage: cckit brief <issue>" >&2; return 2 ;;
  esac
  n="${n#\#}"
  command -v gh >/dev/null 2>&1 || { echo "cckit brief: gh is required" >&2; return 1; }
  command -v jq >/dev/null 2>&1 || { echo "cckit brief: jq is required" >&2; return 1; }

  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  base="${KIT_BASE_BRANCH:-main}"
  repo="${KIT_REPO:-}"

  # The one strict dependency. Fetch title/state/labels/body in a single call.
  local issue_json
  if [ -n "$repo" ]; then
    issue_json="$(gh issue view "$n" --repo "$repo" --json title,state,labels,body 2>&1)" || {
      printf 'cckit brief: could not read issue #%s from %s\n%s\n' "$n" "$repo" "$issue_json" >&2
      return 1
    }
  else
    issue_json="$(gh issue view "$n" --json title,state,labels,body 2>&1)" || {
      printf 'cckit brief: could not read issue #%s\n%s\n' "$n" "$issue_json" >&2
      return 1
    }
  fi
  title="$(printf '%s' "$issue_json"  | jq -r '.title // ""')"
  state="$(printf '%s' "$issue_json"  | jq -r '.state // ""' | tr 'A-Z' 'a-z')"
  labels="$(printf '%s' "$issue_json" | jq -r '[.labels[]?.name] | join(" · ")')"
  body="$(printf '%s' "$issue_json"   | jq -r '.body // ""')"

  foragents="$(printf '%s\n' "$body" | kit_brief_section "For agents")"
  # Paths come from the `## For agents` section when the issue has one; otherwise from the whole
  # body (a sub-issue carries a `Files:` line instead). The brief states which, so a thin file list
  # is legible as "the issue said little", not as "the verb missed something".
  files=""; files_from="body"
  if [ -n "$foragents" ]; then
    files="$(printf '%s\n' "$foragents" | kit_brief_files)"
    [ -n "$files" ] && files_from="for-agents"
  fi
  # A `## For agents` section that names no paths is common (it often carries build ORDER, not
  # files). Fall back to the whole issue rather than reporting "no paths" when the issue clearly
  # lists some elsewhere — and say which source the list came from either way.
  [ -n "$files" ] || files="$(printf '%s\n' "$body" | kit_brief_files)"
  [ -n "$files" ] || files_from="none"

  echo "# Delegation brief — #$n"
  echo
  printf '**%s**\n' "${title:-（untitled）}"
  printf '\n- issue: `#%s` · %s%s\n' "$n" "${state:-unknown}" "${labels:+ · $labels}"
  [ -n "$repo" ] && printf -- '- repo: `%s` · base branch `%s`\n' "$repo" "$base"

  # ── where the work happens
  wt="$(kit_brief_worktree "$n")"
  wtpath="${wt%%	*}"; wtbranch="${wt##*	}"
  if [ -n "$wt" ]; then
    printf -- '- worktree: `%s`\n- branch: `%s`\n' "$wtpath" "$wtbranch"
    seed="$(kit_brief_seed "$wtbranch" "$base")"
    case "$seed" in
      fresh*) printf -- '- seed: **fresh** — `origin/%s` (%s) is already in this branch\n' "$base" "${seed#fresh }" ;;
      stale*) printf -- '- seed: **STALE** — `origin/%s` (%s) is NOT in this branch; rebase before trusting a green check\n' "$base" "${seed#stale }" ;;
      *)      printf -- '- seed: unknown — could not compare against `origin/%s`\n' "$base" ;;
    esac
  else
    printf -- '- worktree: none yet — run `cckit start %s` first; never work in the shared checkout\n' "$n"
  fi
  gate="$([ -f "$root/scripts/check.sh" ] && echo 'bash scripts/check.sh' || echo 'the project gate (no scripts/check.sh found)')"
  printf -- '- gate: `%s` must pass before the PR\n' "$gate"

  # ── the files this issue owns
  echo
  echo "## Files this issue owns"
  echo
  if [ -n "$files" ]; then
    case "$files_from" in
      for-agents) echo "_From the issue's \`## For agents\` section._" ;;
      *) if [ -n "$foragents" ]; then
           echo "_The issue's \`## For agents\` section names no paths — these are every path named elsewhere in the issue._"
         else
           echo "_No \`## For agents\` section — these are every path named anywhere in the issue._"
         fi ;;
    esac
    echo
    # Resolve first, THEN dedupe: two tokens in one issue ("pr-evidence.sh" in prose and
    # "scripts/lib/pr-evidence.sh" in a Files: line) resolve to one path and must print once.
    local resolved_rows
    resolved_rows="$(while IFS= read -r f; do
        [ -n "$f" ] || continue
        kit_brief_resolve "$f" "$root"
        printf '\n'
      done <<EOF
$files
EOF
)"
    printf '%s\n' "$resolved_rows" | grep . | awk -F'\t' '!seen[$1]++' \
      | while IFS="$(printf '\t')" read -r rpath rstate; do
          # An extensionless token that resolves to nothing is prose ("and/or"), not a file the
          # issue owns — the parser is permissive so `bin/cckit` survives; this is where the
          # false positives go.
          case "${rpath##*/}" in
            *.*) : ;;
            *) [ "$rstate" = "new" ] && continue ;;
          esac
          case "$rstate" in
            here) printf -- '- `%s`\n' "$rpath" ;;
            new)  printf -- '- `%s` — does not exist yet (new file)\n' "$rpath" ;;
            *)    printf -- '- `%s` — %s tracked files match this name; confirm which one\n' "$rpath" "${rstate#ambiguous }" ;;
          esac
        done
  else
    echo "_The issue names no paths. Ask for them before starting; do not guess._"
  fi

  # ── the helpers that work sits on
  echo
  echo "## Helpers you already have"
  echo
  libdir="$(command -v kit_lib_dir >/dev/null 2>&1 && kit_lib_dir "$root" || echo "$root/scripts/lib")"
  if [ -d "$libdir" ] && command -v kit_lib_rows >/dev/null 2>&1; then
    # Two derived sources: helpers the issue OWNS, and helpers its existing files actually source.
    local owned_libs sourced_libs want_libs table
    owned_libs="$(printf '%s\n' "$files" | sed -n 's#.*/\([A-Za-z0-9_.-]*\.sh\)$#\1#p')"
    # `if`, not `[ -f … ] &&`: a while loop's rc is its LAST iteration's, so a trailing non-file
    # token (`templates/skills/` — the parser keeps directory tokens) made this assignment rc 1 and
    # `bin/cckit`'s `set -eu` killed the brief right here. Every section below — the helpers table,
    # the standing gotchas, the durable-prose mandate — was silently missing from every generated
    # brief. An `if` with no else always returns 0, so the loop's rc no longer depends on the input.
    sourced_libs="$(while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -f "$root/$f" ]; then kit_brief_sourced "$root/$f" || true; fi
      done <<EOF
$files
EOF
)"
    # OWNED helpers first (the ones this issue edits), then the ones its files merely source, and
    # only up to a cap: an issue that owns `bin/cckit` sources every helper in the kit, and a
    # 40-row table is not a brief. The overflow is counted, never silently dropped.
    local sourced_only cap shown_owned shown_src n_src n_over
    sourced_only="$(printf '%s\n' "$sourced_libs" | grep . | sort -u \
      | { if [ -n "$owned_libs" ]; then grep -vxF -f <(printf '%s\n' "$owned_libs" | grep .) || true; else cat; fi; })"
    cap="${KIT_BRIEF_MAX_HELPERS:-10}"
    shown_owned="$(_kb_rows "$libdir" "$(printf '%s\n' "$owned_libs" | grep . | sort -u)")"
    n_src="$(printf '%s' "$shown_owned" | grep -c . || true)"
    shown_src="$(_kb_rows "$libdir" "$sourced_only" | head -n "$((cap > n_src ? cap - n_src : 0))")"
    # `|| true`, never `|| echo 0`: `grep -c` on empty input already PRINTS 0 and exits 1, so the
    # `echo 0` fallback appends a SECOND zero and the arithmetic below sees "0\n0". Same bug class
    # as the #142 board-counter regression.
    local n_all n_shown
    n_all="$(_kb_rows "$libdir" "$sourced_only" | grep -c . || true)"
    n_shown="$(printf '%s' "$shown_src" | grep -c . || true)"
    n_over="$(( ${n_all:-0} - ${n_shown:-0} ))"
    if [ -n "$shown_owned$shown_src" ]; then
      echo "| helper | errors | purpose |"
      echo "| --- | --- | --- |"
      printf '%s\n' "$shown_owned" | grep . || true
      printf '%s\n' "$shown_src" | grep . || true
      [ "$n_over" -gt 0 ] && printf -- '\n_+%s more helper(s) these files source — `cckit lib` lists them._\n' "$n_over"
    else
      echo "_None of the issue's files are helpers or source one._"
    fi
    echo
    printf -- '_Full catalog: `cckit lib` (%s helpers). Do not reimplement what it already lists._\n' \
      "$(kit_lib_files "$libdir" | grep -c . || true)"
  else
    echo "_No helper catalog here — `cckit lib` is unavailable in this project._"
  fi

  # ── standing gotchas, from the project's own rule
  echo
  echo "## Standing gotchas"
  echo
  gotchas="$(kit_brief_gotchas "$root")"
  if [ -n "$gotchas" ]; then
    printf '%s\n' "$gotchas"
  else
    echo "_No \`delegation-brief.md\` rule found — add one so this section stops being empty._"
  fi

  # ── durable prose, from the same rule. An agent applies a skill only when it is told to, so the
  # concrete mandate has to reach the brief; stating it in communication-style.md alone never fired.
  echo
  echo "## Durable prose"
  echo
  prose="$(kit_brief_durable_prose "$root")"
  if [ -n "$prose" ]; then
    printf '%s\n' "$prose"
  else
    echo "_No \`Durable prose\` section in \`delegation-brief.md\` — add one so an agent writing an issue body, a PR body or a commit message is told to run the \`concrete\` pass first._"
  fi
}
