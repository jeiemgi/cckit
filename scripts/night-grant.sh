#!/usr/bin/env bash
#
# night-grant.sh — read the owner's night grant and turn it into scripts/night-run.mjs args.
#
# The brake on an unattended run is a per-night token budget the owner writes; the waivers are a
# standing base plus per-night additions; some floors can never be waived; the run stops when the
# waves are merged and the gate is green, or when an optional stopCommand passes.
#
# THE GRANT is ONE comment on the plan parent issue:
#
#   <!-- night-grant -->
#   Tonight: run the two approved waves; I accept the lockfile floor.
#
#   ```json
#   { "budget": "+2000k", "waves": [[12],[15]], "waivers": ["lockfile"], "stopCommand": null }
#   ```
#
# The latest comment starting with the marker wins.
#
# FLOORS. The base vocabulary below matches the engine's BASE_FLOORS / BASE_NEVER_WAIVABLE
# (scripts/night-run.mjs). A project adds its own in the kit config (cckit.config.json, or
# .claude/kit.config.json):
#
#   "night": { "floors": { "auth-dep": "the auth library version" },
#              "neverWaivable": ["auth-dep"], "gate": "pnpm typecheck && pnpm lint" }
#
# A bad grant is refused here, before launch, instead of at 3 a.m.; the engine still refuses a
# never-waivable floor on its own.
#
# Usage:
#   scripts/night-grant.sh read <issue>     print the engine args JSON, then `budget=+N`
#   scripts/night-grant.sh parse            same, from a comment body on stdin
#   scripts/night-grant.sh preflight [<settings.json>]
#                                           report allowlist entries an unattended run lacks
#   scripts/night-grant.sh --selftest       offline fixture test (no gh, no network)
#
# bash 3.2 / zsh safe; needs jq.

NIGHT_GRANT_MARKER='<!-- night-grant -->'
NIGHT_GRANT_BASE_FLOORS='lockfile auth security-code security-prose workflows cost secret'
NIGHT_GRANT_BASE_NEVER='workflows cost secret'
NIGHT_GRANT_REQUIRED_ALLOW='Bash(gh pr merge:*)
Bash(git push:*)
Bash(gh issue comment:*)
Bash(gh issue edit:*)
Bash(gh issue close:*)
Bash(gh api:*)'

_ng_err() { printf 'night-grant: %s\n' "$*" >&2; }

_ng_in_list() { # <word> <space-separated list>
  case " $2 " in *" $1 "*) return 0 ;; esac
  return 1
}

