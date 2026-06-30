import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import react from '@astrojs/react';

// Documented version, shown as a header badge so readers know which cckit version these docs
// describe (and can jump to older docs via the tagged releases). Read from THIS package.json —
// version-bump.sh keeps it in lockstep with the root version + git tags. Reading the local file
// (not the repo root) keeps the build self-contained: Vercel's project root is docs-site, so the
// repo root isn't uploaded on a CLI deploy.
const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8'));

// https://astro.build/config
export default defineConfig({
  // Live domain. cckit.dev is the future canonical home (DNS coming soon); until it
  // points here, the deployed site is cckit.vercel.app so canonical + OG resolve.
  site: 'https://cckit.vercel.app',
  vite: { define: { __CCKIT_VERSION__: JSON.stringify(pkg.version) } },
  integrations: [
    react(),
    starlight({
      title: 'cckit',
      // Header version badge — prepended to the social icons (see src/components/SocialIcons.astro).
      components: { SocialIcons: './src/components/SocialIcons.astro' },
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
        { label: 'Installation', items: [
          { label: 'Introduction', slug: 'index' },
          { label: 'Installing cckit', slug: 'install' },
        ]},
        { label: 'Getting started', items: [
          // Starred entry point — the place to begin.
          { label: 'Getting started', slug: 'getting-started', badge: { text: 'Start here', variant: 'success' } },
          { label: 'How to read this guide', slug: 'how-to-read' },
          { label: 'Showcase', slug: 'showcase' },
        ]},
        { label: 'Learning', items: [
          { label: 'CLI reference', slug: 'cli-reference' },
          { label: 'Cookbook', slug: 'cookbook' },
          { label: 'Adopting cckit', slug: 'adoption' },
          { label: 'Config & permissions', slug: 'config-and-permissions' },
        ]},
        { label: 'Agents', items: [
          { label: 'Driving cckit from agents', slug: 'agents' },
          { label: 'The copilot loop', slug: 'copilot' },
          { label: 'Adapters', slug: 'adapters' },
          { label: 'Browser debug', slug: 'debug' },
        ]},
        { label: 'Git mechanisms', items: [
          { label: 'The GitHub cycle', slug: 'github-cycle' },
          { label: 'Efforts, waves & worktrees', slug: 'efforts-and-waves' },
          { label: 'Releasing', slug: 'releasing' },
        ]},
        { label: 'Skills cckit ships', items: [
          { label: 'Skills catalog', slug: 'skills' },
        ]},
        { label: 'Reference', items: [
          { label: 'Security & secret guard', slug: 'security' },
          { label: '"Built with cckit" badge', slug: 'badge' },
        ]},
      ],
    }),
  ],
});
