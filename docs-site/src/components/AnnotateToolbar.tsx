import React from "react";
import { Agentation } from "agentation";

// Dev-only visual-annotation toolbar (click a docs element → leave a note → Claude reads it via the
// agentation MCP and fixes it). Isolated in its own client:only island so `agentation` is never
// imported during the SSR build and never ships to production. The endpoint must match the MCP
// receiver port (annotate.mcp.httpPort, default 4747) or notes never reach Claude.
export default function AnnotateToolbar() {
  return <Agentation endpoint="http://localhost:4747" />;
}
