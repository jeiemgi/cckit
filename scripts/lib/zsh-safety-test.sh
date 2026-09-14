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
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib"
fail=0
ok()   { echo "ok: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }
t()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 -> got '$2' want '$3'"; fi; }

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

# kit-gc.sh — the sibling-lib load itself (#219). `BASH_SOURCE` is bash-only and an interactive zsh
# echoes the directory after a `cd`, so both the old `${(%):-%x}` and a bare `$(cd … && pwd)` left
# worktree-issue.sh unsourced — `wt_protected_reason` undefined, so every branch looked SAFE.
# `unset -f` first: this runs `zsh -i`, which sources the user's init. If that already defined
# `wt_protected_reason`, `_kit_gc_load_deps` returns early and the case would pass without ever
# resolving the dir — the exact thing under test.
run_zsh "kit-gc.sh :: sibling worktree-issue.sh actually loads" \
  "cd '$ROOT'; unset -f wt_protected_reason 2>/dev/null; source scripts/lib/kit-gc.sh; _kit_gc_load_deps >/dev/null 2>&1; command -v wt_protected_reason >/dev/null 2>&1"

# agent-resolve.sh / stage-receipt.sh / review-stage.sh — the same sibling-load defect as kit-gc
# above (#346). Both E318 files resolved their lib dir from a bare `${BASH_SOURCE[0]}`, which is
# empty under zsh: `dirname ""` is ".", so the sources missed and the walk lost ap_profile_validate
# and kit_state_dir. Nothing sourced them under zsh until the captain did, so it never fired.
# `unset -f` first for the same reason kit-gc's case does it — a user init that already defined the
# symbol would pass the case without resolving anything.
run_zsh "agent-resolve.sh :: sibling agent-profile.sh actually loads" \
  "cd '$ROOT'; unset -f ap_profile_validate 2>/dev/null; source scripts/lib/agent-resolve.sh; command -v ap_profile_validate >/dev/null 2>&1"

run_zsh "stage-receipt.sh :: sibling kit-state.sh actually loads" \
  "cd '$ROOT'; unset -f kit_state_dir 2>/dev/null; source scripts/lib/stage-receipt.sh; command -v kit_state_dir >/dev/null 2>&1"

run_zsh "review-stage.sh :: loads both of its dependencies" \
  "cd '$ROOT'; unset -f ap_resolve_pr sr_record 2>/dev/null; source scripts/lib/review-stage.sh; command -v ap_resolve_pr >/dev/null 2>&1 && command -v sr_record >/dev/null 2>&1"

# worktree-start.sh — the `path` local in wt_assign_ports (no-op without .worktree.devPorts).
run_zsh "worktree-start.sh :: wt_assign_ports" \
  "cd '$ROOT'; source scripts/lib/worktree-start.sh; wt_assign_ports '$ROOT' 1 '$ROOT' >/dev/null 2>&1"

# kit-events.sh — the `path` local in emit_event.
run_zsh "kit-events.sh :: emit_event" \
  "cd '$ROOT'; source scripts/lib/kit-events.sh; emit_event test op '{}' >/dev/null 2>&1"

# effort.sh :: effort_snapshot_subs — the work-record collapse (#339). `for sha in $shas` relied on
# the shell word-splitting an unquoted expansion. bash splits on IFS; zsh does not, so the loop ran
# ONCE with every SHA as a single argument, `git rev-parse --short` failed, and the run still printed
# "✓ snapshotted 1 commit(s)" and exited 0. This is a BEHAVIOURAL case, not a source-and-run one: a
# collapsed snapshot returns 0, so only counting the output files catches it.
#
# Throwaway repo, 3 commits past the base, snapshot under zsh, then assert one .diff and one
# index.jsonl line per commit. The trace lands under that repo's git-common-dir, so it goes with the
# tmpdir.
snap_tmp="$(mktemp -d)"
(
  cd "$snap_tmp" || exit 1
  git init -q .
  git config user.email t@t && git config user.name t
  echo base > f.txt && git add f.txt && git commit -qm "base"
  git branch -q effortbase
  for n in 1 2 3; do
    echo "$n" >> f.txt && git add f.txt && git commit -qm "feat: step $n [E99.$n] (#10$n)"
  done
) >/dev/null 2>&1

# `zsh -fc`, not `-ic`: this case reads the function's STDOUT (the trace dir), and an interactive zsh
# sources the user's rc, which can print shell-integration escapes into it. The cases above only
# check exit codes, so they can afford `-i`; this one cannot. Word-splitting — what #339 is about —
# does not depend on interactivity, so `-f` exercises the same behavior.
snap_out="$(zsh -fc "cd ${snap_tmp}; source ${LIB}/effort.sh; effort_snapshot_subs 99 effortbase" 2>/dev/null)"
if [ -z "$snap_out" ] || [ ! -d "$snap_out" ]; then
  bad "effort.sh :: effort_snapshot_subs ran under zsh (no trace dir echoed)"
else
  ndiff="$(ls "$snap_out"/[0-9][0-9]-*.diff 2>/dev/null | wc -l | tr -d ' ')"
  nidx="$(wc -l < "$snap_out/index.jsonl" 2>/dev/null | tr -d ' ')"
  t "effort_snapshot_subs :: one .diff per commit under zsh" "$ndiff" "3"
  t "effort_snapshot_subs :: one index.jsonl line per commit" "$nidx" "3"
  # A `for sha in $shas` collapse names its stub `NN-` — rev-parse --short fails on the joined list.
  if ls "$snap_out"/[0-9][0-9]-.diff >/dev/null 2>&1; then
    bad "effort_snapshot_subs — wrote a short-sha-less NN-.diff stub (the #339 collapse)"
  else
    ok "effort_snapshot_subs — no short-sha-less stub"
  fi
  # index.jsonl must be true JSONL: one parseable record per line, no `jq -s` needed.
  if jq -e . "$snap_out/index.jsonl" >/dev/null 2>&1; then
    ok "effort_snapshot_subs — index.jsonl is line-parseable JSONL"
  else
    bad "effort_snapshot_subs — index.jsonl is not one JSON record per line"
  fi
fi
rm -rf "$snap_tmp"

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
