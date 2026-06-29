#!/usr/bin/env bash
# kit-interview.sh — the deterministic brain of the two-tier onboarding interview (D11, #372).
#
# THE SPLIT: the ASKING is interactive (the kit-onboard skill drives AskUserQuestion — Tier A,
# portable to Cowork/claude.ai). The DERIVING is pure data and lives here, so it is unit-testable
# under bash AND zsh with zero interactivity:
#   - catalog : the question set per tier (global | project | software), loaded from interview/*.json
#               and modules/*.json — data, reviewable, not buried in bash.
#   - context : profile + repo detection, used to PRE-FILL per-project / wizard defaults.
#   - render  : the catalog with every `default` resolved from context (what the skill renders).
#   - apply   : answers {key:value} + a base config  ->  merged config JSON (no side effects).
# The caller (kit-onboard skill / kit-add.sh) persists the merged JSON — to the global profile
# directly, or to a project's .claude/kit.config.json through kit-operate (so it is manifest-tracked).
#
# Source it:  source scripts/lib/kit-interview.sh
# CLI:        kit-interview.sh --catalog TIER
#             kit-interview.sh --context [--dir DIR]
#             kit-interview.sh --render  TIER [--dir DIR]
#             kit-interview.sh --apply   TIER --answers FILE [--base FILE]
# Requires: jq.

_kit_iv_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_kit_iv_dir/kit-cli.sh"      # kit_is_main, kit_say/warn/die
# shellcheck source=/dev/null
. "$_kit_iv_dir/kit-profile.sh"  # kit_profile_read

# Plugin root = two levels up from scripts/lib/. Override with KIT_PLUGIN_ROOT (tests).
kit_iv_plugin_root() {
  if [ -n "${KIT_PLUGIN_ROOT:-}" ]; then printf '%s\n' "$KIT_PLUGIN_ROOT"; return 0; fi
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf '%s\n' "$CLAUDE_PLUGIN_ROOT"; return 0; fi
  ( CDPATH='' cd -- "$_kit_iv_dir/../.." && pwd )
}

_kit_iv_require() { command -v jq >/dev/null 2>&1 || { kit_warn "kit-interview: jq is required"; return 1; }; }

# kit_interview_catalog_file <tier> -> path of the catalog JSON for a tier.
#   global|project -> interview/<tier>.json ;  anything else -> modules/<tier>.json (software, ...)
kit_interview_catalog_file() {
  local tier="$1" root; root="$(kit_iv_plugin_root)"
  case "$tier" in
    global|project) printf '%s/interview/%s.json\n' "$root" "$tier";;
    *)              printf '%s/modules/%s.json\n'    "$root" "$tier";;
  esac
}

# kit_interview_catalog <tier> -> the catalog JSON (verbatim)
kit_interview_catalog() {
  _kit_iv_require || return 1
  local f; f="$(kit_interview_catalog_file "$1")"
  [ -f "$f" ] || { kit_warn "kit-interview: no catalog for tier '$1' ($f)"; return 1; }
  jq -e . "$f" >/dev/null 2>&1 || { kit_warn "kit-interview: invalid JSON in $f"; return 1; }
  cat "$f"
}

# --- repo detection (per-project pre-fill) --------------------------------
# kit_interview_context [dir] -> { profile:{...}, repo:{dir,language,hasGit,remote,hasGitHub} }
kit_interview_context() {
  _kit_iv_require || return 1
  local dir; dir="$(cd "${1:-$PWD}" 2>/dev/null && pwd)" || dir="${1:-$PWD}"
  local base; base="$(basename "$dir")"
  local lang="" hasgit=false remote="" hasgh=false
  [ -f "$dir/package.json" ]   && lang="javascript"
  [ -f "$dir/pyproject.toml" ] && lang="python"
  [ -f "$dir/Cargo.toml" ]     && lang="rust"
  [ -f "$dir/go.mod" ]         && lang="go"
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    hasgit=true
    local url; url="$(git -C "$dir" remote get-url origin 2>/dev/null || true)"
    if [ -n "$url" ]; then
      hasgh=true
      remote="$(printf '%s' "$url" | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
    fi
  fi
  local profile; profile="$(kit_profile_read)"
  jq -n --argjson p "$profile" --arg d "$base" --arg l "$lang" \
        --argjson g "$hasgit" --arg r "$remote" --argjson gh "$hasgh" \
    '{profile:$p, repo:{dir:$d, language:$l, hasGit:$g, remote:$r, hasGitHub:$gh}}'
}

