#!/usr/bin/env bash
# kit-profile.sh — the global, per-USER profile (D7, O8, #372).
#
# THE MODEL: the wide-range interview runs ONCE in a user's life and writes a global profile at
#   ~/.claude/kit.profile.<user>.json
# Multi-user by file (D7): the <user> slug names the file, so two humans on one machine never clash.
# This profile is the FAR end of the cascade — kit-config-resolve reads project layers on top of it,
# and the per-project interview (tier 2) pre-fills its answers FROM this profile. It lives in the
# user's home, OUTSIDE any project, so it is NOT manifest-tracked (the manifest is project-scoped).
#
# Source it:  source scripts/lib/kit-profile.sh
# CLI:        scripts/lib/kit-profile.sh [--user U] [--path | --user-slug | --show | --get JQPATH]
# Requires: jq.

_kit_profile_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_kit_profile_dir/kit-cli.sh"   # kit_is_main, kit_say/warn/die

KIT_PROFILE_SCHEMA=1

_kit_profile_require() { command -v jq >/dev/null 2>&1 || { kit_warn "kit-profile: jq is required"; return 1; }; }

# kit_profile_slugify <text> -> lower-kebab slug (ASCII; drops non-alnum). Matches kit-task-start.
kit_profile_slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'
}

# kit_profile_user_slug [explicit] -> the <user> slug for the profile filename (O8).
# Source cascade: explicit arg > $KIT_PROFILE_USER > git config user.name > $USER/$LOGNAME > "user".
# Always normalized to a slug. The tier-1 interview can confirm/override before first write.
kit_profile_user_slug() {
  local raw="${1:-${KIT_PROFILE_USER:-}}"
  if [ -z "$raw" ]; then raw="$(git config user.name 2>/dev/null || true)"; fi
  if [ -z "$raw" ]; then raw="${USER:-${LOGNAME:-}}"; fi
  [ -z "$raw" ] && raw="user"
  local slug; slug="$(kit_profile_slugify "$raw")"
  [ -z "$slug" ] && slug="user"
  printf '%s\n' "$slug"
}

# kit_profile_home -> the dir that holds profiles. Override with KIT_PROFILE_HOME (tests use this).
kit_profile_home() { printf '%s\n' "${KIT_PROFILE_HOME:-$HOME/.claude}"; }

# kit_profile_path [user] -> absolute path of the user's global profile JSON.
kit_profile_path() {
  local u; u="$(kit_profile_user_slug "${1:-}")"
  printf '%s/kit.profile.%s.json\n' "$(kit_profile_home)" "$u"
}

# kit_profile_exists [user] -> rc 0 if the profile file is present (drives "once in a lifetime").
kit_profile_exists() { [ -f "$(kit_profile_path "${1:-}")" ]; }

# kit_profile_init [user] -> create an empty, schema'd profile if none exists. Idempotent.
kit_profile_init() {
  _kit_profile_require || return 1
  local p; p="$(kit_profile_path "${1:-}")"
  [ -f "$p" ] && return 0
  mkdir -p "$(dirname "$p")" || return 1
  local u; u="$(kit_profile_user_slug "${1:-}")"
  jq -n --argjson s "$KIT_PROFILE_SCHEMA" --arg u "$u" --arg v "${KIT_VERSION:-0.0.0}" \
    '{schema:$s, user:$u, defaults:{}, createdWith:$v}' > "$p"
}

# kit_profile_read [user] -> the profile JSON ({} if absent)
kit_profile_read() {
  _kit_profile_require || return 1
  local p; p="$(kit_profile_path "${1:-}")"
  if [ -f "$p" ]; then cat "$p"; else printf '{}\n'; fi
}

# kit_profile_get <jqpath> [user] -> a resolved value (raw, empty if unset)
kit_profile_get() {
  _kit_profile_require || return 1
  kit_profile_read "${2:-}" | jq -r "$1 // empty"
}

# kit_profile_set <dotpath> <value> [valtype string|bool|number] [user]
# Merge a single value into the profile (deep, by path). Creates the profile if missing.
kit_profile_set() {
  _kit_profile_require || return 1
  local dotpath="$1" value="$2" valtype="${3:-string}" user="${4:-}"
  [ -n "$dotpath" ] || { kit_warn "kit-profile set: path required"; return 1; }
  kit_profile_init "$user" || return 1
  local p tmp; p="$(kit_profile_path "$user")"; tmp="$(mktemp)" || return 1
  # "a.b.c" -> a jq setpath array  ["a","b","c"]   (var named dotpath: `path` is $PATH-tied in zsh)
  local setexpr
  setexpr="$(printf '%s' "$dotpath" | awk -F. '{out="["; for(i=1;i<=NF;i++){ if(i>1)out=out","; out=out"\""$i"\""}; out=out"]"; print out}')"
  case "$valtype" in
    bool|boolean|number|int) jq --argjson v "$value" "setpath($setexpr; \$v)" "$p" > "$tmp" || { rm -f "$tmp"; return 1; };;
    *)                       jq --arg     v "$value" "setpath($setexpr; \$v)" "$p" > "$tmp" || { rm -f "$tmp"; return 1; };;
  esac
  mv "$tmp" "$p"
}

# CLI — direct execution only.
if kit_is_main; then
  _u=""; _mode="path"; _arg=""
  while [ $# -gt 0 ]; do case "$1" in
    --user) _u="$2"; shift 2;;
    --path) _mode="path"; shift;;
    --user-slug) _mode="slug"; shift;;
    --show) _mode="show"; shift;;
    --get) _mode="get"; _arg="$2"; shift 2;;
    -h|--help) echo "usage: kit-profile.sh [--user U] [--path|--user-slug|--show|--get JQPATH]"; exit 0;;
    *) kit_warn "unknown arg: $1"; exit 2;;
  esac; done
  case "$_mode" in
    path) kit_profile_path "$_u";;
    slug) kit_profile_user_slug "$_u";;
    show) kit_profile_read "$_u";;
    get)  kit_profile_get "$_arg" "$_u";;
  esac
fi
