#!/bin/sh
# kinds-test.sh — the `kind:` vocabulary is ONE closed set, and every place that spells it agrees.
#
# A kind value becomes a branch prefix (`cckit start` → `<kind>/<N>-<slug>`), so the label set
# setup-labels.sh provisions, the set `effort new --kind` accepts, and the prefixes the hygiene hook
# accepts must be the same list. Also pins the ctx:S|M|L|XL scale setup-labels.sh provisions.
# Runs the pure helpers under bash AND zsh.
# Hermetic: stubs gh. Run:  bash scripts/lib/kinds-test.sh
# errors: strict — a test runner: rc 1 on any failed assertion

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$dir/../.." && pwd)

if [ -n "${KINDS_TEST_INNER:-}" ]; then
  . "$dir/kinds.sh"
  . "$dir/worktree-start.sh"
  fail=0
  eq() { if [ "$2" != "$3" ]; then echo "FAIL($KINDS_TEST_INNER): $1 -> '[$2]', want '[$3]'"; fail=1; fi; }

  # every kind in the set is valid and is its own branch prefix, silently.
  for k in feat fix task chore security scaffold ci adr spike plan; do
    kit_kind_valid "$k"; eq "valid $k" "$?" "0"
    eq "branch prefix $k"          "$(kit_kind_branch "$k" 2>/dev/null)" "$k"
    eq "branch prefix $k is quiet" "$(kit_kind_branch "$k" 2>&1 >/dev/null)" ""
    eq "wt prefix $k"              "$(_wt_kind_prefix "$k" 2>/dev/null)" "$k"
  done
  # content kinds (#417): a label value, never a branch prefix. Each maps, silently, onto a prefix
  # that IS in the closed set, and titles a PR with a commit type other than feat.
  for pair in post:task campaign:plan brand:task research:spike; do
    k="${pair%%:*}"; want="${pair##*:}"
    kit_kind_content "$k";     eq "content $k" "$?" "0"
    kit_kind_label_valid "$k"; eq "label-valid $k" "$?" "0"
    kit_kind_valid "$k";       eq "content kind $k is not a branch kind" "$?" "1"
    eq "branch prefix $k"          "$(kit_kind_branch "$k" 2>/dev/null)" "$want"
    eq "branch prefix $k is quiet" "$(kit_kind_branch "$k" 2>&1 >/dev/null)" ""
    eq "wt prefix $k"              "$(_wt_kind_prefix "$k" 2>/dev/null)" "$want"
    kit_kind_valid "$(kit_kind_branch "$k" 2>/dev/null)"; eq "prefix of $k is in the closed set" "$?" "0"
    eq "commit type $k"            "$(kit_kind_commit_type "$k")" "docs"
  done
  kit_kind_content feat; eq "feat is not a content kind" "$?" "1"
  kit_kind_label_valid feat; eq "label-valid feat" "$?" "0"
  kit_kind_label_valid bug;  eq "label-valid bug" "$?" "1"
  eq "commit type feat"  "$(kit_kind_commit_type feat)"  "feat"
  eq "commit type chore" "$(kit_kind_commit_type chore)" "chore"
  eq "commit type bug"   "$(kit_kind_commit_type bug)"   "fix"
  eq "commit type task"  "$(kit_kind_commit_type task)"  "feat"
  eq "commit type ''"    "$(kit_kind_commit_type "")"    "feat"
  # a value outside the set never becomes a branch prefix: it degrades to task and says so.
  for k in bug docs enhancement Feat "" "fix/x"; do
    kit_kind_valid "$k"; eq "invalid '$k'" "$?" "1"
    eq "branch prefix '$k' -> task" "$(kit_kind_branch "$k" 2>/dev/null)" "task"
    eq "wt prefix '$k' -> task"     "$(_wt_kind_prefix "$k" 2>/dev/null)" "task"
    case "$(kit_kind_branch "$k" 2>&1 >/dev/null)" in
      *"is not one of"*) : ;;
      *) echo "FAIL($KINDS_TEST_INNER): unknown kind '$k' replaced without a warning"; fail=1 ;;
    esac
  done
  exit "$fail"
fi

