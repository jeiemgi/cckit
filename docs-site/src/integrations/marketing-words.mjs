// marketing-words — fails the build when a Marketing page uses a developer word.
//
// The Marketing track (src/content/docs/marketing/ and its Spanish copy under es/marketing/) is
// written for a reader who never opens a terminal. Those pages say draft, review and approved.
// Three developer words are not allowed in them: "worktree", "branch" and "PR". The one page that
// may use them is words-you-will-hear, the glossary that maps each plain word to its developer
// word.
//
// Used two ways:
//   - as an Astro integration (astro.config.mjs): `astro build` stops before it renders a page;
//   - from the command line: `node src/integrations/marketing-words.mjs [docs-dir]`, exit 0 clean,
//     exit 1 with one `file:line: word` row per hit. scripts/docs-marketing-words-test.sh runs
//     this form against fixtures.
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// "PR" is matched in capitals only: "pr" is a fragment of ordinary words and of URL slugs.
const BANNED = [/\bworktrees?\b/gi, /\bbranch(?:es|ed|ing)?\b/gi, /\bPRs?\b/g];
const EXEMPT = /^words-you-will-hear\.mdx?$/;
const DEFAULT_DOCS = fileURLToPath(new URL('../content/docs/', import.meta.url));

function pages(dir) {
	let out = [];
	for (const name of readdirSync(dir)) {
		const full = join(dir, name);
		if (statSync(full).isDirectory()) out = out.concat(pages(full));
		else if (/\.mdx?$/.test(name) && !EXEMPT.test(name)) out.push(full);
	}
	return out;
}

/** Every Marketing directory under a docs root: `marketing/` and `<lang>/marketing/`. */
function marketingDirs(docs) {
	const dirs = [join(docs, 'marketing')];
	for (const name of readdirSync(docs)) {
		if (/^[a-z]{2}$/.test(name)) dirs.push(join(docs, name, 'marketing'));
	}
	return dirs.filter((d) => {
		try {
			return statSync(d).isDirectory();
		} catch {
			return false;
		}
	});
}

/** @returns {{file: string, line: number, word: string}[]} */
export function findBannedWords(docs = DEFAULT_DOCS) {
	const hits = [];
	for (const dir of marketingDirs(docs)) {
		for (const file of pages(dir)) {
			readFileSync(file, 'utf8')
				.split('\n')
				.forEach((text, i) => {
					for (const re of BANNED) {
						for (const m of text.matchAll(re)) {
							hits.push({ file: relative(docs, file), line: i + 1, word: m[0] });
						}
					}
				});
		}
	}
	return hits;
}

function report(hits) {
	return hits.map((h) => `${h.file}:${h.line}: ${h.word}`).join('\n');
}

export default function marketingWords() {
	return {
		name: 'cckit:marketing-words',
		hooks: {
			'astro:build:start': () => {
				const hits = findBannedWords();
				if (hits.length > 0) {
					throw new Error(
						`Marketing pages must not say worktree, branch or PR (only words-you-will-hear may):\n${report(hits)}`,
					);
				}
			},
		},
	};
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const hits = findBannedWords(process.argv[2] ? resolve(process.argv[2]) : DEFAULT_DOCS);
	if (hits.length > 0) {
		console.error(report(hits));
		process.exit(1);
	}
}