# _ng_night_cfg — the kit config's `night` object as compact JSON, or {} when there is none.
# NIGHT_GRANT_CONFIG overrides the lookup (a path; a missing file reads as {}).
_ng_night_cfg() {
  local f="${NIGHT_GRANT_CONFIG:-}" top
  if [ -z "$f" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=.
    if [ -f "$top/cckit.config.json" ]; then f="$top/cckit.config.json"
    else f="$top/.claude/kit.config.json"; fi
  fi
  [ -f "$f" ] || { printf '{}\n'; return 0; }
  jq -c '(.night // {}) | if type == "object" then . else {} end' "$f" 2>/dev/null || printf '{}\n'
}

# night_grant_parse — stdin: a comment body. stdout: line 1 the engine args JSON
# `{"waves":…,"grant":{"waivers":…,"stopCommand":…}}`, line 2 `budget=+N`. Exit 1 on a refused grant.
night_grant_parse() {
  local body block json budget w bad
  local cfg floors never
  cfg="$(_ng_night_cfg)"
  floors="$NIGHT_GRANT_BASE_FLOORS $(printf '%s' "$cfg" | jq -r '(.floors // {}) | keys[]' | tr '\n' ' ')"
  never="$NIGHT_GRANT_BASE_NEVER $(printf '%s' "$cfg" | jq -r '(.neverWaivable // [])[]' | tr '\n' ' ')"
  body="$(cat | tr -d '\r')"
  case "$body" in
    "$NIGHT_GRANT_MARKER"*) ;;
    *) _ng_err "not a grant: the comment must start with $NIGHT_GRANT_MARKER"; return 1 ;;
  esac
  block="$(printf '%s\n' "$body" | awk '
    !inb && /^```json[[:space:]]*$/ { inb = 1; next }
    inb && /^```[[:space:]]*$/ { exit }
    inb { print }
  ')"
  if [ -z "$block" ]; then _ng_err 'no ```json block in the grant'; return 1; fi
  if ! json="$(printf '%s' "$block" | jq -c . 2>/dev/null)" || [ -z "$json" ]; then
    _ng_err 'the ```json block is not valid JSON'; return 1
  fi
  if [ "$(printf '%s' "$json" | jq -r 'type')" != object ]; then
    _ng_err 'the ```json block must be an object'; return 1
  fi

  budget="$(printf '%s' "$json" | jq -r 'if (.budget|type) == "string" then .budget else "" end')"
  if ! printf '%s' "$budget" | grep -Eq '^\+[1-9][0-9]*[kM]?$'; then
    _ng_err "budget missing or malformed (want +<number>[k|M], e.g. +2000k): '${budget}'"; return 1
  fi

  if ! printf '%s' "$json" | jq -e '
      (.waves | type) == "array" and (.waves | length) > 0 and
      all(.waves[]; type == "array" and length > 0 and
          all(.[]; type == "number" and . == floor and . > 0))' >/dev/null 2>&1; then
    _ng_err 'waves must be a non-empty array of non-empty arrays of issue numbers'; return 1
  fi

  if ! printf '%s' "$json" | jq -e '(.waivers // []) | type == "array" and all(.[]; type == "string")' \
      >/dev/null 2>&1; then
    _ng_err 'waivers must be an array of floor names'; return 1
  fi
  bad=''
  for w in $(printf '%s' "$json" | jq -r '(.waivers // [])[]'); do
    if _ng_in_list "$w" "$never"; then
      _ng_err "refused: '$w' is never waivable — remove it from the grant"
      return 1
    fi
    _ng_in_list "$w" "$floors" || bad="$bad $w"
  done
  if [ -n "$bad" ]; then
    _ng_err "unknown waiver(s):$bad — the floors are: $floors"; return 1
  fi

  if ! printf '%s' "$json" | jq -e '(.stopCommand // null) | . == null or (type == "string" and length > 0)' \
      >/dev/null 2>&1; then
    _ng_err 'stopCommand must be null or a non-empty string'; return 1
  fi

  printf '%s' "$json" | jq -c --argjson cfg "$cfg" '{waves: .waves}
    + (if ($cfg.gate | type) == "string" then {gate: $cfg.gate} else {} end)
    + {grant: {waivers: ((.waivers // []) | unique), stopCommand: (.stopCommand // null),
               extraFloors: ($cfg.floors // {}), neverWaivable: ($cfg.neverWaivable // [])}}'
  printf 'budget=%s\n' "$budget"
}

# night_grant_pick — stdin: a JSON array of comment bodies, oldest first. stdout: the latest body
# that starts with the marker. Exit 1 when none does.
night_grant_pick() {
  local picked
  picked="$(jq -r --arg m "$NIGHT_GRANT_MARKER" \
    '[.[] | select(type == "string") | select(gsub("\r"; "") | startswith($m))] | last // empty' \
    2>/dev/null)"
  if [ -z "$picked" ]; then _ng_err "no comment starts with $NIGHT_GRANT_MARKER"; return 1; fi
  printf '%s\n' "$picked"
}

# night_grant_read <issue> — fetch the issue's comments, pick the latest grant, parse it.
night_grant_read() {
  local issue="${1:-}" bodies picked
  case "$issue" in ''|*[!0-9]*) _ng_err 'usage: night_grant_read <issue-number>'; return 2 ;; esac
  if ! bodies="$(gh api --paginate "repos/{owner}/{repo}/issues/$issue/comments" --jq '.[].body | @json' \
      < /dev/null)"; then
    _ng_err "could not read the comments of #$issue"; return 1
  fi
  picked="$(printf '%s\n' "$bodies" | jq -s . | night_grant_pick)" || return 1
  printf '%s\n' "$picked" | night_grant_parse
}

# night_grant_preflight [<settings.json>] — report what the TRACKED settings allowlist lacks for an
# unattended run. Exit 1 when anything is missing. Never edits the file.
night_grant_preflight() {
  local file="${1:-}" top allow req prefix missing=0
  if [ -z "$file" ]; then
    top="$(git rev-parse --show-toplevel 2>/dev/null)" || { _ng_err 'not in a git checkout'; return 2; }
    file="$top/.claude/settings.json"
  fi
  if [ ! -f "$file" ]; then _ng_err "no settings file at $file"; return 2; fi
  if ! allow="$(jq -r '(.permissions.allow // [])[]' "$file" 2>/dev/null)"; then
    _ng_err "unreadable settings file $file"; return 2
  fi
  while IFS= read -r req; do
    [ -n "$req" ] || continue
    prefix="${req#"Bash("}"; prefix="${prefix%":*)"}"
    if _ng_allow_covers "$prefix" "$allow"; then
      printf '  ok      %s\n' "$req"
    else
      printf '  MISSING %s\n' "$req"; missing=$((missing + 1))
    fi
  done <<EOF
$NIGHT_GRANT_REQUIRED_ALLOW
EOF
  if [ "$missing" -gt 0 ]; then
    printf 'night-grant preflight: %s allowlist entr%s missing in %s (add them by hand; this never edits it)\n' \
      "$missing" "$( [ "$missing" -eq 1 ] && echo y || echo ies)" "$file"
    return 1
  fi
  printf 'night-grant preflight: OK (%s)\n' "$file"
}

# _ng_allow_covers <command-prefix> <allow-list, one per line> — true when an entry allows it:
# `Bash`, `Bash(*)`, or `Bash(<p>:*)` / `Bash(<p> *)` where the command starts with <p> on a word.
_ng_allow_covers() {
  local cmd="$1" entry p
  while IFS= read -r entry; do
    case "$entry" in
      Bash|'Bash(*)') return 0 ;;
      'Bash('*':*)') p="${entry#"Bash("}"; p="${p%":*)"}" ;;
      'Bash('*' *)') p="${entry#"Bash("}"; p="${p%" *)"}" ;;
      *) continue ;;
    esac
    case "$cmd" in "$p"|"$p "*) return 0 ;; esac
  done <<EOF
