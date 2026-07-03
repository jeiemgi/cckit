import React from "react";
import FlowBase, { node, edge } from './FlowBase';

// One effort becomes sub-issues; the plan machine layers them into waves by their blocked-by edges.
// Wave 0 runs in parallel; wave 1 starts once its blockers merge. Left to right = time.
const nodes = [
  node('effort', 0, 1, 'Effort', 'one goal', 'start'),
  node('s1', 1, 0, 'Sub #1', 'wave 0', 'work'),
  node('s2', 1, 1, 'Sub #2', 'wave 0', 'work'),
  node('s3', 1, 2, 'Sub #3', 'wave 0', 'work'),
  node('s4', 2, 0, 'Sub #4', 'wave 1', 'review'),
  node('s5', 2, 2, 'Sub #5', 'wave 1', 'review'),
  node('done', 3, 1, 'Effort done', 'all merged', 'success'),
];

const edges = [
  edge('effort', 's1'),
  edge('effort', 's2'),
  edge('effort', 's3'),
  edge('s1', 's4', 'unblocks', 'review'),
  edge('s3', 's5', 'unblocks', 'review'),
  edge('s4', 'done', undefined, 'success'),
  edge('s5', 'done', undefined, 'success'),
  edge('s2', 'done', undefined, 'success'),
];

export default function EffortWaves() {
  return <FlowBase nodes={nodes} edges={edges} />;
}
