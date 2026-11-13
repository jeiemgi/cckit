#!/usr/bin/env bash
# shellcheck shell=bash
# review-page.sh — plans, decisions and grilling rounds open as a review page (#451).
#
# The page tool is an integration (integrations/lavish.json, `reviewPages.enabled`, ON by default).
# This file is the `cckit page` verb: it decides whether THIS session can show a page, opens one
# through the tool when it can, prints to the terminal when it cannot, and writes the reader's
# answer where the project keeps its record.
#
# A page needs a reader with a browser. rp_mode answers `page` or `terminal<TAB><reason>`, and the
# first rule below that holds decides:
#   1. CCKIT_PAGES=terminal|off|0|false|no    terminal. CCKIT_PAGES=page|on|1|true|yes skips 4-9.
#   2. the integration is off                 `reviewPages.enabled` is false in the project config
#   3. (forced by rule 1: go to 10)
#   4. CI is set (not `false`/`0`)            a CI job has no reader
#   5. CCKIT_HEADLESS is set (not `0`)        an unattended run: `cckit autopilot run` and the tmux
#                                             wave worker export it
#   6. a headless Claude Code session         CLAUDECODE is set and CLAUDE_CODE_SESSION_ATTENDED is
#                                             `0` or CLAUDE_CODE_ENTRYPOINT starts with `sdk`
#                                             (`claude -p` reports `sdk-cli` and `0`)
#   7. SSH_CONNECTION or SSH_TTY is set       the browser would open on the remote host
#   8. not macOS, and neither DISPLAY nor WAYLAND_DISPLAY is set
#   9. no agent session and no terminal       CLAUDECODE unset and none of fd 0/1/2 is a TTY. An
#                                             agent's shell tool has no TTY, so inside an attended
#                                             Claude Code session the TTY is not required
#  10. no runner                              neither `lavish-axi` nor `npx` is on PATH
# Terminal mode is never an error: every verb here exits 0 in it.
#
# Source it:  source scripts/lib/review-page.sh
#   rp_descriptor                    the page tool's descriptor path; rc 1 when there is none
#   rp_enabled                       rc 0 unless the project config turns review pages off
#   rp_runner                        `lavish-axi`, or `npx -y lavish-axi`; rc 1 when neither exists
#   rp_mode                          `page`, or `terminal<TAB><reason>`; always rc 0
#   rp_open <html> [<fallback-md>] [tool args…]
#                                    open the page; in terminal mode, or when the tool exits
#                                    non-zero, print the fallback file (or a one-line notice). rc 0
#   rp_pass <poll|reply|end> <html> [args…]   hand the subcommand to the tool; no-op in terminal mode
#   rp_answer_dest <issue>           `issue` or `file`: where an answer is written
#   rp_answer --kind <plan|decision|grill> --title <t> [--issue <n>] [--body-file <f|->]
#                                    write the answer: a comment on the issue when the project uses
#                                    GitHub and an issue is named, else a file under
#                                    `reviewPages.answersDir` (default docs/answers) in the work tree
#   rp_cli <mode|open|poll|reply|end|answer> …   the `cckit page` verb
# Requires: jq. bash 3.2 + zsh compatible.
# errors: mixed — rp_mode / rp_open / rp_pass in terminal mode always return 0 (falling back is the
# contract); rp_pass in page mode returns the tool's own status; rp_answer is strict: rc 2 on a
# usage error, rc 1 when the comment or the file could not be written.

_rp_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
. "$_rp_dir/kit-cli.sh"       # kit_is_main, kit_say, kit_warn
# shellcheck source=/dev/null
. "$_rp_dir/integrations.sh"  # integration_file, integration_enabled; sources config-path.sh

_rp_tool_id="lavish"

_rp_truthy() { case "${1:-}" in ''|0|false|False|FALSE|no|off) return 1 ;; *) return 0 ;; esac; }

rp_descriptor() { integration_file "$_rp_tool_id"; }

_rp_cfg() { kit_config_path 2>/dev/null || true; }

# rp_enabled — on unless the config says otherwise. No project config at all is ON: the default
# holds in every project, and a directory with no config has not turned anything off.
rp_enabled() {
  local f cfg
  f="$(rp_descriptor)" || return 1
  cfg="$(_rp_cfg)"
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0
  integration_enabled "$f" "$cfg"
}

