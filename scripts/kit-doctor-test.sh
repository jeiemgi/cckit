#!/usr/bin/env bash
# shellcheck shell=bash
# kit-doctor-test.sh — covers the integrations loop in scripts/kit-doctor.sh (E303.4): the
# preflight holds no tool's install recipe; for every descriptor in integrations/ whose config key
# is on it asks the shared runner (scripts/lib/integration-install.sh) and prints one row.
#
# Hermetic: kit-doctor.sh runs against a throwaway project and HOME on a sealed PATH — symlinks to
# the real tools it needs, plus STUBS for everything that would reach the machine or the network
# (uname, brew, gh, node, pnpm, ssh, curl, sysctl, and the package managers pipx / uv). The real
# descriptors (integrations/mempalace.json, integrations/mlx-lm.json) are the ones under test, so
# no real pipx, uv or brew is ever run and nothing is installed.
# Run:  bash scripts/kit-doctor-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/test-env.sh" && test_env_seal
DOCTOR="$ROOT/scripts/kit-doctor.sh"
fail=0
t()     { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()   { if grep -qF -- "$3" <<<"$2"; then echo "ok: $1"; else echo "FAIL: $1 -> '$3' not in: $2"; fail=1; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then echo "FAIL: $1 -> '$3' found in: $2"; fail=1; else echo "ok: $1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "kit-doctor-test: jq absent — skipping (dependency-light gate)"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd -P)"

# ── the sealed PATH ────────────────────────────────────────────────────────────────────────────
sealed="$tmp/sealed"; mkdir -p "$sealed"
for tool in sh bash jq git perl grep sed awk sort cat mkdir rm dirname basename chmod ls pwd env tr head tail find seq sleep mktemp cut nohup mv cp; do
  src="$(command -v "$tool" 2>/dev/null)" || continue
  case "$src" in /*) ln -s "$src" "$sealed/$tool" ;; esac
done
stubs="$tmp/stubs"; mkdir -p "$stubs"
log="$tmp/calls.log"; : > "$log"
printf 'arm64\n' > "$tmp/arch"      # what the stub `uname -m` answers
printf '1\n'     > "$tmp/curl-rc"   # the stub curl's exit code: 1 = nothing answers, 0 = server alive

mk() { cat > "$stubs/$1"; chmod +x "$stubs/$1"; }   # mk <name> — stub body on stdin
# The machine: an Apple-silicon Mac by default, whatever the host really is.
mk uname <<EOF
#!/bin/sh
case "\${1:-}" in -m) cat "$tmp/arch" ;; *) echo Darwin ;; esac
EOF
mk sysctl <<'EOF'
#!/bin/sh
echo "Stub Silicon"
EOF
mk gh <<'EOF'
#!/bin/sh
case "$1 ${2:-}" in
  "--version ") echo "gh version 2.50.0 (stub)" ;;
  "auth status") echo "  - Token scopes: 'project', 'repo'" ;;
  "api user") echo "stub-user" ;;
esac
exit 0
EOF
mk node <<'EOF'
#!/bin/sh
echo v22.0.0
EOF
mk pnpm <<EOF
#!/bin/sh
echo "pnpm \$*" >> "$log"
echo 9.0.0
EOF
mk ssh <<'EOF'
#!/bin/sh
exit 1
EOF
mk curl <<EOF
#!/bin/sh
exit "\$(cat "$tmp/curl-rc")"
EOF

# manager <pipx|uv> — a package manager that "installs" by dropping the tool into ~/.local/bin
# (off PATH, where the real ones put it) and logs its argv.
manager() {
  mk "$1" <<EOF
#!/bin/sh
echo "$1 \$*" >> "$log"
for last in "\$@"; do :; done
case "\$last" in
  mempalace) bin=mempalace ;;
  mlx-lm)    bin=mlx_lm.server ;;
  *) exit 1 ;;
esac
mkdir -p "\$HOME/.local/bin"
printf '#!/bin/sh\necho "stub %s 0.0.0"\n' "\$bin" > "\$HOME/.local/bin/\$bin"
chmod +x "\$HOME/.local/bin/\$bin"
EOF
}
# brew: `brew install <manager>` puts that manager on PATH (the bootstrap); anything else is a no-op.
mk brew <<EOF
#!/bin/sh
echo "brew \$*" >> "$log"
case "\$1 \${2:-}" in
  "--version ") echo "Homebrew 4.0.0 (stub)" ;;
  "install pipx"|"install uv") cp "$tmp/manager-\$2" "$stubs/\$2"; chmod +x "$stubs/\$2" ;;
esac
exit 0
EOF
manager pipx; manager uv
cp "$stubs/pipx" "$tmp/manager-pipx"; cp "$stubs/uv" "$tmp/manager-uv"

calls() { grep -E '^(pipx|uv|brew install) ' "$log" | tr '\n' '|'; }

# project <name> <config-json> -> a throwaway kit project; echoes its dir.
project() {
  mkdir -p "$tmp/$1/.claude"
  printf '%s\n' "$2" > "$tmp/$1/.claude/kit.config.json"
  printf '%s\n' "$tmp/$1"
}
# doctor <home> <project> [flags…] -> stdout = the report; stderr in $tmp/err; rc = the doctor's.
# stdin is /dev/null: no terminal, so the install prompt never fires.
doctor() {
  local home="$1" proj="$2"; shift 2
  mkdir -p "$home"
  [ -f "$home/.gitconfig" ] || printf '[user]\n\tname = Stub User\n\temail = stub@example.invalid\n' > "$home/.gitconfig"
  ( cd "$proj" && PATH="$stubs:$sealed" HOME="$home" KIT_ASCII=1 NO_COLOR=1 LC_ALL=C \
      bash "$DOCTOR" "$@" </dev/null 2> "$tmp/err" )
}
rows() { printf '%s\n' "$1" | grep -E '^ +(ok|FAIL|warn|-) +(mempalace CLI|mlx-lm) ' | sed -E 's/^ +//; s/ +/ /g'; }

# ── 0. the doctor holds no tool's recipe (the sub's acceptance, verbatim) ──────────────────────
t "no installer recipe or per-tool finder is left in kit-doctor.sh" \
  "$(grep -cE 'pipx install|uv tool install|_mp_find|_mlx_find' "$DOCTOR")" "0"

# ── 1. nothing switched on: no integration row, and the exit code a keyless config gets ────────
bare="$(project bare '{"project":{"name":"x"}}')"
off="$(project off '{"memory":{"enabled":false},"local":{"enabled":false}}')"
out_bare="$(doctor "$tmp/h1" "$bare" --dry-run)"; rc_bare=$?
out_off="$(doctor "$tmp/h1" "$off" --dry-run)"; rc_off=$?
t "no keys -> exit 0 on a healthy machine" "$rc_bare" "0"
t "both keys false -> the same exit code as with no keys" "$rc_off" "$rc_bare"
t "both keys false -> no integration row" "$(rows "$out_off")" ""
hasnt "both keys false -> no Integrations section" "$out_off" "Integrations"
hasnt "both keys false -> no Memory section" "$out_off" "Memory (MemPalace)"
hasnt "both keys false -> no Local section" "$out_off" "Local model layer"
t "both keys false -> no manager was called" "$(calls)" ""

# ── 2. both on, tools absent, --dry-run: two rows from the runner, nothing installed ───────────
on="$(project on '{"memory":{"enabled":true},"local":{"enabled":true}}')"
out="$(doctor "$tmp/h2" "$on" --dry-run)"; r=$?
has "dry-run -> Integrations section" "$out" "Integrations (optional tools this project switched on)"
t "dry-run -> one row per descriptor, each naming its FIRST candidate" "$(rows "$out" | tr '\n' '|')" \
  "FAIL mempalace CLI missing — pipx install mempalace|FAIL mlx-lm missing — uv tool install mlx-lm|"
has "dry-run -> action names the recipe" "$out" "Install mlx-lm: uv tool install mlx-lm"
t "dry-run -> exit 1 (an enabled tool is missing)" "$r" "1"
t "dry-run -> no manager was called" "$(calls)" ""
t "dry-run -> no binary" "$(ls "$tmp/h2/.local/bin" 2>/dev/null)" ""
t "dry-run -> no consent recorded" "$(cat "$on/.cckit/consent" 2>/dev/null)" ""
out="$(doctor "$tmp/h2" "$on" --no-install)"
t "--no-install -> the same two rows, nothing installed" "$(rows "$out" | tr '\n' '|')|$(calls)" \
  "FAIL mempalace CLI missing — pipx install mempalace|FAIL mlx-lm missing — uv tool install mlx-lm||"

# ── 3. nobody approved (no terminal, no --fix): nothing installs ───────────────────────────────
out="$(doctor "$tmp/h2" "$on")"; r=$?
has "unapproved run -> the row says why" "$(rows "$out")" "mempalace CLI missing — nothing installs without your yes: cckit doctor --fix"
t "unapproved run -> no manager was called, no consent recorded" "$(calls)|$(cat "$on/.cckit/consent" 2>/dev/null)" "|"
t "unapproved run -> exit 1" "$r" "1"
has "unapproved run -> the runner said where consent lives" "$(cat "$tmp/err")" "$on/.cckit/consent"

# ── 4. --yes (init's preflight path): consent is recorded and the runner installs ──────────────
printf '0\n' > "$tmp/curl-rc"   # the model server answers, so the doctor does not try to start one
: > "$log"
out="$(doctor "$tmp/h4" "$on" --yes)"; r=$?
t "--yes -> each tool installed by its FIRST candidate" "$(calls)" "pipx install mempalace|uv tool install mlx-lm|"
t "--yes -> rows name the winning manager and the off-PATH binary" "$(rows "$out" | tr '\n' '|')" \
  "ok mempalace CLI installed via pipx ($tmp/h4/.local/bin/mempalace)|ok mlx-lm installed via uv ($tmp/h4/.local/bin/mlx_lm.server)|"
has "--yes -> the descriptor's afterInstall line is reported" "$out" "Installed mempalace CLI via pipx — run 'mempalace mcp' to wire the MCP server"
t "--yes -> consent recorded, one line per integration" "$(sort "$on/.cckit/consent" | tr '\n' '|')" "install:mempalace|install:mlx-lm|"
t "--yes -> exit 0" "$r" "0"
has "--yes -> the memory section's non-install checks still run" "$out" "identity header"
has "--yes -> the local section still checks the server" "$out" "alive @ :8080"

# a second run is a no-op
: > "$log"
out="$(doctor "$tmp/h4" "$on" --yes)"; r=$?
t "second run -> present, no manager called, exit 0" "$(rows "$out" | tr '\n' '|')|$(calls)|$r" \
  "ok mempalace CLI installed ($tmp/h4/.local/bin/mempalace)|ok mlx-lm installed ($tmp/h4/.local/bin/mlx_lm.server)|||0"

# ── 5. the fallback candidate: no pipx on the machine -> mempalace installs with uv ────────────
rm -f "$stubs/pipx"; : > "$log"; on5="$(project on5 '{"memory":{"enabled":true}}')"
out="$(doctor "$tmp/h5" "$on5" --fix)"
t "pipx absent -> uv, and no bootstrap (a manager was already there)" "$(calls)|$(rows "$out")" \
  "uv tool install mempalace||ok mempalace CLI installed via uv ($tmp/h5/.local/bin/mempalace)"

# ── 6. the bootstrap: neither pipx nor uv -> the first candidate's manager is installed first ──
rm -f "$stubs/pipx" "$stubs/uv"; : > "$log"; on6="$(project on6 '{"memory":{"enabled":true},"local":{"enabled":true}}')"
out="$(doctor "$tmp/h6" "$on6" --fix)"
# mempalace is pipx-first, so brew brings pipx; by the time mlx-lm runs a manager exists, so uv is
# never bootstrapped and its pipx fallback is used.
t "no manager -> bootstrap the first candidate's manager, once" "$(calls)" \
  "brew install pipx|pipx install mempalace|pipx install mlx-lm|"
rm -f "$stubs/pipx" "$stubs/uv"; : > "$log"; on6b="$(project on6b '{"local":{"enabled":true}}')"
out="$(doctor "$tmp/h6b" "$on6b" --fix)"
t "mlx-lm alone, no manager -> brew install uv, then uv" "$(calls)|$(rows "$out")" \
  "brew install uv|uv tool install mlx-lm||ok mlx-lm installed via uv ($tmp/h6b/.local/bin/mlx_lm.server)"
rm -f "$stubs/pipx" "$stubs/uv"; : > "$log"
out="$(doctor "$tmp/h6c" "$on6b" --dry-run)"
t "no manager, dry-run -> brew is not run either" "$(calls)|$(rows "$out")" "|FAIL mlx-lm missing — uv tool install mlx-lm"

# ── 7. the platform gate: not Apple silicon -> mlx-lm is skipped, never installed ──────────────
manager pipx; manager uv; : > "$log"; printf 'x86_64\n' > "$tmp/arch"
out="$(doctor "$tmp/h7" "$on" --yes)"
has "x86_64 -> mlx-lm row is a skip that names the requirement" "$(rows "$out")" "- mlx-lm needs a Darwin arm64 machine — skipping install"
t "x86_64 -> only mempalace is installed" "$(calls)" "pipx install mempalace|"
t "x86_64 -> no mlx binary" "$(ls "$tmp/h7/.local/bin")" "mempalace"
printf 'arm64\n' > "$tmp/arch"

# ── 8. no terminal and no --fix: report only — no `pnpm install`, no seeded file (#448) ────────
# A trial run of the update path called `cckit doctor` with no flag and stdin not a terminal; it ran
# `pnpm install` in the project and wrote a MemPalace header. Nobody had been asked.
pn="$(project pn '{"project":{"name":"x","slug":"pn"},"memory":{"enabled":true}}')"
printf '{"name":"pn","dependencies":{"left-pad":"1.0.0"}}\n' > "$pn/package.json"
: > "$log"
out="$(doctor "$tmp/h8" "$pn")"
t "no flag, no terminal -> pnpm install is not run" "$(grep -c '^pnpm install' "$log")" "0"
has "no flag, no terminal -> node_modules is reported, with the command" "$out" "missing — run pnpm install"
t "no flag, no terminal -> no identity header is written" "$(ls "$pn/.claude" | grep -c mempal-identity)" "0"
has "no flag, no terminal -> the report says it is report-only and how to install" "$out" "report-only — no terminal and no --fix"
has "no flag, no terminal -> names the flag" "$out" "cckit doctor --fix"
t "no flag, no terminal -> no file is added to the project" "$(cd "$pn" && find . -type f | LC_ALL=C sort | tr '\n' ' ')" "./.claude/kit.config.json ./package.json "
out="$(doctor "$tmp/h8" "$pn" --dry-run)"
hasnt "--dry-run -> not labelled report-only for want of a terminal" "$out" "no terminal and no --fix"
: > "$log"
out="$(doctor "$tmp/h8" "$pn" --fix)"
t "--fix -> pnpm install runs" "$(grep -c '^pnpm install' "$log")" "1"
t "--fix -> the identity header is seeded" "$(ls "$pn/.claude" | grep -c mempal-identity)" "1"
hasnt "--fix -> not report-only" "$out" "report-only"

[ "$fail" = "0" ] && echo "ALL OK (kit-doctor)" || { echo "kit-doctor: FAILURES"; exit 1; }
