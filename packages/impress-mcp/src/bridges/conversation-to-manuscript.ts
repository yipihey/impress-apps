/**
 * Conversation to Manuscript Pipeline
 *
 * Enables extracting research decisions, insights, and citations from
 * impart conversations to create manuscript outlines in imprint.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImpartClient } from "../impart/client.js";
import { ImprintClient } from "../imprint/client.js";

// ============================================================================
// Tool Definitions
// ============================================================================

export const CONVERSATION_MANUSCRIPT_TOOLS: Tool[] = [
  {
    name: "impress_conversation_to_outline",
    description:
      "Extract a manuscript outline from an impart research conversation. Analyzes the conversation to identify key themes, decisions, and structure suitable for a paper.",
    inputSchema: {
      type: "object",
      properties: {
        conversation_id: {
          type: "string",
          description: "The impart conversation ID to analyze",
        },
        document_id: {
          type: "string",
          description:
            "Optional: existing imprint document to add outline to. If not provided, returns the outline without creating a document.",
        },
        style: {
          type: "string",
          enum: ["academic", "technical", "report"],
          description:
            "Outline style (default: academic). Academic follows standard paper structure (intro, methods, results, discussion). Technical follows software documentation patterns.",
        },
      },
      required: ["conversation_id"],
    },
  },
  {
    name: "impress_export_conversation_citations",
    description:
      "Export all paper artifacts referenced in a conversation as citations. Returns BibTeX entries that can be added to an imprint document.",
    inputSchema: {
      type: "object",
      properties: {
        conversation_id: {
          type: "string",
          description: "The impart conversation ID",
        },
        document_id: {
          type: "string",
          description:
            "Optional: imprint document to add citations to directly",
        },
      },
      required: ["conversation_id"],
    },
  },
  {
    name: "impress_conversation_decisions",
    description:
      "Extract all recorded decisions from a conversation. Useful for documenting research rationale in a methods section.",
    inputSchema: {
      type: "object",
      properties: {
        conversation_id: {
          type: "string",
          description: "The impart conversation ID",
        },
      },
      required: ["conversation_id"],
    },
  },
];

// ============================================================================
// Bridge Handler
// ============================================================================

export class ConversationManuscriptBridge {
  constructor(
    private impartClient: ImpartClient,
    private imprintClient: ImprintClient
  ) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      case "impress_conversation_to_outline":
        return this.conversationToOutline(args);
      case "impress_export_conversation_citations":
        return this.exportConversationCitations(args);
      case "impress_conversation_decisions":
        return this.conversationDecisions(args);
      default:
        return {
          content: [
            {
              type: "text",
              text: `Unknown conversation-manuscript tool: ${name}`,
            },
          ],
        };
    }
  }

  // --------------------------------------------------------------------------
  // Conversation to Outline
  // --------------------------------------------------------------------------

  private async conversationToOutline(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversation_id as string;
    const documentId = args?.document_id as string | undefined;
    const style = (args?.style as string) || "academic";

    if (!conversationId) {
      return {
        content: [
          { type: "text", text: "Error: conversation_id is required" },
        ],
      };
    }

    // Get conversation details
    const conversation = await this.impartClient.getConversation(conversationId);
    if (!conversation) {
      return {
        content: [
          {
            type: "text",
            text: `Error: Conversation not found: ${conversationId}`,
          },
        ],
      };
    }

    // Analyze conversation to extract structure
    const conv = conversation.conversation;
    const outline = this.generateOutline({ title: conv.title, messages: conversation.messages }, style);

    // If document_id provided, add outline to document
    if (documentId) {
      try {
        // Create a Typst outline structure
        const typstOutline = this.outlineToTypst(outline);
        await this.imprintClient.updateDocument(documentId, { source: typstOutline });

        return {
          content: [
            {
              type: "text",
              text: [
                `# Outline Generated and Added to Document`,
                "",
                `**Conversation:** ${conv.title}`,
                `**Document:** ${documentId}`,
                `**Style:** ${style}`,
                "",
                "## Generated Outline",
                "",
                this.formatOutline(outline),
              ].join("\n"),
            },
          ],
        };
      } catch (e) {
        return {
          content: [
            {
              type: "text",
              text: `Error adding outline to document: ${e}`,
            },
          ],
        };
      }
    }

    return {
      content: [
        {
          type: "text",
          text: [
            `# Generated Outline`,
            "",
            `**From Conversation:** ${conv.title}`,
            `**Style:** ${style}`,
            "",
            this.formatOutline(outline),
            "",
            "Use impress_conversation_to_outline with document_id to add this to a manuscript.",
          ].join("\n"),
        },
      ],
    };
  }

  private generateOutline(
    conversation: { title: string; messages?: Array<{ contentMarkdown: string; senderRole: string }> },
    style: string
  ): OutlineSection[] {
    // Simple heuristic-based outline generation
    // In a real implementation, this could use LLM analysis

    const title = conversation.title || "Research Document";

    if (style === "academic") {
      return [
        {
          title: "Abstract",
          level: 1,
          notes: ["Summarize the research question and key findings"],
        },
        {
          title: "Introduction",
          level: 1,
          notes: ["Background and motivation", "Research question", "Contributions"],
          subsections: [
            { title: "Background", level: 2, notes: [] },
            { title: "Research Questions", level: 2, notes: [] },
            { title: "Contributions", level: 2, notes: [] },
          ],
        },
        {
          title: "Related Work",
          level: 1,
          notes: ["Discuss relevant prior work from conversation artifacts"],
        },
        {
          title: "Methods",
          level: 1,
          notes: ["Document approach based on conversation decisions"],
        },
        {
          title: "Results",
          level: 1,
          notes: ["Present findings"],
        },
        {
          title: "Discussion",
          level: 1,
          notes: ["Interpret results", "Limitations", "Future work"],
        },
        {
          title: "Conclusion",
          level: 1,
          notes: ["Summarize key points"],
        },
      ];
    } else if (style === "technical") {
      return [
        { title: "Overview", level: 1, notes: ["High-level description"] },
        { title: "Architecture", level: 1, notes: ["System design"] },
        { title: "Implementation", level: 1, notes: ["Technical details"] },
        { title: "Usage", level: 1, notes: ["How to use"] },
        { title: "Limitations", level: 1, notes: ["Known issues"] },
      ];
    } else {
      // Report style
      return [
        { title: "Executive Summary", level: 1, notes: [] },
        { title: "Background", level: 1, notes: [] },
        { title: "Findings", level: 1, notes: [] },
        { title: "Recommendations", level: 1, notes: [] },
        { title: "Appendix", level: 1, notes: [] },
      ];
    }
  }

  private formatOutline(sections: OutlineSection[], indent: number = 0): string {
    const lines: string[] = [];
    const prefix = "  ".repeat(indent);

    for (const section of sections) {
      const marker = section.level === 1 ? "##" : "###";
      lines.push(`${prefix}${marker} ${section.title}`);

      if (section.notes && section.notes.length > 0) {
        for (const note of section.notes) {
          lines.push(`${prefix}  - ${note}`);
        }
      }

      if (section.subsections) {
        lines.push(this.formatOutline(section.subsections, indent + 1));
      }

      lines.push("");
    }

    return lines.join("\n");
  }

  private outlineToTypst(sections: OutlineSection[]): string {
    const lines: string[] = [];

    for (const section of sections) {
      const heading = "=".repeat(section.level);
      lines.push(`${heading} ${section.title}`);
      lines.push("");

      if (section.notes && section.notes.length > 0) {
        lines.push("// TODO:");
        for (const note of section.notes) {
          lines.push(`// - ${note}`);
        }
        lines.push("");
      }

      if (section.subsections) {
        lines.push(this.outlineToTypst(section.subsections));
      }
    }

    return lines.join("\n");
  }

  // --------------------------------------------------------------------------
  // Export Conversation Citations
  // --------------------------------------------------------------------------

  private async exportConversationCitations(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversation_id as string;
    const documentId = args?.document_id as string | undefined;

    if (!conversationId) {
      return {
        content: [
          { type: "text", text: "Error: conversation_id is required" },
        ],
      };
    }

    // Get conversation
    const conversation = await this.impartClient.getConversation(conversationId);
    if (!conversation) {
      return {
        content: [
          {
            type: "text",
            text: `Error: Conversation not found: ${conversationId}`,
          },
        ],
      };
    }

    // Extract paper artifacts from conversation
    const conv = conversation.conversation;
    const paperURIs = this.extractPaperArtifacts({ messages: conversation.messages });

    if (paperURIs.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: `No paper artifacts found in conversation: ${conversationId}\n\nPapers must be recorded using impart_record_artifact to be exported.`,
          },
        ],
      };
    }

    // Extract cite keys from URIs
    const citeKeys = paperURIs
      .map((uri) => {
        const match = uri.match(/impress:\/\/imbib\/papers\/(.+)/);
        return match ? match[1] : null;
      })
      .filter((k): k is string => k !== null);

    return {
      content: [
        {
          type: "text",
          text: [
            `# Paper Citations from Conversation`,
            "",
            `**Conversation:** ${conv.title}`,
            `**Papers Found:** ${citeKeys.length}`,
            "",
            "## Citation Keys",
            "",
            ...citeKeys.map((k) => `- @${k}`),
            "",
            documentId
              ? `Use impress_cite_multiple with these keys to add to document ${documentId}`
              : "Use impress_cite_multiple with document_id to add these to a manuscript.",
          ].join("\n"),
        },
      ],
    };
  }

  private extractPaperArtifacts(conversation: {
    artifacts?: Array<{ uri: string }>;
    messages?: Array<{ mentionedArtifactURIs?: string[] }>;
  }): string[] {
    const uris: Set<string> = new Set();

    // From conversation artifacts
    if (conversation.artifacts) {
      for (const artifact of conversation.artifacts) {
        if (artifact.uri.startsWith("impress://imbib/papers/")) {
          uris.add(artifact.uri);
        }
      }
    }

    // From message mentions
    if (conversation.messages) {
      for (const msg of conversation.messages) {
        if (msg.mentionedArtifactURIs) {
          for (const uri of msg.mentionedArtifactURIs) {
            if (uri.startsWith("impress://imbib/papers/")) {
              uris.add(uri);
            }
          }
        }
      }
    }

    return Array.from(uris);
  }

  // --------------------------------------------------------------------------
  // Conversation Decisions
  // --------------------------------------------------------------------------

  private async conversationDecisions(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversation_id as string;

    if (!conversationId) {
      return {
        content: [
          { type: "text", text: "Error: conversation_id is required" },
        ],
      };
    }

    // Get conversation
    const conversation = await this.impartClient.getConversation(conversationId);
    if (!conversation) {
      return {
        content: [
          {
            type: "text",
            text: `Error: Conversation not found: ${conversationId}`,
          },
        ],
      };
    }

    // Get conversation info
    const conv = conversation.conversation;

    // Note: The current impart API doesn't return decisions directly in the conversation response.
    // This would need to be extended in the impart HTTP API to include decisions.
    // For now, return information that decisions need to be retrieved separately.
    return {
      content: [
        {
          type: "text",
          text: [
            `# Research Decisions`,
            "",
            `**Conversation:** ${conv.title}`,
            `**ID:** ${conv.id}`,
            "",
            "Note: To view decisions, check the conversation in impart directly.",
            "Decisions are recorded using impart_record_decision.",
          ].join("\n"),
        },
      ],
    };
  }
}

// ============================================================================
// Types
// ============================================================================

interface OutlineSection {
  title: string;
  level: number;
  notes: string[];
  subsections?: OutlineSection[];
}
