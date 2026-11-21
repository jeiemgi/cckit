#!/usr/bin/env bash
# docs-record-tables-test.sh — the docs site's record-card transform (#494).
#
# docs-site/src/lib/rehype-record-tables.mjs turns a Markdown table with three or more columns and a
# cell longer than 60 characters into a list of record cards. Checked here on hand-built trees:
# which tables convert, which stay tables, and what a card holds.
#
# Network-free. Needs node; skipped without it.
# Run:  bash scripts/docs-record-tables-test.sh
set -uo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PLUGIN="$ROOT/docs-site/src/lib/rehype-record-tables.mjs"

if ! command -v node >/dev/null 2>&1; then echo "skip: node not found"; exit 0; fi

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cat > "$work/run.mjs" <<'JS'
const { default: plugin } = await import(process.argv[2]);
const T = (value) => ({ type: 'text', value });
const E = (tagName, children, properties = {}) => ({ type: 'element', tagName, properties, children });
const table = (head, rows, properties) =>
  E('table', [
    E('thead', [E('tr', head.map((h) => E('th', [T(h)])))]),
    E('tbody', rows.map((r) => E('tr', r.map((c) => E('td', [T(c)]))))),
  ], properties);
const LONG = 'A read-only report at the start of each session: stale branches and leftover worktrees.';
const run = (node, wrap) => {
  const tree = { type: 'root', children: [wrap ? wrap(node) : node] };
  plugin()(tree);
  return tree.children[0];
};
const flat = (n) => (n.type === 'text' ? n.value : (n.children || []).map(flat).join('|'));
let fail = 0;
const t = (label, got, want) => {
  if (got !== want) { console.log(`FAIL: ${label} -> got '[${got}]' want '[${want}]'`); fail = 1; }
  else console.log(`ok: ${label}`);
};

let out = run(table(['Event', 'Hook', 'What it does'], [['SessionStart', 'repo-hygiene.sh', LONG]]));
t('three columns with a long cell become records', out.tagName, 'ul');
t('the list carries the records class', out.properties.className[0], 'cckit-records');
t('one card per row', String(out.children.length), '1');
t('first cell is the title, its header the kicker, the rest labelled lines',
  flat(out), `Event|SessionStart|Hook|repo-hygiene.sh|What it does|${LONG}`);

out = run(table(['Event', 'Hook', 'What it does'], [['SessionStart', 'repo-hygiene.sh', 'Short.']]));
t('three columns, short cells: stays a table', out.tagName, 'table');

out = run(table(['Flag', 'Effect'], [['--dry-run', LONG]]));
t('two columns: stays a table', out.tagName, 'table');

out = run(table(['Event', 'Hook', 'What it does'], [['a', 'b', LONG]], { className: ['legend'] }));
t('a table with its own class is left alone', out.tagName, 'table');

out = run(table(['Event', 'Hook', 'What it does'], [['a', 'b', LONG]]),
  (n) => E('div', [n], { dataTable: 'grid' }));
t('a table inside data-table="grid" is left alone', out.children[0].tagName, 'table');

out = run(table(['Event', 'Hook', 'What it does'], [['a', 'b', LONG]]),
  (n) => ({ type: 'mdxJsxFlowElement', name: 'div', attributes: [], children: [n] }));
t('a table inside an MDX wrapper is converted', out.children[0].tagName, 'ul');

out = run(table(['#', 'Bucket', 'What it reports'], [['1', 'Local undone work', LONG], ['2', 'PRs', 'x']]));
t('an index column is folded into the title',
  flat(out.children[0]), `Bucket|1|Local undone work|What it reports|${LONG}`);

out = run(table(['Verb', 'Purpose', 'LLM mode'], [['cckit sync', LONG, '']]));
t('an empty cell makes no line', flat(out), `Verb|cckit sync|Purpose|${LONG}`);

process.exit(fail);
JS
node "$work/run.mjs" "$PLUGIN"