fail=0
t() { if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 -> got '[$2]' want '[$3]'"; fail=1; fi; }

for sh in bash zsh; do
  command -v "$sh" >/dev/null 2>&1 || { echo "skip: $sh not installed"; continue; }
  if KINDS_TEST_INNER="$sh" "$sh" "$0"; then echo "ok: kinds helpers under $sh"; else fail=1; fi
done

. "$dir/kinds.sh"
sorted() { printf '%s\n' $1 | sort | tr '\n' ' ' | sed 's/ *$//'; }
want="$(sorted "$KIT_KINDS")"

# 1. the hygiene hook's accepted branch prefixes == the kind set.
hook="$(sed -n 's/.*=~ \^(\([a-z|]*\))\/\[0-9\]+-.*/\1/p' "$root/templates/hooks/repo-hygiene.sh.tmpl" | sed -n 1p | tr '|' ' ')"
t "hygiene hook prefixes == KIT_KINDS" "$(sorted "$hook")" "$want"

# 2. setup-labels.sh's built-in fallback (used where kinds.sh is not installed) == the kind set.
fb="$(sed -n 's/.*\${KIT_KINDS:-\([a-z ]*\)}.*/\1/p' "$root/scripts/setup-labels.sh" | sed -n 1p)"
t "setup-labels fallback kinds == KIT_KINDS" "$(sorted "$fb")" "$want"

# 2b. the content-kind fallback in setup-labels.sh == KIT_CONTENT_KINDS, and no content kind is a
#     branch prefix the hygiene hook would have to learn.
fbc="$(sed -n 's/.*\${KIT_CONTENT_KINDS:-\([a-z ]*\)}.*/\1/p' "$root/scripts/setup-labels.sh" | sed -n 1p)"
t "setup-labels fallback content kinds == KIT_CONTENT_KINDS" "$(sorted "$fbc")" "$(sorted "$KIT_CONTENT_KINDS")"
both="$(printf '%s\n' $KIT_KINDS $KIT_CONTENT_KINDS | sort | uniq -d | tr '\n' ' ')"
t "no kind is in both sets" "$both" ""

# 3. wt_start routes the label through the closed set rather than using it verbatim.
t "wt_start maps the kind label through _wt_kind_prefix" \
  "$(grep -c 'kind="$(_wt_kind_prefix "$kind")"' "$dir/worktree-start.sh" | tr -d ' ')" "1"

# 4. run setup-labels.sh against a stub gh: it provisions every kind + the whole ctx scale, and only
#    label families the rule documents.
command -v jq >/dev/null 2>&1 || { echo "skip: jq missing — setup-labels run not exercised"; exit "$fail"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'SH'
#!/bin/sh
echo "$*" >> "$GH_LOG"
exit 0
SH
chmod +x "$tmp/bin/gh"
GH_LOG="$tmp/gh.log"; export GH_LOG; : > "$GH_LOG"
( cd "$root" && PATH="$tmp/bin:$PATH" KIT_CONFIG="$root/cckit.config.json" bash scripts/setup-labels.sh ) >/dev/null 2>&1
t "setup-labels ran" "$?" "0"
got="$(sed -n 's/^label create kind:\([a-z]*\) .*/\1/p' "$GH_LOG" | sort | tr '\n' ' ' | sed 's/ *$//')"
t "setup-labels provisions exactly the kind set" "$got" "$want"
# 4b. with kinds.content on, the content kind labels are provisioned too.
: > "$GH_LOG"
jq '.kinds = {content:true}' "$root/cckit.config.json" > "$tmp/content.config.json"
( cd "$root" && PATH="$tmp/bin:$PATH" KIT_CONFIG="$tmp/content.config.json" bash scripts/setup-labels.sh ) >/dev/null 2>&1
t "setup-labels ran with kinds.content" "$?" "0"
got="$(sed -n 's/^label create kind:\([a-z]*\) .*/\1/p' "$GH_LOG" | sort | tr '\n' ' ' | sed 's/ *$//')"
t "kinds.content adds exactly the content kinds" "$got" "$(sorted "$KIT_KINDS $KIT_CONTENT_KINDS")"
: > "$GH_LOG"
( cd "$root" && PATH="$tmp/bin:$PATH" KIT_CONFIG="$root/cckit.config.json" bash scripts/setup-labels.sh ) >/dev/null 2>&1
got="$(sed -n 's/^label create ctx:\([A-Z]*\) .*/\1/p' "$GH_LOG" | tr '\n' ' ' | sed 's/ *$//')"
t "setup-labels provisions ctx S M L XL" "$got" "S M L XL"
# roles and agent profiles come from the project config, so those two families may be absent.
got="$(sed -n 's/^label create \([a-z]*\):.*/\1/p' "$GH_LOG" | sort -u \
  | grep -vE '^(agent|ctx|flow|kind|priority|role)$' | tr '\n' ' ' | sed 's/ *$//')"
t "setup-labels creates no family the rule does not document" "$got" ""

[ "$fail" -eq 0 ] && echo "ALL OK (kinds)" || echo "kinds: FAILURES"
exit "$fail"
