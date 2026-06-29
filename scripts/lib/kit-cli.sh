#!/usr/bin/env bash
# kit-cli.sh — tiny shared CLI helpers for the kit's bash scripts (#383). Zero-dep, tier B, sourced.
#
# Inspired by argc/bashew but WITHOUT a runtime dependency: the kit must run on user machines,
# Auto-Dev CI, and Cowork with nothing extra installed, so we keep our own minimal helpers instead
# of depending on a CLI framework binary.
#
# Source it:  source scripts/lib/kit-cli.sh
#
# Provides:
#   kit_is_main          true when the SOURCING script is being executed directly (not sourced).
#                        Replaces the 5-line ZSH_EVAL_CONTEXT / BASH_SOURCE guard duplicated across
#                        kit-wire, kit-remove, kit-mode, kit-config-resolve. Cross-shell (bash+zsh),
#                        verified for execute-vs-source in both. MUST be called from the consumer's
#                        top level (so the bash frame BASH_SOURCE[1] is the consumer itself).
#   kit_say / kit_warn / kit_die   stderr output helpers (stdout stays clean for pipeable data).

# True (rc 0) iff the script that sourced this lib is the one being executed directly.
#   zsh:  inside a function, ZSH_EVAL_CONTEXT is "toplevel:shfunc" when the caller was executed
#         and "...:file:shfunc" when the caller was sourced -> presence of "file" means sourced.
#   bash: BASH_SOURCE[1] (the caller frame's file) equals $0 only when the caller is the main script.
kit_is_main() {
  if [ -n "${ZSH_VERSION:-}" ]; then
    case "$ZSH_EVAL_CONTEXT" in (*file*) return 1;; (*) return 0;; esac
  fi
  [ "${BASH_SOURCE[1]:-}" = "$0" ]
}

# stderr helpers — stdout is reserved for a command's real output so it stays pipeable.
kit_say()  { printf '%s\n' "$*" >&2; }
kit_warn() { printf 'kit: %s\n' "$*" >&2; }
kit_die()  { printf 'kit: %s\n' "$*" >&2; exit "${KIT_DIE_RC:-1}"; }
