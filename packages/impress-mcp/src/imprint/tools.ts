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
  {
    name: "imprint_list_manuscripts",
    description:
      "List every manuscript document known to imprint's shared store, sorted by most-recently-modified first. Includes every manuscript — not just the ones currently open in an editor window. Returns id, title, sectionCount, lastModified, and wordCount for each.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "imprint_get_manuscript_sections",
    description:
      "List every stored section of a manuscript, sorted by order_index. Returns section id, title, body (inline), sectionType, orderIndex, wordCount, and createdAt. Large content-addressed bodies are not rehydrated here — call imprint_get_section for those.",
    inputSchema: {
      type: "object",
      properties: {
        manuscriptId: {
          type: "string",
          description: "The UUID of the manuscript document",
        },
      },
      required: ["manuscriptId"],
    },
  },
  {
    name: "imprint_get_section",
    description:
      "Fetch a single manuscript section by its UUID. Body is rehydrated from content-addressed storage when needed. Use this after imprint_get_manuscript_sections to load the full body of a specific section.",
    inputSchema: {
      type: "object",
      properties: {
        sectionId: {
          type: "string",
          description: "The UUID of the section",
        },
      },
      required: ["sectionId"],
    },
  },
  {
    name: "imprint_cross_document_search",
    description:
      "Full-text search across every stored manuscript section. Multi-term queries use AND semantics — each term must appear in the same section. Returns ranked hits with title, excerpt, score, and the owning document id. Use for 'where did I write about X?' queries across the whole writing corpus.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "The search query (may contain multiple whitespace-separated terms)",
        },
        limit: {
          type: "number",
          description: "Maximum number of hits to return (default: 50)",
        },
      },
      required: ["query"],
    },
  },
  // MARK: - Section-scoped v2 tools (token-efficient)
  {
    name: "imprint_get_outline_v2",
    description:
      "Get a document's outline with stable section UUIDs, levels, byte ranges, and word counts. Agents should call this FIRST when working with a document so they can then fetch individual sections by ID instead of shuttling the entire source. Much more token-efficient than imprint_get_content.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: { type: "string", description: "Document UUID" },
      },
      required: ["documentId"],
    },
  },
  {
    name: "imprint_get_section_body",
    description:
      "Fetch a single section's body from an open document (just that section, not the whole document). sectionKey may be a stable UUID from imprint_get_outline_v2 OR a zero-based integer index. Returns the body text plus the section's metadata and byte range within the source. This is the token-efficient way to read a section; for stored-manuscript sections (not necessarily open in the editor) use imprint_get_section.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: { type: "string", description: "Document UUID" },
        sectionKey: { type: "string", description: "Section UUID (from outline v2) or integer index" },
      },
      required: ["documentId", "sectionKey"],
    },
  },
  {
    name: "imprint_patch_section",
    description:
      "Replace a section's body and/or rename its heading. Queues an operation; poll imprint_get_operation with the returned operationId (or use imprint_wait_for_operation) to confirm it was applied.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: { type: "string", description: "Document UUID" },
        sectionKey: { type: "string", description: "Section UUID or integer index" },
        body: { type: "string", description: "New section body (heading is preserved)" },
        title: { type: "string", description: "New heading text (level is preserved)" },
      },
      required: ["documentId", "sectionKey"],
    },
  },
  {
    name: "imprint_delete_section",
    description:
      "Remove a section (heading + body) from the document. Queues an operation; returns operationId.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: { type: "string", description: "Document UUID" },
        sectionKey: { type: "string", description: "Section UUID or integer index" },
      },
      required: ["documentId", "sectionKey"],
    },
  },
  {
    name: "imprint_create_section",
    description:
      "Create a new section in a document. 'position' controls placement: 'end' (default), 'before:{sectionKey}', or 'after:{sectionKey}'. Level defaults to 1 (top-level heading).",
    inputSchema: {
      type: "object",
      properties: {
        documentId: { type: "string", description: "Document UUID" },
        title: { type: "string", description: "Heading text for the new section" },
        body: { type: "string", description: "Section body content (optional)" },
        level: { type: "number", description: "Heading level 1–6 (default 1)" },
        position: { type: "string", description: "'end', 'before:{key}', or 'after:{key}'" },
      },
      required: ["documentId", "title"],
    },
  },
  {
    name: "imprint_insert_citation_in_section",
    description:
      "Atomically (a) add a BibTeX entry to the document bibliography and (b) insert `@citeKey` inside a specific section. The most agent-friendly way to cite a paper without hunting for byte offsets. Pair with imbib_resolve_identifier to fetch the paper first.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: { type: "string", description: "Document UUID" },
        sectionKey: { type: "string", description: "Section UUID or integer index" },
        citeKey: { type: "string", description: "Cite key (e.g., 'vaswani2017attention')" },
        bibtex: { type: "string", description: "BibTeX entry for the bibliography (optional if already added)" },
        position: { type: "number", description: "Character offset WITHIN the section body (0 = right after heading). Omit to append." },
      },
      required: ["documentId", "sectionKey", "citeKey"],
    },
  },
  {
    name: "imprint_get_operation",
    description:
      "Look up the status of an edit operation that was queued via the HTTP API. Returns state (pending / completed / failed) and timing. Use this to confirm a mutation was actually applied before reading the document back.",
    inputSchema: {
      type: "object",
      properties: {
        operationId: { type: "string", description: "Operation UUID returned by a mutation tool" },
      },
      required: ["operationId"],
    },
  },
  {
    name: "imprint_wait_for_operation",
    description:
      "Poll an operation until it completes (or times out). Preferred over imprint_get_operation when you want a synchronous 'did it actually apply?' confirmation.",
    inputSchema: {
      type: "object",
      properties: {
        operationId: { type: "string", description: "Operation UUID" },
        timeoutMs: { type: "number", description: "Max wait time in ms (default 5000)" },
      },
      required: ["operationId"],
    },
  },
  // MARK: - Comments / suggestions
  {
    name: "imprint_list_comments",
    description:
      "List comments on a document. Filter with 'unresolved', 'resolved', 'suggestions', or 'all' (default). Pass authorAgentId to see only your own comments.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: { type: "string" },
        filter: { type: "string", description: "'all' | 'unresolved' | 'resolved' | 'suggestions'" },
        authorAgentId: { type: "string", description: "If set, return only comments from this agent" },
      },
      required: ["documentId"],
    },
  },
  {
    name: "imprint_create_comment",
    description:
      "Leave a comment on a document. To propose a text edit (rather than just a note), pass 'proposedText' — the human reviewer can then Accept to apply it. Agents should ALWAYS set 'authorAgentId' so their suggestions are badged distinctly in imprint's CommentsSidebarView.",
    inputSchema: {
      type: "object",
      properties: {
        documentId: { type: "string" },
        content: { type: "string", description: "Comment text (shown in the sidebar)" },
        start: { type: "number", description: "Character offset where the comment range begins" },
        end: { type: "number", description: "Character offset where the comment range ends" },
        proposedText: { type: "string", description: "If set, turns this into a suggestion. User can Accept to apply it." },
        authorAgentId: { type: "string", description: "Stable agent identifier (e.g., 'claude-desktop:opus-4.7')" },
        authorName: { type: "string", description: "Display name for the comment author" },
        parentId: { type: "string", description: "For replies: parent comment UUID" },
      },
      required: ["documentId", "content", "start", "end"],
    },
  },
  {
    name: "imprint_update_comment",
    description: "Edit a comment's content, change its proposed text, or resolve/unresolve it.",
    inputSchema: {
      type: "object",
      properties: {
        commentId: { type: "string" },
        content: { type: "string" },
        proposedText: { type: "string" },
        isResolved: { type: "boolean" },
      },
      required: ["commentId"],
    },
  },
  {
    name: "imprint_delete_comment",
    description: "Delete a comment (and any replies).",
    inputSchema: {
      type: "object",
      properties: { commentId: { type: "string" } },
      required: ["commentId"],
    },
  },
  {
    name: "imprint_accept_suggestion",
    description:
      "Apply a suggestion comment's proposedText to the document and resolve the comment. Errors if the comment isn't a suggestion.",
    inputSchema: {
      type: "object",
      properties: { commentId: { type: "string" } },
      required: ["commentId"],
    },
  },
  {
    name: "imprint_reject_suggestion",
    description: "Resolve a suggestion without applying its proposedText.",
    inputSchema: {
      type: "object",
      properties: { commentId: { type: "string" } },
      required: ["commentId"],
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
      case "imprint_list_manuscripts":
        return this.listManuscripts();
      case "imprint_get_manuscript_sections":
        return this.getManuscriptSections(args);
      case "imprint_get_section":
        return this.getSection(args);
      case "imprint_cross_document_search":
        return this.crossDocumentSearch(args);
      case "imprint_get_outline_v2":
        return this.getOutlineV2(args);
      case "imprint_get_section_body":
        return this.getSectionBody(args);
      case "imprint_patch_section":
        return this.patchSection(args);
      case "imprint_delete_section":
        return this.deleteSection(args);
      case "imprint_create_section":
        return this.createSection(args);
      case "imprint_insert_citation_in_section":
        return this.insertCitationInSection(args);
      case "imprint_get_operation":
        return this.getOperation(args);
      case "imprint_wait_for_operation":
        return this.waitForOperation(args);
      case "imprint_list_comments":
        return this.listComments(args);
      case "imprint_create_comment":
        return this.createComment(args);
      case "imprint_update_comment":
        return this.updateComment(args);
      case "imprint_delete_comment":
        return this.deleteComment(args);
      case "imprint_accept_suggestion":
        return this.acceptSuggestion(args);
      case "imprint_reject_suggestion":
        return this.rejectSuggestion(args);
      default:
        return {
          content: [{ type: "text", text: `Unknown imprint tool: ${name}` }],
        };
    }
  }

  // MARK: - v2 handlers

  private async getOutlineV2(args: Record<string, unknown> | undefined) {
    const documentId = String(args?.documentId || "");
    if (!documentId) return errText("documentId is required");
    const r = await this.client.getOutlineV2(documentId);
    if (r.count === 0) {
      return textContent(`No sections detected in document ${documentId} (outline is empty).`);
    }
    const lines = r.sections.map((s) => {
      const type = s.sectionType ? ` [${s.sectionType}]` : "";
      return `- ${"#".repeat(s.level)} ${s.title}${type} · ${s.wordCount}w · range ${s.start}–${s.end}\n  id: ${s.id} · index: ${s.orderIndex}`;
    });
    return textContent(`# Outline for ${documentId} (${r.count} sections)\n\n${lines.join("\n")}`);
  }

  private async getSectionBody(args: Record<string, unknown> | undefined) {
    const documentId = String(args?.documentId || "");
    const sectionKey = String(args?.sectionKey || "");
    if (!documentId || !sectionKey) return errText("documentId and sectionKey are required");
    const r = await this.client.getSectionInDocument(documentId, sectionKey);
    return textContent(
      `# ${r.title}\n\nid: ${r.id}\nlevel: ${r.level} · type: ${r.sectionType || "-"} · index: ${r.orderIndex} · words: ${r.wordCount}\nrange: ${r.start}-${r.end} · bodyStart: ${r.bodyStart}\n\n${r.body}`
    );
  }

  private async patchSection(args: Record<string, unknown> | undefined) {
    const documentId = String(args?.documentId || "");
    const sectionKey = String(args?.sectionKey || "");
    const body = args?.body as string | undefined;
    const title = args?.title as string | undefined;
    if (!documentId || !sectionKey) return errText("documentId and sectionKey are required");
    if (body === undefined && title === undefined) return errText("provide at least one of 'body' or 'title'");
    const r = await this.client.patchSection(documentId, sectionKey, { body, title });
    return textContent(JSON.stringify(r, null, 2));
  }

  private async deleteSection(args: Record<string, unknown> | undefined) {
    const documentId = String(args?.documentId || "");
    const sectionKey = String(args?.sectionKey || "");
    if (!documentId || !sectionKey) return errText("documentId and sectionKey are required");
    const r = await this.client.deleteSection(documentId, sectionKey);
    return textContent(JSON.stringify(r, null, 2));
  }

  private async createSection(args: Record<string, unknown> | undefined) {
    const documentId = String(args?.documentId || "");
    const title = String(args?.title || "");
    if (!documentId || !title) return errText("documentId and title are required");
    const r = await this.client.createSection(documentId, {
      title,
      body: args?.body as string | undefined,
      level: args?.level as number | undefined,
      position: args?.position as string | undefined,
    });
    return textContent(JSON.stringify(r, null, 2));
  }

  private async insertCitationInSection(args: Record<string, unknown> | undefined) {
    const documentId = String(args?.documentId || "");
    const sectionKey = String(args?.sectionKey || "");
    const citeKey = String(args?.citeKey || "");
    if (!documentId || !sectionKey || !citeKey) {
      return errText("documentId, sectionKey, and citeKey are required");
    }
    const r = await this.client.insertCitationInSection(documentId, sectionKey, {
      citeKey,
      bibtex: args?.bibtex as string | undefined,
      position: args?.position as number | undefined,
    });
    return textContent(JSON.stringify(r, null, 2));
  }

  private async getOperation(args: Record<string, unknown> | undefined) {
    const operationId = String(args?.operationId || "");
    if (!operationId) return errText("operationId is required");
    const r = await this.client.getOperation(operationId);
    return textContent(JSON.stringify(r, null, 2));
  }

  private async waitForOperation(args: Record<string, unknown> | undefined) {
    const operationId = String(args?.operationId || "");
    if (!operationId) return errText("operationId is required");
    const timeoutMs = (args?.timeoutMs as number | undefined) ?? 5000;
    const r = await this.client.waitForOperation(operationId, timeoutMs);
    return textContent(JSON.stringify(r, null, 2));
  }

  // MARK: - Comment handlers

  private async listComments(args: Record<string, unknown> | undefined) {
    const documentId = String(args?.documentId || "");
    if (!documentId) return errText("documentId is required");
    const r = await this.client.listComments(documentId, {
      filter: args?.filter as string | undefined,
      authorAgentId: args?.authorAgentId as string | undefined,
    });
    if (r.count === 0) {
      return textContent(`No comments on document ${documentId}.`);
    }
    const lines = r.comments.map((c) => {
      const flags: string[] = [];
      if (c.isSuggestion) flags.push("SUGGESTION");
      if (c.isResolved) flags.push("resolved");
      if (c.authorAgentId) flags.push(`agent:${c.authorAgentId}`);
      const flagStr = flags.length ? ` [${flags.join(", ")}]` : "";
      const proposal = c.proposedText ? `\n  proposed: ${c.proposedText.slice(0, 120)}${c.proposedText.length > 120 ? "…" : ""}` : "";
      return `- ${c.author}${flagStr} @ ${c.range.start}-${c.range.end}\n  ${c.content}${proposal}\n  id: ${c.id}`;
    });
    return textContent(`# Comments on ${documentId} (${r.count})\n\n${lines.join("\n\n")}`);
  }

  private async createComment(args: Record<string, unknown> | undefined) {
    const documentId = String(args?.documentId || "");
    const content = String(args?.content || "");
    const start = args?.start as number | undefined;
    const end = args?.end as number | undefined;
    if (!documentId || !content || start === undefined || end === undefined) {
      return errText("documentId, content, start, and end are required");
    }
    const r = await this.client.createComment(documentId, {
      content,
      start,
      end,
      parentId: args?.parentId as string | undefined,
      proposedText: args?.proposedText as string | undefined,
      authorAgentId: args?.authorAgentId as string | undefined,
      authorName: args?.authorName as string | undefined,
    });
    return textContent(JSON.stringify(r, null, 2));
  }

  private async updateComment(args: Record<string, unknown> | undefined) {
    const commentId = String(args?.commentId || "");
    if (!commentId) return errText("commentId is required");
    const r = await this.client.patchComment(commentId, {
      content: args?.content as string | undefined,
      proposedText: args?.proposedText as string | undefined,
      isResolved: args?.isResolved as boolean | undefined,
    });
    return textContent(JSON.stringify(r, null, 2));
  }

  private async deleteComment(args: Record<string, unknown> | undefined) {
    const commentId = String(args?.commentId || "");
    if (!commentId) return errText("commentId is required");
    const r = await this.client.deleteComment(commentId);
    return textContent(JSON.stringify(r, null, 2));
  }

  private async acceptSuggestion(args: Record<string, unknown> | undefined) {
    const commentId = String(args?.commentId || "");
    if (!commentId) return errText("commentId is required");
    const r = await this.client.acceptComment(commentId);
    return textContent(JSON.stringify(r, null, 2));
  }

  private async rejectSuggestion(args: Record<string, unknown> | undefined) {
    const commentId = String(args?.commentId || "");
    if (!commentId) return errText("commentId is required");
    const r = await this.client.rejectComment(commentId);
    return textContent(JSON.stringify(r, null, 2));
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

  // MARK: - Store-backed manuscript/section handlers

  private async listManuscripts(): Promise<{
    content: Array<{ type: string; text: string }>;
  }> {
    const result = await this.client.listManuscripts();
    if (result.manuscripts.length === 0) {
      return {
        content: [{ type: "text", text: "No manuscripts found in the store." }],
      };
    }
    const lines = result.manuscripts
      .map((m) => {
        const sections = m.sectionCount === 1 ? "section" : "sections";
        return `- **${m.title}** (${m.id})\n  ${m.sectionCount} ${sections} · ${m.totalWordCount} words · last modified ${m.lastModified}`;
      })
      .join("\n");
    return {
      content: [
        {
          type: "text",
          text: `# Manuscripts (${result.count})\n\n${lines}`,
        },
      ],
    };
  }

  private async getManuscriptSections(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const manuscriptId = String(args?.manuscriptId || "");
    if (!manuscriptId) {
      return {
        content: [{ type: "text", text: "Error: manuscriptId is required" }],
      };
    }
    const result = await this.client.listManuscriptSections(manuscriptId);
    if (!result) {
      return {
        content: [{ type: "text", text: `Manuscript not found: ${manuscriptId}` }],
      };
    }
    if (result.sections.length === 0) {
      return {
        content: [
          { type: "text", text: `Manuscript ${manuscriptId} has no stored sections.` },
        ],
      };
    }
    const lines = result.sections
      .map((s) => {
        const type = s.sectionType ? ` [${s.sectionType}]` : "";
        const preview = s.body.length > 120 ? s.body.slice(0, 120) + "…" : s.body;
        return `## ${s.orderIndex}. ${s.title}${type}\n${s.wordCount} words · id: ${s.id}\n\n${preview}`;
      })
      .join("\n\n");
    return {
      content: [
        {
          type: "text",
          text: `# Sections for ${manuscriptId} (${result.count})\n\n${lines}`,
        },
      ],
    };
  }

  private async getSection(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const sectionId = String(args?.sectionId || "");
    if (!sectionId) {
      return {
        content: [{ type: "text", text: "Error: sectionId is required" }],
      };
    }
    const section = await this.client.getSection(sectionId);
    if (!section) {
      return {
        content: [{ type: "text", text: `Section not found: ${sectionId}` }],
      };
    }
    const type = section.sectionType ? ` [${section.sectionType}]` : "";
    return {
      content: [
        {
          type: "text",
          text: `# ${section.title}${type}\n\n**Document:** ${section.documentID}\n**Order:** ${section.orderIndex}\n**Word count:** ${section.wordCount}\n\n---\n\n${section.body}`,
        },
      ],
    };
  }

  private async crossDocumentSearch(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const query = String(args?.query || "").trim();
    if (!query) {
      return {
        content: [{ type: "text", text: "Error: query is required" }],
      };
    }
    const limit = (args?.limit as number | undefined) ?? 50;
    const result = await this.client.crossDocumentSearch(query, limit);
    if (result.results.length === 0) {
      return {
        content: [{ type: "text", text: `No matches for '${query}'.` }],
      };
    }
    const lines = result.results
      .map((hit) => {
        const type = hit.sectionType ? ` [${hit.sectionType}]` : "";
        return `- **${hit.title}**${type} (score ${hit.score.toFixed(1)})\n  section: ${hit.sectionID} · doc: ${hit.documentID}\n  ${hit.excerpt}`;
      })
      .join("\n\n");
    return {
      content: [
        {
          type: "text",
          text: `# Cross-Document Search: "${query}" (${result.count} hits)\n\n${lines}`,
        },
      ],
    };
  }
}

// MARK: - Small helpers for the v2 tool handlers.

function textContent(text: string): { content: Array<{ type: string; text: string }> } {
  return { content: [{ type: "text", text }] };
}

function errText(msg: string): { content: Array<{ type: string; text: string }> } {
  return { content: [{ type: "text", text: `Error: ${msg}` }] };
}
