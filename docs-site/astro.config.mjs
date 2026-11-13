import { readFileSync } from 'node:fs';
import { defineConfig } from 'astro/config';
import { unified } from '@astrojs/markdown-remark';
import starlight from '@astrojs/starlight';
import starlightDocSearch from '@astrojs/starlight-docsearch';
import react from '@astrojs/react';
import sitemap from '@astrojs/sitemap';
import rehypeExternalLinks from 'rehype-external-links';
import marketingWords from './src/integrations/marketing-words.mjs';
import rehypeRecordTables from './src/lib/rehype-record-tables.mjs';

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
  // Keep old docs URLs alive after renames. Every target is a page, never another redirect. The
  // site builds static, so each entry is a meta-refresh page and an #anchor on the old URL is lost.
  // /copilot (`cckit copilot` became `cckit wave`) and /run-your-first-lifecycle predate the move of
  // the area pages under their area (effort 493); the rest are that move.
  redirects: {
    '/adoption': '/getting-started/existing-repo/',
    '/check-your-platform': '/getting-started/install/',
    '/copilot': '/development/waves/',
    '/debug': '/development/browser-debug/',
    '/efforts-and-waves': '/project-management/efforts-and-waves/',
    '/github-cycle': '/development/',
    '/guides': '/reference/',
    '/how-to-read': '/tags/',
    '/initialize': '/getting-started/initialize/',
    '/install': '/getting-started/install/',
    '/light-tasks': '/project-management/light-tasks/',
    '/multi-session': '/development/many-sessions/',
    '/qa-lane': '/review/qa-lane/',
    '/releasing': '/ship/releasing/',
    '/review-gates': '/review/gates/',
    '/review-pages': '/project-management/plan-pages/',
    '/run-your-first-lifecycle': '/getting-started/initialize/',
    '/security': '/review/secret-guard/',
    '/tutorials': '/software/',
    '/tutorials/add-your-own-integration': '/development/add-your-own-integration/',
    '/tutorials/adopt-cckit-in-an-existing-repo': '/getting-started/existing-repo/',
    '/tutorials/break-a-feature-into-an-effort': '/project-management/break-a-feature-into-an-effort/',
    '/tutorials/control-what-claude-code-can-do': '/review/control-what-agents-can-do/',
    '/tutorials/debug-a-web-page-with-claude-code': '/development/browser-debug/',
    '/tutorials/drive-claude-code-headless-in-ci': '/development/headless-in-ci/',
    '/tutorials/extend-claude-code-with-skills': '/development/extend-with-skills/',
    '/tutorials/find-code-with-a-code-graph': '/development/code-graph/',
    '/tutorials/give-claude-code-persistent-memory': '/memory/install-mempalace/',
    '/tutorials/have-an-agent-review-before-a-merge': '/review/agent-review/',
    '/tutorials/keep-private-data-out-of-ai-commits': '/review/keep-private-data-out/',
    '/tutorials/run-checks-with-cckit-hooks': '/development/checks-with-hooks/',
    '/tutorials/run-claude-code-unattended': '/development/run-unattended/',
    '/tutorials/run-issues-in-parallel-with-a-wave': '/development/run-a-wave-in-parallel/',
    '/tutorials/run-one-objective-unattended': '/development/run-one-objective-unattended/',
    '/tutorials/set-up-cckit-in-a-repo': '/getting-started/initialize/',
    '/tutorials/stop-claude-committing-secrets': '/review/stop-committing-secrets/',
    '/tutorials/summarize-long-files-with-a-local-model': '/development/local-model-digest/',
    '/tutorials/take-a-github-issue-to-a-merged-pr': '/development/issue-to-merged-pr/',
    '/tutorials/use-cckit-with-codex': '/getting-started/codex/',
    '/update': '/getting-started/update/',
    '/wave': '/development/waves/',
  },
  vite: { define: { __CCKIT_VERSION__: JSON.stringify(pkg.version) } },
  // External links open in a new tab (safely) and get an "opens externally" icon via CSS
  // (a[target="_blank"] in theme.css). Relative in-site links are untouched.
  // Astro 7 made Satteri the default Markdown processor; keep rendering on the `unified`
  // (remark/rehype) processor so output is byte-identical to Astro 6 and the rehype plugin below
  // still applies. `markdown.rehypePlugins` is the deprecated spelling of exactly this.
  markdown: {
    processor: unified({
      rehypePlugins: [
        [rehypeExternalLinks, { target: '_blank', rel: ['noopener', 'noreferrer'] }],
        // A table of records (3+ columns, a long cell) renders as record cards, not a grid (#494).
        rehypeRecordTables,
      ],
    }),
  },
  integrations: [
    // Stops `astro build` when a Marketing page says worktree, branch or PR.
    marketingWords(),
    react(),
    starlight({
      title: 'cckit',
      // Two languages, one translated section. English is served at the root; Spanish under /es/.
      // Only the 10 Marketing pages exist in Spanish (src/content/docs/es/marketing/). Starlight
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
      // Software: 42 entries. One link to the track's entry page, then the areas in the order a team
      // works in, then Reference. Every group is collapsed; Starlight opens the group that holds the
      // current page. A Software page that is not listed here is linked from its area's "More
      // guides" page or from /reference/, and search covers all of them.
      sidebar: [
        { label: 'Start here', slug: 'software' },
        { label: 'Philosophy', collapsed: true, items: [
          { label: 'The idea', slug: 'philosophy' },
          { label: 'The team: you and the agents', slug: 'philosophy/the-team' },
        ]},
        { label: 'Getting started', collapsed: true, items: [
          { label: 'What you set up, and why', slug: 'getting-started' },
          { label: 'Install and check', slug: 'getting-started/install' },
          { label: 'Initialize a project', slug: 'getting-started/initialize' },
          { label: 'Add cckit to an existing repo', slug: 'getting-started/existing-repo' },
          { label: 'Use cckit with Codex', slug: 'getting-started/codex' },
          { label: 'Update a project', slug: 'getting-started/update' },
        ]},
        { label: 'Memory', collapsed: true, items: [
          { label: 'Why an agent team needs memory', slug: 'memory' },
          { label: 'Install MemPalace', slug: 'memory/install-mempalace' },
          { label: 'How cckit uses memory', slug: 'memory/how-cckit-uses-it' },
        ]},
        { label: 'Project management', collapsed: true, items: [
          { label: 'Units of work, in Scrum terms', slug: 'project-management' },
          { label: 'Tech lead, PM and captain', slug: 'project-management/roles' },
          { label: 'Plans you answer on a page', slug: 'project-management/plan-pages' },
          { label: 'Efforts and waves in practice', slug: 'project-management/efforts-and-waves' },
          { label: 'Tasks without GitHub issues', slug: 'project-management/light-tasks' },
          { label: 'Break a feature into an effort', slug: 'project-management/break-a-feature-into-an-effort' },
        ]},
        { label: 'Design', collapsed: true, items: [
          { label: 'Why design has one owner', slug: 'design' },
          { label: 'Annotate the running interface', slug: 'design/annotate-the-ui' },
          { label: 'Run a UX audit', slug: 'design/ux-audit' },
        ]},
        { label: 'Development', collapsed: true, items: [
          { label: 'How one change is built', slug: 'development' },
          { label: 'Let the agent see the page', slug: 'development/browser-debug' },
          { label: 'Run work in parallel waves', slug: 'development/waves' },
          { label: 'Many sessions, one repository', slug: 'development/many-sessions' },
          { label: 'Take an issue to merged', slug: 'development/issue-to-merged-pr' },
          { label: 'More development guides', slug: 'development/more-guides' },
        ]},
        { label: 'Review', collapsed: true, items: [
          { label: 'Why nothing merges unreviewed', slug: 'review' },
          { label: 'Review gates', slug: 'review/gates' },
          { label: 'QA on a running stack', slug: 'review/qa-lane' },
          { label: 'The secret guard', slug: 'review/secret-guard' },
          { label: 'Agent review before a merge', slug: 'review/agent-review' },
          { label: 'More review guides', slug: 'review/more-guides' },
        ]},
        { label: 'Ship', collapsed: true, items: [
          { label: 'Why merging is a decision', slug: 'ship' },
          { label: 'Merge, close and clean up', slug: 'ship/merge-and-close' },
          { label: 'Cut a release', slug: 'ship/releasing' },
        ]},
        { label: 'Reference', collapsed: true, items: [
          { label: 'CLI reference', slug: 'cli-reference' },
          { label: 'Config and permissions', slug: 'config-and-permissions' },
          { label: 'Integrations', slug: 'integrations' },
          { label: 'Skills cckit ships', slug: 'skills' },
          { label: 'Rules cckit ships', slug: 'rules' },
          { label: 'All reference pages', slug: 'reference' },
        ]},
        // Marketing: 10 pages in the order of the process, for a reader who never opens a terminal.
        // The middleware shows these as a flat list, without the group heading, on every page
        // under /marketing/.
        { label: 'Marketing', translations: { es: 'Marketing' }, items: [
          { label: 'What this is for', translations: { es: 'Para qué sirve esto' }, slug: 'marketing' },
          { label: 'How we work', translations: { es: 'Cómo trabajamos' }, slug: 'marketing/how-we-work' },
          { label: 'Who does what', translations: { es: 'Quién hace qué' }, slug: 'marketing/who-does-what' },
          { label: 'Get set up', translations: { es: 'Prepara todo' }, slug: 'marketing/get-set-up' },
          { label: 'The tools we plug in', translations: { es: 'Las herramientas que conectamos' }, slug: 'marketing/tools' },
          { label: 'Set your brand voice', translations: { es: 'Define tu voz de marca' }, slug: 'marketing/brand-voice' },
          { label: 'Plan and run a campaign', translations: { es: 'Planea y lleva una campaña' }, slug: 'marketing/campaigns' },
          { label: 'A piece, idea to approved', translations: { es: 'Una pieza, de la idea a la aprobación' }, slug: 'marketing/your-first-piece' },
          { label: 'Review and approval', translations: { es: 'Revisión y aprobación' }, slug: 'marketing/review-and-approval' },
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
