# ontology — the words cckit uses, one file each

`ontology/terms/<Term>.json` holds one term: a word the CLI, the skills and the rules use with
one meaning. `scripts/terms-check.sh` reads every file and `bash scripts/check.sh` runs it in
warn mode (it prints, it never fails the gate).

Terms are JSON, not YAML: cckit's gate is bash + `jq` and installs no YAML parser, and a format
the check cannot read is a format nothing enforces.

## The fields

| Field | Type | Rule |
| --- | --- | --- |
| `id` | string | PascalCase (`^[A-Z][A-Za-z0-9]*$`), equal to the file name without `.json` |
| `label` | string, or list of strings | the English word; in a list the first item is the preferred word, the rest are accepted |
| `definition` | string | at least 20 characters: what the thing is, in the CLI's own words |
| `is_not` | list of strings, at least one | the neighbours it is confused with, and the difference |
| `avoid` | list of strings | words not to use for it (may be empty) |
| `home` | object | where the term lives, any of `cli: <verb>` (a top-level verb of `bin/cckit`), `skill: <name>` (a folder under `skills/`), `rule: <path>` (a file under `.claude/rules/`) |
| `status` | `seed` · `sapling` · `tree` | see below |

No other field is allowed.

| Status | Meaning | What the check demands |
| --- | --- | --- |
| `seed` | named, not yet used with one meaning everywhere | the fields validate; `home` may be empty or point at something that does not exist yet |
| `sapling` | the CLI, the skills or the rules use it with this meaning | at least one `home`, and every `home` resolves |
| `tree` | the CLI, the skills, the rules and the docs site all use it with this meaning | same as `sapling` |

## Adding a term

1. Write `ontology/terms/<Term>.json` with the seven fields. Copy an existing file for the shape.
2. Run `bash scripts/terms-check.sh`. It names the file and the field when one is wrong.
3. Name the term in the skills that serve it (`terms:` in the skill's frontmatter) and in
   `kit/skills/routing.yaml`.

## What the check reads

`scripts/terms-check.sh` reads four things and prints one `x <where>: <reason>` line per defect:
the term files; every `home` against `bin/cckit` (the first word of `cli`), `skills/` or
`.claude/skills/` and the rule path; `kit/skills/routing.yaml` (every skill routed, every entry naming
a real skill and a real term or `none`, each skill's `terms:` line equal to its routes); and the
"Which skill does what" table in `AGENTS.md`, one row per skill with the same tasks and terms.
`bash scripts/check.sh` runs it in warn mode. `scripts/terms-check-test.sh` is its test.

## Reading them

```bash
bash scripts/terms-check.sh            # validate every term; print the counts
bash scripts/terms-check.sh --json      # the same counts as one JSON object
jq -r '.definition' ontology/terms/Effort.json
```
