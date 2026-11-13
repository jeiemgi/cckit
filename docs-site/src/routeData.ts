import { defineRouteMiddleware, type StarlightRouteData } from '@astrojs/starlight/route-data';
import { trackOf } from './lib/tracks';

// Starlight has ONE sidebar config. This middleware gives each track its own sidebar by keeping,
// on every page, only the entries of the track the page belongs to (see src/lib/tracks.ts).
type Entry = StarlightRouteData['sidebar'][number];

/** Every link under an entry, groups flattened. */
function links(entry: Entry): Extract<Entry, { type: 'link' }>[] {
	return entry.type === 'link' ? [entry] : entry.entries.flatMap(links);
}

/** A top-level sidebar entry belongs to the track all of its links belong to. */
function entryTrack(entry: Entry) {
	const all = links(entry);
	return all.length > 0 && all.every((l) => trackOf(l.href) === 'marketing') ? 'marketing' : 'software';
}

export const onRequest = defineRouteMiddleware((context) => {
	const route = context.locals.starlightRoute;
	const track = trackOf(context.url.pathname);

	const own = route.sidebar.filter((entry) => entryTrack(entry) === track);
	// Marketing is one short list: drop the group heading and show its pages directly.
	route.sidebar = track === 'marketing' ? own.flatMap((e) => (e.type === 'group' ? e.entries : [e])) : own;

	// Marketing is short enough to read whole: every group is open (Software keeps its collapsed groups).
	if (track === 'marketing') {
		const open = (list: Entry[]) => {
			for (const e of list) {
				if (e.type === 'group') {
					e.collapsed = false;
					open(e.entries);
				}
			}
		};
		open(route.sidebar);
	}

	// Software groups are collapsed, and Starlight opens the one that holds the current page. A page
	// that is not in the sidebar (a guide listed on its area's "More guides" page, a reference page
	// listed on /reference/) opens the group it belongs to: the group whose pages share its first
	// path segment, else the Reference group for a root-level page. The track's entry page
	// (/software/) is a link of its own and leaves every group closed.
	if (track === 'software') {
		// An English fallback copy lives under /es/: compare paths without the locale.
		const bare = (path: string) => path.replace(/^\/[a-z]{2}(?=\/)/, '');
		const here = bare(context.url.pathname);
		const area = here.split('/')[1] ?? '';
		const groups = route.sidebar.filter((e): e is Extract<Entry, { type: 'group' }> => e.type === 'group');
		const listed = route.sidebar.flatMap(links).some((l) => l.isCurrent);
		if (!listed && area) {
			const home =
				groups.find((g) => links(g).some((l) => bare(l.href).split('/')[1] === area)) ??
				(here.split('/').filter(Boolean).length === 1
					? groups.find((g) => links(g).some((l) => bare(l.href) === '/cli-reference/'))
					: undefined);
			if (home) home.collapsed = false;
		}
	}

	// Previous / next were computed over both tracks. Drop a link that leaves the track, so the last
	// Software page does not point at the first Marketing page.
	const hrefs = new Set(route.sidebar.flatMap(links).map((l) => l.href));
	if (route.pagination.prev && !hrefs.has(route.pagination.prev.href)) route.pagination.prev = undefined;
	if (route.pagination.next && !hrefs.has(route.pagination.next.href)) route.pagination.next = undefined;

	// The site title always leads to the one home page. Without this, a Spanish page would link to
	// /es/, an English fallback copy of the home page.
	route.siteTitleHref = '/';

	// Starlight emits an hreflang alternate per locale on every page. Only Marketing pages have a
	// Spanish version, so the alternates are dropped everywhere else.
	if (track !== 'marketing') {
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

	// The track as a <meta> tag: theme.css keys the Marketing accent on it.
	route.head.push({ tag: 'meta', attrs: { name: 'cckit-track', content: track } });
});
