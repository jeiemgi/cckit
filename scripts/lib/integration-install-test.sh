#!/usr/bin/env bash
# shellcheck shell=bash
# integration-install-test.sh — covers the shared installer runner (E303.3),
# scripts/lib/integration-install.sh: candidate order, the ~/.local/bin lookup, the no-op second
# run, KIT_DRY_RUN, the consent gate and the wire command.
#
# Hermetic: the package managers are STUBS on a sealed PATH (a dir of symlinks to the handful of
# real tools the runner needs, plus the stub dir), HOME is a throwaway dir, and consent lives in a
# throwaway state dir — so no real uv/pipx/npm on this machine is ever reached and nothing is
# installed. Run:  bash scripts/lib/integration-install-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
LIB="$ROOT/scripts/lib"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '$2' want '$3'"; fail=1; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "ok: $1"; else echo "FAIL: $1 -> '$3' not in: $2"; fail=1; fi; }
hasnt() { if printf '%s' "$2" | grep -qF -- "$3"; then echo "FAIL: $1 -> '$3' found in: $2"; fail=1; else echo "ok: $1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "integration-install-test: jq absent — skipping (dependency-light gate)"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"

# ── the sealed PATH: real tools the runner needs, and nothing that is a package manager ────────
sealed="$tmp/sealed"; mkdir -p "$sealed"
for tool in sh bash jq git grep sed awk sort cat mkdir rm dirname basename chmod ls pwd env tr head find; do
  src="$(command -v "$tool" 2>/dev/null)" || continue
  case "$src" in /*) ln -s "$src" "$sealed/$tool" ;; esac
done
stubs="$tmp/stubs"; mkdir -p "$stubs"
log="$tmp/calls.log"; : > "$log"

# stub <manager> <works|fails|lies> — every stub appends its argv to the call log.
#   works: drops the tool into $HOME/.local/bin (off PATH, where uv and pipx put it) and exits 0
#   fails: exits 1                    lies: exits 0 but installs nothing
stub() {
  {
    printf '#!/bin/sh\n'
    printf 'echo "%s $*" >> "%s"\n' "$1" "$log"
    case "$2" in
      works) printf 'mkdir -p "$HOME/.local/bin"\n'
             printf 'printf "#!/bin/sh\\necho \\"fixture-tool \\$* in \\$(pwd -P)\\" >> %s\\n" > "$HOME/.local/bin/fixture-tool"\n' "$log"
             printf 'chmod +x "$HOME/.local/bin/fixture-tool"\n' ;;
      fails) printf 'exit 1\n' ;;
      lies)  printf 'exit 0\n' ;;
    esac
  } > "$stubs/$1"
  chmod +x "$stubs/$1"
}
unstub() { rm -f "$stubs"/*; }

fx="$tmp/integrations"; mkdir -p "$fx"
cp "$ROOT/integrations/integration.schema.json" "$fx/"
cat > "$fx/fixture-tool.json" <<'JSON'
{
  "id": "fixture-tool",
  "label": "Fixture Tool",
  "summary": "A tool that exists only in this test.",
  "config": { "key": "codeGraph.provider", "value": "fixture-graph" },
  "detect": { "run": "fixture-tool --version" },
  "install": [
    { "manager": "npm",  "run": "npm install -g fixture-tool" },
    { "manager": "pnpm", "run": "pnpm add -g fixture-tool" },
    { "manager": "pipx", "run": "pipx install fixture-tool" },
    { "manager": "uv",   "run": "uv tool install fixture-tool" }
  ],
  "wire": {
    "run": "fixture-tool init",
    "declined": { "--no-statusline": "cckit owns the statusline.", "--no-hooks": "cckit owns the hooks." }
  },
  "verify": { "run": "fixture-tool check" },
  "docs": "https://example.invalid/fixture-tool#readme",
  "attribution": {
    "author": "Example Org", "homepage": "https://example.invalid/fixture-tool",
    "affiliated": false, "notice": "cckit is not affiliated with Example Org."
  }
}
JSON
desc="$fx/fixture-tool.json"
proj="$tmp/proj"; mkdir -p "$proj"

# run <home> <shell-snippet> -> the snippet with the lib sourced, on the sealed PATH, with HOME and
# the state dir pointed at throwaway dirs. stdout = the runner's stdout; stderr is kept in $tmp/err.
run() {
  local home="$1"; shift
  mkdir -p "$home"
  ( PATH="$stubs:$sealed"; HOME="$home"; export PATH HOME
    export KIT_INTEGRATIONS_DIR="$fx" KIT_STATE_DIR="$home/state"
    # shellcheck source=/dev/null
    . "$LIB/integration-install.sh"
    eval "$*" ) 2> "$tmp/err"
}
# calls -> the package-manager invocations, in order. wired -> the tool's own `init` invocations.
# (The installed fixture tool logs too, every time detect.run probes it; those are not counted.)
calls() { grep -E '^(npm|pnpm|pipx|uv|npx) ' "$log" | tr '\n' '|'; }
wired() { grep -E '^fixture-tool init' "$log" | tr '\n' '|'; }

# ── 1. no consent: nothing installs, and the exit code does not change ─────────────────────────
stub npm works; stub pipx works; stub uv works
h="$tmp/h1"
out="$(run "$h" "integration_install '$desc' '$proj'")"; r=$?
rc "no consent -> rc 0" "$r" "0"
t  "no consent -> status" "$out" "no-consent"
t  "no consent -> no manager was called" "$(calls)" ""
t  "no consent -> no binary" "$(ls "$h/.local/bin" 2>/dev/null)" ""
has "no consent -> stderr names the consent file" "$(cat "$tmp/err")" "$h/state/consent"
# KIT_ASSUME_YES is not consent.
out="$(run "$h" "KIT_ASSUME_YES=1 integration_install '$desc' '$proj'")"
t  "KIT_ASSUME_YES is not consent" "$out|$(calls)" "no-consent|"

# ── 2. consent is one line in the state dir kit_state_dir resolves ─────────────────────────────
run "$h" "integration_consent_has fixture-tool '$proj'"; rc "consent absent -> rc 1" "$?" "1"
run "$h" "integration_consent_record fixture-tool '$proj'"; rc "record consent -> rc 0" "$?" "0"
run "$h" "integration_consent_record fixture-tool '$proj'"; rc "record twice -> rc 0" "$?" "0"
t  "consent file holds one line" "$(cat "$h/state/consent")" "install:fixture-tool"
run "$h" "integration_consent_has fixture-tool '$proj'"; rc "consent recorded -> rc 0" "$?" "0"
run "$h" "integration_consent_has fixture '$proj'";      rc "a prefix of a recorded id is not consent" "$?" "1"
run "$h" "integration_consent_record '../x' '$proj'";    rc "an id that is no id is refused" "$?" "1"
# Without the override the file is <repo>/.cckit/consent, the same from a subdirectory.
if command -v git >/dev/null 2>&1; then
  grepo="$tmp/grepo"; mkdir -p "$grepo/pkg/deep"; git -C "$grepo" init -q 2>/dev/null
  got="$(run "$tmp/h-git" "unset KIT_STATE_DIR; integration_consent_record fixture-tool '$grepo/pkg/deep' && integration_consent_file '$grepo'")"
  t "consent resolves through kit_state_dir" "$got" "$grepo/.cckit/consent"
  t "recorded from a subdirectory, stored at the repo root" "$(cat "$grepo/.cckit/consent" 2>/dev/null)" "install:fixture-tool"
fi

# ── 3. candidates are tried in descriptor order; the first that works wins ─────────────────────
# npm is first and fails, pnpm is not on the machine, pipx works, uv would work but is never tried.
unstub; stub npm fails; stub pipx works; stub uv works; : > "$log"
out="$(run "$h" "integration_install '$desc' '$proj'")"; r=$?
rc "install -> rc 0" "$r" "0"
t  "install -> status names the winner" "$out" "installed pipx"
t  "order: npm, then pipx; pnpm skipped (absent); uv never run" "$(calls)" "npm install -g fixture-tool|pipx install fixture-tool|"
# the binary landed in ~/.local/bin, which is NOT on PATH — it is still resolved
t  "binary off PATH is resolved" "$(run "$h" "integration_bin '$desc'")" "$h/.local/bin/fixture-tool"
run "$h" "integration_detect '$desc'"; rc "detect sees the off-PATH binary" "$?" "0"
run "$h" "command -v fixture-tool >/dev/null 2>&1"; rc "(it really is off PATH)" "$?" "1"

# ── 4. a second run is a no-op ─────────────────────────────────────────────────────────────────
: > "$log"
out="$(run "$h" "integration_install '$desc' '$proj'")"; r=$?
t  "second run -> present, rc 0" "$out|$r" "present|0"
t  "second run -> no manager was called" "$(calls)" ""

# ── 5. the first candidate wins when it works ──────────────────────────────────────────────────
unstub; stub npm works; stub pipx works; : > "$log"; h="$tmp/h5"
run "$h" "integration_consent_record fixture-tool '$proj'"
out="$(run "$h" "integration_install '$desc' '$proj'")"
t  "first candidate works -> it alone runs" "$out|$(calls)" "installed npm|npm install -g fixture-tool|"

# ── 6. a candidate that exits 0 without installing is not trusted ──────────────────────────────
unstub; stub npm lies; stub uv works; : > "$log"; h="$tmp/h6"
run "$h" "integration_consent_record fixture-tool '$proj'"
out="$(run "$h" "integration_install '$desc' '$proj'")"
t  "exit 0 with no binary -> next candidate" "$out|$(calls)" "installed uv|npm install -g fixture-tool|uv tool install fixture-tool|"
# ... unless the descriptor says the candidate leaves no binary (npx)
mkdir -p "$tmp/npx"; cp "$fx/integration.schema.json" "$tmp/npx/"
jq '.install = [{"manager":"npx","run":"npx -y fixture-tool","resident":false}]' "$desc" > "$tmp/npx/fixture-tool.json"
unstub; stub npx lies; : > "$log"; h="$tmp/h6b"
run "$h" "integration_consent_record fixture-tool '$proj'"
out="$(run "$h" "KIT_INTEGRATIONS_DIR='$tmp/npx' integration_install '$tmp/npx/fixture-tool.json' '$proj'")"
t  "resident:false -> the exit code is the evidence" "$out" "installed npx"

# ── 7. every candidate fails, or none is on the machine -> failed, rc 1 ────────────────────────
unstub; stub npm fails; stub pipx lies; : > "$log"; h="$tmp/h7"
run "$h" "integration_consent_record fixture-tool '$proj'"
out="$(run "$h" "integration_install '$desc' '$proj'")"; r=$?
t  "all candidates fail -> failed, rc 1" "$out|$r" "failed|1"
has "all candidates fail -> the manual command is named" "$(cat "$tmp/err")" "npm install -g fixture-tool"
unstub; : > "$log"
out="$(run "$h" "integration_install '$desc' '$proj'")"; r=$?
t  "no manager on PATH -> failed, rc 1" "$out|$r" "failed|1"
has "no manager on PATH -> the managers are named" "$(cat "$tmp/err")" "npm, pnpm, pipx, uv"

# ── 8. KIT_DRY_RUN prints the plan and runs nothing ────────────────────────────────────────────
unstub; stub npm works; stub uv works; : > "$log"; h="$tmp/h8"
run "$h" "integration_consent_record fixture-tool '$proj'"
out="$(run "$h" "KIT_DRY_RUN=1 integration_install '$desc' '$proj'")"; r=$?
plan="$(cat "$tmp/err")"
t  "dry-run -> status, rc 0" "$out|$r" "dry-run|0"
t  "dry-run -> no manager was called" "$(calls)" ""
t  "dry-run -> no binary" "$(ls "$h/.local/bin" 2>/dev/null)" ""
has "dry-run plan lists candidate 1" "$plan" "1. npm install -g fixture-tool   (npm is available)"
has "dry-run plan marks an absent manager" "$plan" "2. pnpm add -g fixture-tool   (skipped: pnpm is not on PATH)"
has "dry-run plan lists candidate 4" "$plan" "4. uv tool install fixture-tool   (uv is available)"
has "dry-run plan shows the wire command" "$plan" "fixture-tool init --no-statusline --no-hooks"
# dry-run wins over a missing consent record too, and says the record is missing
out="$(run "$tmp/h8b" "KIT_DRY_RUN=1 integration_install '$desc' '$proj'")"
t  "dry-run without consent -> still a plan, nothing run" "$out|$(calls)" "dry-run|"
has "dry-run without consent -> says so" "$(cat "$tmp/err")" "consent: NOT recorded"
t  "plan on stdout matches" "$(run "$h" "integration_install_plan '$desc' '$proj'" | head -1)" "fixture-tool: not installed. Candidates, tried in this order until one works:"

# ── 9. the wire command: `declined` becomes flags, reasons stay out ────────────────────────────
t  "declined map is rendered into flags, in descriptor order" "$(run "$h" "integration_wire_command '$desc'")" "fixture-tool init --no-statusline --no-hooks"
jq 'del(.wire.declined)' "$desc" > "$tmp/nodecl.json"
t  "no declined map -> the bare command" "$(run "$h" "integration_wire_command '$tmp/nodecl.json'")" "fixture-tool init"
jq 'del(.wire)' "$desc" > "$tmp/nowire.json"
run "$h" "integration_wire_command '$tmp/nowire.json'" >/dev/null; rc "no wire step -> rc 1" "$?" "1"
hasnt "the reasons never reach the command line" "$(run "$h" "integration_wire_command '$desc'")" "owns"

# wire runs in the project dir, with the off-PATH binary, under the same two gates
h="$tmp/h1"; : > "$log"     # h1: consent recorded, tool installed by pipx into ~/.local/bin
out="$(run "$h" "KIT_DRY_RUN=1 integration_wire '$desc' '$proj'")"
t  "wire dry-run -> nothing run" "$out|$(wired)" "dry-run|"
has "wire dry-run -> prints the command" "$(cat "$tmp/err")" "fixture-tool init --no-statusline --no-hooks"
out="$(run "$h" "integration_wire '$desc' '$proj'")"; r=$?
t  "wire -> wired, rc 0" "$out|$r" "wired|0"
t  "wire ran the rendered command in the project dir" "$(wired)" "fixture-tool init --no-statusline --no-hooks in $proj|"
: > "$log"; rm -f "$h/state/consent"
out="$(run "$h" "integration_wire '$desc' '$proj'")"; r=$?
t  "wire without consent -> nothing run, rc 0" "$out|$r|$(wired)" "no-consent|0|"
mkdir -p "$tmp/nw"; cp "$fx/integration.schema.json" "$tmp/nw/"; cp "$tmp/nowire.json" "$tmp/nw/fixture-tool.json"
out="$(run "$h" "KIT_INTEGRATIONS_DIR='$tmp/nw' integration_wire '$tmp/nw/fixture-tool.json' '$proj'")"
t  "descriptor with no wire step -> none" "$out" "none"

# ── 10. an invalid descriptor is refused before anything runs ──────────────────────────────────
mkdir -p "$tmp/bad"; cp "$fx/integration.schema.json" "$tmp/bad/"
jq 'del(.verify)' "$desc" > "$tmp/bad/fixture-tool.json"
unstub; stub npm works; : > "$log"; h="$tmp/h10"
run "$h" "integration_consent_record fixture-tool '$proj'"
out="$(run "$h" "KIT_INTEGRATIONS_DIR='$tmp/bad' integration_install '$tmp/bad/fixture-tool.json' '$proj'")"; r=$?
t  "invalid descriptor -> failed, rc 1, nothing run" "$out|$r|$(calls)" "failed|1|"
has "invalid descriptor -> the field is named" "$(cat "$tmp/err")" "verify: required field is missing"

# ── 11. safe under `set -euo pipefail`, the way kit-doctor.sh runs ─────────────────────────────
unstub; stub npm fails; stub uv works; : > "$log"; h="$tmp/h11"
run "$h" "integration_consent_record fixture-tool '$proj'"
out="$(PATH="$stubs:$sealed" HOME="$h" KIT_INTEGRATIONS_DIR="$fx" KIT_STATE_DIR="$h/state" \
  bash -c "set -euo pipefail; . '$LIB/integration-install.sh'; s=\"\$(integration_install '$desc' '$proj')\"; echo \"got:\$s\"" 2>/dev/null)"
t  "strict mode: a failing candidate does not abort the caller" "$out" "got:installed uv"

# ── 12. the CLI form ───────────────────────────────────────────────────────────────────────────
cli() { local home="$1"; shift
  PATH="$stubs:$sealed" HOME="$home" KIT_INTEGRATIONS_DIR="$fx" KIT_STATE_DIR="$home/state" bash "$LIB/integration-install.sh" "$@" 2>/dev/null; }
unstub; stub pipx works; : > "$log"; h="$tmp/h12"; mkdir -p "$h"
t  "--install without consent" "$(cli "$h" --install fixture-tool "$proj")" "no-consent"
cli "$h" --consent fixture-tool "$proj"; rc "--consent -> rc 0" "$?" "0"
has "--plan names the candidates" "$(cli "$h" --plan fixture-tool "$proj")" "3. pipx install fixture-tool   (pipx is available)"
t  "--install by id" "$(cli "$h" --install fixture-tool "$proj")" "installed pipx"
t  "--wire-command" "$(cli "$h" --wire-command fixture-tool)" "fixture-tool init --no-statusline --no-hooks"
t  "--wire" "$(cli "$h" --wire fixture-tool "$proj")" "wired"
cli "$h" --install nope >/dev/null; rc "unknown id -> rc 1" "$?" "1"
cli "$h" --bogus >/dev/null;        rc "unknown flag -> rc 2" "$?" "2"

# ── 13. the same runner under zsh (scripts/lib is sourced from zsh too) ────────────────────────
if command -v zsh >/dev/null 2>&1; then
  zbin="$(command -v zsh)"
  unstub; stub npm fails; stub pipx works; stub uv works; : > "$log"; h="$tmp/h13"; mkdir -p "$h"
  out="$(PATH="$stubs:$sealed" HOME="$h" KIT_INTEGRATIONS_DIR="$fx" KIT_STATE_DIR="$h/state" \
    "$zbin" -fc "source '$LIB/integration-install.sh'; integration_install '$desc' '$proj'; integration_consent_record fixture-tool '$proj' && integration_install '$desc' '$proj' && integration_install '$desc' '$proj' && integration_wire_command '$desc'" 2>/dev/null | tr '\n' '|')"
  t "zsh: no-consent, install in order, no-op, wire command" "$out" "no-consent|installed pipx|present|fixture-tool init --no-statusline --no-hooks|"
  t "zsh: order of calls" "$(calls)" "npm install -g fixture-tool|pipx install fixture-tool|"
fi

[ "$fail" = "0" ] && echo "ALL OK" || { echo "SOME FAILED"; exit 1; }
