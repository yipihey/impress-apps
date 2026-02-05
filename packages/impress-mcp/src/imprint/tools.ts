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
    name: "imprint_get_outline",
    description:
      "Get the document structure (headings) of an imprint document. Returns a hierarchical list of sections with their levels, titles, and positions.",
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
    name: "imprint_get_pdf",
    description:
      "Check if a compiled PDF is available for the document. Returns PDF metadata. Use imprint_compile first if needed.",
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
    name: "imprint_search",
    description:
      "Search for text in an imprint document. Returns positions of all matches.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        query: {
          type: "string",
          description: "Text or pattern to search for",
        },
        regex: {
          type: "boolean",
          description: "Treat query as a regular expression (default: false)",
        },
        caseSensitive: {
          type: "boolean",
          description: "Case-sensitive search (default: false)",
        },
      },
      required: ["documentId", "query"],
    },
  },
  {
    name: "imprint_replace",
    description:
      "Search and replace text in an imprint document.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        search: {
          type: "string",
          description: "Text to search for",
        },
        replacement: {
          type: "string",
          description: "Text to replace with",
        },
        all: {
          type: "boolean",
          description: "Replace all occurrences (default: false, replaces first only)",
        },
      },
      required: ["documentId", "search", "replacement"],
    },
  },
  {
    name: "imprint_insert_text",
    description:
      "Insert text at a specific position in an imprint document.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        position: {
          type: "number",
          description: "Character position to insert at (0-indexed)",
        },
        text: {
          type: "string",
          description: "Text to insert",
        },
      },
      required: ["documentId", "position", "text"],
    },
  },
  {
    name: "imprint_delete_text",
    description:
      "Delete a range of text from an imprint document.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        start: {
          type: "number",
          description: "Start position of range to delete (0-indexed)",
        },
        end: {
          type: "number",
          description: "End position of range to delete (exclusive)",
        },
      },
      required: ["documentId", "start", "end"],
    },
  },
  {
    name: "imprint_get_bibliography",
    description:
      "Get all citations in the document's bibliography.",
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
    name: "imprint_add_citation",
    description:
      "Add a citation to the document's bibliography without inserting it in the text.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        citeKey: {
          type: "string",
          description: "The cite key (e.g., 'Einstein1905')",
        },
        bibtex: {
          type: "string",
          description: "The BibTeX entry",
        },
      },
      required: ["documentId", "citeKey", "bibtex"],
    },
  },
  {
    name: "imprint_remove_citation",
    description:
      "Remove a citation from the document's bibliography.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        citeKey: {
          type: "string",
          description: "The cite key to remove",
        },
      },
      required: ["documentId", "citeKey"],
    },
  },
  {
    name: "imprint_get_citation_usages",
    description:
      "Find all places where citations are used in the document source.",
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
    name: "imprint_update_metadata",
    description:
      "Update document metadata (title, authors).",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        title: {
          type: "string",
          description: "New document title",
        },
        authors: {
          type: "array",
          items: { type: "string" },
          description: "New author list",
        },
      },
      required: ["documentId"],
    },
  },
  {
    name: "imprint_export_latex",
    description:
      "Export an imprint document as LaTeX.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: {
          type: "string",
          description: "The UUID of the document",
        },
        template: {
          type: "string",
          description: "LaTeX template to use (e.g., 'mnras', 'aastex', 'article')",
        },
      },
      required: ["documentId"],
    },
  },
  {
    name: "imprint_export_text",
    description:
      "Export an imprint document as plain text (formatting stripped).",
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
    name: "imprint_export_typst",
    description:
      "Export an imprint document as Typst source with its bibliography.",
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
    name: "imprint_get_logs",
    description:
      "Get log entries from imprint's in-app console. Useful for debugging.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "number",
          description: "Maximum entries to return (default: 100)",
        },
        offset: {
          type: "number",
          description: "Entries to skip (for pagination)",
        },
        level: {
          type: "string",
          description: "Filter by log level(s), comma-separated (e.g., 'info,warning,error')",
        },
        category: {
          type: "string",
          description: "Filter by category substring",
        },
        search: {
          type: "string",
          description: "Filter by message text",
        },
        after: {
          type: "string",
          description: "Only entries after this ISO8601 timestamp",
        },
      },
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
      case "imprint_get_outline":
        return this.getOutline(args);
      case "imprint_get_pdf":
        return this.getPDF(args);
      case "imprint_create_document":
        return this.createDocument(args);
      case "imprint_insert_citation":
        return this.insertCitation(args);
      case "imprint_compile":
        return this.compile(args);
      case "imprint_update_document":
        return this.updateDocument(args);
      case "imprint_search":
        return this.search(args);
      case "imprint_replace":
        return this.replace(args);
      case "imprint_insert_text":
        return this.insertText(args);
      case "imprint_delete_text":
        return this.deleteText(args);
      case "imprint_get_bibliography":
        return this.getBibliography(args);
      case "imprint_add_citation":
        return this.addCitation(args);
      case "imprint_remove_citation":
        return this.removeCitation(args);
      case "imprint_get_citation_usages":
        return this.getCitationUsages(args);
      case "imprint_update_metadata":
        return this.updateMetadata(args);
      case "imprint_export_latex":
        return this.exportLatex(args);
      case "imprint_export_text":
        return this.exportText(args);
      case "imprint_export_typst":
        return this.exportTypst(args);
      case "imprint_get_logs":
        return this.getLogs(args);
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

  private async getOutline(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const result = await this.client.getOutline(documentId);
    if (!result) {
      return {
        content: [{ type: "text", text: `Document not found: ${documentId}` }],
      };
    }

    if (result.outline.length === 0) {
      return {
        content: [
          { type: "text", text: "No headings found in the document." },
        ],
      };
    }

    const outlineText = result.outline
      .map((item) => {
        const indent = "  ".repeat(item.level - 1);
        return `${indent}- ${item.title} (line ${item.line})`;
      })
      .join("\n");

    return {
      content: [
        {
          type: "text",
          text: `# Document Outline\n\n${outlineText}`,
        },
      ],
    };
  }

  private async getPDF(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const pdfData = await this.client.getPDF(documentId);
    if (!pdfData) {
      return {
        content: [
          {
            type: "text",
            text: `PDF not available for document ${documentId}. Use imprint_compile first to generate it.`,
          },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: `PDF available for document ${documentId}. Size: ${Math.round(pdfData.byteLength / 1024)} KB`,
        },
      ],
    };
  }

  private async search(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    const query = String(args?.query || "");

    if (!documentId || !query) {
      return {
        content: [
          { type: "text", text: "Error: documentId and query are required" },
        ],
      };
    }

    const result = await this.client.searchText(documentId, query, {
      regex: args?.regex as boolean | undefined,
      caseSensitive: args?.caseSensitive as boolean | undefined,
    });

    if (!result) {
      return {
        content: [{ type: "text", text: `Document not found: ${documentId}` }],
      };
    }

    if (result.matchCount === 0) {
      return {
        content: [
          { type: "text", text: `No matches found for "${query}"` },
        ],
      };
    }

    const matchList = result.matches
      .slice(0, 10)
      .map((m, i) => `${i + 1}. Position ${m.position}: "${m.text}"`)
      .join("\n");

    const moreText =
      result.matchCount > 10
        ? `\n\n... and ${result.matchCount - 10} more matches`
        : "";

    return {
      content: [
        {
          type: "text",
          text: `# Search Results\n\nFound ${result.matchCount} matches for "${query}":\n\n${matchList}${moreText}`,
        },
      ],
    };
  }

  private async replace(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    const search = String(args?.search || "");
    const replacement = String(args?.replacement || "");

    if (!documentId || !search) {
      return {
        content: [
          {
            type: "text",
            text: "Error: documentId and search are required",
          },
        ],
      };
    }

    const replaceAll = args?.all as boolean | undefined;

    await this.client.replaceText(documentId, search, replacement, replaceAll);

    return {
      content: [
        {
          type: "text",
          text: `Replace requested: "${search}" → "${replacement}" (${replaceAll ? "all occurrences" : "first occurrence"})`,
        },
      ],
    };
  }

  private async insertText(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    const position = args?.position as number | undefined;
    const text = String(args?.text || "");

    if (!documentId || position === undefined || !text) {
      return {
        content: [
          {
            type: "text",
            text: "Error: documentId, position, and text are required",
          },
        ],
      };
    }

    await this.client.insertText(documentId, position, text);

    return {
      content: [
        {
          type: "text",
          text: `Inserted ${text.length} characters at position ${position}`,
        },
      ],
    };
  }

  private async deleteText(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    const start = args?.start as number | undefined;
    const end = args?.end as number | undefined;

    if (!documentId || start === undefined || end === undefined) {
      return {
        content: [
          {
            type: "text",
            text: "Error: documentId, start, and end are required",
          },
        ],
      };
    }

    await this.client.deleteText(documentId, start, end);

    return {
      content: [
        {
          type: "text",
          text: `Deleted ${end - start} characters from position ${start} to ${end}`,
        },
      ],
    };
  }

  private async getBibliography(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const result = await this.client.getBibliography(documentId);
    if (!result) {
      return {
        content: [{ type: "text", text: `Document not found: ${documentId}` }],
      };
    }

    if (result.count === 0) {
      return {
        content: [
          { type: "text", text: "No citations in document bibliography." },
        ],
      };
    }

    const citationList = result.citations
      .map((c) => `- **${c.citeKey}**`)
      .join("\n");

    return {
      content: [
        {
          type: "text",
          text: `# Bibliography (${result.count} entries)\n\n${citationList}`,
        },
      ],
    };
  }

  private async addCitation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    const citeKey = String(args?.citeKey || "");
    const bibtex = String(args?.bibtex || "");

    if (!documentId || !citeKey || !bibtex) {
      return {
        content: [
          {
            type: "text",
            text: "Error: documentId, citeKey, and bibtex are required",
          },
        ],
      };
    }

    await this.client.addCitation(documentId, citeKey, bibtex);

    return {
      content: [
        {
          type: "text",
          text: `Citation "${citeKey}" added to bibliography`,
        },
      ],
    };
  }

  private async removeCitation(
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

    await this.client.removeCitation(documentId, citeKey);

    return {
      content: [
        {
          type: "text",
          text: `Citation "${citeKey}" removed from bibliography`,
        },
      ],
    };
  }

  private async getCitationUsages(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const result = await this.client.getCitationUsages(documentId);
    if (!result) {
      return {
        content: [{ type: "text", text: `Document not found: ${documentId}` }],
      };
    }

    if (result.usages.length === 0) {
      return {
        content: [
          { type: "text", text: "No citation usages found in document." },
        ],
      };
    }

    // Group by cite key
    const byKey: Record<string, number[]> = {};
    for (const usage of result.usages) {
      if (!byKey[usage.citeKey]) {
        byKey[usage.citeKey] = [];
      }
      byKey[usage.citeKey].push(usage.position);
    }

    const usageList = Object.entries(byKey)
      .map(([key, positions]) => `- @${key}: ${positions.length} usage(s) at positions ${positions.join(", ")}`)
      .join("\n");

    return {
      content: [
        {
          type: "text",
          text: `# Citation Usages\n\n${usageList}`,
        },
      ],
    };
  }

  private async updateMetadata(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const title = args?.title as string | undefined;
    const authors = args?.authors as string[] | undefined;

    if (!title && !authors) {
      return {
        content: [
          {
            type: "text",
            text: "Error: At least title or authors must be provided",
          },
        ],
      };
    }

    await this.client.updateMetadata(documentId, { title, authors });

    const updates: string[] = [];
    if (title) updates.push(`title: "${title}"`);
    if (authors) updates.push(`authors: [${authors.join(", ")}]`);

    return {
      content: [
        {
          type: "text",
          text: `Metadata updated: ${updates.join(", ")}`,
        },
      ],
    };
  }

  private async exportLatex(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const template = args?.template as string | undefined;
    const latex = await this.client.exportLatex(documentId, template);

    return {
      content: [
        {
          type: "text",
          text: `# LaTeX Export\n\n\`\`\`latex\n${latex}\n\`\`\``,
        },
      ],
    };
  }

  private async exportText(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const text = await this.client.exportText(documentId);

    return {
      content: [
        {
          type: "text",
          text: `# Plain Text Export\n\n${text}`,
        },
      ],
    };
  }

  private async exportTypst(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = String(args?.documentId || "");
    if (!documentId) {
      return {
        content: [{ type: "text", text: "Error: documentId is required" }],
      };
    }

    const result = await this.client.exportTypst(documentId);
    if (!result) {
      return {
        content: [{ type: "text", text: `Document not found: ${documentId}` }],
      };
    }

    const bibInfo = Object.keys(result.bibliography).length > 0
      ? `\n\n**Bibliography entries:** ${Object.keys(result.bibliography).join(", ")}`
      : "";

    return {
      content: [
        {
          type: "text",
          text: `# Typst Export\n\n\`\`\`typst\n${result.source}\n\`\`\`${bibInfo}`,
        },
      ],
    };
  }

  private async getLogs(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.getLogs({
      limit: args?.limit as number | undefined,
      offset: args?.offset as number | undefined,
      level: args?.level as string | undefined,
      category: args?.category as string | undefined,
      search: args?.search as string | undefined,
      after: args?.after as string | undefined,
    });

    if (result.data.entries.length === 0) {
      return {
        content: [{ type: "text", text: "No log entries found." }],
      };
    }

    const logLines = result.data.entries
      .map((entry) => {
        const level = entry.level.toUpperCase().padEnd(7);
        return `[${entry.timestamp}] ${level} [${entry.category}] ${entry.message}`;
      })
      .join("\n");

    return {
      content: [
        {
          type: "text",
          text: `# imprint Logs (${result.data.count} of ${result.data.totalInStore} entries)\n\n\`\`\`\n${logLines}\n\`\`\``,
        },
      ],
    };
  }
}
