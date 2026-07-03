#!/usr/bin/env bash
# claude-kit init — scaffold a tailored .claude/ into a target project.
# Substitutes {{VARS}} and resolves <!-- IF:FLAG --> blocks from a role profile.
#
# Usage:
#   scripts/init.sh --profile software --name "My App" [flags]
#   scripts/init.sh --upgrade --target <dir>          # merge new features into an existing setup
#
# Flags (all optional except --profile; sensible defaults derived otherwise):
#   --profile <software|content|research|minimal>   role profile (required unless --upgrade)
#   --target <dir>            project root to scaffold into       (default: $PWD)
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
#   --prepush "<command>"     install an opt-in pre-push gate that runs <command> before
#                             `git push` and blocks on failure     (default: none -> no gate)
#   --local <on|off>          local model layer (mlx_lm.server) for NL chores at $0 API cost
#                             (config + SessionStart status hook)  (default: off)
#   --lang <str>              working language                     (default: English)
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
PROFILE=""; TARGET="$PWD"; NAME=""; SLUG=""; REPO=""; GH_OWNER=""; OWNER_NAME=""
PROJECT_NUMBER=""; PLANS_FORMAT=""; PLANS_DIR=""; MEMORY=""; LANG_PREF="English"; FORCE=0
SPECKIT=""; PREPUSH_CMD=""; LOCAL_LAYER=""; LOCAL_EXPLICIT=0; DRY_RUN=0; UPGRADE=0
SKILL_PREFIX=""   # namespace applied to kit-namespaced skill templates (from kit.config .skillPrefix on upgrade)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
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
    --prepush) PREPUSH_CMD="$2"; shift 2 ;;
    --local) LOCAL_LAYER="$2"; LOCAL_EXPLICIT=1; shift 2 ;;
    --lang) LANG_PREF="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --upgrade) UPGRADE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "x unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Installed plugin version -> recorded into kit.config as kitVersion (drives /kit-update checks).
PLUGIN_VERSION="$(jq -r '.version // "0.0.0"' "$KIT_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo "0.0.0")"

# ---- upgrade mode: backfill inputs from the project's existing config ----
if [[ $UPGRADE -eq 1 ]]; then
  UP_TARGET="$(cd "${TARGET:-$PWD}" && pwd)"
  UP_CFG="$UP_TARGET/.claude/kit.config.json"
  [[ -f "$UP_CFG" ]] || { echo "x --upgrade needs $UP_CFG (run /kit-init first)."; exit 1; }

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
  if [[ "$_have_kv" == "$PLUGIN_VERSION" ]]; then
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
  [[ -z "$PLANS_FORMAT" ]] && PLANS_FORMAT="$(jq -r '.plans.format // ""' "$UP_CFG")"
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
mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"
BASENAME="$(basename "$TARGET")"
[[ -z "$NAME" ]] && NAME="$BASENAME"
[[ -z "$SLUG" ]] && SLUG="$(echo "$BASENAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-|-$//g')"
if [[ -z "$GH_OWNER" ]]; then GH_OWNER="$(gh api user --jq .login 2>/dev/null || echo "")"; fi
[[ -z "$OWNER_NAME" ]] && OWNER_NAME="${GH_OWNER:-owner}"
# Prefer the project's ACTUAL GitHub remote over an <owner>/<dir-basename> guess — the local
# directory name often differs from the repo name (would target a non-existent repo otherwise).
[[ -z "$REPO" ]] && REPO="$(cd "$TARGET" 2>/dev/null && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[[ -z "$REPO" && -n "$GH_OWNER" ]] && REPO="$GH_OWNER/$SLUG"
[[ -z "$REPO" ]] && REPO="$SLUG"

