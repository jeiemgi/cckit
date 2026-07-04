#!/usr/bin/env bash
# benchmark/lib/bench-common.sh — shared plumbing for the benchmark harness: locate the benchmarks
# dir + its config, resolve the knowledge dir, read JSONL records, and the objective path-match
# predicate. Source this; do not execute it. Requires: jq.

# Resolve the benchmarks directory: explicit $BENCH_DIR wins, else ./benchmarks under the invoking
# project, else the example set shipped with cckit (templates/benchmarks) as a last resort so a
# fresh checkout can `--dry` before it has grown its own data.
bench_dir() {
  if [ -n "${BENCH_DIR:-}" ]; then printf '%s' "$BENCH_DIR"; return; fi
  if [ -d "$PWD/benchmarks" ]; then printf '%s' "$PWD/benchmarks"; return; fi
  printf '%s' "${BENCH_KIT_ROOT:-.}/templates/benchmarks"
}

# The benchmark config (sets + tiers + targets). Optional — the runner falls back to discovering
# *.jsonl in the dir when it is absent.
bench_config() {
  local d; d="$(bench_dir)"
  [ -f "$d/benchmark.config.json" ] && printf '%s' "$d/benchmark.config.json"
}

# The knowledge dir the docs live in. Prefer the benchmark config, else the loaded kit config
# (KIT_KNOWLEDGE_DIR), else the conventional default.
bench_knowledge_dir() {
  local cfg kd
  cfg="$(bench_config)"
  if [ -n "$cfg" ]; then
    kd="$(jq -r '.knowledgeDir // empty' "$cfg" 2>/dev/null)"
    [ -n "$kd" ] && { printf '%s' "$kd"; return; }
  fi
  printf '%s' "${KIT_KNOWLEDGE_DIR:-knowledge}"
}

# Objective top-hit path match. Args: <returned-path> <expected-json>. The expected value may be a
# single path or a JSON array of acceptable paths (split-canonical). A match is suffix-or-basename
# equality after stripping ./ and a leading knowledge-dir prefix — lenient about where the model
# rooted the path, strict about which document it named. Returns 0 on match.
bench_path_match() {
  local got="$1" expect_json="$2" e norm_got norm_e
  norm_got="$(bench_norm_path "$got")"
  # Iterate the expected paths (works for a bare string too, jq -r '.[]?' handles arrays only, so
  # normalize to an array first).
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    norm_e="$(bench_norm_path "$e")"
    [ "$norm_got" = "$norm_e" ] && return 0
    # basename equality catches "docs/x.md" vs "x.md"
    [ "${norm_got##*/}" = "${norm_e##*/}" ] && [ "${norm_e##*/}" = "$norm_e" -o "${norm_got##*/}" != "$norm_got" ] && return 0
  done < <(printf '%s' "$expect_json" | jq -r 'if type=="array" then .[] else . end' 2>/dev/null)
  return 1
}

# Normalize a path for comparison: lowercase, strip surrounding quotes/space, drop a leading ./ and
# a leading <knowledge-dir>/ segment so "knowledge/a.md" and "a.md" compare equal.
bench_norm_path() {
  local p="$1" kd
  kd="$(bench_knowledge_dir)"
  p="$(printf '%s' "$p" | tr 'A-Z' 'a-z' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  p="${p#./}"
  p="${p#"$(printf '%s' "$kd" | tr 'A-Z' 'a-z')/"}"
  printf '%s' "$p"
}

# Emit each record of a JSONL set as one compact JSON object per line. Blank lines + # comments are
# skipped so a set file can be annotated.
bench_records() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -vE '^[[:space:]]*(#|$)' "$file" | jq -c '.' 2>/dev/null
}
