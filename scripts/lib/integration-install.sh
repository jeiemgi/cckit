#!/usr/bin/env bash
# integration-install.sh — the ONE installer runner for an integration descriptor (E303.3).
#
# integrations.sh reads and checks a descriptor; this file ACTS on one: it walks the descriptor's
# ordered `install` candidates, finds the binary afterwards, and runs the optional `wire` step.
# It replaced the per-tool copies of that walk (scripts/kit-doctor.sh calls it for every enabled
# descriptor) and holds no tool-specific code — every command it runs comes from the descriptor.
#
# Four rules, in the order integration_install applies them:
#   1. Already installed (the descriptor's `detect.run` exits 0) -> nothing runs. A second run is
#      a no-op.
#   2. KIT_DRY_RUN set -> the plan is printed, nothing runs.
#   3. No recorded consent for this integration in this repo -> nothing runs, rc 0. Consent is one
#      `install:<id>` line in the `consent` file of the state dir kit_state_dir resolves (.cckit/,
#      shared by every worktree of the repo). KIT_ASSUME_YES is NOT consent.
#   4. Candidates are tried in descriptor order. One whose `manager` is not on PATH is skipped.
#      The first whose command exits 0 AND leaves the tool detectable wins; the rest never run.
#      When NO candidate's manager is on PATH, each candidate's optional `bootstrap` is tried in
#      the same order (`brew install uv`); the first that puts a manager on PATH lets the walk
#      run. A machine that already holds any listed manager is never bootstrapped.
#
# uv and pipx drop binaries into ~/.local/bin, which is often not on PATH in the session that ran
# the install. Every detect / install / wire command therefore runs with `$HOME/.local/bin`
# appended to PATH (appended: a binary already on PATH wins), and integration_bin resolves there.
#
# Source it:  source scripts/lib/integration-install.sh
#   integration_consent_file [dir]        the consent file for the repo at dir (not created)
#   integration_consent_has <id> [dir]    rc 0 when `install:<id>` is recorded
#   integration_consent_record <id> [dir] record it (idempotent); rc 1 when it cannot be written
#   integration_bin <file>                path of the tool's binary (detect.bin, else the first
#                                         word of detect.run): PATH, then ~/.local/bin; rc 1 when
#                                         it is in neither
#   integration_detect <file>             rc 0 when detect.run exits 0
#   integration_install_plan <file> [dir] the plan on stdout; runs nothing
#   integration_install <file> [dir]      one status line on stdout, progress on stderr:
#                                           present | dry-run | no-consent | installed <manager>
#                                           (all rc 0) or failed (rc 1)
#   integration_wire_command <file>       `wire.run` + every flag in `wire.declined`; rc 1 when the
#                                         descriptor has no wire step
#   integration_wire <file> [dir]         run it in dir, under the same dry-run + consent rules:
#                                           none | dry-run | no-consent | wired (rc 0) | failed (rc 1)
# CLI:        integration-install.sh --plan <id|file> [dir]
#             integration-install.sh --install <id|file> [dir]
#             integration-install.sh --wire <id|file> [dir]
#             integration-install.sh --wire-command <id|file>
#             integration-install.sh --consent <id> [dir]
# Requires: jq. bash 3.2 + zsh compatible; safe to source under `set -euo pipefail`.
# errors: best-effort — a failed candidate falls through to the next; rc 1 only when the
# descriptor is invalid or no candidate left the tool installed. Declining (dry-run, no consent)
# is rc 0.

_kit_ii_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_kit_ii_dir/kit-cli.sh"       # kit_is_main, kit_say, kit_warn
# shellcheck source=/dev/null
. "$_kit_ii_dir/integrations.sh"  # integration_validate, integration_file
# shellcheck source=/dev/null
. "$_kit_ii_dir/kit-state.sh"     # kit_state_file

_kit_ii_id_ok() { printf '%s' "${1:-}" | grep -qE '^[a-z][a-z0-9]*(-[a-z0-9]+)*$'; }

# _kit_ii_sh <dir> <command> -> run one descriptor command in dir with ~/.local/bin appended to
# PATH. stdin is /dev/null so an installer can neither block on a prompt nor eat the caller's
# stdin; stdout goes to stderr so the caller's stdout stays the one status line.
_kit_ii_sh() {
  ( cd "$1" 2>/dev/null && PATH="$PATH:$HOME/.local/bin" sh -c "$2" ) </dev/null >&2
}

# ── consent ────────────────────────────────────────────────────────────────────────────────────
integration_consent_file() {
  local d="${1:-$PWD}"
  ( cd "$d" 2>/dev/null && kit_state_file consent )
}

integration_consent_has() {
  local id="${1:-}" f
  _kit_ii_id_ok "$id" || return 1
  f="$(integration_consent_file "${2:-$PWD}")" || return 1
  [ -f "$f" ] || return 1
  grep -qxF -- "install:$id" "$f" 2>/dev/null
}

