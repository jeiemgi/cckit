import React from "react";
import { ReactFlow, Background, Controls, Position, MarkerType } from '@xyflow/react';
import type { Node, Edge } from '@xyflow/react';
import '@xyflow/react/dist/style.css';

// FlowBase — the reusable, self-explanatory, LEFT-TO-RIGHT diagram surface for the docs.
// Diagrams pass plain nodes/edges; FlowBase applies the house defaults: left→right handles,
// arrowheads, fit-to-view, and read-only interaction (pan/zoom yes, editing no) so a reader can
// explore without being able to break the picture. One look should explain the flow.

export type FlowNode = Node<{ label: React.ReactNode }>;

const nodeStyle: React.CSSProperties = {
  borderRadius: 10,
  border: '1px solid var(--sl-color-gray-4)',
  background: 'var(--sl-color-gray-6)',
  color: 'var(--sl-color-white)',
  padding: '8px 12px',
  fontSize: 13,
  width: 150,
  textAlign: 'center',
  lineHeight: 1.3,
};

export default function FlowBase({
  nodes,
  edges,
  height = 340,
}: {
  nodes: FlowNode[];
  edges: Edge[];
  height?: number;
}) {
  const laidOut = nodes.map((n) => ({
    sourcePosition: Position.Right,
    targetPosition: Position.Left,
    style: { ...nodeStyle, ...(n.style ?? {}) },
    ...n,
  }));
  return (
    <div style={{ height, width: '100%', margin: '1.25rem 0' }} className="not-content">
      <ReactFlow
        nodes={laidOut}
        edges={edges}
        fitView
        fitViewOptions={{ padding: 0.15 }}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        zoomOnScroll={false}
        preventScrolling={false}
        defaultEdgeOptions={{
          markerEnd: { type: MarkerType.ArrowClosed },
          style: { stroke: 'var(--sl-color-text-accent)' },
        }}
      >
        <Background gap={18} color="var(--sl-color-gray-5)" />
        <Controls showInteractive={false} position="bottom-right" />
      </ReactFlow>
    </div>
  );
}

// node — terminal helper to compose a titled node with an optional one-line description.
export function node(
  id: string,
  col: number,
  row: number,
  title: string,
  desc?: string,
  style?: React.CSSProperties,
): FlowNode {
  return {
    id,
    position: { x: col * 210, y: row * 110 },
    data: {
      label: (
        <span>
          <strong>{title}</strong>
          {desc ? <><br /><span style={{ fontSize: 11, opacity: 0.85 }}>{desc}</span></> : null}
        </span>
      ),
    },
    style,
  };
}

// edge — terminal helper for a labelled arrow.
export function edge(source: string, target: string, label?: string): Edge {
  return { id: `${source}-${target}`, source, target, label, animated: !!label };
}
