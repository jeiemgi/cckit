import React from "react";
import FlowBase, { node, edge } from './FlowBase';

// One effort becomes sub-issues; the plan machine layers them into waves by their blocked-by edges.
// Wave 0 runs in parallel; wave 1 starts once its blockers merge. Left to right = time.
const nodes = [
  node('effort', 0, 1, 'Effort', 'one goal'),
  node('s1', 1, 0, 'Sub #1', 'wave 0'),
  node('s2', 1, 1, 'Sub #2', 'wave 0'),
  node('s3', 1, 2, 'Sub #3', 'wave 0'),
  node('s4', 2, 0, 'Sub #4', 'wave 1', { borderColor: 'var(--sl-color-text-accent)' }),
  node('s5', 2, 2, 'Sub #5', 'wave 1', { borderColor: 'var(--sl-color-text-accent)' }),
  node('done', 3, 1, 'Effort done', 'all merged'),
];

const edges = [
  edge('effort', 's1'),
  edge('effort', 's2'),
  edge('effort', 's3'),
  edge('s1', 's4', 'unblocks'),
  edge('s3', 's5', 'unblocks'),
  edge('s4', 'done'),
  edge('s5', 'done'),
  edge('s2', 'done'),
];

export default function EffortWaves() {
  return <FlowBase nodes={nodes} edges={edges} height={360} />;
}
