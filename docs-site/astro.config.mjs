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

// Dev-only annotation toolbar: register the Footer override ONLY outside production, so the
// `agentation` island is never collected into `astro build` output (a runtime DEV gate still ships
// the chunk; gating at config time keeps it out entirely).
const DEV = process.env.NODE_ENV !== 'production';

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
      // Wrap long code lines instead of a horizontal scrollbar (the long copilot prompts especially).
      expressiveCode: { defaultProps: { wrap: true } },
      // Header version badge — prepended to the social icons (see src/components/SocialIcons.astro).
      // Footer override mounts the dev-only annotation toolbar (stripped from production).
      components: {
        SocialIcons: './src/components/SocialIcons.astro',
        // Footer override only in dev → the agentation toolbar island is never built for production.
        ...(DEV ? { Footer: './src/components/Footer.astro' } : {}),
      },
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
      // Ordered as a journey: orient + set up, then WHERE cckit enters your git workflow, then WHEN
      // you reach for it day to day, then everything to look up. Each group is a stage, not a bucket.
      sidebar: [
        { label: '1 · Start here', items: [
          { label: 'What cckit is', slug: 'index' },
          { label: 'How to read this guide', slug: 'how-to-read' },
          { label: 'Installing cckit', slug: 'install' },
          { label: 'Your first run', slug: 'getting-started', badge: { text: 'Start here', variant: 'success' } },
          { label: 'Showcase', slug: 'showcase' },
        ]},
        { label: '2 · How the work flows', items: [
          { label: 'The GitHub cycle', slug: 'github-cycle' },
          { label: 'Efforts, waves & worktrees', slug: 'efforts-and-waves' },
          { label: 'Hooks — when cckit acts for you', slug: 'hooks' },
        ]},
        { label: '3 · Using cckit day to day', items: [
          { label: 'The copilot loop', slug: 'copilot' },
          { label: 'Driving cckit from agents', slug: 'agents' },
          { label: 'Cookbook', slug: 'cookbook' },
          { label: 'Adopting cckit on a repo', slug: 'adoption' },
        ]},
        { label: '4 · Reference', items: [
          { label: 'CLI reference', slug: 'cli-reference' },
          { label: 'Skills cckit ships', slug: 'skills' },
          { label: 'Config & permissions', slug: 'config-and-permissions' },
          { label: 'Adapters', slug: 'adapters' },
          { label: 'Releasing', slug: 'releasing' },
          { label: 'Security & secret guard', slug: 'security' },
          { label: 'Browser debug', slug: 'debug' },
          { label: '"Built with cckit" badge', slug: 'badge' },
        ]},
      ],
    }),
  ],
});
