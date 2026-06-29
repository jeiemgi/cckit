import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
  site: 'https://cckit.dev',
  integrations: [
    starlight({
      title: 'cckit',
      description: 'A project operating system for coding agents — the full GitHub work lifecycle as a CLI, drivable by Claude Code and any agent.',
      social: { github: 'https://github.com/jeiemgi/cckit' },
      favicon: '/favicon.svg',
      // SEO / social share. Starlight already emits canonical, description, sitemap, and
      // title/OG tags from `site` + page frontmatter; this adds the social image + card type.
      head: [
        { tag: 'meta', attrs: { property: 'og:image', content: 'https://cckit.dev/og.png' } },
        { tag: 'meta', attrs: { property: 'og:image:alt', content: 'cckit — the full GitHub work lifecycle as a CLI' } },
        { tag: 'meta', attrs: { property: 'og:type', content: 'website' } },
        { tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
        { tag: 'meta', attrs: { name: 'twitter:image', content: 'https://cckit.dev/og.png' } },
      ],
      // The Designer owns the visual theme — this file is the single hook (elegant + sober,
      // never Claude/Anthropic colors). Placeholder until the Designer's spec lands.
      customCss: ['./src/styles/theme.css'],
      sidebar: [
        { label: 'Start', items: [
          { label: 'Introduction', slug: 'index' },
          { label: 'Getting started', slug: 'getting-started' },
        ]},
        { label: 'Guides', items: [
          { label: 'CLI reference', slug: 'cli-reference' },
          { label: 'Driving cckit from agents', slug: 'agents' },
          { label: 'Config & permissions', slug: 'config-and-permissions' },
        ]},
        { label: 'Reference', items: [
          { label: 'Security & secret guard', slug: 'security' },
          { label: '"Built with cckit" badge', slug: 'badge' },
        ]},
      ],
    }),
  ],
});
