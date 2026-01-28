/**
 * MCP tool definitions for imbib
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImbibClient } from "./client.js";

export const IMBIB_TOOLS: Tool[] = [
  {
    name: "imbib_search_library",
    description:
      "Search the imbib library for papers by title, author, abstract, or keywords. Returns matching papers with metadata and BibTeX.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description:
            "Search query (title, author name, keywords, or full-text)",
        },
        limit: {
          type: "number",
          description: "Maximum number of results to return (default: 20)",
        },
        offset: {
          type: "number",
          description: "Number of results to skip for pagination (default: 0)",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "imbib_get_paper",
    description:
      "Get detailed information about a specific paper by its cite key. Returns full metadata and BibTeX entry.",
    inputSchema: {
      type: "object",
      properties: {
        citeKey: {
          type: "string",
          description:
            "The cite key of the paper (e.g., 'Einstein1905', 'Vaswani2017Attention')",
        },
      },
      required: ["citeKey"],
    },
  },
  {
    name: "imbib_export_bibtex",
    description:
      "Export BibTeX entries for one or more papers. Useful for creating bibliography files or inserting citations.",
    inputSchema: {
      type: "object",
      properties: {
        citeKeys: {
          type: "array",
          items: { type: "string" },
          description: "List of cite keys to export",
        },
      },
      required: ["citeKeys"],
    },
  },
  {
    name: "imbib_list_collections",
    description:
      "List all collections in the imbib library. Collections organize papers into groups.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "imbib_status",
    description:
      "Check if imbib is running and get library statistics. Returns paper count, collection count, and server status.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
];

export class ImbibTools {
  constructor(private client: ImbibClient) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      case "imbib_search_library":
        return this.searchLibrary(args);
      case "imbib_get_paper":
        return this.getPaper(args);
      case "imbib_export_bibtex":
        return this.exportBibTeX(args);
      case "imbib_list_collections":
        return this.listCollections();
      case "imbib_status":
        return this.getStatus();
      default:
        return {
          content: [{ type: "text", text: `Unknown imbib tool: ${name}` }],
        };
    }
  }

  private async searchLibrary(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const query = String(args?.query || "");
    const limit = args?.limit as number | undefined;
    const offset = args?.offset as number | undefined;

    const result = await this.client.searchLibrary(query, {
      limit: limit ?? 20,
      offset,
    });

    if (result.papers.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: `No papers found matching "${query}"`,
          },
        ],
      };
    }

    const paperList = result.papers
      .map((p) => {
        const authors =
          p.authors.length > 3
            ? `${p.authors.slice(0, 3).join(", ")} et al.`
            : p.authors.join(", ");
        const year = p.year ? ` (${p.year})` : "";
        const venue = p.venue ? ` - ${p.venue}` : "";
        const pdf = p.hasPDF ? " [PDF]" : "";
        const starred = p.isStarred ? " *" : "";
        return `- **${p.citeKey}**: ${p.title}${year}\n  ${authors}${venue}${pdf}${starred}`;
      })
      .join("\n\n");

    return {
      content: [
        {
          type: "text",
          text: `Found ${result.count} papers matching "${query}":\n\n${paperList}`,
        },
      ],
    };
  }

  private async getPaper(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKey = String(args?.citeKey || "");
    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }

    const paper = await this.client.getPaper(citeKey);
    if (!paper) {
      return {
        content: [{ type: "text", text: `Paper not found: ${citeKey}` }],
      };
    }

    const info = [
      `# ${paper.title}`,
      "",
      `**Cite Key:** ${paper.citeKey}`,
      `**Authors:** ${paper.authors.join(", ")}`,
      paper.year ? `**Year:** ${paper.year}` : null,
      paper.venue ? `**Venue:** ${paper.venue}` : null,
      paper.doi ? `**DOI:** ${paper.doi}` : null,
      paper.arxivID ? `**arXiv:** ${paper.arxivID}` : null,
      paper.citationCount
        ? `**Citations:** ${paper.citationCount}`
        : null,
      "",
      paper.abstract ? `## Abstract\n\n${paper.abstract}` : null,
      "",
      "## BibTeX",
      "```bibtex",
      paper.bibtex,
      "```",
    ]
      .filter(Boolean)
      .join("\n");

    return {
      content: [{ type: "text", text: info }],
    };
  }

  private async exportBibTeX(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKeys = args?.citeKeys as string[] | undefined;
    if (!citeKeys || citeKeys.length === 0) {
      return {
        content: [
          { type: "text", text: "Error: At least one citeKey is required" },
        ],
      };
    }

    const result = await this.client.exportBibTeX(citeKeys);

    return {
      content: [
        {
          type: "text",
          text: `# BibTeX Export (${result.paperCount} papers)\n\n\`\`\`bibtex\n${result.content}\n\`\`\``,
        },
      ],
    };
  }

  private async listCollections(): Promise<{
    content: Array<{ type: string; text: string }>;
  }> {
    const collections = await this.client.listCollections();

    if (collections.length === 0) {
      return {
        content: [{ type: "text", text: "No collections found in library" }],
      };
    }

    const list = collections
      .map((c) => {
        const smart = c.isSmartCollection ? " (Smart)" : "";
        return `- **${c.name}**${smart}: ${c.paperCount} papers`;
      })
      .join("\n");

    return {
      content: [
        {
          type: "text",
          text: `# Collections (${collections.length})\n\n${list}`,
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
            text: "imbib is not running or HTTP API is disabled.\n\nTo enable:\n1. Open imbib\n2. Go to Settings > Automation\n3. Enable HTTP Server",
          },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: [
            "# imbib Status",
            "",
            `**Status:** ${status.status}`,
            `**Version:** ${status.version}`,
            `**Papers:** ${status.libraryCount}`,
            `**Collections:** ${status.collectionCount}`,
            `**Port:** ${status.serverPort}`,
          ].join("\n"),
        },
      ],
    };
  }
}