# profile defaults
[[ -z "$PLANS_FORMAT" ]] && PLANS_FORMAT="$(jq -r '.defaults.plans_format' "$PROFILE_FILE")"
[[ -z "$MEMORY" ]] && MEMORY="$(jq -r '.defaults.memory' "$PROFILE_FILE")"
[[ -z "$SPECKIT" ]] && SPECKIT="$(jq -r '.defaults.speckit // "off"' "$PROFILE_FILE")"
[[ -z "$LOCAL_LAYER" ]] && LOCAL_LAYER="$(jq -r '.defaults.local // "off"' "$PROFILE_FILE")"
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

# FLAGS_ON drives <!-- IF:X --> resolution
FLAGS_ON=""
[[ "$MEMORY_BOOL" == "true" ]]  && FLAGS_ON="${FLAGS_ON}MEMORY,"
[[ "$PROJECTS_V2" == "true" ]]  && FLAGS_ON="${FLAGS_ON}PROJECTS_V2,"
[[ "$PLANS_ON" == "true" ]]         && FLAGS_ON="${FLAGS_ON}PLANS,"
[[ "$DESIGN_ON" == "true" ]]        && FLAGS_ON="${FLAGS_ON}DESIGN,"
[[ "$SPECKIT_ON" == "true" ]]       && FLAGS_ON="${FLAGS_ON}SPECKIT,"
[[ "$STACK_SKILLS_ON" == "true" ]]  && FLAGS_ON="${FLAGS_ON}STACK_SKILLS,"

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
export PLANS_DIR PLANS_FORMAT KNOWLEDGE_DIR="knowledge" WING="$SLUG" CLAUDE_PROJECT_SLUG
export MILESTONES_HUMAN ROLES_HUMAN AGENT_TABLE SKILL_TABLE
export KIT_FLAGS_ON="$FLAGS_ON"

# emit: resolve IF blocks, then substitute {{VARS}}
emit() {  # <src> <dest>
  mkdir -p "$(dirname "$2")"
  perl -0777 -pe '
    my %on = map { $_=>1 } grep { length } split /,/, ($ENV{KIT_FLAGS_ON}//"");
    1 while s{<!-- IF:(\w+) -->(.*?)<!-- /IF:\1 -->}{ $on{$1} ? $2 : "" }gse;
    s/\{\{(\w+)\}\}/ exists $ENV{$1} ? $ENV{$1} : "{{$1}}" /ge;
  ' "$1" > "$2"
}

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
  [[ "${3:-}" == "exec" ]] && chmod +x "$2" 2>/dev/null
  [[ $UPGRADE -eq 1 ]] && UPGRADE_ADDED+=("$rel")
  return 0
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
  echo "  Board   : $([[ "$PROJECTS_V2" == "true" ]] && echo "Projects v2 #$PROJECT_NUMBER" || echo "off (gh issues only)")"
  echo "  Memory  : $MEMORY_BOOL   Plans: $PLANS_FORMAT   Lang: $LANG_PREF"
  echo "  Spec Kit: $SPECKIT_ON   Pre-push gate: $PREPUSH_ENABLED   Local model: $LOCAL_ON   kitVersion: $PLUGIN_VERSION"
  echo ""
  echo "  Would write:"
  echo "    CLAUDE.md"
  echo "    .claude/kit.config.json"
  echo "    .claude/settings.local.json"
  echo "    .claude/hooks/repo-hygiene.sh             (SessionStart: read-only repo-hygiene report)"
  echo "    .claude/hooks/guard-base-branch-commit.sh (PreToolUse Bash: block commits to base branch)"
  echo "    .claude/hooks/kit_version_check.sh   (SessionStart: update check)"
  for r in $RULES; do
    case "$r" in
      mempalace)          [[ "$MEMORY_BOOL" == "true" ]] || continue ;;
      design-routing)     [[ "$DESIGN_ON"   == "true" ]] || continue ;;
      plan-output-format) [[ "$PLANS_ON"    == "true" ]] || continue ;;
    esac
    [[ -f "$KIT_ROOT/templates/rules/$r.md" ]] && echo "    .claude/rules/$r.md"
  done
  for a in $AGENTS; do
    [[ -f "$KIT_ROOT/templates/agents/$a.md" ]] && echo "    .claude/agents/$a/AGENT.md"
  done
  for s in $SKILLS; do
    _dn="$s"; { [[ -n "$SKILL_PREFIX" ]] && _is_namespaced "$s"; } && _dn="${SKILL_PREFIX}${s}"
    [[ -f "$KIT_ROOT/templates/skills/$s/SKILL.md" ]] && echo "    .claude/skills/$_dn/SKILL.md"
    [[ -d "$KIT_ROOT/templates/skills/$s/references" ]] && echo "    .claude/skills/$_dn/references/"
  done
  echo "    scripts/ (kit-config.sh, gh-project.sh, kit-version-check.sh, setup-labels.sh, setup-milestones.sh, capture-project-ids.sh, task-sync.sh, knowledge-lint.sh)"
  echo "    knowledge/INDEX.md                        (knowledge-base manifest — rules/knowledge-base.md)"
  echo "    .claude/lib/kit-sigil.sh                  (claude-kit attribution sigil helper, sourced by task-* footers)"
  [[ "$MEMORY_BOOL"     == "true" ]] && echo "    .claude/hooks/mempal_session_start.sh + mempal_save.sh + mempal_precompact.sh + mempal_followup.sh   (SessionStart / Stop / PreCompact / SessionEnd)"
  [[ "$MEMORY_BOOL"     == "true" ]] && echo "    .claude/mempal-identity.$SLUG.txt              (per-wing wake-up header — edit the Stack line)"
  [[ "$PREPUSH_ENABLED" == "true" ]] && echo "    .claude/hooks/prepush_gate.sh   (PreToolUse Bash gate: $PREPUSH_CMD)"
  [[ "$LOCAL_ON"        == "true" ]] && echo "    .claude/hooks/kit-local-status.sh   (SessionStart: announce local model layer when alive)"
  echo ""
  echo "  Onboarding would offer (opt-in): gh auth$([[ "$MEMORY_BOOL" == "true" ]] && echo " · MemPalace (mempalace-mcp)") · gws (if you use Google Workspace) · local model layer (--local on: NL chores at \$0 via mlx_lm.server)"
  echo ""
  echo "Re-run without --dry-run to write these files."
  exit 0
