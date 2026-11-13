#!/usr/bin/env bash
# shellcheck shell=bash
# init-guide.sh — the guided half of `cckit init` (#456): what kind of folder this is, the
# plain-language questions, and the recipe + database registries a new project starts from.
#
# Three things live here, and none of them writes to GitHub (that is init-github.sh):
#
#   1. DETECTION — init_detect_class <dir> names the folder before anything is written:
#        home             the home directory or another place a project never lives
#                         ($HOME, its parent, /, ~/Desktop, ~/Documents, ~/Downloads)
#        missing | empty  no folder yet, or nothing in it
#        files            files, but no project marker and no git repository
#        project-nogit    a project marker (package.json, go.mod, a kit config, …), no git
#        git-noremote     a git repository with no `origin` remote
#        project-remote   a git repository with an `origin` remote
#   2. THE ADVISOR — init_ask / init_ask_text put ONE question at a time, every choice with a
#      description and exactly one marked recommended. The answer comes from, in order: the answers
#      file (`--answers FILE`, a JSON object {"<key>":"<value>"}, the `cckit add --answers` format),
#      the terminal, or — with an answers file and no entry for the key — the recommended option.
#      With neither a terminal nor an answers file the advisor is off and init runs from flags only.
#   3. RECIPES AND DATABASES AS DATA — one JSON descriptor per recipe in recipes/ and per database
#      option in databases/ at the kit root. Adding one is adding a file: nothing here names an id.
#
#   init_detect_class <dir>            one of the class names above
#   init_abs_path <path>               absolute path of a folder that may not exist yet
#   init_slugify <text>                lowercase-dashed slug
#   init_advisor_on                    rc 0 when a question can be answered (answers file or TTY)
#   init_ask <key> <question> <why> <option>…   option = "value|label|description|R" (R = recommended)
#   init_ask_text <key> <question> <default>
#   recipes_dir | recipes_list | recipe_file <id> | recipe_validate <file>
#   databases_dir | databases_list | database_file <id> | database_validate <file>
#   database_offered <file>            rc 0 when the option ships its guide page AND its setup test
#   recipe_run <file> <dir>            run the recipe's commands in <dir>
#   database_apply <file> <stack> <dir>  packages, client code, env file, gitignore
#   database_guide <file> <dir>        open the guide page, or print the same steps
# Requires: jq. bash 3.2 compatible.
# errors: mixed — detection and the registries are pure; recipe_run / database_apply return rc 1
# on a failed command and report every step they took

_ig_self_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
_ig_kit_root="$(CDPATH='' cd -- "$_ig_self_dir/../.." && pwd)"

# ── small helpers ───────────────────────────────────────────────────────────────────────────────

init_slugify() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed -E 's/^-+//; s/-+$//'; }

# init_abs_path <path> -> the absolute path, resolving the deepest ancestor that exists. A folder
# that is not there yet still gets a real path, so a dry run can name it without creating it.
init_abs_path() {
  local p="$1" tail="" base
  case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#\~/}" ;; esac
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ ! -d "$p" ] && [ "$p" != "/" ]; do
    base="$(basename "$p")"
    case "$base" in
      .)  ;;
      *)  tail="/$base$tail" ;;
    esac
    p="$(dirname "$p")"
  done
  # Logical, not physical: `cd && pwd` is what --upgrade resolves, and a hook path written by a
  # fresh init must be the same string an upgrade computes (on macOS /var is a link to /private/var).
  p="$(CDPATH='' cd -- "$p" 2>/dev/null && pwd)" || return 1
  [ "$p" = "/" ] && p=""
  printf '%s%s\n' "$p" "${tail:-}" | sed 's#^$#/#'
}

# _ig_is_home <abs dir> -> rc 0 for a location a project is never scaffolded into.
_ig_is_home() {
  local d="$1" h=""
  [ "$d" = "/" ] && return 0
  [ -n "${HOME:-}" ] && h="$(CDPATH='' cd -- "$HOME" 2>/dev/null && pwd -P)"
  [ -n "$h" ] || return 1
  case "$d" in
    "$h"|"$(dirname "$h")"|"$h/Desktop"|"$h/Documents"|"$h/Downloads") return 0 ;;
  esac
  return 1
}

# The files that say "this is already a project". A kit config counts: a re-run lands here.
_IG_MARKERS="package.json pyproject.toml requirements.txt setup.py Cargo.toml go.mod Gemfile composer.json pom.xml build.gradle build.gradle.kts Makefile deno.json pubspec.yaml mix.exs CMakeLists.txt cckit.config.json .claude/kit.config.json"