rp_runner() {
  if command -v lavish-axi >/dev/null 2>&1; then printf 'lavish-axi\n'; return 0; fi
  if command -v npx >/dev/null 2>&1; then printf 'npx -y lavish-axi\n'; return 0; fi
  return 1
}

# _rp_run <args…> — run the page tool with these arguments: the binary when it is on PATH, else
# through npx. Spelled as two branches because a command held in a variable does not word-split
# under zsh.
_rp_run() {
  if command -v lavish-axi >/dev/null 2>&1; then lavish-axi "$@"; else npx -y lavish-axi "$@"; fi
}

rp_mode() {
  local forced=0 cfg
  case "${CCKIT_PAGES:-}" in
    '') ;;
    terminal|off|0|false|no) printf 'terminal\tCCKIT_PAGES=%s\n' "$CCKIT_PAGES"; return 0 ;;
    page|on|1|true|yes) forced=1 ;;
    *) kit_warn "page: CCKIT_PAGES='$CCKIT_PAGES' is neither 'page' nor 'terminal' — ignored" ;;
  esac
  if ! rp_enabled; then
    cfg="$(_rp_cfg)"
    printf 'terminal\treview pages are off (reviewPages.enabled is false in %s)\n' "${cfg:-the project config}"
    return 0
  fi
  if [ "$forced" -eq 0 ]; then
    if _rp_truthy "${CI:-}"; then printf 'terminal\tCI is set: a CI job has no reader\n'; return 0; fi
    if _rp_truthy "${CCKIT_HEADLESS:-}"; then printf 'terminal\tCCKIT_HEADLESS is set: an unattended run\n'; return 0; fi
    if [ -n "${CLAUDECODE:-}" ]; then
      if [ "${CLAUDE_CODE_SESSION_ATTENDED:-}" = "0" ]; then
        printf 'terminal\ta headless Claude Code session (CLAUDE_CODE_SESSION_ATTENDED=0)\n'; return 0
      fi
      case "${CLAUDE_CODE_ENTRYPOINT:-}" in
        sdk*) printf 'terminal\ta headless Claude Code session (CLAUDE_CODE_ENTRYPOINT=%s)\n' "$CLAUDE_CODE_ENTRYPOINT"; return 0 ;;
      esac
    fi
    if [ -n "${SSH_CONNECTION:-}" ] || [ -n "${SSH_TTY:-}" ]; then
      printf 'terminal\tan SSH session: the browser would open on the remote host\n'; return 0
    fi
    if [ "$(uname -s 2>/dev/null)" != "Darwin" ] && [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
      printf 'terminal\tno display: neither DISPLAY nor WAYLAND_DISPLAY is set\n'; return 0
    fi
    if [ -z "${CLAUDECODE:-}" ] && ! [ -t 0 ] && ! [ -t 1 ] && ! [ -t 2 ]; then
      printf 'terminal\tno terminal and no attended agent session (set CCKIT_PAGES=page to open one anyway)\n'; return 0
    fi
  fi
  if ! rp_runner >/dev/null; then
    printf 'terminal\tneither lavish-axi nor npx is on PATH\n'; return 0
  fi
  printf 'page\n'
}

_rp_json() { [ "${CCKIT_OUTPUT:-human}" = "json" ]; }

# _rp_ignore_dir <html> — keep the page directory out of `git status`. When the page sits in a
# `.lavish/` directory of a git work tree and git does not already ignore it, one `.lavish/` line
# goes into the repository's local exclude file (info/exclude: never tracked, never pushed).
_rp_ignore_dir() {
  local d ex
  d="$(CDPATH='' cd -- "$(dirname -- "$1")" 2>/dev/null && pwd)" || return 0
  [ "$(basename "$d")" = ".lavish" ] || return 0
  git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if git -C "$d" check-ignore -q "$d" 2>/dev/null; then return 0; fi
  ex="$(git -C "$d" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null)" || return 0
  [ -n "$ex" ] || return 0
  mkdir -p "$(dirname "$ex")" 2>/dev/null || return 0
  printf '.lavish/\n' >> "$ex" 2>/dev/null || true
  return 0
}

