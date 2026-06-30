---
name: docs-writer
description: >
  Write and edit end-user documentation in the house voice: kind but robust, ADHD-oriented and
  scannable, ZERO analogies, beginner-inclusive but expert-skippable. Encodes the page template
  (title → one-line description → self-explanatory left-to-right diagram → body → next-section
  buttons) and the diagram discipline (interactive, left-to-right, self-explanatory, never
  repetitive). Use it to keep every docs page readable by people with low software knowledge
  without watering down the substance.
when_to_use: >
  When writing or editing any documentation page meant for humans — guides, getting-started,
  concept pages, how-to pages, reference intros. Use it before drafting (to lay out the page) and
  after drafting (to run the checklist). Not for code comments, commit messages, or PR bodies.
metadata:
  version: 1.0.0
---

# docs-writer — the house voice for human documentation

Documentation here is read by people with low software knowledge. It must still be correct and
complete for experts. The whole skill is one promise: **a beginner can follow the flow, and an
expert can skip to the part they need — on the same page.**

You write the page so both happen at once.

## The reader

- The lowest-baseline reader has barely used a terminal. Write so they are never lost.
- The expert reader knows git, PRs, and agents. Write so they can skip past the basics in seconds.
- Both read the same page. You do not fork the docs by skill level — you **structure** the page so
  the basic material is clearly marked and easy to scroll past.

## Voice rules (non-negotiable)

1. **No analogies. Ever.** Do not say "think of it like…", "it's basically a…", "imagine a…".
   Explain the actual thing in plain words. If a sentence starts to compare the topic to something
   else, delete it and describe the topic directly.
2. **Kind but robust.** Warm, plain, encouraging — and still precise. Kindness is short sentences
   and no jargon-dumping, not vagueness. Never sacrifice a correct detail to sound friendly.
3. **Not "so technical."** Use the plain word over the insider word. When a technical term is
   unavoidable, define it in one short clause the first time it appears, then use it freely.
4. **ADHD-oriented.** One idea per paragraph. Short paragraphs (1–3 sentences). Front-load the
   point — the first words of every paragraph, bullet, and heading carry the meaning. Generous
   headings so the page is skimmable. No walls of text.
5. **Lead with the verb / the outcome.** "Open a pull request to…" beats "In order to be able to
   open a pull request, you will…". Cut "in order to", "simply", "just", "basically", "of course".
6. **Show, don't promise.** Prefer a real command, a real screenshot, a real diagram over a
   paragraph describing one.

## The page template

Every page follows this order, top to bottom:

1. **Title** — the name of the thing or the task. Plain. No cleverness.
2. **One-line description** — a single sentence under the title saying what this page lets the
   reader do or understand. This is the whole page in one breath.
3. **Self-explanatory diagram** — a left-to-right diagram of the flow, placed high on the page,
   that a reader could understand with the title alone. See *Diagram discipline* below. If the
   page has no flow worth drawing, skip this — do not force a diagram.
4. **The body** — the rest of the docs: concepts, steps, the how and the why, and inline
   **links to learn** more (definitions, deeper pages, external references). This is where the
   beginner-only material lives, clearly headed so experts scroll past it.
5. **Next-section buttons** — at the bottom, one or two clear buttons to the next step(s) in the
   journey. Never leave the reader at a dead end.

Hold the order. Title, then the one-liner, then the picture, then the words, then the way out.

### Skeleton

```mdx
# <Plain title>

<One sentence: what you can do or understand after this page.>

<FlowDiagram .../>   {/* left-to-right, self-explanatory, only if there's a flow */}

## <First concept — front-loaded heading>
<Short paragraph. One idea. Plain words. A [link to learn](…) where useful.>

## <Steps, if this is a how-to>
<Steps component: 1, 2, 3 — one action each.>

> [!NOTE]
> <Beginner aside: a basic point experts can skip, clearly marked.>

---
<Next-section buttons: → Next step  ·  → Related concept>
```

## Diagram discipline

- **Interactive, left-to-right.** Diagrams are interactive (React Flow / SVG) and flow left to
  right, following how the reader reads.
- **Self-explanatory.** A diagram must make sense from the page title alone — labels are plain
  words, the arrows tell the story, no legend required to grasp the shape.
- **Diagram the flow, not the prose.** Draw a flow when seeing it is faster than reading it:
  sequences, branches, parallel work, lifecycles. Do not draw a diagram that just restates a
  sentence.
- **Never repetitive.** If two pages share a flow, draw it once on the most relevant page and link
  to it from the other. The same diagram should not appear twice.
- **Pair with steps, don't duplicate them.** The diagram shows the shape; a Steps list gives the
  exact actions. They complement each other — they do not repeat each other word for word.

## Scannability mechanics

- Headings every few paragraphs. A reader scanning only the headings should still get the gist.
- Bold the **lead word** of a bullet when the bullets are a list of distinct things.
- Lists over prose for anything enumerable (steps, options, requirements).
- Callouts for the things that interrupt: a NOTE for "good to know", a CAUTION for "this can bite
  you", a TIP for a shortcut. Use them sparingly so they keep their weight.
- Code and commands in code blocks, never inline-buried in a paragraph.
- One screen, one idea: if a section runs long, it is probably two sections.

## Beginner-inclusive, expert-skippable

- Put the absolute-basics content (what a terminal is, how to run a command, what a branch is) in
  its own clearly-headed section or aside, so an expert sees the heading and scrolls past in one
  motion.
- Never make the expert read the basics to reach the substance. Never make the beginner hunt for
  the basics because they were assumed away.
- Mark the entry point. If a section is "start here for total beginners", say so in the heading.

## Before you finish — checklist

- [ ] Title is plain; the one-line description says what the page delivers.
- [ ] If there's a flow, a left-to-right self-explanatory diagram sits near the top — and it is
      not a redrawn paragraph.
- [ ] **Zero analogies.** Re-read every sentence that compares the topic to anything else; rewrite
      it to describe the topic directly.
- [ ] Every technical term is defined the first time, in one clause.
- [ ] Paragraphs are short and front-loaded; the page is skimmable by headings alone.
- [ ] Beginner-only material is clearly headed so experts can skip it.
- [ ] No "simply", "just", "basically", "in order to", "of course".
- [ ] Next-section buttons at the bottom — no dead end.
- [ ] A reader with low software knowledge could follow the flow start to finish.
