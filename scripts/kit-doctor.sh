#!/usr/bin/env bash
# kit-doctor — onboarding preflight: deps + brew bootstrap + gh auth/scopes + SSH guided
#
# Usage:
#   scripts/kit-doctor.sh                 # detect + report; in a terminal, ASK before installing.
#                                         # With no terminal and no --fix: report only, nothing is
#                                         # installed and no file is written
#   scripts/kit-doctor.sh --fix           # install missing deps without asking (alias: --yes, -y)
#   scripts/kit-doctor.sh --dry-run       # report only — no installs, no auth changes
#   scripts/kit-doctor.sh --no-install    # check and auth only — skip package installs
#   scripts/kit-doctor.sh --dismiss-local # silence the "local layer down" session notice
#                                         # until the next x.y kit update
#   scripts/kit-doctor.sh --agents        # only the selected agent runtimes (claude / codex):
#                                         # present or absent; exit 1 if one is absent. No network.
#
# Tiers:
#   Tier 0  Homebrew (macOS bootstrap — requires sudo password)
#   Tier 1  git, gh, jq, perl           — hard deps, auto-install via brew
#   Tier 2  node + pnpm, vercel, turbo  — project-specific, auto-install if applicable
#   Agents  the runtime binary of each adapter the project selected (`adapters` in the config),
#           plus whether the Codex hooks are registered in .codex/hooks.json when codex is selected
#   Integr. one row per descriptor in integrations/ that is on (its config key, or on by default
#           with the key absent — a missing default-on tool is reported, not failed) — installed by the
#           shared runner (scripts/lib/integration-install.sh), only with recorded consent
#   Local   mlx_lm.server auto-start (when .local.enabled)
#   Auth    gh auth status + scope:project, git config name/email
#   SSH     optional guided flow (ed25519, pbcopy, link to github settings)
set -euo pipefail

# Own directory — so we can find sibling scripts (kit-export-project.sh) regardless of cwd.
_export_dir_doctor="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ---- flags ------------------------------------------------------------------
DRY_RUN=0; NO_INSTALL=0; DISMISS_LOCAL=0; ASSUME_YES=0; AGENTS_ONLY=0
INSTALL_APPROVED=0   # 1 = the operator said yes to installs in THIS run (--fix/--yes, or the prompt)
for _a in "$@"; do
  case "$_a" in
    --dry-run)       DRY_RUN=1 ;;
    --no-install)    NO_INSTALL=1 ;;
    --fix|--yes|-y)  ASSUME_YES=1; INSTALL_APPROVED=1 ;;
    --dismiss-local) DISMISS_LOCAL=1 ;;
    --agents)        AGENTS_ONLY=1 ;;
    -h|--help)
      sed -n '2,15p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
  esac
done

# ---- --dismiss-local: record the dismiss and exit (no preflight run) ---------
# Writes .local.dismissed = current kitVersion to kit.config.json; the SessionStart
# notice stays silent until the kit's x.y core moves past it (issue #313).
if [[ $DISMISS_LOCAL -eq 1 ]]; then
  command -v kit_config_path >/dev/null 2>&1 || . "$(dirname "$0")/lib/config-path.sh"
  _kitcfg="$(kit_config_path "${TARGET:-$PWD}" 2>/dev/null || true)"
  [[ -n "$_kitcfg" ]] || _kitcfg="${TARGET:-$PWD}/.claude/kit.config.json"
  if ! command -v jq >/dev/null 2>&1 || [[ ! -f "$_kitcfg" ]]; then
    echo "kit-doctor: cannot dismiss — need jq + $_kitcfg" >&2
    exit 1
  fi
  _kv="$(jq -r '.kitVersion // "0.0.0"' "$_kitcfg")"
  _tmp="$(mktemp)"
  jq --arg v "$_kv" '.local.dismissed = $v' "$_kitcfg" > "$_tmp" && mv "$_tmp" "$_kitcfg"
  echo "local layer notice dismissed (kit $_kv) — reappears on the next x.y kit update"
  echo "re-enable earlier: remove .local.dismissed from .claude/kit.config.json"
  exit 0
fi

# ---- color/unicode detection (matches kit-sigil.sh pattern) -----------------
_loc="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
if [ "${KIT_ASCII:-}" = "1" ]; then KIT_UNICODE=0
elif printf '%s' "$_loc" | grep -qiE 'utf-?8'; then KIT_UNICODE=1
else KIT_UNICODE=0; fi

if [ "${FORCE_COLOR:-}" = "1" ]; then KIT_COLOR=1
elif [ -t 1 ] && [ -z "${NO_COLOR+x}" ]; then KIT_COLOR=1
else KIT_COLOR=0; fi

if [ "$KIT_COLOR" = 1 ]; then
  C_AZAFRAN=$'\033[38;2;201;122;44m'
  C_SUCCESS=$'\033[38;2;21;128;61m'
  C_FAIL=$'\033[38;2;192;50;43m'
  C_WARN=$'\033[38;2;180;83;9m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_AZAFRAN=''; C_SUCCESS=''; C_FAIL=''; C_WARN=''; C_DIM=''; C_BOLD=''; C_RESET=''
fi

if [ "$KIT_UNICODE" = 1 ]; then
  MARK_OK="${C_SUCCESS}✓${C_RESET}"
  MARK_FAIL="${C_FAIL}✗${C_RESET}"
  MARK_WARN="${C_WARN}!${C_RESET}"
  MARK_SKIP="${C_DIM}-${C_RESET}"
  MARK_SEED="${C_AZAFRAN}⡶${C_RESET}"
else
  MARK_OK="ok"; MARK_FAIL="FAIL"; MARK_WARN="warn"; MARK_SKIP="-"; MARK_SEED="o"
fi

# ---- install consent --------------------------------------------------------
# The doctor can install missing dependencies for you (Homebrew, gh, jq, node, …). When a HUMAN runs
# it in a terminal, ASK first — install only if approved. A non-interactive caller that wants
# installs passes --fix/--yes (init.sh's preflight does). A run with no terminal and no --fix has
# nobody to ask, so it is report-only: no package install, no `pnpm install`, no seeded or refreshed
# file, no server start (#448 — it used to run `pnpm install` in whatever directory it was called
# from). --dry-run / --no-install already skip installs entirely. MAY_INSTALL is the one gate every
# install or write below reads.
if [[ $DRY_RUN -eq 0 && $NO_INSTALL -eq 0 && $ASSUME_YES -eq 0 && $AGENTS_ONLY -eq 0 && -t 0 ]]; then
  printf '\n  %s%scckit doctor can install anything missing for you%s (via Homebrew, corepack, etc.).\n' "$C_BOLD" "" "$C_RESET"
  printf '  It will show each thing as it goes. Nothing is installed if you decline.\n\n'
  printf '  Install missing dependencies? [Y/n] '
  read -r _reply || _reply=""
  case "$_reply" in
    [nN]|[nN][oO])
      NO_INSTALL=1
      printf '\n  %s report-only — listing what is missing and how to install it (no changes made).\n' "$MARK_SKIP" ;;
    *) INSTALL_APPROVED=1 ;;  # default (Enter / y) → proceed with installs
  esac
