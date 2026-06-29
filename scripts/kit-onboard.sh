#!/usr/bin/env bash
# kit-onboard.sh — persist two-tier interview answers (D11, #372). The ASKING is the kit-onboard
# skill (AskUserQuestion, Tier A). This script is the deterministic persistence half:
#
#   global   answers -> ~/.claude/kit.profile.<user>.json   (the once-in-a-lifetime profile, D7)
#   project  answers -> ./.claude/kit.config.json           (manifest-tracked via kit-operate)
#
# Split this way the persistence is unit-testable under bash AND zsh; the skill only renders.
#
# Run:
#   scripts/kit-onboard.sh global  --answers FILE [--user U]
#   scripts/kit-onboard.sh project --answers FILE [--dir DIR]
#   scripts/kit-onboard.sh status                  # has the global profile been created?
# Env: KIT_ASSUME_YES / KIT_DRY_RUN (project tier, via kit-operate).  Requires: jq.

set -uo pipefail
_ob_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_ob_dir/lib/kit-interview.sh"   # catalog/apply (pulls kit-cli + kit-profile)
# shellcheck source=/dev/null
. "$_ob_dir/lib/kit-operate.sh"     # four-beat machine + manifest (project tier)

# kit_onboard_global <answersfile> [user]
# Ensure the profile exists (schema + user + slug), then merge the global-tier answers onto it.
kit_onboard_global() {
  command -v jq >/dev/null 2>&1 || kit_die "jq required"
  local answers="$1" user="${2:-}"
  [ -f "$answers" ] || kit_die "answers file missing: $answers"
  kit_profile_init "$user" || kit_die "could not init profile"
  local p merged tmp; p="$(kit_profile_path "$user")"
  merged="$(kit_interview_apply global "$answers" "$p")" || kit_die "deriving global profile failed"
  tmp="$(mktemp)"; printf '%s\n' "$merged" > "$tmp" && mv "$tmp" "$p" || { rm -f "$tmp"; kit_die "write failed"; }
  kit_say "global profile updated: $p"
}

# kit_onboard_project <answersfile> [targetdir]
# Merge the project-tier answers onto ./.claude/kit.config.json through kit-operate (manifest).
kit_onboard_project() {
  command -v jq >/dev/null 2>&1 || kit_die "jq required"
  local answers="$1" target="${2:-$PWD}"
  [ -f "$answers" ] || kit_die "answers file missing: $answers"
  target="$(cd "$target" 2>/dev/null && pwd)" || kit_die "no such dir: $target"
  cd "$target" || kit_die "cannot enter $target"
  local cfg=".claude/kit.config.json" base merged
  base=""; [ -f "$cfg" ] && base="$cfg"
  merged="$(kit_interview_apply project "$answers" "$base")" || kit_die "deriving project config failed"
  kit_say "kit onboard project  ->  $target/$cfg"
  printf '%s\n' "$merged" | kit_op_write_content "$cfg" A onboard
  case $? in 0|10) return 0;; *) kit_die "failed to write $cfg";; esac
}

# CLI
if kit_is_main; then
  _sub="${1:-}"; shift 2>/dev/null || true
  _answers=""; _user=""; _dir="$PWD"
  while [ $# -gt 0 ]; do case "$1" in
    --answers) _answers="$2"; shift 2;;
    --user) _user="$2"; shift 2;;
    --dir) _dir="$2"; shift 2;;
    -h|--help) echo "usage: kit-onboard.sh global|project|status [--answers F] [--user U] [--dir D]"; exit 0;;
    *) kit_die "unknown arg: $1";;
  esac; done
  case "$_sub" in
    global)  kit_onboard_global  "$_answers" "$_user";;
    project) kit_onboard_project "$_answers" "$_dir";;
    status)  if kit_profile_exists "$_user"; then echo "profile: $(kit_profile_path "$_user") (exists)"; else echo "profile: none yet — run the global interview"; exit 1; fi;;
    *) kit_die "usage: kit-onboard.sh global|project|status ...";;
  esac
fi
