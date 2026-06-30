import React from "react";
import FlowBase, { node, edge } from './FlowBase';

// The copilot loop: the plan machine hands a wave to the agent, which fans it out to one subagent
// per issue (each in its own worktree), then the captain gates + merges the PRs and the loop
// advances to the next wave. Left to right = one turn of the loop.
const nodes = [
  node('plan', 0, 1, 'Plan', 'the next wave', 'start'),
  node('a1', 1, 0, 'Subagent', 'issue · worktree', 'work'),
  node('a2', 1, 1, 'Subagent', 'issue · worktree', 'work'),
  node('a3', 1, 2, 'Subagent', 'issue · worktree', 'work'),
  node('captain', 2, 1, 'Captain', 'gate + merge PRs', 'review'),
  node('advance', 3, 1, 'Advance', 'next wave', 'success'),
];

const edges = [
  edge('plan', 'a1'),
  edge('plan', 'a2'),
  edge('plan', 'a3'),
  edge('a1', 'captain'),
  edge('a2', 'captain'),
  edge('a3', 'captain'),
  edge('captain', 'advance', 'merged', 'success'),
  edge('advance', 'plan', 'repeat', 'start'),
];

export default function CopilotFanout() {
  return <FlowBase nodes={nodes} edges={edges} />;
}