fi
MAY_INSTALL=0; UNAPPROVED=0
if [[ $DRY_RUN -eq 0 && $NO_INSTALL -eq 0 ]]; then
  if [[ $INSTALL_APPROVED -eq 1 ]]; then MAY_INSTALL=1; else UNAPPROVED=1; fi
fi

# ---- report accumulators ----------------------------------------------------
CHECKS_OK=0; CHECKS_FAIL=0; CHECKS_WARN=0
ACTIONS_TAKEN=()   # things the doctor installed/fixed
ACTIONS_NEEDED=()  # things the user must do manually

row() {  # <mark> <label> <detail>
  printf '  %-3s  %-28s %s\n' "$1" "$2" "${3:-}"
}

# ---- macOS detection --------------------------------------------------------
IS_MACOS=0
[[ "$(uname -s 2>/dev/null)" == "Darwin" ]] && IS_MACOS=1

# ---- helpers ----------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

# brew_install <pkg> [<cmd-to-check>] — install via brew unless dry-run/no-install
# Returns 0 if the command is now available, 1 if not.
brew_install() {
  local pkg="$1" cmd="${2:-$1}"
  if [[ $MAY_INSTALL -eq 0 ]]; then
    return 1
  fi
  if ! has_cmd brew; then return 1; fi
  brew install "$pkg" >/dev/null 2>&1 && has_cmd "$cmd"
}

# ---- agent runtimes (E257.3) ------------------------------------------------
# One row per adapter the project SELECTED (`adapters` in its config; a config without the key means
# claude). An adapter whose CLI is not on PATH is installed but cannot run, so it is a warning and a
# manual action — the doctor never installs an agent CLI. Sets AGENTS_ABSENT to the count.
AGENTS_ABSENT=0
doctor_agents() {
  local _d _sel _name _state _ver _tab
  _d="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
  command -v kit_config_path >/dev/null 2>&1 || . "$_d/lib/config-path.sh"
  command -v adapter_runtime_report >/dev/null 2>&1 || . "$_d/lib/adapter-select.sh"
  _tab="$(printf '\t')"
  if ! _sel="$(adapter_project_list "${TARGET:-$PWD}" 2>/dev/null)"; then
    row "$MARK_FAIL" "adapters" "the config's 'adapters' value is invalid (expected claude and/or codex)"
    CHECKS_FAIL=$((CHECKS_FAIL + 1)); AGENTS_ABSENT=$((AGENTS_ABSENT + 1))
    return 0
  fi
  while IFS="$_tab" read -r _name _state _ver; do
    [[ -n "$_name" ]] || continue
    if [[ "$_state" == "present" ]]; then
      row "$MARK_OK" "$_name" "$_ver"
      CHECKS_OK=$((CHECKS_OK + 1))
    else
      row "$MARK_WARN" "$_name" "absent — the $_name adapter is selected but its CLI is not on PATH"
      CHECKS_WARN=$((CHECKS_WARN + 1)); AGENTS_ABSENT=$((AGENTS_ABSENT + 1))
      ACTIONS_NEEDED+=("Install the $_name CLI (the project selects the $_name adapter)")
    fi
  done <<EOF_AGENTS
$(adapter_runtime_report "$_sel")
EOF_AGENTS
  # Codex runs a project's hooks from .codex/hooks.json, and only after the user trusted them. The
  # registration is checkable; the trust is Codex's own per-machine state and is not readable here,
  # so a registered row says so instead of claiming the hooks run (E257.5).
  if adapter_has "$_sel" codex; then
    local _root
    command -v codex_hooks_registered >/dev/null 2>&1 || . "$_d/lib/codex-hooks.sh"
    _root="$(git -C "${TARGET:-$PWD}" rev-parse --show-toplevel 2>/dev/null)"
    [[ -n "$_root" ]] || _root="${TARGET:-$PWD}"
    if codex_hooks_registered "$_root/.codex/hooks.json" guard-base-branch-commit.sh \
       && codex_hooks_registered "$_root/.codex/hooks.json" kit-mail-check.sh; then
      row "$MARK_OK" "codex hooks" "registered in .codex/hooks.json — Codex runs them once trusted (/hooks in Codex; trust is not readable from here)"
      CHECKS_OK=$((CHECKS_OK + 1))
    else
      row "$MARK_WARN" "codex hooks" "not registered in .codex/hooks.json — the commit guard and session mail do not run in Codex"
      CHECKS_WARN=$((CHECKS_WARN + 1))
      ACTIONS_NEEDED+=("Run cckit init --upgrade to register the Codex hooks in .codex/hooks.json")
    fi
  fi
}

# ---- --agents: only the runtime rows, then exit (no installs, no network) ----
if [[ $AGENTS_ONLY -eq 1 ]]; then
  printf '  %s%sAgent runtimes%s\n' "$C_BOLD" "" "$C_RESET"
  doctor_agents
  [[ $AGENTS_ABSENT -eq 0 ]] || exit 1
  exit 0
fi

# ============================================================================
# BANNER
# ============================================================================
printf '\n'
printf '  %s%s%s  kit-doctor\n' "$MARK_SEED" "$C_BOLD" " / claude-kit${C_RESET}"
printf '  %s\n' "${C_DIM}onboarding preflight${C_RESET}${DRY_RUN:+${C_WARN} [dry-run]${C_RESET}}${NO_INSTALL:+${C_DIM} [no-install]${C_RESET}}"
[[ $UNAPPROVED -eq 1 && $AGENTS_ONLY -eq 0 ]] && printf '  %s report-only — no terminal and no --fix, so nothing is installed and no file is written. To install: cckit doctor --fix\n' "$MARK_SKIP"
printf '\n'

# ============================================================================
# TIER 0 — Homebrew bootstrap (macOS only)
# ============================================================================
printf '  %s%sTier 0 — bootstrap%s\n' "$C_BOLD" "" "$C_RESET"

if [[ $IS_MACOS -eq 0 ]]; then
  row "$MARK_SKIP" "Homebrew" "not macOS — skipping"
elif has_cmd brew; then
  row "$MARK_OK" "Homebrew" "$(brew --version 2>/dev/null | head -1)"
  CHECKS_OK=$((CHECKS_OK + 1))
