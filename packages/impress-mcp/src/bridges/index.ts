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

export {
  EMAIL_TO_PAPER_TOOLS,
  EmailToPaperBridge,
} from "./email-to-paper.js";

export {
  FIGURE_BRIDGE_TOOLS,
  FigureBridge,
} from "./figure-bridge.js";

// Aggregate all bridge tools
import { CITATION_BRIDGE_TOOLS } from "./citation-bridge.js";
import { CONVERSATION_MANUSCRIPT_TOOLS } from "./conversation-to-manuscript.js";
import { ARTIFACT_RESOLVER_TOOLS } from "./artifact-resolver.js";
import { EMAIL_TO_PAPER_TOOLS } from "./email-to-paper.js";
import { FIGURE_BRIDGE_TOOLS } from "./figure-bridge.js";

export const ALL_BRIDGE_TOOLS = [
  ...CITATION_BRIDGE_TOOLS,
  ...CONVERSATION_MANUSCRIPT_TOOLS,
  ...ARTIFACT_RESOLVER_TOOLS,
  ...EMAIL_TO_PAPER_TOOLS,
  ...FIGURE_BRIDGE_TOOLS,
];
