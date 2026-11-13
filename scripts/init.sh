#!/usr/bin/env bash
# claude-kit init — scaffold a tailored .claude/ into a target project.
# Substitutes {{VARS}} and resolves <!-- IF:FLAG --> blocks from a role profile.
#
# Usage:
#   scripts/init.sh [<folder>] [flags]                # guided setup: detect, ask, scaffold, git + GitHub
#   scripts/init.sh --profile software --no-github    # scaffold only, nothing outside the folder
#   scripts/init.sh --upgrade --target <dir>          # merge new features into an existing setup
#
# Flags (all optional; sensible defaults derived otherwise):
#   <folder> | --target <dir> project folder (created when missing)  (default: $PWD)
#   --no-github               scaffold only: no git init, no commit, no GitHub write
#   --yes                     run the git + GitHub setup without asking (required with no terminal)
#   --public                  create the GitHub repository public       (default: private)
#   --answers <file>          JSON {"<question key>":"<answer>"} for the guided questions
#   --recipe <id|none>        start a NEW project from recipes/<id>.json
#   --database <id|none>      add the database option databases/<id>.json
#   --profile <software|content|research|minimal>   role profile (asked when a terminal or an
#                             answers file is there; else required unless --upgrade)
#   --name <str>              human project name                  (default: target basename)
#   --slug <str>             short slug / mempalace wing          (default: lowercased basename)
#   --repo <owner/repo>       GitHub repo                          (default: <owner>/<slug>)
#   --owner-login <login>     GitHub user/org login                (default: gh api user)
#   --owner-name <str>        human owner name                     (default: owner-login)
#   --project-number <int>    Projects v2 number (enables board)   (default: none -> board off)
#   --plans <mdx|markdown|none>  plan file format                  (default: profile default)
#   --plans-dir <dir>         where plans live                     (default: per format)
#   --memory <on|off>         enable MemPalace memory + hooks      (default: profile default)
#   --speckit <on|off>        add the Spec-Driven Development flow  (default: off)
#   --plain-language <on|off> install the plain-language rule: the agent says draft, review and
#                             approve, and names git mechanics only when asked (default: profile default)
#   --prepush "<command>"     install an opt-in pre-push gate that runs <command> before
#                             `git push` and blocks on failure     (default: none -> no gate)
#   --local <on|off>          local model layer (mlx_lm.server) for NL chores at $0 API cost
#                             (config + SessionStart status hook)  (default: off)
#   --lang <str>              working language                     (default: English)
#   --adapter <claude|codex|both>  which agent adapter(s) to install  (default: claude; with
#                             --upgrade: the stored selection, and a named adapter is ADDED to it)
#   --upgrade                 merge new kit features into an existing .claude/ (preserves your edits)
#   --dry-run                 print the scaffold plan and exit, writing nothing
#   --force                   overwrite without prompting
set -euo pipefail

# ============================================================================
# TERMINAL IDENTITY — init banner + golden-angle plant animation              #
# Canonical brief: the cckit docs (                                     #
#   terminal-identity brief) #
# Sources kit-sigil.sh for palette/mode detection when available.             #
# ============================================================================

# _kit_banner_detect_mode — populate KIT_COLOR, KIT_UNICODE, and palette vars.
# Tries to source the plugin's kit-sigil template (plain bash, no {{VARS}});
# falls back to inline detection if the template is unavailable or fails.
_kit_banner_detect_mode() {
  # Try the plugin's sigil template (lives beside this script in the plugin tree)
  local _sigil
  _sigil="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/templates/lib/kit-sigil.sh.tmpl"
  if [ -f "$_sigil" ]; then
    # shellcheck disable=SC1090
    if source "$_sigil" 2>/dev/null; then
      kit_color_mode 2>/dev/null && return 0
    fi
  fi
  # Inline fallback — matches the logic in kit-sigil.sh exactly.
  local _loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [ "${KIT_ASCII:-}" = "1" ]; then
    KIT_UNICODE=0
  elif printf '%s' "$_loc" | grep -qiE 'utf-?8'; then
    KIT_UNICODE=1
  else
    KIT_UNICODE=0
  fi
  if [ "${FORCE_COLOR:-}" = "1" ]; then
    KIT_COLOR=1
  elif [ -t 1 ] && [ -z "${NO_COLOR+x}" ]; then
    KIT_COLOR=1
  else
    KIT_COLOR=0
  fi
  if [ "$KIT_COLOR" = 1 ]; then
    KIT_AZAFRAN=$'\033[38;2;201;122;44m'
    KIT_INK=$'\033[2m'
    KIT_POLVO=$'\033[38;2;168;160;151m'
    KIT_RESET=$'\033[0m'
  else
    KIT_AZAFRAN=''; KIT_INK=''; KIT_POLVO=''; KIT_RESET=''
  fi
}

# _kit_print_static_banner — the V4 box-drawing CLAUDE KIT banner (§7 exact form).
# Always printed: after the animation on TTY, or alone when non-TTY / ASCII mode.
# Reads: KIT_COLOR KIT_UNICODE KIT_AZAFRAN KIT_INK KIT_POLVO KIT_RESET
# Arg 1 (optional): version string, no "v" prefix (e.g. "0.7.0").
_kit_print_static_banner() {
  local _ver="${1:-}"
  printf '\n'
  if [ "${KIT_UNICODE:-0}" = "1" ]; then
    # V4 box-drawing letterforms — ink-dim body, single Azafran seed as I-dot of KIT.
    # Brief §7 exact layout (three rows of box-drawing, then lockup + tagline):
    #
    #   ┌─┐┬  ┌─┐┬ ┬┌┬┐┌─┐   ┬┌─┬┌┬┐
    #   │  │  ├─┤│ │ ││├┤    ├┴┐│ │      ●   <- Azafran seed (I-dot of KIT)
    #   └─┘┴─┘┴ ┴└─┘─┴┘└─┘   ┴ ┴┴ ┴
    #
    #   ⡶ / claude-kit   agentic workflows for your repo
    #   v0.7.0   · the seed is planted
    printf '  %s%s%s\n' \
      "${KIT_INK}" \
      '┌─┐┬  ┌─┐┬ ┬┌┬┐┌─┐   ┬┌─┬┌┬┐' \
      "${KIT_RESET}"
    # Row 2: letterforms + Azafran seed to the right (the I-dot of KIT)
    printf '  %s%s%s  %s%s%s\n' \
      "${KIT_INK}" '│  │  ├─┤│ │ ││├┤    ├┴┐│ │ ' "${KIT_RESET}" \
      "${KIT_AZAFRAN}" '●' "${KIT_RESET}"
    printf '  %s%s%s\n' \
      "${KIT_INK}" \
      '└─┘┴─┘┴ ┴└─┘─┴┘└─┘   ┴ ┴┴ ┴' \
      "${KIT_RESET}"
    printf '\n'
    # Lockup line: seed-head leader + wordmark + tagline
    printf '  %s%s%s%s%s\n' \
      "${KIT_AZAFRAN}" '⡶' "${KIT_RESET}" \
      "${KIT_INK}" " / claude-kit   agentic workflows for your repo${KIT_RESET}"
    if [ -n "$_ver" ]; then
      printf '  %s%s%s\n' "${KIT_POLVO}" "v${_ver}   · the seed is planted" "${KIT_RESET}"
    else
      printf '  %s%s%s\n' "${KIT_POLVO}" '· the seed is planted' "${KIT_RESET}"
    fi
  else
    # ASCII fallback — no box-drawing, no Braille (KIT_ASCII=1 or non-UTF-8 locale).
    printf '  CLAUDE KIT\n'
    printf '  ----------\n'
    printf '\n'
    printf '  o / claude-kit   agentic workflows for your repo\n'
    if [ -n "$_ver" ]; then
      printf '  v%s   . the seed is planted\n' "$_ver"
    else
      printf '  . the seed is planted\n'
    fi
  fi
  printf '\n'
}

# _kit_plant_animation — golden-angle Vogel seed-head plant animation (§7 beat 1).
#
# Guard: runs ONLY when stdout is a TTY AND KIT_UNICODE=1 (full Unicode, not ASCII mode).
# Uses ANSI cursor-up to repaint a 4-row Braille grid in-place as seeds enter.
#
# Geometry: n=13, fixed scale, 10x16 dot grid => 5 Braille cols x 4 rows.
#   Seed n at angle n*137.50776 deg, radius sqrt(n). Coordinates locked to the
#   full n=13 scatter so each seed lands in its final position (no rescaling).
#   Pre-computed in Python from the Vogel rule; see brief §2 for derivation.
#
# Animation frames (seeds visible: 1, 2, 4, 7, 13):
#   f1  = seed n=0 only  (center)
#   f2  = seeds n=0,1
#   f4  = seeds n=0..3
#   f7  = seeds n=0..6
#   ff  = seeds n=0..12 (full n=13 hero)
#
# Braille rows — each string is 5 Braille chars (U+2800-28FF).
# Row 0 = top, row 3 = bottom. Center seed (n=0) lives at row 1, col 2.
_kit_plant_animation() {
  [ -t 1 ]                     || return 0  # non-TTY: skip, banner will print statically
  [ "${KIT_UNICODE:-0}" = "1" ] || return 0  # ASCII mode: skip

  local ind='  '  # indent to align with banner text

  # Frame data — pre-computed Braille rows (5 chars each, 4 rows per frame).
  # Stored as positional arrays via function-local vars (portable; no declare -a needed).
  # Frame f1: seed n=0 (center seed only)
  local f1_0='⠀⠀⠀⠀⠀' f1_1='⠀⠀⢀⠀⠀' f1_2='⠀⠀⠀⠀⠀' f1_3='⠀⠀⠀⠀⠀'
  # Frame f2: seeds n=0,1
  local f2_0='⠀⠀⠀⠀⠀' f2_1='⠀⠀⢀⠀⠀' f2_2='⠀⠀⠂⠀⠀' f2_3='⠀⠀⠀⠀⠀'
  # Frame f4: seeds n=0..3
  local f4_0='⠀⠀⠀⠀⠀' f4_1='⠀⠀⢈⠀⠀' f4_2='⠀⠀⠂⠄⠀' f4_3='⠀⠀⠀⠀⠀'
  # Frame f7: seeds n=0..6
  local f7_0='⠀⠀⠀⠀⠀' f7_1='⠀⠄⢈⠐⠀' f7_2='⠀⠀⠂⠄⠀' f7_3='⠀⠀⠁⠀⠀'
  # Frame ff: seeds n=0..12 (full n=13 hero)
  local ff_0='⢀⠠⠀⠐⠀' ff_1='⠀⠄⢈⠐⠀' ff_2='⠠⠀⠂⠄⠂' ff_3='⠀⠀⠁⠄⠀'

  # Print one frame: 4 Braille rows in ink-dim.
  # Args: row0 row1 row2 row3
  _print_frame() {
    printf '%s%s%s\n' "${KIT_INK}${ind}" "$1" "${KIT_RESET}"
    printf '%s%s%s\n' "${KIT_INK}${ind}" "$2" "${KIT_RESET}"
    printf '%s%s%s\n' "${KIT_INK}${ind}" "$3" "${KIT_RESET}"
    printf '%s%s%s\n' "${KIT_INK}${ind}" "$4" "${KIT_RESET}"
  }

  # Cursor up N lines (ANSI CSI A).
  _cur_up() { printf '\033[%dA' "$1"; }

  # Portable fractional sleep — silently ignores if the system only takes integers.
  _psleep() { sleep "$1" 2>/dev/null || true; }

  # Print a leading blank line and the first frame (no repaint yet).
  printf '\n'
  _print_frame "$f1_0" "$f1_1" "$f1_2" "$f1_3"

  # Subsequent frames: cursor-up 4, repaint in-place.
  _psleep 0.12
  _cur_up 4; _print_frame "$f2_0" "$f2_1" "$f2_2" "$f2_3"

  _psleep 0.12
  _cur_up 4; _print_frame "$f4_0" "$f4_1" "$f4_2" "$f4_3"

  _psleep 0.12
  _cur_up 4; _print_frame "$f7_0" "$f7_1" "$f7_2" "$f7_3"

  _psleep 0.18
  _cur_up 4; _print_frame "$ff_0" "$ff_1" "$ff_2" "$ff_3"

  # Brief pause before the banner snaps in, then clear the animation grid.
  _psleep 0.30
  # Move up past the 4 grid rows + the blank line printed before the grid (5 lines total),
  # then erase from cursor to end of screen so the banner replaces the grid cleanly.
  _cur_up 5
  printf '\033[J'  # CSI J — erase from cursor to end of screen
}

# _kit_init_banner — entry point for a fresh init run (not --upgrade, not --dry-run).
# Arg 1 (optional): plugin version string without "v" prefix.
_kit_init_banner() {
  _kit_banner_detect_mode
  _kit_plant_animation           # no-op when non-TTY / KIT_ASCII=1 / non-UTF-8
  _kit_print_static_banner "${1:-}"   # always prints (static or after animation)
}

# ============================================================================
# END TERMINAL IDENTITY                                                        #
# ============================================================================

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---- preflight: run kit-doctor for Tier 1 hard deps (jq, perl, gh, git) ----
# Skip during --upgrade (already initialized) and --dry-run (read-only; doctor
# would be redundant). In interactive runs the doctor auto-installs what it can;
# if Tier 1 deps are still missing after it runs, init exits with a clear report.
_DOCTOR="$KIT_ROOT/scripts/kit-doctor.sh"
_INIT_SKIP_PREFLIGHT=0
for _ia in "$@"; do [[ "$_ia" == "--upgrade" || "$_ia" == "--dry-run" ]] && _INIT_SKIP_PREFLIGHT=1; done
# KIT_INIT_PREFLIGHT=0 skips it too: the fixture tests drive a FRESH init, and the doctor installs
# packages and checks gh auth — neither belongs in a network-free test.
[[ "${KIT_INIT_PREFLIGHT:-1}" == "0" ]] && _INIT_SKIP_PREFLIGHT=1

