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
# INTEGRATIONS (E303.2): the same entry also switches on an optional third-party tool described by
# integrations/<id>.json. `kit-add.sh` with no name LISTS what can be added. `kit-add.sh <id>` asks
# the one question kit-interview derives from the descriptor and sets that descriptor's config key
# in the project config kit_config_path resolves — no other key changes. It installs nothing.
# A descriptor that lists `rules` (E303.10) also gets each rule template copied into the project's
# .claude/rules/, and under KIT_DRY_RUN the install + wire plan is printed after the config diff.
#
# SKILLS (#504): a skill cckit ships that declares itself addable (templates/skills/<name>/add.json:
# label, summary and the one config key it switches on) is the third thing `add` accepts.
# `kit-add.sh page-design` sets that key in the project config and copies the skill's SKILL.md and
# references/ into the skills folder of each adapter the project selects. It asks nothing, keeps a
# copy that is already there, and is the way a project already at the installed version gets the
# skill: `cckit init --upgrade` refuses such a project before it adds anything.
#
# Run:
#   scripts/kit-add.sh                                         # list integrations + modules + skills
#   scripts/kit-add.sh page-design [--dir DIR]                 # switch a kit skill on and copy it in
#   scripts/kit-add.sh <integration> [--dir DIR] [--set enable=yes|no]
#   scripts/kit-add.sh software [--dir DIR] --answers FILE     # non-interactive (skill/CI/tests)
#   scripts/kit-add.sh software --set versioning=github --set deploy=vercel --set ci=github-actions
#   KIT_ASSUME_YES=1 scripts/kit-add.sh software               # accept every recommended default
#   scripts/kit-add.sh qa --answers FILE                       # how this project's review stack boots (#294)
#   KIT_DRY_RUN=1 scripts/kit-add.sh software                  # preview only
# Requires: jq.

set -uo pipefail
_add_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_add_dir/lib/kit-interview.sh"   # catalog/apply (pulls kit-cli + kit-profile)
# shellcheck source=/dev/null
. "$_add_dir/lib/kit-operate.sh"     # four-beat machine + manifest
# shellcheck source=/dev/null
. "$_add_dir/lib/integration-install.sh"  # integration_install_plan — the dry-run plan
# shellcheck source=/dev/null
command -v adapter_list_from_config >/dev/null 2>&1 || . "$_add_dir/lib/adapter-select.sh"  # which skills folders

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

  # Both supported layouts: a root cckit.config.json (self-host) wins when this island has one,
  # else the scaffolded .claude/kit.config.json. Checked in THIS dir only — never walked upward,
  # so a module still writes into this island and nothing above it.
  local cfg=".claude/kit.config.json" base merged tmp
  [ -f "cckit.config.json" ] && cfg="cckit.config.json"
  base=""; [ -f "$cfg" ] && base="$cfg"
  merged="$(kit_interview_apply "$module" "$answers" "$base")" || kit_die "deriving module config failed"
  # Belt-and-suspenders: guarantee the module name is in modules[] even if the spec omitted it.
  merged="$(printf '%s' "$merged" | jq --arg m "$module" '.modules = ((.modules // []) + [$m] | unique)')"

  kit_say "kit add $module  ->  $target/$cfg"
  # Through a FILE, not a pipe: kit_op_write asks before overwriting a config it does not track
  # (every `cckit init` config, every self-host one) and reads that yes from stdin. Piping the
  # content in made stdin the already-drained pipe, so the prompt always read EOF and declined.
  tmp="$(mktemp)" || kit_die "mktemp failed"
  printf '%s\n' "$merged" > "$tmp"
  kit_op_write "$tmp" "$cfg" A "add:$module"
  local rc=$?
  rm -f "$tmp"
  case $rc in
    0)  kit_say "module '$module' active here. modules: $(printf '%s' "$merged" | jq -c '.modules')";;
    10) kit_say "no change (already applied / declined / dry-run).";;
    *)  kit_die "failed to write $cfg";;
  esac
  return 0
}

# --- integrations (E303.2) -------------------------------------------------
# kit_add_kind <name> -> prints `module` or `integration`; rc 1 when it is neither. A module wins
# a shared name, the same precedence kit_interview_catalog applies.
kit_add_kind() {
  if kit_add_module_exists "$1"; then printf 'module\n'; return 0; fi
  if integration_file "$1" >/dev/null 2>&1; then printf 'integration\n'; return 0; fi
  if kit_add_skill_file "$1" >/dev/null 2>&1; then printf 'skill\n'; return 0; fi
  return 1
}