# _rp_terminal <reason> <html> [<fallback-md>] — the terminal side of rp_open.
_rp_terminal() {
  local reason="$1" html="$2" fb="${3:-}"
  kit_say "page: terminal output — $reason"
  if _rp_json; then
    jq -cn --arg r "$reason" --arg f "$html" --arg fb "$fb" \
      '{mode: "terminal", reason: $r, file: $f} + (if $fb == "" then {} else {fallback: $fb} end)'
    return 0
  fi
  if [ -n "$fb" ] && [ -f "$fb" ]; then cat "$fb"; return 0; fi
  printf 'terminal: no page was opened (%s). Print the plan, the options or the questions in the terminal.\n' "$reason"
}

rp_open() {
  local html="${1:-}" fb="${2:-}" mode reason runner rc
  [ $# -ge 2 ] && shift 2 || shift $#
  [ -n "$html" ] || { kit_warn "page open: name the HTML file — cckit page open <html-file> [--fallback <md-file>]"; return 2; }
  [ -f "$html" ] || { kit_warn "page open: no file at '$html'"; return 2; }
  if [ -n "$fb" ] && [ ! -f "$fb" ]; then kit_warn "page open: no fallback file at '$fb'"; return 2; fi
  mode="$(rp_mode)"
  if [ "$mode" != "page" ]; then
    reason="${mode#*	}"
    _rp_terminal "$reason" "$html" "$fb"
    return 0
  fi
  runner="$(rp_runner)"
  _rp_ignore_dir "$html"
  # Under --llm stdout is the one JSON object, so the tool's own output goes to stderr.
  if _rp_json; then _rp_run "$html" "$@" >&2; rc=$?
  else _rp_run "$html" "$@"; rc=$?; fi
  if [ "$rc" -ne 0 ]; then
    _rp_terminal "$runner exited $rc" "$html" "$fb"
    return 0
  fi
  if _rp_json; then jq -cn --arg f "$html" '{mode: "page", file: $f}'; fi
  return 0
}

rp_pass() {
  local sub="${1:-}" html="${2:-}" mode
  [ -n "$html" ] || { kit_warn "page $sub: name the HTML file — cckit page $sub <html-file>"; return 2; }
  shift 2
  mode="$(rp_mode)"
  if [ "$mode" != "page" ]; then
    kit_say "page $sub: nothing to do in terminal mode — ${mode#*	}"
    return 0
  fi
  _rp_run "$sub" "$html" "$@"
}

# ── the answer ─────────────────────────────────────────────────────────────────────────────────
_rp_cfg_get() {  # <jq-path> -> the config value, or empty
  local cfg; cfg="$(_rp_cfg)"
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0
  jq -r "$1 // \"\"" "$cfg" 2>/dev/null || true
}

# rp_answer_dest <issue> -> `issue` or `file`. `reviewPages.answers` decides when it is set
# (`issue` | `file`); otherwise an answer goes to the issue when the project names a GitHub repo
# (`github.repo`) and an issue number was given, and to a file in every other case.
rp_answer_dest() {
  local issue="${1:-}" want repo
  want="$(_rp_cfg_get '.reviewPages.answers')"
  case "$want" in
    issue|file) printf '%s\n' "$want"; return 0 ;;
    '') ;;
    *) kit_warn "page answer: reviewPages.answers='$want' is neither 'issue' nor 'file' — ignored" ;;
  esac
  repo="$(_rp_cfg_get '.github.repo')"
  if [ -n "$repo" ] && [ -n "$issue" ]; then printf 'issue\n'; else printf 'file\n'; fi
}

_rp_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' | cut -c1-50 | sed 's/-$//'
}

_rp_kind_label() { case "$1" in plan) printf 'Plan' ;; decision) printf 'Decision' ;; grill) printf 'Grill' ;; esac; }

