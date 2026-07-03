import { defineCollection, z } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';

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
    // Rendered as chips above the first step.
    prerequisites: z.array(z.string()).default([]),
    // Short label on the social card, e.g. "Security" or "Parallel work".
    ogTag: z.string().optional(),
    // Extra target keywords (kept out of the visible copy; used for meta + intent tracking).
    keywords: z.array(z.string()).default([]),
    // Slugs of sibling tutorials for the internal-link cluster.
    related: z.array(z.string()).default([]),
  })
  .optional();

export const collections = {
  docs: defineCollection({
    loader: docsLoader(),
    schema: docsSchema({ extend: z.object({ tutorial }) }),
  }),
};
