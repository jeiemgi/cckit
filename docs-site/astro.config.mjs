import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
  // Live domain. cckit.dev is the future canonical home (DNS coming soon); until it
  // points here, the deployed site is cckit.vercel.app so canonical + OG resolve.
  site: 'https://cckit.vercel.app',
  integrations: [
    starlight({
      title: 'cckit',
      description: 'A project operating system for coding agents — the full GitHub work lifecycle as a CLI, drivable by Claude Code and any agent.',
      social: { github: 'https://github.com/jeiemgi/cckit' },
      favicon: '/favicon.svg',
      // SEO / social share. Starlight already emits canonical, description, sitemap, and
      // title/OG tags from `site` + page frontmatter; this adds the social image + card type.
      head: [
        { tag: 'meta', attrs: { property: 'og:image', content: 'https://cckit.vercel.app/og.png' } },
        { tag: 'meta', attrs: { property: 'og:image:alt', content: 'cckit — the full GitHub work lifecycle as a CLI' } },
        { tag: 'meta', attrs: { property: 'og:type', content: 'website' } },
        { tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
        { tag: 'meta', attrs: { name: 'twitter:image', content: 'https://cckit.vercel.app/og.png' } },
      ],
      // The Designer owns the visual theme — this file is the single hook (elegant + sober,
      // never Claude/Anthropic colors). Placeholder until the Designer's spec lands.
      customCss: ['./src/styles/theme.css'],
      sidebar: [
        { label: 'Start', items: [
          { label: 'Introduction', slug: 'index' },
          { label: 'Getting started', slug: 'getting-started' },
          { label: 'Installing cckit', slug: 'install' },
        ]},
        { label: 'Guides', items: [
          { label: 'CLI reference', slug: 'cli-reference' },
          { label: 'Driving cckit from agents', slug: 'agents' },
          { label: 'Adopting cckit', slug: 'adoption' },
          { label: 'Config & permissions', slug: 'config-and-permissions' },
          { label: 'Browser debug', slug: 'debug' },
        ]},
        { label: 'Reference', items: [
          { label: 'Adapters', slug: 'adapters' },
          { label: 'Releasing', slug: 'releasing' },
          { label: 'Security & secret guard', slug: 'security' },
          { label: '"Built with cckit" badge', slug: 'badge' },
        ]},
      ],
    }),
  ],
});
