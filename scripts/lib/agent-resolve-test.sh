#!/usr/bin/env bash
# agent-resolve-test.sh — the profile RESOLUTION precedence contract (#319).
#
# Hermetic: the precedence walk takes label strings as arguments, so nothing here calls gh or the
# network. That is the reason ap_resolve is pure and ap_labels_fetch is a separate, thin helper.
# Run:  bash scripts/lib/agent-resolve-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion
# shellcheck shell=bash
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/scripts/lib/agent-resolve.sh"

command -v jq >/dev/null 2>&1 || { echo "agent-resolve-test: jq absent — skipping"; exit 0; }

fail=0
t()  { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }
rc() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> rc '[$2]' want '[$3]'"; fail=1; fi; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
CFG="$tmp/kit.config.json"
cat > "$CFG" <<'JSON'
{
  "agents": {
    "default": "build",
    "profiles": {
      "build":  { "kind": "claude", "stages": ["build"],  "write": true },
      "review": { "kind": "codex",  "stages": ["review"] },
      "both":   { "kind": "claude", "stages": ["build", "review"] }
    }
  }
}
JSON

# ── label parsing ──────────────────────────────────────────────────────────────────────────────
t "reads an agent: label"              "$(ap_profile_from_labels 'agent:review,priority:p1')" "review"
t "label order does not matter"        "$(ap_profile_from_labels 'priority:p1,agent:review')" "review"
t "newline-separated labels work"      "$(printf 'ctx:M\nagent:build' | { read -r a; read -r b; ap_profile_from_labels "$a,$b"; })" "build"
t "surrounding spaces are trimmed"     "$(ap_profile_from_labels ' agent:build , ctx:M ')" "build"
t "no agent: label yields empty"       "$(ap_profile_from_labels 'priority:p1,ctx:M')" ""
t "empty label set yields empty"       "$(ap_profile_from_labels '')" ""
t "a bare 'agent:' is not a profile"   "$(ap_profile_from_labels 'agent:')" ""
t "the same label twice is not ambiguous" "$(ap_profile_from_labels 'agent:build,agent:build')" "build"

# Two DIFFERENT agent labels must refuse, not pick one — a silent pick runs an unchosen agent.
ap_profile_from_labels 'agent:build,agent:review' >/dev/null 2>&1
rc "two different agent labels are ambiguous" "$?" "2"

# ── parent effort number ───────────────────────────────────────────────────────────────────────
t "parent number from a sub title"  "$(ap_parent_effort_num '[Effort 318] 3 · resolve profiles')" "318"
t "standalone issue has no parent"  "$(ap_parent_effort_num 'fix: a plain bug')" ""
t "an umbrella title is not a sub"  "$(ap_parent_effort_num '[Effort] 318 · agents by profile')" ""

# ── precedence: override > issue > parent > default ────────────────────────────────────────────
t "override wins over everything"  "$(ap_resolve "$CFG" build 'both' 'agent:review' 'agent:review' 2>/dev/null)" "both"
t "issue label beats parent label" "$(ap_resolve "$CFG" review '' 'agent:review' 'agent:both' 2>/dev/null)" "review"
t "parent label beats the default" "$(ap_resolve "$CFG" review '' '' 'agent:review' 2>/dev/null)" "review"
t "default applies when nothing else does" "$(ap_resolve "$CFG" build '' '' '' 2>/dev/null)" "build"

t "source: override"      "$(ap_resolve_source "$CFG" 'both' 'agent:review' '')" "command override"
t "source: issue label"   "$(ap_resolve_source "$CFG" '' 'agent:review' 'agent:both')" "issue label"
t "source: parent label"  "$(ap_resolve_source "$CFG" '' '' 'agent:review')" "parent effort label"
t "source: the default"   "$(ap_resolve_source "$CFG" '' '' '')" "agents.default"

# ── the resolved name is validated against the stage before it is returned ─────────────────────
# review is stages:[review], so resolving it for `build` must fail even though the label is explicit.
ap_resolve "$CFG" build '' 'agent:review' '' >/dev/null 2>&1
rc "a label naming a profile barred from the stage is refused" "$?" "2"
ap_resolve "$CFG" build 'ghost' '' '' >/dev/null 2>&1
rc "an override naming an undeclared profile is refused" "$?" "2"
ap_resolve "$CFG" build '' 'agent:build,agent:review' '' >/dev/null 2>&1
rc "ambiguity propagates out of resolve" "$?" "2"
t "a profile listing both stages resolves at either" "$(ap_resolve "$CFG" review 'both' '' '' 2>/dev/null)" "both"

# The refusal must say which precedence level supplied the bad name.
case "$(ap_resolve "$CFG" build '' 'agent:review' '' 2>&1 >/dev/null)" in
  *"issue label"*) echo "ok: the refusal names the precedence level" ;;
  *) echo "FAIL: the refusal does not name the precedence level"; fail=1 ;;
esac

# ── nothing resolves at all ────────────────────────────────────────────────────────────────────
# With no agents.default, level 4 is the CHEAPEST declared profile, not a failure — an
# unconfigured project runs the inexpensive path rather than refusing.
cat > "$tmp/nodefault.json" <<'JSON'
{ "agents": { "profiles": {
  "spendy":  { "kind": "claude", "tier": "high", "stages": ["build"] },
  "thrifty": { "kind": "claude", "tier": "low",  "stages": ["build"] }
} } }
JSON
t "no override/label/default resolves to the CHEAPEST profile" "$(ap_resolve "$tmp/nodefault.json" build '' '' '' 2>/dev/null)" "thrifty"
# Only a config declaring NO profiles at all resolves nothing.
echo '{}' > "$tmp/empty.json"
ap_resolve "$tmp/empty.json" build '' '' '' >/dev/null 2>&1
rc "a config with no profiles at all is rc 4" "$?" "4"

# A dangling agents.default must still refuse through the resolver, not fall through to rc 4.
cat > "$tmp/dangling.json" <<'JSON'
{ "agents": { "default": "missing", "profiles": { "b": { "kind": "claude", "stages": ["build"] } } } }
JSON
ap_resolve "$tmp/dangling.json" build '' '' '' >/dev/null 2>&1
rc "a dangling default refuses rather than resolving nothing" "$?" "2"

# ── the impure helper degrades instead of dying ────────────────────────────────────────────────
t "labels_fetch with no args is empty" "$(ap_labels_fetch)" ""
t "labels_fetch with no issue is empty" "$(ap_labels_fetch 'o/r')" ""

[ "$fail" -eq 0 ] && echo "agent-resolve-test: PASS" || echo "agent-resolve-test: FAILED"
exit "$fail"
