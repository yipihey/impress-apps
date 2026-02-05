/**
 * Cross-App Bridges
 *
 * Bridges enable workflows that span multiple impress apps.
 */

export {
  CITATION_BRIDGE_TOOLS,
  CitationBridge,
} from "./citation-bridge.js";

export {
  CONVERSATION_MANUSCRIPT_TOOLS,
  ConversationManuscriptBridge,
} from "./conversation-to-manuscript.js";

export {
  ARTIFACT_RESOLVER_TOOLS,
  ArtifactResolverBridge,
} from "./artifact-resolver.js";

// Aggregate all bridge tools
import { CITATION_BRIDGE_TOOLS } from "./citation-bridge.js";
import { CONVERSATION_MANUSCRIPT_TOOLS } from "./conversation-to-manuscript.js";
import { ARTIFACT_RESOLVER_TOOLS } from "./artifact-resolver.js";

export const ALL_BRIDGE_TOOLS = [
  ...CITATION_BRIDGE_TOOLS,
  ...CONVERSATION_MANUSCRIPT_TOOLS,
  ...ARTIFACT_RESOLVER_TOOLS,
];
