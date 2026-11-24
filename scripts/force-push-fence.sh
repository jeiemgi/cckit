#!/usr/bin/env bash
# force-push-fence.sh — #592: the gate fails when a non-test file under bin/ or scripts/ force-pushes.
# A pushed branch is brought onto its base by `git merge origin/<base>`, never by a rebase, so no
# push needs --force. The squash merge keeps history linear anyway.
#
#   scripts/force-push-fence.sh              rc 0 when the count is at or under the baseline, 1 over it
#   scripts/force-push-fence.sh --root <dir> fence another checkout
#   scripts/force-push-fence.sh --write      write the current count into the baseline
#
# Counts non-comment lines in bin/* and scripts/**/*.sh (test files `*-test.sh` and `test-*.sh`, and
# this script, are skipped) that hold `push` with `--force`, `--force-with-lease` or `-f`, or the
# `--force-with-lease` flag on its own. Ratchet against scripts/force-push-fence.baseline (`force=<n>`).
# errors: strict — set -e; a missing baseline exits 1
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
write=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) ROOT="$(cd "${2:?--root needs a directory}" && pwd)"; shift 2 ;;
    --write) write=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "force-push-fence: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
baseline="$ROOT/scripts/force-push-fence.baseline"

# A forbidden push: `push` then --force / --force-with-lease / -f on one line, or a bare --force-with-lease.
re='push[^|;&]*(--force|[[:space:]]-f([[:space:]]|$))|--force-with-lease'
hits="$(cd "$ROOT" && { for f in bin/*; do [ -f "$f" ] && echo "$f"; done; for f in scripts/*.sh scripts/lib/*.sh; do [ -f "$f" ] && echo "$f"; done; } \
  | grep -vE -- '-test\.sh$|(^|/)test-[a-z-]+\.sh$|^scripts/force-push-fence\.sh$' | sort -u | while IFS= read -r f; do
      grep -nE "$re" "$f" | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s|^|$f:|" || true
    done)"
n="$(printf '%s\n' "$hits" | sed '/^$/d' | wc -l | tr -d ' ')"

if [ "$write" = 1 ]; then
  printf 'force=%s\n' "$n" > "$baseline"
  echo "force-push-fence: baseline written — force=$n"
  exit 0
fi
[ -f "$baseline" ] || { echo "force-push-fence: no baseline at $baseline (run: scripts/force-push-fence.sh --write)" >&2; exit 1; }
max="$(sed -n 's/^force=//p' "$baseline" | sed -n 1p)"
case "$max" in *[!0-9]*|'') echo "force-push-fence: the baseline must hold force=<n>" >&2; exit 1 ;; esac

if [ "$n" -gt "$max" ]; then
  echo "x force-push fence: $n force-push line(s) (baseline $max). Update the branch with git merge origin/<base> and push plain:"
  printf '%s\n' "$hits" | sed '/^$/d' | sed 's/^/    /'
  exit 1
fi
echo "ok force-push fence: $n/$max force-push lines in bin/ and scripts/"
if [ "$n" -lt "$max" ]; then echo "   the count went down — ratchet it: scripts/force-push-fence.sh --write"; fi
exit 0
