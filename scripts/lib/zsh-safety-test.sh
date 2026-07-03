#!/usr/bin/env bash
# shellcheck shell=bash
# zsh-safety-test.sh — the zsh reserved-name acceptance harness (#116). Every lib that a project may
# source from an INTERACTIVE zsh (the kit's shells alias `g=git`, and zsh ties `path` to $PATH as a
# special array) must source AND run clean there — no "defining function based on alias" parse error
# from a bare `g()`, and no clobbered command-search PATH from a bare `path` local.
#
# The bar per fixed lib: under `zsh -ic` with `alias g=git` set, sourcing the lib returns 0, invoking
# its representative function returns 0, and `git` is still resolvable afterward (PATH intact). Also a
# static regression guard: no bare `local … path …` or `g()` definition creeps back into these files.
#
# Skips (rc 0) when zsh is absent, so the gate stays dependency-light (CI installs zsh, so it runs
# there). bash 3.2 compatible. Run:  bash scripts/lib/zsh-safety-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

if ! command -v zsh >/dev/null 2>&1; then
  echo "zsh-safety-test: zsh absent — skipping (dependency-light gate)"
  exit 0
fi

cd "$ROOT" || exit 1

# run_zsh <label> <snippet> — the snippet runs under `zsh -ic` with `alias g=git` already set. Passes
# only when it exits 0 AND git is still on PATH afterward (proves no `path` clobber leaked out).
run_zsh() {
  local label="$1" snippet="$2" out rc
  out="$(zsh -ic "alias g=git; { $snippet ; } ; ec=\$? ; command -v git >/dev/null 2>&1 || ec=99 ; exit \$ec" 2>&1)"
  rc=$?
  case "$rc" in
    0)  ok "$label (zsh source+run clean, PATH intact)" ;;
    99) bad "$label — PATH clobbered under zsh (a reserved-name local leaked): $(printf '%s' "$out" | tail -1)" ;;
    *)  bad "$label — rc=$rc under zsh: $(printf '%s' "$out" | tail -1)" ;;
  esac
}

# kit-config.sh — the `g()` alias collision (source-time parse error) + `_kit_cfg_get` run.
run_zsh "kit-config.sh :: load_kit_config" \
  "cd '$ROOT'; source scripts/lib/kit-config.sh; load_kit_config >/dev/null 2>&1"

# kit-gc.sh — the `path` local in kit_gc_analyze's while-read (read-only, safe to run).
run_zsh "kit-gc.sh :: kit_gc_analyze" \
  "cd '$ROOT'; export KIT_GC_REPO=jeiemgi/cckit; source scripts/lib/kit-config.sh; load_kit_config >/dev/null 2>&1; source scripts/lib/kit-gc.sh; kit_gc_analyze >/dev/null 2>&1"

# worktree-start.sh — the `path` local in wt_assign_ports (no-op without .worktree.devPorts).
run_zsh "worktree-start.sh :: wt_assign_ports" \
  "cd '$ROOT'; source scripts/lib/worktree-start.sh; wt_assign_ports '$ROOT' 1 '$ROOT' >/dev/null 2>&1"

# kit-events.sh — the `path` local in emit_event.
run_zsh "kit-events.sh :: emit_event" \
  "cd '$ROOT'; source scripts/lib/kit-events.sh; emit_event test op '{}' >/dev/null 2>&1"

# ── static regression guard: no bare reserved-name local reintroduced ──────────────────────────
# Match a `local` declaration listing a bare `path` word, or a bare `g()` function definition. The
# fixed files use namespaced names (wtpath / apppath / logpath / _kit_cfg_get); a plain word here
# would be the regression. Comments are stripped first so the explanatory notes don't trip it.
for f in kit-config.sh kit-gc.sh worktree-start.sh kit-events.sh; do
  code="$(sed 's/#.*$//' "$LIB/$f")"
  if printf '%s\n' "$code" | grep -qE '\blocal\b[^=]*\bpath\b'; then
    bad "$f still declares a bare \`local … path …\`"
  elif printf '%s\n' "$code" | grep -qE '(^|[^_[:alnum:]])g\(\)'; then
    bad "$f still defines a bare \`g()\`"
  else
    ok "$f — no bare reserved-name local (static guard)"
  fi
done

[ "$fail" -eq 0 ] && echo "ALL OK (zsh-safety)" || echo "zsh-safety: FAILURES"
exit "$fail"
