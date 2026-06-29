# Knowledge base — governance

The project's knowledge base lives in `knowledge/` (config: `knowledge.dir` in
`.claude/kit.config.json`). It is the durable, agent-readable source of truth for product and
project knowledge: brand, design system, decisions, research, reference docs.

## Hard rules

1. **If a file exists in `knowledge/`, it is current.** Superseded docs are **deleted** — git
   history is the archive. Never keep a dead doc around "for reference"; never create an
   `archive/` folder.
2. **The latest decision wins.** When two docs conflict, the decision log + the `updated`
   frontmatter date resolve it. Fix the loser in the same PR you notice it.
3. **Every doc carries frontmatter** — required, lint-enforced:

   ```yaml
   ---
   status: canonical | reference | historical
   owner: <role>          # which agent/role maintains it
   updated: YYYY-MM-DD    # last substantive change
   ---
   ```

   `canonical` = source of truth for its topic · `reference` = consultable, not normative ·
   `historical` = context only, decisions inside may be superseded.
4. **`knowledge/INDEX.md` is the manifest** — one row per doc (file, topic, status, owner,
   updated). Agents read INDEX first to find the canonical doc per topic. A new doc lands in
   INDEX **in the same PR**, or the lint fails.
5. **Research becomes knowledge or it evaporates.** A research session's durable output is a
   `reference` doc in `knowledge/` + an INDEX row — not a chat transcript.
6. **Plans are not knowledge.** Plans (deliverable contracts) live in the plans dir and complete
   via `status:` flip — see `plan-output-format.md`. Knowledge docs describe what IS; plans
   describe what's BEING BUILT.

## Enforcement

- `scripts/knowledge-lint.sh` validates all of the above (frontmatter, INDEX completeness, live
  refs, plan Deliverables contract). Run it locally before a knowledge PR; wire it into CI on
  PRs touching `knowledge/**` or the plans dir.
- Project-specific extra checks go in `scripts/knowledge-lint.local.sh` (sourced by the kit
  script; survives `/kit-update` refreshes).