$2
EOF
  return 1
}

# ── selftest (offline) ────────────────────────────────────────────────────────────────────────
night_grant_selftest() {
  local fails=0 out st tmp cfg
  NIGHT_GRANT_CONFIG="${TMPDIR:-/tmp}/night-grant-no-config-$$.json"; export NIGHT_GRANT_CONFIG
  _t() { # <label> <want> <got>
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
  }
  _grant() { # <json> — a grant comment around a json block
    printf '%s\nTonight: two waves.\n\n```json\n%s\n```\n' "$NIGHT_GRANT_MARKER" "$1"
  }

  # parse — the happy path
  out="$(_grant '{"budget":"+2000k","waves":[[12],[15]],"waivers":["lockfile"],"stopCommand":null}' \
    | night_grant_parse 2>/dev/null)"; st=$?
  _t "parse: a valid grant exits 0" 0 "$st"
  _t "parse: line 1 is the engine args" \
    '{"waves":[[12],[15]],"grant":{"waivers":["lockfile"],"stopCommand":null,"extraFloors":{},"neverWaivable":[]}}' \
    "$(printf '%s\n' "$out" | sed -n 1p)"
  _t "parse: line 2 is the budget" 'budget=+2000k' "$(printf '%s\n' "$out" | sed -n 2p)"

  out="$(_grant '{"budget":"+3M","waves":[[1,2]],"stopCommand":"pnpm typecheck"}' \
    | night_grant_parse 2>/dev/null | sed -n 1p)"
  _t "parse: absent waivers -> [] and stopCommand kept" \
    '{"waves":[[1,2]],"grant":{"waivers":[],"stopCommand":"pnpm typecheck","extraFloors":{},"neverWaivable":[]}}' "$out"

  # parse — refusals
  _grant '{"waves":[[1]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: no budget is refused" 1 "$st"
  _grant '{"budget":"2000k","waves":[[1]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: budget without + is refused" 1 "$st"
  _grant '{"budget":"+2000G","waves":[[1]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: budget with a unit other than k|M is refused" 1 "$st"
  _grant '{"budget":"+10k","waves":[]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: empty waves is refused" 1 "$st"
  _grant '{"budget":"+10k","waves":[[1],[]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: an empty wave is refused" 1 "$st"
  _grant '{"budget":"+10k","waves":[["12"]]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a non-integer issue is refused" 1 "$st"
  _grant '{"budget":"+10k","waves":[[1]],"waivers":["lockfle"]}' | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a waiver outside the floor vocabulary is refused" 1 "$st"
  out="$(_grant '{"budget":"+10k","waves":[[1]],"waivers":["lockfile","cost"]}' \
    | night_grant_parse 2>&1 >/dev/null)"; st=$?
  _t "parse: a never-waivable waiver is refused" 1 "$st"
  case "$out" in *cost*'never waivable'*) out=named ;; esac
  _t "parse: the refusal names the never-waivable floor" named "$out"

  # parse — floors and gate the project declares in its kit config
  cfg="$NIGHT_GRANT_CONFIG.fixture"
  printf '%s' '{"night":{"floors":{"auth-dep":"the auth library","build-config":"the build config"},"neverWaivable":["auth-dep"],"gate":"make check"}}' >"$cfg"
  out="$(_grant '{"budget":"+10k","waves":[[1]],"waivers":["build-config"]}' \
    | NIGHT_GRANT_CONFIG="$cfg" night_grant_parse 2>/dev/null | sed -n 1p)"
  _t "parse: a project floor is waivable and the config travels in the args" \
    '{"waves":[[1]],"gate":"make check","grant":{"waivers":["build-config"],"stopCommand":null,"extraFloors":{"auth-dep":"the auth library","build-config":"the build config"},"neverWaivable":["auth-dep"]}}' "$out"
  _grant '{"budget":"+10k","waves":[[1]],"waivers":["auth-dep"]}' \
    | NIGHT_GRANT_CONFIG="$cfg" night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a project never-waivable floor is refused" 1 "$st"
  rm -f "$cfg"
  for w in workflows cost secret; do
    _grant "{\"budget\":\"+10k\",\"waves\":[[1]],\"waivers\":[\"$w\"]}" | night_grant_parse >/dev/null 2>&1; st=$?
    _t "parse: '$w' is never waivable" 1 "$st"
  done
  printf 'just a comment\n```json\n{"budget":"+10k","waves":[[1]]}\n```\n' \
    | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a body without the marker is refused" 1 "$st"
  printf '%s\nno block here\n' "$NIGHT_GRANT_MARKER" | night_grant_parse >/dev/null 2>&1; st=$?
  _t "parse: a grant without a json block is refused" 1 "$st"

  # pick — the latest marker comment wins
  out="$(printf '%s' '["<!-- night-grant -->\nold","unrelated","<!-- night-grant -->\nnew","also unrelated"]' \
    | night_grant_pick 2>/dev/null | tail -1)"
  _t "pick: the latest grant comment wins" new "$out"
  printf '%s' '["hello","world"]' | night_grant_pick >/dev/null 2>&1; st=$?
  _t "pick: no grant comment exits 1" 1 "$st"

  # preflight — against fixture settings files
  tmp="${TMPDIR:-/tmp}/night-grant-selftest-$$.json"
  printf '%s' '{"permissions":{"allow":["Bash(gh pr merge:*)"]}}' >"$tmp"
  out="$(night_grant_preflight "$tmp" 2>/dev/null)"; st=$?
  _t "preflight: a thin allowlist exits 1" 1 "$st"
  _t "preflight: it reports each missing entry" 5 "$(printf '%s\n' "$out" | grep -c '^  MISSING')"
  printf '%s' '{"permissions":{"allow":["Bash(gh:*)","Bash(git push:*)"]}}' >"$tmp"
  night_grant_preflight "$tmp" >/dev/null 2>&1; st=$?
  _t "preflight: a broader prefix covers its commands" 0 "$st"
  printf '%s' '{"permissions":{"allow":["Bash(ghx:*)","Bash(git:*)"]}}' >"$tmp"
  night_grant_preflight "$tmp" >/dev/null 2>&1; st=$?
  _t "preflight: a prefix only covers on a word boundary" 1 "$st"
  rm -f "$tmp"
  night_grant_preflight "$tmp" >/dev/null 2>&1; st=$?
  _t "preflight: a missing file is 2, never a silent 0" 2 "$st"

  if [ "$fails" -eq 0 ]; then printf 'night-grant selftest OK\n'; return 0; fi
  printf 'night-grant selftest FAILED (%s)\n' "$fails"; return 1
}

# ── dispatch (only when executed by name with a subcommand) ───────────────────────────────────
case "${0##*/}" in
  night-grant.sh)
    if [ $# -gt 0 ]; then
      _ng_cmd="$1"; shift
      case "$_ng_cmd" in
        read)       night_grant_read "$@" ;;
        parse)      night_grant_parse ;;
        preflight)  night_grant_preflight "$@" ;;
        --selftest|selftest) night_grant_selftest ;;
        -h|--help)  sed -n '/^# Usage/,/^# bash/p' "$0" | sed 's/^# \{0,1\}//' ;;
        *) _ng_err "unknown subcommand $_ng_cmd"; exit 2 ;;
      esac
    fi
    ;;
esac
