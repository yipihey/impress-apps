/**
 * MCP tool definitions for imprint
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImprintClient } from "./client.js";

export const IMPRINT_TOOLS: Tool[] = [
  {
    name: "imprint_list_documents",
    description:
      "List all currently open imprint documents. Returns document IDs, titles, and metadata.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "imprint_get_document",
    description:
      "Get metadata about a specific imprint document by its ID.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
      },
      required: ["documentId"],
    },
  },
  {
    name: "imprint_get_content",
    description:
      "Get the full source content (Typst) of an imprint document. Useful for reading or modifying document text.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
      },
      required: ["documentId"],
    },
  },
  {
    name: "imprint_create_document",
    description:
      "Request creation of a new imprint document with optional title and initial content.",
    inputSchema: {
      type: "object",
      properties: {
        title: {
          type: "string",
          description: "Document title (default: 'Untitled')",
        },
        source: {
          type: "string",
          description: "Initial Typst source content",
        },
      },
    },
  },
  {
    name: "imprint_insert_citation",
    description:
      "Insert a citation into an imprint document. The citation will be added at the current cursor position or specified location.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        citeKey: {
          type: "string",
          description:
            "The cite key to insert (e.g., 'Einstein1905')",
        },
        bibtex: {
          type: "string",
          description:
            "Optional BibTeX entry to add to the document bibliography",
        },
        position: {
          type: "number",
          description:
            "Optional character position to insert at (default: current cursor)",
        },
      },
      required: ["documentId", "citeKey"],
    },
  },
  {
    name: "imprint_compile",
    description:
      "Compile an imprint document to PDF. Triggers the Typst compiler and generates output.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document to compile",
        },
      },
      required: ["documentId"],
    },
  },
  {
    name: "imprint_update_document",
    description:
      "Update an imprint document's source content or title.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        source: {
          type: "string",
          description: "New Typst source content",
        },
        title: {
          type: "string",
          description: "New document title",
        },
      },
      required: ["documentId"],
    },
  },
  {
    name: "imprint_status",
    description:
      "Check if imprint is running and get application status.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
];

export class ImprintTools {
  constructor(private client: ImprintClient) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      case "imprint_list_documents":
        return this.listDocuments();
      case "imprint_get_document":
        return this.getDocument(args);
      case "imprint_get_content":
        return this.getContent(args);
      case "imprint_create_document":
        return this.createDocument(args);
      case "imprint_insert_citation":
        return this.insertCitation(args);
      case "imprint_compile":
        return this.compile(args);
      case "imprint_update_document":
        return this.updateDocument(args);
      case "imprint_status":
        return this.getStatus();
      default:
        return {
          content: [{ type: "text", text: `Unknown imprint tool: ${name}` }],
        };
    }
  }

  private async listDocuments(): Promise<{
    content: Array<{ type: string; text: string }>;
  }> {
    const result = await this.client.listDocuments();

    if (result.documents.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: "No documents are currently open in imprint.",
          },
        ],
      };
    }

    const docList = result.documents
      .map((d) => {
        const authors =
          d.authors.length > 0 ? `\n  Authors: ${d.authors.join(", ")}` : "";
        const citations =
          d.citationCount !== undefined
            ? `\n  Citations: ${d.citationCount}`
            : "";
        return `- **${d.title}**\n  ID: ${d.id}${authors}${citations}\n  Modified: ${d.modifiedAt}`;
      })
      .join("\n\n");

    return {
      content: [
        {
          type: "text",
          text: `# Open Documents (${result.count})\n\n${docList}`,
        },
      ],
    };
  }

  private async getDocument(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const doc = await this.client.getDocument(documentId);
    if (!doc) {
      return {
        content: [{ type: "text", text: `Document not found: ${documentId}` }],
      };
    }

    const info = [
      `# ${doc.title}`,
      "",
      `**ID:** ${doc.id}`,
      doc.authors.length > 0 ? `**Authors:** ${doc.authors.join(", ")}` : null,
      `**Created:** ${doc.createdAt}`,
      `**Modified:** ${doc.modifiedAt}`,
      doc.bibliography
        ? `**Bibliography:** ${doc.bibliography.length} entries`
        : null,
      doc.linkedImbibManuscriptID
        ? `**Linked imbib Manuscript:** ${doc.linkedImbibManuscriptID}`
        : null,
    ]
      .filter(Boolean)
      .join("\n");

    return {
      content: [{ type: "text", text: info }],
    };
  }

  private async getContent(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const content = await this.client.getDocumentContent(documentId);
    if (!content) {
      return {
        content: [{ type: "text", text: `Document not found: ${documentId}` }],
      };
    }

    const bibEntries = Object.keys(content.bibliography || {});
    const bibInfo =
      bibEntries.length > 0
        ? `\n\n---\n**Bibliography entries:** ${bibEntries.join(", ")}`
        : "";

    return {
      content: [
        {
          type: "text",
          text: `# Document Content\n\n\`\`\`typst\n${content.source}\n\`\`\`${bibInfo}`,
        },
      ],
    };
  }

  private async createDocument(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const title = args?.title as string | undefined;
    const source = args?.source as string | undefined;

    const result = await this.client.createDocument({ title, source });

    return {
      content: [
        {
          type: "text",
          text: `Document creation requested:\n- **Title:** ${result.title}\n- **ID:** ${result.id}`,
        },
      ],
    };
  }

  private async insertCitation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    const citeKey = String(args?.citeKey || "");

    if (!documentId || !citeKey) {
      return {
        content: [
          {
            type: "text",
            text: "Error: documentId and citeKey are required",
          },
        ],
      };
    }

    const bibtex = args?.bibtex as string | undefined;
    const position = args?.position as number | undefined;

    await this.client.insertCitation(documentId, citeKey, { bibtex, position });

    return {
      content: [
        {
          type: "text",
          text: `Citation @${citeKey} inserted into document ${documentId}`,
        },
      ],
    };
  }

  private async compile(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    await this.client.compileDocument(documentId);

    return {
      content: [
        {
          type: "text",
          text: `Compilation triggered for document ${documentId}. PDF will be generated.`,
        },
      ],
    };
  }

  private async updateDocument(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const source = args?.source as string | undefined;
    const title = args?.title as string | undefined;

    if (!source && !title) {
      return {
        content: [
          { type: "text", text: "Error: At least source or title must be provided" },
        ],
      };
    }

    await this.client.updateDocument(documentId, { source, title });

    return {
      content: [
        {
          type: "text",
          text: `Document ${documentId} updated successfully`,
        },
      ],
    };
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
            text: "imprint is not running or HTTP API is disabled.\n\nTo enable:\n1. Open imprint\n2. Go to Settings > Automation\n3. Enable HTTP Server",
          },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: [
            "# imprint Status",
            "",
            `**Status:** ${status.status}`,
            `**App:** ${status.app}`,
            `**Version:** ${status.version}`,
            `**Open Documents:** ${status.openDocuments}`,
            `**Port:** ${status.port}`,
          ].join("\n"),
        },
      ],
    };
  }
}