else
  if [[ $MAY_INSTALL -eq 0 ]]; then
    row "$MARK_FAIL" "Homebrew" "missing — install: https://brew.sh"
    CHECKS_FAIL=$((CHECKS_FAIL + 1))
    ACTIONS_NEEDED+=("Install Homebrew: https://brew.sh")
  else
    printf '\n'
    printf '  %s Homebrew not found — running the official installer (will ask for sudo password)...\n' "$MARK_WARN"
    printf '  %sInstaller URL: https://brew.sh%s\n\n' "$C_DIM" "$C_RESET"
    if /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
      # Add brew to PATH for the rest of this session (Apple Silicon path)
      [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)" 2>/dev/null || true
      [[ -f /usr/local/bin/brew   ]] && eval "$(/usr/local/bin/brew shellenv)"   2>/dev/null || true
      row "$MARK_OK" "Homebrew" "installed $(brew --version 2>/dev/null | head -1)"
      CHECKS_OK=$((CHECKS_OK + 1))
      ACTIONS_TAKEN+=("Installed Homebrew")
    else
      row "$MARK_FAIL" "Homebrew" "install failed — see https://brew.sh"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Manually install Homebrew: https://brew.sh")
    fi
  fi
fi
printf '\n'

# ============================================================================
# TIER 1 — hard deps
# ============================================================================
printf '  %s%sTier 1 — hard deps%s\n' "$C_BOLD" "" "$C_RESET"

# ---- git -------------------------------------------------------------------
if has_cmd git; then
  _gitver="$(git --version 2>/dev/null | awk '{print $3}')"
  row "$MARK_OK" "git" "$_gitver"
  CHECKS_OK=$((CHECKS_OK + 1))
elif brew_install git; then
  row "$MARK_OK" "git" "installed $(git --version 2>/dev/null | awk '{print $3}')"
  CHECKS_OK=$((CHECKS_OK + 1))
  ACTIONS_TAKEN+=("Installed git via brew")
else
  row "$MARK_FAIL" "git" "missing — brew install git"
  CHECKS_FAIL=$((CHECKS_FAIL + 1))
  ACTIONS_NEEDED+=("Install git: brew install git")
fi

# ---- gh (min version 2.29 for Projects v2) ----------------------------------
GH_OK=0
if has_cmd gh; then
  _ghver="$(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
  # Check for Projects v2 support (gh >= 2.29.0)
  _ghmaj="${_ghver%%.*}"
  _ghmin="${_ghver#*.}"; _ghmin="${_ghmin%%.*}"
  if [[ "${_ghmaj:-0}" -gt 2 ]] || \
     [[ "${_ghmaj:-0}" -eq 2 && "${_ghmin:-0}" -ge 29 ]]; then
    row "$MARK_OK" "gh" "$_ghver (Projects v2 ok)"
    CHECKS_OK=$((CHECKS_OK + 1))
    GH_OK=1
  else
    row "$MARK_WARN" "gh" "$_ghver — upgrade needed (>=2.29 for Projects v2)"
    CHECKS_WARN=$((CHECKS_WARN + 1))
    if [[ $MAY_INSTALL -eq 1 ]] && has_cmd brew; then
      brew upgrade gh >/dev/null 2>&1 && GH_OK=1 && ACTIONS_TAKEN+=("Upgraded gh")
    fi
    [[ $GH_OK -eq 0 ]] && ACTIONS_NEEDED+=("Upgrade gh: brew upgrade gh")
  fi
elif brew_install gh; then
  _ghver="$(gh --version 2>/dev/null | head -1 | awk '{print $3}')"
  row "$MARK_OK" "gh" "installed $\_ghver"
  CHECKS_OK=$((CHECKS_OK + 1))
  GH_OK=1
  ACTIONS_TAKEN+=("Installed gh via brew")
else
  row "$MARK_FAIL" "gh" "missing — brew install gh"
  CHECKS_FAIL=$((CHECKS_FAIL + 1))
  ACTIONS_NEEDED+=("Install gh: brew install gh")
fi

# ---- jq -------------------------------------------------------------------
if has_cmd jq; then
  row "$MARK_OK" "jq" "$(jq --version 2>/dev/null)"
  CHECKS_OK=$((CHECKS_OK + 1))
elif brew_install jq; then
  row "$MARK_OK" "jq" "installed $(jq --version 2>/dev/null)"
  CHECKS_OK=$((CHECKS_OK + 1))
  ACTIONS_TAKEN+=("Installed jq via brew")
else
  row "$MARK_FAIL" "jq" "missing — brew install jq"
  CHECKS_FAIL=$((CHECKS_FAIL + 1))
  ACTIONS_NEEDED+=("Install jq: brew install jq")
fi

# ---- perl -----------------------------------------------------------------
if has_cmd perl; then
  row "$MARK_OK" "perl" "$(perl --version 2>/dev/null | head -2 | tail -1 | tr -d '()' | awk '{print $2}')"
  CHECKS_OK=$((CHECKS_OK + 1))
elif brew_install perl; then
  row "$MARK_OK" "perl" "installed"
  CHECKS_OK=$((CHECKS_OK + 1))
  ACTIONS_TAKEN+=("Installed perl via brew")
else
  row "$MARK_FAIL" "perl" "missing — brew install perl"
  CHECKS_FAIL=$((CHECKS_FAIL + 1))
  ACTIONS_NEEDED+=("Install perl: brew install perl")
fi
printf '\n'

# ============================================================================
# TIER 2 — project deps (context-aware)
# ============================================================================
printf '  %s%sTier 2 — project deps%s\n' "$C_BOLD" "" "$C_RESET"

# ---- node + pnpm (check package.json for pinned version) -------------------
_pkg_json="${TARGET:-$PWD}/package.json"
_pkg_mgr=""
[[ -f "$_pkg_json" ]] && _pkg_mgr="$(jq -r '.packageManager // ""' "$_pkg_json" 2>/dev/null || true)"

if has_cmd node; then
  row "$MARK_OK" "node" "$(node --version 2>/dev/null)"
  CHECKS_OK=$((CHECKS_OK + 1))
elif brew_install node; then
  row "$MARK_OK" "node" "installed $(node --version 2>/dev/null)"
  CHECKS_OK=$((CHECKS_OK + 1))
  ACTIONS_TAKEN+=("Installed node via brew")
else
  row "$MARK_FAIL" "node" "missing — brew install node"
  CHECKS_FAIL=$((CHECKS_FAIL + 1))
  ACTIONS_NEEDED+=("Install node: brew install node")
fi

if has_cmd pnpm; then
  row "$MARK_OK" "pnpm" "$(pnpm --version 2>/dev/null)"
  CHECKS_OK=$((CHECKS_OK + 1))