# --- addable kit skills (#504) ---------------------------------------------
# kit_add_skill_file <name> -> the add.json of a kit skill that can be added; rc 1 when the name is
# not a skill id or the skill ships no add.json. The id grammar is checked first, so `../x` never
# resolves outside templates/skills/.
kit_add_skill_file() {
  local f
  grep -qE '^[a-z][a-z0-9]*(-[a-z0-9]+)*$' <<<"${1:-}" || return 1
  f="$(kit_iv_plugin_root)/templates/skills/$1/add.json"
  [ -f "$f" ] && [ -f "$(dirname "$f")/SKILL.md" ] || return 1
  printf '%s\n' "$f"
}

# kit_add_skills_list -> the names of the addable kit skills, sorted.
kit_add_skills_list() {
  find "$(kit_iv_plugin_root)/templates/skills" -mindepth 2 -maxdepth 2 -type f -name add.json 2>/dev/null \
    | sed -e 's#/add\.json$##' -e 's#.*/##' | sort
}

# kit_add_skill_missing <name> <root> <adapters> -> the adapter skill folders (relative to root)
# that do not hold the skill, one per line. Empty = installed for every selected adapter.
kit_add_skill_missing() {
  local name="$1" root="$2" a d
  for a in $(printf '%s\n' "$3"); do   # a substitution splits under zsh; a bare $3 does not
    d="$(adapter_dir "$a")" || continue
    [ -f "$root/$d/skills/$name/SKILL.md" ] || printf '%s/skills/%s\n' "$d" "$name"
  done
}

# kit_add_skill <name> [targetdir]
# Sets the skill's config key in the project config (the same merge an integration gets: every
# other key is kept) and copies templates/skills/<name>/ — SKILL.md and references/ — into
# <adapter-dir>/skills/<name>/ for each adapter in the config. A folder that already holds a
# SKILL.md is kept whole, so a project's edits survive a re-run; a second run changes nothing.
# KIT_DRY_RUN prints the plan and writes nothing. rc 1: no project config, or a failed copy.
kit_add_skill() {
  command -v jq >/dev/null 2>&1 || { kit_die "jq required"; }
  local name="$1" target="${2:-$PWD}" f src cfg root rel key on merged tmp verdict adapters rest d ref bad=0
  f="$(kit_add_skill_file "$name")" || kit_die "unknown skill '$name' — run 'cckit add' to list what can be added"
  src="$(dirname "$f")"
  target="$(cd "$target" 2>/dev/null && pwd)" || kit_die "no such dir: $target"
  cfg="$(kit_config_path "$target" 2>/dev/null)" || cfg=""
  [ -n "$cfg" ] && [ -f "$cfg" ] || kit_die "no project config found from $target — run 'cckit init' first"
  key="$(jq -r '.config.key' "$f")"; on="$(jq -c 'if (.config | has("value")) then .config.value else true end' "$f")"
  root="$(_kit_add_root "$cfg")"
  rel="${cfg#"$root"/}"
  merged="$(jq --arg k "$key" --argjson v "$on" 'setpath($k | split("."); $v)' "$cfg")" || kit_die "cannot read $cfg"

  if [ "$(printf '%s' "$merged" | jq -S .)" = "$(jq -S . "$cfg")" ]; then
    kit_say "kit add $name: $key is already $on in $cfg."
  else
    kit_say "kit add $name  ->  $cfg"
    tmp="$(mktemp "$cfg.XXXXXX")" || kit_die "cannot write beside $cfg"
    printf '%s\n' "$merged" > "$tmp"
    _kit_op_diff "$tmp" "$cfg"
    if [ -n "${KIT_DRY_RUN:-}" ]; then
      rm -f "$tmp"; kit_say "  [dry-run] would write $cfg"
    else
      verdict="$(cd "$root" && kit_manifest_verify "$rel" 2>/dev/null || true)"
      mv "$tmp" "$cfg" || { rm -f "$tmp"; kit_die "failed to write $cfg"; }
      [ "$verdict" = "intact" ] && ( cd "$root" && kit_manifest_record "$rel" A "add:$name" ) >/dev/null 2>&1
      kit_say "$key = $on."
    fi
  fi

  adapters="$(adapter_list_from_config "$cfg")" || kit_die "the config's 'adapters' value is invalid (expected claude and/or codex)"
  rest="$(kit_add_skill_missing "$name" "$root" "$adapters")"
  if [ -z "$rest" ]; then kit_say "skill $name: already in the project — kept as it is."; return 0; fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -n "${KIT_DRY_RUN:-}" ]; then kit_say "  [dry-run] would write $root/$d/"; continue; fi
    if ! mkdir -p "$root/$d" 2>/dev/null || ! cp "$src/SKILL.md" "$root/$d/SKILL.md" 2>/dev/null; then
      kit_warn "kit add $name: cannot write $root/$d/SKILL.md"; bad=1; continue
    fi
    if [ -d "$src/references" ]; then
      mkdir -p "$root/$d/references" 2>/dev/null || bad=1
      # `find`, not a glob: an unmatched glob is an error under zsh.
      find "$src/references" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r ref; do
        cp "$ref" "$root/$d/references/" 2>/dev/null || kit_warn "kit add $name: cannot write $root/$d/references/$(basename "$ref")"
      done
    fi
    kit_say "skill written: $root/$d/"
  done <<EOF
