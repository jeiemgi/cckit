#!/usr/bin/env bash
# layout-fence-test.sh — the layout ratchet refuses a new top-level directory, a file under a
# retired root, growth or slack in the scripts/ counts, and code that is not a forwarding stub there. Network-free; fixtures under mktemp.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '$2' want '$3'"; fail=1; fi; }
r="$tmp/r"; mkdir -p "$r/scripts/lib" "$r/kit" "$r/lib/core"
git -C "$r" init -q
cp "$HERE/layout-fence.sh" "$r/lib/core/"
printf 'bin\nkit\nlib\nscripts\n' > "$r/lib/core/layout-fence.allow"
printf '#!/usr/bin/env bash\n# cckit-forwarding-stub: scripts/lib/a.sh moved to lib/core/a.sh\n' > "$r/scripts/lib/a.sh"; : > "$r/kit/x"
printf 'scripts-top 0\nscripts-lib 1\n' > "$r/lib/core/layout-fence.baseline"
git -C "$r" add -A
run() { bash "$r/lib/core/layout-fence.sh" >/dev/null 2>&1; echo "$?"; }
t "the fixture is clean" "$(run)" "0"
mkdir -p "$r/newdir"; : > "$r/newdir/f"; git -C "$r" add newdir
t "a new top-level directory fails" "$(run)" "1"
git -C "$r" rm -rq --cached newdir; rm -rf "$r/newdir"
mkdir -p "$r/templates"; : > "$r/templates/f"; git -C "$r" add templates
printf 'templates\n' >> "$r/lib/core/layout-fence.allow"
t "a file under a retired root fails, even when allowed" "$(run)" "1"
git -C "$r" rm -rq --cached templates; rm -rf "$r/templates"
: > "$r/scripts/new.sh"; git -C "$r" add scripts/new.sh
t "a new file directly under scripts/ fails" "$(run)" "1"
git -C "$r" rm -q --cached scripts/new.sh; rm -f "$r/scripts/new.sh"
printf '#!/usr/bin/env bash\necho real code\n' > "$r/scripts/lib/a.sh"; git -C "$r" add scripts/lib/a.sh
t "code that is not a forwarding stub fails" "$(run)" "1"
git -C "$r" rm -q --cached scripts/lib/a.sh
t "a drop without lowering the baseline fails" "$(run)" "1"
printf 'scripts-top 0\nscripts-lib 0\n' > "$r/lib/core/layout-fence.baseline"
t "the lowered baseline passes" "$(run)" "0"
[ "$fail" -eq 0 ] && echo "layout-fence-test: PASS" || echo "layout-fence-test: FAIL"
exit "$fail"
