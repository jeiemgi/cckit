#!/usr/bin/env bash
# shellcheck shell=bash
# upgrade-report.sh — what `cckit init --upgrade` changed on disk, measured, not narrated (#448).
#
# The upgrade's own bookkeeping (added / preserved / refreshed) is filled in by the write helpers,
# and a file a later step merges into (`.claude/settings.json`, the config) was reported as
# preserved while its bytes changed. The dry run printed a hand-kept list of everything the kit
# could ever write. Both are replaced by ONE measurement: checksum the kit-managed paths before and
# after, and print the difference. The dry run takes the same measurement on a temporary copy.
#
#   upgrade_snapshot <dir>                 -> "<path>\t<crc>:<bytes>" per file, sorted by path
#   upgrade_changes <before> <after>       -> "A\t<path>" / "M\t<path>" / "D\t<path>", sorted by path
#   upgrade_changes_print <changes> <head> -> the block both the dry run and the real run print
#   upgrade_dry_run <target> <init.sh> <args…>
#                                          -> runs the real upgrade on a copy; prints the block
#   json_write_minimal <merged> <file>     -> replace <file> by <merged> with the fewest changed lines
#
# Runs under bash 3.2 and zsh: no word-splitting of a variable, no arrays indexed from 0.
# errors: mixed — upgrade_snapshot / upgrade_changes / upgrade_changes_print always return 0 (an
# unreadable dir is an empty snapshot); upgrade_dry_run returns the simulated run's rc; json_write_minimal
# returns non-zero only when the final write fails.

# The paths an upgrade can write under. `.claude/worktrees` (other checkouts), `node_modules` and
# `.git` are never the kit's, so they are pruned from both the snapshot and the dry-run copy.
_upgrade_roots() {
  printf '%s\n' .claude .codex .agents .cckit scripts knowledge benchmarks \
    CLAUDE.md AGENTS.md .gitignore cckit.config.json
}

upgrade_snapshot() {  # <dir>
  ( cd "$1" 2>/dev/null || exit 0
    _upgrade_roots | while IFS= read -r _ur; do
      [ -e "$_ur" ] || continue
      find "$_ur" \( -name worktrees -o -name node_modules -o -name .git \) -prune -o -type f -print0
    done | xargs -0 cksum /dev/null 2>/dev/null \
      | sed -n 's/^\([0-9][0-9]*\) \([0-9][0-9]*\) \(.*\)$/\3	\1:\2/p' \
      | grep -v '^/dev/null	' | LC_ALL=C sort ) || true
}

upgrade_changes() {  # <before-file> <after-file>
  awk -F'\t' '
    NR == FNR { b[$1] = $2; next }
    { seen[$1] = 1 }
    !($1 in b) { print "A\t" $1; next }
    b[$1] != $2 { print "M\t" $1 }
    END { for (p in b) if (!(p in seen)) print "D\t" p }
  ' "$1" "$2" | LC_ALL=C sort -t'	' -k2
}

upgrade_changes_print() {  # <changes-file> <heading>
  local a m d
  a="$(grep -c '^A	' "$1" 2>/dev/null || true)"; m="$(grep -c '^M	' "$1" 2>/dev/null || true)"
  d="$(grep -c '^D	' "$1" 2>/dev/null || true)"
  printf '  %s (%s added, %s modified' "$2" "${a:-0}" "${m:-0}"
  [ "${d:-0}" -gt 0 ] && printf ', %s deleted' "$d"
  printf '):\n'
  if [ -s "$1" ]; then sed 's/^\(.\)	/    \1 /' "$1"; else printf '    (nothing)\n'; fi
}

