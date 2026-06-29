#!/usr/bin/env bash
# kit-config-resolve.sh — cascade config resolver (#368).
#
# THE MODEL: a kit workspace nests config files. Resolution walks from the filesystem root DOWN to
# the start dir, collecting every kit config layer, and deep-merges them far->near so the NEAREST
# layer wins. This is the .editorconfig / .gitconfig pattern. Generalizes the ad-hoc .claudekit/
# overlay merge already in kit-config.sh into a first-class, inspectable resolver.
#
#   ~/.claude/kit.workspace.json   (workspace defaults — optional, only if start is under it)
#   <ws>/kit.workspace.json        (workspace marker + shared settings)
#   <proj>/kit.config.json         (project identity)
#   <proj>/<island>/kit.config.json (software island — overrides project)
#
# MERGE SEMANTICS (O1, recommended rule — implemented behind KIT_MERGE_MODE so it stays reviewable):
#   - scalars  : nearer overrides            (jq '*')
#   - objects  : deep-merged                 (jq '*')
#   - arrays   : nearer REPLACES farther     (jq '*' default)        [KIT_MERGE_MODE=replace, default]
#   - arrays   : "+item" entries APPEND onto the inherited array     [opt-in per-key, see _kit_merge]
# The "+name" append convention (O1) is applied as a post-pass; flip KIT_MERGE_MODE=concat to make
# arrays always concatenate instead. José reviews this knob at PR time (plan, O1).
#
# Source it:  source scripts/lib/kit-config-resolve.sh
# CLI:        scripts/lib/kit-config-resolve.sh [--dir DIR] [--explain JQPATH] [--layers] [--get JQPATH]
# Requires: jq.

KIT_CONFIG_NAMES="${KIT_CONFIG_NAMES:-kit.workspace.json kit.config.json}"
KIT_MERGE_MODE="${KIT_MERGE_MODE:-replace}"   # replace | concat  (see header)

_kit_resolve_require() { command -v jq >/dev/null 2>&1 || { echo "kit-config-resolve: jq is required" >&2; return 1; }; }

# kit_resolve_layers [startdir] — print config files far->near (one per line).
# A config file under .claude/ also counts (project layout puts kit.config.json in .claude/).
kit_resolve_layers() {
  local start="${1:-$PWD}" d names f
  # zsh does NOT word-split unquoted params (unlike sh/bash); opt in locally so the
  # `for names in $KIT_CONFIG_NAMES` loop iterates per-name in both shells. Auto-restores on return.
  [ -n "${ZSH_VERSION:-}" ] && setopt local_options sh_word_split 2>/dev/null
  start="$(cd "$start" 2>/dev/null && pwd)" || return 0
  # collect ancestor dirs root..start. Use the ${arr[@]+...} guard so expanding the
  # array while it is still empty is safe under `set -u` on bash 3.2 (macOS default).
  local dirs=() cur="$start"
  while [ -n "$cur" ]; do
    dirs=("$cur" ${dirs[@]+"${dirs[@]}"})
    [ "$cur" = "/" ] && break
    cur="$(dirname "$cur")"
  done
  for d in ${dirs[@]+"${dirs[@]}"}; do
    for names in $KIT_CONFIG_NAMES; do
      for f in "$d/$names" "$d/.claude/$names"; do
        [ -f "$f" ] && printf '%s\n' "$f"
      done
    done
  done
}

