import React from "react";
import FlowBase, { node, edge } from './FlowBase';

// The full GitHub work cycle, left to right: an issue becomes a branch, the work becomes a pull
// request, review either merges it or sends it back for changes. The headline diagram.
const nodes = [
  node('issue', 0, 1, 'Issue', 'what to do'),
  node('branch', 1, 1, 'Branch', 'isolated worktree'),
  node('work', 2, 1, 'Work', 'implement + test'),
  node('pr', 3, 1, 'Pull request', 'propose the change'),
  node('review', 4, 1, 'Review', 'checks + a look'),
  node('merge', 5, 0, 'Merge', 'into main', { borderColor: 'var(--sl-color-text-accent)' }),
  node('changes', 5, 2, 'Changes', 'sent back'),
];

const edges = [
  edge('issue', 'branch'),
  edge('branch', 'work'),
  edge('work', 'pr'),
  edge('pr', 'review'),
  edge('review', 'merge', 'approved'),
  edge('review', 'changes', 'needs work'),
  edge('changes', 'work'),
];

export default function GitHubCycle() {
  return <FlowBase nodes={nodes} edges={edges} height={360} />;
}