if [[ $_INIT_SKIP_PREFLIGHT -eq 0 && -x "$_DOCTOR" ]]; then
  # --yes: init's preflight installs Tier-1 deps non-interactively (no approval prompt here; the
  # user already opted into setup by running init). A human running `cckit doctor` directly is asked.
  bash "$_DOCTOR" --yes || {
    echo "" >&2
    echo "x kit-doctor reported unresolved issues — fix them and re-run /kit-init." >&2
    exit 1
  }
else
  # Fallback bare checks (upgrade/dry-run path: doctor was already run on init)
  command -v jq   >/dev/null 2>&1 || { echo "x jq is required."   >&2; exit 1; }
  command -v perl >/dev/null 2>&1 || { echo "x perl is required." >&2; exit 1; }
fi

# ---- parse flags ---------------------------------------------------------
_INIT_ARGS=("$@")   # as typed — the --upgrade dry run replays them against a copy (#448)
PROFILE=""; TARGET="$PWD"; NAME=""; SLUG=""; REPO=""; GH_OWNER=""; OWNER_NAME=""
PROJECT_NUMBER=""; PLANS_FORMAT=""; PLANS_DIR=""; MEMORY=""; LANG_PREF="English"; FORCE=0
PLAIN_LANGUAGE=""
SPECKIT=""; PREPUSH_CMD=""; LOCAL_LAYER=""; LOCAL_EXPLICIT=0; DRY_RUN=0; UPGRADE=0
ADAPTER_ARG=""    # --adapter as typed; resolved to ADAPTERS below (stored selection wins on upgrade)
# Guided setup (#456): the folder as typed, the git + GitHub steps, the advisor's answers.
FOLDER_GIVEN=0; NO_GITHUB=0; ASSUME_YES=0; REPO_VISIBILITY="private"; INIT_ANSWERS=""
RECIPE_ARG=""; DATABASE_ARG=""
SKILL_PREFIX=""   # namespace applied to kit-namespaced skill templates (from kit.config .skillPrefix on upgrade)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --target) TARGET="$2"; FOLDER_GIVEN=1; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --slug) SLUG="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --owner-login) GH_OWNER="$2"; shift 2 ;;
    --owner-name) OWNER_NAME="$2"; shift 2 ;;
    --project-number) PROJECT_NUMBER="$2"; shift 2 ;;
    --plans) PLANS_FORMAT="$2"; shift 2 ;;
    --plans-dir) PLANS_DIR="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --speckit) SPECKIT="$2"; shift 2 ;;
    --plain-language) PLAIN_LANGUAGE="$2"; shift 2 ;;
    --prepush) PREPUSH_CMD="$2"; shift 2 ;;
    --local) LOCAL_LAYER="$2"; LOCAL_EXPLICIT=1; shift 2 ;;
    --lang) LANG_PREF="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --upgrade) UPGRADE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --adapter) ADAPTER_ARG="$2"; shift 2 ;;
    --no-github) NO_GITHUB=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --public) REPO_VISIBILITY="public"; shift ;;
    --answers) INIT_ANSWERS="$2"; shift 2 ;;
    --recipe) RECIPE_ARG="$2"; shift 2 ;;
    --database) DATABASE_ARG="$2"; shift 2 ;;
    -h|--help) sed -n '2,41p' "$0"; exit 0 ;;
    -*) echo "x unknown flag: $1" >&2; exit 1 ;;
    *) if [[ $FOLDER_GIVEN -eq 1 ]]; then echo "x one folder only (got '$TARGET' and '$1')" >&2; exit 1; fi
       TARGET="$1"; FOLDER_GIVEN=1; shift ;;
  esac
done

# ---- adapter selection (E257.3) -------------------------------------------
# Validated here, before anything is written: an unknown adapter name refuses the whole run.
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/adapter-select.sh"
ADAPTERS_NEW=""
if [[ -n "$ADAPTER_ARG" ]]; then
  ADAPTERS_NEW="$(adapter_normalize "$ADAPTER_ARG")" || { echo "x --adapter takes claude, codex or both (got '$ADAPTER_ARG')" >&2; exit 1; }
fi
ADAPTERS="${ADAPTERS_NEW:-claude}"   # fresh init; --upgrade replaces this with the stored selection
ADAPTER_ADDED=0

# ---- guided setup: name the folder, ask what is missing (#456) -------------
# Before anything is written. `--upgrade` never enters it: an upgrade works on a project that is
# already set up and asks nothing.
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/init-guide.sh"
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/init-github.sh"
INIT_CLASS=""; INIT_NEW=0; INIT_ALREADY=0; RECIPE_FILE=""; DB_FILE=""; DB_STACK=""; SETUP_RUN=0
if [[ $UPGRADE -eq 0 ]]; then
  if [[ -n "$INIT_ANSWERS" && ! -f "$INIT_ANSWERS" ]]; then echo "x --answers: no such file: $INIT_ANSWERS" >&2; exit 2; fi
  if [[ -n "$INIT_ANSWERS" ]] && ! jq -e 'type == "object"' "$INIT_ANSWERS" >/dev/null 2>&1; then
    echo "x --answers: $INIT_ANSWERS is not a JSON object of {\"question\": \"answer\"}" >&2; exit 2
  fi
  init_guide_resolve
fi

# Installed plugin version -> recorded into kit.config as kitVersion (drives /kit-update checks).
PLUGIN_VERSION="$(jq -r '.version // "0.0.0"' "$KIT_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo "0.0.0")"

# ---- upgrade mode: backfill inputs from the project's existing config ----
if [[ $UPGRADE -eq 1 ]]; then
  UP_TARGET="$(cd "${TARGET:-$PWD}" && pwd)"
  UP_CFG="$(adapter_config_existing "$UP_TARGET" || true)"
  [[ -n "$UP_CFG" && -f "$UP_CFG" ]] || { echo "x --upgrade needs $UP_TARGET/.claude/kit.config.json (run /kit-init first)."; exit 1; }
  # The stored selection is the truth on upgrade. --adapter only ever ADDS to it: dropping an
  # adapter is an uninstall of its files, which is `cckit remove`'s job, not an upgrade side effect.
  ADAPTERS_HAVE="$(adapter_list_from_config "$UP_CFG")" || { echo "x $UP_CFG has an invalid 'adapters' value (expected claude and/or codex)." >&2; exit 1; }
  ADAPTERS="$(adapter_union "$ADAPTERS_HAVE" "$ADAPTERS_NEW")"
  [[ "$ADAPTERS" != "$ADAPTERS_HAVE" ]] && ADAPTER_ADDED=1

  # ---- guard: never apply the kit over its OWN home, or downgrade ----------
  # The kit is DEVELOPED in-tree in its home repo (packages/claude-kit-plugin/). Running
  # --upgrade there would copy the installed (usually OLDER) plugin snapshot over the live
  # source — the recurring "every time I improve the kit, /kit-update fights me" footgun.
  # Refuse cleanly (exit 0, not an error) so the home repo edits the source directly.
  if [[ -f "$UP_TARGET/packages/claude-kit-plugin/.claude-plugin/plugin.json" ]]; then
    echo "x $UP_TARGET is claude-kit's home repo -- edit packages/claude-kit-plugin/ directly; /kit-update is for consumer projects, not the kit's source."
    exit 0
  fi
  # Nothing to do when the installed plugin is the SAME version as the project (avoids the
  # confusing re-scan + any stray re-add). A genuinely-behind consumer (kitVersion < plugin)
  # still upgrades normally.
  _have_kv="$(jq -r '.kitVersion // "0.0.0"' "$UP_CFG" 2>/dev/null || echo 0.0.0)"
  # ...unless this run enables a second adapter: that is new work at the same version. So is a
  # Codex project whose hooks are not registered (a hooks.json that was unparseable at init, or a
  # project scaffolded before E257.5): `cckit doctor` sends the user here to repair exactly that.
  _cx_unregistered=0
  if adapter_has "$ADAPTERS" codex; then
    # shellcheck source=/dev/null
    . "$KIT_ROOT/scripts/lib/codex-hooks.sh"
    codex_hooks_registered "$UP_TARGET/.codex/hooks.json" guard-base-branch-commit.sh || _cx_unregistered=1
  fi
  if [[ "$_have_kv" == "$PLUGIN_VERSION" && $ADAPTER_ADDED -eq 0 && $_cx_unregistered -eq 0 ]]; then
    echo "x already at $PLUGIN_VERSION -- nothing to upgrade. (To pull a newer release, refresh the plugin cache: claude plugin update.)"
    exit 0
  fi

  [[ -z "$PROFILE" ]]      && PROFILE="$(jq -r '.profile // "minimal"' "$UP_CFG")"
  [[ -z "$NAME" ]]         && NAME="$(jq -r '.project.name // ""' "$UP_CFG")"
  [[ -z "$SLUG" ]]         && SLUG="$(jq -r '.project.slug // ""' "$UP_CFG")"
  [[ -z "$REPO" ]]         && REPO="$(jq -r '.github.repo // ""' "$UP_CFG")"
  [[ -z "$GH_OWNER" ]]     && GH_OWNER="$(jq -r '.github.owner // ""' "$UP_CFG")"
  [[ -z "$MEMORY" ]]       && MEMORY="$(jq -r 'if .memory.enabled then "on" else "off" end' "$UP_CFG")"
  [[ -z "$SPECKIT" ]]      && SPECKIT="$(jq -r 'if (.specKit.enabled // false) then "on" else "off" end' "$UP_CFG")"
  [[ -z "$LOCAL_LAYER" ]]  && LOCAL_LAYER="$(jq -r 'if (.local.enabled // false) then "on" else "off" end' "$UP_CFG")"
  # The stored switch is the truth on upgrade: a project that turned plain language off keeps it
  # off whatever its profile defaults to.
  [[ -z "$PLAIN_LANGUAGE" ]] && PLAIN_LANGUAGE="$(jq -r 'if (.plainLanguage.enabled // false) then "on" else "off" end' "$UP_CFG")"
  # A config with NO plans key at all deliberately runs without plan files — upgrade must not
  # resurrect the profile default (and with it the plans rule + config block) (#149).
  [[ -z "$PLANS_FORMAT" ]] && PLANS_FORMAT="$(jq -r 'if has("plans") then (.plans.format // "") else "none" end' "$UP_CFG")"
  [[ "$LANG_PREF" == "English" ]] && LANG_PREF="$(jq -r '.project.language // "English"' "$UP_CFG")"
  # Skill-name prefix: projects that namespace their kit skills (e.g. "kit-task-close") set
  # `skillPrefix` so upgrade scaffolds namespaced templates to the matching name instead of
  # creating bare-name duplicates. Empty = bare names (default).
  [[ -z "$SKILL_PREFIX" ]] && SKILL_PREFIX="$(jq -r '.skillPrefix // ""' "$UP_CFG")"
  _UPNUM="$(jq -r '.github.projectNumber // empty' "$UP_CFG")"
  [[ -z "$PROJECT_NUMBER" && -n "$_UPNUM" && "$_UPNUM" != "null" ]] && PROJECT_NUMBER="$_UPNUM"
  _UPPP="$(jq -r '.prePush.command // ""' "$UP_CFG")"
  [[ -z "$PREPUSH_CMD" && -n "$_UPPP" && "$_UPPP" != "null" ]] && PREPUSH_CMD="$_UPPP"

  # ---- upgrade exclusion registry (#334) ----------------------------------
  # `upgrade.removed[]` + keys of `upgrade.renamed{}` are paths the project
  # deleted/renamed ON PURPOSE. The upgrade must never re-add them ("add missing
  # files" doesn't know the project's deliberate state). Read from the EXISTING
  # config (pre-merge) into a newline-delimited list consumed by _upgrade_excluded.
  UPGRADE_EXCLUDE="$(jq -r '((.upgrade.removed // []) + ((.upgrade.renamed // {}) | keys)) | .[]' "$UP_CFG" 2>/dev/null || true)"

  # ---- dirty working tree guard (upgrade mode only) -----------------------
  # Refuse to write files into a project with uncommitted changes.
  # Safe no-op when git is unavailable or UP_TARGET is not a git repo.
  # Pass --force to skip at your own risk.
  if [[ $DRY_RUN -eq 0 && $FORCE -eq 0 ]]; then
    if git -C "$UP_TARGET" rev-parse --git-dir >/dev/null 2>&1; then
      _dirty="$(git -C "$UP_TARGET" status --porcelain 2>/dev/null || true)"
      if [[ -n "$_dirty" ]]; then
        echo "x working tree is dirty -- commit, stash, or discard before running /kit-update" >&2
        echo "  (pass --force to override at your own risk)" >&2
        exit 1
      fi
    fi
  fi
fi

[[ -z "$PROFILE" ]] && { echo "x --profile is required (software|content|research|minimal)"; exit 1; }
PROFILE_FILE="$KIT_ROOT/profiles/$PROFILE.json"
[[ -f "$PROFILE_FILE" ]] || { echo "x no such profile: $PROFILE ($PROFILE_FILE)"; exit 1; }

