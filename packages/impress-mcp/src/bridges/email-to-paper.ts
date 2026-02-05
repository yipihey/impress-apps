/**
 * Email/Conversation to Paper Bridge: impart → imbib
 *
 * Extracts paper references from impart conversations and adds them to imbib.
 * Recognizes DOIs, arXiv IDs, PubMed IDs, and common paper URLs.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImbibClient } from "../imbib/client.js";
import { ImpartClient, ResearchMessage } from "../impart/client.js";

// ============================================================================
// Paper Identifier Patterns
// ============================================================================

/** Regular expressions for extracting paper identifiers from text. */
const IDENTIFIER_PATTERNS = {
  // DOI: 10.xxxx/xxxxx (various formats)
  doi: [
    /\b(10\.\d{4,}(?:\.\d+)*\/[^\s"<>]+)/gi,
    /doi\.org\/(10\.\d{4,}(?:\.\d+)*\/[^\s"<>]+)/gi,
    /doi:\s*(10\.\d{4,}(?:\.\d+)*\/[^\s"<>]+)/gi,
  ],

  // arXiv: 2301.12345, arXiv:2301.12345, or older format hep-th/9901001
  arxiv: [
    /\barXiv:(\d{4}\.\d{4,5}(?:v\d+)?)/gi,
    /\barXiv:([a-z-]+\/\d{7}(?:v\d+)?)/gi,
    /arxiv\.org\/abs\/(\d{4}\.\d{4,5}(?:v\d+)?)/gi,
    /arxiv\.org\/abs\/([a-z-]+\/\d{7}(?:v\d+)?)/gi,
    /arxiv\.org\/pdf\/(\d{4}\.\d{4,5}(?:v\d+)?)/gi,
    /\b(\d{4}\.\d{4,5})\b/g, // Bare arXiv ID (context-dependent)
  ],

  // PubMed ID: PMID: 12345678 or pubmed.gov/12345678
  pmid: [
    /\bPMID:\s*(\d{7,8})/gi,
    /pubmed\.(?:ncbi\.nlm\.nih\.)?gov\/(\d{7,8})/gi,
  ],

  // ADS bibcode: 2020ApJ...900..100A
  bibcode: [/\b(\d{4}[A-Za-z&.]{5,}\d{4}[A-Z])\b/g],

  // Semantic Scholar: S2 paper IDs are long hex strings
  s2: [/semanticscholar\.org\/paper\/[^\/]+\/([a-f0-9]{40})/gi],

  // OpenAlex: W followed by digits
  openalex: [/openalex\.org\/W(\d+)/gi, /\bW(\d{9,})\b/g],
};

/** URL patterns that likely contain papers. */
const PAPER_URL_PATTERNS = [
  /https?:\/\/(?:www\.)?nature\.com\/articles\/[^\s"<>]+/gi,
  /https?:\/\/(?:www\.)?science\.org\/doi\/[^\s"<>]+/gi,
  /https?:\/\/(?:www\.)?pnas\.org\/doi\/[^\s"<>]+/gi,
  /https?:\/\/(?:www\.)?cell\.com\/[^\s"<>]+\/fulltext\/[^\s"<>]+/gi,
  /https?:\/\/(?:www\.)?sciencedirect\.com\/science\/article\/[^\s"<>]+/gi,
  /https?:\/\/(?:www\.)?link\.springer\.com\/article\/[^\s"<>]+/gi,
  /https?:\/\/(?:www\.)?iopscience\.iop\.org\/article\/[^\s"<>]+/gi,
  /https?:\/\/(?:www\.)?journals\.aps\.org\/[^\s"<>]+/gi,
  /https?:\/\/(?:www\.)?academic\.oup\.com\/[^\s"<>]+\/article[^\s"<>]*/gi,
  /https?:\/\/(?:www\.)?biorxiv\.org\/content\/[^\s"<>]+/gi,
  /https?:\/\/(?:www\.)?medrxiv\.org\/content\/[^\s"<>]+/gi,
];

// ============================================================================
// Tool Definitions
// ============================================================================

export const EMAIL_TO_PAPER_TOOLS: Tool[] = [
  {
    name: "impress_extract_papers_from_conversation",
    description:
      "Scan an impart conversation for paper references (DOIs, arXiv IDs, URLs) and extract them. Returns found identifiers without adding to library yet. Use this to preview what papers can be extracted.",
    inputSchema: {
      type: "object",
      properties: {
        conversation_id: {
          type: "string",
          description: "The impart conversation ID to scan",
        },
        message_limit: {
          type: "number",
          description:
            "Maximum number of recent messages to scan (default: all messages)",
        },
      },
      required: ["conversation_id"],
    },
  },
  {
    name: "impress_add_papers_from_conversation",
    description:
      "Extract paper references from an impart conversation and add them to imbib. Recognizes DOIs, arXiv IDs, PubMed IDs, and paper URLs. Optionally downloads PDFs and adds to a collection.",
    inputSchema: {
      type: "object",
      properties: {
        conversation_id: {
          type: "string",
          description: "The impart conversation ID to extract papers from",
        },
        collection_id: {
          type: "string",
          description: "Optional: imbib collection ID to add papers to",
        },
        library_id: {
          type: "string",
          description: "Optional: imbib library ID to add papers to",
        },
        download_pdfs: {
          type: "boolean",
          description: "Whether to download PDFs for the papers (default: false)",
        },
        message_limit: {
          type: "number",
          description:
            "Maximum number of recent messages to scan (default: all messages)",
        },
        tag: {
          type: "string",
          description:
            "Optional: tag to apply to all added papers (e.g., 'from-conversation/project-name')",
        },
      },
      required: ["conversation_id"],
    },
  },
  {
    name: "impress_extract_papers_from_text",
    description:
      "Extract paper identifiers from arbitrary text. Useful for processing email bodies, notes, or any text containing paper references.",
    inputSchema: {
      type: "object",
      properties: {
        text: {
          type: "string",
          description: "The text to scan for paper references",
        },
        add_to_library: {
          type: "boolean",
          description:
            "Whether to add found papers to imbib (default: false, just returns identifiers)",
        },
        download_pdfs: {
          type: "boolean",
          description: "Whether to download PDFs if adding to library",
        },
      },
      required: ["text"],
    },
  },
];

// ============================================================================
// Extracted Paper Type
// ============================================================================

interface ExtractedPaper {
  identifier: string;
  type: "doi" | "arxiv" | "pmid" | "bibcode" | "s2" | "openalex" | "url";
  source: string; // Where it was found (message ID or "text")
  context?: string; // Surrounding text for context
}

// ============================================================================
// Bridge Handler
// ============================================================================

export class EmailToPaperBridge {
  constructor(
    private imbibClient: ImbibClient,
    private impartClient: ImpartClient
  ) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      case "impress_extract_papers_from_conversation":
        return this.extractFromConversation(args);
      case "impress_add_papers_from_conversation":
        return this.addFromConversation(args);
      case "impress_extract_papers_from_text":
        return this.extractFromText(args);
      default:
        return {
          content: [
            { type: "text", text: `Unknown email-to-paper tool: ${name}` },
          ],
        };
    }
  }

  // --------------------------------------------------------------------------
  // Extract Papers from Conversation (Preview)
  // --------------------------------------------------------------------------

  private async extractFromConversation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversation_id as string;
    const messageLimit = args?.message_limit as number | undefined;

    if (!conversationId) {
      return {
        content: [
          { type: "text", text: "Error: conversation_id is required" },
        ],
      };
    }

    try {
      // Get conversation with messages
      const conversation = await this.impartClient.getConversation(conversationId);
      const messages = messageLimit
        ? conversation.messages.slice(-messageLimit)
        : conversation.messages;

      // Extract papers from all messages
      const papers = this.extractPapersFromMessages(messages);

      if (papers.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: [
                `# No Papers Found`,
                "",
                `Scanned ${messages.length} messages in conversation "${conversation.conversation.title}"`,
                "",
                "No DOIs, arXiv IDs, PubMed IDs, or paper URLs were detected.",
              ].join("\n"),
            },
          ],
        };
      }

      // Group by type
      const grouped = this.groupByType(papers);

      return {
        content: [
          {
            type: "text",
            text: [
              `# Papers Found in Conversation`,
              "",
              `**Conversation:** ${conversation.conversation.title}`,
              `**Messages scanned:** ${messages.length}`,
              `**Papers found:** ${papers.length}`,
              "",
              ...Object.entries(grouped).map(([type, items]) => [
                `## ${this.typeDisplayName(type as ExtractedPaper["type"])} (${items.length})`,
                "",
                ...items.map((p) => `- \`${p.identifier}\``),
                "",
              ]).flat(),
              "",
              "Use `impress_add_papers_from_conversation` to add these to your imbib library.",
            ].join("\n"),
          },
        ],
      };
    } catch (e) {
      return {
        content: [
          { type: "text", text: `Error accessing conversation: ${e}` },
        ],
      };
    }
  }

  // --------------------------------------------------------------------------
  // Add Papers from Conversation
  // --------------------------------------------------------------------------

  private async addFromConversation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const conversationId = args?.conversation_id as string;
    const collectionId = args?.collection_id as string | undefined;
    const libraryId = args?.library_id as string | undefined;
    const downloadPdfs = (args?.download_pdfs as boolean) ?? false;
    const messageLimit = args?.message_limit as number | undefined;
    const tag = args?.tag as string | undefined;

    if (!conversationId) {
      return {
        content: [
          { type: "text", text: "Error: conversation_id is required" },
        ],
      };
    }

    try {
      // Get conversation with messages
      const conversation = await this.impartClient.getConversation(conversationId);
      const messages = messageLimit
        ? conversation.messages.slice(-messageLimit)
        : conversation.messages;

      // Extract papers from all messages
      const papers = this.extractPapersFromMessages(messages);

      if (papers.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: `No papers found in conversation "${conversation.conversation.title}"`,
            },
          ],
        };
      }

      // Deduplicate identifiers
      const uniqueIdentifiers = [...new Set(papers.map((p) => this.formatIdentifier(p)))];

      // Add to imbib
      const result = await this.imbibClient.addPapers(uniqueIdentifiers, {
        collection: collectionId,
        library: libraryId,
        downloadPDFs: downloadPdfs,
      });

      // Apply tag if specified
      if (tag && result.added.length > 0) {
        const addedCiteKeys = result.added.map((p) => p.citeKey);
        await this.imbibClient.addTag(addedCiteKeys, tag);
      }

      // Record in conversation that papers were extracted
      await this.impartClient.recordArtifact(
        conversationId,
        `impress://imbib/search?tag=${encodeURIComponent(tag || "from-conversation")}`,
        "paper-collection",
        `${result.added.length} papers added to imbib`
      );

      return {
        content: [
          {
            type: "text",
            text: [
              `# Papers Added to imbib`,
              "",
              `**From conversation:** ${conversation.conversation.title}`,
              `**Messages scanned:** ${messages.length}`,
              "",
              `## Results`,
              "",
              `- **Added:** ${result.added.length}`,
              `- **Duplicates (already in library):** ${result.duplicates.length}`,
              `- **Failed:** ${Object.keys(result.failed).length}`,
              "",
              result.added.length > 0
                ? [
                    "### Successfully Added",
                    "",
                    ...result.added.slice(0, 10).map(
                      (p) => `- **@${p.citeKey}**: ${p.title?.slice(0, 50)}...`
                    ),
                    result.added.length > 10
                      ? `- ... and ${result.added.length - 10} more`
                      : "",
                  ].join("\n")
                : "",
              "",
              Object.keys(result.failed).length > 0
                ? [
                    "### Failed to Add",
                    "",
                    ...Object.entries(result.failed)
                      .slice(0, 5)
                      .map(([id, err]) => `- ${id}: ${err}`),
                  ].join("\n")
                : "",
              "",
              tag ? `All papers tagged with: \`${tag}\`` : "",
              downloadPdfs ? "PDFs are being downloaded in the background." : "",
            ]
              .filter((line) => line !== "")
              .join("\n"),
          },
        ],
      };
    } catch (e) {
      return {
        content: [
          { type: "text", text: `Error adding papers: ${e}` },
        ],
      };
    }
  }

  // --------------------------------------------------------------------------
  // Extract Papers from Text
  // --------------------------------------------------------------------------

  private async extractFromText(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const text = args?.text as string;
    const addToLibrary = (args?.add_to_library as boolean) ?? false;
    const downloadPdfs = (args?.download_pdfs as boolean) ?? false;

    if (!text) {
      return {
        content: [{ type: "text", text: "Error: text is required" }],
      };
    }

    const papers = this.extractPapersFromText(text, "text");

    if (papers.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: "No paper identifiers found in the provided text.",
          },
        ],
      };
    }

    if (!addToLibrary) {
      // Just return the found identifiers
      const grouped = this.groupByType(papers);

      return {
        content: [
          {
            type: "text",
            text: [
              `# Papers Found`,
              "",
              `Found ${papers.length} paper identifier(s):`,
              "",
              ...Object.entries(grouped).map(([type, items]) => [
                `## ${this.typeDisplayName(type as ExtractedPaper["type"])}`,
                "",
                ...items.map((p) => `- \`${p.identifier}\``),
                "",
              ]).flat(),
              "",
              "Set `add_to_library: true` to add these to imbib.",
            ].join("\n"),
          },
        ],
      };
    }

    // Add to imbib
    try {
      const uniqueIdentifiers = [...new Set(papers.map((p) => this.formatIdentifier(p)))];

      const result = await this.imbibClient.addPapers(uniqueIdentifiers, {
        downloadPDFs: downloadPdfs,
      });

      return {
        content: [
          {
            type: "text",
            text: [
              `# Papers Added to imbib`,
              "",
              `- **Added:** ${result.added.length}`,
              `- **Duplicates:** ${result.duplicates.length}`,
              `- **Failed:** ${Object.keys(result.failed).length}`,
              "",
              result.added.length > 0
                ? result.added
                    .map((p) => `- @${p.citeKey}: ${p.title?.slice(0, 50)}...`)
                    .join("\n")
                : "",
            ]
              .filter((line) => line !== "")
              .join("\n"),
          },
        ],
      };
    } catch (e) {
      return {
        content: [{ type: "text", text: `Error adding papers: ${e}` }],
      };
    }
  }

  // --------------------------------------------------------------------------
  // Helper Methods
  // --------------------------------------------------------------------------

  private extractPapersFromMessages(messages: ResearchMessage[]): ExtractedPaper[] {
    const papers: ExtractedPaper[] = [];

    for (const message of messages) {
      const extracted = this.extractPapersFromText(message.contentMarkdown, message.id);
      papers.push(...extracted);
    }

    return this.deduplicatePapers(papers);
  }

  private extractPapersFromText(text: string, source: string): ExtractedPaper[] {
    const papers: ExtractedPaper[] = [];

    // Extract DOIs
    for (const pattern of IDENTIFIER_PATTERNS.doi) {
      for (const match of text.matchAll(pattern)) {
        const doi = match[1].replace(/[.,;:)\]]+$/, ""); // Clean trailing punctuation
        papers.push({
          identifier: doi,
          type: "doi",
          source,
        });
      }
    }

    // Extract arXiv IDs
    for (const pattern of IDENTIFIER_PATTERNS.arxiv) {
      for (const match of text.matchAll(pattern)) {
        papers.push({
          identifier: match[1],
          type: "arxiv",
          source,
        });
      }
    }

    // Extract PubMed IDs
    for (const pattern of IDENTIFIER_PATTERNS.pmid) {
      for (const match of text.matchAll(pattern)) {
        papers.push({
          identifier: match[1],
          type: "pmid",
          source,
        });
      }
    }

    // Extract bibcodes
    for (const pattern of IDENTIFIER_PATTERNS.bibcode) {
      for (const match of text.matchAll(pattern)) {
        papers.push({
          identifier: match[1],
          type: "bibcode",
          source,
        });
      }
    }

    // Extract Semantic Scholar IDs
    for (const pattern of IDENTIFIER_PATTERNS.s2) {
      for (const match of text.matchAll(pattern)) {
        papers.push({
          identifier: match[1],
          type: "s2",
          source,
        });
      }
    }

    // Extract OpenAlex IDs
    for (const pattern of IDENTIFIER_PATTERNS.openalex) {
      for (const match of text.matchAll(pattern)) {
        papers.push({
          identifier: `W${match[1]}`,
          type: "openalex",
          source,
        });
      }
    }

    // Extract paper URLs (these will be resolved by imbib)
    for (const pattern of PAPER_URL_PATTERNS) {
      for (const match of text.matchAll(pattern)) {
        papers.push({
          identifier: match[0],
          type: "url",
          source,
        });
      }
    }

    return papers;
  }

  private deduplicatePapers(papers: ExtractedPaper[]): ExtractedPaper[] {
    const seen = new Set<string>();
    return papers.filter((paper) => {
      const key = `${paper.type}:${paper.identifier.toLowerCase()}`;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  }

  private formatIdentifier(paper: ExtractedPaper): string {
    // Format the identifier for the imbib addPapers API
    switch (paper.type) {
      case "doi":
        return paper.identifier.startsWith("10.")
          ? paper.identifier
          : `10.${paper.identifier}`;
      case "arxiv":
        return `arXiv:${paper.identifier}`;
      case "pmid":
        return `PMID:${paper.identifier}`;
      case "bibcode":
        return paper.identifier;
      case "s2":
        return paper.identifier;
      case "openalex":
        return paper.identifier;
      case "url":
        return paper.identifier;
      default:
        return paper.identifier;
    }
  }

  private groupByType(
    papers: ExtractedPaper[]
  ): Record<string, ExtractedPaper[]> {
    return papers.reduce(
      (acc, paper) => {
        if (!acc[paper.type]) acc[paper.type] = [];
        acc[paper.type].push(paper);
        return acc;
      },
      {} as Record<string, ExtractedPaper[]>
    );
  }

  private typeDisplayName(type: ExtractedPaper["type"]): string {
    const names: Record<ExtractedPaper["type"], string> = {
      doi: "DOIs",
      arxiv: "arXiv IDs",
      pmid: "PubMed IDs",
      bibcode: "ADS Bibcodes",
      s2: "Semantic Scholar",
      openalex: "OpenAlex",
      url: "Paper URLs",
    };
    return names[type] || type;
  }
}
