#!/usr/bin/env bash
# integrations-check.sh — run every integration descriptor's recipe for real and say which step
# broke (E303.8). A descriptor hardcodes upstream facts: a package name, an installer's flags, a
# binary's name. Nothing in the gate notices when one drifts, because the gate never installs
# anything. This script does, and .github/workflows/integrations-check.yml runs it every month on
# a clean runner.
#
# It holds no recipe of its own. Every command comes from the descriptor and runs through the
# shared runner (scripts/lib/integration-install.sh), so what is checked is what `cckit doctor`
# would run.
#
# Steps per descriptor, in order; the first that fails ends that descriptor:
#   validate   the descriptor matches integrations/integration.schema.json
#   platform   `appliesWhen.platform` matches this machine — a mismatch is a skip, not a failure.
#              `appliesWhen.anyExtension` is satisfied on purpose: the scratch repo is seeded with
#              one file of the first listed extension, because the recipe is under test, not a repo
#   install    integration_install, with consent recorded in the scratch repo only. A tool already
#              on the machine is reported and its install recipe is NOT exercised
#   detect     `detect.run` exits 0 afterwards
#   verify     `verify.run` exits 0
#   wire       integration_wire in the scratch repo, when the descriptor has a wire step
#
# Not exercised: install candidates after the one that worked (the runner stops at the first), a
# `bootstrap` on a machine that already holds one of the managers, `uninstall`, and `build.deep`.
#
# Usage: integrations-check.sh [--yes] [id|file ...]
#   no ids   every descriptor in integrations/ ($KIT_INTEGRATIONS_DIR overrides)
#   --yes    install for real. Without it nothing runs: each descriptor is validated and its plan
#            is printed. Meant for a throwaway machine — it installs tools on the machine it runs on.
# Output: one `ok|skip|FAIL <id>: <step>: <detail>` line per step on stdout, runner progress on
# stderr, then a one-line count.
# Requires: jq, git.
# errors: strict — rc 1 when any descriptor fails a step, rc 2 on a usage error; rc 0 otherwise,
# including the plan-only run without --yes

set -u
_ic_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_ic_dir/lib/integration-install.sh"   # integration_install, integration_wire, integrations.sh

_ic_usage() { kit_warn "usage: integrations-check.sh [--yes] [id|file ...]"; }

ic_yes=0
ic_args=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ic_yes=1 ;;
    -h|--help) _ic_usage; exit 0 ;;
    -*) _ic_usage; exit 2 ;;
    *) ic_args="$ic_args $1" ;;
  esac
  shift
done

command -v jq >/dev/null 2>&1 || kit_die "integrations-check: jq is required"

# Consent for this run goes into the scratch repo and nowhere else: an inherited KIT_STATE_DIR
# would point the consent file at a real project.
unset KIT_STATE_DIR
[ "$ic_yes" -eq 1 ] && unset KIT_DRY_RUN

ic_tmp="$(mktemp -d)" || kit_die "integrations-check: cannot create a scratch dir"
trap 'rm -rf "$ic_tmp"' EXIT
ic_tmp="$(cd "$ic_tmp" && pwd -P)"

ic_checked=0; ic_failed=0; ic_skipped=0

_ic_line() { printf '%-4s %s: %s\n' "$1" "$2" "$3"; }
_ic_fail() {
  _ic_line FAIL "$1" "$2: $3"
  # The captured output of the failing step, indented, so the issue body carries the evidence.
  if [ -s "${4:-}" ]; then tail -n 20 "$4" | sed 's/^/       /'; fi
  ic_failed=$((ic_failed + 1))
}

# _ic_scratch <id> <file> -> a fresh git repo for one descriptor, seeded so that an
# `anyExtension` predicate holds.
_ic_scratch() {
  local d="$ic_tmp/$1" ext
  mkdir -p "$d" || return 1
  git -C "$d" init -q >/dev/null 2>&1 || true
  ext="$(jq -r '.appliesWhen.anyExtension[0] // ""' "$2" 2>/dev/null)"
  if [ -n "$ext" ]; then : > "$d/seed$ext"; fi
  printf '%s\n' "$d"
}