elif [[ -n "$_pkg_mgr" && "$_pkg_mgr" == pnpm* ]]; then
  # Pinned in package.json — enable via corepack
  if has_cmd corepack || has_cmd node; then
    if [[ $MAY_INSTALL -eq 1 ]]; then
      corepack enable pnpm 2>/dev/null && \
        corepack prepare "$_pkg_mgr" --activate 2>/dev/null && \
        ACTIONS_TAKEN+=("Enabled pnpm via corepack ($_pkg_mgr)") || true
    fi
    if has_cmd pnpm; then
      row "$MARK_OK" "pnpm" "$(pnpm --version 2>/dev/null) (via corepack)"
      CHECKS_OK=$((CHECKS_OK + 1))
    else
      row "$MARK_FAIL" "pnpm" "missing — corepack enable pnpm"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Enable pnpm: corepack enable pnpm && corepack prepare $_pkg_mgr --activate")
    fi
  else
    row "$MARK_FAIL" "pnpm" "missing — npm install -g pnpm"
    CHECKS_FAIL=$((CHECKS_FAIL + 1))
    ACTIONS_NEEDED+=("Install pnpm: npm install -g pnpm")
  fi
elif brew_install pnpm; then
  row "$MARK_OK" "pnpm" "installed $(pnpm --version 2>/dev/null)"
  CHECKS_OK=$((CHECKS_OK + 1))
  ACTIONS_TAKEN+=("Installed pnpm via brew")
else
  row "$MARK_WARN" "pnpm" "not found (needed for turbo monorepo)"
  CHECKS_WARN=$((CHECKS_WARN + 1))
  ACTIONS_NEEDED+=("Install pnpm: brew install pnpm")
fi

# ---- node_modules (check if pnpm install needed) ----------------------------
_nm="${TARGET:-$PWD}/node_modules"
if [[ -d "$_nm" ]]; then
  row "$MARK_OK" "node_modules" "present"
  CHECKS_OK=$((CHECKS_OK + 1))
elif [[ -f "$_pkg_json" ]]; then
  if [[ $MAY_INSTALL -eq 1 ]] && has_cmd pnpm; then
    printf '\n  %s node_modules missing — running pnpm install...\n' "$MARK_WARN"
    if pnpm install --frozen-lockfile 2>/dev/null || pnpm install; then
      row "$MARK_OK" "node_modules" "installed via pnpm install"
      CHECKS_OK=$((CHECKS_OK + 1))
      ACTIONS_TAKEN+=("Ran pnpm install")
    else
      row "$MARK_FAIL" "node_modules" "pnpm install failed — run manually"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Run pnpm install")
    fi
  else
    row "$MARK_WARN" "node_modules" "missing — run pnpm install"
    CHECKS_WARN=$((CHECKS_WARN + 1))
    ACTIONS_NEEDED+=("Run pnpm install")
  fi
else
  row "$MARK_SKIP" "node_modules" "no package.json found — skipping"
fi

# ---- vercel (only if .vercel/ linked or VERCEL env) -------------------------
_has_vercel_link=0
[[ -d "${TARGET:-$PWD}/.vercel" ]] && _has_vercel_link=1

if [[ $_has_vercel_link -eq 1 ]] || [[ -n "${VERCEL:-}" ]]; then
  if has_cmd vercel; then
    row "$MARK_OK" "vercel" "$(vercel --version 2>/dev/null | head -1)"
    CHECKS_OK=$((CHECKS_OK + 1))
  elif brew_install vercel vercel; then
    row "$MARK_OK" "vercel" "installed $(vercel --version 2>/dev/null | head -1)"
    CHECKS_OK=$((CHECKS_OK + 1))
    ACTIONS_TAKEN+=("Installed vercel CLI via brew")
  elif [[ $MAY_INSTALL -eq 1 ]] && has_cmd npm; then
    npm install -g vercel >/dev/null 2>&1 && \
      ACTIONS_TAKEN+=("Installed vercel CLI via npm") || true
    if has_cmd vercel; then
      row "$MARK_OK" "vercel" "installed $(vercel --version 2>/dev/null | head -1)"
      CHECKS_OK=$((CHECKS_OK + 1))
    else
      row "$MARK_FAIL" "vercel" "missing — npm install -g vercel"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Install vercel: npm install -g vercel")
    fi
  else
    row "$MARK_FAIL" "vercel" "missing — npm install -g vercel"
    CHECKS_FAIL=$((CHECKS_FAIL + 1))
    ACTIONS_NEEDED+=("Install vercel: npm install -g vercel")
  fi
else
  row "$MARK_SKIP" "vercel" "no .vercel/ project link — skipping"
fi

# turbo + playwright: dev deps only — never global; check node_modules
if [[ -d "$_nm" ]]; then
  if [[ -x "$_nm/.bin/turbo" ]]; then
    row "$MARK_OK" "turbo" "dev dep present"
    CHECKS_OK=$((CHECKS_OK + 1))
  else
    row "$MARK_SKIP" "turbo" "not in node_modules (run pnpm install)"
  fi
  if [[ -x "$_nm/.bin/playwright" ]]; then
    row "$MARK_OK" "playwright" "dev dep present"
    CHECKS_OK=$((CHECKS_OK + 1))
  else
    row "$MARK_SKIP" "playwright" "not in node_modules (run pnpm install)"
  fi
fi
printf '\n'

# ============================================================================
# AGENT RUNTIMES — the CLI of each selected adapter
# ============================================================================
printf '  %s%sAgent runtimes%s\n' "$C_BOLD" "" "$C_RESET"
doctor_agents
printf '\n'

# ============================================================================
# INTEGRATIONS (opt-in — one row per descriptor in integrations/ the project switched on)
# ============================================================================
# An optional third-party tool is DATA: integrations/<id>.json names its config key, its detect
# command and its install candidates in order. This loop holds no tool's recipe. For every
# descriptor whose config key is on it asks the shared runner (lib/integration-install.sh) and
# turns the runner's one status line into a row. Silent when the project switched nothing on.
#
# The runner installs only with consent recorded in .cckit/consent (`install:<id>`). The operator
# saying yes to installs in THIS run — --fix/--yes, or the terminal prompt above — is that consent,
# and is recorded here, so init's `--yes` preflight keeps installing. A run nobody approved (no
# TTY, no --fix) reports the tool missing and installs nothing. --dry-run / --no-install run the
# runner under KIT_DRY_RUN: it plans, and neither installs nor records anything.
command -v kit_config_path >/dev/null 2>&1 || . "$(dirname "$0")/lib/config-path.sh"
_kitcfg="$(kit_config_path "${TARGET:-$PWD}" 2>/dev/null || true)"
[[ -n "$_kitcfg" ]] || _kitcfg="${TARGET:-$PWD}/.claude/kit.config.json"

