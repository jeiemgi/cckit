#!/usr/bin/env bash
# shellcheck shell=bash
# test-env.sh — seal a test from the caller's kit environment (#369).
#
# A developer shell that has run `load_kit_config` (or set KIT_CONFIG by hand) exports KIT_*,
# CCKIT_* and EFFORT_* variables. A test that inherits them reads the developer's project instead
# of its own fixture: KIT_CONFIG=/elsewhere made five suites fail. Source this first, then call
# test_env_seal before the test sets its own variables.
#
#   test_env_seal        unset every exported KIT_* / CCKIT_* / EFFORT_* variable in this shell
#   test_env_unset_args  print `-u NAME` pairs for env(1), one per line (the runner uses these)
#
# scripts/test.sh scrubs the same set before it runs each test; this covers a test run directly.
# errors: pure — no side effects beyond unsetting variables in the current shell
# bash 3.2 + zsh compatible.

_test_env_names() {
  env | sed -n 's/^\(KIT_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(CCKIT_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(EFFORT_[A-Za-z0-9_]*\)=.*/\1/p'
}

test_env_seal() {
  local n
  for n in $(_test_env_names); do unset "$n"; done
  return 0
}

test_env_unset_args() {
  local n
  for n in $(_test_env_names); do printf -- '-u\n%s\n' "$n"; done
}