init_detect_class() {
  local d="$1" m
  [ -e "$d" ] || { echo missing; return 0; }
  d="$(CDPATH='' cd -- "$d" 2>/dev/null && pwd -P)" || { echo missing; return 0; }
  if _ig_is_home "$d"; then echo home; return 0; fi
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [ -n "$(git -C "$d" remote get-url origin 2>/dev/null || true)" ]; then echo project-remote; else echo git-noremote; fi
    return 0
  fi
  # Nothing but macOS folder metadata is an empty folder.
  if [ -z "$(find "$d" -mindepth 1 -maxdepth 1 ! -name .DS_Store 2>/dev/null | sed -n 1p)" ]; then echo empty; return 0; fi
  for m in $_IG_MARKERS; do
    [ -e "$d/$m" ] && { echo project-nogit; return 0; }
  done
  echo files
}

# ── the advisor ─────────────────────────────────────────────────────────────────────────────────
# INIT_ANSWERS  path of the answers file ("" = none)
# KIT_INIT_TTY  1 / 0 forces the terminal check (a test has no TTY; a wrapper may know better)

_ig_tty() {
  case "${KIT_INIT_TTY:-}" in 1) return 0 ;; 0) return 1 ;; esac
  [ -t 0 ] && [ -t 1 ]
}

init_advisor_on() { [ -n "${INIT_ANSWERS:-}" ] || _ig_tty; }

# _ig_answer <key> -> the answers-file value for key; rc 1 when there is none.
_ig_answer() {
  [ -n "${INIT_ANSWERS:-}" ] && [ -f "$INIT_ANSWERS" ] || return 1
  jq -e -r --arg k "$1" 'if (has($k) and (.[$k] != null)) then (.[$k] | tostring) else empty end' "$INIT_ANSWERS" 2>/dev/null
}

# init_ask <key> <question> <why> <option>… -> the chosen value on stdout; the conversation goes to
# stderr. Each option is "value|label|description" with a 4th field "R" on the recommended one.
# rc 2 when an answers-file value is not one of the options.
init_ask() {
  local key="$1" q="$2" why="$3"; shift 3
  local rec="" n=0 o v l d r ans="" i pick
  for o in "$@"; do
    IFS='|' read -r v l d r <<EOF
$o
EOF
    if [ -z "$rec" ] && [ "${r:-}" = "R" ]; then rec="$v"; fi
  done
  [ -n "$rec" ] || rec="${1%%|*}"
  if ans="$(_ig_answer "$key")"; then
    for o in "$@"; do
      if [ "${o%%|*}" = "$ans" ]; then
        printf '  ? %s -> %s (answers file)\n' "$q" "$ans" >&2
        printf '%s\n' "$ans"; return 0
      fi
    done
    printf 'x "%s" is not an answer to "%s" (%s). Choose one of:' "$ans" "$key" "$q" >&2
    for o in "$@"; do printf ' %s' "${o%%|*}" >&2; done
    printf '\n' >&2
    return 2
  fi
  if ! _ig_tty; then
    printf '  ? %s -> %s (recommended; "%s" is not in the answers file)\n' "$q" "$rec" "$key" >&2
    printf '%s\n' "$rec"; return 0
  fi
  {
    printf '\n%s\n' "$q"
    [ -n "$why" ] && printf '  %s\n' "$why"
    for o in "$@"; do
      n=$((n + 1))
      IFS='|' read -r v l d r <<EOF
$o
EOF
      printf '  %d) %s%s\n' "$n" "$l" "$([ "$v" = "$rec" ] && printf ' (Recommended)')"
      [ -n "$d" ] && printf '       %s\n' "$d"
    done
    printf 'Type a number and press Enter (Enter alone takes the recommended one): '
  } >&2
  while :; do
    IFS= read -r pick || pick=""
    [ -z "$pick" ] && { printf '%s\n' "$rec"; return 0; }
    i=0
    for o in "$@"; do
      i=$((i + 1))
      if [ "$pick" = "$i" ] || [ "$pick" = "${o%%|*}" ]; then printf '%s\n' "${o%%|*}"; return 0; fi
    done
    printf 'That is not one of the choices. Type a number from 1 to %d: ' "$n" >&2
  done
}

