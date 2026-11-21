// The docs site has two tracks. A page belongs to Marketing when it lives under /marketing/ (or its
// Spanish copy under /es/marketing/); every other page is Software. The Software track's entry page is
// /software/; the home page (/) is the door to both tracks. The track decides three things:
// which sidebar the page shows (src/routeData.ts), which accent colour it takes (the `cckit-track`
// meta tag read by src/styles/theme.css) and which entry of the top-bar switch is current
// (src/components/TrackSwitch.astro).
export type Track = 'software' | 'marketing';

const MARKETING = /^\/?(?:[a-z]{2}\/)?marketing(?:\/|$)/;

/** Track of a page, from its route id (`marketing/get-set-up`) or its path (`/es/marketing/`). */
export function trackOf(idOrPath: string): Track {
	return MARKETING.test(idOrPath) ? 'marketing' : 'software';
}
