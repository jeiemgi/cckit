#!/usr/bin/env bash
# kit-doctor — onboarding preflight: deps + brew bootstrap + gh auth/scopes + SSH guided
#
# Usage:
#   scripts/kit-doctor.sh                 # detect + report; in a terminal, ASK before installing
#   scripts/kit-doctor.sh --fix           # install missing deps without asking (alias: --yes, -y)
#   scripts/kit-doctor.sh --dry-run       # report only — no installs, no auth changes
#   scripts/kit-doctor.sh --no-install    # check and auth only — skip package installs
#   scripts/kit-doctor.sh --dismiss-local # silence the "local layer down" session notice
#                                         # until the next x.y kit update
#
# Tiers:
#   Tier 0  Homebrew (macOS bootstrap — requires sudo password)
#   Tier 1  git, gh, jq, perl           — hard deps, auto-install via brew
#   Tier 2  node + pnpm, vercel, turbo  — project-specific, auto-install if applicable
#   Local   mlx-lm via uv tool install + mlx_lm.server auto-start (when .local.enabled)
#   Auth    gh auth status + scope:project, git config name/email
#   SSH     optional guided flow (ed25519, pbcopy, link to github settings)
set -euo pipefail

# Own directory — so we can find sibling scripts (kit-export-project.sh) regardless of cwd.
_export_dir_doctor="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ---- flags ------------------------------------------------------------------
DRY_RUN=0; NO_INSTALL=0; DISMISS_LOCAL=0; ASSUME_YES=0
for _a in "$@"; do
  case "$_a" in
    --dry-run)       DRY_RUN=1 ;;
    --no-install)    NO_INSTALL=1 ;;
    --fix|--yes|-y)  ASSUME_YES=1 ;;
    --dismiss-local) DISMISS_LOCAL=1 ;;
    -h|--help)
      sed -n '2,13p' "$0" | grep '^#' | sed 's/^# \?//'
      exit 0 ;;
  esac
done

# ---- --dismiss-local: record the dismiss and exit (no preflight run) ---------
# Writes .local.dismissed = current kitVersion to kit.config.json; the SessionStart
# notice stays silent until the kit's x.y core moves past it (issue #313).
if [[ $DISMISS_LOCAL -eq 1 ]]; then
  _kitcfg="${TARGET:-$PWD}/.claude/kit.config.json"
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
# it in a terminal, ASK first — install only if approved. Non-interactive callers (init.sh preflight,
# hooks) pass --fix/--yes or simply have no TTY, so automation keeps its current auto-install behavior
# and never blocks on a prompt. --dry-run / --no-install already skip installs entirely.
if [[ $DRY_RUN -eq 0 && $NO_INSTALL -eq 0 && $ASSUME_YES -eq 0 && -t 0 ]]; then
  printf '\n  %s%scckit doctor can install anything missing for you%s (via Homebrew, corepack, etc.).\n' "$C_BOLD" "" "$C_RESET"
  printf '  It will show each thing as it goes. Nothing is installed if you decline.\n\n'
  printf '  Install missing dependencies? [Y/n] '
  read -r _reply || _reply=""
  case "$_reply" in
    [nN]|[nN][oO])
      NO_INSTALL=1
      printf '\n  %s report-only — listing what is missing and how to install it (no changes made).\n' "$MARK_SKIP" ;;
    *) : ;;  # default (Enter / y) → proceed with installs
  esac
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
  if [[ $DRY_RUN -eq 1 || $NO_INSTALL -eq 1 ]]; then
    return 1
  fi
  if ! has_cmd brew; then return 1; fi
  brew install "$pkg" >/dev/null 2>&1 && has_cmd "$cmd"
}