# ---- resolve target + defaults ------------------------------------------
# A folder that is not there yet is created when the first file is written, not here: a dry run
# and a declined confirmation leave nothing behind (#456).
if [[ -d "$TARGET" ]]; then TARGET="$(cd "$TARGET" && pwd)"; else TARGET="$(init_abs_path "$TARGET")"; fi
BASENAME="$(basename "$TARGET")"
# Prefer the ACTUAL repo name from the git remote — the local directory is often cloned/renamed to a
# different name — and only fall back to the directory basename (#73).
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/git-remote.sh"
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/hook-refresh.sh"   # hook_refresh_state — refresh unmodified hooks (#370)
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/upgrade-report.sh" # measured change list + minimal JSON writes (#448)
NAME_SRC="$(git_remote_repo_name "$TARGET" 2>/dev/null || true)"; NAME_SRC="${NAME_SRC:-$BASENAME}"
[[ -z "$NAME" ]] && NAME="$NAME_SRC"
[[ -z "$SLUG" ]] && SLUG="$(echo "$NAME_SRC" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-|-$//g')"
if [[ -z "$GH_OWNER" ]]; then GH_OWNER="$(gh api user --jq .login 2>/dev/null || echo "")"; fi
[[ -z "$OWNER_NAME" ]] && OWNER_NAME="${GH_OWNER:-owner}"
# Prefer the project's ACTUAL GitHub remote over an <owner>/<dir-basename> guess — the local
# directory name often differs from the repo name (would target a non-existent repo otherwise).
if [[ -z "$REPO" && $INIT_ALREADY -eq 1 ]]; then
  REPO="$(jq -r '.github.repo // empty' "$(adapter_config_existing "$TARGET")" 2>/dev/null || true)"
fi
[[ -z "$REPO" ]] && REPO="$(cd "$TARGET" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[[ -z "$REPO" && -n "$GH_OWNER" ]] && REPO="$GH_OWNER/$SLUG"
[[ -z "$REPO" ]] && REPO="$SLUG"

# ---- base branch ---------------------------------------------------------
# Rules that name the integration branch are TEMPLATED on it ({{BASE_BRANCH}}), so a project that
# integrates on `develop` does not scaffold a rule telling agents to branch from `main` (#283).
# Resolved the same way the rest of the kit resolves it (kit-config.sh: baseBranch -> integrationBranch
# -> flow -> "main"), then WRITTEN into the generated config below — a rendered rule that disagrees
# with KIT_BASE_BRANCH is the bug this parameterization exists to remove.
#   1. KIT_BASE_BRANCH from the environment (an explicit caller override)
#   2. the project's existing config, found by kit_config_path (re-init / --upgrade keeps the
#      project's choice) — the ONE resolver, so this honors $KIT_CONFIG and finds a config in an
#      ancestor directory. Hand-checking two TARGET-local filenames skipped both.
#   3. the repo's actual GitHub default branch (same source as REPO/GH_OWNER above)
#   4. "main"
# Unconditional, not `[[ -z ${BASE_BRANCH:-} ]]`: KIT_BASE_BRANCH is the DOCUMENTED override, and
# BASE_BRANCH is an internal name this script exports for `emit` — an inherited BASE_BRANCH from a
# caller's environment must not silently outrank it.
BASE_BRANCH="${KIT_BASE_BRANCH:-}"
if [[ -z "$BASE_BRANCH" ]]; then
  # shellcheck source=/dev/null
  . "$KIT_ROOT/scripts/lib/config-path.sh"
  _bb_cfg="$(kit_config_path "$TARGET" 2>/dev/null || true)"
  if [[ -n "$_bb_cfg" && -f "$_bb_cfg" ]]; then
    BASE_BRANCH="$(jq -r '.github.baseBranch // .github.integrationBranch // .github.flow // empty' "$_bb_cfg" 2>/dev/null || true)"
  fi
fi
[[ -z "$BASE_BRANCH" ]] && BASE_BRANCH="$(cd "$TARGET" 2>/dev/null && gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
# The git + GitHub setup (#456) runs when it is wanted AND confirmed: --yes, or a terminal to ask
# on. A dry run plans as if it were confirmed. A project with no `origin` remote that the setup is
# about to give a repository integrates on `develop` (main stays the release branch).
SETUP_WANTED=0; SETUP_BASE_CHOSEN=0
if [[ $UPGRADE -eq 0 && $NO_GITHUB -eq 0 ]] && { [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] || _ig_tty; }; then
  SETUP_WANTED=1
fi
if [[ -z "$BASE_BRANCH" && $SETUP_WANTED -eq 1 ]] && [[ -z "$(git -C "$TARGET" remote get-url origin 2>/dev/null || true)" ]]; then
  BASE_BRANCH="develop"; SETUP_BASE_CHOSEN=1
fi
[[ -z "$BASE_BRANCH" ]] && BASE_BRANCH="main"

# profile defaults
[[ -z "$PLANS_FORMAT" ]] && PLANS_FORMAT="$(jq -r '.defaults.plans_format' "$PROFILE_FILE")"
[[ -z "$MEMORY" ]] && MEMORY="$(jq -r '.defaults.memory' "$PROFILE_FILE")"
[[ -z "$SPECKIT" ]] && SPECKIT="$(jq -r '.defaults.speckit // "off"' "$PROFILE_FILE")"
[[ -z "$LOCAL_LAYER" ]] && LOCAL_LAYER="$(jq -r '.defaults.local // "off"' "$PROFILE_FILE")"
# Content work (E415). Profile defaults only — no flag: a project changes them in its config.
#   content_kinds on  -> kinds.content: true   (setup-labels.sh provisions the content kind labels)
CONTENT_KINDS="$(jq -r '.defaults.content_kinds // "off"' "$PROFILE_FILE")"
#   pr_body content   -> pr.bodyStyle: "content" (draft-and-review wording in generated PR bodies)
case "$CONTENT_KINDS" in on|true|yes) CONTENT_KINDS_ON="true";; *) CONTENT_KINDS_ON="false";; esac
#   plain_language on -> plainLanguage.enabled: true + the plain-language rule (--plain-language wins)
PR_BODY_STYLE="$(jq -r '.defaults.pr_body // "code"' "$PROFILE_FILE")"
[[ -z "$PLAIN_LANGUAGE" ]] && PLAIN_LANGUAGE="$(jq -r '.defaults.plain_language // "off"' "$PROFILE_FILE")"
case "$PLAIN_LANGUAGE" in on|true|yes) PLAIN_ON="true";; *) PLAIN_ON="false";; esac
[[ "$PR_BODY_STYLE" == "content" ]] || PR_BODY_STYLE="code"
if [[ -z "$PLANS_DIR" ]]; then
  case "$PLANS_FORMAT" in
    mdx) PLANS_DIR="apps/plans/src/briefs" ;;
    *)   PLANS_DIR="docs/plans" ;;
  esac
fi

# arrays from profile
ROLES_NL="$(jq -r '.roles[]' "$PROFILE_FILE")"
MS_NL="$(jq -r '.milestones[]' "$PROFILE_FILE")"
AGENTS="$(jq -r '.agents[]' "$PROFILE_FILE")"
SKILLS="$(jq -r '.skills[]' "$PROFILE_FILE")"
RULES="$(jq -r '.rules[]' "$PROFILE_FILE")"

# Kit-namespaced skill set: templates whose names take $SKILL_PREFIX (the workflow skills:
# task-*, effort-*). Content skills (morning-briefing, karpathy-…) are NOT listed and stay bare.
# Listed in templates/skills/NAMESPACED (one name per line) so the marker lives outside the artifact.
NAMESPACED_SKILLS="$(grep -vE '^\s*(#|$)' "$KIT_ROOT/templates/skills/NAMESPACED" 2>/dev/null || true)"
_is_namespaced() {  # <skill-name> -> 0 if it takes the prefix
  printf '%s\n' "$NAMESPACED_SKILLS" | grep -qxF "$1"
}
# Rewrite a freshly-scaffolded namespaced skill so its own name: + sibling /command refs + sigil
# label carry $SKILL_PREFIX (template ships bare; the project namespaces). The (?![\w-]) guard stops
# /task-pr matching inside /task-pr-merge. perl is a Tier-1 dep (kit-doctor).
_prefix_skill_file() {  # <file>
  local f="$1" n
  printf '%s\n' "$NAMESPACED_SKILLS" | while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    P="$SKILL_PREFIX" N="$n" perl -i -pe '
      my ($p,$n)=($ENV{P},$ENV{N});
      s{^name:\h*\Q$n\E\h*$}{name: $p$n};
      s{/\Q$n\E(?![\w-])}{/$p$n}g;
      s{kit_sigil "\Q$n\E"}{kit_sigil "$p$n"}g;
    ' "$f"
  done
}

ROLES_JSON="$(printf '%s' "$ROLES_NL" | jq -Rs 'split("\n")|map(select(length>0))')"
MS_JSON="$(printf '%s' "$MS_NL" | jq -Rs 'split("\n")|map(select(length>0))')"
ROLES_HUMAN="$(printf '%s' "$ROLES_NL" | paste -sd '·' - | sed 's/·/ · /g')"
MILESTONES_HUMAN="$(printf '%s' "$MS_NL" | paste -sd '·' - | sed 's/·/ · /g')"

# flags / booleans
if [[ -n "$PROJECT_NUMBER" ]]; then PROJECTS_V2="true"; PNUM_JSON="$PROJECT_NUMBER"; else PROJECTS_V2="false"; PNUM_JSON="null"; PROJECT_NUMBER="null"; fi
case "$MEMORY" in on|true|yes) MEMORY_BOOL="true";; *) MEMORY_BOOL="false";; esac
if [[ "$PLANS_FORMAT" == "none" ]]; then PLANS_ON="false"; else PLANS_ON="true"; fi
if echo "$ROLES_NL" | grep -qx "Designer"; then DESIGN_ON="true"; else DESIGN_ON="false"; fi
CLAUDE_PROJECT_SLUG="$(echo "$TARGET" | sed 's#/#-#g')"

# spec kit
case "$SPECKIT" in on|true|yes) SPECKIT_ON="true";; *) SPECKIT_ON="false";; esac
SPECKIT_JSON="$SPECKIT_ON"

# pre-push gate (opt-in: enabled when a check command is provided)
if [[ -n "$PREPUSH_CMD" ]]; then PREPUSH_ENABLED="true"; else PREPUSH_ENABLED="false"; fi

# local model layer (opt-in: mlx_lm.server for NL chores)
case "$LOCAL_LAYER" in on|true|yes) LOCAL_ON="true";; *) LOCAL_ON="false";; esac

# stack-gated build skills present in this profile?
if echo "$SKILLS" | grep -qE '^(feature-build-refine|supabase-patterns)$'; then STACK_SKILLS_ON="true"; else STACK_SKILLS_ON="false"; fi

# code graph (an integration, switched on by `cckit add <id>` — never by an init flag). A fresh
# scaffold therefore has it off; only --upgrade can find it on, in the project's existing config.
CODEGRAPH_ON="false"
if [[ $UPGRADE -eq 1 ]]; then
  _cg="$(jq -r '.codeGraph.provider // ""' "$UP_CFG" 2>/dev/null || true)"
  [[ -n "$_cg" && "$_cg" != "none" ]] && CODEGRAPH_ON="true"
fi

# FLAGS_ON drives <!-- IF:X --> resolution
FLAGS_ON=""
[[ "$MEMORY_BOOL" == "true" ]]  && FLAGS_ON="${FLAGS_ON}MEMORY,"
[[ "$PROJECTS_V2" == "true" ]]  && FLAGS_ON="${FLAGS_ON}PROJECTS_V2,"
[[ "$PLANS_ON" == "true" ]]         && FLAGS_ON="${FLAGS_ON}PLANS,"
[[ "$DESIGN_ON" == "true" ]]        && FLAGS_ON="${FLAGS_ON}DESIGN,"
[[ "$SPECKIT_ON" == "true" ]]       && FLAGS_ON="${FLAGS_ON}SPECKIT,"
[[ "$STACK_SKILLS_ON" == "true" ]]  && FLAGS_ON="${FLAGS_ON}STACK_SKILLS,"
[[ "$CODEGRAPH_ON" == "true" ]]     && FLAGS_ON="${FLAGS_ON}CODEGRAPH,"

# ---- build agent/skill tables -------------------------------------------
short_desc() { sed -n 's/^description: //p' "$1" | head -1 | cut -c1-92; }
AGENT_TABLE="| Agent | Role |
| ----- | ---- |"
for a in $AGENTS; do
  f="$KIT_ROOT/templates/agents/$a.md"
  [[ -f "$f" ]] || { echo "  missing agent template: $a" >&2; continue; }
  AGENT_TABLE="$AGENT_TABLE