$rest
EOF
  [ "$bad" -eq 0 ] || return 1
  [ -n "${KIT_DRY_RUN:-}" ] || kit_say "Reload the agent session so it lists $name, and commit the files above."
  return 0
}

# _kit_add_list_json [dir] -> {integrations:[{id,label,summary,key,enabled,applies}],modules:[{id,label}],
#                              skills:[{id,label,summary,key,enabled,installed}]}
# `enabled` / `applies` are judged against the project at dir. Read-only.
_kit_add_list_json() {
  local d="${1:-$PWD}" id f cfg en ap rows mods m sks root
  cfg="$(kit_config_path "$d" 2>/dev/null)" || cfg=""
  rows="[]"
  for id in $(integrations_list); do
    f="$(integrations_dir)/$id.json"
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || continue
    en=false; [ -n "$cfg" ] && integration_enabled "$f" "$cfg" && en=true
    ap=false; integration_applies "$f" "$d" && ap=true
    rows="$(printf '%s' "$rows" | jq -c --slurpfile x "$f" --arg id "$id" --argjson en "$en" --argjson ap "$ap" \
      '. + [{id: $id, label: ($x[0].label // $id), summary: ($x[0].summary // ""), key: ($x[0].config.key // ""), enabled: $en, applies: $ap}]')"
  done
  mods="[]"
  # Ids, not paths, go through the word-split: a plugin root with a space in it stays one path.
  for m in $(find "$(kit_iv_plugin_root)/modules" -maxdepth 1 -type f -name '*.json' 2>/dev/null \
               | sed -e 's#.*/##' -e 's#\.json$##' | sort); do
    f="$(kit_iv_plugin_root)/modules/$m.json"
    jq -e 'type == "object"' "$f" >/dev/null 2>&1 || continue
    mods="$(printf '%s' "$mods" | jq -c --slurpfile x "$f" --arg id "$m" '. + [{id: $id, label: ($x[0].label // $id)}]')"
  done
  # Addable kit skills: `enabled` is the config key, `installed` is the skill folder of every
  # adapter the project selects.
  sks="[]"; root=""; [ -n "$cfg" ] && root="$(_kit_add_root "$cfg")"
  for m in $(kit_add_skills_list); do
    f="$(kit_add_skill_file "$m")" || continue
    en=false; ap=false
    if [ -n "$cfg" ] && [ -f "$cfg" ]; then
      jq -e --slurpfile x "$f" '($x[0].config) as $c
        | (try getpath($c.key | split(".")) catch null) == (if ($c | has("value")) then $c.value else true end)' "$cfg" >/dev/null 2>&1 && en=true
      [ -z "$(kit_add_skill_missing "$m" "$root" "$(adapter_list_from_config "$cfg" 2>/dev/null || echo claude)")" ] && ap=true
    fi
    sks="$(printf '%s' "$sks" | jq -c --slurpfile x "$f" --arg id "$m" --argjson en "$en" --argjson ap "$ap" \
      '. + [{id: $id, label: ($x[0].label // $id), summary: ($x[0].summary // ""), key: ($x[0].config.key // ""), enabled: $en, installed: $ap}]')"
  done
  jq -cn --argjson i "$rows" --argjson m "$mods" --argjson s "$sks" '{integrations: $i, modules: $m, skills: $s}'
}