# upgrade_dry_run — the dry run of an upgrade IS the upgrade, run on a copy.
# Copies the kit-managed paths of <target> into a temp dir of the same basename, runs init.sh there
# with the caller's own flags (minus --dry-run, plus --force: the copy has no git history to guard),
# and prints the before/after difference. <target> is never written. rc = the simulated run's rc.
upgrade_dry_run() {  # <target> <init.sh> <args…>
  local target="$1" init="$2" tmp copy a rc=0 r
  shift 2
  tmp="$(mktemp -d)" || return 1
  copy="$tmp/$(basename "$target")"
  mkdir -p "$copy" || { rm -rf "$tmp"; return 1; }
  copy="$(cd "$copy" && pwd)"
  _upgrade_roots | while IFS= read -r r; do
    [ -e "$target/$r" ] || continue
    ( cd "$target" && tar -cf - --exclude 'worktrees' --exclude 'node_modules' --exclude '.git' "$r" ) \
      | ( cd "$copy" && tar -xf - )
  done
  # Absolute paths the project recorded (hook commands in settings.local.json, project.path) name
  # <target>. Point them at the copy, so the simulated run sees a project that is consistent with
  # where it lives — otherwise a registration it would recognise looks foreign and is added twice.
  grep -rlF -- "$target" "$copy" 2>/dev/null | while IFS= read -r r; do
    FROM="$target" TO="$copy" perl -pi -e 's/\Q$ENV{FROM}\E/$ENV{TO}/g' "$r" 2>/dev/null
  done
  upgrade_snapshot "$copy" > "$tmp/before"
  set -- "$@" --target "$copy" --force
  local n=$# i=0
  while [ "$i" -lt "$n" ]; do
    a="$1"; shift; i=$((i + 1))
    [ "$a" = "--dry-run" ] || set -- "$@" "$a"
  done
  KIT_UPGRADE_SIMULATED=1 bash "$init" "$@" > "$tmp/out" 2>&1 </dev/null || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '  x the simulated upgrade failed (exit %s) — nothing was written to %s. Its output:\n' "$rc" "$target" >&2
    sed "s|$copy|$target|g; s/^/    /" "$tmp/out" >&2
    rm -rf "$tmp"; return "$rc"
  fi
  upgrade_snapshot "$copy" > "$tmp/after"
  upgrade_changes "$tmp/before" "$tmp/after" > "$tmp/changes"
  upgrade_changes_print "$tmp/changes" "Would change"
  rm -rf "$tmp"
  return 0
}

# json_write_minimal — write <merged> over <file> changing as few lines as the change needs.
# jq re-serialises a whole document: a one-key change rewrote every line whose formatting differed
# from jq's (inline arrays expanded, 66 changed lines for a `kitVersion` bump). So:
#   - same value as <file> already holds  -> <file> is not touched            (prints "unchanged")
#   - only top-level string keys differ   -> each is replaced in place, by text (prints "in-place")
#   - anything else                       -> <merged> replaces <file>          (prints "rewritten")
# The in-place result is re-parsed and compared with <merged>; on any difference it falls back to
# "rewritten", so the file always ends up holding exactly <merged>'s value. <merged> is consumed.
json_write_minimal() {  # <merged-file> <file>
  local merged="$1" file="$2" keys k v tmp
  if [ ! -f "$file" ]; then mv "$merged" "$file" && echo rewritten; return; fi
  if jq -e -n --slurpfile a "$merged" --slurpfile b "$file" '$a[0] == $b[0]' >/dev/null 2>&1; then
    rm -f "$merged"; echo unchanged; return 0
  fi
  # Top-level keys present in both, strings in both, whose value differs — and nothing else differs.
  keys="$(jq -r -n --slurpfile a "$merged" --slurpfile b "$file" '
    $a[0] as $m | $b[0] as $h
    | [ $m | keys_unsorted[] | select($m[.] != $h[.]) ] as $diff
    | if ($m | keys) == ($h | keys)
         and ($diff | all(. as $k | ($m[$k] | type) == "string" and ($h[$k] | type) == "string"))
      then $diff[] else empty end' 2>/dev/null || true)"
  if [ -n "$keys" ] && command -v perl >/dev/null 2>&1; then
    tmp="$file.kit-inplace"
    cp "$file" "$tmp"
    printf '%s\n' "$keys" | while IFS= read -r k; do
      v="$(jq -n --slurpfile a "$merged" --arg k "$k" '$a[0][$k]')"   # JSON-encoded, quotes included
      K="$k" V="$v" perl -0777 -i -pe '
        my ($k, $v) = ($ENV{K}, $ENV{V});
        s/("\Q$k\E"\s*:\s*)"(?:[^"\\]|\\.)*"/$1.$v/e;' "$tmp"
    done
    if jq -e -n --slurpfile a "$merged" --slurpfile b "$tmp" '$a[0] == $b[0]' >/dev/null 2>&1; then
      mv "$tmp" "$file" && rm -f "$merged"; echo in-place; return 0
    fi
    rm -f "$tmp"
  fi
  mv "$merged" "$file" && echo rewritten
}