# ============================================================================
# BANNER
# ============================================================================
printf '\n'
printf '  %s%s%s  kit-doctor\n' "$MARK_SEED" "$C_BOLD" " / claude-kit${C_RESET}"
printf '  %s\n' "${C_DIM}onboarding preflight${C_RESET}${DRY_RUN:+${C_WARN} [dry-run]${C_RESET}}${NO_INSTALL:+${C_DIM} [no-install]${C_RESET}}"
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
  if [[ $DRY_RUN -eq 1 || $NO_INSTALL -eq 1 ]]; then
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
    if [[ $DRY_RUN -eq 0 && $NO_INSTALL -eq 0 ]] && has_cmd brew; then
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
    if [[ $DRY_RUN -eq 0 && $NO_INSTALL -eq 0 ]]; then
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
  if [[ $DRY_RUN -eq 0 && $NO_INSTALL -eq 0 ]] && has_cmd pnpm; then
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
  elif [[ $DRY_RUN -eq 0 && $NO_INSTALL -eq 0 ]] && has_cmd npm; then
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
# LOCAL MODEL LAYER (opt-in — only checked when .local.enabled is true)
# ============================================================================
# Same gating principle as vercel: silence when the project didn't opt in.
# Install path (#313): `uv tool install mlx-lm` — isolated tool venv, PEP 668-safe
# (Homebrew python is externally-managed; plain pip/pip3 fails there). Fallback
# pipx; NEVER suggest plain pip. When mlx-lm is present but the server is down,
# the doctor starts it in background + health-checks the port. --dry-run stays
# 100% read-only: it reports what it would do, installs and starts nothing.
_kitcfg="${TARGET:-$PWD}/.claude/kit.config.json"
_local_on="false"
[[ -f "$_kitcfg" ]] && _local_on="$(jq -r '.local.enabled // false' "$_kitcfg" 2>/dev/null || echo false)"
if [[ "$_local_on" == "true" ]]; then
  printf '  %s%sLocal model layer (mlx_lm.server)%s\n' "$C_BOLD" "" "$C_RESET"
  _lport="$(jq -r '.local.port // 8080' "$_kitcfg" 2>/dev/null || echo 8080)"
  _lmodel="$(jq -r '.local.model // "mlx-community/Qwen3-8B-4bit"' "$_kitcfg" 2>/dev/null || echo "mlx-community/Qwen3-8B-4bit")"

  # Apple silicon — MLX requirement; gate install/start on it
  _mlx_capable=0
  if [[ $IS_MACOS -eq 1 && "$(uname -m 2>/dev/null)" == "arm64" ]]; then
    row "$MARK_OK" "apple silicon" "$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo arm64)"
    CHECKS_OK=$((CHECKS_OK + 1))
    _mlx_capable=1
  else
    row "$MARK_WARN" "apple silicon" "MLX needs an Apple silicon Mac — local layer will stay dormant here"
    CHECKS_WARN=$((CHECKS_WARN + 1))
  fi

  # mlx-lm binary — uv/pipx install to ~/.local/bin, which may not be on PATH yet
  _mlx_find() {
    if has_cmd mlx_lm.server; then command -v mlx_lm.server
    elif [[ -x "$HOME/.local/bin/mlx_lm.server" ]]; then echo "$HOME/.local/bin/mlx_lm.server"
    fi
    return 0  # never trip set -e via the $(...) assignment
  }
  _mlx_bin="$(_mlx_find)"

  if [[ -n "$_mlx_bin" ]]; then
    row "$MARK_OK" "mlx-lm" "installed ($_mlx_bin)"
    CHECKS_OK=$((CHECKS_OK + 1))
  elif [[ $_mlx_capable -eq 0 ]]; then
    row "$MARK_SKIP" "mlx-lm" "not Apple silicon — skipping install"
  elif [[ $DRY_RUN -eq 1 || $NO_INSTALL -eq 1 ]]; then
    row "$MARK_FAIL" "mlx-lm" "missing — uv tool install mlx-lm"
    CHECKS_FAIL=$((CHECKS_FAIL + 1))
    ACTIONS_NEEDED+=("Install the local model runtime: uv tool install mlx-lm")
  else
    # ensure an installer: uv preferred (brew-installable), pipx as fallback
    if ! has_cmd uv && ! has_cmd pipx; then
      brew_install uv uv && ACTIONS_TAKEN+=("Installed uv via brew") || true
    fi
    if has_cmd uv; then
      printf '  %s mlx-lm missing — installing via uv tool install (isolated venv)...\n' "$MARK_WARN"
      uv tool install mlx-lm >/dev/null 2>&1 || true
      _mlx_installer="uv tool install"
    elif has_cmd pipx; then
      printf '  %s mlx-lm missing — installing via pipx (isolated venv)...\n' "$MARK_WARN"
      pipx install mlx-lm >/dev/null 2>&1 || true
      _mlx_installer="pipx"
    fi
    _mlx_bin="$(_mlx_find)"
    if [[ -n "$_mlx_bin" ]]; then
      row "$MARK_OK" "mlx-lm" "installed via ${_mlx_installer:-uv} ($_mlx_bin)"
      CHECKS_OK=$((CHECKS_OK + 1))
      ACTIONS_TAKEN+=("Installed mlx-lm via ${_mlx_installer:-uv}")
    else
      row "$MARK_FAIL" "mlx-lm" "install failed — uv tool install mlx-lm"
      CHECKS_FAIL=$((CHECKS_FAIL + 1))
      ACTIONS_NEEDED+=("Install the local model runtime: uv tool install mlx-lm")
    fi
  fi

  # server alive on the configured port — auto-start when down + installed
  _lurl="http://127.0.0.1:${_lport}/v1/models"
  if curl -sf -m 1 "$_lurl" >/dev/null 2>&1; then
    row "$MARK_OK" "server" "alive @ :${_lport} (${_lmodel##*/}) — NL chores run at \$0"
    CHECKS_OK=$((CHECKS_OK + 1))
  elif [[ -z "$_mlx_bin" ]]; then
    row "$MARK_WARN" "server" "not running — install mlx-lm first, then re-run kit-doctor"
    CHECKS_WARN=$((CHECKS_WARN + 1))
    ACTIONS_NEEDED+=("Start the local model server: mlx_lm.server --model ${_lmodel} --port ${_lport}")
  elif [[ $DRY_RUN -eq 1 ]]; then
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

# ---- onboarding page -------------------------------------------------------
_admin_url="${CCKIT_ADMIN_URL:-http://localhost:3001}"
printf '  %sOnboarding guide (web): %s/onboarding%s\n' "$C_DIM" "$_admin_url" "$C_RESET"
printf '\n'

# Exit non-zero when critical checks failed
[[ $CHECKS_FAIL -gt 0 ]] && exit 1 || exit 0
