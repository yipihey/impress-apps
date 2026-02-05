/**
 * Artifact URI Resolver
 *
 * Unified resolver for impress:// URIs that fetches data from the appropriate app.
 * Supports imbib papers, imprint documents, and impart conversations.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImbibClient } from "../imbib/client.js";
import { ImprintClient } from "../imprint/client.js";
import { ImpartClient } from "../impart/client.js";

// ============================================================================
// Tool Definitions
// ============================================================================

export const ARTIFACT_RESOLVER_TOOLS: Tool[] = [
  {
    name: "impress_resolve_artifact",
    description:
      "Resolve an impress:// URI and return the artifact data. Supports imbib papers, imprint documents, and impart conversations. Use this to fetch data from any part of the impress suite using a uniform URI scheme.",
    inputSchema: {
      type: "object",
      properties: {
        uri: {
          type: "string",
          description:
            "The impress:// URI to resolve. Examples: impress://imbib/papers/Vaswani2017, impress://imprint/documents/abc123, impress://impart/conversations/xyz789",
        },
        include_content: {
          type: "boolean",
          description:
            "Include full content (e.g., document source, conversation messages). Default: false for summary only.",
        },
      },
      required: ["uri"],
    },
  },
  {
    name: "impress_list_artifacts",
    description:
      "List available artifacts across all impress apps. Returns a summary of papers, documents, and conversations.",
    inputSchema: {
      type: "object",
      properties: {
        app: {
          type: "string",
          enum: ["imbib", "imprint", "impart", "all"],
          description: "Filter by app, or 'all' for everything (default: all)",
        },
        limit: {
          type: "number",
          description: "Maximum items per app (default: 10)",
        },
      },
    },
  },
];

// ============================================================================
// URI Parsing
// ============================================================================

interface ParsedURI {
  app: "imbib" | "imprint" | "impart";
  type: string;
  id: string;
  valid: boolean;
  error?: string;
}

function parseImpressURI(uri: string): ParsedURI {
  const match = uri.match(/^impress:\/\/(\w+)\/(\w+)\/(.+)$/);

  if (!match) {
    return {
      app: "imbib",
      type: "",
      id: "",
      valid: false,
      error: `Invalid URI format: ${uri}. Expected: impress://app/type/id`,
    };
  }

  const [, app, type, id] = match;

  if (!["imbib", "imprint", "impart"].includes(app)) {
    return {
      app: "imbib",
      type,
      id,
      valid: false,
      error: `Unknown app: ${app}. Valid apps: imbib, imprint, impart`,
    };
  }

  return {
    app: app as "imbib" | "imprint" | "impart",
    type,
    id,
    valid: true,
  };
}

// ============================================================================
// Bridge Handler
// ============================================================================

export class ArtifactResolverBridge {
  constructor(
    private imbibClient: ImbibClient | null,
    private imprintClient: ImprintClient | null,
    private impartClient: ImpartClient | null
  ) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      case "impress_resolve_artifact":
        return this.resolveArtifact(args);
      case "impress_list_artifacts":
        return this.listArtifacts(args);
      default:
        return {
          content: [
            { type: "text", text: `Unknown artifact resolver tool: ${name}` },
          ],
        };
    }
  }

  // --------------------------------------------------------------------------
  // Resolve Artifact
  // --------------------------------------------------------------------------

  private async resolveArtifact(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const uri = args?.uri as string;
    const includeContent = (args?.include_content as boolean) ?? false;

    if (!uri) {
      return {
        content: [{ type: "text", text: "Error: uri is required" }],
      };
    }

    const parsed = parseImpressURI(uri);
    if (!parsed.valid) {
      return {
        content: [{ type: "text", text: `Error: ${parsed.error}` }],
      };
    }

    switch (parsed.app) {
      case "imbib":
        return this.resolveImbibArtifact(parsed, includeContent);
      case "imprint":
        return this.resolveImprintArtifact(parsed, includeContent);
      case "impart":
        return this.resolveImpartArtifact(parsed, includeContent);
      default:
        return {
          content: [{ type: "text", text: `Unknown app: ${parsed.app}` }],
        };
    }
  }

  private async resolveImbibArtifact(
    parsed: ParsedURI,
    includeContent: boolean
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    if (!this.imbibClient) {
      return {
        content: [
          { type: "text", text: "Error: imbib is not available" },
        ],
      };
    }

    if (parsed.type !== "papers") {
      return {
        content: [
          {
            type: "text",
            text: `Unknown imbib artifact type: ${parsed.type}. Supported: papers`,
          },
        ],
      };
    }

    const paper = await this.imbibClient.getPaper(parsed.id);
    if (!paper) {
      return {
        content: [
          { type: "text", text: `Paper not found: ${parsed.id}` },
        ],
      };
    }

    const lines = [
      `# Paper: ${paper.title}`,
      "",
      `**URI:** impress://imbib/papers/${paper.citeKey}`,
      `**Cite Key:** @${paper.citeKey}`,
      `**Authors:** ${paper.authors?.join(", ") || "Unknown"}`,
      `**Year:** ${paper.year || "n.d."}`,
      paper.venue ? `**Venue:** ${paper.venue}` : null,
      paper.doi ? `**DOI:** ${paper.doi}` : null,
      "",
    ].filter((l) => l !== null);

    if (includeContent && paper.abstract) {
      lines.push("## Abstract", "", paper.abstract, "");
    }

    return {
      content: [{ type: "text", text: lines.join("\n") }],
    };
  }

  private async resolveImprintArtifact(
    parsed: ParsedURI,
    includeContent: boolean
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    if (!this.imprintClient) {
      return {
        content: [
          { type: "text", text: "Error: imprint is not available" },
        ],
      };
    }

    if (parsed.type !== "documents") {
      return {
        content: [
          {
            type: "text",
            text: `Unknown imprint artifact type: ${parsed.type}. Supported: documents`,
          },
        ],
      };
    }

    const doc = await this.imprintClient.getDocument(parsed.id);
    if (!doc) {
      return {
        content: [
          { type: "text", text: `Document not found: ${parsed.id}` },
        ],
      };
    }

    const lines = [
      `# Document: ${doc.title}`,
      "",
      `**URI:** impress://imprint/documents/${doc.id}`,
      `**Authors:** ${doc.authors?.join(", ") || "Not specified"}`,
      `**Modified:** ${doc.modifiedAt}`,
      `**Citations:** ${doc.citationCount || 0}`,
      "",
    ];

    // Note: To get full document content, use imprint_get_content directly.
    // The artifact resolver returns a summary view.

    return {
      content: [{ type: "text", text: lines.join("\n") }],
    };
  }

  private async resolveImpartArtifact(
    parsed: ParsedURI,
    includeContent: boolean
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    if (!this.impartClient) {
      return {
        content: [
          { type: "text", text: "Error: impart is not available" },
        ],
      };
    }

    if (parsed.type !== "conversations") {
      return {
        content: [
          {
            type: "text",
            text: `Unknown impart artifact type: ${parsed.type}. Supported: conversations`,
          },
        ],
      };
    }

    const response = await this.impartClient.getConversation(parsed.id);
    if (!response) {
      return {
        content: [
          { type: "text", text: `Conversation not found: ${parsed.id}` },
        ],
      };
    }

    const conv = response.conversation;
    const lines = [
      `# Conversation: ${conv.title}`,
      "",
      `**URI:** impress://impart/conversations/${conv.id}`,
      `**Participants:** ${conv.participants?.join(", ") || "Unknown"}`,
      `**Created:** ${conv.createdAt}`,
      `**Last Activity:** ${conv.lastActivityAt}`,
      conv.tags?.length
        ? `**Tags:** ${conv.tags.join(", ")}`
        : null,
      "",
    ].filter((l) => l !== null);

    if (includeContent && response.messages) {
      lines.push("## Messages", "");
      const recentMessages = response.messages.slice(-5);
      for (const msg of recentMessages) {
        lines.push(
          `**[${msg.senderRole}]:** ${msg.contentMarkdown?.slice(0, 200)}${msg.contentMarkdown && msg.contentMarkdown.length > 200 ? "..." : ""}`,
          ""
        );
      }
      if (response.messages.length > 5) {
        lines.push(`(${response.messages.length - 5} earlier messages omitted)`, "");
      }
    }

    return {
      content: [{ type: "text", text: lines.join("\n") }],
    };
  }

  // --------------------------------------------------------------------------
  // List Artifacts
  // --------------------------------------------------------------------------

  private async listArtifacts(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const appFilter = (args?.app as string) || "all";
    const limit = (args?.limit as number) || 10;

    const sections: string[] = ["# Available Artifacts", ""];

    // imbib papers
    if ((appFilter === "all" || appFilter === "imbib") && this.imbibClient) {
      const status = await this.imbibClient.checkStatus();
      if (status) {
        const result = await this.imbibClient.searchLibrary("", { limit });
        sections.push(
          "## imbib Papers",
          "",
          `Total in library: ${status.libraryCount || "unknown"}`,
          ""
        );
        if (result && result.papers.length > 0) {
          for (const paper of result.papers.slice(0, limit)) {
            sections.push(
              `- **@${paper.citeKey}**: ${paper.title?.slice(0, 50)}${paper.title && paper.title.length > 50 ? "..." : ""}`,
              `  URI: impress://imbib/papers/${paper.citeKey}`
            );
          }
        } else {
          sections.push("No papers found.");
        }
        sections.push("");
      } else {
        sections.push("## imbib Papers", "", "imbib is not running.", "");
      }
    }

    // imprint documents
    if ((appFilter === "all" || appFilter === "imprint") && this.imprintClient) {
      const status = await this.imprintClient.checkStatus();
      if (status) {
        const docs = await this.imprintClient.listDocuments();
        sections.push(
          "## imprint Documents",
          "",
          `Open documents: ${docs?.documents?.length || 0}`,
          ""
        );
        if (docs && docs.documents.length > 0) {
          for (const doc of docs.documents.slice(0, limit)) {
            sections.push(
              `- **${doc.title}** (${doc.id})`,
              `  URI: impress://imprint/documents/${doc.id}`
            );
          }
        } else {
          sections.push("No documents open.");
        }
        sections.push("");
      } else {
        sections.push("## imprint Documents", "", "imprint is not running.", "");
      }
    }

    // impart conversations
    if ((appFilter === "all" || appFilter === "impart") && this.impartClient) {
      const status = await this.impartClient.checkStatus();
      if (status) {
        const convs = await this.impartClient.listConversations();
        sections.push(
          "## impart Conversations",
          "",
          `Total conversations: ${convs?.conversations?.length || 0}`,
          ""
        );
        if (convs && convs.conversations.length > 0) {
          for (const conv of convs.conversations.slice(0, limit)) {
            sections.push(
              `- **${conv.title}** (${conv.id})`,
              `  URI: impress://impart/conversations/${conv.id}`
            );
          }
        } else {
          sections.push("No conversations found.");
        }
        sections.push("");
      } else {
        sections.push("## impart Conversations", "", "impart is not running.", "");
      }
    }

    return {
      content: [{ type: "text", text: sections.join("\n") }],
    };
  }
}
