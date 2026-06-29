#!/usr/bin/env bash
# secret-guard.sh — agnostic secret + privacy guard. Ensures cckit never publishes secrets,
# key material, env files, or YOUR private project data. NOTHING project-specific is hardcoded:
# the secret/key patterns are universal, and "what is private to me" is supplied by the user via
# an optional, gitignored denylist (.cckit/privacy-denylist) — cckit ships only an .example.
#
# Applies to EVERYTHING publishable — code, docs, cookbook, examples, templates.
# Usage:  source secret-guard.sh && secret_guard_scan [file...]   (default: git-tracked files)
#         exit 0 = clean, 1 = a finding (with a report on stderr).

# Files that must never be committed (by basename). Env files include .env.example/.sample —
# even an example leaks your variable *names* and structure, so it stays local.
_sg_forbidden_name() {
  case "$1" in
    .env|.env.*|*.env) return 0 ;;
    *.pem|*.key|*.p12|*.pfx|*.keystore|*.jks|id_rsa|id_rsa.*|id_ed25519|id_ed25519.*) return 0 ;;
    .netrc|.pgpass|.npmrc|credentials|credentials.*|secrets.json|secrets.yaml|secrets.yml|*.tfvars) return 0 ;;
    *.project-ids*|.project-ids.env) return 0 ;;
    *) return 1 ;;
  esac
}

# Universal high-signal secret content patterns (provider key prefixes, private-key blocks).
# Written so the patterns do not match their own literal text.
_sg_secret_patterns() {
  cat <<'PAT'
-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----
AKIA[0-9A-Z]{16}
ASIA[0-9A-Z]{16}
sk-[A-Za-z0-9]{20,}
sk-proj-[A-Za-z0-9_-]{20,}
gh[pousr]_[A-Za-z0-9]{36,}
github_pat_[A-Za-z0-9_]{50,}
AIza[0-9A-Za-z_-]{35}
xox[baprs]-[0-9A-Za-z-]{10,}
sk_live_[0-9A-Za-z]{24,}
rk_live_[0-9A-Za-z]{24,}
glpat-[0-9A-Za-z_-]{20,}
eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}
PAT
}

# Generic "assignment of a real-looking secret value" — allows placeholders (<...>, ${...},
# YOUR_, example, changeme, xxxx, redacted, placeholder).
_sg_assign_pattern='(api[_-]?key|secret|password|passwd|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key)["'"'"' ]*[:=]+[ ]*["'"'"'][^"'"'"'$<{ ]{8,}'

secret_guard_scan() {
  local files findings=0 f line denylist
  if [ "$#" -gt 0 ]; then files=("$@"); else
    # default: git-tracked + staged, minus this guard + the example denylist (avoid self-match)
    mapfile -t files < <(git ls-files 2>/dev/null | grep -vE 'scripts/lib/secret-guard\.sh|privacy-denylist\.example' || true)
  fi

  # (a) forbidden filenames
  for f in "${files[@]:-}"; do
    [ -z "$f" ] && continue
    if _sg_forbidden_name "$(basename "$f")"; then
      echo "x secret-guard: forbidden file must not be committed: $f" >&2; findings=$((findings+1))
    fi
  done

  # (b) universal secret content patterns
  local pat
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "x secret-guard: secret-like content: $line" >&2; findings=$((findings+1))
    done < <(printf '%s\n' "${files[@]:-}" | tr '\n' '\0' | xargs -0 grep -nIE "$pat" 2>/dev/null | head -20)
  done < <(_sg_secret_patterns)

  # (c) generic secret assignment (placeholders allowed)
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in *YOUR_*|*example*|*EXAMPLE*|*placeholder*|*changeme*|*xxxx*|*redacted*|*'<'*|*'${'*) continue ;; esac
    echo "x secret-guard: secret-like assignment: $line" >&2; findings=$((findings+1))
  done < <(printf '%s\n' "${files[@]:-}" | tr '\n' '\0' | xargs -0 grep -niIE "$_sg_assign_pattern" 2>/dev/null | head -20)

  # (d) user-supplied privacy denylist (agnostic: YOU declare what is yours; file stays local)
  denylist=".cckit/privacy-denylist"
  if [ -f "$denylist" ]; then
    while IFS= read -r term; do
      term="$(printf '%s' "$term" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -z "$term" ] && continue
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "x secret-guard: private term '$term' present: $line" >&2; findings=$((findings+1))
      done < <(printf '%s\n' "${files[@]:-}" | tr '\n' '\0' | xargs -0 grep -nIF "$term" 2>/dev/null | head -10)
    done < "$denylist"
  fi

  if [ "$findings" -gt 0 ]; then
    echo "✗ secret-guard: $findings finding(s) — refusing to proceed" >&2; return 1
  fi
  return 0
}