# doctor_integration <descriptor> — one row for one enabled integration.
doctor_integration() {
  local f="$1" id label recipe st bin after
  id="$(jq -r '.id' "$f")"; label="$(jq -r '.label' "$f")"
  recipe="$(jq -r '.install[0].run' "$f")"
  if integration_detect "$f" "$_ig_target"; then
    bin="$(integration_bin "$f" || true)"
    row "$MARK_OK" "$label" "installed${bin:+ ($bin)}"
    CHECKS_OK=$((CHECKS_OK + 1))
    return 0
  fi
  if ! integration_applies "$f" "$_ig_target"; then
    row "$MARK_SKIP" "$label" "needs $(integration_applies_needs "$f") — skipping install"
    return 0
  fi
  # On by default and never chosen by this project: its callers fall back without the tool, so a
  # missing one is reported, does not fail the run, and is NOT installed — a yes to installs covers
  # what the project switched on. `cckit add <id>` writes the key, and then the rows below apply.
  if integration_default_on "$f" && ! integration_explicit "$f" "$_kitcfg"; then
    row "$MARK_SKIP" "$label" "not installed — on by default, falls back without it. By hand: $recipe  (or 'cckit add $id', then 'cckit doctor --fix')"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 || $NO_INSTALL -eq 1 ]]; then
    st="$(KIT_DRY_RUN=1 integration_install "$f" "$_ig_target" 2>/dev/null || true)"
  else
    if [[ $INSTALL_APPROVED -eq 1 ]]; then integration_consent_record "$id" "$_ig_target" || true; fi
    st="$(integration_install "$f" "$_ig_target" || true)"
  fi
  case "$st" in
    present|installed\ *)
      bin="$(integration_bin "$f" || true)"
      if [[ "$st" == present ]]; then
        row "$MARK_OK" "$label" "installed${bin:+ ($bin)}"
      else
        after="$(jq -r '.afterInstall // ""' "$f")"
        row "$MARK_OK" "$label" "installed via ${st#installed }${bin:+ ($bin)}"
        ACTIONS_TAKEN+=("Installed $label via ${st#installed }${after:+ — $after}")
      fi
      CHECKS_OK=$((CHECKS_OK + 1)) ;;
    dry-run)
      row "$MARK_FAIL" "$label" "missing — $recipe"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Install $label: $recipe") ;;
    no-consent)
      row "$MARK_FAIL" "$label" "missing — nothing installs without your yes: cckit doctor --fix"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Install $label: cckit doctor --fix  (or by hand: $recipe)") ;;
    *)
      row "$MARK_FAIL" "$label" "install failed — $recipe"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Install $label: $recipe") ;;
  esac
}

_ig_target="${TARGET:-$PWD}"
if has_cmd jq && [[ -f "$_kitcfg" ]]; then
  # shellcheck source=/dev/null
  . "$_export_dir_doctor/lib/integration-install.sh"
  _ig_shown=0
  for _ig_id in $(integrations_list); do
    _ig_f="$(integration_file "$_ig_id")" || continue
    integration_enabled "$_ig_f" "$_kitcfg" || continue
    if [[ $_ig_shown -eq 0 ]]; then
      printf '  %s%sIntegrations (optional tools that are on in this project)%s\n' "$C_BOLD" "" "$C_RESET"
      _ig_shown=1
    fi
    doctor_integration "$_ig_f"
  done
  if [[ $_ig_shown -eq 1 ]]; then printf '\n'; fi
fi

# ============================================================================
# LOCAL MODEL LAYER (opt-in — only checked when .local.enabled is true)
# ============================================================================
# Same gating principle as vercel: silence when the project didn't opt in. The runtime itself is
# an integration (integrations/mlx-lm.json) and was handled by the loop above; this section is the
# part that is not an install — the server. When the runtime is present but the server is down,
# the doctor starts it in background + health-checks the port. --dry-run stays 100% read-only: it
# reports what it would do and starts nothing.
_local_on="false"
[[ -f "$_kitcfg" ]] && _local_on="$(jq -r '.local.enabled // false' "$_kitcfg" 2>/dev/null || echo false)"
if [[ "$_local_on" == "true" ]]; then
  printf '  %s%sLocal model layer (mlx_lm.server)%s\n' "$C_BOLD" "" "$C_RESET"
  _lport="$(jq -r '.local.port // 8080' "$_kitcfg" 2>/dev/null || echo 8080)"
  _lmodel="$(jq -r '.local.model // "mlx-community/Qwen3-8B-4bit"' "$_kitcfg" 2>/dev/null || echo "mlx-community/Qwen3-8B-4bit")"

  # Apple silicon — MLX requirement (the descriptor's appliesWhen.platform gates the install)
  if [[ $IS_MACOS -eq 1 && "$(uname -m 2>/dev/null)" == "arm64" ]]; then
    row "$MARK_OK" "apple silicon" "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo arm64)"
    CHECKS_OK=$((CHECKS_OK + 1))
  else
    row "$MARK_WARN" "apple silicon" "MLX needs an Apple silicon Mac — local layer will stay dormant here"
    CHECKS_WARN=$((CHECKS_WARN + 1))
  fi

  # the server binary — resolved through the descriptor, so ~/.local/bin is searched too
  _mlx_bin="$(integration_bin "$(integration_file mlx-lm 2>/dev/null || true)" 2>/dev/null || true)"

  # server alive on the configured port — auto-start when down + installed
  _lurl="http://127.0.0.1:${_lport}/v1/models"
  if curl -sf -m 1 "$_lurl" >/dev/null 2>&1; then
    row "$MARK_OK" "server" "alive @ :${_lport} (${_lmodel##*/}) — NL chores run at \$0"
    CHECKS_OK=$((CHECKS_OK + 1))
  elif [[ -z "$_mlx_bin" ]]; then
    row "$MARK_WARN" "server" "not running — install mlx-lm first, then re-run kit-doctor"
    CHECKS_WARN=$((CHECKS_WARN + 1))
    ACTIONS_NEEDED+=("Start the local model server: mlx_lm.server --model ${_lmodel} --port ${_lport}")
  elif [[ $DRY_RUN -eq 1 || $UNAPPROVED -eq 1 ]]; then
    row "$MARK_WARN" "server" "not running — would start mlx_lm.server in background (first run downloads ~4.5 GB)"
    CHECKS_WARN=$((CHECKS_WARN + 1))
    ACTIONS_NEEDED+=("Start the local model server: mlx_lm.server --model ${_lmodel} --port ${_lport}")
  else
    _llog="$HOME/.claude/kit-local-server.log"
    mkdir -p "$HOME/.claude" 2>/dev/null || _llog="${TMPDIR:-/tmp}/kit-local-server.log"
    # first-run warning: model not in the HF cache yet → server stays "loading" for a while
    _hfdir="$HOME/.cache/huggingface/hub/models--${_lmodel//\//--}"
    [[ -d "$_hfdir" ]] || printf '  %s first run: the model downloads now (~4.5 GB) — the server may take several minutes to come up\n' "$MARK_WARN"
    printf '  %s server down — starting mlx_lm.server in background (log: %s)...\n' "$MARK_WARN" "$_llog"
    nohup "$_mlx_bin" --model "$_lmodel" --port "$_lport" >>"$_llog" 2>&1 &
    _mlx_pid=$!
    _lup=0
    for _i in $(seq 1 30); do
      if curl -sf -m 1 "$_lurl" >/dev/null 2>&1; then _lup=1; break; fi
      kill -0 "$_mlx_pid" 2>/dev/null || break
      sleep 1
    done
    if [[ $_lup -eq 1 ]]; then
      row "$MARK_OK" "server" "started @ :${_lport} (${_lmodel##*/}) — NL chores run at \$0"
      CHECKS_OK=$((CHECKS_OK + 1))
      ACTIONS_TAKEN+=("Started mlx_lm.server @ :${_lport} (pid $_mlx_pid)")
    elif kill -0 "$_mlx_pid" 2>/dev/null; then
      row "$MARK_WARN" "server" "starting (pid $_mlx_pid) — model still downloading/loading; check: curl :${_lport}/v1/models"
      CHECKS_WARN=$((CHECKS_WARN + 1))
      ACTIONS_TAKEN+=("Started mlx_lm.server (pid $_mlx_pid) — still loading, log: $_llog")
    else
      row "$MARK_FAIL" "server" "failed to start — see $_llog"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Start the local model server manually: mlx_lm.server --model ${_lmodel} --port ${_lport} (log: $_llog)")
    fi
  fi
  printf '\n'
