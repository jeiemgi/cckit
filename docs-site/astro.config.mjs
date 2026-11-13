import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import { unified } from '@astrojs/markdown-remark';
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
  // against it. cckit.vercel.app and www.cckit.dev redirect here (308, set on the Vercel project).
  site: 'https://cckit.dev',
  // Keep old docs URLs alive after renames.
  redirects: {
    '/copilot': '/wave/', // `cckit copilot` → `cckit wave`
    '/run-your-first-lifecycle': '/initialize/', // lifecycle page reframed as the init tutorial
  },
  vite: { define: { __CCKIT_VERSION__: JSON.stringify(pkg.version) } },
  // External links open in a new tab (safely) and get an "opens externally" icon via CSS
  // (a[target="_blank"] in theme.css). Relative in-site links are untouched.
  // Astro 7 made Satteri the default Markdown processor; keep rendering on the `unified`
  // (remark/rehype) processor so output is byte-identical to Astro 6 and the rehype plugin below
  // still applies. `markdown.rehypePlugins` is the deprecated spelling of exactly this.
  markdown: {
    processor: unified({
      rehypePlugins: [[rehypeExternalLinks, { target: '_blank', rel: ['noopener', 'noreferrer'] }]],
    }),
  },
  integrations: [
    react(),
    starlight({
      title: 'cckit',
      // Two languages, one translated section. English is served at the root; Spanish under /es/.
      // Only the 7 Marketing pages exist in Spanish (src/content/docs/es/marketing/). Starlight
      // still builds an English fallback copy of every other page under /es/; those copies are
      // kept out of the sitemap below and marked noindex by the route middleware, and the language
      // picker is rendered on Marketing pages only (src/components/LanguageSelect.astro).
      defaultLocale: 'root',
      locales: {
        root: { label: 'English', lang: 'en' },
        es: { label: 'Español', lang: 'es' },
      },
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
        // SiteTitle override appends the Software / Marketing switch to the top bar.
        SiteTitle: './src/components/SiteTitle.astro',
        // LanguageSelect override shows the picker on Marketing pages only.
        LanguageSelect: './src/components/LanguageSelect.astro',
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
        // Google Consent Mode v2: consent defaults to DENIED before gtag loads, so GA sends only
        // cookieless "modeled" pings and sets no identifiers/cookies until the visitor accepts via
        // the ConsentBanner (src/components/ConsentBanner.astro, mounted from Footer.astro). A stored
        // 'granted' choice is re-applied here — early, before the first `config` ping — so returning
        // opted-in visitors are tracked from the first hit without re-prompting.
        ...(GA_MEASUREMENT_ID
          ? [
              { tag: 'script', attrs: { async: true, src: `https://www.googletagmanager.com/gtag/js?id=${GA_MEASUREMENT_ID}` } },
              {
                tag: 'script',
                content:
                  `window.dataLayer=window.dataLayer||[];function gtag(){dataLayer.push(arguments);}` +
                  `gtag('consent','default',{ad_storage:'denied',ad_user_data:'denied',ad_personalization:'denied',analytics_storage:'denied',wait_for_update:500});` +
                  `try{if(localStorage.getItem('cckit-consent')==='granted'){gtag('consent','update',{analytics_storage:'granted'});}}catch(e){}` +
                  `gtag('js',new Date());gtag('config','${GA_MEASUREMENT_ID}');`,
              },
            ]
          : []),
      ],
      // The Designer owns the visual theme — this file is the single hook (elegant + sober,
      // never Claude/Anthropic colors). Placeholder until the Designer's spec lands.
      customCss: ['./src/styles/theme.css'],
      // Per-track sidebars: this one array holds the entries of both tracks, and the route
      // middleware keeps only the entries of the track a page belongs to (src/routeData.ts).
      routeMiddleware: './src/routeData.ts',
      // Software: 19 entries in 4 groups, grouped by the job the reader is doing. Every other
      // Software page stays reachable by search and from the "All tutorials" / "All guides" pages.
      sidebar: [
        { label: 'Start', items: [
          { label: 'Overview', slug: 'index' },
          { label: 'Quickstart', slug: 'getting-started', badge: { text: 'Start here', variant: 'success' } },
          { label: 'Install', slug: 'install' },
          { label: 'Initialize', slug: 'initialize' },
        ]},
        { label: 'Ship one issue', items: [
          { label: 'The GitHub cycle', slug: 'github-cycle' },
          { label: 'Issue to merged PR', slug: 'tutorials/take-a-github-issue-to-a-merged-pr' },
          { label: 'Review gates', slug: 'review-gates' },
          { label: 'Hooks', slug: 'hooks' },
          { label: 'Security and secret guard', slug: 'security' },
        ]},
        { label: 'Ship many at once', items: [
          { label: 'Efforts, waves and worktrees', slug: 'efforts-and-waves' },
          { label: 'Break a feature into an effort', slug: 'tutorials/break-a-feature-into-an-effort' },
          { label: 'Run a wave in parallel', slug: 'tutorials/run-issues-in-parallel-with-a-wave' },
          { label: 'Run unattended', slug: 'tutorials/run-claude-code-unattended' },
          { label: 'Releasing', slug: 'releasing' },
        ]},
        { label: 'Look it up', items: [
          { label: 'CLI reference', slug: 'cli-reference' },
          { label: 'Config and permissions', slug: 'config-and-permissions' },
          { label: 'Skills cckit ships', slug: 'skills' },
          { label: 'Driving cckit from agents', slug: 'agents' },
          { label: 'All tutorials', slug: 'tutorials' },
          { label: 'All guides', slug: 'guides' },
        ]},
        // Marketing: 7 pages for a reader who never opens a terminal. The middleware shows these
        // as a flat list, without the group heading, on every page under /marketing/.
        { label: 'Marketing', translations: { es: 'Marketing' }, items: [
          { label: 'What cckit does for you', translations: { es: 'Qué hace cckit por ti' }, slug: 'marketing' },
          { label: 'Get set up', translations: { es: 'Prepara todo' }, slug: 'marketing/get-set-up' },
          { label: 'Your first piece', translations: { es: 'Tu primera pieza' }, slug: 'marketing/your-first-piece' },
          { label: 'Set your brand voice', translations: { es: 'Define tu voz de marca' }, slug: 'marketing/brand-voice' },
          { label: 'Plan and run a campaign', translations: { es: 'Planea y lleva una campaña' }, slug: 'marketing/campaigns' },
          { label: 'Who does what', translations: { es: 'Quién hace qué' }, slug: 'marketing/who-does-what' },
          { label: 'Words you will hear', translations: { es: 'Palabras que vas a escuchar' }, slug: 'marketing/words-you-will-hear' },
        ]},
      ],
    }),
    // Starlight uses this sitemap integration instead of its default when one is present. Keep the
    // /social/ export templates (IG feed + story cards) out of the sitemap — they're internal
    // manual-post assets, not pages we want crawled or indexed. Under /es/ only the Marketing pages
    // are Spanish; every other /es/ URL is an English fallback copy and stays out too.
    sitemap({
      filter: (page) => {
        const path = new URL(page).pathname;
        if (path.includes('/social/')) return false;
        return !path.startsWith('/es/') || path.startsWith('/es/marketing/');
      },
    }),
  ],
});
