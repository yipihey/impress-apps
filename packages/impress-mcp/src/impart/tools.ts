/**
 * MCP tool definitions for impart
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImpartClient } from "./client.js";

export const IMPART_TOOLS: Tool[] = [
  {
    name: "impart_status",
    description:
      "Check if impart is running and get basic info. Returns account count and server status.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "impart_get_logs",
    description:
      "Get log entries from impart's in-app console. Useful for debugging email sync, IMAP/SMTP operations, and AI research sessions.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "number",
          description: "Maximum entries to return (default: 100)",
        },
        level: {
          type: "string",
          description:
            'Comma-separated log levels to include (e.g. "info,warning,error"). Default: all levels.',
        },
        category: {
          type: "string",
          description:
            'Filter by category substring (e.g. "imap", "smtp", "sync", "counsel")',
        },
        search: {
          type: "string",
          description: "Filter by message text (case-insensitive)",
        },
        after: {
          type: "string",
          description:
            "ISO8601 timestamp - only return entries after this time",
        },
      },
    },
  },
  // Research Conversation Tools
  {
    name: "impart_list_conversations",
    description:
      "List research conversations. Returns conversations with metadata, participant info, and activity timestamps.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "number",
          description: "Maximum conversations to return (default: 50)",
        },
        offset: {
          type: "number",
          description: "Offset for pagination (default: 0)",
        },
        includeArchived: {
          type: "boolean",
          description: "Include archived conversations (default: false)",
        },
      },
    },
  },
  {
    name: "impart_get_conversation",
    description:
      "Get a specific research conversation with all messages and statistics. Includes full message history, participant info, and conversation analytics.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "The conversation UUID",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "impart_create_conversation",
    description:
      "Create a new research conversation. Returns the new conversation ID. The conversation will be available in impart for interactive use.",
    inputSchema: {
      type: "object",
      properties: {
        title: {
          type: "string",
          description: "Title of the conversation",
        },
        participants: {
          type: "array",
          items: { type: "string" },
          description:
            'Optional participant identifiers (e.g. "user@email.com", "counsel-opus4.5@impart.local")',
        },
      },
      required: ["title"],
    },
  },
  {
    name: "impart_add_message",
    description:
      "Add a message to an existing research conversation. The message will be queued for UI synchronization in impart.",
    inputSchema: {
      type: "object",
      properties: {
        conversationId: {
          type: "string",
          description: "The conversation UUID",
        },
        senderRole: {
          type: "string",
          enum: ["human", "counsel", "system"],
          description: "Role of the message sender",
        },
        senderId: {
          type: "string",
          description:
            'Sender identifier (email for human, agent address like "counsel-opus4.5@impart.local" for AI)',
        },
        content: {
          type: "string",
          description: "Message content in Markdown format",
        },
        causationId: {
          type: "string",
          description: "Optional UUID of the message this is responding to",
        },
      },
      required: ["conversationId", "senderRole", "senderId", "content"],
    },
  },
  {
    name: "impart_branch_conversation",
    description:
      "Branch a research conversation from a specific message. Creates a side conversation for exploring tangential topics while preserving the main thread.",
    inputSchema: {
      type: "object",
      properties: {
        conversationId: {
          type: "string",
          description: "The parent conversation UUID",
        },
        fromMessageId: {
          type: "string",
          description: "The message UUID to branch from",
        },
        title: {
          type: "string",
          description: "Title for the new branch conversation",
        },
      },
      required: ["conversationId", "fromMessageId", "title"],
    },
  },
  {
    name: "impart_update_conversation",
    description:
      "Update metadata for a research conversation. Can update title, summary, and/or tags.",
    inputSchema: {
      type: "object",
      properties: {
        conversationId: {
          type: "string",
          description: "The conversation UUID",
        },
        title: {
          type: "string",
          description: "New title (optional)",
        },
        summary: {
          type: "string",
          description: "New AI-generated summary (optional)",
        },
        tags: {
          type: "array",
          items: { type: "string" },
          description: "New tags to set (optional, replaces existing)",
        },
      },
      required: ["conversationId"],
    },
  },
  {
    name: "impart_record_artifact",
    description:
      "Record an artifact reference in a conversation. Artifacts are external resources like papers, repositories, datasets that are discussed in the conversation.",
    inputSchema: {
      type: "object",
      properties: {
        conversationId: {
          type: "string",
          description: "The conversation UUID",
        },
        uri: {
          type: "string",
          description:
            'The artifact URI (e.g. "impress://imbib/papers/Fowler2012", "https://github.com/...", "doi:10.1234/...")',
        },
        type: {
          type: "string",
          description:
            'Artifact type (e.g. "paper", "repository", "dataset", "document")',
        },
        displayName: {
          type: "string",
          description: "Optional human-readable display name",
        },
      },
      required: ["conversationId", "uri", "type"],
    },
  },
  {
    name: "impart_record_decision",
    description:
      "Record a decision made during a research conversation. Captures the decision description and rationale for future reference and provenance tracking.",
    inputSchema: {
      type: "object",
      properties: {
        conversationId: {
          type: "string",
          description: "The conversation UUID",
        },
        description: {
          type: "string",
          description: "What was decided",
        },
        rationale: {
          type: "string",
          description: "Why this decision was made",
        },
      },
      required: ["conversationId", "description", "rationale"],
    },
  },
];

export class ImpartTools {
  constructor(private client: ImpartClient) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      case "impart_status":
        return this.getStatus();
      case "impart_get_logs":
        return this.getLogs(args);
      case "impart_list_conversations":
        return this.listConversations(args);
      case "impart_get_conversation":
        return this.getConversation(args);
      case "impart_create_conversation":
        return this.createConversation(args);
      case "impart_add_message":
        return this.addMessage(args);
      case "impart_branch_conversation":
        return this.branchConversation(args);
      case "impart_update_conversation":
        return this.updateConversation(args);
      case "impart_record_artifact":
        return this.recordArtifact(args);
      case "impart_record_decision":
        return this.recordDecision(args);
      default:
        return {
          content: [{ type: "text", text: `Unknown impart tool: ${name}` }],
        };
    }
  }

  private async getStatus(): Promise<{
    content: Array<{ type: string; text: string }>;
  }> {
    const status = await this.client.checkStatus();

    if (!status) {
      return {
        content: [
          {
            type: "text",
            text: "impart is not running or HTTP API is disabled.\n\nTo enable:\n1. Open impart\n2. Go to Settings > Automation\n3. Enable HTTP Server",
          },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: [
            "# impart Status",
            "",
            `**Status:** ${status.status}`,
            `**Version:** ${status.version}`,
            `**Accounts:** ${status.accounts}`,
            `**Port:** ${status.port}`,
          ].join("\n"),
        },
      ],
    };
  }

  private async getLogs(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.getLogs({
      limit: args?.limit as number | undefined,
      level: args?.level as string | undefined,
      category: args?.category as string | undefined,
      search: args?.search as string | undefined,
      after: args?.after as string | undefined,
    });

    if (result.data.entries.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: `No log entries found (${result.data.totalInStore} total in store)`,
          },
        ],
      };
    }

    const lines = result.data.entries.map((e) => {
      const time = e.timestamp.replace(/.*T/, "").replace(/Z$/, "");
      const level = e.level.toUpperCase().padEnd(7);
      return `[${time}] [${level}] [${e.category}] ${e.message}`;
    });

    return {
      content: [
        {
          type: "text",
          text: `# impart Logs (${result.data.entries.length} of ${result.data.count} filtered, ${result.data.totalInStore} total)\n\n\`\`\`\n${lines.join("\n")}\n\`\`\``,
        },
      ],
    };
  }

  // ============================================================
  // Research Conversation Handlers
  // ============================================================

  private async listConversations(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    try {
      const result = await this.client.listConversations({
        limit: args?.limit as number | undefined,
        offset: args?.offset as number | undefined,
        includeArchived: args?.includeArchived as boolean | undefined,
      });

      if (result.conversations.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: `No research conversations found (${result.total} total)`,
            },
          ],
        };
      }

      const lines = result.conversations.map((c) => {
        const archived = c.isArchived ? " [ARCHIVED]" : "";
        const tags = c.tags.length > 0 ? ` [${c.tags.join(", ")}]` : "";
        return `- **${c.title}**${archived}${tags}\n  ID: ${c.id}\n  Participants: ${c.participants.join(", ")}\n  Last activity: ${c.lastActivityAt}`;
      });

      return {
        content: [
          {
            type: "text",
            text: `# Research Conversations (${result.count} of ${result.total})\n\n${lines.join("\n\n")}`,
          },
        ],
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text: `Error listing conversations: ${error instanceof Error ? error.message : "Unknown error"}`,
          },
        ],
      };
    }
  }

  private async getConversation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string;
    if (!id) {
      return {
        content: [{ type: "text", text: "Missing required parameter: id" }],
      };
    }

    try {
      const result = await this.client.getConversation(id);
      const c = result.conversation;
      const s = result.statistics;

      const messageLines = result.messages.map((m) => {
        const role = m.senderRole.toUpperCase().padEnd(7);
        const tokens = m.tokenCount ? ` (${m.tokenCount} tokens)` : "";
        return `[${role}] ${m.senderId}${tokens}\n${m.contentMarkdown.substring(0, 500)}${m.contentMarkdown.length > 500 ? "..." : ""}`;
      });

      const statsText = [
        `Messages: ${s.messageCount} (${s.humanMessageCount} human, ${s.counselMessageCount} AI)`,
        `Artifacts: ${s.artifactCount} (${s.paperCount} papers, ${s.repositoryCount} repos)`,
        `Tokens: ${s.totalTokens}`,
        `Branches: ${s.branchCount}`,
      ].join(" | ");

      return {
        content: [
          {
            type: "text",
            text: [
              `# ${c.title}`,
              "",
              `**ID:** ${c.id}`,
              `**Participants:** ${c.participants.join(", ")}`,
              `**Tags:** ${c.tags.length > 0 ? c.tags.join(", ") : "none"}`,
              `**Created:** ${c.createdAt}`,
              `**Last Activity:** ${c.lastActivityAt}`,
              c.isArchived ? "**Status:** Archived" : "",
              c.summaryText ? `\n**Summary:** ${c.summaryText}` : "",
              "",
              `## Statistics`,
              statsText,
              "",
              `## Messages (${result.messages.length})`,
              "",
              messageLines.join("\n\n---\n\n"),
            ]
              .filter(Boolean)
              .join("\n"),
          },
        ],
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text: `Error getting conversation: ${error instanceof Error ? error.message : "Unknown error"}`,
          },
        ],
      };
    }
  }

  private async createConversation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const title = args?.title as string;
    if (!title) {
      return {
        content: [{ type: "text", text: "Missing required parameter: title" }],
      };
    }

    try {
      const result = await this.client.createConversation(
        title,
        args?.participants as string[] | undefined
      );

      return {
        content: [
          {
            type: "text",
            text: [
              `# Conversation Created`,
              "",
              `**ID:** ${result.conversationId}`,
              `**Title:** ${result.title}`,
              `**Participants:** ${result.participants.join(", ") || "none"}`,
              "",
              result.message,
            ].join("\n"),
          },
        ],
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text: `Error creating conversation: ${error instanceof Error ? error.message : "Unknown error"}`,
          },
        ],
      };
    }
  }

  private async addMessage(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversationId as string;
    const senderRole = args?.senderRole as "human" | "counsel" | "system";
    const senderId = args?.senderId as string;
    const content = args?.content as string;

    if (!conversationId || !senderRole || !senderId || !content) {
      return {
        content: [
          {
            type: "text",
            text: "Missing required parameters: conversationId, senderRole, senderId, content",
          },
        ],
      };
    }

    try {
      const result = await this.client.addMessage(
        conversationId,
        senderRole,
        senderId,
        content,
        args?.causationId as string | undefined
      );

      return {
        content: [
          {
            type: "text",
            text: [
              `# Message Added`,
              "",
              `**Conversation:** ${result.conversationId}`,
              `**Role:** ${result.senderRole}`,
              `**Sender:** ${result.senderId}`,
              "",
              result.message,
            ].join("\n"),
          },
        ],
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text: `Error adding message: ${error instanceof Error ? error.message : "Unknown error"}`,
          },
        ],
      };
    }
  }

  private async branchConversation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversationId as string;
    const fromMessageId = args?.fromMessageId as string;
    const title = args?.title as string;

    if (!conversationId || !fromMessageId || !title) {
      return {
        content: [
          {
            type: "text",
            text: "Missing required parameters: conversationId, fromMessageId, title",
          },
        ],
      };
    }

    try {
      const result = await this.client.branchConversation(
        conversationId,
        fromMessageId,
        title
      );

      return {
        content: [
          {
            type: "text",
            text: [
              `# Conversation Branched`,
              "",
              `**Parent Conversation:** ${result.conversationId}`,
              `**From Message:** ${result.fromMessageId}`,
              `**Branch Title:** ${result.title}`,
              "",
              result.message,
            ].join("\n"),
          },
        ],
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text: `Error branching conversation: ${error instanceof Error ? error.message : "Unknown error"}`,
          },
        ],
      };
    }
  }

  private async updateConversation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversationId as string;
    if (!conversationId) {
      return {
        content: [
          { type: "text", text: "Missing required parameter: conversationId" },
        ],
      };
    }

    const updates: { title?: string; summary?: string; tags?: string[] } = {};
    if (args?.title) updates.title = args.title as string;
    if (args?.summary) updates.summary = args.summary as string;
    if (args?.tags) updates.tags = args.tags as string[];

    if (Object.keys(updates).length === 0) {
      return {
        content: [
          {
            type: "text",
            text: "At least one of title, summary, or tags must be provided",
          },
        ],
      };
    }

    try {
      const result = await this.client.updateConversation(
        conversationId,
        updates
      );

      return {
        content: [
          {
            type: "text",
            text: [
              `# Conversation Updated`,
              "",
              `**ID:** ${result.conversationId}`,
              "",
              result.message,
            ].join("\n"),
          },
        ],
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text: `Error updating conversation: ${error instanceof Error ? error.message : "Unknown error"}`,
          },
        ],
      };
    }
  }

  private async recordArtifact(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversationId as string;
    const uri = args?.uri as string;
    const type = args?.type as string;

    if (!conversationId || !uri || !type) {
      return {
        content: [
          {
            type: "text",
            text: "Missing required parameters: conversationId, uri, type",
          },
        ],
      };
    }

    try {
      const result = await this.client.recordArtifact(
        conversationId,
        uri,
        type,
        args?.displayName as string | undefined
      );

      return {
        content: [
          {
            type: "text",
            text: [
              `# Artifact Recorded`,
              "",
              `**Conversation:** ${result.conversationId}`,
              `**URI:** ${result.uri}`,
              `**Type:** ${result.type}`,
              "",
              result.message,
            ].join("\n"),
          },
        ],
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text: `Error recording artifact: ${error instanceof Error ? error.message : "Unknown error"}`,
          },
        ],
      };
    }
  }

  private async recordDecision(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversationId as string;
    const description = args?.description as string;
    const rationale = args?.rationale as string;

    if (!conversationId || !description || !rationale) {
      return {
        content: [
          {
            type: "text",
            text: "Missing required parameters: conversationId, description, rationale",
          },
        ],
      };
    }

    try {
      const result = await this.client.recordDecision(
        conversationId,
        description,
        rationale
      );

      return {
        content: [
          {
            type: "text",
            text: [
              `# Decision Recorded`,
              "",
              `**Conversation:** ${result.conversationId}`,
              `**Decision:** ${result.description}`,
              "",
              result.message,
            ].join("\n"),
          },
        ],
      };
    } catch (error) {
      return {
        content: [
          {
            type: "text",
            text: `Error recording decision: ${error instanceof Error ? error.message : "Unknown error"}`,
          },
        ],
      };
    }
  }
}