integration_consent_record() {
  local id="${1:-}" d="${2:-$PWD}" f
  _kit_ii_id_ok "$id" || { kit_warn "integration consent: '$id' is not an integration id"; return 1; }
  if integration_consent_has "$id" "$d"; then return 0; fi
  f="$(integration_consent_file "$d")" || return 1
  mkdir -p "$(dirname "$f")" 2>/dev/null || { kit_warn "integration consent: cannot create $(dirname "$f")"; return 1; }
  printf 'install:%s\n' "$id" >> "$f" 2>/dev/null || { kit_warn "integration consent: cannot write $f"; return 1; }
}

# ── detect ─────────────────────────────────────────────────────────────────────────────────────
integration_bin() {
  local f="${1:-}" name
  [ -f "$f" ] || return 1
  name="$(jq -r '.detect.bin // (.detect.run | split(" ")[0]) // ""' "$f" 2>/dev/null)" || return 1
  [ -n "$name" ] || return 1
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return 0; fi
  if [ -x "$HOME/.local/bin/$name" ]; then printf '%s\n' "$HOME/.local/bin/$name"; return 0; fi
  return 1
}

integration_detect() {
  local f="${1:-}" cmd
  [ -f "$f" ] || return 1
  cmd="$(jq -r '.detect.run // ""' "$f" 2>/dev/null)" || return 1
  [ -n "$cmd" ] || return 1
  _kit_ii_sh "${2:-$PWD}" "$cmd" >/dev/null 2>&1
}

# ── install ────────────────────────────────────────────────────────────────────────────────────
# integration_install_plan <file> [dir] -> what integration_install would do, on stdout.
integration_install_plan() {
  local f="${1:-}" d="${2:-$PWD}" id n i mgr run have wire
  [ -f "$f" ] || return 1
  id="$(jq -r '.id' "$f")"
  if integration_detect "$f" "$d"; then
    printf '%s: already installed (%s) — nothing to do\n' "$id" "$(integration_bin "$f" || jq -r '.detect.run' "$f")"
  else
    printf '%s: not installed. Candidates, tried in this order until one works:\n' "$id"
    n="$(jq '.install | length' "$f")"; i=0
    while [ "$i" -lt "$n" ]; do
      mgr="$(jq -r --argjson i "$i" '.install[$i].manager' "$f")"
      run="$(jq -r --argjson i "$i" '.install[$i].run' "$f")"
      have="skipped: $mgr is not on PATH"; command -v "$mgr" >/dev/null 2>&1 && have="$mgr is available"
      printf '  %s. %s   (%s)\n' "$((i + 1))" "$run" "$have"
      i=$((i + 1))
    done
    if ! _kit_ii_any_manager "$f"; then
      jq -r '.install[] | select(.bootstrap != null)
        | "  bootstrap, because none of those managers is on PATH: \(.bootstrap.run)   (needs \(.bootstrap.manager))"' "$f"
    fi
    if integration_consent_has "$id" "$d"; then printf '  consent: recorded in %s\n' "$(integration_consent_file "$d")"
    else printf '  consent: NOT recorded in %s — nothing installs without it\n' "$(integration_consent_file "$d")"; fi
  fi
  if wire="$(integration_wire_command "$f")"; then printf '  wire (in %s): %s\n' "$d" "$wire"; fi
  return 0
}

# _kit_ii_any_manager <file> -> rc 0 when at least one install candidate's manager is on PATH.
_kit_ii_any_manager() {
  local m
  for m in $(jq -r '.install[].manager' "$1" 2>/dev/null); do
    if command -v "$m" >/dev/null 2>&1; then return 0; fi
  done
  return 1
}

# _kit_ii_bootstrap <file> <dir> -> with no candidate manager on PATH, run the candidates'
# `bootstrap` commands in descriptor order until one puts a manager on PATH. rc 0 when a manager
# is then available. Only integration_install calls it, past the dry-run and consent gates.
_kit_ii_bootstrap() {
  local f="$1" d="$2" id n i bmgr brun
  id="$(jq -r '.id' "$f")"
  n="$(jq '.install | length' "$f")"; i=0
  while [ "$i" -lt "$n" ]; do
    bmgr="$(jq -r --argjson i "$i" '.install[$i].bootstrap.manager // ""' "$f")"
    brun="$(jq -r --argjson i "$i" '.install[$i].bootstrap.run // ""' "$f")"
    i=$((i + 1))
    [ -n "$bmgr" ] && [ -n "$brun" ] || continue
    command -v "$bmgr" >/dev/null 2>&1 || continue
    kit_say "integration $id: no installer on this machine — bootstrapping with $bmgr — $brun"
    _kit_ii_sh "$d" "$brun" 2>/dev/null || true
    if _kit_ii_any_manager "$f"; then return 0; fi
  done
  return 1
}

