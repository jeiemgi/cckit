import React from "react";
import FlowBase, { node, edge } from './FlowBase';

// Why parallel work doesn't collide: one repo, but each issue gets its own branch + worktree (a
// separate working copy on disk). Agents edit in their own worktree; only the merged PRs meet again
// on main. Left to right = from the shared repo, out to isolated copies, back to main.
const nodes = [
  node('repo', 0, 1, 'Repo', 'main'),
  node('w1', 1, 0, 'Worktree A', 'branch · issue #1'),
  node('w2', 1, 1, 'Worktree B', 'branch · issue #2'),
  node('w3', 1, 2, 'Worktree C', 'branch · issue #3'),
  node('main', 2, 1, 'Main', 'merges, no clashes', { borderColor: 'var(--sl-color-text-accent)' }),
];

const edges = [
  edge('repo', 'w1'),
  edge('repo', 'w2'),
  edge('repo', 'w3'),
  edge('w1', 'main'),
  edge('w2', 'main'),
  edge('w3', 'main'),
];

export default function WorktreeIsolation() {
  return <FlowBase nodes={nodes} edges={edges} height={320} />;
}
