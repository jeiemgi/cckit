import { getCollection } from 'astro:content';
import { OGImageRoute } from 'astro-og-canvas';

// One generated 1200×630 social card per docs page. The Head override points each page's og:image /
// twitter:image at /og/<id>.png. Guides fold their eyebrow (Guide · <tag> · <difficulty> ·
// <time>) into the card's second line so a security tutorial and a parallel-work tutorial don't
// share one anonymous image in the feed.
const entries = await getCollection('docs');
const pages = Object.fromEntries(entries.map((entry) => [entry.id, entry]));

export const { getStaticPaths, GET } = await OGImageRoute({
  param: 'slug',
  pages,
  getImageOptions: (_id, entry) => {
    const t = entry.data.tutorial;
    const eyebrow = t
      ? ['Guide', t.ogTag, `${t.difficulty} · ${t.time}`].filter(Boolean).join(' · ')
      : 'cckit';
    return {
      title: entry.data.title,
      description: t ? eyebrow : entry.data.description ?? '',
      // The theme's dark page and surface, with a cobalt edge (src/styles/theme.css).
      bgGradient: [
        [27, 33, 29],
        [37, 46, 39],
      ],
      border: { color: [145, 177, 255], width: 10, side: 'inline-start' },
      padding: 60,
      font: {
        title: { color: [242, 244, 235], size: 62, weight: 'Bold', lineHeight: 1.1 },
        description: { color: [177, 188, 170], size: 30, weight: 'Normal' },
      },
    };
  },
});