fi

# ============================================================================
# MEMORY LAYER (MemPalace) — opt-in — only checked when .memory.enabled is true
# ============================================================================
# Same gating principle as the local model layer: silent unless the project opted
# into memory at init. Two things to verify:
#   1. a per-wing identity header exists. `mempalace wake-up` scopes the L1 *body* to the
#      wing, but reads its L0 identity *header* from the single global ~/.mempalace/identity.txt
#      (mempalace layers.py Layer0), so every wing shows the same — usually wrong — header
#      unless .claude/mempal-identity.<wing>.txt is present. --fix seeds a starter from kit.config.
#   2. the session-start hook is current — older hooks just ran `wake-up --wing` and could not
#      apply the per-wing header from (1). --fix re-emits the hook from the kit template.
# The CLI itself is an integration (integrations/mempalace.json), handled by the loop above.
_mem_on="false"
[[ -f "$_kitcfg" ]] && _mem_on="$(jq -r '.memory.enabled // false' "$_kitcfg" 2>/dev/null || echo false)"
if [[ "$_mem_on" == "true" ]]; then
  printf '  %s%sMemory (MemPalace)%s\n' "$C_BOLD" "" "$C_RESET"
  _mwing="$(jq -r '.memory.wing // .project.slug // ""' "$_kitcfg" 2>/dev/null || echo "")"
  [[ -z "$_mwing" || "$_mwing" == "null" ]] && _mwing="$(basename "${TARGET:-$PWD}")"

  # 1. per-wing identity header — the fix for the global-header bug
  _idfile="${TARGET:-$PWD}/.claude/mempal-identity.${_mwing}.txt"
  _idfile_generic="${TARGET:-$PWD}/.claude/mempal-identity.txt"
  if [[ -s "$_idfile" ]] || [[ -s "$_idfile_generic" ]]; then
    _present="$_idfile"; [[ -s "$_idfile" ]] || _present="$_idfile_generic"
    row "$MARK_OK" "identity header" "wing-scoped (${_present#${TARGET:-$PWD}/})"
    CHECKS_OK=$((CHECKS_OK + 1))
  elif [[ $MAY_INSTALL -eq 1 ]]; then
    # Seed a starter header from kit.config so this wing stops inheriting the global identity.
    _owner="$(jq -r '.project.owner // ""' "$_kitcfg" 2>/dev/null || echo "")"
    _pname="$(jq -r '.project.name // ""' "$_kitcfg" 2>/dev/null || echo "")"
    [[ -z "$_pname" || "$_pname" == "null" ]] && _pname="$_mwing"
    {
      printf 'Project: %s (wing: %s)\n' "$_pname" "$_mwing"
      [[ -n "$_owner" && "$_owner" != "null" ]] && printf 'Owner: %s\n' "$_owner"
      printf 'Stack: (describe this project — this header shows on every session wake-up)\n'
    } > "$_idfile"
    row "$MARK_OK" "identity header" "seeded .claude/mempal-identity.${_mwing}.txt — edit the Stack line"
    ACTIONS_TAKEN+=("Seeded per-wing MemPalace header .claude/mempal-identity.${_mwing}.txt (edit it to taste)")
    CHECKS_OK=$((CHECKS_OK + 1))
  else
    row "$MARK_WARN" "identity header" "missing — wake-up shows the global ~/.mempalace/identity.txt for every wing"
    CHECKS_WARN=$((CHECKS_WARN + 1))
    ACTIONS_NEEDED+=("Create .claude/mempal-identity.${_mwing}.txt so this wing has its own wake-up header (or run: cckit doctor --fix)")
  fi

  # 2. session-start hook freshness — the `mempal-identity` marker means the hook
  #    knows how to swap in the per-wing header (1). Older hooks lack it.
  _hook="${TARGET:-$PWD}/.claude/hooks/mempal_session_start.sh"
  _kit_root="$(dirname "$_export_dir_doctor")"
  _hook_tmpl="$_kit_root/templates/hooks/mempal_session_start.sh.tmpl"
  if [[ ! -f "$_hook" ]]; then
    : # no hook installed — the integration row already covers a non-functioning memory layer
  elif grep -q 'mempal-identity' "$_hook" 2>/dev/null; then
    row "$MARK_OK" "session-start hook" "current — applies the per-wing header"
    CHECKS_OK=$((CHECKS_OK + 1))
  elif [[ $MAY_INSTALL -eq 1 && -f "$_hook_tmpl" ]]; then
    # Re-emit from the template (only {{WING}} to substitute; no IF blocks in this hook).
    if sed "s|{{WING}}|${_mwing}|g" "$_hook_tmpl" > "$_hook"; then
      chmod +x "$_hook"
      row "$MARK_OK" "session-start hook" "refreshed — now applies the per-wing header"
      ACTIONS_TAKEN+=("Refreshed .claude/hooks/mempal_session_start.sh (now swaps in the per-wing header)")
      CHECKS_OK=$((CHECKS_OK + 1))
    else
      row "$MARK_WARN" "session-start hook" "stale — refresh failed; re-run: cckit init --upgrade"
      CHECKS_WARN=$((CHECKS_WARN + 1))
      ACTIONS_NEEDED+=("Refresh the session-start hook manually: cckit init --upgrade")
    fi
  else
    row "$MARK_WARN" "session-start hook" "stale — ignores the per-wing header (runs wake-up --wing only)"
    CHECKS_WARN=$((CHECKS_WARN + 1))
    ACTIONS_NEEDED+=("Refresh the session-start hook: cckit doctor --fix (or cckit init --upgrade)")
  fi
  printf '\n'
fi

