#!/usr/bin/env bash
# docs-marketing-words-test.sh — two checks on the docs site's source (E426).
#
#   1. The Marketing word check. docs-site/src/integrations/marketing-words.mjs fails `astro build`
#      when a page under marketing/ or <lang>/marketing/ says "worktree", "branch" or "PR"; the
#      glossary page words-you-will-hear is the one exemption. Run here against fixtures, then
#      against the real pages.
#   2. The old test address. Before cckit.dev the site was served from a vercel.app address. No
#      docs page, component, style or config value may link or redirect to it.
#
# Network-free; fixtures under mktemp. Part 1 needs node and is skipped without it.
# Run:  bash scripts/docs-marketing-words-test.sh
set -uo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CHECK="$ROOT/docs-site/src/integrations/marketing-words.mjs"

fail=0
t() {  # t <label> <got> <want>
  if [ "$2" != "$3" ]; then echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; else echo "ok: $1"; fi
}

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# ── 1. the Marketing word check ─────────────────────────────────────────────────────────────────
if command -v node >/dev/null 2>&1; then
  docs="$work/docs"
  mkdir -p "$docs/marketing" "$docs/es/marketing" "$docs/tutorials"
  printf 'Ask for a review of your draft.\n' > "$docs/marketing/index.mdx"
  printf 'El borrador pasa a revision.\n' > "$docs/es/marketing/index.mdx"
  # The glossary may use all three words; so may any page outside Marketing.
  printf 'A draft is a branch. A review is a PR. A worktree is a folder.\n' > "$docs/marketing/words-you-will-hear.mdx"
  printf 'Un borrador es un branch; la revision es un PR.\n' > "$docs/es/marketing/words-you-will-hear.mdx"
  printf 'cckit start makes a worktree and a branch, then a PR.\n' > "$docs/tutorials/index.mdx"

  out="$(node "$CHECK" "$docs" 2>&1)"; rc=$?
  t "clean pages pass" "$rc" "0"
  t "clean pages print nothing" "$out" ""

  # A lowercase "pr" inside a word or a URL slug is not the word PR.
  printf 'See [the tutorial](/tutorials/take-a-github-issue-to-a-merged-pr/) to approve and improve.\n' > "$docs/marketing/slug.mdx"
  out="$(node "$CHECK" "$docs" 2>&1)"; rc=$?
  t "a pr slug and 'approve' are not hits" "$rc" "0"

  printf 'line one\nOpen a PR from your branch.\n' > "$docs/marketing/bad.mdx"
  printf 'Claude crea un worktree.\n' > "$docs/es/marketing/bad.mdx"
  out="$(node "$CHECK" "$docs" 2>&1)"; rc=$?
  t "banned words fail" "$rc" "1"
  n="$(printf '%s\n' "$out" | grep -c 'marketing/bad.mdx:2: PR$')"
  t "reports file:line: PR" "$n" "1"
  n="$(printf '%s\n' "$out" | grep -c 'marketing/bad.mdx:2: branch$')"
  t "reports file:line: branch" "$n" "1"
  n="$(printf '%s\n' "$out" | grep -c 'es/marketing/bad.mdx:1: worktree$')"
  t "checks the Spanish pages" "$n" "1"
  n="$(printf '%s\n' "$out" | grep -c 'words-you-will-hear\|tutorials/')"
  t "glossary and non-Marketing pages are exempt" "$n" "0"

  out="$(node "$CHECK" 2>&1)"; rc=$?
  t "the real Marketing pages pass (${out:-clean})" "$rc" "0"
else
  echo "SKIP: node not available — Marketing word check not run"
fi

# ── 2. nothing links or redirects to the old test address ───────────────────────────────────────
# Lines that are comments are skipped: a comment may name the old address to say it is retired.
hits="$(grep -rnE 'vercel\.app' "$ROOT/docs-site/src" "$ROOT/docs-site/public" \
  "$ROOT/docs-site/astro.config.mjs" "$ROOT/docs-site/vercel.json" 2>/dev/null \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|/\*|\*|#|\{/\*)' || true)"
t "no vercel.app address in the docs site (${hits:-none})" "$hits" ""
grep -q 'vercel\.app' "$ROOT/README.md" && readme=1 || readme=0
t "no vercel.app address in README.md" "$readme" "0"

[ "$fail" -eq 0 ] && echo "docs-marketing-words-test: all ok"
exit "$fail"