# kit_add_list [dir] -> what `add` accepts, on stdout. One JSON object when CCKIT_OUTPUT=json
# (`cckit add --llm`), else a table. An empty registry is a valid answer, not an error.
kit_add_list() {
  command -v jq >/dev/null 2>&1 || { kit_die "jq required"; }
  local d="${1:-$PWD}" j n
  j="$(_kit_add_list_json "$d")" || return 1
  if [ "${CCKIT_OUTPUT:-human}" = "json" ]; then printf '%s\n' "$j"; return 0; fi
  n="$(printf '%s' "$j" | jq '.integrations | length')"
  if [ "$n" -eq 0 ]; then
    printf 'Integrations: none described yet (%s holds no descriptor).\n' "$(integrations_dir)"
  else
    printf 'Integrations — optional third-party tools (cckit add <name>):\n'
    printf '%s' "$j" | jq -r '.integrations[]
      | "  \(.id)  \(.label) — \(.summary)  [\(if .enabled then "on" else "off" end)\(if .applies then "" else ", does not apply here" end)]"'
  fi
  if [ "$(printf '%s' "$j" | jq '.modules | length')" -gt 0 ]; then
    printf 'Modules (cckit add <name>):\n'
    printf '%s' "$j" | jq -r '.modules[] | "  \(.id)  \(.label)"'
  fi
  if [ "$(printf '%s' "$j" | jq '.skills | length')" -gt 0 ]; then
    printf 'Skills — shipped with cckit (cckit add <name>):\n'
    printf '%s' "$j" | jq -r '.skills[]
      | "  \(.id)  \(.summary)  [\(if .enabled then "on" else "off" end), \(if .installed then "installed" else "not in this project" end)]"'
  fi
}

# _kit_add_root <config> -> the project root a config file belongs to: the dir holding .claude/
# for the scaffolded layout, the config's own dir for a root cckit.config.json.
_kit_add_root() {
  case "$1" in
    */.claude/kit.config.json) dirname "$(dirname "$1")" ;;
    *) dirname "$1" ;;
  esac
}

# _kit_add_rules <descriptor> <project-root> <id>
# Copies each rule template the descriptor lists (`rules`) into <root>/.claude/rules/. A rule file
# already there is kept — never overwritten, so a project's edits survive a re-run. Under
# KIT_DRY_RUN it names the files and writes none. A descriptor with no `rules` does nothing.
_kit_add_rules() {
  local f="$1" root="$2" id="$3" r src dest
  for r in $(jq -r '.rules // [] | .[]' "$f" 2>/dev/null); do
    src="$(kit_iv_plugin_root)/templates/rules/$r.md"; dest=".claude/rules/$r.md"
    [ -e "$root/$dest" ] && continue
    [ -f "$src" ] || { kit_warn "kit add $id: rule template missing ($src) — rule not written"; continue; }
    if [ -n "${KIT_DRY_RUN:-}" ]; then kit_say "  [dry-run] would write $root/$dest"; continue; fi
    if mkdir -p "$root/.claude/rules" 2>/dev/null && cp "$src" "$root/$dest" 2>/dev/null; then
      # Tracked only where a manifest already exists: an add never invents one.
      [ -f "$root/.claude/kit.manifest.json" ] && ( cd "$root" && kit_manifest_record "$dest" A "add:$id" ) >/dev/null 2>&1
      kit_say "rule written: $root/$dest"
    else
      kit_warn "kit add $id: cannot write $root/$dest"
    fi
  done
  return 0
}