fi

# ---- guard ---------------------------------------------------------------
if [[ -e "$TARGET/.claude/kit.config.json" && $FORCE -eq 0 && $UPGRADE -eq 0 ]]; then
  echo "  $TARGET/.claude already initialized. Re-run with --upgrade to merge in new features (preserves your edits), or --force to overwrite generated files."
  exit 1
fi

# ---- init banner (fresh init only; not on --upgrade) ---------------------
# Beat 1: golden-angle plant animation (TTY + Unicode only, else skipped).
# Beat 2: V4 box-drawing CLAUDE KIT banner snap (always).
if [[ $UPGRADE -eq 0 ]]; then
  _kit_init_banner "$PLUGIN_VERSION"
fi

UPGRADE_ADDED=(); UPGRADE_PRESERVED=(); UPGRADE_SKIPPED=()
echo "-> $([[ $UPGRADE -eq 1 ]] && echo Upgrading || echo Scaffolding) $PROFILE profile $([[ $UPGRADE -eq 1 ]] && echo in || echo into) $TARGET"
mkdir -p "$TARGET/.claude/agents" "$TARGET/.claude/skills" "$TARGET/.claude/rules" "$TARGET/scripts/lib"

# ---- kit.config.json (built with jq for correctness) --------------------
KITCFG="$TARGET/.claude/kit.config.json"
jq -n \
  --arg kitver "$PLUGIN_VERSION" \
  --arg name "$NAME" --arg slug "$SLUG" --arg owner "$OWNER_NAME" --arg lang "$LANG_PREF" --arg path "$TARGET" \
  --arg profile "$PROFILE" --argjson roles "$ROLES_JSON" \
  --arg repo "$REPO" --arg ghowner "$GH_OWNER" \
  --argjson pv2 "$PROJECTS_V2" --argjson pnum "$PNUM_JSON" --arg ptitle "$NAME" \
  --argjson milestones "$MS_JSON" \
  --arg pfmt "$PLANS_FORMAT" --arg pdir "$PLANS_DIR" \
  --argjson mem "$MEMORY_BOOL" --arg wing "$SLUG" --arg cps "$CLAUDE_PROJECT_SLUG" \
  --argjson speckit "$SPECKIT_JSON" \
  --argjson ppen "$PREPUSH_ENABLED" --arg ppcmd "$PREPUSH_CMD" \
  --argjson localon "$LOCAL_ON" \
  '{kitVersion:$kitver,
    project:{name:$name,slug:$slug,owner:$owner,language:$lang,path:$path},
    profile:$profile, roles:$roles,
    github:{repo:$repo,owner:$ghowner,projectsV2:$pv2,projectNumber:$pnum,projectTitle:$ptitle},
    milestones:$milestones,
    plans:{format:$pfmt,dir:$pdir},
    knowledge:{dir:"knowledge"},
    specKit:{enabled:$speckit},
    prePush:{enabled:$ppen,command:$ppcmd},
    local:{enabled:$localon,port:8080,model:"mlx-community/Qwen3-8B-4bit"},
    memory:{enabled:$mem,provider:"mempalace",wing:$wing,claudeProjectSlug:$cps}}' \
  > "$KITCFG.kit-new"
