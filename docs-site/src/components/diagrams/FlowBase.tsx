import React from "react";
import { ReactFlow, Background, Controls, Position, MarkerType } from '@xyflow/react';
import type { Node, Edge } from '@xyflow/react';
import '@xyflow/react/dist/style.css';

// FlowBase — the reusable, self-explanatory, LEFT-TO-RIGHT diagram surface for the docs.
// Diagrams pass plain nodes/edges; FlowBase applies the house defaults: left→right handles,
// arrowheads, fit-to-view, read-only interaction (pan/zoom yes, editing no), a fixed aspect ratio
// so it renders well in the browser, and a STAGE COLOR system so each kind of step reads at a
// glance. One look should explain the flow. Colors are theme-aware (work in dark + light).

export type FlowNode = Node<{ label: React.ReactNode }>;

// Stage palette — one hue per kind of step/action. Tints sit over the panel so they read in both
// themes; the border carries the colour, the text stays high-contrast.
type Kind = 'start' | 'work' | 'propose' | 'review' | 'success' | 'warn' | 'neutral';
const HUE: Record<Kind, string> = {
  start:   '#2c8fa6', // steel cyan — the brand / entry points
  work:    '#d99a2b', // amber — hands-on implementation
  propose: '#8b7cf6', // violet — proposing a change (a PR)
  review:  '#38a8c6', // sky — checks + review
  success: '#2faa6a', // green — merged / done
  warn:    '#e0617a', // rose — sent back / needs work
  neutral: '#7c8a91', // gray — context, not a step
};

function nodeStyleFor(kind: Kind): React.CSSProperties {
  const c = HUE[kind];
  return {
    borderRadius: 10,
    border: `1.5px solid ${c}`,
    background: `color-mix(in srgb, ${c} 16%, var(--sl-color-gray-6))`,
    color: 'var(--sl-color-white)',
    padding: '10px 12px',
    fontSize: 15,
    width: 150,
    textAlign: 'center',
    lineHeight: 1.3,
  };
}

export default function FlowBase({
  nodes,
  edges,
}: {
  nodes: FlowNode[];
  edges: Edge[];
}) {
  return (
    <div
      className="not-content cckit-flow"
      style={{
        width: '100%',
        aspectRatio: '2 / 1',
        minHeight: 340,
        maxHeight: 540,
      }}
    >
      <ReactFlow
        nodes={nodes}
        edges={edges}
        fitView
        fitViewOptions={{ padding: 0.08 }}
        minZoom={0.2}
        maxZoom={1.4}
        nodesDraggable={false}
        nodesConnectable={false}
        elementsSelectable={false}
        zoomOnScroll={false}
        preventScrolling={false}
        proOptions={{ hideAttribution: false }}
        defaultEdgeOptions={{ markerEnd: { type: MarkerType.ArrowClosed } }}
      >
        <Background gap={18} color="var(--sl-color-gray-5)" />
        <Controls showInteractive={false} position="bottom-right" />
      </ReactFlow>
    </div>
  );
}

// node — a titled node with an optional one-line description and a stage colour.
export function node(
  id: string,
  col: number,
  row: number,
  title: string,
  desc?: string,
  kind: Kind = 'neutral',
): FlowNode {
  return {
    id,
    position: { x: col * 190, y: row * 124 },
    sourcePosition: Position.Right,
    targetPosition: Position.Left,
    style: nodeStyleFor(kind),
    data: {
      label: (
        <span>
          <strong>{title}</strong>
          {desc ? <><br /><span style={{ fontSize: 12.5, opacity: 0.85 }}>{desc}</span></> : null}
        </span>
      ),
    },
  };
}

// edge — a labelled arrow, optionally tinted to match the step it leads to (success/warn).
export function edge(source: string, target: string, label?: string, kind?: Kind): Edge {
  const stroke = kind ? HUE[kind] : 'var(--sl-color-text-accent)';
  return {
    id: `${source}-${target}`,
    source,
    target,
    label,
    animated: !!label,
    style: { stroke },
    labelStyle: { fill: 'var(--sl-color-white)', fontSize: 11 },
    labelBgStyle: { fill: 'var(--sl-color-black)' },
    markerEnd: { type: MarkerType.ArrowClosed, color: kind ? HUE[kind] : undefined },
  };
}
