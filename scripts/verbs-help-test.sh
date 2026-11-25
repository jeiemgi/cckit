#!/usr/bin/env bash
# shellcheck shell=bash
# verbs-help-test.sh — #556: every verb has help. `cckit <verb> --help` is answered by the dispatcher
# from lib/core/verbs.tsv before the verb runs, so it exits 0, starts with the verb's usage, names
# its question and its prompt, and never reaches a parser that rejects --help. Runs every verb in a
# throwaway git repo with a stub `gh` that refuses everything, then checks the repo is untouched.
# No network, no port.
# Run:  bash scripts/verbs-help-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
t()   { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
CCKIT="$ROOT/bin/cckit"
# shellcheck source=/dev/null
source "$ROOT/lib/core/verbs.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub" "$tmp/repo" "$tmp/home"
printf '#!/bin/sh\necho "gh $*" >> "%s/gh.log"\nexit 1\n' "$tmp" > "$tmp/stub/gh"; chmod +x "$tmp/stub/gh"
git -C "$tmp/repo" init -q
git -C "$tmp/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
before="$(cd "$tmp/repo" && git status --porcelain --ignored; ls -A)"

run_help() { (cd "$tmp/repo" && PATH="$tmp/stub:$PATH" HOME="$tmp/home" GH_TOKEN= "$CCKIT" "$@" </dev/null 2>&1); }

# ── 1. every verb answers --help from the table ────────────────────────────────────────────────
for v in $(verbs_names verb default); do
  out="$(run_help "$v" --help)"; rc=$?
  bad=""
  [ "$rc" -eq 0 ] || bad="$bad rc=$rc"
  first_usage="$(verbs_get "$v" 10 | awk -F'\\\\n' '{ print $1 }')"
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "$first_usage" ] || bad="$bad first-line"
  grep -qF "  Answers: $(verbs_get "$v" 8)" <<<"$out" || bad="$bad no-question"
  grep -qF "  Paste:   \"$(verbs_get "$v" 9)\"" <<<"$out" || bad="$bad no-prompt"
  grep -qF '  Needs:   ' <<<"$out" || bad="$bad no-needs"
  grep -qiE 'unknown (flag|option|command)' <<<"$out" && bad="$bad unknown-flag"
  t "cckit $v --help: rc 0, usage first, question, prompt, needs" "$bad" ""
done

# ── 2. -h and `cckit help <verb>` are the same answer ─────────────────────────────────────────
t "cckit merge -h is cckit merge --help" "$(run_help merge -h)" "$(run_help merge --help)"
t "cckit help start is cckit start --help" "$(run_help help start)" "$(run_help start --help)"
run_help help no-such-verb >/dev/null; t "cckit help <unknown> exits 2" "$?" "2"

# ── 3. a verb with its own help keeps it, under Details ───────────────────────────────────────
for v in $(verbs_rows | awk -F'\t' '$2 == "verb" && $7 == "yes" { print $1 }'); do
  out="$(run_help "$v" --help)"
  t "cckit $v --help prints its own help under Details" "$(printf '%s\n' "$out" | grep -c '^Details:$')" "1"
done

# ── 4. no verb did any work: the repo is untouched and the forge was never written to ─────────
t "help left the repo untouched" "$(cd "$tmp/repo" && git status --porcelain --ignored; ls -A)" "$before"
writes="$(grep -vE '^gh (auth (token|status)|--version)' "$tmp/gh.log" 2>/dev/null)"
t "help made no forge call beyond reading the token" "$writes" ""

# ── 5. a verb with no entry fails the check ───────────────────────────────────────────────────
printf 'g\tgroup\t-\t-\t-\t-\t-\tWhat?\t-\t-\nnoentry\talias\tnone\t-\tgit\t-\t-\t-\t-\t-\n' > "$tmp/v.tsv"
VERBS_FILE="$tmp/v.tsv" verbs_entry noentry >/dev/null; t "fixture: verbs_entry on a name with no entry rc 1" "$?" "1"

[ "$fail" -eq 0 ] && echo "ALL OK (verbs-help)" || echo "verbs-help: FAILURES"
exit "$fail"
