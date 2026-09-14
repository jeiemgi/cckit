#!/usr/bin/env bash
# review-lint.sh — codified review findings as a deterministic gate (kit-owned).
#
# WHY: an AI reviewer (CodeRabbit) finds the same classes of defect over and over, but its findings
# live in PR threads and die there. Anything MECHANICAL in that stream — a pattern that is wrong
# every time it appears, regardless of intent — belongs in a gate that runs in under a second and
# never forgets. This file is that gate; `review-rules.conf` is the rule table, one block per rule,
# each carrying the PR it was earned from.
#
# WHAT IT IS NOT: a replacement for review. Only the mechanical slice maps here. Findings that need
# intent — doc-vs-code drift, architectural contracts, "is this the right abstraction" — stay with
# the reviewer. Do not force those into regexes; a noisy gate is worse than no gate.
#
#   scripts/review-lint.sh                 lint against the baseline (the gate)
#   scripts/review-lint.sh --report        every rule's current hit count; never fails
#   scripts/review-lint.sh --rule <ID>     show every hit for one rule, with context
#   scripts/review-lint.sh --update        re-baseline from current hits
#
# Baseline: scripts/review-lint-baseline.txt  ("<RULE> <path> <count>"). Grandfathers today's hits
# per file so adding a rule never forces a repo-wide fix; only NEW or GROWN hits fail.
# bash 3.2 compatible (no associative arrays, no mapfile).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RULES="scripts/review-rules.conf"
BASELINE="scripts/review-lint-baseline.txt"

FAIL=0
err()  { echo "x $1"; FAIL=1; }
ok()   { echo "ok $1"; }
note() { echo "  $1"; }

[ -f "$RULES" ] || { echo "review-lint: no $RULES — nothing to enforce"; exit 0; }

# ---- rule table access ------------------------------------------------------
rule_ids() { awk '/^\[.+\]$/ { gsub(/^\[|\]$/, ""); print }' "$RULES"; }

# rule_field <id> <key> — value of one key inside one [id] block ("" if unset).
rule_field() {
  awk -v id="$1" -v key="$2" '
    /^\[.+\]$/ { cur = $0; gsub(/^\[|\]$/, "", cur); inblk = (cur == id); next }
    !inblk { next }
    index($0, key ":") == 1 { sub("^" key ":[ \t]*", ""); print; exit }
  ' "$RULES"
}

# ---- file selection ---------------------------------------------------------
# Scope/exclude are comma-separated shell patterns matched with `case`, where `*` DOES cross `/`
# (case patterns are not pathname expansion). So `scripts/*` matches `scripts/lib/foo.sh`.
# Tracked files when there are any; otherwise a filesystem walk. The fallback matters for a
# freshly scaffolded project, where the kit has written files but nothing is staged yet -
# `git ls-files` is empty there, and without this the gate would silently scan nothing.
list_files() {
  local tracked
  tracked="$(git ls-files 2>/dev/null)"
  if [ -n "$tracked" ]; then printf '%s\n' "$tracked"; return 0; fi
  find . -type f \
    -not -path './.git/*' -not -path '*/node_modules/*' \
    -not -path './dist/*' -not -path './.cckit/*' 2>/dev/null | sed 's|^\./||'
}

files_for_rule() {
  local scope exclude f keep pat
  scope="$(rule_field "$1" scope)"
  exclude="$(rule_field "$1" exclude)"
  [ -n "$scope" ] || scope='*'
  list_files | while IFS= read -r f; do
    # Never lint the rule table or the baseline: both quote the very patterns they describe,
    # so scanning them makes every rule match itself.
    case "$f" in "$RULES"|"$BASELINE") continue ;; esac
    keep=0
    IFS=',' read -r -a _scopes <<< "$(printf '%s' "$scope" | tr -d ' ')"
    for pat in "${_scopes[@]}"; do
      [ -n "$pat" ] || continue
      case "$f" in $pat) keep=1; break ;; esac
    done
    [ "$keep" -eq 1 ] || continue
    if [ -n "$exclude" ]; then
      IFS=',' read -r -a _excl <<< "$(printf '%s' "$exclude" | tr -d ' ')"
      for pat in "${_excl[@]}"; do
        [ -n "$pat" ] || continue
        case "$f" in $pat) keep=0; break ;; esac
      done
    fi
    [ "$keep" -eq 1 ] && printf '%s\n' "$f"
  done
}