if [[ $UPGRADE -eq 1 && -f "$KITCFG" ]]; then
  # deep-merge: existing values win (preserve user choices), new keys added, version bumped.
  jq -s --arg kitver "$PLUGIN_VERSION" '.[0] * .[1] | .kitVersion = $kitver' "$KITCFG.kit-new" "$KITCFG" \
    > "$KITCFG.merged" && mv "$KITCFG.merged" "$KITCFG"
  rm -f "$KITCFG.kit-new"
  # Existing values win in the merge — but an EXPLICIT --local flag is a user decision now,
  # so it overrides the preserved value (port/model stay as the user configured them).
  if [[ $LOCAL_EXPLICIT -eq 1 ]]; then
    jq --argjson v "$LOCAL_ON" '.local = ((.local // {port:8080,model:"mlx-community/Qwen3-8B-4bit"}) | .enabled = $v)' \
      "$KITCFG" > "$KITCFG.tmp" && mv "$KITCFG.tmp" "$KITCFG"
  fi
  echo "  + .claude/kit.config.json (merged · kitVersion -> $PLUGIN_VERSION)"
else
  mv "$KITCFG.kit-new" "$KITCFG"
  echo "  + .claude/kit.config.json"
fi

# ---- CLAUDE.md -----------------------------------------------------------
safe_write "$KIT_ROOT/templates/CLAUDE.md.tmpl" "$TARGET/CLAUDE.md"
echo "  + CLAUDE.md"

# ---- rules (filtered by enabled flags) ----------------------------------
for r in $RULES; do
  # Skip rules whose feature is disabled for this project.
  case "$r" in
    mempalace)          [[ "$MEMORY_BOOL" == "true" ]] || continue ;;
    design-routing)     [[ "$DESIGN_ON"   == "true" ]] || continue ;;
    plan-output-format) [[ "$PLANS_ON"    == "true" ]] || continue ;;
  esac
  src="$KIT_ROOT/templates/rules/$r.md"
  [[ -f "$src" ]] || { echo "  missing rule: $r"; continue; }
  safe_write "$src" "$TARGET/.claude/rules/$r.md"
  echo "  + .claude/rules/$r.md"
done

# ---- agents --------------------------------------------------------------
for a in $AGENTS; do
  src="$KIT_ROOT/templates/agents/$a.md"
  [[ -f "$src" ]] || continue
  safe_write "$src" "$TARGET/.claude/agents/$a/AGENT.md"
  echo "  + .claude/agents/$a/AGENT.md"
