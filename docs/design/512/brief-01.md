# Claude delivery 01: explain how the tools connect

You are the implementation delegate. Codex directs and reviews; José owns the product.
Read `AGENTS.md`, `.claude/rules/delegation-brief.md`, `.claude/skills/concrete/SKILL.md`,
`.claude/skills/karpathy-guidelines/SKILL.md` and `docs/design/512/README.md` first.
Apply concrete before durable prose: cut by named offense, never word count; preserve evidence,
commands, paths and limitations. Resolve unverifiable claims at the evidence gap.

Repository `jeiemgi/cckit`, base `develop`, Projects v2 off. Work only in the current
`task/512-docs-guides-less-text-more-visual` worktree. No reset, merge, deployment, new dependency,
or writes to the primary checkout. Do not create additional agents. This is a sequential delivery.
Do not change account settings, read secrets or attempt permission bypasses. Report restrictions.

## Objective

Implement a reusable, responsive explanation of the relationship between a coding agent,
cckit's project instructions, the user's project and GitHub. Include an accessible staged view
that teaches one small change from request to reviewed PR. Model merge as a separate optional
step and state that deployment is configured separately. Use the appointment-booking example
in EN/ES; the reader can use their own project.

## Owned files

- New components under `docs-site/src/components/learning/`.
- Two new sample pages `docs-site/src/content/docs/learn/how-the-tools-connect.mdx`
  and `docs-site/src/content/docs/es/learn/how-the-tools-connect.mdx`.
- A delivery report `docs/design/512/delivery-01.md`.

Do not change navigation, global CSS, current guides, package manifests or existing diagrams.
Use component-scoped CSS, existing fonts and dependencies. This bounded delivery establishes
the pattern for later home/navigation work. Do not publish fake CLI output or fake screenshots.

## Acceptance

- A readable static explanation exists before any JavaScript loads; no canvas-only explanation.
- Prev/next, replay and pause are keyboard accessible with clear labels and disabled states.
  If auto-play exists, it is opt-in, stops on user interaction, and respects reduced motion.
- Diagram text does not shrink to fit a whole graph. Stack on narrow screens.
- Light and dark styles have visible focus and contrast; decorative characters carry no facts.
- Explain branch/worktree/PR at the step that needs them, without an up-front term dump.
- Preserve truth: checks are configured, worktree conflicts remain possible, PR review is not
  deployment. Do not make every consumer use GitHub if explaining local light-task alternatives.
- Build with `pnpm --dir docs-site build`. Inspect the output for both routes. Record the actual
  commands/results and remaining browser review in the report.

Finish with files changed, validation, risks, and next review action. If local git writes fail,
leave the files and report intact. Do not claim a commit or PR was created without evidence.