# ============================================================================
# AUTH + CONFIG
# ============================================================================
printf '  %s%sAuth + config%s\n' "$C_BOLD" "" "$C_RESET"

# ---- gh auth status ---------------------------------------------------------
GH_AUTHED=0
if ! has_cmd gh; then
  row "$MARK_SKIP" "gh auth" "gh not found — install first"
else
  if gh auth status >/dev/null 2>&1; then
    _ghuser="$(gh api user --jq .login 2>/dev/null || echo "unknown")"
    row "$MARK_OK" "gh auth" "logged in as @$_ghuser"
    CHECKS_OK=$((CHECKS_OK + 1))
    GH_AUTHED=1
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      row "$MARK_FAIL" "gh auth" "not authenticated — gh auth login"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Authenticate: gh auth login")
    else
      printf '\n  %s gh not authenticated — launching gh auth login (device flow)...\n\n' "$MARK_WARN"
      if gh auth login --git-credential-helper; then
        _ghuser="$(gh api user --jq .login 2>/dev/null || echo "unknown")"
        row "$MARK_OK" "gh auth" "logged in as @$_ghuser"
        CHECKS_OK=$((CHECKS_OK + 1))
        GH_AUTHED=1
        ACTIONS_TAKEN+=("Authenticated gh (device flow)")
      else
        row "$MARK_FAIL" "gh auth" "login failed — run: gh auth login"
        CHECKS_FAIL=$((CHECKS_FAIL + 1))
        ACTIONS_NEEDED+=("Authenticate: gh auth login")
      fi
    fi
  fi
fi

# ---- gh scope: project (Projects v2 silently fails without it) --------------
GH_SCOPE_PROJECT=0
if [[ $GH_AUTHED -eq 1 ]] && has_cmd gh; then
  _token_scopes="$(gh auth status 2>&1 | grep -i 'token scopes\|scopes:' | head -1 || true)"
  if echo "$_token_scopes" | grep -qi 'project'; then
    row "$MARK_OK" "gh scope:project" "present"
    CHECKS_OK=$((CHECKS_OK + 1))
    GH_SCOPE_PROJECT=1
  else
    if [[ $DRY_RUN -eq 1 ]]; then
      row "$MARK_FAIL" "gh scope:project" "missing — gh auth refresh -s project"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Add scope: gh auth refresh -s project")
    else
      printf '\n  %s scope \"project\" missing — running gh auth refresh (will open browser)...\n\n' "$MARK_WARN"
      if gh auth refresh -s project; then
        row "$MARK_OK" "gh scope:project" "added"
        CHECKS_OK=$((CHECKS_OK + 1))
        GH_SCOPE_PROJECT=1
        ACTIONS_TAKEN+=("Added gh scope:project via auth refresh")
      else
        row "$MARK_FAIL" "gh scope:project" "refresh failed — gh auth refresh -s project"
        CHECKS_FAIL=$((CHECKS_FAIL + 1))
        ACTIONS_NEEDED+=("Add scope: gh auth refresh -s project")
      fi
    fi
  fi
elif [[ $GH_AUTHED -eq 0 ]]; then
  row "$MARK_SKIP" "gh scope:project" "gh not authed — re-run after login"
fi

# ---- git config user.name + user.email -------------------------------------
_git_name="$(git config --global user.name 2>/dev/null || true)"
if [[ -n "$_git_name" ]]; then
  row "$MARK_OK" "git user.name" "$_git_name"
  CHECKS_OK=$((CHECKS_OK + 1))
else
  row "$MARK_FAIL" "git user.name" "not set — git config --global user.name \"Your Name\""
  CHECKS_FAIL=$((CHECKS_FAIL + 1))
  ACTIONS_NEEDED+=("Set git identity: git config --global user.name \"Your Name\"")
fi

_git_email="$(git config --global user.email 2>/dev/null || true)"
if [[ -n "$_git_email" ]]; then
  row "$MARK_OK" "git user.email" "$_git_email"
  CHECKS_OK=$((CHECKS_OK + 1))
else
  row "$MARK_FAIL" "git user.email" "not set — git config --global user.email \"you@example.com\""
  CHECKS_FAIL=$((CHECKS_FAIL + 1))
  ACTIONS_NEEDED+=("Set git email: git config --global user.email \"you@example.com\"")
fi

# ---- base branch vs GitHub default -----------------------------------------
# `Closes #N` auto-close only fires when a PR merges into the repo's DEFAULT branch. If this
# project integrates on a non-default branch (github.baseBranch, e.g. develop) that mismatch
# silently leaves issues open on native/UI merges. cckit's own `pr-merge` closes them explicitly,
# but the misalignment still bites anyone who merges from the GitHub UI — so surface it.
if [[ $GH_AUTHED -eq 1 ]] && has_cmd gh && [[ -f "$_kitcfg" ]]; then
  _cfg_repo="$(jq -r '.github.repo // empty' "$_kitcfg" 2>/dev/null || true)"
  # Same fallback chain as load_kit_config (#117) so the warning judges the branch cckit actually
  # integrates on: baseBranch -> integrationBranch -> flow -> "main".
  _cfg_base="$(jq -r '.github.baseBranch // .github.integrationBranch // .github.flow // "main"' "$_kitcfg" 2>/dev/null || echo main)"
  if [[ -n "$_cfg_repo" ]]; then
    _gh_default="$(gh repo view "$_cfg_repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)"
    if [[ -z "$_gh_default" ]]; then
      row "$MARK_SKIP" "base branch" "couldn't read GitHub default for $_cfg_repo — skipped"
    elif [[ "$_cfg_base" == "$_gh_default" ]]; then
      row "$MARK_OK" "base branch" "$_cfg_base = GitHub default"
      CHECKS_OK=$((CHECKS_OK + 1))
    else
      row "$MARK_WARN" "base branch" "baseBranch '$_cfg_base' ≠ GitHub default '$_gh_default' — 'Closes #N' won't auto-close on GitHub-UI merges"
      CHECKS_WARN=$((CHECKS_WARN + 1))
      ACTIONS_NEEDED+=("Align base branch: 'gh repo edit $_cfg_repo --default-branch $_cfg_base' (or set github.baseBranch to '$_gh_default'). Note: 'cckit pr-merge' already closes linked issues explicitly.")
    fi
  fi
fi
printf '\n'

# ============================================================================
# SSH (optional guided flow)
# ============================================================================
printf '  %s%sSSH (optional — GitHub HTTPS auth already configured by gh)%s\n' "$C_BOLD" "" "$C_RESET"

_ssh_result=0
ssh -T git@github.com -o ConnectTimeout=5 -o BatchMode=yes 2>&1 | grep -q "successfully authenticated" && _ssh_result=1 || true

if [[ $_ssh_result -eq 1 ]]; then
  row "$MARK_OK" "SSH to github.com" "key already accepted"
  CHECKS_OK=$((CHECKS_OK + 1))
