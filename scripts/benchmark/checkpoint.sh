#!/usr/bin/env bash
# benchmark/checkpoint.sh — recorded benchmark checkpoints, one file per release version (#452).
#
# A checkpoint is one scored retrieval run, kept. A release has one run file,
# benchmarks/runs/<X.Y.Z>.json, holding every checkpoint taken while that version was being built:
#   { "schema": 1, "version": "X.Y.Z", "checkpoints": [ { "n": 1, … }, { "n": 2, … } ] }
# The format is specified in benchmarks/runs/README.md.
#
# Usage:
#   checkpoint.sh record <X.Y.Z> [--from <run.json>]… [--passes <N>] [--model <name>]
#                        [--commit <sha>] [--ref <name>] [--date <YYYY-MM-DD>] [--note <text>]
#                        [--verbs <timings.json>]
#       Append a checkpoint to benchmarks/runs/<X.Y.Z>.json. Without --from it runs the benchmark
#       (run.sh --json) --passes times (default 1). Each --from is one pass already run: the JSON
#       `cckit bench run --json` printed. Passes are summed, so score = answers right / answers asked.
#       --verbs attaches a per-verb measurement already taken (the JSON verb-timings.sh --json
#       printed) as the checkpoint's `verbs`: wall milliseconds and gh calls per verb.
#       Rewrites the results page when benchmark.config.json names one in `resultsPage`.
#   checkpoint.sh list [--json]
#       Every recorded checkpoint, oldest first.
#   checkpoint.sh check <X.Y.Z>
#       The release gate. The version's last checkpoint is compared with the checkpoint recorded
#       before it over the questions BOTH asked (matched by set file + id). Exit 0 when it scores at
#       least as high on those, or when the two share no question (a new baseline); exit 1 when the
#       version has no checkpoint, or it scores lower on the shared questions; exit 2 on a usage
#       error or a run file that is not a checkpoint file.
#   checkpoint.sh page [--out <file>] [--check]
#       Print the results page (markdown) built from the run files; --out writes it; --check exits 1
#       when the file on disk differs from what the run files produce.
#
# Env: BENCH_DIR (the benchmarks dir; default ./benchmarks).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/bench-common.sh"

command -v jq >/dev/null 2>&1 || { echo "checkpoint.sh: jq is required" >&2; exit 2; }

DIR="$(bench_dir)"
RUNS="$DIR/runs"
PROJECT_ROOT="$(cd "$DIR/.." 2>/dev/null && pwd)"

usage() { sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; }

# A flag that takes a value, given as the last argument, has none: refuse it. Without this check
# `shift 2` fails on one remaining argument, shifts nothing, and the parse loop never ends.
need_value() { [ "$2" -ge 2 ] || { echo "checkpoint $1: $3 needs a value" >&2; return 2; }; }

