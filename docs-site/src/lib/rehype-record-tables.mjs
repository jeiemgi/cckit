// Markdown tables whose rows are records — a name, a few attributes, a sentence — render as a list
// of record cards instead of a grid. A grid gives every column a share of the width, so two code
// columns squeeze a description column down to a character per line (#494: /hooks/, Event · Hook ·
// What it does). In a card the first cell is the heading and every other cell is a labelled line
// that takes the full width. A leading index column is folded into the heading.
//
// Authors keep writing Markdown tables. A table is converted when it has three or more columns and
// at least one cell longer than LONG_CELL characters; a small table that fits stays a table. A
// table written as raw HTML with its own class (the legend table) is left alone, and so is a table
// inside an element marked `data-table="grid"`.

const LONG_CELL = 60;

const text = (node) =>
  node.type === 'text' ? node.value : (node.children || []).map(text).join('');

const els = (node, tag) =>
  (node.children || []).filter((c) => c.type === 'element' && c.tagName === tag);

const el = (tagName, className, children) => ({
  type: 'element',
  tagName,
  properties: className ? { className: [className] } : {},
  children,
});

function toRecords(table) {
  const head = els(table, 'thead')[0];
  const body = els(table, 'tbody')[0];
  if (!head || !body) return null;
  const headRow = els(head, 'tr')[0];
  if (!headRow) return null;
  const labels = els(headRow, 'th').map((th) => th.children);
  if (labels.length < 3) return null;

  const rows = els(body, 'tr').map((tr) => [...els(tr, 'td'), ...els(tr, 'th')]);
  if (!rows.length) return null;
  const long = rows.some((cells) => cells.some((c) => text(c).trim().length > LONG_CELL));
  if (!long) return null;

  // A leading index column ("#": 1, 2, 3) is not a name: the next column titles the card and the
  // index is written in front of it.
  const indexed = rows.every((cells) => cells[0] && /^\d+$/.test(text(cells[0]).trim()));
  const at = indexed ? 1 : 0;

  const cards = rows.map((cells) => {
    const first = cells[at];
    const rest = cells.slice(at + 1);
    const title = first ? first.children : [];
    const lines = rest
      .map((cell, i) => ({ cell, label: labels[at + i + 1] || [] }))
      .filter(({ cell }) => text(cell).trim() !== '' || cell.children.some((c) => c.type === 'element'))
      .map(({ cell, label }) =>
        el('div', 'cckit-record__line', [
          el('dt', 'cckit-record__label', label),
          el('dd', 'cckit-record__value', cell.children),
        ]),
      );
    return el('li', 'cckit-record', [
      el('div', 'cckit-record__head', [
        el('span', 'cckit-record__kicker', labels[at] || []),
        el(
          'div',
          'cckit-record__title',
          indexed
            ? [el('span', 'cckit-record__index', [{ type: 'text', value: text(cells[0]).trim() }]), ...title]
            : title,
        ),
      ]),
      el('dl', 'cckit-record__body', lines),
    ]);
  });
  return el('ul', 'cckit-records', cards);
}

function walk(node, keepGrid) {
  if (!node.children) return;
  const attr = (node.attributes || []).find((x) => x && x.name === 'data-table');
  const grid =
    keepGrid ||
    (node.properties && node.properties.dataTable === 'grid') ||
    (attr && attr.value === 'grid');
  node.children = node.children.map((child) => {
    // An MDX wrapper (<div class="…"> written in the page) is not an `element` node; walk into it.
    if (child.type === 'element' && child.tagName === 'table') {
      const own = child.properties && (child.properties.className || child.properties.class);
      if (grid || (own && String(own).length)) return child;
      return toRecords(child) || child;
    }
    walk(child, grid);
    return child;
  });
}

export default function rehypeRecordTables() {
  return (tree) => walk(tree, false);
}
