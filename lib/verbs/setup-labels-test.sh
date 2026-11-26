#!/usr/bin/env bash
# shellcheck shell=bash
# setup-labels-test.sh — `setup-labels.sh --dry-run` lists the kit's whole label set, read from the
# kit's own variables (#639), and writes nothing.
#
#   - every kind in KIT_KINDS, every priority in KIT_PRIORITIES (p0..p3), every ctx bucket in
#     EFFORT_CTX_BUCKETS, every flow in EFFORT_FLOWS (lowercased), the config's roles and agent
#     profiles, and `effort`;
#   - a configured effort.flows[] replaces the default flows;
#   - the descriptions are kit_label_desc's, and the flow and role ones match what `cckit effort new`
#     writes (effort-ops.sh calls the same function; no retired "lane" wording is left);
#   - the installed layout (scripts/setup-labels.sh beside scripts/lib/) finds every set too;
#   - an unknown argument is refused with rc 2.
# Hermetic: a mktemp project, gh is a stub that logs and fails, no network.
# Run:  bash lib/verbs/setup-labels-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/lib/core/test-env.sh" && test_env_seal
fail=0
t()     { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
has()   { case "$2" in *"$3"*) echo "ok: $1" ;; *) echo "FAIL: $1 -> output lacks '[$3]'"; fail=1 ;; esac; }
hasnt() { case "$2" in *"$3"*) echo "FAIL: $1 -> output has '[$3]'"; fail=1 ;; *) echo "ok: $1" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "setup-labels-test: jq absent — skipping (dependency-light gate)"; exit 0; }

tmp="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/proj"
printf '#!/bin/sh\necho "gh $*" >> "%s/gh.log"\nexit 1\n' "$tmp" > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
: > "$tmp/gh.log"
export PATH="$tmp/bin:$PATH" GH_TOKEN=test-token CCKIT_FORGE=github

cat > "$tmp/proj/kit.config.json" <<'JSON'
{ "github": { "repo": "o/r", "owner": "o", "baseBranch": "develop" },
  "roles": ["Backend", "Tech Lead"],
  "agents": { "profiles": { "review": {} } } }
JSON

# The kit's own sets, read the way setup-labels reads them.
# shellcheck source=/dev/null
. "$ROOT/lib/core/kinds.sh"
EFFORT_CTX_BUCKETS="$(sed -n 's/^EFFORT_CTX_BUCKETS="\(.*\)"$/\1/p' "$ROOT/lib/core/effort-metrics.sh")"
default_flows="$(sed -n 's/^EFFORT_FLOWS="\${EFFORT_FLOWS:-\(.*\)}"$/\1/p' "$ROOT/lib/core/effort.sh")"
t "the ctx scale is S M L XL" "$EFFORT_CTX_BUCKETS" "S M L XL"
t "the priority set is p0..p3" "$KIT_PRIORITIES" "p0 p1 p2 p3"

names() { cut -f1 | tr '\n' ' ' | sed 's/ *$//'; }
run() { ( cd "$tmp/proj" && KIT_CONFIG="$tmp/proj/kit.config.json" bash "$@" 2>/dev/null ); }

out="$(run "$ROOT/lib/verbs/setup-labels.sh" --dry-run)"; rc=$?
t "dry run exits 0" "$rc" "0"
got="$(printf '%s\n' "$out" | names)"
for k in $KIT_KINDS;          do has "lists kind:$k"     " $got " " kind:$k "; done
for p in $KIT_PRIORITIES;     do has "lists priority:$p" " $got " " priority:$p "; done
for c in $EFFORT_CTX_BUCKETS; do has "lists ctx:$c"      " $got " " ctx:$c "; done
for f in $default_flows; do
  f_lc="$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')"
  has "lists flow:$f_lc" " $got " " flow:$f_lc "
