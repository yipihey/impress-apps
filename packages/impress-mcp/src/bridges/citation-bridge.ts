/**
 * Citation Bridge: imbib → imprint
 *
 * Enables citing papers from imbib in imprint documents.
 * This bridge fetches BibTeX from imbib and inserts citations into imprint.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImbibClient } from "../imbib/client.js";
import { ImprintClient } from "../imprint/client.js";

// ============================================================================
// Tool Definitions
// ============================================================================

export const CITATION_BRIDGE_TOOLS: Tool[] = [
  {
    name: "impress_cite_paper",
    description:
      "Cite a paper from imbib in an imprint document. Fetches BibTeX from imbib, adds it to the document's bibliography, and inserts a @cite reference at the specified position. This is the primary way to add citations from your library to manuscripts.",
    inputSchema: {
      type: "object",
      properties: {
        document_id: {
          type: "string",
          description: "The imprint document ID to add the citation to",
        },
        cite_key: {
          type: "string",
          description:
            "The citation key from imbib (e.g., 'Vaswani2017', 'Einstein1905')",
        },
        position: {
          type: "number",
          description:
            "Optional: character position in the document to insert the citation. If not provided, citation is added to bibliography only.",
        },
        context: {
          type: "string",
          description:
            "Optional: search for this text in the document and insert citation after it",
        },
      },
      required: ["document_id", "cite_key"],
    },
  },
  {
    name: "impress_cite_multiple",
    description:
      "Cite multiple papers from imbib in an imprint document at once. Useful for adding a batch of related citations.",
    inputSchema: {
      type: "object",
      properties: {
        document_id: {
          type: "string",
          description: "The imprint document ID to add citations to",
        },
        cite_keys: {
          type: "array",
          items: { type: "string" },
          description: "Array of citation keys from imbib to add",
        },
      },
      required: ["document_id", "cite_keys"],
    },
  },
  {
    name: "impress_get_citation_suggestions",
    description:
      "Search imbib for papers matching a query and suggest citations. Useful when you know the topic but not the exact paper.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Search query (title, author, keywords, etc.)",
        },
        limit: {
          type: "number",
          description: "Maximum number of suggestions (default: 5)",
        },
      },
      required: ["query"],
    },
  },
];

// ============================================================================
// Bridge Handler
// ============================================================================

export class CitationBridge {
  constructor(
    private imbibClient: ImbibClient,
    private imprintClient: ImprintClient
  ) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      case "impress_cite_paper":
        return this.citePaper(args);
      case "impress_cite_multiple":
        return this.citeMultiple(args);
      case "impress_get_citation_suggestions":
        return this.getCitationSuggestions(args);
      default:
        return {
          content: [
            { type: "text", text: `Unknown citation bridge tool: ${name}` },
          ],
        };
    }
  }

  // --------------------------------------------------------------------------
  // Cite Paper
  // --------------------------------------------------------------------------

  private async citePaper(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = args?.document_id as string;
    const citeKey = args?.cite_key as string;
    const position = args?.position as number | undefined;
    const context = args?.context as string | undefined;

    if (!documentId || !citeKey) {
      return {
        content: [
          {
            type: "text",
            text: "Error: document_id and cite_key are required",
          },
        ],
      };
    }

    // Step 1: Verify imbib is running and get the paper
    const paper = await this.imbibClient.getPaper(citeKey);
    if (!paper) {
      return {
        content: [
          {
            type: "text",
            text: `Error: Paper not found in imbib: ${citeKey}\n\nTip: Use impress_get_citation_suggestions to search for the paper.`,
          },
        ],
      };
    }

    // Step 2: Get BibTeX for the paper
    const bibtexResult = await this.imbibClient.exportBibTeX([citeKey]);
    if (!bibtexResult || !bibtexResult.content) {
      return {
        content: [
          {
            type: "text",
            text: `Error: Could not export BibTeX for paper: ${citeKey}`,
          },
        ],
      };
    }

    // Step 3: Add citation to imprint document
    try {
      await this.imprintClient.insertCitation(documentId, citeKey, {
        bibtex: bibtexResult.content,
        position,
      });
    } catch (e) {
      return {
        content: [
          {
            type: "text",
            text: `Error adding citation to document: ${e}`,
          },
        ],
      };
    }

    const authors = paper.authors?.slice(0, 3).join(", ") || "Unknown authors";
    const year = paper.year || "n.d.";

    return {
      content: [
        {
          type: "text",
          text: [
            `# Citation Added`,
            "",
            `**Paper:** ${paper.title}`,
            `**Authors:** ${authors}${paper.authors && paper.authors.length > 3 ? " et al." : ""}`,
            `**Year:** ${year}`,
            `**Cite Key:** @${citeKey}`,
            "",
            `Added to document ${documentId}`,
            position !== undefined ? `Inserted at position ${position}` : "Added to bibliography",
          ].join("\n"),
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Cite Multiple
  // --------------------------------------------------------------------------

  private async citeMultiple(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = args?.document_id as string;
    const citeKeys = args?.cite_keys as string[];

    if (!documentId || !citeKeys || citeKeys.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: "Error: document_id and cite_keys (non-empty array) are required",
          },
        ],
      };
    }

    const results: string[] = [];
    const failed: string[] = [];

    for (const citeKey of citeKeys) {
      try {
        // Verify paper exists
        const paper = await this.imbibClient.getPaper(citeKey);
        if (!paper) {
          failed.push(`${citeKey}: not found in imbib`);
          continue;
        }

        // Add citation
        await this.imprintClient.insertCitation(documentId, citeKey, {});
        results.push(`@${citeKey}: ${paper.title?.slice(0, 50)}...`);
      } catch (e) {
        failed.push(`${citeKey}: ${e}`);
      }
    }

    return {
      content: [
        {
          type: "text",
          text: [
            `# Multiple Citations Added`,
            "",
            `**Document:** ${documentId}`,
            "",
            results.length > 0 ? "## Successfully Added" : null,
            ...results.map((r) => `- ${r}`),
            "",
            failed.length > 0 ? "## Failed" : null,
            ...(failed.length > 0 ? failed.map((f) => `- ${f}`) : []),
            "",
            `**Summary:** ${results.length} added, ${failed.length} failed`,
          ]
            .filter((line) => line !== null)
            .join("\n"),
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Get Citation Suggestions
  // --------------------------------------------------------------------------

  private async getCitationSuggestions(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const query = args?.query as string;
    const limit = (args?.limit as number) || 5;

    if (!query) {
      return {
        content: [{ type: "text", text: "Error: query is required" }],
      };
    }

    const searchResult = await this.imbibClient.searchLibrary(query, { limit });

    if (!searchResult || searchResult.papers.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: `No papers found for query: "${query}"\n\nTry broadening your search or checking if the paper is in your library.`,
          },
        ],
      };
    }

    const suggestions = searchResult.papers.slice(0, limit).map((paper) => {
      const authors =
        paper.authors?.slice(0, 2).join(", ") +
        (paper.authors && paper.authors.length > 2 ? " et al." : "");
      return `- **@${paper.citeKey}**: ${paper.title?.slice(0, 60)}${paper.title && paper.title.length > 60 ? "..." : ""}\n  ${authors} (${paper.year || "n.d."})`;
    });

    return {
      content: [
        {
          type: "text",
          text: [
            `# Citation Suggestions for "${query}"`,
            "",
            `Found ${searchResult.papers.length} papers. Top ${Math.min(limit, searchResult.papers.length)}:`,
            "",
            ...suggestions,
            "",
            "Use `impress_cite_paper` with any cite_key above to add to your document.",
          ].join("\n"),
        },
      ],
    };
  }
}