rp_answer() {
  local kind="" title="" issue="" bfile="" dest tmp body id marker label repo out dir root rel slug f n today
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind)      kind="${2:-}";  [ $# -gt 1 ] && shift ;;
      --title)     title="${2:-}"; [ $# -gt 1 ] && shift ;;
      --issue)     issue="${2:-}"; [ $# -gt 1 ] && shift ;;
      --body-file) bfile="${2:-}"; [ $# -gt 1 ] && shift ;;
      *) kit_warn "page answer: unknown argument '$1'"; return 2 ;;
    esac
    shift
  done
  case "$kind" in plan|decision|grill) ;; *) kit_warn "page answer: --kind is one of plan, decision, grill"; return 2 ;; esac
  [ -n "$title" ] || { kit_warn "page answer: --title is required"; return 2; }
  issue="${issue#\#}"
  if [ -n "$issue" ]; then
    case "$issue" in *[!0-9]*) kit_warn "page answer: --issue takes an issue number, got '$issue'"; return 2 ;; esac
  fi
  tmp="$(mktemp)" || return 1
  if [ -z "$bfile" ] || [ "$bfile" = "-" ]; then cat > "$tmp"
  elif [ -f "$bfile" ]; then cat "$bfile" > "$tmp"
  else rm -f "$tmp"; kit_warn "page answer: no body file at '$bfile'"; return 2; fi
  if ! grep -q '[^[:space:]]' "$tmp"; then rm -f "$tmp"; kit_warn "page answer: the answer is empty — pass --body-file <file>, or the text on stdin"; return 2; fi

  dest="$(rp_answer_dest "$issue")"
  if [ "$dest" = "issue" ] && [ -z "$issue" ]; then
    rm -f "$tmp"; kit_warn "page answer: reviewPages.answers is 'issue' — name one with --issue <n>"; return 2
  fi
  # The id is a checksum of what is being recorded, so recording the same answer twice is a no-op.
  id="$( { printf '%s\n%s\n' "$kind" "$title"; cat "$tmp"; } | cksum | awk '{print $1}')"
  marker="<!-- cckit:page-answer kind=$kind id=$id -->"
  label="$(_rp_kind_label "$kind")"
  today="$(date +%Y-%m-%d)"
  body="$(mktemp)" || { rm -f "$tmp"; return 1; }

  if [ "$dest" = "issue" ]; then
    { printf '%s\n### %s answer: %s\n\n' "$marker" "$label" "$title"; cat "$tmp"
      printf '\n\n_Recorded from a review page with `cckit page answer`, %s._\n' "$today"; } > "$body"
    repo="$(_rp_cfg_get '.github.repo')"
    if [ -n "$repo" ]; then out="$(gh issue view "$issue" --repo "$repo" --json comments -q '.comments[].body' 2>/dev/null || true)"
    else out="$(gh issue view "$issue" --json comments -q '.comments[].body' 2>/dev/null || true)"; fi
    case "$out" in *"$marker"*)
      rm -f "$tmp" "$body"
      kit_say "page answer: already recorded on #$issue — nothing written"
      if _rp_json; then jq -cn --arg i "$issue" '{ok: true, where: "issue", issue: ($i | tonumber), written: false}'
      else printf 'issue #%s (already recorded)\n' "$issue"; fi
      return 0 ;;
    esac
    if [ -n "$repo" ]; then out="$(gh issue comment "$issue" --repo "$repo" --body-file "$body" 2>&1)"; n=$?
    else out="$(gh issue comment "$issue" --body-file "$body" 2>&1)"; n=$?; fi
    rm -f "$tmp" "$body"
    if [ "$n" -ne 0 ]; then
      kit_warn "page answer: could not comment on #$issue — $out"
      return 1
    fi
    if _rp_json; then jq -cn --arg i "$issue" --arg u "$out" '{ok: true, where: "issue", issue: ($i | tonumber), url: $u, written: true}'
    else printf 'issue #%s %s\n' "$issue" "$out"; fi
    return 0
  fi

  dir="$(_rp_cfg_get '.reviewPages.answersDir')"; [ -n "$dir" ] || dir="docs/answers"
  case "/$dir/" in
    //*|*/../*) rm -f "$tmp" "$body"; kit_warn "page answer: reviewPages.answersDir must be a path inside the repo, got '$dir'"; return 2 ;;
  esac
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || root="$PWD"
  slug="$(_rp_slug "$title")"; [ -n "$slug" ] || slug="answer"
  rel="$dir/$today-$kind-$slug"
  # The marker is looked up in every file of the directory, not only today's: the file name starts
  # with the date, so the same answer recorded on a later day would otherwise be written twice.
  f=""
  [ -d "$root/$dir" ] && f="$(grep -lF -- "$marker" "$root/$dir"/*.md 2>/dev/null | sed -n 1p)"
  if [ -n "$f" ]; then
    rm -f "$tmp" "$body"
    kit_say "page answer: already recorded in $f — nothing written"
    if _rp_json; then jq -cn --arg f "$f" '{ok: true, where: "file", file: $f, written: false}'
    else printf 'file %s (already recorded)\n' "$f"; fi
    return 0
  fi
  f="$root/$rel.md"; n=1
  while [ -e "$f" ]; do n=$((n + 1)); f="$root/$rel-$n.md"; done
  { printf '# %s answer: %s\n\n%s\n\n' "$label" "$title" "$marker"
    printf -- '- Recorded: %s\n- Kind: %s\n' "$today" "$kind"
    [ -n "$issue" ] && printf -- '- Issue: #%s\n' "$issue"
    printf '\n'; cat "$tmp"; printf '\n'; } > "$body"
  if ! mkdir -p "$(dirname "$f")" 2>/dev/null || ! cp "$body" "$f" 2>/dev/null; then
    rm -f "$tmp" "$body"; kit_warn "page answer: cannot write $f"; return 1
  fi
  rm -f "$tmp" "$body"
  kit_say "page answer: written to $f — commit it with the change it belongs to"
  if _rp_json; then jq -cn --arg f "$f" '{ok: true, where: "file", file: $f, written: true}'
  else printf 'file %s\n' "$f"; fi
  return 0
}