# kit_interview_render <tier> [dir] -> the catalog with each question.default resolved from context.
# For a question with "prefillFrom":"profile.language", if context.<prefillFrom> is non-empty it
# becomes the default. This is what the skill renders into AskUserQuestion.
kit_interview_render() {
  _kit_iv_require || return 1
  local tier="$1" dir="${2:-$PWD}" cat ctx
  cat="$(kit_interview_catalog "$tier")" || return 1
  ctx="$(kit_interview_context "$dir")"  || return 1
  jq --argjson ctx "$ctx" '
    def deref($path): ($path | split(".")) as $p | reduce $p[] as $k ($ctx; if type=="object" then .[$k] else null end);
    .questions |= map(
      if (.prefillFrom // "") != ""
      then (deref(.prefillFrom)) as $v | if ($v != null and $v != "") then .default = ($v|tostring) else . end
      else . end
    )
  ' <<EOF
$cat
EOF
}

# --- apply: answers + base config -> merged config (pure) -----------------
# _kit_iv_setpath <dotpath> <value> <valtype>  : jq filter snippet applied to stdin JSON.
# valtype: string | bool | number | json. For valtype json on an existing array, unions uniquely
# (so adding a module twice is a no-op — idempotent modules:[]).
_kit_iv_apply_set() {
  local dotpath="$1" value="$2" valtype="${3:-string}"   # `path` is $PATH-tied in zsh — never use it
  local setexpr
  setexpr="$(printf '%s' "$dotpath" | awk -F. '{out="["; for(i=1;i<=NF;i++){ if(i>1)out=out","; out=out"\""$i"\""}; out=out"]"; print out}')"
  case "$valtype" in
    bool|boolean|number|int)
      jq --argjson v "$value" "setpath($setexpr; \$v)";;
    json)
      jq --argjson v "$value" "
        getpath($setexpr) as \$cur
        | if (\$cur|type)==\"array\" and (\$v|type)==\"array\"
          then setpath($setexpr; (\$cur + \$v | unique))
          else setpath($setexpr; \$v) end";;
    *)
      jq --arg v "$value" "setpath($setexpr; \$v)";;
  esac
}