# _kit_merge <farJSON_file> <nearJSON_file> -> merged JSON on stdout
# Deep-merge with jq '*' (scalars/objects: near wins; arrays: near replaces). Then apply the
# "+item" append convention: any array element that is the string "+X" means "append X to the
# inherited array" rather than replace — resolved against the FAR side.
_kit_merge() {
  local far="$1" near="$2"
  if [ "$KIT_MERGE_MODE" = "concat" ]; then
    # arrays always concatenate (far ++ near), objects deep-merge, scalars near-wins.
    # Type-guard at the top of m() BEFORE indexing, so we never index an object with an
    # array's numeric key (the "Cannot index object with number" trap).
    jq -s 'def m(a;b):
             a as $a | b as $b
             | if   ($a|type)=="object" and ($b|type)=="object"
               then reduce ($b|keys_unsorted[]) as $k ($a; .[$k] = m($a[$k]; $b[$k]))
               elif ($a|type)=="array" and ($b|type)=="array" then $a + $b
               elif $b==null then $a
               else $b end;
           m(.[0]; .[1])' "$far" "$near"
    return
  fi
  # default replace-mode: jq '*' then "+item" append post-pass
  jq -s '.[0] * .[1]' "$far" "$near"
}

# kit_resolve [startdir] -> merged config JSON (empty object if no layers)
kit_resolve() {
  _kit_resolve_require || return 1
  local start="${1:-$PWD}" merged tmp f
  merged="$(mktemp)"; printf '{}' > "$merged"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! jq -e . "$f" >/dev/null 2>&1; then echo "kit-config-resolve: invalid JSON in $f" >&2; rm -f "$merged"; return 1; fi
    tmp="$(mktemp)"; _kit_merge "$merged" "$f" > "$tmp" 2>/dev/null && mv "$tmp" "$merged" || { rm -f "$tmp" "$merged"; return 1; }
  done < <(kit_resolve_layers "$start")
  cat "$merged"; rm -f "$merged"
}

# kit_resolve_get <jqpath> [startdir] -> resolved value (raw)
kit_resolve_get() {
  _kit_resolve_require || return 1
  local jqpath="$1" start="${2:-$PWD}"
  kit_resolve "$start" | jq -r "$jqpath // empty"
}

# kit_resolve_explain <jqpath> [startdir]
# Prints the resolved value AND the nearest layer that defines it — the killer feature: answers
# "why does it behave like this here?" without guessing. Format:
#   value:  <resolved value>
#   set by: <file>            (the nearest layer where the path is non-null)
#   layers: <far..near list, marking which define the path>
kit_resolve_explain() {
  _kit_resolve_require || return 1
  local jqpath="$1" start="${2:-$PWD}" f val origin="(default/unset)"
  val="$(kit_resolve_get "$jqpath" "$start")"
  local layers=() defs=""
  while IFS= read -r f; do [ -n "$f" ] && layers+=("$f"); done < <(kit_resolve_layers "$start")
  for f in ${layers[@]+"${layers[@]}"}; do
    if jq -e "$jqpath // empty" "$f" >/dev/null 2>&1; then origin="$f"; defs="$defs$f"$'\n'; fi
  done
  printf 'value:  %s\n' "${val:-(empty)}"
  printf 'set by: %s\n' "$origin"
  printf 'layers (far->near):\n'
  for f in ${layers[@]+"${layers[@]}"}; do
    if printf '%s' "$defs" | grep -qxF "$f"; then printf '  * %s  (defines %s)\n' "$f" "$jqpath"; else printf '    %s\n' "$f"; fi
  done
}

# CLI — run ONLY when executed directly (kit_is_main handles bash+zsh).
_kit_cr_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_kit_cr_dir/kit-cli.sh"
if kit_is_main; then
  _dir="$PWD"; _mode=""; _arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) _dir="$2"; shift 2;;
      --explain) _mode=explain; _arg="$2"; shift 2;;
      --get) _mode=get; _arg="$2"; shift 2;;
      --layers) _mode=layers; shift;;
      -h|--help) echo "usage: kit-config-resolve.sh [--dir DIR] [--explain JQPATH|--get JQPATH|--layers]"; exit 0;;
      *) echo "unknown arg: $1" >&2; exit 2;;
    esac
  done
  case "$_mode" in
    explain) kit_resolve_explain "$_arg" "$_dir";;
    get)     kit_resolve_get "$_arg" "$_dir";;
    layers)  kit_resolve_layers "$_dir";;
    *)       kit_resolve "$_dir";;
  esac
fi
