#!/usr/bin/env bash
# commitlint.sh — validate a subject line against Conventional Commits. ONE implementation,
# shared by the PR-title gate (.github/workflows/commitlint.yml) and the local test suite.
#
# Why this exists: PRs are squash-merged (`gh pr merge --squash`), so the PR *title* becomes the
# single commit on the base branch that release-please reads to compute the next version. A
# non-conventional title makes release-please classify the change as "other" and silently
# under-bump (or skip the release) — so every PR title MUST be a Conventional Commit subject.
#
#   commitlint.sh "<subject>"   exit 0 = valid, 1 = invalid (with guidance on stderr)
#   source commitlint.sh && commitlint_check "<subject>"   same, as a function
#
# The accepted types are commitlint's config-conventional set, a superset of the types
# scripts/lib/version-bump.sh acts on (feat -> minor; fix/perf/refactor/revert -> patch;
# feat!/BREAKING CHANGE -> major; the rest -> no release). Keeping the two in step means a title
# that passes here is one release-please can always classify.

# Conventional Commit subject: type(scope)!: description
#   type    — one of the known types below
#   (scope) — optional, e.g. (orchestrate), (main)
#   !       — optional breaking-change marker
#   : SPACE — required separator
#   description — required, non-empty
_CL_TYPES='build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test'
_CL_RE="^(${_CL_TYPES})(\([a-z0-9][a-z0-9._/-]*\))?(!)?: .+"

commitlint_check() {
  local subject="${1-}"
  if [ -z "$subject" ]; then
    printf 'commitlint: empty subject — nothing to validate\n' >&2
    return 1
  fi
  if printf '%s' "$subject" | grep -qE "$_CL_RE"; then
    return 0
  fi
  {
    printf 'commitlint: not a Conventional Commit subject:\n'
    printf '  %s\n\n' "$subject"
    printf 'Expected: type(scope)!: summary\n'
    printf '  type   one of: %s\n' "$(printf '%s' "$_CL_TYPES" | tr '|' ' ')"
    printf '  scope  optional, e.g. feat(orchestrate): ...\n'
    printf '  !      optional breaking-change marker, e.g. feat!: ...\n'
    printf '  : then a space, then a non-empty summary\n\n'
    printf 'Why it matters: this subject is the squash-merge commit release-please reads to pick\n'
    printf 'the next version. A non-conventional subject under-bumps the release silently.\n'
  } >&2
  return 1
}

# Run as a CLI when executed directly (not when sourced).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  commitlint_check "${1-}"
fi
