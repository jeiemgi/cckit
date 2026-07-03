import React from "react";
import FlowBase, { node, edge } from './FlowBase';

// Every tag answers one question: WHO pulls the trigger? Left = the initiator, right = the tag that
// marks it. You act (say / type / slash), the system fires on its own (a hook), an agent reads the
// machine surface (--llm), or nothing triggers it at all (a flow or concept — just things to know).
const nodes = [
  node('you', 0, 1, 'You act', 'a person, on purpose', 'start'),
  node('auto', 0, 3, 'It fires itself', 'on an event', 'neutral'),
  node('agentInit', 0, 4, 'An agent reads', 'the machine surface', 'work'),
  node('none', 0, 5, 'No trigger', 'nothing to fire', 'neutral'),

  node('conv', 1, 0, 'Conversational', 'say it in plain words', 'propose'),
  node('cmd', 1, 1, 'Command', 'type `cckit <verb>`', 'propose'),
  node('skill', 1, 2, 'Skill', 'type `/kit-*`', 'propose'),
  node('hook', 1, 3, 'Hook', 'runs automatically', 'review'),
  node('agentTag', 1, 4, 'Agent', 'reads `--llm` output', 'work'),
  node('passive', 1, 5, 'Flow · Concept', 'a term worth knowing', 'neutral'),
];

const edges = [
  edge('you', 'conv'),
  edge('you', 'cmd'),
  edge('you', 'skill'),
  edge('auto', 'hook'),
  edge('agentInit', 'agentTag'),
  edge('none', 'passive'),
];

export default function TriggerSurfaces() {
  return <FlowBase nodes={nodes} edges={edges} />;
}