# kit_add_integration <id> <answersfile> [targetdir]
# Sets the descriptor's config key in the project config, and copies the rule templates the
# descriptor lists (_kit_add_rules); it installs nothing. Refusals, each before
# any write: an invalid descriptor (rc 1), a repo the tool cannot work on (rc 0 — declined, not an
# error), no project config (rc 1). The merge keeps every existing key, so the write does not go
# through kit_op_write's conffiles guard, which exists to stop a WHOLE-FILE replacement of a file
# the user edited; a manifest entry that was intact is re-recorded so it stays intact.
kit_add_integration() {
  command -v jq >/dev/null 2>&1 || { kit_die "jq required"; }
  local id="$1" answers="$2" target="${3:-$PWD}"
  local f label cfg root rel merged tmp verdict key exts
  f="$(integration_file "$id")" || kit_die "unknown integration '$id' — run 'cckit add' to list them"
  integration_validate "$f" || kit_die "integration '$id': invalid descriptor ($f) — nothing written"
  [ -f "$answers" ] || kit_die "internal: answers file missing ($answers)"
  target="$(cd "$target" 2>/dev/null && pwd)" || kit_die "no such dir: $target"
  label="$(jq -r '.label' "$f")"; key="$(jq -r '.config.key' "$f")"

  if ! integration_applies "$f" "$target"; then
    exts="$(integration_applies_needs "$f")"
    kit_say "kit add $id: not offered here — $label needs $exts. That does not hold here. Nothing written."
    return 0
  fi

  cfg="$(kit_config_path "$target" 2>/dev/null)" || cfg=""
  [ -n "$cfg" ] && [ -f "$cfg" ] || kit_die "no project config found from $target — run 'cckit init' first ($label is switched on by '$key' in that config)"
  merged="$(kit_interview_apply "$id" "$answers" "$cfg")" || kit_die "deriving the config for '$id' failed"

  if [ "$(printf '%s' "$merged" | jq -S .)" = "$(jq -S . "$cfg")" ]; then
    if integration_enabled "$f" "$cfg"; then
      kit_say "kit add $id: no change — $key already selects $label in $cfg."
      _kit_add_rules "$f" "$(_kit_add_root "$cfg")" "$id"
      [ -n "${KIT_DRY_RUN:-}" ] && integration_install_plan "$f" "$target"
    else kit_say "kit add $id: left off — nothing written."; fi
    return 0
  fi

  kit_say "kit add $id  ->  $cfg"
  tmp="$(mktemp "$cfg.XXXXXX")" || kit_die "cannot write beside $cfg"
  printf '%s\n' "$merged" > "$tmp"
  _kit_op_diff "$tmp" "$cfg"
  if [ -n "${KIT_DRY_RUN:-}" ]; then
    rm -f "$tmp"; kit_say "  [dry-run] would write $cfg"
    # Declining a default-on integration writes the off value: no rule and no install plan follow.
    if ! printf '%s' "$merged" | jq -e --slurpfile d "$f" '
        ($d[0].config) as $c | (if ($c | has("value")) then $c.value else true end) as $on
        | (try getpath($c.key | split(".")) catch null) == $on' >/dev/null 2>&1; then return 0; fi
    _kit_add_rules "$f" "$(_kit_add_root "$cfg")" "$id"
    # What `cckit doctor` would then install, and the wire command, for this repo. Runs nothing.
    integration_install_plan "$f" "$target"
    return 0
  fi
  # Manifest paths are relative to the project root: the dir holding .claude/, or the config's own.
  root="$(dirname "$cfg")"; rel="$(basename "$cfg")"
  case "$cfg" in */.claude/kit.config.json) root="$(dirname "$root")"; rel=".claude/kit.config.json";; esac
  verdict="$(cd "$root" && kit_manifest_verify "$rel" 2>/dev/null || true)"
  mv "$tmp" "$cfg" || { rm -f "$tmp"; kit_die "failed to write $cfg"; }
  [ "$verdict" = "intact" ] && ( cd "$root" && kit_manifest_record "$rel" A "add:$id" ) >/dev/null 2>&1
  if ! integration_enabled "$f" "$cfg"; then
    # A descriptor that is on by default is the one case where declining writes: the off value.
    kit_say "$label is off: $key = $(jq -c --arg k "$key" 'getpath($k | split("."))' "$cfg"). Turn it back on with 'cckit add $id'."
    return 0
  fi
  kit_say "$label is on: $key = $(jq -c --arg k "$key" 'getpath($k | split("."))' "$cfg"). Nothing was installed."
  _kit_add_rules "$f" "$root" "$id"
  kit_say "$(jq -r '"\(.attribution.notice)  Docs: \(.docs)"' "$f")"
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
    -h|--help) echo "usage: kit-add.sh [<module|integration|skill>] [--dir DIR] [--answers FILE] [--set k=v ...]   (no name lists what can be added; env: KIT_ASSUME_YES, KIT_DRY_RUN)"; exit 0;;
    -*) kit_die "unknown flag: $1";;
    *) [ -z "$_module" ] && _module="$1" || kit_die "unexpected arg: $1"; shift;;
  esac; done
  # No name = the list. Read-only, rc 0 even when the registry is empty.
  [ -n "$_module" ] || { kit_add_list "$_target"; exit $?; }
  _kind="$(kit_add_kind "$_module")" || kit_die "unknown module or integration '$_module' — run 'cckit add' to list them"
  # A kit skill has no question to ask: it sets one key and copies its files.
  if [ "$_kind" = "skill" ]; then kit_add_skill "$_module" "$_target"; exit $?; fi
  _af="$(_kit_add_collect "$_module" "$_answers" ${_sets[@]+"${_sets[@]}"})" || kit_die "collecting answers failed"
  if [ "$_kind" = "integration" ]; then kit_add_integration "$_module" "$_af" "$_target"; _rc=$?
  else kit_add "$_module" "$_af" "$_target"; _rc=$?; fi
  rm -f "$_af"
  exit $_rc
fi