done

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
  safe_write "$src" "$TARGET/.claude/skills/$dest_name/SKILL.md"
  # If prefixed AND this was a FRESH scaffold (frontmatter still bare), rewrite name + sibling refs.
  # An existing (preserved) skill already reads `name: $dest_name`, so the guard skips it.
  if [[ "$dest_name" != "$s" && -f "$TARGET/.claude/skills/$dest_name/SKILL.md" ]] \
     && grep -qE "^name:[[:space:]]*${s}[[:space:]]*\$" "$TARGET/.claude/skills/$dest_name/SKILL.md"; then
    _prefix_skill_file "$TARGET/.claude/skills/$dest_name/SKILL.md"
  fi
  echo "  + .claude/skills/$dest_name/SKILL.md"
  # bundled references for multi-file skills (copied verbatim, no templating).
  # Per-file safe_copy so the upgrade contract (preserve existing, skip excluded) applies.
  if [[ -d "$KIT_ROOT/templates/skills/$s/references" ]]; then
    for _ref in "$KIT_ROOT/templates/skills/$s/references/"*; do
      [[ -f "$_ref" ]] || continue
      safe_copy "$_ref" "$TARGET/.claude/skills/$dest_name/references/$(basename "$_ref")"
    done
    echo "  + .claude/skills/$dest_name/references/"
  fi
done

# ---- scripts (libs + setup + sync; kit-owned) ---------------------------
# safe_copy honors the upgrade contract: on --upgrade an EXISTING script is PRESERVED, never
# overwritten with an older template (the #334 downgrade that erased #307/#313/#314). Fresh
# inits get the current scripts; to refresh a kit-owned script later, delete it then re-upgrade.
safe_copy "$KIT_ROOT/scripts/lib/kit-config.sh"     "$TARGET/scripts/lib/kit-config.sh"
safe_copy "$KIT_ROOT/scripts/lib/gh-project.sh"     "$TARGET/scripts/lib/gh-project.sh"
safe_copy "$KIT_ROOT/scripts/lib/worktree-issue.sh" "$TARGET/scripts/lib/worktree-issue.sh"
safe_copy "$KIT_ROOT/scripts/lib/role-identity.sh"  "$TARGET/scripts/lib/role-identity.sh"
safe_copy "$KIT_ROOT/scripts/lib/kit-local.sh"      "$TARGET/scripts/lib/kit-local.sh"
safe_copy "$KIT_ROOT/scripts/lib/engine-adapter.sh" "$TARGET/scripts/lib/engine-adapter.sh"
safe_copy "$KIT_ROOT/scripts/lib/effort-metrics.sh" "$TARGET/scripts/lib/effort-metrics.sh"
safe_copy "$KIT_ROOT/scripts/lib/gh-log.sh"         "$TARGET/scripts/lib/gh-log.sh"
safe_copy "$KIT_ROOT/scripts/lib/kit-events.sh"     "$TARGET/scripts/lib/kit-events.sh"
safe_copy "$KIT_ROOT/scripts/lib/worktree-start.sh" "$TARGET/scripts/lib/worktree-start.sh"
safe_copy "$KIT_ROOT/scripts/kit-version-check.sh"  "$TARGET/scripts/kit-version-check.sh" exec
for sc in setup-labels.sh setup-milestones.sh capture-project-ids.sh task-sync.sh knowledge-lint.sh; do
  safe_copy "$KIT_ROOT/scripts/$sc" "$TARGET/scripts/$sc" exec
done
echo "  + scripts/ (libs + setup + task-sync + version-check + knowledge-lint)"

# ---- knowledge base (governed dir: INDEX manifest; upgrade-safe) ---------
mkdir -p "$TARGET/knowledge"
safe_write "$KIT_ROOT/templates/knowledge-INDEX.md.tmpl" "$TARGET/knowledge/INDEX.md"
echo "  + knowledge/INDEX.md (manifest — see .claude/rules/knowledge-base.md)"