else
  row "$MARK_SKIP" "SSH to github.com" "no key — HTTPS is used by default (gh auth sets it up)"

  # Show guided SSH setup only if user explicitly wants SSH
  if [[ "${KIT_DOCTOR_SSH:-}" == "1" && $DRY_RUN -eq 0 ]]; then
    _ssh_key="$HOME/.ssh/id_ed25519_kit"
    if [[ ! -f "$_ssh_key" ]]; then
      printf '\n  Generating ed25519 SSH key at %s...\n' "$_ssh_key"
      ssh-keygen -t ed25519 -f "$_ssh_key" -C "claude-kit onboarding" -N "" 2>/dev/null
      ACTIONS_TAKEN+=("Generated SSH key $_ssh_key")
    fi
    if has_cmd pbcopy; then
      pbcopy < "${_ssh_key}.pub"
      printf '  Public key copied to clipboard.\n'
    else
      cat "${_ssh_key}.pub"
    fi
    printf '\n  Paste the public key at: https://github.com/settings/ssh/new\n'
    ACTIONS_NEEDED+=("Add SSH public key: https://github.com/settings/ssh/new")
  else
    printf '  %sTip: set KIT_DOCTOR_SSH=1 and re-run to generate an ed25519 key.%s\n' "$C_DIM" "$C_RESET"
  fi
fi
printf '\n'

# ============================================================================
# SURFACE PORTABILITY (connection test — terminal / Cowork / claude.ai, #376)
# ============================================================================
# A kit project should run on all three Claude surfaces with no hand edits. Terminal + Cowork read
# CLAUDE.md + .claude/ natively; claude.ai needs the kit-export-project transform. This test asks
# the same question kit-export-project --verify does: is the PORTABLE surface self-sufficient — does
# every file CLAUDE.md leans on carry tier-A (portable) semantics, not a tier-B CLI-only shim that
# would silently no-op off-terminal? Read-only; gated on a kit project (CLAUDE.md present).
_kit_target="${TARGET:-$PWD}"
_export_script="$_export_dir_doctor/kit-export-project.sh"
if [[ -f "$_kit_target/CLAUDE.md" && -f "$_export_script" ]]; then
  printf '  %s%sSurface portability (terminal / Cowork / claude.ai)%s\n' "$C_BOLD" "" "$C_RESET"
  if ( cd "$_kit_target" && bash "$_export_script" --verify ) >/dev/null 2>&1; then
    row "$MARK_OK" "portable surface" "tier-A self-sufficient — runs in terminal/Cowork/claude.ai unchanged"
    CHECKS_OK=$((CHECKS_OK + 1))
  else
    row "$MARK_WARN" "portable surface" "defect(s) — run: kit-export-project.sh --verify"
    CHECKS_WARN=$((CHECKS_WARN + 1))
    ACTIONS_NEEDED+=("Inspect portability: scripts/kit-export-project.sh --verify (then export for claude.ai with no args)")
  fi
  printf '\n'
fi

# ============================================================================
# INSTRUCTION FILES (resident context budget, #357)
# ============================================================================
# CLAUDE.md and every .claude/rules/*.md without a `paths:` frontmatter load into every session;
# Claude Code warns at startup once they pass 150k characters combined. Show the number and the
# three largest files here so it is seen before that warning is. Read-only, and the same
# measurement the gate uses (instruction-budget-lint.sh --summary). Absent when the project has no
# instruction files.
_budget_lint="$_export_dir_doctor/instruction-budget-lint.sh"
if [[ -f "$_budget_lint" ]]; then
  _budget_line="$(INSTRUCTION_BUDGET_ROOT="$_kit_target" bash "$_budget_lint" --summary 2>/dev/null || true)"
  if [[ -n "$_budget_line" ]]; then
    printf '  %s%sInstruction files (loaded into every session)%s\n' "$C_BOLD" "" "$C_RESET"
    _budget_resident="$(printf '%s' "$_budget_line" | awk '{print $3}')"
    _budget_limit="$(printf '%s' "$_budget_line" | awk '{print $5}')"
    if [[ "$_budget_resident" =~ ^[0-9]+$ && "$_budget_limit" =~ ^[0-9]+$ && "$_budget_resident" -gt "$_budget_limit" ]]; then
      row "$MARK_WARN" "resident budget" "$_budget_line"
      CHECKS_WARN=$((CHECKS_WARN + 1))
      ACTIONS_NEEDED+=("Trim resident instruction files: scripts/instruction-budget-lint.sh --report (scope a rule with paths:, or split it into a short rule + a knowledge doc)")
    else
      row "$MARK_OK" "resident budget" "$_budget_line"
      CHECKS_OK=$((CHECKS_OK + 1))
    fi
    printf '\n'
  fi
fi

# ============================================================================
# SUMMARY
# ============================================================================
printf '  %s%sSummary%s\n' "$C_BOLD" "" "$C_RESET"
printf '  %-4s %s checked ok\n' "" "$CHECKS_OK"
[[ $CHECKS_WARN  -gt 0 ]] && printf '  %-4s %s warnings\n' "" "$CHECKS_WARN"
[[ $CHECKS_FAIL  -gt 0 ]] && printf '  %-4s %s failed\n' "" "$CHECKS_FAIL"

if [[ ${#ACTIONS_TAKEN[@]} -gt 0 ]]; then
  printf '\n  %s%sInstalled / fixed:%s\n' "$C_BOLD" "" "$C_RESET"
  for _a in "${ACTIONS_TAKEN[@]}"; do
    printf '  %s  %s\n' "$MARK_OK" "$_a"
  done
fi

if [[ ${#ACTIONS_NEEDED[@]} -gt 0 ]]; then
  printf '\n  %s%sAction required:%s\n' "$C_BOLD" "" "$C_RESET"
  for _a in "${ACTIONS_NEEDED[@]}"; do
    printf '  %s  %s\n' "$MARK_FAIL" "$_a"
  done
fi
printf '\n'

# ---- onboarding / docs pointer ---------------------------------------------
# Show the local onboarding app ONLY when something actually answers on it —
# otherwise point at the public docs. (Previously this always printed
# http://localhost:3001/onboarding even when nothing served that port.)
_admin_url="${CCKIT_ADMIN_URL:-http://localhost:3001}"
if has_cmd curl && curl -fsS --max-time 1 "$_admin_url/onboarding" >/dev/null 2>&1; then
  printf '  %sOnboarding guide (web): %s/onboarding%s\n' "$C_DIM" "$_admin_url" "$C_RESET"
else
  printf '  %sDocs & quick start: %shttps://cckit.dev%s\n' "$C_DIM" "" "$C_RESET"
fi
printf '\n'

# Exit non-zero when critical checks failed
[[ $CHECKS_FAIL -gt 0 ]] && exit 1 || exit 0