done
has "lists effort"            " $got " " effort "
has "lists backlog (#647)"     " $got " " backlog "
has "lists the config roles"  " $got " " role:backend role:tech-lead "
has "lists the agent profile" " $got " " agent:review "
hasnt "content kinds stay off by default" " $got " " kind:post "
t "dry run writes nothing (gh never called)" "$(wc -l < "$tmp/gh.log" | tr -d ' ')" "0"
t "every line is name<TAB>color<TAB>description" \
  "$(printf '%s\n' "$out" | awk -F'\t' 'NF != 3 || $3 == ""' | wc -l | tr -d ' ')" "0"

# Descriptions come from kit_label_desc — the same call effort-ops.sh makes.
row() { printf '%s\n' "$out" | awk -F'\t' -v n="$1" '$1 == n {print $3}'; }
t "flow description"     "$(row flow:core)"   "$(kit_label_desc flow core)"
t "flow says what it is" "$(row flow:core)"   "Flow: an area of the product"
t "role description"     "$(row role:backend)" "$(kit_label_desc role backend)"
t "priority p0 description" "$(row priority:p0)" "Drop everything"
t "ctx description"      "$(row ctx:XL)"      "$(kit_label_desc ctx XL)"
t "backlog description"  "$(row backlog)"     "$(kit_label_desc backlog)"
t "backlog description names the no-board case" "$(row backlog | grep -c "no board")" "1"
t "effort-ops describes labels through kit_label_desc" \
  "$(grep -c '_eff_ensure_label .*"\$(kit_label_desc ' "$ROOT/lib/verbs/effort-ops.sh" | tr -d ' ')" "8"
t "effort-ops has no retired lane wording" \
  "$(grep -c '_eff_ensure_label .*lane' "$ROOT/lib/verbs/effort-ops.sh" | tr -d ' ')" "0"

# A configured effort.flows[] replaces the default flows.
jq '.effort = {flows: ["Billing", "Mobile"]}' "$tmp/proj/kit.config.json" > "$tmp/proj/flows.json"
got="$( ( cd "$tmp/proj" && KIT_CONFIG="$tmp/proj/flows.json" bash "$ROOT/lib/verbs/setup-labels.sh" --dry-run 2>/dev/null ) \
  | names | tr ' ' '\n' | grep '^flow:' | tr '\n' ' ' | sed 's/ *$//')"
t "configured flows replace the default" "$got" "flow:billing flow:mobile"

# kinds.content on adds the content kinds.
jq '.kinds = {content: true}' "$tmp/proj/kit.config.json" > "$tmp/proj/content.json"
got="$( ( cd "$tmp/proj" && KIT_CONFIG="$tmp/proj/content.json" bash "$ROOT/lib/verbs/setup-labels.sh" --dry-run 2>/dev/null ) | names)"
for k in $KIT_CONTENT_KINDS; do has "content on lists kind:$k" " $got " " kind:$k "; done

# The installed layout: scripts/setup-labels.sh beside scripts/lib/.
mkdir -p "$tmp/inst/scripts/lib"
cp "$ROOT/lib/verbs/setup-labels.sh" "$tmp/inst/scripts/"
for f in kit-config.sh config-path.sh effort.sh kinds.sh effort-metrics.sh; do
  [ -f "$ROOT/lib/core/$f" ] && cp "$ROOT/lib/core/$f" "$tmp/inst/scripts/lib/"
done
for f in "$ROOT"/lib/forge/*.sh "$ROOT"/lib/core/*.sh; do
  [ -f "$tmp/inst/scripts/lib/$(basename "$f")" ] || cp "$f" "$tmp/inst/scripts/lib/"
done
inst="$(run "$tmp/inst/scripts/setup-labels.sh" --dry-run | names)"
t "installed layout lists the same labels" "$inst" "$(printf '%s\n' "$out" | names)"

# An unknown argument is refused before anything runs.
( cd "$tmp/proj" && KIT_CONFIG="$tmp/proj/kit.config.json" bash "$ROOT/lib/verbs/setup-labels.sh" --bogus >/dev/null 2>&1 ); rc=$?
t "unknown argument -> rc 2" "$rc" "2"

[ "$fail" -eq 0 ] && echo "ALL OK (setup-labels)" || echo "setup-labels: FAILURES"
exit "$fail"