# ---- matching ---------------------------------------------------------------
# Emits "path:line:text" for every hit of one rule.
#
# code_only drops FULL-LINE comments only (first non-blank char is `#`). It deliberately does not
# strip trailing comments: in shell `#` is ambiguous (`${v#p}`, `$#`, `'#'`), so stripping it would
# corrupt real code lines. Use `ignore:` for the rest.
hits_for_rule() {
  local id="$1" kind pattern prog ignore code_only flist
  kind="$(rule_field "$id" kind)"
  ignore="$(rule_field "$id" ignore)"
  code_only="$(rule_field "$id" code_only)"

  flist="$(files_for_rule "$id")"
  [ -n "$flist" ] || return 0

  # Two rule kinds. `regex` (the default) is a per-line grep — enough for most findings. `awk` is
  # for rules that need STATE across lines, such as fence parity: a bare ``` is only a defect when
  # it OPENS a block, and no per-line pattern can know that. An awk rule supplies a one-line program
  # that prints FILENAME":"FNR":"$0 for each hit and resets its state on FNR==1.
  if [ "$kind" = "awk" ]; then
    prog="$(rule_field "$id" awk)"
    [ -n "$prog" ] || return 0
    printf '%s\n' "$flist" \
      | tr '\n' '\0' \
      | xargs -0 awk "$prog" 2>/dev/null
  else
    pattern="$(rule_field "$id" pattern)"
    [ -n "$pattern" ] || return 0
    printf '%s\n' "$flist" \
      | tr '\n' '\0' \
      | xargs -0 grep -nE -- "$pattern" /dev/null 2>/dev/null
  fi \
    | awk -v co="${code_only:-false}" -v ig="${ignore:-}" '
        {
          body = $0
          sub(/^[^:]*:[0-9]+:/, "", body)
          if (co == "true") { t = body; sub(/^[ \t]+/, "", t); if (substr(t, 1, 1) == "#") next }
          if (ig != "" && body ~ ig) next
          print
        }
      '
}

baseline_count() {
  [ -f "$BASELINE" ] || { echo 0; return; }
  grep -v '^[[:space:]]*#' "$BASELINE" 2>/dev/null \
    | awk -v r="$1" -v p="$2" '$1 == r && $2 == p { print $3; found = 1; exit } END { if (!found) print 0 }'
}

MODE="${1:-lint}"
ARG="${2:-}"

# ---- --rule <ID> ------------------------------------------------------------
if [ "$MODE" = "--rule" ]; then
  [ -n "$ARG" ] || { echo "usage: review-lint.sh --rule <ID>"; exit 2; }
  rule_ids | grep -qx "$ARG" || { echo "x unknown rule '$ARG'"; exit 2; }
  echo "[$ARG] $(rule_field "$ARG" title)"
  echo "  why:    $(rule_field "$ARG" why)"
  echo "  source: $(rule_field "$ARG" source)"
  echo
  hits_for_rule "$ARG" | sed 's/^/  /'
  echo
  echo "  $(hits_for_rule "$ARG" | grep -c . | tr -d ' ') hit(s)"
  exit 0
fi

# ---- --report ---------------------------------------------------------------
if [ "$MODE" = "--report" ]; then
  printf '%-26s %5s  %s\n' RULE HITS TITLE
  rule_ids | while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%-26s %5s  %s\n' "$id" "$(hits_for_rule "$id" | grep -c . | tr -d ' ')" "$(rule_field "$id" title)"
  done
  exit 0
fi

# ---- --update ---------------------------------------------------------------
if [ "$MODE" = "--update" ]; then
  {
    echo "# review-lint-baseline.txt — generated by scripts/review-lint.sh --update"
    echo "# Pre-existing hits, GRANDFATHERED per file: they may stay, but may never grow, and a"
    echo "# file not listed here must have zero hits. Fix a file and re-run --update to tighten."
    echo "#"
    echo "# <RULE> <path> <count>"
    rule_ids | while IFS= read -r id; do
      [ -n "$id" ] || continue
      hits_for_rule "$id" | awk -F: '{ print $1 }' | sort | uniq -c \
        | awk -v r="$id" '{ print r, $2, $1 }'
    done
  } > "$BASELINE"
  echo "ok wrote $BASELINE ($(grep -cv '^[[:space:]]*#' "$BASELINE" | tr -d ' ') grandfathered file(s))"
  exit 0
fi

# ---- lint (the gate) --------------------------------------------------------
total=0
grandfathered=0
while IFS= read -r id; do
  [ -n "$id" ] || continue
  title="$(rule_field "$id" title)"
  why="$(rule_field "$id" why)"
  src="$(rule_field "$id" source)"

  # Per-file counts for this rule.
  counts="$(hits_for_rule "$id" | awk -F: '{ print $1 }' | sort | uniq -c | awk '{ print $2, $1 }')"
  [ -n "$counts" ] || continue

  while read -r path n; do
    [ -n "$path" ] || continue
    total=$(( total + n ))
    base="$(baseline_count "$id" "$path")"
    if [ "$n" -gt "$base" ]; then
      if [ "$base" -eq 0 ]; then
        err "[$id] $path: $n hit(s) — $title"
      else
        err "[$id] $path: grew to $n hit(s) (baseline $base) — $title"
      fi
      note "why:    $why"
      note "source: $src"
      hits_for_rule "$id" | grep "^$path:" | head -3 | sed 's/^/    /'
      note "see all: scripts/review-lint.sh --rule $id"
    else
      grandfathered=$(( grandfathered + n ))
    fi
  done <<EOF
$counts
EOF
done < <(rule_ids)

if [ "$FAIL" -eq 0 ]; then
  ok "review rules clean ($(rule_ids | grep -c . | tr -d ' ') rule(s), $grandfathered grandfathered hit(s))"
fi
exit "$FAIL"