# init_ask_text <key> <question> <default> -> free text; an empty answer takes the default.
init_ask_text() {
  local key="$1" q="$2" def="$3" ans=""
  if ans="$(_ig_answer "$key")" && [ -n "$ans" ]; then
    printf '  ? %s -> %s (answers file)\n' "$q" "$ans" >&2
    printf '%s\n' "$ans"; return 0
  fi
  if ! _ig_tty; then
    printf '  ? %s -> %s (default; "%s" is not in the answers file)\n' "$q" "$def" "$key" >&2
    printf '%s\n' "$def"; return 0
  fi
  printf '\n%s\n  Press Enter for: %s\n> ' "$q" "$def" >&2
  IFS= read -r ans || ans=""
  printf '%s\n' "${ans:-$def}"
}

# ── registries: recipes/ and databases/ ─────────────────────────────────────────────────────────

recipes_dir()   { printf '%s\n' "${KIT_RECIPES_DIR:-$_ig_kit_root/recipes}"; }
databases_dir() { printf '%s\n' "${KIT_DATABASES_DIR:-$_ig_kit_root/databases}"; }

_ig_list() {  # <dir> -> descriptor ids, sorted (a *.schema.json file is not a descriptor)
  [ -d "$1" ] || return 0
  find "$1" -maxdepth 1 -type f -name '*.json' ! -name '*.schema.json' 2>/dev/null \
    | sed -e 's#.*/##' -e 's#\.json$##' | sort
}
recipes_list()   { _ig_list "$(recipes_dir)"; }
databases_list() { _ig_list "$(databases_dir)"; }

