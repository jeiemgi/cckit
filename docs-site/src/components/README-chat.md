# Chat and Outcomes: authoring a guide step

`<Chat>` is the conversation window every guide step leads with. `<Outcomes>` is the collapsed block under it.

Import them in the page: `import Chat from '../../../components/Chat.astro';` (adjust the `../` count; the Spanish twin under `es/` has one more).

| Prop | Notes |
| --- | --- |
| `title` | required; becomes the aria-label |
| `say` | required; what a person types; also the copy payload |
| `ran` | Software only, required there: a command, a list of commands, or `{ cmd, output }` items. A Marketing page that sets it fails the build |
| `output` | real output, a string or a list of lines (use a list: MDX strips the indentation of a multi-line string) |
| `means` | the "What this means" line |
| `project` | default "Bakery site" |
| slot | the agent's reply, plain words |

`<Outcomes of="<command>">` wraps the Markdown table of outputs, meanings and exit codes. The summary counts the rows. `title` replaces the generated summary.

## Truth rules

1. `say` is what a person would type; `ran` is a real command with real flags, checked against `AGENTS.md` and `bin/cckit`. No literal issue or task numbers outside an output sample.
2. `output` is real: from a run on the Bakery project, from a read-only verb run there, or from an expected string a test in `scripts/` asserts. With none of those, omit it.
3. Only trim output with a line `…`; replace an absolute path with `<project>`.
4. The reply says what happened and claims nothing the command did not do.
5. Say "your agent" (Software) or "your assistant" (Marketing, es "tu asistente"); never "Ask Claude". Marketing windows carry no command and no output, and are written in both languages.

## Software

```mdx
<Chat
  title="checking which cckit version the Bakery site is on"
  say="Is the Bakery site on the current cckit version?"
  ran="cckit update"
  output="⡶ / claude-kit · v0.9.0  al día · up to date"
  means="Checking is safe, it changes nothing."
>
  The Bakery site is on the installed version.
</Chat>
```

## Marketing

```mdx
<Chat
  title="handing over the bakery landing page"
  say="Make a landing page for the bakery: the name and a tagline at the top, three products with prices, opening hours, and a contact form."
  means="Nothing is public yet. You read the page and approve it or ask for changes."
>
  Done. Here is the link to review it.
</Chat>
```