is_version() { grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$1"; }

# Recorded versions, oldest first (numeric per field: 0.10.0 sorts after 0.9.0).
cp_versions() {
  local f v
  [ -d "$RUNS" ] || return 0
  for f in "$RUNS"/*.json; do
    [ -e "$f" ] || continue
    v="$(basename "$f" .json)"
    is_version "$v" && printf '%s\n' "$v"
  done | sort -t. -k1,1n -k2,2n -k3,3n
}

# One JSON array of every checkpoint, oldest first, each tagged with its version. Returns 2, with
# the file named on stderr, when a run file is not a checkpoint file.
cp_all() {
  local v files=()
  while IFS= read -r v; do [ -n "$v" ] && files+=("$RUNS/$v.json"); done < <(cp_versions)
  [ "${#files[@]}" -gt 0 ] || { printf '[]'; return 0; }
  # One unreadable file would make every verdict, list and page silently empty: name it and stop.
  for v in "${files[@]}"; do
    jq -e 'type == "object" and (.checkpoints | type == "array")' "$v" >/dev/null 2>&1 \
      || { echo "checkpoint.sh: $v is not a checkpoint file (invalid JSON, or no .checkpoints array)" >&2; return 2; }
  done
  jq -s -c '[ .[] | .version as $v | (.checkpoints // [])[] | . + {version: $v} ]' "${files[@]}"
}

# ---- record ----------------------------------------------------------------
cmd_record() {
  local version="" passes=1 model="" commit="" ref="" date_s="" note="" verbs="" froms=() tmp i f
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from|--passes|--model|--commit|--ref|--date|--note|--verbs) need_value record "$#" "$1" || return 2 ;;
      -h|--help) usage; return 0 ;;
    esac
    case "$1" in
      --from)    froms+=("${2:-}"); shift 2 ;;
      --from=*)  froms+=("${1#*=}"); shift ;;
      --passes)  passes="${2:-}"; shift 2 ;;
      --passes=*) passes="${1#*=}"; shift ;;
      --model)   model="${2:-}"; shift 2 ;;
      --model=*) model="${1#*=}"; shift ;;
      --commit)  commit="${2:-}"; shift 2 ;;
      --commit=*) commit="${1#*=}"; shift ;;
      --ref)     ref="${2:-}"; shift 2 ;;
      --ref=*)   ref="${1#*=}"; shift ;;
      --date)    date_s="${2:-}"; shift 2 ;;
      --date=*)  date_s="${1#*=}"; shift ;;
      --note)    note="${2:-}"; shift 2 ;;
      --note=*)  note="${1#*=}"; shift ;;
      --verbs)   verbs="${2:-}"; shift 2 ;;
      --verbs=*) verbs="${1#*=}"; shift ;;
      -*)        echo "checkpoint record: unknown flag '$1'" >&2; return 2 ;;
      *)         if [ -z "$version" ]; then version="$1"; shift
                 else echo "checkpoint record: unexpected argument '$1'" >&2; return 2; fi ;;
    esac
  done
  is_version "$version" || { echo "checkpoint record: version must be X.Y.Z (got '${version}')" >&2; return 2; }
  grep -Eq '^[1-9][0-9]*$' <<<"$passes" || { echo "checkpoint record: --passes must be a positive integer" >&2; return 2; }

  cp_all >/dev/null || return 2   # an unreadable run file is reported before anything is run or written

  # A measurement to attach is validated before anything is run: every row needs the five fields
  # the page prints, as a string and four non-negative numbers.
  if [ -n "$verbs" ]; then
    [ -f "$verbs" ] || { echo "checkpoint record: no such verb timings file: $verbs" >&2; return 2; }
    jq -e '(.verbs | type == "array") and (.verbs | length) > 0
           and ([ .verbs[] | (.verb | type == "string")
                  and ([.runs, .min_ms, .median_ms, .gh_calls] | all(type == "number" and . >= 0)) ] | all)' \
      "$verbs" >/dev/null 2>&1 \
      || { echo "checkpoint record: $verbs is not a verb timings file (.verbs rows need verb, runs, min_ms, median_ms, gh_calls)" >&2; return 2; }
  fi

  tmp="$(mktemp -d)" || return 2
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  if [ "${#froms[@]}" -gt 0 ]; then
    i=0
    for f in "${froms[@]}"; do
      [ -f "$f" ] || { echo "checkpoint record: no such run file: $f" >&2; return 2; }
      jq -e 'type == "object" and (.results | type == "array")' "$f" >/dev/null 2>&1 \
        || { echo "checkpoint record: $f is not a run (no .results array)" >&2; return 2; }
      i=$((i+1)); cp "$f" "$tmp/pass-$i.json"
    done
  else
    i=0
    while [ "$i" -lt "$passes" ]; do
      i=$((i+1))
      echo "checkpoint record: pass $i of $passes" >&2
      # run.sh exits 1 when any question failed; that is a score, not an error here.
      bash "$SCRIPT_DIR/run.sh" --json > "$tmp/pass-$i.json" 2>"$tmp/pass-$i.err"
      jq -e '.results | type == "array"' "$tmp/pass-$i.json" >/dev/null 2>&1 \
        || { echo "checkpoint record: pass $i produced no run JSON" >&2; cat "$tmp/pass-$i.err" >&2; return 2; }
    done
  fi

  # Question text, looked up by set file + id, so the page can show what was asked.
  local qmap="$tmp/questions.json" setf
  printf '{}' > "$qmap"
  for setf in "$DIR"/*.jsonl; do
    [ -e "$setf" ] || continue
    bench_records "$setf" | jq -s -c --arg set "$(basename "$setf")" \
      '[ .[] | select(.id != null) | {key: ($set + "|" + (.id|tostring)), value: (.q // .claim // "")} ] | from_entries' \
      > "$tmp/one.json" 2>/dev/null || continue
    jq -s -c '.[0] + .[1]' "$qmap" "$tmp/one.json" > "$tmp/merged.json" && mv "$tmp/merged.json" "$qmap"
  done

  # Defaults that describe where the run came from.
  [ -n "$date_s" ] || date_s="$(date +%Y-%m-%d)"
  [ -n "$commit" ] || commit="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
  [ -n "$ref" ]    || ref="$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || true)"
  [ -n "$model" ]  || model="$(jq -r '.model // empty' "$tmp/pass-1.json" 2>/dev/null)"
  [ -n "$model" ]  || model="${BENCH_MODEL:-${BENCH_BACKEND:-claude}}"

  local out="$RUNS/$version.json" existing="$tmp/existing.json"
  mkdir -p "$RUNS"
  if [ -f "$out" ]; then
    jq -e '.checkpoints | type == "array"' "$out" >/dev/null 2>&1 \
      || { echo "checkpoint record: $out is not a checkpoint file (no .checkpoints array)" >&2; return 2; }
    cp "$out" "$existing"
  else
    jq -n --arg v "$version" '{schema: 1, version: $v, checkpoints: []}' > "$existing"
  fi

  local vfile="$tmp/verbs.json"
  if [ -n "$verbs" ]; then
    jq -c '[ .verbs[] | {verb, runs, min_ms, median_ms, gh_calls} + (if (.exit // 0) != 0 then {exit} else {} end) ]' "$verbs" > "$vfile" || return 2
  else
    printf 'null' > "$vfile"
  fi

  jq -s --slurpfile ex "$existing" --slurpfile q "$qmap" --slurpfile vb "$vfile" \
     --arg date "$date_s" --arg commit "$commit" --arg ref "$ref" --arg model "$model" --arg note "$note" '
    . as $passes
    | [ $passes[] | select(.dry == true) ] as $dry
    | if ($dry | length) > 0 then error("a --dry run has no scores to record") else . end
    # run.sh stores an empty answer only when the model backend failed (a real answer is a path or
    # NONE). Such a run measures the backend, not the docs, and an empty answer passes the abstain tier.
    | ( [ $passes[].results[] | select((.got // "") == "") ] | length ) as $noanswer
    | if $noanswer > 0 then error("\($noanswer) answer(s) are empty: the model backend returned nothing, so there is no score to record") else . end
    # One row per question, in the order the first pass asked them.
    | ( [ $passes[].results[] ] | group_by(.set + "|" + (.id|tostring)) ) as $groups
    | ( [ $passes[0].results[] | .set + "|" + (.id|tostring) ] ) as $order
    | ( $groups | map({ key: (.[0].set + "|" + (.[0].id|tostring)), value: . }) | from_entries ) as $by
    | [ $order[] | $by[.] as $g
        | { set: $g[0].set, tier: $g[0].tier, id: $g[0].id,
            q: ($q[0][ $g[0].set + "|" + ($g[0].id|tostring) ] // ""),
            expect: $g[0].expect,
            got: ( ([ $g[] | select(.pass | not) | .got ] | first) // $g[-1].got ),
            passed: ([ $g[] | select(.pass) ] | length),
            asked: ($g | length),
            latency_ms: (([ $g[] | .latency_ms // 0 ] | add) / ($g | length) | floor) }
        | . + { pass: (.passed == .asked) } ] as $results
    | ( [ $results[].asked ] | add // 0 ) as $total
    | ( [ $results[].passed ] | add // 0 ) as $pass
    | if $total == 0 then error("the run has no results") else . end
    | $ex[0] as $file
    | $file
    | .schema = 1
    | .checkpoints += [ {
        n: (($file.checkpoints | length) + 1),
        date: $date, ref: $ref, commit: $commit, model: $model,
        passes: ($passes | length),
        questions: ($results | length),
        total: $total, pass: $pass,
        score_pct: (($pass * 100 / $total) | floor),
        tiers: ( $results | group_by(.tier)
                 | map({ key: .[0].tier, value: { total: ([.[].asked] | add), pass: ([.[].passed] | add) } })
                 | from_entries ),
        note: $note,
        results: $results }
        + (if $vb[0] != null then { verbs: $vb[0] } else {} end) ]
  ' "$tmp"/pass-*.json > "$tmp/new.json" || { echo "checkpoint record: could not build the checkpoint" >&2; return 2; }

  mv "$tmp/new.json" "$out"
  jq -r '.checkpoints[-1] | "recorded checkpoint \(.n) of '"$version"': \(.pass)/\(.total) (\(.score_pct)%) · \(.passes) pass(es) · \(.model) · \(.ref)@\(.commit)" + (if .verbs then " · \(.verbs | length) verb timings" else "" end)' "$out"
  echo "  file: $out"

  local page; page="$(cp_page_path)"
  if [ -n "$page" ]; then
    cmd_page --out "$page" && echo "  page: $page"
  fi
}

# ---- list ------------------------------------------------------------------
cmd_list() {
  local json=0 all
  for a in "$@"; do case "$a" in --json|--llm) json=1 ;; *) echo "checkpoint list: unknown arg '$a'" >&2; return 2 ;; esac; done
  all="$(cp_all)" || return 2
  if [ "$json" -eq 1 ]; then
    printf '%s' "$all" | jq -c '[ .[] | del(.results) ]'
    return 0
  fi
  if [ "$(printf '%s' "$all" | jq 'length')" -eq 0 ]; then
    echo "no recorded checkpoints in $RUNS"; return 0
  fi
  printf '%s' "$all" | jq -r '.[] | "\(.version)  #\(.n)  \(.date)  \(.pass)/\(.total) (\(.score_pct)%)  \(.passes) pass(es)  \(.model)  \(.ref)@\(.commit)"'
}

# ---- check (the release gate) ----------------------------------------------
# Two checkpoints are compared over the questions BOTH asked, matched by set file + id (#452). The
# question set grows between checkpoints (18 to 55 in 0.10.0), and a whole-run fraction would read
# 54 of 55 as lower than 18 of 18 although no question got worse. On the shared questions the scores
# compare as fractions (answers right / answers asked, cross-multiplied), so a different number of
# passes still compares and integer-percent rounding never decides a release. Two checkpoints that
# share no question cannot be compared: the newer one is a new baseline and passes.
cmd_check() {
  local version="${1:-}" all
  is_version "$version" || { echo "checkpoint check: version must be X.Y.Z (got '${version}')" >&2; return 2; }
  all="$(cp_all)" || return 2
  if [ ! -f "$RUNS/$version.json" ] || [ "$(jq '(.checkpoints // []) | length' "$RUNS/$version.json" 2>/dev/null || echo 0)" -eq 0 ]; then
    echo "benchmark check: no recorded checkpoint for $version (expected $RUNS/$version.json)"
    echo "  record one: cckit bench checkpoint $version"
    return 1
  fi
  local verdict line
  line="$(printf '%s' "$all" | jq -r --arg v "$version" '
    def key: .set + "|" + (.id | tostring);
    def bykey(c): [ (c.results // [])[] | { key: key, value: . } ] | from_entries;
    def lbl(c): "\(c.version) checkpoint \(c.n): \(c.pass)/\(c.total) (\(c.score_pct)%)";
    . as $a
    | ( [ range(0; length) | select($a[.].version == $v) ] | last ) as $idx
    | $a[$idx] as $cur
    | ( if $idx > 0 then $a[$idx - 1] else null end ) as $prev
    | if $prev == null then "ok\tbenchmark check: " + lbl($cur) + " — no earlier checkpoint to compare against"
      else
        bykey($cur) as $c | bykey($prev) as $p
        | [ $c | keys_unsorted[] | select($p[.] != null) ] as $shared
        | ( ($c | length) - ($shared | length) ) as $new
        | ( ($p | length) - ($shared | length) ) as $gone
        | "\($new) new, \($gone) removed" as $delta
        | if ($shared | length) == 0
            then "ok\tbenchmark check: " + lbl($cur) + " — new baseline: it shares no question with "
                 + lbl($prev) + " (\($delta))"
          else
            ( [ $shared[] | $c[.].passed ] | add ) as $cp | ( [ $shared[] | $c[.].asked ] | add ) as $ct
            | ( [ $shared[] | $p[.].passed ] | add ) as $pp | ( [ $shared[] | $p[.].asked ] | add ) as $pt
            | [ $shared[] | select($p[.].pass and ($c[.].pass | not)) | $c[.] | "\(.set) \(.id)" ] as $worse
            | "on the \($shared | length) question(s) both asked (\($cp)/\($ct) now, \($pp)/\($pt) before); \($delta)" as $on
            | ( if ($worse | length) > 0 then "\n  right before, missed now: " + ($worse | join(", ")) else "" end ) as $tail
            | if ($cp * $pt) < ($pp * $ct)
                then "low\tbenchmark check: " + lbl($cur) + " is lower than " + lbl($prev) + " " + $on + $tail
              else "ok\tbenchmark check: " + lbl($cur) + " — not lower than " + lbl($prev) + " " + $on + $tail
              end
          end
      end
  ')"
  verdict="${line%%	*}"
  printf '%s\n' "${line#*	}"
  [ "$verdict" = "ok" ]
}

# ---- page ------------------------------------------------------------------
# The results page named by benchmark.config.json `resultsPage` (relative to the project root).
cp_page_path() {
  local cfg rel
  cfg="$(bench_config)"
  [ -n "$cfg" ] || return 0
  rel="$(jq -r '.resultsPage // empty' "$cfg" 2>/dev/null)"
  [ -n "$rel" ] || return 0
  case "$rel" in /*) printf '%s' "$rel" ;; *) printf '%s' "$PROJECT_ROOT/$rel" ;; esac
}

cp_render_page() {
  local all
  all="$(cp_all)" || return 2
  printf '%s' "$all" | jq -r '
    def cell: tostring | gsub("[\r\n]+"; " ") | gsub("\\|"; "\\|") | gsub("<"; "&lt;") | gsub("\\{"; "&#123;");
    def code: tostring | gsub("[\r\n]+"; " ") | gsub("`"; "") | gsub("\\|"; "\\|") | .[0:120] | "`" + . + "`";
    def docs: if type == "array" then map(code) | join(" or ") else code end;
    def tier(c; t): if c.tiers[t] then "\(c.tiers[t].pass)/\(c.tiers[t].total)" else "—" end;
    def vkey: split(".") | map(tonumber);
    . as $all
    | "---",
      "title: Benchmark results",
      "description: The documentation benchmark score recorded at every checkpoint of every release.",
      "---",
      "",
      "<!-- Generated from benchmarks/runs/*.json by `cckit bench page`. Do not edit by hand: scripts/check.sh fails when this page differs from the run files. -->",
      "",
      "Each release records the [documentation benchmark](/benchmark/) as one or more checkpoints: a run, the fixes it showed were needed, then another run. A release is refused when its last checkpoint scores lower than the checkpoint recorded before it, counted over the questions both checkpoints asked ([Releasing](/ship/releasing/#the-benchmark-check)).",
      "",
      "Score is answers right out of answers asked. A checkpoint with more than one pass asks every question that many times.",
      "",
      ( if ($all | length) == 0 then "No checkpoint has been recorded yet." else
          ( [ $all[].version ] | unique | sort_by(vkey) | reverse | .[] ) as $v
          | [ $all[] | select(.version == $v) ] as $cps
          | "## " + $v,
            "",
            "| Checkpoint | Date | Commit | Model | Passes | Score | Retrieval | Adversarial | Abstain |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
            ( $cps[] | "| \(.n) | \(.date | cell) | \(((.ref // "") + "@" + (.commit // "")) | code) | \(.model | cell) | \(.passes) | **\(.pass)/\(.total)** (\(.score_pct)%) | \(tier(.; "retrieval")) | \(tier(.; "adversarial")) | \(tier(.; "abstain")) |" ),
            "",
            ( $cps[]
              | . as $c
              | [ $c.results[] | select(.pass | not) ] as $missed
              | ( if ($c.note // "") != "" then "Checkpoint \($c.n) note: \($c.note | cell)", "" else empty end ),
                ( if ($missed | length) == 0 then "Checkpoint \($c.n): no missed questions.", ""
                  else
                    "Checkpoint \($c.n) missed \($missed | length) of \($c.questions) questions:",
                    "",
                    "| Question | Tier | Expected | Answered | Right |",
                    "| --- | --- | --- | --- | --- |",
                    ( $missed[] | "| \(.id | code) \(.q // "" | cell) | \(.tier | cell) | \(.expect | docs) | \(.got | code) | \(.passed)/\(.asked) |" ),
                    ""
                  end ),
                ( if (($c.verbs // []) | length) == 0 then empty
                  else
                    "Checkpoint \($c.n) verb timings: wall time of each read-only verb and the number of times it ran `gh`.",
                    "",
                    "| Verb | Runs | Min ms | Median ms | gh calls |",
                    "| --- | --- | --- | --- | --- |",
                    ( $c.verbs[] | "| \("cckit " + .verb | code)\(if (.exit // 0) != 0 then " (exit \(.exit))" else "" end) | \(.runs) | \(.min_ms) | \(.median_ms) | \(.gh_calls) |" ),
                    ""
                  end ) )
        end )
  '
}

cmd_page() {
  local out="" check=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --out)   need_value page "$#" "$1" || return 2; out="$2"; shift 2 ;;
      --out=*) out="${1#*=}"; shift ;;
      --check) check=1; shift ;;
      *)       echo "checkpoint page: unknown arg '$1'" >&2; return 2 ;;
    esac
  done
  [ -n "$out" ] || [ "$check" -eq 0 ] || out="$(cp_page_path)"
  if [ "$check" -eq 1 ]; then
    [ -n "$out" ] || { echo "checkpoint page --check: no page configured (benchmark.config.json resultsPage) and no --out" >&2; return 2; }
    local want
    want="$(cp_render_page)" || return 2
    if [ -f "$out" ] && [ "$want" = "$(cat "$out")" ]; then
      echo "benchmark results page is current: $out"; return 0
    fi
    echo "benchmark results page is stale: $out" >&2
    echo "  regenerate: cckit bench page --out $out" >&2
    return 1
  fi
  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    cp_render_page > "$out.tmp.$$" && mv "$out.tmp.$$" "$out" || { rm -f "$out.tmp.$$"; return 2; }
  else
    cp_render_page
  fi
}

sub="${1:-}"; [ "$#" -gt 0 ] && shift
case "$sub" in
  record) cmd_record "$@" ;;
  list)   cmd_list "$@" ;;
  check)  cmd_check "$@" ;;
  page)   cmd_page "$@" ;;
  -h|--help|"") usage; [ -n "$sub" ] && exit 0 || exit 2 ;;
  *) echo "checkpoint.sh: unknown subcommand '$sub' (record|list|check|page)" >&2; exit 2 ;;
esac