_rp_usage() {
  cat >&2 <<'EOF'
cckit page mode                          print `page`, or `terminal` and why this session has no page
cckit page open <html-file> [--fallback <md-file>] [-- <tool flags…>]
                                         open the page in the browser; where there is none, print the
                                         fallback file (or a one-line notice) and exit 0. Flags after
                                         `--` go to the page tool (`--reopen`, `--no-open`)
cckit page poll  <html-file> [args…]     wait for the reader's feedback (the page tool's `poll`)
cckit page reply <html-file> [args…]     show a reply on the page (the page tool's `reply`)
cckit page end   <html-file>             end the page session
cckit page answer --kind <plan|decision|grill> --title "<title>" [--issue <n>] [--body-file <file>]
                                         record the answer (body from the file, or stdin): a comment
                                         on the issue when the project uses GitHub and --issue is
                                         given, else a file under reviewPages.answersDir (docs/answers)

On by default. Off: `cckit add lavish --set enable=no` (reviewPages.enabled: false), or
CCKIT_PAGES=terminal for one command. A session with no browser (CI, an unattended run, SSH, no
display) prints to the terminal and exits 0.
EOF
}

rp_cli() {
  local sub="${1:-}" html="" fb="" mode
  [ $# -gt 0 ] && shift
  case "$sub" in
    mode)
      mode="$(rp_mode)"
      if _rp_json; then
        case "$mode" in
          page) jq -cn '{mode: "page"}' ;;
          *) jq -cn --arg r "${mode#*	}" '{mode: "terminal", reason: $r}' ;;
        esac
      else
        case "$mode" in page) printf 'page\n' ;; *) printf 'terminal: %s\n' "${mode#*	}" ;; esac
      fi ;;
    open)
      while [ $# -gt 0 ]; do
        case "$1" in
          --fallback) fb="${2:-}"; [ $# -gt 1 ] && shift ;;
          --) shift; break ;;
          -*) kit_warn "page open: unknown flag '$1'"; return 2 ;;
          *) if [ -z "$html" ]; then html="$1"; else kit_warn "page open: one HTML file at a time"; return 2; fi ;;
        esac
        shift
      done
      rp_open "$html" "$fb" "$@" ;;
    poll|reply|end) rp_pass "$sub" "$@" ;;
    answer) rp_answer "$@" ;;
    ''|-h|--help|help) _rp_usage; [ -n "$sub" ] || return 2 ;;
    *) kit_warn "page: unknown subcommand '$sub'"; _rp_usage; return 2 ;;
  esac
}

if kit_is_main; then rp_cli "$@"; fi
