#!/usr/bin/env bash
# integrations.sh — the integration registry: one JSON descriptor per optional third-party tool
# in integrations/ at the plugin root, beside modules/ and interview/ (E303.1).
#
# A descriptor is DATA: label, the config key that turns the tool on, a detect command, ordered
# install candidates, a verify command, a docs link, an attribution block, and an optional
# applicability predicate. This file reads and checks that data. It installs nothing and writes
# nothing — the runner that acts on a descriptor is a separate lib.
#
# Source it:  source scripts/lib/integrations.sh
#   integrations_dir                      where descriptors live ($KIT_INTEGRATIONS_DIR overrides)
#   integrations_list                     descriptor ids, sorted, one per line
#   integration_file <id>                 path of one descriptor; rc 1 when there is none
#   integration_validate <file>           rc 0, or rc 1 with one `<id>: <field>: <problem>` line
#                                         per problem on stderr
#   integrations_validate_all             validate every descriptor; rc 1 if any fails
#   integration_applies <file> [dir]      rc 0 when the tool can work on the repo at dir, on this
#                                         machine
#   integration_applies_needs <file>      the descriptor's conditions in words, for a decline message
#   integration_config_key <file>         the dotted config key that turns it on
#   integration_enabled <file> [config]   rc 0 when that key holds the descriptor's ON value, or
#                                         is absent and the descriptor is on by default
#   integration_default_on <file>         rc 0 when the descriptor sets `config.default: true`
#   integration_explicit <file> [config]  rc 0 when the config holds the key at all
# CLI:        integrations.sh --list
#             integrations.sh --validate [id|file]
#             integrations.sh --applies <id|file> [dir]
# Requires: jq. bash 3.2 + zsh compatible.
# errors: pure — reads descriptors and the repo's file list; rc reports the answer, nothing is written

_kit_ig_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_kit_ig_dir/kit-cli.sh"      # kit_is_main, kit_warn
# shellcheck source=/dev/null
. "$_kit_ig_dir/config-path.sh"  # kit_config_path

_kit_ig_schema_name="integration.schema.json"

_kit_ig_require() { command -v jq >/dev/null 2>&1 || { kit_warn "integrations: jq is required"; return 1; }; }

# integrations_dir -> the descriptor directory. Plugin root = two levels up from scripts/lib/.
integrations_dir() {
  if [ -n "${KIT_INTEGRATIONS_DIR:-}" ]; then printf '%s\n' "$KIT_INTEGRATIONS_DIR"; return 0; fi
  if [ -n "${KIT_PLUGIN_ROOT:-}" ]; then printf '%s/integrations\n' "$KIT_PLUGIN_ROOT"; return 0; fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf '%s/integrations\n' "$CLAUDE_PLUGIN_ROOT"; return 0; fi
  printf '%s/integrations\n' "$(CDPATH='' cd -- "$_kit_ig_dir/../.." && pwd)"
}

# integrations_list -> ids, sorted. The schema lives in the same dir and is not a descriptor.
# `find`, not a glob: an unmatched glob is an error under zsh, and an empty registry is valid.
integrations_list() {
  local d; d="$(integrations_dir)"
  [ -d "$d" ] || return 0
  find "$d" -maxdepth 1 -type f -name '*.json' ! -name "$_kit_ig_schema_name" 2>/dev/null \
    | sed -e 's#.*/##' -e 's#\.json$##' | sort
}

# integration_file <id> -> path. The id is checked against the id grammar first, so an argument
# like `../x` can never resolve to a file outside the registry.
integration_file() {
  local id="${1:-}" f
  printf '%s' "$id" | grep -qE '^[a-z][a-z0-9]*(-[a-z0-9]+)*$' || return 1
  f="$(integrations_dir)/$id.json"
  [ -f "$f" ] || return 1
  printf '%s\n' "$f"
}

