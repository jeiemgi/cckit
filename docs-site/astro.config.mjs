import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightDocSearch from '@astrojs/starlight-docsearch';
import react from '@astrojs/react';
import sitemap from '@astrojs/sitemap';
import rehypeExternalLinks from 'rehype-external-links';

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

// Analytics + Search Console — same optional-env pattern as Algolia above: both are no-ops until
// set, so the build never breaks for a fresh clone. GA4 is free with no event cap (unlike Vercel's
// own Web Analytics, which pauses collection once the Hobby plan's monthly cap is hit), which is
// why it's the traffic layer here; Vercel Speed Insights (added below, near-zero setup since the
// site is already on Vercel) covers Core Web Vitals instead.
const GA_MEASUREMENT_ID = envVar('PUBLIC_GA_MEASUREMENT_ID');
const GSC_VERIFICATION = envVar('PUBLIC_GSC_VERIFICATION');

// https://astro.build/config
export default defineConfig({
  // Live domain. cckit.dev is the production canonical home; canonical + OG resolve
  // against it. cckit.vercel.app stays as the preview URL for non-production deploys.
  site: 'https://cckit.dev',
  // Keep old docs URLs alive after renames.
  redirects: {
    '/copilot': '/wave/', // `cckit copilot` → `cckit wave`
    '/run-your-first-lifecycle': '/initialize/', // lifecycle page reframed as the init tutorial
  },
  vite: { define: { __CCKIT_VERSION__: JSON.stringify(pkg.version) } },
  // External links open in a new tab (safely) and get an "opens externally" icon via CSS
  // (a[target="_blank"] in theme.css). Relative in-site links are untouched.
  markdown: {
    rehypePlugins: [[rehypeExternalLinks, { target: '_blank', rel: ['noopener', 'noreferrer'] }]],
  },
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
        // Head override swaps the single global og.png for a per-page generated card
        // (/og/<id>.png). Its per-page og:image/twitter:image replace the global ones below.
        Head: './src/components/Head.astro',
        ...(DEV ? { PageSidebar: './src/components/DevAnnotate.astro' } : {}),
      },
      description: 'Be the architect — cckit runs the mechanics. The full GitHub work lifecycle as a CLI that turns your Git into retrievable, efficient context, drivable by Claude Code and any agent.',
      social: [{ icon: 'github', label: 'GitHub', href: 'https://github.com/jeiemgi/cckit' }],
      favicon: '/favicon.svg',
      // SEO / social share. Starlight emits canonical, description, sitemap, and title/OG tags from
      // `site` + page frontmatter; the per-page og:image/twitter:image are emitted by the Head
      // override (src/components/Head.astro) so each page gets its own generated card.
      head: [
        // Algolia site verification — lets the Algolia Crawler confirm ownership of the site.
        { tag: 'meta', attrs: { name: 'algolia-site-verification', content: '9E796471F3020A1F' } },
        { tag: 'meta', attrs: { property: 'og:type', content: 'website' } },
        // Google Search Console ownership verification (meta-tag method) — set PUBLIC_GSC_VERIFICATION
        // to the content value Search Console gives you when adding cckit.dev as a property.
        ...(GSC_VERIFICATION
          ? [{ tag: 'meta', attrs: { name: 'google-site-verification', content: GSC_VERIFICATION } }]
          : []),
        // GA4 — set PUBLIC_GA_MEASUREMENT_ID (a "G-XXXXXXX" id) in Vercel project env vars to enable.
        ...(GA_MEASUREMENT_ID
          ? [
              { tag: 'script', attrs: { async: true, src: `https://www.googletagmanager.com/gtag/js?id=${GA_MEASUREMENT_ID}` } },
              {
                tag: 'script',
                content: `window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}gtag('js',new Date());gtag('config','${GA_MEASUREMENT_ID}');`,
              },
            ]
          : []),
      ],
      // The Designer owns the visual theme — this file is the single hook (elegant + sober,
      // never Claude/Anthropic colors). Placeholder until the Designer's spec lands.
      customCss: ['./src/styles/theme.css'],
      // Split by subject with a clear separation of concerns:
      //   Get started — orient + set up · Concepts — how it works · Guides — how to do things ·
      //   Reference — look things up. Each group is one kind of content, not a stage.
      sidebar: [
        { label: 'Get started', items: [
          { label: 'The idea', slug: 'philosophy', badge: { text: 'Human-written', variant: 'tip' } },
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
        { label: 'Tutorials', items: [
          { label: 'All tutorials', slug: 'tutorials' },
          { label: 'Set up cckit in a repo', slug: 'tutorials/set-up-cckit-in-a-repo' },
          { label: 'Add cckit to an existing repo', slug: 'tutorials/adopt-cckit-in-an-existing-repo' },
          { label: 'Issue → merged PR', slug: 'tutorials/take-a-github-issue-to-a-merged-pr' },
          { label: 'Break a feature into an effort', slug: 'tutorials/break-a-feature-into-an-effort' },
          { label: 'Run a wave in parallel', slug: 'tutorials/run-issues-in-parallel-with-a-wave' },
          { label: 'Run Claude Code unattended', slug: 'tutorials/run-claude-code-unattended' },
          { label: 'Drive Claude Code headless in CI', slug: 'tutorials/drive-claude-code-headless-in-ci' },
          { label: 'Stop Claude committing secrets', slug: 'tutorials/stop-claude-committing-secrets' },
          { label: 'Keep private data out of AI commits', slug: 'tutorials/keep-private-data-out-of-ai-commits' },
          { label: 'Control what Claude Code can do', slug: 'tutorials/control-what-claude-code-can-do' },
          { label: 'Give Claude Code persistent memory', slug: 'tutorials/give-claude-code-persistent-memory' },
          { label: 'Run checks with cckit hooks', slug: 'tutorials/run-checks-with-cckit-hooks' },
          { label: 'Debug a web page with Claude Code', slug: 'tutorials/debug-a-web-page-with-claude-code' },
          { label: 'Extend Claude Code with skills', slug: 'tutorials/extend-claude-code-with-skills' },
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
    // Starlight uses this sitemap integration instead of its default when one is present. Keep the
    // /social/ export templates (IG feed + story cards) out of the sitemap — they're internal
    // manual-post assets, not pages we want crawled or indexed.
    sitemap({ filter: (page) => !page.includes('/social/') }),
  ],
});
