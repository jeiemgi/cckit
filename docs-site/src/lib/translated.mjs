// Which pages exist in both languages. A page is translated when the same file exists under
// src/content/docs/ and under src/content/docs/es/. Starlight also builds an English fallback copy
// of every other page under /es/; a fallback is not a translation, so it gets no language picker,
// no hreflang pair and no sitemap entry (astro.config.mjs, src/routeData.ts,
// src/components/LanguageSelect.astro all ask this module).
// Reads the source tree, so it runs from the docs-site directory (as `astro dev` and `astro build` do).
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

const DOCS = join(process.cwd(), 'src/content/docs');

function pages(dir, base = '') {
	let out = [];
	for (const name of readdirSync(dir)) {
		const full = join(dir, name);
		if (statSync(full).isDirectory()) out = out.concat(pages(full, `${base}${name}/`));
		else if (/\.mdx?$/.test(name)) out.push(`${base}${name.replace(/\.mdx?$/, '')}`);
	}
	return out;
}

const route = (id) => `/${id.replace(/(^|\/)index$/, '')}`.replace(/\/?$/, '/');

let cache;
/** English routes ('/', '/marketing/tools/') whose page also exists in Spanish. */
export function translatedRoutes() {
	if (cache) return cache;
	const es = join(DOCS, 'es');
	const ids = existsSync(es) ? pages(es) : [];
	cache = new Set(
		ids.filter((id) => existsSync(join(DOCS, `${id}.mdx`)) || existsSync(join(DOCS, `${id}.md`))).map(route),
	);
	return cache;
}

/** True when the page at this path ('/es/marketing/' or '/marketing/') exists in both languages. */
export function isTranslated(pathname) {
	const bare = pathname.replace(/^\/es(?=\/|$)/, '') || '/';
	return translatedRoutes().has(bare.replace(/\/?$/, '/'));
}