# integration_install <file> [dir] -> one status line on stdout (see the header).
integration_install() {
  local f="${1:-}" d="${2:-$PWD}" id n i mgr run resident tried=0
  if ! integration_validate "$f"; then printf 'failed\n'; return 1; fi
  id="$(jq -r '.id' "$f")"
  if integration_detect "$f" "$d"; then printf 'present\n'; return 0; fi
  if [ -n "${KIT_DRY_RUN:-}" ]; then
    integration_install_plan "$f" "$d" >&2
    printf 'dry-run\n'; return 0
  fi
  if ! integration_consent_has "$id" "$d"; then
    kit_say "integration $id: not installed — no consent recorded in $(integration_consent_file "$d")"
    printf 'no-consent\n'; return 0
  fi
  if ! _kit_ii_any_manager "$f"; then _kit_ii_bootstrap "$f" "$d" || true; fi
  n="$(jq '.install | length' "$f")"; i=0
  while [ "$i" -lt "$n" ]; do
    mgr="$(jq -r --argjson i "$i" '.install[$i].manager' "$f")"
    run="$(jq -r --argjson i "$i" '.install[$i].run' "$f")"
    resident="$(jq -r --argjson i "$i" '.install[$i] | if has("resident") then .resident else true end' "$f")"
    i=$((i + 1))
    command -v "$mgr" >/dev/null 2>&1 || continue
    tried=$((tried + 1))
    kit_say "integration $id: installing with $mgr — $run"
    if _kit_ii_sh "$d" "$run" 2>/dev/null; then
      # A candidate marked resident:false (npx) leaves no binary to detect; its exit code is the
      # only evidence there is.
      if [ "$resident" = "false" ] || integration_detect "$f" "$d"; then
        printf 'installed %s\n' "$mgr"; return 0
      fi
      kit_say "integration $id: $mgr exited 0 but the tool is still not detected — trying the next candidate"
    else
      kit_say "integration $id: $mgr failed — trying the next candidate"
    fi
  done
  if [ "$tried" -eq 0 ]; then
    kit_say "integration $id: none of its installers is on PATH ($(jq -r '[.install[].manager] | join(", ")' "$f"))"
  else
    kit_say "integration $id: no candidate left the tool installed. Install it by hand: $(jq -r '.install[0].run' "$f")"
  fi
  printf 'failed\n'; return 1
}

# ── wire ───────────────────────────────────────────────────────────────────────────────────────
# integration_wire_command <file> -> `wire.run` followed by every key of `wire.declined`, in the
# order the descriptor writes them. The keys are the flags that turn a tool feature OFF; the
# values are the reasons, for the reader, and never reach the command line.
integration_wire_command() {
  local f="${1:-}"
  [ -f "$f" ] || return 1
  jq -er 'select(.wire.run != null) | [.wire.run] + ((.wire.declined // {}) | keys_unsorted) | join(" ")' "$f" 2>/dev/null || return 1
}

# integration_wire <file> [dir] -> run the wire step in dir. Not gated on detect: the step writes
# into the project, so whether a re-run is a no-op is the tool's contract, not this runner's.
integration_wire() {
  local f="${1:-}" d="${2:-$PWD}" id cmd
  if ! integration_validate "$f"; then printf 'failed\n'; return 1; fi
  id="$(jq -r '.id' "$f")"
  if ! cmd="$(integration_wire_command "$f")"; then printf 'none\n'; return 0; fi
  if [ -n "${KIT_DRY_RUN:-}" ]; then
    kit_say "integration $id: would run in $d — $cmd"
    printf 'dry-run\n'; return 0
  fi
  if ! integration_consent_has "$id" "$d"; then
    kit_say "integration $id: not wired — no consent recorded in $(integration_consent_file "$d")"
    printf 'no-consent\n'; return 0
  fi
  kit_say "integration $id: wiring in $d — $cmd"
  if _kit_ii_sh "$d" "$cmd"; then printf 'wired\n'; return 0; fi
  kit_say "integration $id: the wire command failed"
  printf 'failed\n'; return 1
}

_kit_ii_main() {
  local f
  case "${1:-}" in
    --plan)         f="$(_kit_ig_arg "${2:-}")" || return 1; integration_install_plan "$f" "${3:-$PWD}" ;;
    --install)      f="$(_kit_ig_arg "${2:-}")" || return 1; integration_install "$f" "${3:-$PWD}" ;;
    --wire)         f="$(_kit_ig_arg "${2:-}")" || return 1; integration_wire "$f" "${3:-$PWD}" ;;
    --wire-command) f="$(_kit_ig_arg "${2:-}")" || return 1; integration_wire_command "$f" ;;
    --consent)      integration_consent_record "${2:-}" "${3:-$PWD}" ;;
    *) kit_warn "usage: integration-install.sh --plan|--install|--wire <id|file> [dir] | --wire-command <id|file> | --consent <id> [dir]"; return 2 ;;
  esac
}

if kit_is_main; then _kit_ii_main "$@"; fi