| \`$a\` | $(short_desc "$f") |"
done
SKILL_TABLE="| Skill | When |
| ----- | ---- |"
for s in $SKILLS; do
  f="$KIT_ROOT/templates/skills/$s/SKILL.md"
  [[ -f "$f" ]] || { echo "  missing skill template: $s" >&2; continue; }
  SKILL_TABLE="$SKILL_TABLE
| \`$s\` | $(short_desc "$f") |"
done

# ---- export vars for substitution ---------------------------------------
export PROJECT_NAME="$NAME" PROJECT_SLUG="$SLUG" OWNER_NAME="$OWNER_NAME" COMMS_LANG="$LANG_PREF"
export PROFILE GH_REPO="$REPO" GH_OWNER="$GH_OWNER" PROJECT_NUMBER PROJECT_BOARD_TITLE="$NAME"
export BASE_BRANCH
export PLANS_DIR PLANS_FORMAT KNOWLEDGE_DIR="knowledge" WING="$SLUG" CLAUDE_PROJECT_SLUG
export MILESTONES_HUMAN ROLES_HUMAN AGENT_TABLE SKILL_TABLE
export KIT_FLAGS_ON="$FLAGS_ON"

# ---- per-adapter layout --------------------------------------------------
# One template set renders for both adapters. What differs is where the files land ({{ADAPTER_DIR}}),
# which IF:ADAPTER_* blocks survive, and the instruction file name — nothing else.
KITCFG="$(adapter_config_existing "$TARGET" || true)"
[[ -n "$KITCFG" ]] || KITCFG="$(adapter_config_default "$TARGET" "$ADAPTERS")"
CONFIG_REL="${KITCFG#"$TARGET"/}"
MANIFEST_REL="$(adapter_manifest_rel "$TARGET" "$ADAPTERS")"
export CONFIG_REL
_rule_enabled() {  # <rule> -> 0 unless its feature is off for this project
  case "$1" in
    mempalace)          [[ "$MEMORY_BOOL" == "true" ]] || return 1 ;;
    design-routing)     [[ "$DESIGN_ON"   == "true" ]] || return 1 ;;
    plan-output-format) [[ "$PLANS_ON"    == "true" ]] || return 1 ;;
    plain-language)     [[ "$PLAIN_ON"    == "true" ]] || return 1 ;;
  esac
  return 0
}
# The plain-language rule follows its switch, not the profile list: a profile that lists it gets it
# only while the switch is on, and `--plain-language on` adds it to a profile that does not list it.
if [[ "$PLAIN_ON" == "true" ]] && ! printf '%s\n' "$RULES" | grep -qx 'plain-language'; then
  RULES="$RULES
plain-language"
fi
RULE_LIST=""
for r in $RULES; do
  _rule_enabled "$r" && [[ -f "$KIT_ROOT/templates/rules/$r.md" ]] || continue
  RULE_LIST="${RULE_LIST:+$RULE_LIST
}- \`.agents/rules/$r.md\`"
done
export RULE_LIST
use_adapter() {  # <claude|codex> — point emit at that adapter's dir + IF blocks
  ADAPTER_DIR="$(adapter_dir "$1")"
  KIT_FLAGS_ON="${FLAGS_ON}ADAPTER_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]'),"
  ADAPTER_INSTRUCTIONS="$(adapter_instructions "$1")"
  export ADAPTER_DIR KIT_FLAGS_ON ADAPTER_INSTRUCTIONS
}
# Shared (adapter-neutral) files that name a rules path point at the first selected adapter's copy.
use_adapter "${ADAPTERS%% *}"

# emit: resolve IF blocks, then substitute {{VARS}}
render_tpl() {  # <src> -> stdout
  perl -0777 -pe '
    my %on = map { $_=>1 } grep { length } split /,/, ($ENV{KIT_FLAGS_ON}//"");
    1 while s{<!-- IF:(\w+) -->(.*?)<!-- /IF:\1 -->}{ $on{$1} ? $2 : "" }gse;
    s/\{\{(\w+)\}\}/ exists $ENV{$1} ? $ENV{$1} : "{{$1}}" /ge;
  ' "$1"
}
emit() {  # <src> <dest>
  mkdir -p "$(dirname "$2")"
  render_tpl "$1" > "$2"
  WRITTEN+=("${2#"$TARGET"/}")
}
WRITTEN=()   # every path this run wrote (not preserved) — the adapter-managed ones go in the manifest

# _upgrade_excluded: true when <rel> was removed/renamed by the project on purpose
# (registered in kit.config.json `upgrade.removed[]` / `upgrade.renamed{}`). Matches an
# entry exactly OR as a directory prefix (entry "/.claude/skills/foo" covers its SKILL.md
# + references/). Only meaningful in --upgrade; always false otherwise. (#334)
_upgrade_excluded() {  # <rel>
  [[ $UPGRADE -eq 1 ]] || return 1
  local rel="$1" e
  while IFS= read -r e; do
    [[ -z "$e" ]] && continue
    [[ "$rel" == "$e" || "$rel" == "$e"/* ]] && return 0
  done <<< "${UPGRADE_EXCLUDE:-}"
  return 1
}

# safe_write: in --upgrade, never overwrite an existing file (preserve user edits) and never
# re-add a config-excluded path — only add genuinely new files. In normal mode it is just emit.
# Tracks added / preserved / skipped-by-config paths for the upgrade summary. (#334)
safe_write() {  # <src> <dest>
  local rel="${2#"$TARGET"/}"
  if _upgrade_excluded "$rel"; then
    UPGRADE_SKIPPED+=("$rel"); return 0
  fi
  if [[ $UPGRADE -eq 1 && -e "$2" ]]; then
    UPGRADE_PRESERVED+=("$rel"); return 0
  fi
  emit "$1" "$2"
  [[ $UPGRADE -eq 1 ]] && UPGRADE_ADDED+=("$rel")
  return 0
}

# safe_copy: verbatim (non-templated) counterpart of safe_write for kit-owned files copied
# as-is (scripts/, skill references). Honors the SAME upgrade contract — existing files are
# PRESERVED, config-excluded paths are SKIPPED — fixing the downgrade where scripts/ used to
# be unconditionally overwritten with older templates. Pass "exec" as $3 to chmod +x. (#334)
safe_copy() {  # <src> <dest> [exec]
  local rel="${2#"$TARGET"/}"
  [[ -f "$1" ]] || return 0
  if _upgrade_excluded "$rel"; then
    UPGRADE_SKIPPED+=("$rel"); return 0
  fi
  if [[ $UPGRADE -eq 1 && -e "$2" ]]; then
    UPGRADE_PRESERVED+=("$rel"); return 0
  fi
  mkdir -p "$(dirname "$2")"
  cp "$1" "$2"
  WRITTEN+=("$rel")
  [[ "${3:-}" == "exec" ]] && chmod +x "$2" 2>/dev/null
  [[ $UPGRADE -eq 1 ]] && UPGRADE_ADDED+=("$rel")
  return 0
}

# hook_write: safe_write for a kit-owned HOOK (#370). In --upgrade an existing hook is refreshed when
# it is an unmodified copy of an earlier template version (hook_refresh_state: the manifest hash or
# cckit's own template history), and reported as drifted — never overwritten — when the repo
# customized it. Everything else (new file, config-excluded path, normal init) is safe_write.
hook_write() {  # <src> <dest>
  local rel="${2#"$TARGET"/}" state
  if [[ $UPGRADE -ne 1 || ! -e "$2" ]] || _upgrade_excluded "$rel"; then safe_write "$1" "$2"; return 0; fi
  state="$(hook_refresh_state "$2" "$1" "$KIT_ROOT" "$TARGET/$MANIFEST_REL" "$rel")"
  case "$state" in
    refresh) emit "$1" "$2"; UPGRADE_REFRESHED+=("$rel") ;;
    drifted) UPGRADE_DRIFTED+=("$rel") ;;
    *)       UPGRADE_PRESERVED+=("$rel") ;;
  esac
  return 0
}

# ---- git + GitHub setup: the whole plan first, then ONE confirmation (#456) ----
# Nothing has been written yet. --yes confirms; a terminal is asked once; with neither, the setup
# does not run and the run says so at the end (re-run with --yes). A dry run only prints the plan.
IG_TARGET="$TARGET"; IG_REPO="$REPO"; IG_BASE="$BASE_BRANCH"; IG_VISIBILITY="$REPO_VISIBILITY"
IG_PROJECTS_V2="$PROJECTS_V2"; IG_KIT_ROOT="$KIT_ROOT"; IG_DOCTOR=1
[[ "${KIT_INIT_PREFLIGHT:-1}" == "0" ]] && IG_DOCTOR=0   # the fixture tests' switch: no doctor, no network
SETUP_DECLINED=0
if [[ $SETUP_WANTED -eq 1 && $DRY_RUN -eq 0 ]]; then
  echo ""
  echo "cckit init is about to set up \"$NAME\" in $TARGET"
  [[ -n "$RECIPE_FILE" ]] && echo "  Starting point: $(jq -r .label "$RECIPE_FILE")"
  [[ -n "$DB_FILE" ]] && echo "  Database: $(jq -r .label "$DB_FILE")"
  echo "  Git and GitHub setup:"
  init_setup_plan | sed 's/^/  /'
  if [[ $ASSUME_YES -eq 1 ]]; then
    SETUP_RUN=1
  else
    printf '\nGo ahead? [Y/n]  (n = only the files in the folder; nothing is created on GitHub) '
    IFS= read -r _setup_ok || _setup_ok="n"
    case "$_setup_ok" in ""|y|Y|yes|Yes|YES) SETUP_RUN=1 ;; *) SETUP_DECLINED=1 ;; esac
  fi
  # Declined: the project keeps the base branch it would have had without the setup.
  if [[ $SETUP_RUN -eq 0 && $SETUP_BASE_CHOSEN -eq 1 ]]; then BASE_BRANCH="main"; IG_BASE="main"; fi
fi

# _init_finish — the closing lines of a guided run: the database guide, why the setup did not run
# (when it did not), the step totals. Exits 1 when a step failed, 0 otherwise.
_init_finish() {
  local _d _s _f
  if [[ -n "$DB_FILE" ]]; then database_guide "$DB_FILE" "$TARGET"; fi
  if [[ $UPGRADE -eq 0 && $NO_GITHUB -eq 0 && $SETUP_RUN -eq 0 ]]; then
    echo ""
    if [[ $SETUP_DECLINED -eq 1 ]]; then
      echo "Git and GitHub setup: not run (you answered no). To run it later: cckit init --yes   (inside $TARGET)"
    else
      echo "Git and GitHub setup: not run — there is no terminal to confirm on."
      echo "  To run it: cckit init --yes   (inside $TARGET).  To leave it out on purpose: --no-github."
    fi
  fi
  if [[ -n "$INIT_STEP_LOG" ]]; then
    _d="$(printf '%s' "$INIT_STEP_LOG" | grep -c '^  \[done' || true)"
    _s="$(printf '%s' "$INIT_STEP_LOG" | grep -c '^  \[skipped' || true)"
    _f="$(printf '%s' "$INIT_STEP_LOG" | grep -c '^  \[failed' || true)"
    echo ""
    echo "Result: $_d done · $_s skipped (already there, or not available) · $_f failed"
    if [[ "$_f" -gt 0 ]]; then
      printf '%s' "$INIT_STEP_LOG" | grep '^  \[failed'
      echo "Fix what failed and run cckit init again: finished steps are skipped."
    fi
  fi
  if [[ -n "$RECIPE_FILE" && $INIT_FAILED -eq 0 ]]; then
    _s="$(jq -r '.start // empty' "$RECIPE_FILE")"
    [[ -n "$_s" ]] && echo "To see the project running: cd $TARGET && $_s"
  fi
  [[ $INIT_FAILED -gt 0 ]] && exit 1
  exit 0
}

# ---- dry run: print the plan and exit, writing nothing -------------------
if [[ $DRY_RUN -eq 1 ]]; then
  echo "-> DRY RUN — nothing will be written. Plan for $TARGET:"
  [[ $UPGRADE -eq 1 ]] && echo "  (UPGRADE: existing files are PRESERVED; only genuinely-missing files are added; config keys merged.)"
  [[ $UPGRADE -eq 1 && -n "${UPGRADE_EXCLUDE:-}" ]] && { echo "  (SKIPPED by kit.config upgrade.removed/renamed — never re-added:)"; printf '%s\n' "${UPGRADE_EXCLUDE}" | sed 's/^/      - /'; }
  echo ""
  echo "  Profile : $PROFILE"
  echo "  Project : $NAME ($SLUG)"
  echo "  Repo    : $REPO"
  echo "  Base    : $BASE_BRANCH   (rules that name the integration branch render this)"
  echo "  Adapters: $ADAPTERS$([[ $ADAPTER_ADDED -eq 1 ]] && echo "   (adding to stored: $ADAPTERS_HAVE)")"
  echo "  Board   : $([[ "$PROJECTS_V2" == "true" ]] && echo "Projects v2 #$PROJECT_NUMBER" || echo "off (gh issues only)")"
  echo "  Memory  : $MEMORY_BOOL   Plans: $PLANS_FORMAT   Lang: $LANG_PREF"
  echo "  Spec Kit: $SPECKIT_ON   Pre-push gate: $PREPUSH_ENABLED   Local model: $LOCAL_ON   kitVersion: $PLUGIN_VERSION"
  [[ "$CONTENT_KINDS_ON" == "true" ]] && echo "  Content : kind labels post · campaign · brand · research"
  [[ "$PR_BODY_STYLE" == "content" ]] && echo "  PR text : content (draft and review wording)"
  [[ "$PLAIN_ON" == "true" ]] && echo "  Wording : plain language (draft, review, approve)"
  echo ""
  if [[ $UPGRADE -eq 1 ]]; then
    # An upgrade's dry run is the upgrade itself, run on a temporary copy of the kit-managed paths
    # and measured (#448) — not the list below, which names everything a FRESH init can write.
    upgrade_dry_run "$TARGET" "$KIT_ROOT/scripts/init.sh" "${_INIT_ARGS[@]}" || exit $?
    echo ""
    echo "  A = added · M = modified. Measured by running the upgrade on a temporary copy; $TARGET was not written."
    echo "Re-run without --dry-run to apply."
    exit 0
  fi
  # A project that already has the kit files (#456): a real run leaves them alone, so the plan is
  # the database option and the setup steps, not the file list.
  if [[ $INIT_ALREADY -eq 1 && ( $SETUP_WANTED -eq 1 || -n "$DB_FILE" ) ]]; then
    echo "  cckit files: already there ($CONFIG_REL) — a run leaves them as they are (--upgrade merges in new kit features)."
    echo ""
    if [[ -n "$DB_FILE" ]]; then
      echo "  Database option $(jq -r .id "$DB_FILE") would add what is missing of:"
      database_plan "$DB_FILE" "$DB_STACK"
      echo ""
    fi
    if [[ $SETUP_WANTED -eq 1 ]]; then
      echo "  Git and GitHub setup would run these steps (nothing is written to GitHub by a dry run):"
      init_setup_plan | sed 's/^/  /'
      echo ""
    fi
    echo "Re-run without --dry-run to apply."
    exit 0
  fi
  echo "  Would write:"
  echo "    $CONFIG_REL"
  echo "    $MANIFEST_REL   (ownership manifest, gitignored)"
  if adapter_has "$ADAPTERS" claude; then
  echo "    .claude/settings.local.json"
  echo "    .claude/hooks/repo-hygiene.sh             (SessionStart: read-only repo-hygiene report)"
  echo "    .claude/hooks/guard-base-branch-commit.sh (PreToolUse Bash: block commits to base branch)"
  echo "    .claude/hooks/guard-raw-git-ops.sh   (PreToolUse Bash, tracked settings.json: raw gh/git -> cckit verb)"
  echo "    .claude/hooks/kit_version_check.sh   (SessionStart: update check)"
  echo "    .claude/hooks/kit-mail-check.sh      (session mail, tracked settings.json: PostToolUse / UserPromptSubmit / SessionStart / Stop)"
  for a in $AGENTS; do
    [[ -f "$KIT_ROOT/templates/agents/$a.md" ]] && echo "    .claude/agents/$a/AGENT.md"
  done
  fi
  for _ad in $ADAPTERS; do
    _add="$(adapter_dir "$_ad")"
    echo "    $(adapter_instructions "$_ad")"
    for r in $RULES; do
      _rule_enabled "$r" || continue
      [[ -f "$KIT_ROOT/templates/rules/$r.md" ]] && echo "    $_add/rules/$r.md"
    done
    [[ "$CODEGRAPH_ON" == "true" ]] && echo "    $_add/rules/code-retrieval.md           (codeGraph.provider is set)"
    for s in $SKILLS; do
      _dn="$s"; { [[ -n "$SKILL_PREFIX" ]] && _is_namespaced "$s"; } && _dn="${SKILL_PREFIX}${s}"
      [[ -f "$KIT_ROOT/templates/skills/$s/SKILL.md" ]] && echo "    $_add/skills/$_dn/SKILL.md"
      [[ -d "$KIT_ROOT/templates/skills/$s/references" ]] && echo "    $_add/skills/$_dn/references/"
    done
  done
  if adapter_has "$ADAPTERS" codex; then
  echo "    .codex/hooks/ (repo-hygiene.sh, kit_version_check.sh, kit-mail-check.sh, guard-base-branch-commit.sh, guard-raw-git-ops.sh$([[ "$PREPUSH_ENABLED" == "true" ]] && echo ", prepush_gate.sh")$([[ "$LOCAL_ON" == "true" ]] && echo ", kit-local-status.sh"))"
  echo "    .codex/hooks.json                         (merged: cckit's registrations are added, yours are kept; trust them in Codex with /hooks)"
  for a in $AGENTS; do
    [[ -f "$KIT_ROOT/templates/agents/$a.md" ]] && echo "    .codex/agents/$a.toml"
  done
  echo "    (Codex adapter: no memory hooks — they read Claude Code transcripts)"
  fi
  echo "    scripts/ (kit-config.sh, gh-project.sh, kit-version-check.sh, setup-labels.sh, setup-milestones.sh, capture-project-ids.sh, task-sync.sh, knowledge-lint.sh, review-lint.sh + review-rules.conf, skill-frontmatter-lint.sh, instruction-budget-lint.sh)"
  echo "    knowledge/INDEX.md                        (knowledge-base manifest — rules/knowledge-base.md)"
  if adapter_has "$ADAPTERS" claude; then
  echo "    .claude/lib/kit-sigil.sh                  (claude-kit attribution sigil helper, sourced by task-* footers)"
  [[ "$MEMORY_BOOL"     == "true" ]] && echo "    .claude/hooks/mempal_session_start.sh + mempal_save.sh + mempal_precompact.sh + mempal_followup.sh   (SessionStart / Stop / PreCompact / SessionEnd)"
  [[ "$MEMORY_BOOL"     == "true" ]] && echo "    .claude/mempal-identity.$SLUG.txt              (per-wing wake-up header — edit the Stack line)"
  [[ "$PREPUSH_ENABLED" == "true" ]] && echo "    .claude/hooks/prepush_gate.sh   (PreToolUse Bash gate: $PREPUSH_CMD)"
  [[ "$LOCAL_ON"        == "true" ]] && echo "    .claude/hooks/kit-local-status.sh   (SessionStart: announce local model layer when alive)"
  fi
  echo ""
  echo "  Onboarding would offer (opt-in): gh auth$([[ "$MEMORY_BOOL" == "true" ]] && echo " · MemPalace (mempalace-mcp)") · gws (if you use Google Workspace) · local model layer (--local on: NL chores at \$0 via mlx_lm.server)"
  echo ""
  if [[ -n "$RECIPE_FILE" ]]; then
    echo "  Recipe $(jq -r .id "$RECIPE_FILE") would run, in $TARGET:"
    recipe_plan "$RECIPE_FILE"
    echo ""
  fi
  if [[ -n "$DB_FILE" ]]; then
    echo "  Database option $(jq -r .id "$DB_FILE") would add:"
    database_plan "$DB_FILE" "$DB_STACK"
    echo ""
  fi
  if [[ $SETUP_WANTED -eq 1 ]]; then
    echo "  Git and GitHub setup would run these steps (nothing is written to GitHub by a dry run):"
    init_setup_plan | sed 's/^/  /'
    echo ""
  elif [[ $NO_GITHUB -eq 1 ]]; then
    echo "  Git and GitHub setup: off (--no-github)."
    echo ""
  fi
  echo "Re-run without --dry-run to write these files."
  exit 0
fi

# ---- guard ---------------------------------------------------------------
if [[ -e "$KITCFG" && $FORCE -eq 0 && $UPGRADE -eq 0 ]]; then
  # A re-run of the guided setup on a project that already has the kit files (#456): the files are
  # left as they are, and only the steps that are still missing run.
  if [[ $SETUP_RUN -eq 1 || -n "$DB_FILE" ]]; then
    echo ""
    echo "-> $TARGET already has the cckit files ($CONFIG_REL)"
    init_step skipped "cckit files" "already there (cckit init --upgrade merges in new kit features)"
    if [[ -n "$DB_FILE" ]]; then database_apply "$DB_FILE" "$DB_STACK" "$TARGET"; fi
    if [[ $SETUP_RUN -eq 1 ]]; then init_setup_run; fi
    _init_finish
  fi
  echo "  $TARGET already initialized ($CONFIG_REL). Re-run with --upgrade to merge in new features (preserves your edits), or --force to overwrite generated files."
  exit 1
fi

# ---- recipe + database: the project itself, before the kit files (#456) ---
# The recipe's generators want an empty folder, so they run first; the kit files land on top.
if [[ -n "$RECIPE_FILE" ]]; then
  echo ""
  echo "-> Starting point: $(jq -r .label "$RECIPE_FILE")  (this downloads packages and can take a few minutes)"
  if ! recipe_run "$RECIPE_FILE" "$TARGET"; then
    echo "" >&2
    echo "x The starting point could not be built, so nothing else was set up." >&2
    echo "  Fix the problem shown above, delete the folder $TARGET, and run cckit init again." >&2
    exit 1
  fi
fi
if [[ -n "$DB_FILE" ]]; then
  echo ""
  echo "-> Database: $(jq -r .label "$DB_FILE")"
  mkdir -p "$TARGET"
  database_apply "$DB_FILE" "$DB_STACK" "$TARGET"
fi

# ---- init banner (fresh init only; not on --upgrade) ---------------------
# Beat 1: golden-angle plant animation (TTY + Unicode only, else skipped).
# Beat 2: V4 box-drawing CLAUDE KIT banner snap (always).
if [[ $UPGRADE -eq 0 ]]; then
  _kit_init_banner "$PLUGIN_VERSION"
fi

UPGRADE_ADDED=(); UPGRADE_PRESERVED=(); UPGRADE_SKIPPED=(); UPGRADE_REFRESHED=(); UPGRADE_DRIFTED=()
# Checksums of the kit-managed paths before the first write: the summary prints what differs after
# the last one, so a file a later step merges into is reported as modified, not as preserved (#448).
_UP_SNAP=""
if [[ $UPGRADE -eq 1 && -z "${KIT_UPGRADE_SIMULATED:-}" ]]; then
  _UP_SNAP="$(mktemp -d)" && upgrade_snapshot "$TARGET" > "$_UP_SNAP/before"
fi
echo "-> $([[ $UPGRADE -eq 1 ]] && echo Upgrading || echo Scaffolding) $PROFILE profile $([[ $UPGRADE -eq 1 ]] && echo in || echo into) $TARGET"
mkdir -p "$TARGET/scripts/lib" "$(dirname "$KITCFG")"
adapter_has "$ADAPTERS" claude && mkdir -p "$TARGET/.claude/agents" "$TARGET/.claude/skills" "$TARGET/.claude/rules"

# ---- kit.config.json (built with jq for correctness) --------------------
# Location: .claude/kit.config.json when the Claude adapter is selected (the layout every existing
# project has); the root cckit.config.json for a Codex-only project, which gets no .claude/ tree.
jq -n \
  --argjson adapters "$(adapter_json "$ADAPTERS")" \
  --arg kitver "$PLUGIN_VERSION" \
  --arg name "$NAME" --arg slug "$SLUG" --arg owner "$OWNER_NAME" --arg lang "$LANG_PREF" --arg path "$TARGET" \
  --arg profile "$PROFILE" --argjson roles "$ROLES_JSON" \
  --arg repo "$REPO" --arg ghowner "$GH_OWNER" \
  --arg base "$BASE_BRANCH" \
  --argjson pv2 "$PROJECTS_V2" --argjson pnum "$PNUM_JSON" --arg ptitle "$NAME" \
  --argjson milestones "$MS_JSON" \
  --arg pfmt "$PLANS_FORMAT" --arg pdir "$PLANS_DIR" \
  --argjson mem "$MEMORY_BOOL" --arg wing "$SLUG" --arg cps "$CLAUDE_PROJECT_SLUG" \
  --argjson speckit "$SPECKIT_JSON" \
  --argjson ppen "$PREPUSH_ENABLED" --arg ppcmd "$PREPUSH_CMD" \
  --argjson localon "$LOCAL_ON" \
  --argjson ckinds "$CONTENT_KINDS_ON" --arg prbody "$PR_BODY_STYLE" --argjson plain "$PLAIN_ON" \
  '{kitVersion:$kitver,
    adapters:$adapters,
    project:{name:$name,slug:$slug,owner:$owner,language:$lang,path:$path},
    profile:$profile, roles:$roles,
    github:{repo:$repo,owner:$ghowner,baseBranch:$base,projectsV2:$pv2,projectNumber:$pnum,projectTitle:$ptitle},
    milestones:$milestones,
    plans:{format:$pfmt,dir:$pdir},
    knowledge:{dir:"knowledge"},
    specKit:{enabled:$speckit},
    prePush:{enabled:$ppen,command:$ppcmd},
    local:{enabled:$localon,port:8080,model:"mlx-community/Qwen3-8B-4bit"},
    memory:{enabled:$mem,provider:"mempalace",wing:$wing,claudeProjectSlug:$cps}}
   # Content-work keys are written only when the profile turns them on, so the config of a
   # software project does not gain keys it never reads (E415).
   | if $ckinds then .kinds = {content:true} else . end
   | if $prbody == "content" then .pr = {bodyStyle:"content"} else . end
   | if $plain then .plainLanguage = {enabled:true} else . end
   # A Codex-only config is the tracked root file, so it carries no absolute machine path.
   | if ($adapters | index("claude")) then . else del(.project.path) end' \
  > "$KITCFG.kit-new"
if [[ $UPGRADE -eq 1 && -f "$KITCFG" ]]; then
  # deep-merge: existing values win (preserve user choices), new REQUIRED keys added, version
  # bumped. FEATURE blocks (plans/specKit/prePush/local/memory) are additive only when the
  # project's config ALREADY has them — a missing feature key is a deliberate absence, and an
  # upgrade must never inject profile defaults over it (#149). `adapters` follows the same rule: a
  # config without the key means Claude, and an upgrade that changes nothing must not write it.
  # The project's key order is kept: a key the template adds goes after the keys already there, at
  # every depth. (`$tmpl * $have` gave the same values in the TEMPLATE's order, which moved the
  # project's own blocks around on every upgrade — #448.)
  jq -s --arg kitver "$PLUGIN_VERSION" '
    def fill($h; $t):
      if ($h | type) == "object" and ($t | type) == "object"
      then reduce ($t | keys_unsorted[]) as $k ($h;
             if has($k) then .[$k] = fill($h[$k]; $t[$k]) else .[$k] = $t[$k] end)
      else $h end;
    .[1] as $have
    | (.[0] | with_entries(.key as $k | select(
        (["plans","specKit","prePush","local","memory","adapters","plainLanguage"] | index($k)) == null
        or ($have | has($k))))) as $tmpl
    | fill($have; $tmpl) | .kitVersion = $kitver' "$KITCFG.kit-new" "$KITCFG" \
    > "$KITCFG.merged"
  rm -f "$KITCFG.kit-new"
  # Existing values win in the merge — but an EXPLICIT --local flag is a user decision now,
  # so it overrides the preserved value (port/model stay as the user configured them).
  if [[ $LOCAL_EXPLICIT -eq 1 ]]; then
    jq --argjson v "$LOCAL_ON" '.local = ((.local // {port:8080,model:"mlx-community/Qwen3-8B-4bit"}) | .enabled = $v)' \
      "$KITCFG.merged" > "$KITCFG.tmp" && mv "$KITCFG.tmp" "$KITCFG.merged"
  fi
  # An explicit --adapter is a decision made now, so it is written even where the key was absent.
  if [[ -n "$ADAPTERS_NEW" ]]; then
    jq --argjson v "$(adapter_json "$ADAPTERS")" '.adapters = $v' "$KITCFG.merged" > "$KITCFG.tmp" && mv "$KITCFG.tmp" "$KITCFG.merged"
  fi
  # Written with the fewest changed lines: a version bump alone edits the one `kitVersion` line and
  # leaves the file's formatting as the project keeps it. A merge that adds keys re-serialises it.
  _cfg_how="$(json_write_minimal "$KITCFG.merged" "$KITCFG")"
  echo "  + $CONFIG_REL (merged · kitVersion -> $PLUGIN_VERSION · $_cfg_how)"
else
  mv "$KITCFG.kit-new" "$KITCFG"
  echo "  + $CONFIG_REL"
fi

# ---- agents: one role source, one definition per selected runtime (E257.6) ----
# templates/agents/<role>.md is the role. Claude Code reads it as markdown; Codex reads a custom
# agent as TOML, so the SAME rendered role is translated by agent_def_codex (scripts/lib/agent-def.sh).
if adapter_has "$ADAPTERS" claude; then
use_adapter claude
for a in $AGENTS; do
  src="$KIT_ROOT/templates/agents/$a.md"
  [[ -f "$src" ]] || continue
  safe_write "$src" "$TARGET/.claude/agents/$a/AGENT.md"
  echo "  + .claude/agents/$a/AGENT.md"
done
fi
if adapter_has "$ADAPTERS" codex; then
use_adapter codex
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/agent-def.sh"
for a in $AGENTS; do
  src="$KIT_ROOT/templates/agents/$a.md"
  [[ -f "$src" ]] || continue
  _ca_rel=".codex/agents/$a.toml"; _ca_dst="$TARGET/$_ca_rel"
  if _upgrade_excluded "$_ca_rel"; then UPGRADE_SKIPPED+=("$_ca_rel"); continue; fi
  if [[ $UPGRADE -eq 1 && -e "$_ca_dst" ]]; then UPGRADE_PRESERVED+=("$_ca_rel"); continue; fi
  if [[ $UPGRADE -eq 0 && $FORCE -eq 0 && -e "$_ca_dst" ]]; then
    # A fresh init over a .codex/agents/ the user already keeps: their file wins, as AGENTS.md does.
    echo "  = $_ca_rel (already there — kept; --force replaces it)"; continue
  fi
  _ca_tmp="$(mktemp)"
  render_tpl "$src" > "$_ca_tmp"
  mkdir -p "$TARGET/.codex/agents"
  if agent_def_codex "$_ca_tmp" > "$_ca_dst.kit-new"; then
    mv "$_ca_dst.kit-new" "$_ca_dst"
    WRITTEN+=("$_ca_rel")
    [[ $UPGRADE -eq 1 ]] && UPGRADE_ADDED+=("$_ca_rel")
    echo "  + $_ca_rel"
  else
    rm -f "$_ca_dst.kit-new"
    echo "  ! $_ca_rel not written — templates/agents/$a.md has no name or description" >&2
  fi
  rm -f "$_ca_tmp"
done
fi
use_adapter "${ADAPTERS%% *}"

# ---- instructions + rules + skills, once per selected adapter ------------
# Same templates, same loop: the adapter decides the destination dir and the IF:ADAPTER_* blocks.
# A second adapter's pass never touches the first one's tree.
for _ad in $ADAPTERS; do
use_adapter "$_ad"
AD="$ADAPTER_DIR"; _instr="$(adapter_instructions "$_ad")"

# CLAUDE.md / AGENTS.md — one source (templates/instructions.md.tmpl). A pre-existing AGENTS.md is
# usually the project's own contract, so a fresh init keeps it unless --force (CLAUDE.md keeps its
# historical behavior: a fresh init writes it).
if [[ "$_ad" == "codex" && -e "$TARGET/$_instr" && $UPGRADE -eq 0 && $FORCE -eq 0 ]]; then
  echo "  = $_instr exists — kept (re-run with --force to replace it with the cckit instructions)"
else
  safe_write "$KIT_ROOT/templates/instructions.md.tmpl" "$TARGET/$_instr"
  echo "  + $_instr"
fi

# ---- rules (filtered by enabled flags) ----------------------------------
for r in $RULES; do
  # Skip rules whose feature is disabled for this project.
  _rule_enabled "$r" || continue
  src="$KIT_ROOT/templates/rules/$r.md"
  [[ -f "$src" ]] || { echo "  missing rule: $r"; continue; }
  safe_write "$src" "$TARGET/$AD/rules/$r.md"
  echo "  + $AD/rules/$r.md"
done
# code-retrieval is in no profile: `cckit add <id>` writes it when a code-graph integration is
# switched on. An upgrade re-adds it only for a project whose config already has one on.
if [[ "$CODEGRAPH_ON" == "true" ]]; then
  safe_write "$KIT_ROOT/templates/rules/code-retrieval.md" "$TARGET/$AD/rules/code-retrieval.md"
  echo "  + $AD/rules/code-retrieval.md"
fi

# ---- skills --------------------------------------------------------------
for s in $SKILLS; do
  src="$KIT_ROOT/templates/skills/$s/SKILL.md"
  [[ -f "$src" ]] || continue
  # Namespaced skills take $SKILL_PREFIX so we scaffold to the project's name (kit-task-close)
  # instead of a bare-name duplicate (task-close) alongside it.
  dest_name="$s"
  if [[ -n "$SKILL_PREFIX" ]] && _is_namespaced "$s"; then
    dest_name="${SKILL_PREFIX}${s}"
  fi
  safe_write "$src" "$TARGET/$AD/skills/$dest_name/SKILL.md"
  # If prefixed AND this was a FRESH scaffold (frontmatter still bare), rewrite name + sibling refs.
  # An existing (preserved) skill already reads `name: $dest_name`, so the guard skips it.
  if [[ "$dest_name" != "$s" && -f "$TARGET/$AD/skills/$dest_name/SKILL.md" ]] \
     && grep -qE "^name:[[:space:]]*${s}[[:space:]]*\$" "$TARGET/$AD/skills/$dest_name/SKILL.md"; then
    _prefix_skill_file "$TARGET/$AD/skills/$dest_name/SKILL.md"
  fi
  echo "  + $AD/skills/$dest_name/SKILL.md"
  # bundled references for multi-file skills (copied verbatim, no templating).
  # Per-file safe_copy so the upgrade contract (preserve existing, skip excluded) applies.
  if [[ -d "$KIT_ROOT/templates/skills/$s/references" ]]; then
    for _ref in "$KIT_ROOT/templates/skills/$s/references/"*; do
      [[ -f "$_ref" ]] || continue
      safe_copy "$_ref" "$TARGET/$AD/skills/$dest_name/references/$(basename "$_ref")"
    done
    echo "  + $AD/skills/$dest_name/references/"
  fi
done
done   # adapters
use_adapter "${ADAPTERS%% *}"

# ---- scripts (libs + setup + sync; kit-owned) ---------------------------
# safe_copy honors the upgrade contract: on --upgrade an EXISTING script is PRESERVED, never
# overwritten with an older template (the #334 downgrade that erased #307/#313/#314). Fresh
# inits get the current scripts; to refresh a kit-owned script later, delete it then re-upgrade.
safe_copy "$KIT_ROOT/scripts/lib/kit-config.sh"     "$TARGET/scripts/lib/kit-config.sh"
# kit-config.sh and kit-version-check.sh both source this resolver from beside themselves; without it
# they only ever look at .claude/kit.config.json and miss a Codex-only project's root config.
safe_copy "$KIT_ROOT/scripts/lib/config-path.sh"    "$TARGET/scripts/lib/config-path.sh"
safe_copy "$KIT_ROOT/scripts/lib/gh-project.sh"     "$TARGET/scripts/lib/gh-project.sh"
safe_copy "$KIT_ROOT/scripts/lib/worktree-issue.sh" "$TARGET/scripts/lib/worktree-issue.sh"
safe_copy "$KIT_ROOT/scripts/lib/role-identity.sh"  "$TARGET/scripts/lib/role-identity.sh"
safe_copy "$KIT_ROOT/scripts/lib/kit-local.sh"      "$TARGET/scripts/lib/kit-local.sh"
safe_copy "$KIT_ROOT/scripts/lib/engine-adapter.sh" "$TARGET/scripts/lib/engine-adapter.sh"
safe_copy "$KIT_ROOT/scripts/lib/effort-metrics.sh" "$TARGET/scripts/lib/effort-metrics.sh"
safe_copy "$KIT_ROOT/scripts/lib/gh-log.sh"         "$TARGET/scripts/lib/gh-log.sh"
safe_copy "$KIT_ROOT/scripts/lib/kit-events.sh"     "$TARGET/scripts/lib/kit-events.sh"
# task-sync.sh sources board-view.sh unguarded (set -e) and effort-plan.sh for `--plan`.
safe_copy "$KIT_ROOT/scripts/lib/board-view.sh"     "$TARGET/scripts/lib/board-view.sh"
safe_copy "$KIT_ROOT/scripts/lib/effort-plan.sh"    "$TARGET/scripts/lib/effort-plan.sh"
safe_copy "$KIT_ROOT/scripts/lib/worktree-start.sh" "$TARGET/scripts/lib/worktree-start.sh"
# pr-evidence.sh is the helper rules/gate-and-review.md tells a project to source; without this copy
# `cckit lib` resolves to the project's own scripts/lib, where the helper would be missing.
safe_copy "$KIT_ROOT/scripts/lib/pr-evidence.sh"    "$TARGET/scripts/lib/pr-evidence.sh"
safe_copy "$KIT_ROOT/scripts/lib/session-registry.sh" "$TARGET/scripts/lib/session-registry.sh"
safe_copy "$KIT_ROOT/scripts/lib/kinds.sh"          "$TARGET/scripts/lib/kinds.sh"
safe_copy "$KIT_ROOT/scripts/kit-version-check.sh"  "$TARGET/scripts/kit-version-check.sh" exec
for sc in setup-labels.sh setup-milestones.sh capture-project-ids.sh task-sync.sh knowledge-lint.sh \
          review-lint.sh skill-frontmatter-lint.sh instruction-budget-lint.sh; do
  safe_copy "$KIT_ROOT/scripts/$sc" "$TARGET/scripts/$sc" exec
done
# review-lint is table-driven: the engine is useless without a rule table, so the starter table
# travels with it. Every lint self-disables when it does not apply (no rule table / no skills dir /
# no CLAUDE.md and no rules dir), so shipping them to every project is safe.
safe_copy "$KIT_ROOT/scripts/review-rules.conf" "$TARGET/scripts/review-rules.conf"
# Seed each baseline ONCE so a fresh project starts green and only *new* defects fail. Never
# regenerate an existing baseline - that would silently re-grandfather drift on upgrade.
#
# ASK for the path, never reconstruct it. This used to test "$_lint-baseline.txt", which is right
# for review-lint and wrong for skill-frontmatter-lint (it writes skill-frontmatter-baseline.txt, no
# "-lint"). The guessed name never existed, so the "already seeded" guard never matched and every
# upgrade re-baselined it - exactly what the line above forbids.
#
# KIT_LINT_WALK=1 so the seed sees the files just written. init.sh usually scaffolds into a repo
# that already has commits, where `git ls-files` is non-empty and the untracked kit files are
# invisible to it; the baseline would come out empty and the gate would go red on the user's first
# commit of the scaffold.
for _lint in review-lint skill-frontmatter-lint instruction-budget-lint; do
  [[ -f "$TARGET/scripts/$_lint.sh" ]] || continue
  _baseline="$( cd "$TARGET" && bash "scripts/$_lint.sh" --baseline-path 2>/dev/null )"
  [[ -n "$_baseline" ]] || continue
  [[ -e "$TARGET/$_baseline" ]] && continue
  ( cd "$TARGET" && KIT_LINT_WALK=1 bash "scripts/$_lint.sh" --update ) >/dev/null 2>&1 || true
done
echo "  + scripts/ (libs + setup + task-sync + version-check + knowledge-lint + review-lint + skill-frontmatter-lint + instruction-budget-lint)"

# ---- benchmark harness (generic machinery; kit-owned) + example dataset ----
# The harness measures how well THIS project's own canonical docs can be found + used by a cold
# agent (retrieval / adversarial / abstain / quality tiers). Machinery is kit-owned (refreshed on
# upgrade); the datasets under benchmarks/ are the project's own — we scaffold an EXAMPLE set +
# schema only, and safe_write preserves it on upgrade so growth is never clobbered.
for bs in run.sh run-quality.sh report.sh gate.sh stop-check.sh benchmark-test.sh; do
  safe_copy "$KIT_ROOT/scripts/benchmark/$bs" "$TARGET/scripts/benchmark/$bs" exec
done
safe_copy "$KIT_ROOT/scripts/benchmark/lib/model.sh"        "$TARGET/scripts/benchmark/lib/model.sh"
safe_copy "$KIT_ROOT/scripts/benchmark/lib/bench-common.sh" "$TARGET/scripts/benchmark/lib/bench-common.sh"
echo "  + scripts/benchmark/ (doc-retrieval benchmark harness — see benchmarks/SCHEMA.md)"

mkdir -p "$TARGET/benchmarks"
for bf in SCHEMA.md benchmark.config.json retrieval.jsonl adversarial.jsonl abstain.jsonl quality.jsonl .gitignore; do
  safe_write "$KIT_ROOT/templates/benchmarks/$bf" "$TARGET/benchmarks/$bf"
done
echo "  + benchmarks/ (example dataset + schema — grow your own; run: scripts/benchmark/report.sh)"

# ---- knowledge base (governed dir: INDEX manifest; upgrade-safe) ---------
mkdir -p "$TARGET/knowledge"
safe_write "$KIT_ROOT/templates/knowledge-INDEX.md.tmpl" "$TARGET/knowledge/INDEX.md"
echo "  + knowledge/INDEX.md (manifest — see $ADAPTER_DIR/rules/knowledge-base.md)"

# ==== Claude adapter only: sigil lib, settings, hooks, statusline wiring ====
# Everything from here to the matching `fi` is Claude Code configuration. A Codex-only project gets
# none of it — Codex hook registration is E257.5 — and the body is left unindented on purpose so the
# hook blocks keep their history.
if adapter_has "$ADAPTERS" claude; then

# ---- .claude/lib (kit-sigil attribution helper; all projects; idempotent) ----
# Sourced by the task-* skill footers + repo-hygiene to emit one "claude-kit"
# attribution sigil per kit-action boundary (see knowledge/brand.md §6).
mkdir -p "$TARGET/.claude/lib"
safe_write "$KIT_ROOT/templates/lib/kit-sigil.sh.tmpl" "$TARGET/.claude/lib/kit-sigil.sh"
chmod +x "$TARGET/.claude/lib/kit-sigil.sh" 2>/dev/null || true
echo "  + .claude/lib/kit-sigil.sh"

# ---- settings.json (versioned — travels to worktrees + collaborators) ---
# Unlike settings.local.json (gitignored, per-checkout), this one is CHECKED IN so the
# captain's pre-authorized wave-merge (gh pr merge under an approved plan) works in every
# worktree and for every collaborator without re-prompting. safe_write = preserve-if-exists.
mkdir -p "$TARGET/.claude"
safe_write "$KIT_ROOT/templates/settings/settings.json.tmpl" "$TARGET/.claude/settings.json"
echo "  + .claude/settings.json (versioned captain merge permission)"

# ---- settings.local.json (+ hooks, additive) ----------------------------
mkdir -p "$TARGET/.claude"
safe_write "$KIT_ROOT/templates/settings/settings.local.json.tmpl" "$TARGET/.claude/settings.local.json"
SETTINGS="$TARGET/.claude/settings.local.json"
# A merge that leaves the value as it was does not rewrite the file (json_write_minimal, #448).
merge_settings() { jq "$@" "$SETTINGS" > "$SETTINGS.tmp" && json_write_minimal "$SETTINGS.tmp" "$SETTINGS" >/dev/null; }
HOOK_NOTE=""

if [[ "$MEMORY_BOOL" == "true" && $UPGRADE -eq 0 ]]; then
  mkdir -p "$TARGET/.claude/hooks"
  emit "$KIT_ROOT/templates/hooks/mempal_session_start.sh.tmpl" "$TARGET/.claude/hooks/mempal_session_start.sh"
  emit "$KIT_ROOT/templates/hooks/mempal_save.sh.tmpl"       "$TARGET/.claude/hooks/mempal_save.sh"
  emit "$KIT_ROOT/templates/hooks/mempal_precompact.sh.tmpl" "$TARGET/.claude/hooks/mempal_precompact.sh"
  emit "$KIT_ROOT/templates/hooks/mempal_followup.sh.tmpl"   "$TARGET/.claude/hooks/mempal_followup.sh"
  chmod +x "$TARGET/.claude/hooks/mempal_session_start.sh" "$TARGET/.claude/hooks/mempal_save.sh" "$TARGET/.claude/hooks/mempal_precompact.sh" "$TARGET/.claude/hooks/mempal_followup.sh"
  # Per-wing wake-up header — without it, `mempalace wake-up` shows the single global
  # ~/.mempalace/identity.txt for every wing (the session-start hook swaps this in). See
  # templates/rules/mempalace.md; `cckit doctor` re-seeds it if it goes missing.
  _mpid="$TARGET/.claude/mempal-identity.$SLUG.txt"
  if [[ ! -e "$_mpid" ]]; then
    {
      printf 'Project: %s (wing: %s)\n' "$NAME" "$SLUG"
      [[ -n "$OWNER_NAME" ]] && printf 'Owner: %s\n' "$OWNER_NAME"
      printf 'Stack: (describe this project — this header shows on every session wake-up)\n'
    } > "$_mpid"
  fi
  merge_settings --arg start "$TARGET/.claude/hooks/mempal_session_start.sh" --arg save "$TARGET/.claude/hooks/mempal_save.sh" --arg pre "$TARGET/.claude/hooks/mempal_precompact.sh" --arg fup "$TARGET/.claude/hooks/mempal_followup.sh" \
    '.hooks.SessionStart = [{matcher:"",hooks:[{type:"command",command:$start,timeout:30}]}]
     | .hooks.Stop = [{matcher:"",hooks:[{type:"command",command:$save,timeout:30}]}]
     | .hooks.PreCompact = [{matcher:"",hooks:[{type:"command",command:$pre,timeout:30}]}]
     | .hooks.SessionEnd = [{matcher:"",hooks:[{type:"command",command:$fup,timeout:30}]}]'
  HOOK_NOTE="$HOOK_NOTE + MemPalace"
fi

if [[ "$PREPUSH_ENABLED" == "true" && $UPGRADE -eq 0 ]]; then
  mkdir -p "$TARGET/.claude/hooks"
  emit "$KIT_ROOT/templates/hooks/prepush_gate.sh.tmpl" "$TARGET/.claude/hooks/prepush_gate.sh"
  chmod +x "$TARGET/.claude/hooks/prepush_gate.sh"
  merge_settings --arg gate "$TARGET/.claude/hooks/prepush_gate.sh" \
    '.hooks.PreToolUse = [{matcher:"Bash",hooks:[{type:"command",command:$gate,timeout:120}]}]'
  HOOK_NOTE="$HOOK_NOTE + pre-push gate"
fi

# ---- local model layer SessionStart hook (opt-in; idempotent, also on --upgrade) ----
if [[ "$LOCAL_ON" == "true" ]]; then
  mkdir -p "$TARGET/.claude/hooks"
  hook_write "$KIT_ROOT/templates/hooks/kit-local-status.sh.tmpl" "$TARGET/.claude/hooks/kit-local-status.sh"
  chmod +x "$TARGET/.claude/hooks/kit-local-status.sh" 2>/dev/null || true
  merge_settings --arg ls "$TARGET/.claude/hooks/kit-local-status.sh" \
    '.hooks.SessionStart = (((.hooks.SessionStart // []) | map(select((.hooks[0].command // "") != $ls))) + [{matcher:"",hooks:[{type:"command",command:$ls,timeout:10}]}])'
  HOOK_NOTE="$HOOK_NOTE + local-status"
fi

# ---- repo-hygiene SessionStart hook (all projects; read-only; idempotent) ----
mkdir -p "$TARGET/.claude/hooks"
hook_write "$KIT_ROOT/templates/hooks/repo-hygiene.sh.tmpl" "$TARGET/.claude/hooks/repo-hygiene.sh"
chmod +x "$TARGET/.claude/hooks/repo-hygiene.sh" 2>/dev/null || true
merge_settings --arg rh "$TARGET/.claude/hooks/repo-hygiene.sh" \
  '.hooks.SessionStart = (((.hooks.SessionStart // []) | map(select((.hooks[0].command // "") != $rh))) + [{matcher:"",hooks:[{type:"command",command:$rh,timeout:10}]}])'
HOOK_NOTE="$HOOK_NOTE + repo-hygiene"

# ---- base-branch commit guard PreToolUse(Bash) hook (all projects; idempotent) ----
mkdir -p "$TARGET/.claude/hooks"
hook_write "$KIT_ROOT/templates/hooks/guard-base-branch-commit.sh.tmpl" "$TARGET/.claude/hooks/guard-base-branch-commit.sh"
chmod +x "$TARGET/.claude/hooks/guard-base-branch-commit.sh" 2>/dev/null || true
merge_settings --arg gd "$TARGET/.claude/hooks/guard-base-branch-commit.sh" \
  '.hooks.PreToolUse = (((.hooks.PreToolUse // []) | map(select((.hooks[0].command // "") != $gd))) + [{matcher:"Bash",hooks:[{type:"command",command:$gd,timeout:10}]}])'
HOOK_NOTE="$HOOK_NOTE + commit-guard"

# ---- raw-git guard PreToolUse(Bash) hook (all projects; init AND --upgrade; idempotent) ----
# Blocks raw gh issue create / pr create / pr merge / issue close and branch-from-base, and names the
# cckit verb to run instead (#364). Wired in the TRACKED settings.json with $CLAUDE_PROJECT_DIR, not
# settings.local.json: the local file is per-checkout and gitignored, so a guard wired there never
# reaches a worktree — which is exactly where agents work.
hook_write "$KIT_ROOT/templates/hooks/guard-raw-git-ops.sh.tmpl" "$TARGET/.claude/hooks/guard-raw-git-ops.sh"
chmod +x "$TARGET/.claude/hooks/guard-raw-git-ops.sh" 2>/dev/null || true
_TRACKED="$TARGET/.claude/settings.json"
[[ -f "$_TRACKED" ]] || echo '{}' > "$_TRACKED"
# A registration that is already there — in its own block or inside one the project arranged — is
# left where it is; the file is rewritten only when the guard had to be added (#448: the upgrade
# moved it into a new block on every run and still listed settings.json as preserved).
# shellcheck disable=SC2016  # $CLAUDE_PROJECT_DIR is expanded by Claude Code at hook time
jq --arg g '$CLAUDE_PROJECT_DIR/.claude/hooks/guard-raw-git-ops.sh' \
  'if ([ (.hooks.PreToolUse // [])[] | (.hooks // [])[] | .command ] | index($g)) != null then .
   else .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{matcher:"Bash",hooks:[{type:"command",command:$g,timeout:10}]}])
   end' "$_TRACKED" > "$_TRACKED.tmp" && json_write_minimal "$_TRACKED.tmp" "$_TRACKED" >/dev/null
echo "  + .claude/hooks/guard-raw-git-ops.sh (PreToolUse Bash, wired in tracked settings.json: raw gh/git -> cckit verb)"

# ---- session-mail hook (all projects; init AND --upgrade; idempotent) ----
# One script on four events delivers `cckit msg` mail to a running session (E257.5). Wired in the
# TRACKED settings.json for the same reason as the raw-git guard: mail has to reach worktrees. A
# registration that is already there is left as it is (its timeout or position may be the user's),
# and a project that listed the hook in `upgrade.removed` is not re-wired.
if ! _upgrade_excluded ".claude/hooks/kit-mail-check.sh"; then
  hook_write "$KIT_ROOT/templates/hooks/kit-mail-check.sh.tmpl" "$TARGET/.claude/hooks/kit-mail-check.sh"
  chmod +x "$TARGET/.claude/hooks/kit-mail-check.sh" 2>/dev/null || true
  # shellcheck disable=SC2016  # $CLAUDE_PROJECT_DIR is expanded by Claude Code at hook time
  jq --arg m 'bash "$CLAUDE_PROJECT_DIR/.claude/hooks/kit-mail-check.sh"' '
    reduce (["PostToolUse","*"], ["UserPromptSubmit",""], ["SessionStart",""], ["Stop",""]) as [$e, $mt] (.;
      if ([ (.hooks[$e] // [])[] | (.hooks // [])[] | .command ] | index($m)) != null then .
      else .hooks[$e] = ((.hooks[$e] // [])
        + [ (if $mt == "" then {} else {matcher: $mt} end) + {hooks: [{type: "command", command: $m, timeout: 10}]} ])
      end)' "$_TRACKED" > "$_TRACKED.tmp" && json_write_minimal "$_TRACKED.tmp" "$_TRACKED" >/dev/null
  echo "  + .claude/hooks/kit-mail-check.sh (session mail, wired in tracked settings.json on 4 events)"
fi

# ---- version-check SessionStart hook (all projects; idempotent) ---------
mkdir -p "$TARGET/.claude/hooks"
hook_write "$KIT_ROOT/templates/hooks/kit_version_check.sh.tmpl" "$TARGET/.claude/hooks/kit_version_check.sh"
chmod +x "$TARGET/.claude/hooks/kit_version_check.sh" 2>/dev/null || true
merge_settings --arg vc "$TARGET/.claude/hooks/kit_version_check.sh" \
  '.hooks.SessionStart = (((.hooks.SessionStart // []) | map(select((.hooks[0].command // "") != $vc))) + [{matcher:"",hooks:[{type:"command",command:$vc,timeout:10}]}])'
HOOK_NOTE="$HOOK_NOTE + version-check"

echo "  + .claude/settings.local.json${HOOK_NOTE:+ (}${HOOK_NOTE# + }${HOOK_NOTE:+)}"
else
  echo "  · Codex adapter only: no .claude/ tree"
fi   # ==== end Claude adapter only ====

# ==== Codex adapter: hook scripts + their registration in .codex/hooks.json (E257.5) ====
# The SAME hook templates as the Claude adapter, rendered into .codex/hooks/: Codex sends the event
# fields they read (hook_event_name, cwd, tool_input.command) and honours the same answers (exit 2 +
# stderr blocks a tool, decision:block continues a Stop, additionalContext injects text).
# Not installed: the MemPalace hooks. mempal_save / mempal_precompact mine ~/.claude/projects/, the
# Claude Code transcript store, and no Codex transcript format has been validated against
# `mempalace mine` — see agent-compatibility.mdx.
CODEX_HOOKS_CHANGED=0
if adapter_has "$ADAPTERS" codex; then
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/codex-hooks.sh"
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/kit-manifest.sh"
mkdir -p "$TARGET/.codex/hooks"
_CX_SRC="$(mktemp)"
cp "$KIT_ROOT/templates/codex/hooks.json.tmpl" "$_CX_SRC"
_CX_HOOKS="repo-hygiene.sh kit_version_check.sh kit-mail-check.sh guard-base-branch-commit.sh guard-raw-git-ops.sh"
_cx_optional() {  # <event> <matcher> <script> <timeout> — an opt-in hook joins the set to register
  local frag; frag="$(mktemp)"
  codex_hooks_fragment "$1" "$2" "$3" "$4" > "$frag" && codex_hooks_merge "$_CX_SRC" "$frag" >/dev/null
  rm -f "$frag"
  _CX_HOOKS="$_CX_HOOKS $3"
}
[[ "$PREPUSH_ENABLED" == "true" ]] && _cx_optional PreToolUse Bash prepush_gate.sh 120
[[ "$LOCAL_ON"        == "true" ]] && _cx_optional SessionStart "" kit-local-status.sh 10
for _h in $_CX_HOOKS; do
  _cx_dst="$TARGET/.codex/hooks/$_h"
  _cx_n=$(( ${#WRITTEN[@]} + ${#UPGRADE_REFRESHED[@]} ))
  if [[ $UPGRADE -eq 0 && $FORCE -eq 0 && -e "$_cx_dst" ]]; then
    # A fresh init over a .codex/hooks/ the user already keeps: their file wins, as AGENTS.md does.
    echo "  = .codex/hooks/$_h (already there — kept; --force replaces it)"
  else
    hook_write "$KIT_ROOT/templates/hooks/$_h.tmpl" "$_cx_dst"
    chmod +x "$_cx_dst" 2>/dev/null || true
  fi
  [[ $(( ${#WRITTEN[@]} + ${#UPGRADE_REFRESHED[@]} )) -gt $_cx_n ]] && CODEX_HOOKS_CHANGED=1
done
echo "  + .codex/hooks/ ($(printf '%s' "$_CX_HOOKS" | sed 's/ /, /g'))"
# hooks.json is the project's file. cckit's handlers are merged in (a handler already registered for
# the event is skipped, everything else in the file is kept) and a merge that changes nothing does
# not rewrite it. It is recorded as kit-owned only when cckit created it or the manifest still
# proves it unmodified — a hooks.json holding the user's own entries is never claimed.
_CX_JSON="$TARGET/.codex/hooks.json"; _cx_own=0
if [[ ! -e "$_CX_JSON" ]]; then _cx_own=1
elif [[ "$( cd "$TARGET" && KIT_MANIFEST="$MANIFEST_REL" kit_manifest_verify .codex/hooks.json 2>/dev/null )" == "intact" ]]; then _cx_own=1
fi
if _upgrade_excluded ".codex/hooks.json"; then
  UPGRADE_SKIPPED+=(".codex/hooks.json")
elif _cx_state="$(codex_hooks_merge "$_CX_JSON" "$_CX_SRC")"; then
  case "$_cx_state" in
    created) echo "  + .codex/hooks.json (SessionStart / PreToolUse Bash / PostToolUse / UserPromptSubmit / Stop)"
             [[ $UPGRADE -eq 1 ]] && UPGRADE_ADDED+=(".codex/hooks.json") ;;
    merged)  echo "  ~ .codex/hooks.json (cckit's hooks added; the entries already there are kept)" ;;
    *)       [[ $UPGRADE -eq 1 ]] && UPGRADE_PRESERVED+=(".codex/hooks.json") ;;
  esac
  if [[ "$_cx_state" != "unchanged" ]]; then
    CODEX_HOOKS_CHANGED=1
    [[ $_cx_own -eq 1 ]] && WRITTEN+=(".codex/hooks.json")
  fi
else
  echo "  ! .codex/hooks.json was left untouched — cckit's Codex hooks are NOT registered. Fix the file, then run: cckit init --upgrade" >&2
fi
rm -f "$_CX_SRC"
[[ "$MEMORY_BOOL" == "true" ]] && echo "  · Codex adapter: no memory hooks — the transcript sweep reads Claude Code's ~/.claude/projects/ only"
fi   # ==== end Codex adapter hooks ====

# ---- recommended .gitignore entries (idempotent) ------------------------
# kit.manifest.json is kit-managed bookkeeping (content hashes + timestamps, re-stamped on every
# wire) — tracking it would dirty the tree on every session/upgrade, the exact churn #334 removes.
GI="$TARGET/.gitignore"
_GI_LOCAL=""; adapter_has "$ADAPTERS" claude && _GI_LOCAL=".claude/settings.local.json"
for _ig in "$_GI_LOCAL" "$MANIFEST_REL" ".kann/"; do
  [[ -n "$_ig" ]] || continue
  if [[ -f "$GI" ]]; then grep -qxF "$_ig" "$GI" || printf '%s\n' "$_ig" >> "$GI"; else printf '%s\n' "$_ig" > "$GI"; fi
done

# ---- wire (converge) -----------------------------------------------------
# Runs on BOTH scaffold and --upgrade so every update re-wires (fixes the class of bug where
# /kit-update refreshed files but never re-ran the wiring → statusline/settings drifted). #369
if [[ -f "$KIT_ROOT/scripts/kit-wire.sh" ]] && adapter_has "$ADAPTERS" claude; then
  # On --upgrade an EXISTING .claude/statusline.sh follows the same contract as safe_write: the
  # conffiles guard in kit-operate keeps a customized (or untracked) shim; only a shim the kit
  # provably owns intact is refreshed (#149).
  _SHIM="$TARGET/.claude/statusline.sh"
  _shim_before=""; [[ -f "$_SHIM" ]] && _shim_before="$(cat "$_SHIM" 2>/dev/null)"
  if ( cd "$TARGET" && KIT_MANIFEST="$MANIFEST_REL" CLAUDE_PLUGIN_ROOT="$KIT_ROOT" KIT_ASSUME_YES=1 bash "$KIT_ROOT/scripts/kit-wire.sh" >/dev/null 2>&1 ); then
    echo "  + wired: statusline shim + settings.statusLine (kit-wire)"
  fi
  if [[ $UPGRADE -eq 1 && -n "$_shim_before" && "$_shim_before" == "$(cat "$_SHIM" 2>/dev/null)" ]]; then
    UPGRADE_PRESERVED+=(".claude/statusline.sh")
  fi
fi

# ---- ownership manifest: record what this run wrote ----------------------
# Only the adapter files written NOW (never a preserved one — its content may be the user's), hashed
# after every merge above so the recorded hash is the file as it was left. Keyed by path, so a
# repeated upgrade updates nothing and adds nothing. This is what lets `cckit remove` and a later
# upgrade tell a kit-owned file from an edited one for BOTH adapters.
# shellcheck source=/dev/null
. "$KIT_ROOT/scripts/lib/kit-manifest.sh"
if [[ ${#WRITTEN[@]} -gt 0 ]]; then
  ( cd "$TARGET" && for _w in "${WRITTEN[@]}"; do
      if adapter_managed "$_w"; then printf '%s\t%s\n' "$(adapter_tier "$_w")" "$_w"; fi
    done | sort -u | KIT_MANIFEST="$MANIFEST_REL" kit_manifest_record_batch init "$PLUGIN_VERSION" ) \
    || echo "  ! could not record the ownership manifest ($MANIFEST_REL)" >&2
fi

# ---- summary -------------------------------------------------------------
echo ""
echo "claude-kit $([[ $UPGRADE -eq 1 ]] && echo upgraded || echo scaffolded) — profile: $PROFILE"
echo "  Project : $NAME ($SLUG)"
echo "  Repo    : $REPO"
echo "  Adapters: $ADAPTERS"
echo "  Board   : $([[ "$PROJECTS_V2" == "true" ]] && echo "Projects v2 #$PROJECT_NUMBER" || echo "off (gh issues only)")"
echo "  Agents  : $(echo $AGENTS | tr '\n' ' ')"
echo "  Memory  : $MEMORY_BOOL   Plans: $PLANS_FORMAT   Lang: $LANG_PREF   kitVersion: $PLUGIN_VERSION"
echo "  Spec Kit: $SPECKIT_ON   Pre-push gate: $PREPUSH_ENABLED   Local model: $LOCAL_ON   Stack skills self-gate by package.json"

if [[ $UPGRADE -eq 1 ]]; then
  echo ""
  echo "  Upgrade -> kitVersion $PLUGIN_VERSION"
  # What changed on disk, measured (the same block `--upgrade --dry-run` prints as "Would change").
  # A file the helpers left alone but a later step merged into — .claude/settings.json gaining a hook
  # registration — is in this block as M and is taken out of the Preserved list below.
  if [[ -n "$_UP_SNAP" && -f "$_UP_SNAP/before" ]]; then
    upgrade_snapshot "$TARGET" > "$_UP_SNAP/after"
    upgrade_changes "$_UP_SNAP/before" "$_UP_SNAP/after" > "$_UP_SNAP/changes"
    upgrade_changes_print "$_UP_SNAP/changes" "Changed on disk"
    _UP_MEASURED=1
    if [[ ${#UPGRADE_PRESERVED[@]} -gt 0 ]]; then
      _up_kept=()
      for _p in "${UPGRADE_PRESERVED[@]}"; do
        grep -qxF "M	$_p" "$_UP_SNAP/changes" || _up_kept+=("$_p")
      done
      UPGRADE_PRESERVED=(); [[ ${#_up_kept[@]} -gt 0 ]] && UPGRADE_PRESERVED=("${_up_kept[@]}")
    fi
    rm -rf "$_UP_SNAP"
  fi
  # The A rows above already name every added file; the helper's own list is printed only when no
  # measurement was taken.
  if [[ ${_UP_MEASURED:-0} -eq 0 && ${#UPGRADE_ADDED[@]} -gt 0 ]]; then echo "  Added (new in this kit version):"; printf '    + %s\n' "${UPGRADE_ADDED[@]}"; fi
  if [[ ${#UPGRADE_PRESERVED[@]} -gt 0 ]]; then echo "  Preserved (your edits, untouched):"; printf '    = %s\n' "${UPGRADE_PRESERVED[@]}"; fi
  if [[ ${#UPGRADE_SKIPPED[@]}   -gt 0 ]]; then echo "  Skipped (removed/renamed via kit.config upgrade):"; printf '    - %s\n' "${UPGRADE_SKIPPED[@]}"; fi
  if [[ ${#UPGRADE_REFRESHED[@]} -gt 0 ]]; then echo "  Refreshed (unmodified hook, now the current template):"; printf '    ~ %s\n' "${UPGRADE_REFRESHED[@]}"; fi
  if [[ ${#UPGRADE_DRIFTED[@]}   -gt 0 ]]; then echo "  Drifted (customized hook, kept — diff it against templates/hooks/ by hand):"; printf '    ! %s\n' "${UPGRADE_DRIFTED[@]}"; fi
  [[ $CODEX_HOOKS_CHANGED -eq 1 ]] && echo "  Codex hooks changed: Codex skips a new or changed hook until you trust it — run /hooks in Codex."
else
  echo ""
  echo "Next steps:"
  echo "  1. Review $(adapter_instructions "${ADAPTERS%% *}") and $CONFIG_REL"
  if [[ $SETUP_RUN -eq 0 ]]; then
  echo "  2. ./scripts/setup-labels.sh && ./scripts/setup-milestones.sh   # seed the repo"
  if [[ "$PROJECTS_V2" == "true" ]]; then echo "  3. ./scripts/capture-project-ids.sh   # cache Projects v2 field IDs"; fi
  fi
  [[ "$LOCAL_ON" == "true" ]] && echo "  4. /kit-doctor   # local model layer: installs mlx-lm (recipe: integrations/mlx-lm.json) + starts mlx_lm.server"
  adapter_has "$ADAPTERS" codex && echo "  · Codex: commit .codex/, then run /hooks in Codex and trust the project hooks — Codex skips them until you do."
fi

# ---- git + GitHub setup, then the closing report (#456) --------------------
if [[ $UPGRADE -eq 0 ]]; then
  if [[ $SETUP_RUN -eq 1 ]]; then init_setup_run; fi
  _init_finish
fi

exit 0
