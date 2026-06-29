#!/usr/bin/env bash
# kit-add.sh — stack a MODULE onto a project (D1 "modules apilables", #372).  e.g. `kit add software`.
#
# THE MOMENT: a free workspace ("build me an app") becomes a GitHub-managed software island WITHOUT
# restructuring anything above it (D4/D17). A module is identity, not a file dump (D14): kit-add
# writes the island's .claude/kit.config.json (modules[] + wizard answers) through the F0 operation
# machine, so it is manifest-tracked, idempotent (2x = no-op), dry-runnable, and removable. The
# engine (agents/skills) is the installed plugin singleton — it is never copied per project.
#
# The ASKING (the wizard) is interactive and portable, so the kit-onboard skill / the /kit-add
# command render it via AskUserQuestion and pass answers here as a file. This script also takes a
# minimal terminal fallback so it stands alone.
#
# Run:
#   scripts/kit-add.sh software [--dir DIR] --answers FILE     # non-interactive (skill/CI/tests)
#   scripts/kit-add.sh software --set versioning=github --set deploy=vercel --set ci=github-actions
#   KIT_ASSUME_YES=1 scripts/kit-add.sh software               # accept every recommended default
#   KIT_DRY_RUN=1 scripts/kit-add.sh software                  # preview only
# Requires: jq.

set -uo pipefail
_add_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_add_dir/lib/kit-interview.sh"   # catalog/apply (pulls kit-cli + kit-profile)
# shellcheck source=/dev/null
. "$_add_dir/lib/kit-operate.sh"     # four-beat machine + manifest

# kit_add_module_exists <module> -> rc 0 if a module spec is installed
kit_add_module_exists() { [ -f "$(kit_interview_catalog_file "$1")" ]; }

# kit_add <module> <answersfile> [targetdir]
# Merges the module's wizard answers onto the island config and persists via kit-operate.
kit_add() {
  command -v jq >/dev/null 2>&1 || { kit_die "jq required"; }
  local module="$1" answers="$2" target="${3:-$PWD}"
  [ -n "$module" ] || kit_die "usage: kit-add.sh <module> [--dir DIR] [--answers FILE | --set k=v ...]"
  kit_add_module_exists "$module" || kit_die "unknown module '$module' (no $(kit_interview_catalog_file "$module"))"
  [ -f "$answers" ] || kit_die "internal: answers file missing ($answers)"

  # Operate + manifest are relative to the island root — work from there.
  target="$(cd "$target" 2>/dev/null && pwd)" || kit_die "no such dir: $target"
  cd "$target" || kit_die "cannot enter $target"

  local cfg=".claude/kit.config.json" base merged tmp
  base=""; [ -f "$cfg" ] && base="$cfg"
  merged="$(kit_interview_apply "$module" "$answers" "$base")" || kit_die "deriving module config failed"
  # Belt-and-suspenders: guarantee the module name is in modules[] even if the spec omitted it.
  merged="$(printf '%s' "$merged" | jq --arg m "$module" '.modules = ((.modules // []) + [$m] | unique)')"

  kit_say "kit add $module  ->  $target/$cfg"
  printf '%s\n' "$merged" | kit_op_write_content "$cfg" A "add:$module"
  local rc=$?
  case $rc in
    0)  kit_say "module '$module' active here. modules: $(printf '%s' "$merged" | jq -c '.modules')";;
    10) kit_say "no change (already applied / declined / dry-run).";;
    *)  kit_die "failed to write $cfg";;
  esac
  return 0
}

# --- collect answers from flags / env / minimal terminal fallback ---------
# Builds a {key:value} JSON. Precedence: --answers FILE, then --set overrides, then for any unset
# question: KIT_ASSUME_YES/non-tty -> default; tty -> ask once with the recommended default.
_kit_add_collect() {
  local module="$1" answers_file="$2"; shift 2
  # All locals up front — a bare `local x` re-run in a loop prints the var under zsh (typeset-like).
  local sets=("$@")
  local catalog acc kv k v tmp nq i key def have pick qtext r
  catalog="$(kit_interview_catalog "$module")" || return 1
  acc="$(mktemp)"
  if [ -n "$answers_file" ] && [ -f "$answers_file" ]; then cp "$answers_file" "$acc"; else printf '{}\n' > "$acc"; fi
  # apply --set k=v
  for kv in ${sets[@]+"${sets[@]}"}; do
    k="${kv%%=*}"; v="${kv#*=}"
    tmp="$(mktemp)"; jq --arg k "$k" --arg v "$v" '.[$k]=$v' "$acc" > "$tmp" && mv "$tmp" "$acc"
  done
  # fill the rest
  nq="$(printf '%s' "$catalog" | jq '.questions | length')"; i=0
  while [ "$i" -lt "$nq" ]; do
    key="$(printf '%s' "$catalog" | jq -r ".questions[$i].key")"
    def="$(printf '%s' "$catalog" | jq -r ".questions[$i].default // \"\"")"
    have="$(jq -r --arg k "$key" '.[$k] // empty' "$acc")"
    if [ -z "$have" ]; then
      pick="$def"
      if [ -z "${KIT_ASSUME_YES:-}" ] && [ -z "${KIT_DRY_RUN:-}" ] && [ -t 0 ]; then
        qtext="$(printf '%s' "$catalog" | jq -r ".questions[$i].question")"
        printf '%s [%s] ' "$qtext" "$def" >&2
        r=""; IFS= read -r r </dev/tty 2>/dev/null || r=""
        [ -n "$r" ] && pick="$r"
      fi
      tmp="$(mktemp)"; jq --arg k "$key" --arg v "$pick" '.[$k]=$v' "$acc" > "$tmp" && mv "$tmp" "$acc"
    fi
    i=$((i+1))
  done
  printf '%s\n' "$acc"   # caller reads the path, then removes it
}

# CLI
if kit_is_main; then
  _module=""; _target="$PWD"; _answers=""; _sets=()
  while [ $# -gt 0 ]; do case "$1" in
    --dir) _target="$2"; shift 2;;
    --answers) _answers="$2"; shift 2;;
    --set) _sets+=("$2"); shift 2;;
    -h|--help) echo "usage: kit-add.sh <module> [--dir DIR] [--answers FILE] [--set k=v ...]   (env: KIT_ASSUME_YES, KIT_DRY_RUN)"; exit 0;;
    -*) kit_die "unknown flag: $1";;
    *) [ -z "$_module" ] && _module="$1" || kit_die "unexpected arg: $1"; shift;;
  esac; done
  [ -n "$_module" ] || kit_die "usage: kit-add.sh <module> [--dir DIR] [--answers FILE] [--set k=v ...]"
  kit_add_module_exists "$_module" || kit_die "unknown module '$_module'"
  _af="$(_kit_add_collect "$_module" "$_answers" ${_sets[@]+"${_sets[@]}"})" || kit_die "collecting answers failed"
  kit_add "$_module" "$_af" "$_target"; _rc=$?
  rm -f "$_af"
  exit $_rc
fi
