import { defineRouteMiddleware, type StarlightRouteData } from '@astrojs/starlight/route-data';
import { isTranslated } from './lib/translated.mjs';

// One sidebar for the whole site (astro.config.mjs). This middleware does three things to it and
// to the page head: it opens the group an unlisted page belongs to, it keeps the hreflang pair
// only on pages that exist in both languages, and it marks an English fallback copy under /es/
// as not to be indexed.
type Entry = StarlightRouteData['sidebar'][number];
type Group = Extract<Entry, { type: 'group' }>;

/** Every link under an entry, groups flattened. */
function links(entry: Entry): Extract<Entry, { type: 'link' }>[] {
	return entry.type === 'link' ? [entry] : entry.entries.flatMap(links);
}

export const onRequest = defineRouteMiddleware((context) => {
	const route = context.locals.starlightRoute;

	// Groups are collapsed, and Starlight opens the one that holds the current page. A page that is
	// not in the sidebar (a guide listed on its area's "More guides" page, a reference page listed on
	// /reference/) opens the group it belongs to: the top-level group whose pages share its first
	// path segment, else the Reference group for a root-level page.
	const bare = (path: string) => path.replace(/^\/[a-z]{2}(?=\/)/, '');
	const here = bare(context.url.pathname);
	const area = here.split('/')[1] ?? '';
	const groups = route.sidebar.filter((e): e is Group => e.type === 'group');
	const listed = route.sidebar.flatMap(links).some((l) => l.isCurrent);
	if (!listed && area) {
		const home =
			groups.find((g) => links(g).some((l) => bare(l.href).split('/')[1] === area)) ??
			(here.split('/').filter(Boolean).length === 1
				? groups.find((g) => links(g).some((l) => bare(l.href) === '/cli-reference/'))
				: undefined);
		if (home) home.collapsed = false;
	}

	// Starlight emits an hreflang alternate per locale on every page. Keep the pair only where the
	// page exists in both languages (src/lib/translated.mjs).
	if (!isTranslated(context.url.pathname)) {
		route.head = route.head.filter((t) => !(t.tag === 'link' && t.attrs?.rel === 'alternate' && t.attrs?.hreflang));
	}
	// An English fallback copy under /es/ is not a page of its own: keep it out of search engines
	// and point its canonical at the English original.
	if (route.isFallback && route.locale) {
		const original = context.url.pathname.replace(new RegExp(`^/${route.locale}(?=/)`), '');
		for (const t of route.head) {
			if (t.tag === 'link' && t.attrs?.rel === 'canonical' && context.site) {
				t.attrs.href = new URL(original, context.site).href;
			}
		}
		route.head.push({ tag: 'meta', attrs: { name: 'robots', content: 'noindex, follow' } });
	}
});