# ---- .claude/lib (kit-sigil attribution helper; all projects; idempotent) ----
# Sourced by the task-* skill footers + repo-hygiene to emit one "claude-kit"
# attribution sigil per kit-action boundary (see knowledge/brand.md §6).
mkdir -p "$TARGET/.claude/lib"
safe_write "$KIT_ROOT/templates/lib/kit-sigil.sh.tmpl" "$TARGET/.claude/lib/kit-sigil.sh"
chmod +x "$TARGET/.claude/lib/kit-sigil.sh" 2>/dev/null || true
echo "  + .claude/lib/kit-sigil.sh"

# ---- settings.local.json (+ hooks, additive) ----------------------------
mkdir -p "$TARGET/.claude"
safe_write "$KIT_ROOT/templates/settings/settings.local.json.tmpl" "$TARGET/.claude/settings.local.json"
SETTINGS="$TARGET/.claude/settings.local.json"
merge_settings() { jq "$@" "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"; }
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
  safe_write "$KIT_ROOT/templates/hooks/kit-local-status.sh.tmpl" "$TARGET/.claude/hooks/kit-local-status.sh"
  chmod +x "$TARGET/.claude/hooks/kit-local-status.sh" 2>/dev/null || true
  merge_settings --arg ls "$TARGET/.claude/hooks/kit-local-status.sh" \
    '.hooks.SessionStart = (((.hooks.SessionStart // []) | map(select((.hooks[0].command // "") != $ls))) + [{matcher:"",hooks:[{type:"command",command:$ls,timeout:10}]}])'
  HOOK_NOTE="$HOOK_NOTE + local-status"
fi

# ---- repo-hygiene SessionStart hook (all projects; read-only; idempotent) ----
mkdir -p "$TARGET/.claude/hooks"
safe_write "$KIT_ROOT/templates/hooks/repo-hygiene.sh.tmpl" "$TARGET/.claude/hooks/repo-hygiene.sh"
chmod +x "$TARGET/.claude/hooks/repo-hygiene.sh" 2>/dev/null || true
merge_settings --arg rh "$TARGET/.claude/hooks/repo-hygiene.sh" \
  '.hooks.SessionStart = (((.hooks.SessionStart // []) | map(select((.hooks[0].command // "") != $rh))) + [{matcher:"",hooks:[{type:"command",command:$rh,timeout:10}]}])'
HOOK_NOTE="$HOOK_NOTE + repo-hygiene"

# ---- base-branch commit guard PreToolUse(Bash) hook (all projects; idempotent) ----
mkdir -p "$TARGET/.claude/hooks"
safe_write "$KIT_ROOT/templates/hooks/guard-base-branch-commit.sh.tmpl" "$TARGET/.claude/hooks/guard-base-branch-commit.sh"
chmod +x "$TARGET/.claude/hooks/guard-base-branch-commit.sh" 2>/dev/null || true
merge_settings --arg gd "$TARGET/.claude/hooks/guard-base-branch-commit.sh" \
  '.hooks.PreToolUse = (((.hooks.PreToolUse // []) | map(select((.hooks[0].command // "") != $gd))) + [{matcher:"Bash",hooks:[{type:"command",command:$gd,timeout:10}]}])'
HOOK_NOTE="$HOOK_NOTE + commit-guard"

# ---- version-check SessionStart hook (all projects; idempotent) ---------
mkdir -p "$TARGET/.claude/hooks"
safe_write "$KIT_ROOT/templates/hooks/kit_version_check.sh.tmpl" "$TARGET/.claude/hooks/kit_version_check.sh"
chmod +x "$TARGET/.claude/hooks/kit_version_check.sh" 2>/dev/null || true
merge_settings --arg vc "$TARGET/.claude/hooks/kit_version_check.sh" \
  '.hooks.SessionStart = (((.hooks.SessionStart // []) | map(select((.hooks[0].command // "") != $vc))) + [{matcher:"",hooks:[{type:"command",command:$vc,timeout:10}]}])'
