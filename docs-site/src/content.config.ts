import { defineCollection, z } from 'astro:content';
import { docsLoader, i18nLoader } from '@astrojs/starlight/loaders';
import { docsSchema, i18nSchema } from '@astrojs/starlight/schema';
import { docSearchI18nSchema } from '@astrojs/starlight-docsearch/schema';

// Tutorial template fields. Only tutorial pages set `tutorial:` — every field is optional for the
// rest of the docs. The template components (TutorialMeta, TutorialSchema) and the OG-card endpoint
// read these off the route entry, so an author fills frontmatter once and the page, its meta tags,
// its JSON-LD, and its social card all derive from it.
const tutorial = z
  .object({
    // The bare job phrased as a verb, e.g. "stop Claude committing secrets" — used in HowTo JSON-LD.
    job: z.string(),
    difficulty: z.enum(['beginner', 'intermediate', 'advanced']).default('beginner'),
    // Human read-time / effort, e.g. "5 min".
    time: z.string(),
    // The "Before you start" checklist in TutorialMeta: full sentences. An item is a string, or
    // { text, link, href }: `link` is the words that become a link (found inside `text`, else
    // appended after it). Backticks in `text` render as inline code.
    prerequisites: z
      .array(z.union([z.string(), z.object({ text: z.string(), link: z.string(), href: z.string() })]))
      .default([]),
    // Short label on the social card, e.g. "Security" or "Parallel work".
    ogTag: z.string().optional(),
    // Extra target keywords (kept out of the visible copy; used for meta + intent tracking).
    keywords: z.array(z.string()).default([]),
    // Page ids of sibling guides (e.g. development/issue-to-merged-pr) for the internal-link cluster.
    related: z.array(z.string()).default([]),
  })
  .optional();

export const collections = {
  docs: defineCollection({
    loader: docsLoader(),
    schema: docsSchema({ extend: z.object({ tutorial }) }),
  }),
  // UI strings per language (src/content/i18n/{en,es}.json): the search trigger text and the
  // DocSearch modal strings (`docsearch.*` keys).
  i18n: defineCollection({
    loader: i18nLoader(),
    schema: i18nSchema({ extend: docSearchI18nSchema() }),
  }),
};