_ic_one() {
  local f="$1" id d log st cmd
  id="$(basename "$f" .json)"
  log="$ic_tmp/$id.log"
  ic_checked=$((ic_checked + 1))

  if ! integration_validate "$f" >"$log" 2>&1; then
    _ic_fail "$id" validate "the descriptor does not match the schema" "$log"; return 0
  fi
  _ic_line ok "$id" "validate"

  d="$(_ic_scratch "$id" "$f")" || { _ic_fail "$id" platform "cannot create a scratch repo"; return 0; }
  if ! integration_applies "$f" "$d"; then
    _ic_line skip "$id" "platform: needs $(integration_applies_needs "$f"); this is $(uname -s) $(uname -m)"
    ic_skipped=$((ic_skipped + 1)); return 0
  fi

  if [ "$ic_yes" -ne 1 ]; then
    KIT_DRY_RUN=1 integration_install_plan "$f" "$d" | sed 's/^/       /'
    _ic_line skip "$id" "install: plan only — pass --yes to run it"
    ic_skipped=$((ic_skipped + 1)); return 0
  fi

  if integration_detect "$f" "$d"; then
    _ic_line skip "$id" "install: already on this machine, so the install recipe was not exercised"
  else
    integration_consent_record "$id" "$d" || { _ic_fail "$id" install "cannot record consent in $d"; return 0; }
    st="$(integration_install "$f" "$d" 2>"$log")" || { _ic_fail "$id" install "no candidate installed the tool" "$log"; return 0; }
    case "$st" in
      installed*) _ic_line ok "$id" "install: ${st#installed } — $(jq -r --arg m "${st#installed }" '[.install[] | select(.manager == $m)][0].run' "$f")" ;;
      *) _ic_fail "$id" install "the runner answered '$st' instead of installing" "$log"; return 0 ;;
    esac
    if ! integration_detect "$f" "$d"; then
      _ic_fail "$id" detect "'$(jq -r '.detect.run' "$f")' fails after a successful install"; return 0
    fi
  fi
  _ic_line ok "$id" "detect: $(jq -r '.detect.run' "$f")"

  cmd="$(jq -r '.verify.run // ""' "$f")"
  if [ -n "$cmd" ]; then
    if ! _kit_ii_sh "$d" "$cmd" >"$log" 2>&1; then
      _ic_fail "$id" verify "'$cmd' exited non-zero" "$log"; return 0
    fi
    _ic_line ok "$id" "verify: $cmd"
  fi

  if cmd="$(integration_wire_command "$f")"; then
    integration_consent_record "$id" "$d" || { _ic_fail "$id" wire "cannot record consent in $d"; return 0; }
    st="$(integration_wire "$f" "$d" 2>"$log")" || st="failed"
    if [ "$st" != "wired" ]; then
      _ic_fail "$id" wire "'$cmd' did not complete (runner answered '$st')" "$log"; return 0
    fi
    _ic_line ok "$id" "wire: $cmd"
  fi
  return 0
}

if [ -z "$ic_args" ]; then ic_args="$(integrations_list)"; fi
for ic_a in $ic_args; do
  if [ -f "$ic_a" ]; then ic_f="$ic_a"
  elif ic_f="$(integration_file "$ic_a")"; then :
  else
    ic_checked=$((ic_checked + 1))
    _ic_fail "$ic_a" validate "no descriptor with that id in $(integrations_dir)"
    continue
  fi
  _ic_one "$ic_f"
done

printf 'integrations-check: %s checked, %s failed, %s skipped\n' "$ic_checked" "$ic_failed" "$ic_skipped"
[ "$ic_failed" -eq 0 ]