HOOK_NOTE="$HOOK_NOTE + version-check"

# ---- recommended .gitignore entries (idempotent) ------------------------
# kit.manifest.json is kit-managed bookkeeping (content hashes + timestamps, re-stamped on every
# wire) — tracking it would dirty the tree on every session/upgrade, the exact churn #334 removes.
GI="$TARGET/.gitignore"
for _ig in ".claude/settings.local.json" ".claude/kit.manifest.json" ".kann/"; do
  if [[ -f "$GI" ]]; then grep -qxF "$_ig" "$GI" || printf '%s\n' "$_ig" >> "$GI"; else printf '%s\n' "$_ig" > "$GI"; fi
done

echo "  + .claude/settings.local.json${HOOK_NOTE:+ (}${HOOK_NOTE# + }${HOOK_NOTE:+)}"

# ---- wire (converge) -----------------------------------------------------
# Runs on BOTH scaffold and --upgrade so every update re-wires (fixes the class of bug where
# /kit-update refreshed files but never re-ran the wiring → statusline/settings drifted). #369
if [[ -f "$KIT_ROOT/scripts/kit-wire.sh" ]]; then
  if ( cd "$TARGET" && CLAUDE_PLUGIN_ROOT="$KIT_ROOT" KIT_ASSUME_YES=1 bash "$KIT_ROOT/scripts/kit-wire.sh" >/dev/null 2>&1 ); then
    echo "  + wired: statusline shim + settings.statusLine (kit-wire)"
  fi
fi

# ---- summary -------------------------------------------------------------
echo ""
echo "claude-kit $([[ $UPGRADE -eq 1 ]] && echo upgraded || echo scaffolded) — profile: $PROFILE"
echo "  Project : $NAME ($SLUG)"
echo "  Repo    : $REPO"
echo "  Board   : $([[ "$PROJECTS_V2" == "true" ]] && echo "Projects v2 #$PROJECT_NUMBER" || echo "off (gh issues only)")"
echo "  Agents  : $(echo $AGENTS | tr '\n' ' ')"
echo "  Memory  : $MEMORY_BOOL   Plans: $PLANS_FORMAT   Lang: $LANG_PREF   kitVersion: $PLUGIN_VERSION"
echo "  Spec Kit: $SPECKIT_ON   Pre-push gate: $PREPUSH_ENABLED   Local model: $LOCAL_ON   Stack skills self-gate by package.json"

if [[ $UPGRADE -eq 1 ]]; then
  echo ""
  echo "  Upgrade -> kitVersion $PLUGIN_VERSION"
  if [[ ${#UPGRADE_ADDED[@]}     -gt 0 ]]; then echo "  Added (new in this kit version):"; printf '    + %s\n' "${UPGRADE_ADDED[@]}"; fi
  if [[ ${#UPGRADE_PRESERVED[@]} -gt 0 ]]; then echo "  Preserved (your edits, untouched):"; printf '    = %s\n' "${UPGRADE_PRESERVED[@]}"; fi
  if [[ ${#UPGRADE_SKIPPED[@]}   -gt 0 ]]; then echo "  Skipped (removed/renamed via kit.config upgrade):"; printf '    - %s\n' "${UPGRADE_SKIPPED[@]}"; fi
else
  echo ""
  echo "Next steps:"
  echo "  1. Review CLAUDE.md and .claude/kit.config.json"
  echo "  2. ./scripts/setup-labels.sh && ./scripts/setup-milestones.sh   # seed the repo"
  [[ "$PROJECTS_V2" == "true" ]] && echo "  3. ./scripts/capture-project-ids.sh   # cache Projects v2 field IDs"
  [[ "$LOCAL_ON" == "true" ]] && echo "  4. /kit-doctor   # local model layer: installs mlx-lm (uv tool install) + starts mlx_lm.server"
fi

exit 0
