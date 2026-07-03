import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightDocSearch from '@astrojs/starlight-docsearch';
import react from '@astrojs/react';

// .env files are NOT injected into process.env inside astro.config.mjs. Vercel DOES populate
// process.env from the project's env vars at build, so prefer that; locally, fall back to parsing
// docs-site/.env directly (no vite/dotenv dependency needed). Used only for the DocSearch creds below.
const readDotenv = (name) => {
  try {
    const m = readFileSync(new URL('./.env', import.meta.url), 'utf8').match(
      new RegExp('^' + name + '=(.*)$', 'm'),
    );
    return m ? m[1].trim() : undefined;
  } catch {
    return undefined;
  }
};
const envVar = (name) => process.env[name] ?? readDotenv(name);

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

// Algolia DocSearch — replaces the default Pagefind search when configured. The three values are
// public, client-side DocSearch credentials (the API key is search-only); they're read from env so
// they aren't committed and so the build works (falls back to Pagefind) until they're set. Provide
// them in docs-site/.env locally and in the Vercel project settings for production.
const ALGOLIA = {
  appId: envVar('ALGOLIA_APP_ID'),
  apiKey: envVar('ALGOLIA_SEARCH_API_KEY') || envVar('ALGOLIA_API_KEY'),
  indexName: envVar('ALGOLIA_INDEX_NAME'),
};
const HAS_DOCSEARCH = Boolean(ALGOLIA.appId && ALGOLIA.apiKey && ALGOLIA.indexName);

// https://astro.build/config
export default defineConfig({
  // Live domain. cckit.dev is the future canonical home (DNS coming soon); until it
  // points here, the deployed site is cckit.vercel.app so canonical + OG resolve.
  site: 'https://cckit.vercel.app',
  // Keep old docs URLs alive after renames.
  redirects: {
    '/copilot': '/wave/', // `cckit copilot` → `cckit wave`
    '/run-your-first-lifecycle': '/initialize/', // lifecycle page reframed as the init tutorial
  },
  vite: { define: { __CCKIT_VERSION__: JSON.stringify(pkg.version) } },
  integrations: [
    react(),
    starlight({
      title: 'cckit',
      // Algolia DocSearch (when ALGOLIA_* env vars are set); otherwise the default Pagefind search.
      plugins: HAS_DOCSEARCH
        ? [starlightDocSearch({ appId: ALGOLIA.appId, apiKey: ALGOLIA.apiKey, indexName: ALGOLIA.indexName })]
        : [],
      // Wrap long code lines instead of a horizontal scrollbar (the long copilot prompts especially).
      expressiveCode: { defaultProps: { wrap: true } },
      // Header version badge — prepended to the social icons (see src/components/SocialIcons.astro).
      // Footer override mounts the dev-only annotation toolbar (stripped from production).
      components: {
        SocialIcons: './src/components/SocialIcons.astro',
        // Footer override is ALWAYS on (it carries the standing legal disclaimer). The dev-only
        // Agentation toolbar lives in a SEPARATE override (PageSidebar) that's registered only in
        // dev, so its island is never collected into the production build.
        Footer: './src/components/Footer.astro',
        ...(DEV ? { PageSidebar: './src/components/DevAnnotate.astro' } : {}),
      },
      description: 'A project operating system for coding agents — the full GitHub work lifecycle as a CLI, drivable by Claude Code and any agent.',
      social: { github: 'https://github.com/jeiemgi/cckit' },
      favicon: '/favicon.svg',
      // SEO / social share. Starlight already emits canonical, description, sitemap, and
      // title/OG tags from `site` + page frontmatter; this adds the social image + card type.
      head: [
        // Algolia site verification — lets the Algolia Crawler confirm ownership of the site.
        { tag: 'meta', attrs: { name: 'algolia-site-verification', content: '9E796471F3020A1F' } },
        { tag: 'meta', attrs: { property: 'og:image', content: 'https://cckit.vercel.app/og.png' } },
        { tag: 'meta', attrs: { property: 'og:image:alt', content: 'cckit — the full GitHub work lifecycle as a CLI' } },
        { tag: 'meta', attrs: { property: 'og:type', content: 'website' } },
        { tag: 'meta', attrs: { name: 'twitter:card', content: 'summary_large_image' } },
        { tag: 'meta', attrs: { name: 'twitter:image', content: 'https://cckit.vercel.app/og.png' } },
      ],
      // The Designer owns the visual theme — this file is the single hook (elegant + sober,
      // never Claude/Anthropic colors). Placeholder until the Designer's spec lands.
      customCss: ['./src/styles/theme.css'],
      // Split by subject with a clear separation of concerns:
      //   Get started — orient + set up · Concepts — how it works · Guides — how to do things ·
      //   Reference — look things up. Each group is one kind of content, not a stage.
      sidebar: [
        { label: 'Get started', items: [
          { label: 'Overview', slug: 'index' },
          { label: 'How to read this guide', slug: 'how-to-read' },
          { label: 'Quickstart', slug: 'getting-started', badge: { text: 'Start here', variant: 'success' } },
          { label: 'Install cckit', slug: 'install' },
          { label: 'Check your platform', slug: 'check-your-platform' },
          { label: 'Initialize cckit', slug: 'initialize' },
          { label: 'Set up memory', slug: 'memory', badge: { text: 'Optional', variant: 'note' } },
          { label: 'Adopting cckit on a repo', slug: 'adoption' },
          { label: 'Showcase', slug: 'showcase' },
        ]},
        { label: 'Concepts', items: [
          { label: 'The GitHub cycle', slug: 'github-cycle' },
          { label: 'Efforts, waves & worktrees', slug: 'efforts-and-waves' },
          { label: 'Hooks', slug: 'hooks' },
          { label: 'Adapters', slug: 'adapters' },
        ]},
        { label: 'Guides', items: [
          { label: 'All guides', slug: 'guides' },
          { label: 'Wave', slug: 'wave' },
          { label: 'Driving cckit from agents', slug: 'agents' },
          { label: 'Cookbook', slug: 'cookbook' },
          { label: 'Browser debug', slug: 'debug' },
        ]},
        { label: 'Reference', items: [
          { label: 'CLI reference', slug: 'cli-reference' },
          { label: 'Skills cckit ships', slug: 'skills' },
          { label: 'Tags directory', slug: 'tags' },
          { label: 'Config & permissions', slug: 'config-and-permissions' },
          { label: 'Releasing', slug: 'releasing' },
          { label: 'Security & secret guard', slug: 'security' },
          { label: '"Built with cckit" badge', slug: 'badge' },
          { label: 'Disclaimer & trademarks', slug: 'disclaimer' },
        ]},
      ],
    }),
  ],
});