_ig_file() {  # <dir> <id>
  case "$2" in ""|*/*|.*) return 1 ;; esac
  [ -f "$1/$2.json" ] || return 1
  printf '%s\n' "$1/$2.json"
}
recipe_file()   { _ig_file "$(recipes_dir)" "$1"; }
database_file() { _ig_file "$(databases_dir)" "$1"; }

# _ig_validate <file> <jq predicate…> — each predicate is "field problem|jq expression that must be true".
_ig_validate() {
  local f="$1" id rc=0 chk expr msg; shift
  id="$(basename "$f" .json)"
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { echo "$id: not a JSON object" >&2; return 1; }
  for chk in "$@"; do
    msg="${chk%%|*}"; expr="${chk#*|}"
    jq -e --arg id "$id" "$expr" "$f" >/dev/null 2>&1 || { echo "$id: $msg" >&2; rc=1; }
  done
  return $rc
}

recipe_validate() {
  _ig_validate "$1" \
    'id: must equal the file name|.id == $id' \
    'label: required text|(.label | type) == "string" and (.label | length) > 0' \
    'summary: required text|(.summary | type) == "string" and (.summary | length) > 0' \
    'profile: required text|(.profile | type) == "string" and (.profile | length) > 0' \
    'stack: required text|(.stack | type) == "string" and (.stack | length) > 0' \
    'recommended: must be true or false|(.recommended | type) == "boolean"' \
    'steps: one or more {label, run}|(.steps | type) == "array" and (.steps | length) > 0 and all(.steps[]; (.label | type) == "string" and (.run | type) == "string" and (.run | length) > 0)' \
    'requires: a list of {command, why}|((.requires // []) | type) == "array" and all((.requires // [])[]; (.command | type) == "string")' \
    'lastVerified: a YYYY-MM-DD date|(.lastVerified // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")'
}

database_validate() {
  _ig_validate "$1" \
    'id: must equal the file name|.id == $id' \
    'label: required text|(.label | type) == "string" and (.label | length) > 0' \
    'summary: required text|(.summary | type) == "string" and (.summary | length) > 0' \
    'fits: required text (when this option fits)|(.fits | type) == "string" and (.fits | length) > 0' \
    'recommended: must be true or false|(.recommended | type) == "boolean"' \
    'envFile: required text|(.envFile | type) == "string" and (.envFile | length) > 0' \
    'env: one or more {name, placeholder, what, where}|(.env | type) == "array" and (.env | length) > 0 and all(.env[]; (.name | test("^[A-Z][A-Z0-9_]*$")) and (.placeholder | type) == "string" and (.what | type) == "string" and (.where | type) == "string")' \
    'guide: required path|(.guide | type) == "string" and (.guide | length) > 0' \
    'test: required path|(.test | type) == "string" and (.test | length) > 0' \
    'steps: one or more lines of text|(.steps | type) == "array" and (.steps | length) > 0 and all(.steps[]; type == "string")' \
    'stacks: one or more {install, packages, files}|(.stacks | type) == "object" and (.stacks | length) > 0 and all(.stacks[]; (.install | type) == "string" and (.packages | type) == "array" and (.files | type) == "array" and all(.files[]; (.from | type) == "string" and (.to | type) == "string"))' \
    'lastVerified: a YYYY-MM-DD date|(.lastVerified // "") | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")'
}

# database_path <file> <relative> -> a descriptor-relative path made absolute. Paths in a database
# descriptor are relative to the directory the descriptor is in.
database_path() { printf '%s/%s\n' "$(CDPATH='' cd -- "$(dirname "$1")" && pwd)" "$2"; }

# database_offered <file> -> rc 0 when the option is valid and ships BOTH its guide page and its
# setup test. An option without them is never shown.
database_offered() {
  local f="$1" g t
  database_validate "$f" 2>/dev/null || return 1
  g="$(database_path "$f" "$(jq -r '.guide' "$f")")"; t="$(database_path "$f" "$(jq -r '.test' "$f")")"
  [ -f "$g" ] && [ -f "$t" ]
}

# database_stack_for <file> <dir> [stack] -> the stack block name to use: the given one when the
# descriptor has it, else the first stack whose detect.packageDependency is in <dir>/package.json.
database_stack_for() {
  local f="$1" d="$2" want="${3:-}" s dep
  if [ -n "$want" ]; then
    jq -e --arg s "$want" '.stacks | has($s)' "$f" >/dev/null 2>&1 && { printf '%s\n' "$want"; return 0; }
    return 1
  fi
  [ -f "$d/package.json" ] || return 1
  for s in $(jq -r '.stacks | keys[]' "$f"); do
    dep="$(jq -r --arg s "$s" '.stacks[$s].detect.packageDependency // empty' "$f")"
    [ -n "$dep" ] || continue
    jq -e --arg d "$dep" '((.dependencies // {}) + (.devDependencies // {})) | has($d)' "$d/package.json" >/dev/null 2>&1 \
      && { printf '%s\n' "$s"; return 0; }
  done
  return 1
}

# ── step lines ──────────────────────────────────────────────────────────────────────────────────
# One line per step, the same three words everywhere: done · skipped · failed. INIT_FAILED counts
# the failures so the caller can exit non-zero after every later step has still run.
INIT_FAILED="${INIT_FAILED:-0}"
INIT_STEP_LOG="${INIT_STEP_LOG:-}"
init_step() {  # <done|skipped|failed> <what> [detail]
  local line
  line="$(printf '  [%-7s] %s%s' "$1" "$2" "${3:+ — $3}")"
  printf '%s\n' "$line"
  INIT_STEP_LOG="${INIT_STEP_LOG}${line}
"
  [ "$1" = "failed" ] && INIT_FAILED=$((INIT_FAILED + 1))
  return 0
}

# _ig_run_in <dir> <command> -> run it there with no stdin, output indented as it arrives; the
# rc is the command's own (a subshell, so the caller's `set -e` / pipefail are not in play).
_ig_run_in() {
  ( set +e; ( cd "$1" && bash -c "$2" </dev/null ) 2>&1 | sed 's/^/     | /'; exit "${PIPESTATUS[0]}" )
}

# ── recipes ─────────────────────────────────────────────────────────────────────────────────────

# recipe_plan <file> -> the commands the recipe runs, one per line, for a dry run or a preview.
recipe_plan() { jq -r '.steps[] | "      $ \(.run)    # \(.label)"' "$1"; }

# recipe_missing_tools <file> -> one "command — why" line per required command not on PATH.
recipe_missing_tools() {
  local f="$1" c
  for c in $(jq -r '(.requires // [])[].command' "$f"); do
    command -v "$c" >/dev/null 2>&1 || jq -r --arg c "$c" '(.requires // [])[] | select(.command == $c) | "\(.command) — \(.why // "needed by this recipe")"' "$f"
  done
}

# recipe_run <file> <dir> -> runs every step in <dir>. Stops at the first failed command: the steps
# build on each other, so a later one cannot succeed. rc 1 on a failure.
recipe_run() {
  local f="$1" d="$2" n i label run rc missing
  missing="$(recipe_missing_tools "$f")"
  if [ -n "$missing" ]; then
    init_step failed "recipe $(jq -r .id "$f")" "missing on this computer: $(printf '%s' "$missing" | tr '\n' ';')"
    return 1
  fi
  mkdir -p "$d" || return 1
  n="$(jq '.steps | length' "$f")"; i=0
  while [ "$i" -lt "$n" ]; do
    label="$(jq -r --argjson i "$i" '.steps[$i].label' "$f")"
    run="$(jq -r --argjson i "$i" '.steps[$i].run' "$f")"
    printf '  -> %s\n     $ %s\n' "$label" "$run"
    rc=0; _ig_run_in "$d" "$run" || rc=$?
    if [ "$rc" -ne 0 ]; then
      init_step failed "$label" "\`$run\` exited $rc"
      return 1
    fi
    init_step done "$label"
    i=$((i + 1))
  done
  return 0
}

# ── databases ───────────────────────────────────────────────────────────────────────────────────

# database_plan <file> <stack> -> what database_apply would do, for a dry run.
database_plan() {
  local f="$1" s="$2"
  jq -r --arg s "$s" '
    "      $ \(.stacks[$s].install)",
    (.stacks[$s].files[] | "      + \(.to)"),
    "      + \(.envFile)   (\([.env[].name] | join(", ")) — placeholders; you type the real values)",
    "      + .gitignore entry for \(.envFile)"' "$f"
}

# _ig_env_ignored <dir> <envfile> -> rc 0 when git would ignore it (or .gitignore already names it).
_ig_env_ignored() {
  local d="$1" e="$2"
  if git -C "$d" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$d" check-ignore -q "$e" 2>/dev/null && return 0
    return 1
  fi
  [ -f "$d/.gitignore" ] || return 1
  grep -qxF "$e" "$d/.gitignore" && return 0
  grep -qxE '\.env\*|\.env\.\*|\.env\*\.local|\.env\.local' "$d/.gitignore"
}

# database_apply <file> <stack> <dir> -> the four steps, each reported. Idempotent: a package that
# is already a dependency, a file that is already there, a variable the env file already names and
# an ignore rule that already matches are each skipped. A VALUE in the env file is never read into
# a variable and never printed: only variable NAMES are compared.
database_apply() {
  local f="$1" s="$2" d="$3" id env_file install need p n i from to src name ph added
  id="$(jq -r .id "$f")"; env_file="$(jq -r .envFile "$f")"
  # 1. packages
  install="$(jq -r --arg s "$s" '.stacks[$s].install' "$f")"
  need=0
  for p in $(jq -r --arg s "$s" '.stacks[$s].packages[]' "$f"); do
    [ -f "$d/package.json" ] && jq -e --arg p "$p" '((.dependencies // {}) + (.devDependencies // {})) | has($p)' "$d/package.json" >/dev/null 2>&1 || need=1
  done
  if [ "$need" -eq 0 ]; then
    init_step skipped "$id packages" "already in package.json"
  else
    printf '  -> %s packages\n     $ %s\n' "$id" "$install"
    i=0; _ig_run_in "$d" "$install" || i=$?
    if [ "$i" -ne 0 ]; then init_step failed "$id packages" "\`$install\` exited $i"; else init_step done "$id packages"; fi
  fi
  # 2. client code
  n="$(jq --arg s "$s" '.stacks[$s].files | length' "$f")"; i=0
  while [ "$i" -lt "$n" ]; do
    from="$(jq -r --arg s "$s" --argjson i "$i" '.stacks[$s].files[$i].from' "$f")"
    to="$(jq -r --arg s "$s" --argjson i "$i" '.stacks[$s].files[$i].to' "$f")"
    src="$(database_path "$f" "$from")"
    case "$to" in /*|*..*) init_step failed "$to" "a recipe file must stay inside the project"; i=$((i + 1)); continue ;; esac
    if [ ! -f "$src" ]; then
      init_step failed "$to" "the kit does not ship $from"
    elif [ -f "$d/$to" ]; then
      if cmp -s "$src" "$d/$to"; then init_step skipped "$to" "already there"; else init_step skipped "$to" "already there, with your changes — left as it is"; fi
    else
      mkdir -p "$(dirname "$d/$to")" && cp "$src" "$d/$to" && init_step done "$to" || init_step failed "$to" "could not write it"
    fi
    i=$((i + 1))
  done
  # 3. env file: names with placeholders; an existing line is never changed
  added=""
  for name in $(jq -r '.env[].name' "$f"); do
    if [ -f "$d/$env_file" ] && grep -qE "^[[:space:]]*(export[[:space:]]+)?${name}=" "$d/$env_file"; then continue; fi
    ph="$(jq -r --arg n "$name" '.env[] | select(.name == $n) | .placeholder' "$f")"
    if [ ! -f "$d/$env_file" ]; then
      printf '# %s — replace each placeholder with your own value. This file stays on your computer: git ignores it.\n' "$(jq -r .label "$f")" > "$d/$env_file"
    fi
    printf '%s=%s\n' "$name" "$ph" >> "$d/$env_file"
    added="$added $name"
  done
  if [ -n "$added" ]; then init_step done "$env_file" "added the names$added (placeholders)"; else init_step skipped "$env_file" "already names every variable"; fi
  # 4. the env file is never committed
  if _ig_env_ignored "$d" "$env_file"; then
    init_step skipped ".gitignore" "$env_file is already ignored"
  else
    printf '%s\n' "$env_file" >> "$d/.gitignore" && init_step done ".gitignore" "$env_file is now ignored"
  fi
  return 0
}

# _ig_browser_possible -> rc 0 when a page can be opened for the person at the keyboard.
# KIT_INIT_BROWSER=0 turns it off; a run without a terminal, over SSH, or in CI never opens one.
_ig_browser_possible() {
  [ "${KIT_INIT_BROWSER:-1}" = "0" ] && return 1
  _ig_tty || return 1
  [ -n "${CI:-}" ] && return 1
  [ -n "${SSH_CONNECTION:-}${SSH_TTY:-}" ] && return 1
  command -v npx >/dev/null 2>&1 || return 1
  case "$(uname -s)" in
    Darwin) return 0 ;;
    *) [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] ;;
  esac
}

# database_steps <file> <dir> -> the credential steps as numbered text. Names only, never a value.
database_steps() {
  local f="$1" d="$2"
  jq -r --arg d "$d" '
    "  \(.label): where each value comes from (checked against the provider on \(.lastVerified))",
    (.steps | to_entries[] | "    \(.key + 1). \(.value)"),
    "  The file to edit: \($d)/\(.envFile)",
    (.env[] | "    \(.name) = \(.what)  (\(.where))"),
    "  Type the values into that file yourself. cckit never reads them back, and git ignores the file."' "$f"
}

# database_guide <file> <dir> -> open the guide page when a browser is possible; otherwise print
# the same steps. Always prints where the page is.
database_guide() {
  local f="$1" d="$2" g
  g="$(database_path "$f" "$(jq -r .guide "$f")")"
  echo ""
  if _ig_browser_possible; then
    echo "  Opening the $(jq -r .label "$f") guide in your browser: $g"
    if ! ( cd "$d" && npx -y lavish-axi "$g" </dev/null >/dev/null 2>&1 ); then
      echo "  The page did not open. The same steps:"
      database_steps "$f" "$d"
    fi
  else
    database_steps "$f" "$d"
    echo "  The same guide as a page: $g"
  fi
}

# ── the guided resolution init.sh calls before anything is written ──────────────────────────────
# Reads the caller's globals TARGET, FOLDER_GIVEN, NAME, PROFILE, FORCE, RECIPE_ARG, DATABASE_ARG and
# sets: TARGET (absolute), NAME, PROFILE, INIT_CLASS, INIT_NEW (1 = a new project), INIT_ALREADY
# (1 = the kit config is already there), RECIPE_FILE, DB_FILE, DB_STACK. Exits 0 when the user
# stops, 2 on an answer or a folder it has to refuse. It writes nothing.

_ig_opt_text() { printf '%s' "$1" | tr '|\n' '/ '; }

# _ig_pick_location <base dir> <allow here: 1|0> -> sets TARGET (and NAME when it was empty).
_ig_pick_location() {
  local base="$1" allow_here="$2" name slug loc cls
  name="$(init_ask_text project_name "What should the project be called?" "${NAME:-$([ "$allow_here" = 1 ] && basename "$base" || echo my-project)}")"
  slug="$(init_slugify "$name")"; [ -n "$slug" ] || slug="my-project"
  if [ "$allow_here" = 1 ]; then
    loc="$(init_ask_text location "Where should it live? Type a folder, or the word here for $base" "here")"
  else
    loc="$(init_ask_text location "Where should it live? Type the folder for it (it is created for you)" "$base/$slug")"
  fi
  if [ "$loc" = "here" ]; then
    [ "$allow_here" = 1 ] || { echo "x A project cannot live directly in $base. Give it a folder of its own, for example $base/$slug" >&2; exit 2; }
    TARGET="$base"
  else
    TARGET="$(init_abs_path "$loc")" || { echo "x cannot use the folder '$loc'" >&2; exit 2; }
  fi
  [ -n "${NAME:-}" ] || NAME="$name"
  cls="$(init_detect_class "$TARGET")"
  case "$cls" in
    empty|missing) ;;
    home) echo "x $TARGET is a home or system folder. A project needs a folder of its own, for example $TARGET/$slug" >&2; exit 2 ;;
    *)    echo "x $TARGET already has things in it. A new project needs an empty or new folder." >&2; exit 2 ;;
  esac
  INIT_CLASS="$cls"
}

init_guide_resolve() {
  local adv=0 ans id f opts stack cfg n
  TARGET="$(init_abs_path "$TARGET")" || { echo "x cannot use the folder '$TARGET'" >&2; exit 2; }
  INIT_CLASS="$(init_detect_class "$TARGET")"
  INIT_NEW=0; INIT_ALREADY=0; RECIPE_FILE=""; DB_FILE=""; DB_STACK=""
  init_advisor_on && adv=1

  case "$INIT_CLASS" in
    home)
      if [ "$adv" -eq 0 ]; then
        echo "x $TARGET is a home or system folder, not a project folder, so nothing is set up in it." >&2
        echo "  A new project: name the folder it should live in —  cckit init <folder>" >&2
        echo "  A project you already have: run cckit init inside its folder." >&2
        exit 2
      fi
      ans="$(init_ask new_project "Is this a new project?" \
        "You are in $TARGET. That is not a project folder, and nothing is ever set up directly in it." \
        "yes|Yes, start a new project|It gets a folder of its own. You choose where in the next question.|R" \
        "no|No, the project already exists|Nothing is written. Open that project's folder and run cckit init there.")" || exit $?
      if [ "$ans" = "no" ]; then echo "Nothing was written. Open your project's folder in the terminal and run: cckit init"; exit 0; fi
      _ig_pick_location "$TARGET" 0
      INIT_NEW=1
      ;;
    empty|missing)
      if [ "$adv" -eq 1 ]; then
        ans="$(init_ask new_project "Is this a new project?" \
          "$TARGET $([ "$INIT_CLASS" = missing ] && echo "does not exist yet" || echo "is empty")." \
          "yes|Yes, start a new project here|The next questions choose what goes in it.|R" \
          "no|No, I meant a project that already exists|Nothing is written. Open that project's folder and run cckit init there.")" || exit $?
        if [ "$ans" = "no" ]; then echo "Nothing was written. Open your project's folder in the terminal and run: cckit init"; exit 0; fi
        [ "${FOLDER_GIVEN:-0}" = "1" ] || _ig_pick_location "$TARGET" 1
      fi
      INIT_NEW=1
      ;;
    files)
      if [ "$adv" -eq 1 ]; then
        ans="$(init_ask folder_use "This folder has files in it but does not look like a project yet. What should happen?" \
          "$TARGET has no project file (such as package.json) and is not a git repository." \
          "here|Set it up as a project, right here|The cckit files are added next to what is already there. Nothing of yours is changed or removed.|R" \
          "new|Start a new project in a folder of its own|This folder is left alone. You choose the new folder next." \
          "cancel|Stop|Nothing is written.")" || exit $?
        case "$ans" in
          cancel) echo "Nothing was written."; exit 0 ;;
          new)    _ig_pick_location "$TARGET" 0; INIT_NEW=1 ;;
        esac
      fi
      ;;
  esac

  # A kit config that is already there makes this a re-run: the profile comes from it.
  cfg="$(adapter_config_existing "$TARGET" 2>/dev/null || true)"
  if [ -n "$cfg" ] && [ -f "$cfg" ] && [ "${FORCE:-0}" -eq 0 ]; then
    INIT_ALREADY=1
    [ -n "${PROFILE:-}" ] || PROFILE="$(jq -r '.profile // "minimal"' "$cfg" 2>/dev/null || echo minimal)"
  fi

  # ---- recipe ----
  if [ -n "${RECIPE_ARG:-}" ]; then
    if [ "$RECIPE_ARG" != "none" ]; then
      RECIPE_FILE="$(recipe_file "$RECIPE_ARG")" || { echo "x no recipe named '$RECIPE_ARG'. Available: $(recipes_list | tr '\n' ' ')" >&2; exit 2; }
    fi
  elif [ "$INIT_NEW" -eq 1 ] && [ "$adv" -eq 1 ] && [ -n "$(recipes_list)" ]; then
    set --
    for id in $(recipes_list); do
      f="$(recipe_file "$id")"; recipe_validate "$f" 2>/dev/null || continue
      set -- "$@" "$id|$(_ig_opt_text "$(jq -r .label "$f")")|$(_ig_opt_text "$(jq -r '.summary + (if .fits then " Fits: " + .fits else "" end)' "$f")")|$(jq -r 'if .recommended then "R" else "" end' "$f")"
    done
    if [ $# -gt 0 ]; then
      ans="$(init_ask recipe "What should the project start from?" \
        "A recipe builds a working starting point, so the first thing you see is something that runs." \
        "$@" "none|An empty project|Only the cckit workflow files. You add the app yourself.")" || exit $?
      [ "$ans" = "none" ] || RECIPE_FILE="$(recipe_file "$ans")"
    fi
  fi
  if [ -n "$RECIPE_FILE" ]; then
    recipe_validate "$RECIPE_FILE" || { echo "x the recipe $(basename "$RECIPE_FILE") is not valid (problems above)" >&2; exit 2; }
    case "$INIT_CLASS" in
      empty|missing) ;;
      *) echo "x A recipe starts a NEW project and needs an empty folder; $TARGET already has files. Run it on a new folder: cckit init <folder> --recipe $(jq -r .id "$RECIPE_FILE")" >&2; exit 2 ;;
    esac
    n="$(jq -r '.folderName // empty' "$RECIPE_FILE")"
    if [ -n "$n" ] && ! grep -qE "$n" <<<"$(basename "$TARGET")"; then
      echo "x This recipe needs a folder name in lowercase letters, digits and dashes; '$(basename "$TARGET")' is not. Try: $(dirname "$TARGET")/$(init_slugify "$(basename "$TARGET")")" >&2
      exit 2
    fi
    [ -n "${PROFILE:-}" ] || PROFILE="$(jq -r .profile "$RECIPE_FILE")"
  fi

  # ---- database ----
  stack=""; [ -n "$RECIPE_FILE" ] && stack="$(jq -r .stack "$RECIPE_FILE")"
  if [ -n "${DATABASE_ARG:-}" ]; then
    if [ "$DATABASE_ARG" != "none" ]; then
      DB_FILE="$(database_file "$DATABASE_ARG")" || { echo "x no database option named '$DATABASE_ARG'. Available: $(databases_list | tr '\n' ' ')" >&2; exit 2; }
      database_validate "$DB_FILE" || { echo "x the database option '$DATABASE_ARG' is not valid (problems above)" >&2; exit 2; }
      database_offered "$DB_FILE" || { echo "x the database option '$DATABASE_ARG' is not offered: its guide page or its setup test is missing" >&2; exit 2; }
    fi
  elif [ "$INIT_NEW" -eq 1 ] && [ "$adv" -eq 1 ] && [ -n "$RECIPE_FILE" ]; then
    set --
    for id in $(databases_list); do
      f="$(database_file "$id")"; database_offered "$f" || continue
      database_stack_for "$f" "$TARGET" "$stack" >/dev/null 2>&1 || continue
      set -- "$@" "$id|$(_ig_opt_text "$(jq -r .label "$f")")|$(_ig_opt_text "$(jq -r '.summary + " Fits: " + .fits' "$f")")|$(jq -r 'if .recommended then "R" else "" end' "$f")"
    done
    if [ $# -gt 0 ]; then
      ans="$(init_ask database_needed "Will the project need to remember things — accounts, saved items, orders?" \
        "That is what a database is for. It can also be added later: run cckit init --database <name> inside the project." \
        "yes|Yes, set one up now|You get the code that talks to it and a step-by-step guide for the account and the keys.|R" \
        "no|No, not now|Nothing is added. The project works without one.")" || exit $?
      if [ "$ans" = "yes" ]; then
        ans="$(init_ask database "Which database?" "Each one is a service that stores the project's information." "$@")" || exit $?
        DB_FILE="$(database_file "$ans")"
      fi
    fi
  fi
  if [ -n "$DB_FILE" ]; then
    DB_STACK="$(database_stack_for "$DB_FILE" "$TARGET" "$stack")" || {
      echo "x $(jq -r .label "$DB_FILE") has no setup for this project. It supports: $(jq -r '.stacks | keys | join(", ")' "$DB_FILE")" >&2; exit 2; }
  fi

  # ---- profile ----
  if [ -z "${PROFILE:-}" ] && [ "$adv" -eq 1 ]; then
    set --
    for f in "$_ig_kit_root"/profiles/*.json; do
      [ -f "$f" ] || continue
      id="$(basename "$f" .json)"
      set -- "$@" "$id|$(_ig_opt_text "$(jq -r '.label // .name' "$f")")|$(_ig_opt_text "$(jq -r '.description // ""' "$f")")|$([ "$id" = software ] && echo R)"
    done
    PROFILE="$(init_ask profile "What kind of work is this project?" \
      "It decides which helpers (agents, skills, rules) are installed. It can be changed later." "$@")" || exit $?
  fi
  return 0
}
