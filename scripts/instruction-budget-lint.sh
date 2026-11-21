#!/usr/bin/env bash
# instruction-budget-lint.sh — context-budget guardrail for instruction files (kit-owned).
#
# WHY: Claude Code loads every CLAUDE.md, and every `.claude/rules/*.md` that has no `paths:`
# frontmatter, into EVERY session whatever the task. It warns at startup once those files add up
# past a combined 150k characters; over the limit they still load, and adherence drops. A project
# grows rules one decision at a time, so the resident set drifts upward with no single commit to
# blame. skill-frontmatter-lint.sh ratchets the skill LISTING; this is the same drift one level up.
#
# WHAT: splits the instruction files into two sets and enforces a RATCHET, not a hard cap.
#
#   resident      CLAUDE.md, CLAUDE.local.md, .claude/CLAUDE.md, and every rule with no `paths:` key
#   path-scoped   a rule whose frontmatter declares `paths:` — loaded only once a matching file is read
#
#   - the resident total may not exceed BUDGET bytes (150000), and
#   - no single instruction file, resident or scoped, may exceed MAX_LINES lines (200).
#
# Today's offenders are recorded in a baseline and allowed to stay; nothing may grow past its
# recorded size and nothing NEW may land over a limit.
#
#   scripts/instruction-budget-lint.sh                  lint against the baseline (the gate)
#   scripts/instruction-budget-lint.sh --report         every file's cost, both sets; never fails
#   scripts/instruction-budget-lint.sh --summary        one line: resident total + three largest
#   scripts/instruction-budget-lint.sh --update         rewrite the baseline from current sizes
#   scripts/instruction-budget-lint.sh --baseline-path  print the baseline path (init.sh asks for it)
#
# Baseline: scripts/instruction-budget-baseline.txt
#   "<path> <lines>"     a file over MAX_LINES, grandfathered at that line count
#   "@resident <bytes>"  the resident total, present only while it is over BUDGET
#
# LIMITS, stated so the number is not over-trusted:
#   - `@path` imports inside a CLAUDE.md are not followed; an imported file is not counted.
#   - CLAUDE.md files in subdirectories and in ~/.claude load too and are not counted — this lint
#     measures what the repo root commits.
#   - `paths:` is detected as a top-level frontmatter key. Its globs are not evaluated.
#
# INSTRUCTION_BUDGET_ROOT measures another directory (`cckit status` / `cckit doctor` point the
# kit's copy at the project they are run in). bash 3.2 compatible.
set -uo pipefail

# Bytes, not characters — same reason as skill-frontmatter-lint.sh: a count that changes with the
# locale makes a ratchet fire on files nobody touched. Bytes are >= characters, so measuring bytes
# against a character limit errs toward warning early, never late.
LC_ALL=C
export LC_ALL

ROOT="${INSTRUCTION_BUDGET_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT" || { echo "instruction-budget-lint: cannot enter $ROOT" >&2; exit 1; }

BASELINE="scripts/instruction-budget-baseline.txt"
BUDGET="${KIT_INSTRUCTION_BUDGET:-150000}"
MAX_LINES="${KIT_INSTRUCTION_MAX_LINES:-200}"
TAB="$(printf '\t')"

FAIL=0
err()  { echo "x $1"; FAIL=1; }
ok()   { echo "ok $1"; }
note() { echo "  $1"; }

MODE="${1:-lint}"

# The one place the baseline filename is spelled; init.sh asks rather than reconstructing it.
if [ "$MODE" = "--baseline-path" ]; then
  printf '%s\n' "$BASELINE"
  exit 0
fi

# has_paths <file> — rc 0 when the file opens with a frontmatter block that has a top-level
# `paths:` key. Only a block that starts on line 1 counts: Claude Code reads no other.
has_paths() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    /^paths[ \t]*:/ { found = 1; exit }
    END { exit found ? 0 : 1 }
  ' "$1"
}

baseline_for() {  # <key> → the recorded number, or empty
  [ -f "$BASELINE" ] || { echo ""; return; }
  grep -v '^[[:space:]]*#' "$BASELINE" 2>/dev/null \
    | awk -v k="$1" '{ n = $NF; sub(/[ \t]+[0-9]+[ \t]*$/, ""); if ($0 == k && !hit) { print n; hit = 1 } }'
}

# ---- collect ----------------------------------------------------------------
rows=""   # "<bytes>\t<lines>\t<resident|scoped>\t<path>" per line
resident=0; scoped=0; n_resident=0; n_scoped=0; count=0
add_file() {
  local f="$1" kind="$2" b l
  b="$(wc -c < "$f" | tr -d ' ')"
  l="$(wc -l < "$f" | tr -d ' ')"
  rows="${rows}${b}${TAB}${l}${TAB}${kind}${TAB}${f}
"
  count=$(( count + 1 ))
  if [ "$kind" = resident ]; then
    resident=$(( resident + b )); n_resident=$(( n_resident + 1 ))
  else
    scoped=$(( scoped + b )); n_scoped=$(( n_scoped + 1 ))
  fi
}

for f in CLAUDE.md CLAUDE.local.md .claude/CLAUDE.md; do
  [ -f "$f" ] && add_file "$f" resident