# kit_interview_apply <tier> <answersfile> [basefile] -> merged config JSON on stdout.
# answersfile: {"<key>":"<chosen value>", ...}. Unanswered questions fall back to their default.
# Control questions (e.g. project.software) carry no `set` — they steer the caller, not the config.
kit_interview_apply() {
  _kit_iv_require || return 1
  # ALL locals declared ONCE up front. A BARE `local x` re-run inside a loop PRINTS the var under
  # zsh (treated like `typeset x`), polluting stdout — so never re-declare locals in the loops below.
  local tier="$1" ans="$2" base="${3:-}"
  local catalog merged nsets nq i p v vt tmp q key qtype def answer target nset j
  [ -f "$ans" ] || { kit_warn "kit-interview apply: answers file missing: $ans"; return 1; }
  catalog="$(kit_interview_catalog "$tier")" || return 1
  merged="$(mktemp)" || return 1
  if [ -n "$base" ] && [ -f "$base" ]; then cp "$base" "$merged"; else printf '{}\n' > "$merged"; fi

  # 1. unconditional catalog-level sets (e.g. modules:["software"])
  nsets="$(printf '%s' "$catalog" | jq '(.sets // []) | length')"
  i=0
  while [ "$i" -lt "$nsets" ]; do
    p="$(printf '%s' "$catalog"  | jq -r ".sets[$i].path")"
    v="$(printf '%s' "$catalog"  | jq -r ".sets[$i].value")"
    vt="$(printf '%s' "$catalog" | jq -r ".sets[$i].valtype // \"string\"")"
    tmp="$(mktemp)"; _kit_iv_apply_set "$p" "$v" "$vt" < "$merged" > "$tmp" && mv "$tmp" "$merged" || { rm -f "$tmp" "$merged"; return 1; }
    i=$((i+1))
  done

  # 2. per-question answers
  nq="$(printf '%s' "$catalog" | jq '.questions | length')"
  i=0
  while [ "$i" -lt "$nq" ]; do
    q="$(printf '%s' "$catalog" | jq ".questions[$i]")"
    key="$(printf '%s' "$q" | jq -r '.key')"
    qtype="$(printf '%s' "$q" | jq -r '.type // "text"')"
    def="$(printf '%s' "$q" | jq -r '.default // ""')"
    answer="$(jq -r --arg k "$key" '.[$k] // empty' "$ans")"
    [ -z "$answer" ] && answer="$def"

    if [ "$qtype" = "text" ]; then
      target="$(printf '%s' "$q" | jq -r '.target // empty')"
      if [ -n "$target" ] && [ -n "$answer" ]; then
        tmp="$(mktemp)"; _kit_iv_apply_set "$target" "$answer" string < "$merged" > "$tmp" && mv "$tmp" "$merged" || { rm -f "$tmp" "$merged"; return 1; }
      fi
    else
      # select: apply the chosen option's set[] (control-only options have none)
      nset="$(printf '%s' "$q" | jq --arg a "$answer" '[.options[] | select(.value==$a)] | .[0].set // [] | length')"
      j=0
      while [ "$j" -lt "$nset" ]; do
        p="$(printf '%s' "$q"  | jq -r --arg a "$answer" "[.options[] | select(.value==\$a)][0].set[$j].path")"
        v="$(printf '%s' "$q"  | jq -r --arg a "$answer" "[.options[] | select(.value==\$a)][0].set[$j].value")"
        vt="$(printf '%s' "$q" | jq -r --arg a "$answer" "[.options[] | select(.value==\$a)][0].set[$j].valtype // \"string\"")"
        tmp="$(mktemp)"; _kit_iv_apply_set "$p" "$v" "$vt" < "$merged" > "$tmp" && mv "$tmp" "$merged" || { rm -f "$tmp" "$merged"; return 1; }
        j=$((j+1))
      done
    fi
    i=$((i+1))
  done

  cat "$merged"; rm -f "$merged"
}

# CLI — direct execution only.
if kit_is_main; then
  _mode=""; _tier=""; _dir="$PWD"; _ans=""; _base=""
  while [ $# -gt 0 ]; do case "$1" in
    --catalog) _mode=catalog; _tier="$2"; shift 2;;
    --context) _mode=context; shift;;
    --render)  _mode=render; _tier="$2"; shift 2;;
    --apply)   _mode=apply; _tier="$2"; shift 2;;
    --dir)     _dir="$2"; shift 2;;
    --answers) _ans="$2"; shift 2;;
    --base)    _base="$2"; shift 2;;
    -h|--help) echo "usage: kit-interview.sh --catalog|--render TIER [--dir D] | --context [--dir D] | --apply TIER --answers F [--base F]"; exit 0;;
    *) kit_warn "unknown arg: $1"; exit 2;;
  esac; done
  case "$_mode" in
    catalog) kit_interview_catalog "$_tier";;
    context) kit_interview_context "$_dir";;
    render)  kit_interview_render "$_tier" "$_dir";;
    apply)   kit_interview_apply "$_tier" "$_ans" "$_base";;
    *) kit_warn "nothing to do (see --help)"; exit 2;;
  esac
fi
