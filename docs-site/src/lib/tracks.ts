// A page under /marketing/ (or its Spanish copy under /es/marketing/) is written for a reader who
// never opens a terminal; every other page is written for a developer. The site has one navigation
// for both (astro.config.mjs). This helper only tells the two kinds of page apart where the wording
// differs: "your assistant" against "your agent" in Chat.astro and TutorialMeta.astro, and the
// plain-words check in src/integrations/marketing-words.mjs.
export type Track = 'software' | 'marketing';

const MARKETING = /^\/?(?:[a-z]{2}\/)?marketing(?:\/|$)/;

/** Kind of a page, from its route id (`marketing/get-set-up`) or its path (`/es/marketing/`). */
export function trackOf(idOrPath: string): Track {
	return MARKETING.test(idOrPath) ? 'marketing' : 'software';
}
