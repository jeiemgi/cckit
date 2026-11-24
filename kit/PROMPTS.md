# kit/ — what `cckit init` installs

Templates, skills, profiles, integrations, commands, modules, recipes, routines, interview
questions, database descriptors, the status line, completions and git hooks. A file here is
copied into, or read on behalf of, someone else's project.

| Rule | Check |
| --- | --- |
| The plugin manifest names `./kit/skills/` and `./kit/commands/` and both resolve | `scripts/self-install-test.sh`; the plugin fence in the PR |
| Skill frontmatter stays inside the listing budget | `scripts/skill-frontmatter-lint.sh` |
| Agent templates carry `name` and `description`, and their skills resolve | `scripts/agent-template-lint.sh`, `scripts/agent-skills-lint.sh` |
| Nothing private ships | the leak fence and the secret guard in `scripts/check.sh` |
| The npm tarball ships `kit/` | `scripts/lib/integrations-test.sh`, `scripts/lib/adapter-select-test.sh` |
| No new payload root at the top level | `lib/core/layout-fence.sh` (retired roots must stay empty) |