done
if [ -d .claude/rules ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if has_paths "$f"; then add_file "$f" scoped; else add_file "$f" resident; fi
  done < <(find .claude/rules -type f -name '*.md' 2>/dev/null | sort)
fi

pct=0
[ "$BUDGET" -gt 0 ] && pct=$(( resident * 100 / BUDGET ))

# largest_three — "a (n), b (n), c (n)" over the resident set, the files a trim would start with.
largest_three() {
  printf '%s' "$rows" | awk -F'\t' '$3 == "resident"' | sort -t"$TAB" -k1,1nr | sed -n 1,3p \
    | awk -F'\t' '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $4, $1 }'
}

# ---- --summary --------------------------------------------------------------
# One line for `cckit status` and `cckit doctor`. Prints nothing when there is nothing to measure,
# so a caller can omit the line instead of reporting a zero that reads as a measurement.
if [ "$MODE" = "--summary" ]; then
  [ "$count" -gt 0 ] || exit 0
  printf 'instruction files: %s of %s bytes resident (%s%%); largest: %s\n' \
    "$resident" "$BUDGET" "$pct" "$(largest_three)"
  exit 0
fi

if [ "$count" -eq 0 ]; then
  echo "instruction-budget-lint: no CLAUDE.md and no .claude/rules/ — nothing to lint"
  exit 0
fi

# ---- --report ---------------------------------------------------------------
if [ "$MODE" = "--report" ]; then
  for kind in resident scoped; do
    if [ "$kind" = resident ]; then
      echo "resident — loaded into every session"
    else
      echo
      echo "path-scoped — loaded when a file matching \`paths:\` is read"
    fi
    printf '%8s %6s  %s\n' bytes lines file
    printf '%s' "$rows" | awk -F'\t' -v k="$kind" '$3 == k' | sort -t"$TAB" -k1,1nr \
      | while IFS="$TAB" read -r b l _k f; do
          flag=""; [ "$l" -gt "$MAX_LINES" ] && flag="  <- over ${MAX_LINES} lines"
          printf '%8s %6s  %s%s\n' "$b" "$l" "$f" "$flag"
        done
  done
  echo
  flag=""; [ "$resident" -gt "$BUDGET" ] && flag="  <- over the limit"
  echo "resident total: ${resident} of ${BUDGET} bytes (${pct}%), ${n_resident} file(s)${flag}"
  echo "path-scoped: ${scoped} bytes in ${n_scoped} file(s) — what those rules would add to every session without \`paths:\`"
  echo "largest resident: $(largest_three)"
  exit 0
fi

# ---- --update ---------------------------------------------------------------
if [ "$MODE" = "--update" ]; then
  mkdir -p "$(dirname "$BASELINE")"
  {
    echo "# instruction-budget-baseline.txt — generated by scripts/instruction-budget-lint.sh --update"
    echo "# Instruction files over ${MAX_LINES} lines, and the resident total while it is over ${BUDGET} bytes."
    echo "# These are GRANDFATHERED: allowed to stay, but may never grow. Shrink them, scope a rule with"
    echo "# \`paths:\`, or split it into a short rule + a knowledge doc, then re-run --update to tighten."
    echo "#"
    echo "# <path> <lines>   |   @resident <bytes>"
    [ "$resident" -gt "$BUDGET" ] && echo "@resident $resident"
    printf '%s' "$rows" | sort -t"$TAB" -k4,4 | while IFS="$TAB" read -r _b l _k f; do
      [ "$l" -gt "$MAX_LINES" ] && printf '%s %s\n' "$f" "$l"
    done
  } > "$BASELINE"
  echo "ok wrote $BASELINE ($(grep -cv '^[[:space:]]*#' "$BASELINE") grandfathered)"
  exit 0
fi

# ---- lint (the gate) --------------------------------------------------------
over=0
base="$(baseline_for @resident)"
if [ "$resident" -gt "$BUDGET" ]; then
  over=$(( over + 1 ))
  if [ -z "$base" ]; then
    err "resident instruction files total ${resident} bytes, over the ${BUDGET}-byte limit"
    note "every byte loads into EVERY session. Give a rule that covers one kind of file a \`paths:\`"
    note "frontmatter, or split a long rule into a short resident half + a knowledge doc."
    note "see what costs most: scripts/instruction-budget-lint.sh --report"
  elif [ "$resident" -gt "$base" ]; then
    err "resident instruction files grew to ${resident} bytes (baseline ${base}, limit ${BUDGET})"
    note "trim back to ${base} or below, or re-baseline deliberately with --update"
  fi
elif [ -n "$base" ]; then
  note "resident total is now under the limit (${resident}) — run --update to drop @resident from the baseline"
fi

while IFS="$TAB" read -r _b l _k f; do
  [ -n "$f" ] || continue
  base="$(baseline_for "$f")"
  if [ "$l" -le "$MAX_LINES" ]; then
    [ -n "$base" ] && note "$f is now ${l} lines — run --update to drop it from the baseline"
    continue
  fi
  over=$(( over + 1 ))
  if [ -z "$base" ]; then
    err "$f: ${l} lines, over the ${MAX_LINES}-line limit for one instruction file"
    note "split it (a short rule that points at a knowledge doc), or accept it deliberately with:"
    note "scripts/instruction-budget-lint.sh --update"
  elif [ "$l" -gt "$base" ]; then
    err "$f: grew to ${l} lines (baseline ${base}) — an over-long instruction file may not grow"
    note "trim it back to ${base} or below, or re-baseline deliberately with --update"
  fi
done < <(printf '%s' "$rows" | sort -t"$TAB" -k4,4)

if [ "$FAIL" -eq 0 ]; then
  ok "instruction files within budget (${resident} of ${BUDGET} bytes resident in ${n_resident} file(s), ${n_scoped} path-scoped; $over grandfathered)"
fi
exit "$FAIL"