# The schema checker. integration.schema.json is the one statement of the format; this walks a
# descriptor against it instead of restating the required fields in bash. It implements the
# keywords the schema uses and no others (the schema's own description lists them).
# shellcheck disable=SC2016
_kit_ig_check_jq='
def at($p; $k): if $p == "" then $k else "\($p).\($k)" end;
def chk($s; $p):
  . as $v | ($v | type) as $vt
  | (if ($s | has("type")) and $vt != $s.type
     then "\(if $p == "" then "(descriptor)" else $p end): expected \($s.type), got \($vt)" else empty end),
    (if ($s | has("enum")) and (any($s.enum[]; . == $v) | not)
     then "\($p): must be one of \($s.enum | map(tostring) | join(", "))" else empty end),
    (if $vt == "string" then
       (if ($s | has("minLength")) and ($v | length) < $s.minLength then "\($p): must not be empty" else empty end),
       (if ($s | has("pattern")) and ($v | test($s.pattern) | not) then "\($p): does not match \($s.pattern)" else empty end)
     elif $vt == "array" then
       (if ($s | has("minItems")) and ($v | length) < $s.minItems
        then "\($p): needs at least \($s.minItems) item(s)" else empty end),
       (if ($s | has("items")) then ($v | to_entries[] | .key as $i | .value | chk($s.items; "\($p)[\($i)]")) else empty end)
     elif $vt == "object" and ($s.type // "") == "object" then
       (($s.required // [])[] | . as $k | select($v | has($k) | not) | "\(at($p; $k)): required field is missing"),
       (($s.properties // {}) | to_entries[] | .key as $k | .value as $sub
          | select($v | has($k)) | $v[$k] | chk($sub; at($p; $k))),
       (if $s.additionalProperties == false
        then ($v | keys[] | . as $k | select(($s.properties // {}) | has($k) | not) | "\(at($p; $k)): unknown field")
        else empty end)
     else empty end);
chk($schema[0]; ""),
# Two rules the schema cannot express.
(if (.id | type) == "string" and .id != $stem
 then "id: \($q)\(.id)\($q) must match the file name \($q)\($stem)\($q)" else empty end),
(if (.id | type) == "string" and (.config.key? | type) == "string"
    and ((.id | ascii_downcase | gsub("[^a-z0-9]"; "")) as $vendor
         | any(.config.key | ascii_downcase | split(".")[]; . == $vendor))
 then "config.key: names the tool (\(.config.key)) — name the capability, e.g. <capability>.provider" else empty end)
'

# integration_validate <file> -> rc 0 clean; rc 1 with one line per problem on stderr.
integration_validate() {
  _kit_ig_require || return 1
  local f="${1:-}" stem schema out
  [ -n "$f" ] && [ -f "$f" ] || { kit_warn "integrations: no descriptor at '${f}'"; return 1; }
  stem="$(basename "$f" .json)"
  schema="$(integrations_dir)/$_kit_ig_schema_name"
  [ -f "$schema" ] || { kit_warn "integrations: schema not found ($schema)"; return 1; }
  jq -e . "$f" >/dev/null 2>&1 || { printf '%s: not valid JSON\n' "$stem" >&2; return 1; }
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { printf '%s: (descriptor): expected object\n' "$stem" >&2; return 1; }
  out="$(jq -r --slurpfile schema "$schema" --arg stem "$stem" --arg q "'" "$_kit_ig_check_jq" "$f" 2>&1)" || {
    printf '%s: validator failed: %s\n' "$stem" "$out" >&2; return 1; }
  [ -z "$out" ] && return 0
  printf '%s\n' "$out" | sed "s#^#$stem: #" >&2
  return 1
}

# integrations_validate_all -> rc 0 when every descriptor is clean (an empty registry is clean).
integrations_validate_all() {
  local id bad=0
  for id in $(integrations_list); do
    integration_validate "$(integrations_dir)/$id.json" || bad=1
  done
  return "$bad"
}

# _kit_ig_repo_files <dir> -> the files a tool would see, one per line. Inside a git work tree
# that is git's own list (tracked + untracked, minus ignored), so build output and dependencies
# never make a tool look applicable. Outside one, every file except .git/ and node_modules/.
_kit_ig_repo_files() {
  local d="$1"
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$d" ls-files -co --exclude-standard 2>/dev/null
  else
    find "$d" -type f ! -path '*/.git/*' ! -path '*/node_modules/*' 2>/dev/null
  fi
}

# integration_applies <file> [dir] -> rc 0 when the tool can work on the repo at dir, on this
# machine. No `appliesWhen` = applies anywhere. Two kinds of condition; every one present must hold:
#   platform      `os` / `arch` equal `uname -s` / `uname -m` verbatim (the machine, not the repo)
#   anyExtension  at least one file ends in a listed extension (case-sensitive; a dotfile named
#                 exactly `.ts` has no extension)
# rc 1 otherwise, including an absent dir when the repo is what is being judged.
integration_applies() {
  _kit_ig_require || return 1
  local f="${1:-}" d="${2:-$PWD}" exts want_os want_arch
  [ -f "$f" ] || return 1
  want_os="$(jq -r '.appliesWhen.platform.os // ""' "$f" 2>/dev/null)" || return 1
  want_arch="$(jq -r '.appliesWhen.platform.arch // ""' "$f" 2>/dev/null)" || return 1
  if [ -n "$want_os" ] && [ "$(uname -s 2>/dev/null)" != "$want_os" ]; then return 1; fi
  if [ -n "$want_arch" ] && [ "$(uname -m 2>/dev/null)" != "$want_arch" ]; then return 1; fi
  exts="$(jq -r '.appliesWhen.anyExtension // [] | join(" ")' "$f" 2>/dev/null)" || return 1
  [ -n "$exts" ] || return 0
  [ -d "$d" ] || return 1
  # The whole list is read (no early exit): closing the pipe early would SIGPIPE the lister and
  # turn a match into a failure for a caller running under `pipefail`.
  _kit_ig_repo_files "$d" | awk -v exts="$exts" '
    BEGIN { n = split(exts, a, " "); for (i = 1; i <= n; i++) want[a[i]] = 1 }
    { b = $0; sub(/.*\//, "", b); i = match(b, /\.[^.]*$/); if (i > 1 && (substr(b, i) in want)) found = 1 }
    END { exit(found ? 0 : 1) }'
}

# integration_applies_needs <file> -> what the descriptor requires, in words, on one line. Empty
# when it has no `appliesWhen`. The one wording every decline message uses.
integration_applies_needs() {
  _kit_ig_require || return 1
  [ -f "${1:-}" ] || return 1
  jq -r '(.appliesWhen // {}) as $a
    | [ (($a.platform // {}) | [.os // empty, .arch // empty] | select(length > 0)
          | "a " + join(" ") + " machine"),
        (($a.anyExtension // []) | select(length > 0)
          | "at least one file ending in: " + join(" ")) ]
    | join(", and ")' "$1" 2>/dev/null
}

# integration_config_key <file> -> the dotted key, e.g. codeGraph.provider
integration_config_key() {
  _kit_ig_require || return 1
  jq -er '.config.key' "${1:-}" 2>/dev/null
}

# integration_enabled <file> [config] -> rc 0 when the project config holds the descriptor's ON
# value at its key (`config.value`, or boolean true when the descriptor names none). Another value
# or no config file at all is rc 1. An unset key is rc 1 too — off is the default, never an error —
# unless the descriptor sets `config.default: true`, which makes the unset key ON.
integration_enabled() {
  _kit_ig_require || return 1
  local f="${1:-}" cfg="${2:-}"
  [ -f "$f" ] || return 1
  [ -n "$cfg" ] || cfg="$(kit_config_path 2>/dev/null)" || return 1
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 1
  jq -e --slurpfile d "$f" '
    ($d[0].config) as $c
    | (if ($c | has("value")) then $c.value else true end) as $on
    | (try getpath($c.key | split(".")) catch null) as $v
    | if $v == null then ($c.default == true) else $v == $on end' "$cfg" >/dev/null 2>&1
}

# integration_default_on <file> -> rc 0 when the descriptor is on by default (`config.default`
# is true): on wherever the config does not hold its key.
integration_default_on() {
  _kit_ig_require || return 1
  [ -f "${1:-}" ] || return 1
  jq -e '.config.default == true' "$1" >/dev/null 2>&1
}

# integration_explicit <file> [config] -> rc 0 when the project config HOLDS the descriptor's key,
# whatever its value. rc 1 for an absent key or no config: the difference between a project that
# chose the tool and one that only inherits a default.
integration_explicit() {
  _kit_ig_require || return 1
  local f="${1:-}" cfg="${2:-}"
  [ -f "$f" ] || return 1
  [ -n "$cfg" ] || cfg="$(kit_config_path 2>/dev/null)" || return 1
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 1
  jq -e --slurpfile d "$f" '(try getpath($d[0].config.key | split(".")) catch null) != null' "$cfg" >/dev/null 2>&1
}

# _kit_ig_arg <id|file> -> a descriptor path from either form.
_kit_ig_arg() {
  if [ -f "${1:-}" ]; then printf '%s\n' "$1"; return 0; fi
  integration_file "${1:-}" || { kit_warn "integrations: no integration '${1:-}'"; return 1; }
}

_kit_ig_main() {
  local f
  case "${1:-}" in
    --list) integrations_list ;;
    --validate)
      if [ -n "${2:-}" ]; then f="$(_kit_ig_arg "$2")" || return 1; integration_validate "$f"
      else integrations_validate_all; fi ;;
    --applies)
      f="$(_kit_ig_arg "${2:-}")" || return 1
      integration_applies "$f" "${3:-$PWD}" ;;
    *) kit_warn "usage: integrations.sh --list | --validate [id|file] | --applies <id|file> [dir]"; return 2 ;;
  esac
}

if kit_is_main; then _kit_ig_main "$@"; fi
