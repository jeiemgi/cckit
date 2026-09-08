#!/usr/bin/env bash
# shellcheck shell=bash
# effort-slug-test.sh — covers the effort slug layer (#93/#94/#96): slug derivation (doubling fix),
# `slug #N` display, and effort_slug_resolve (number passthrough, branch match, ambiguity, no-match,
# slug:<slug> label vs title-derived precedence). Hermetic: a throwaway git repo with effort/* branches
# + a stubbed gh (no network/auth). Run:  bash scripts/lib/effort-slug-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc() { # <label> <expected-rc> ; reads the just-run command's rc from $?
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '$2' want '$3'"; fail=1; fi; }
command -v git >/dev/null 2>&1 || { echo "effort-slug-test: git required" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Stub gh so the issue-based fallback is deterministic (label lookup + title-derived).
stub="$tmp/bin"; mkdir -p "$stub"
cat > "$stub/gh" <<'SH'
#!/usr/bin/env bash
# issue list --label slug:explicit-handle  → #207 ; title search → #205 "[Effort] 205 · [Core] Title Only Effort"
case "$*" in
  *"--label slug:explicit-handle"*) echo "207" ;;
  *"--label slug:"*)                : ;;                       # unknown label → no match
  *"in:title"*)                     printf '205\t[Effort] 205 · [Core] Title Only Effort\n' ;;
  *) : ;;
esac
SH
chmod +x "$stub/gh"
export PATH="$stub:$PATH"
export EFFORT_REPO="o/r" KIT_REPO="o/r"

# shellcheck source=/dev/null
source "$LIB/effort-slug.sh"

# ── slug derivation (the #93 doubling fix) ─────────────────────────────────────────────────────
t "_eff_title_slug peels prefix + flow (parent)" \
  "$(_eff_title_slug '[Effort] 93 · [Core] Slug handles for efforts')" "slug-handles-for-efforts"
t "_eff_title_slug peels prefix + flow (sub)" \
  "$(_eff_title_slug '[Effort 93] 2 · [UI] Accept slug in commands')" "accept-slug-in-commands"
t "_eff_title_slug without a flow tag" \
  "$(_eff_title_slug '[Effort] 12 · plain outcome name')" "plain-outcome-name"
t "_eff_slug lowercases + dashes arbitrary text" \
  "$(_eff_slug 'Some Mixed CASE!!')" "some-mixed-case"

# ── display ────────────────────────────────────────────────────────────────────────────────────
t "effort_display renders slug #N"   "$(effort_display 93 slug-handles)" "slug-handles #93"
t "effort_display without a slug"    "$(effort_display 93)"              "#93"

# ── effort_slug_resolve: number passthrough (canonical key, never re-mapped) ───────────────────
t  "resolve passes a pure number through" "$(effort_slug_resolve 93)" "93"
effort_slug_resolve "" >/dev/null 2>&1; rc "resolve rejects empty input (rc 2)" "$?" "2"

# ── effort_slug_resolve: branch matching (local + remote effort/* refs) ────────────────────────
( cd "$tmp" && git init -q --bare remote.git )
git clone -q "$tmp/remote.git" "$tmp/work"
cd "$tmp/work" || exit 1
git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git push -q origin HEAD:main
git branch effort/101-resolve-slug
git branch effort/102-accept-slug
git push -q origin effort/101-resolve-slug effort/102-accept-slug
# remote-only branch (delete the local ref so only refs/remotes/origin/… carries it)
git branch -D effort/102-accept-slug >/dev/null 2>&1

t  "resolve a local branch slug"  "$(effort_slug_resolve resolve-slug)" "101"
t  "resolve a remote-only slug"   "$(effort_slug_resolve accept-slug)"  "102"

# ── ambiguity: two efforts share a slug → structured error, nonzero rc, no guess ───────────────
git branch effort/103-resolve-slug
out="$(effort_slug_resolve resolve-slug 2>&1)"; r=$?
rc "ambiguous slug returns nonzero rc" "$r" "1"
case "$out" in *ambiguous*) echo "ok: ambiguous slug explains itself" ;; *) echo "FAIL: ambiguous message: $out"; fail=1 ;; esac
git branch -D effort/103-resolve-slug >/dev/null 2>&1

# ── gh fallback: slug:<slug> label wins; title-derived used when no branch/label matches ───────
t  "resolve via slug label (no branch)"     "$(effort_slug_resolve explicit-handle)"   "207"
t  "resolve via title-derived (no branch)"  "$(effort_slug_resolve title-only-effort)" "205"

# ── no match anywhere → nonzero rc ─────────────────────────────────────────────────────────────
out="$(effort_slug_resolve nope-not-here 2>&1)"; r=$?
rc "unknown slug returns nonzero rc" "$r" "1"
case "$out" in *"no effort matches"*) echo "ok: unknown slug explains itself" ;; *) echo "FAIL: no-match message: $out"; fail=1 ;; esac

# ── #244 · effort_branch_rows — the ONE effort-branch scan (shared with the WIP gate) ──────────
# `<N>\t<slug>` per effort/<N>-<slug> ref, local heads AND remote-tracking. #101 is local+remote
# (two rows, de-duplication is the caller's job); #102 is remote-only and must still appear.
t "branch_rows lists local + remote effort refs" \
  "$(effort_branch_rows | sort | tr '\t' '=' | tr '\n' ' ')" \
  "101=resolve-slug 101=resolve-slug 102=accept-slug "
t "branch_rows ignores non-effort branches" \
  "$(git branch nope/500-not-an-effort >/dev/null 2>&1; effort_branch_rows | grep -c '^500' | tr -d ' ')" "0"
# refs/heads only — the half that needs no cache and no network. #102 is remote-only, so absent.
t "branch_rows_local is refs/heads only" \
  "$(effort_branch_rows_local | sort | tr '\t' '=' | tr '\n' ' ')" "101=resolve-slug "

# ── #244 review · effort_branch_rows_origin — what origin has NOW, not what the cache remembers ──
# rc 0 with rows for a reachable origin; rc 1 (never a silent empty) when origin cannot be read.
t "branch_rows_origin lists origin's effort heads" \
  "$(effort_branch_rows_origin | sort | tr '\t' '=' | tr '\n' ' ')" \
  "101=resolve-slug 102=accept-slug "
# A branch deleted on origin drops out immediately — no fetch, no prune. Deleted by writing the bare
# remote directly, not by `git push origin :ref` from HERE: a delete-push updates this clone's own
# tracking ref, which would hide the very staleness under test. Writing the remote is the honest
# "another machine deleted it" case, and it is what leaves refs/remotes stale.
git --git-dir="$tmp/remote.git" update-ref -d refs/heads/effort/102-accept-slug
t "branch_rows_origin drops a branch deleted on origin" \
  "$(effort_branch_rows_origin | grep -c '^102' | tr -d ' ')" "0"
t "the deleted branch is still in the local cache"  \
  "$(effort_branch_rows | grep -c '^102' | tr -d ' ')" "1"
# An unreachable origin is rc 1, so a caller can tell "cannot read" from "origin has none".
git remote set-url origin "$tmp/absent.git"
effort_branch_rows_origin >/dev/null 2>&1; rc "branch_rows_origin returns rc 1 when origin is unreachable" "$?" "1"
git remote set-url origin "$tmp/remote.git"

[ "$fail" -eq 0 ] && echo "ALL OK (effort-slug)" || echo "effort-slug: FAILURES"
exit "$fail"
