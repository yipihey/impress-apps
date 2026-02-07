/**
 * MCP tool definitions for imbib
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import {
  ImbibClient,
  type Paper,
  type Participant,
  type Activity,
  type Comment,
  type Assignment,
  type Annotation,
} from "./client.js";

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
    name: "imbib_search_sources",
    description:
      "Search external academic sources (ADS, arXiv, Crossref, PubMed, etc.) for papers by topic, keywords, or author. Returns papers NOT yet in the library, with identifiers that can be passed to imbib_add_papers. Use this to discover new papers on a topic.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description:
            "Search query (topic, keywords, author name). For ADS, supports field qualifiers like 'author:Einstein year:2024'.",
        },
        source: {
          type: "string",
          description:
            "Optional: specific source to search (ads, arxiv, crossref, pubmed, semanticscholar, openalex, dblp). If omitted, searches all available sources.",
          enum: [
            "ads",
            "arxiv",
            "crossref",
            "pubmed",
            "semanticscholar",
            "openalex",
            "dblp",
          ],
        },
        limit: {
          type: "number",
          description: "Maximum number of results to return (default: 20)",
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
  {
    name: "imbib_get_logs",
    description:
      "Get log entries from imbib's in-app console. Useful for debugging and observing app behavior. Logs include PDF imports, sync events, search operations, and more.",
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
            'Filter by category substring (e.g. "tags", "sync", "pdfbrowser")',
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
  // --------------------------------------------------------------------------
  // Write Operations
  // --------------------------------------------------------------------------
  {
    name: "imbib_add_papers",
    description:
      "Add papers to the imbib library by identifier. Supports DOI, arXiv ID, bibcode, or other identifiers. Automatically fetches metadata from external sources. If papers already exist, they are still added to the target library/collection.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description:
            "List of paper identifiers (DOI, arXiv ID, bibcode, cite key)",
        },
        library: {
          type: "string",
          description: "Library UUID to add papers to (optional)",
        },
        collection: {
          type: "string",
          description: "Collection UUID to add papers to (optional)",
        },
        downloadPDFs: {
          type: "boolean",
          description: "Whether to download PDFs immediately (default: false)",
        },
      },
      required: ["identifiers"],
    },
  },
  {
    name: "imbib_add_to_library",
    description:
      "Add existing papers to a specific library. Use this to organize papers that are already in imbib into a different library.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description:
            "List of paper identifiers (DOI, arXiv ID, bibcode, cite key, UUID)",
        },
        libraryID: {
          type: "string",
          description: "UUID of the target library",
        },
      },
      required: ["identifiers", "libraryID"],
    },
  },
  {
    name: "imbib_delete_papers",
    description:
      "Delete papers from the imbib library. Use with caution - this permanently removes papers.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "List of paper identifiers (cite keys, DOIs, etc.)",
        },
      },
      required: ["identifiers"],
    },
  },
  {
    name: "imbib_mark_read",
    description:
      "Mark papers as read or unread. Useful for tracking reading progress.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "List of paper identifiers",
        },
        read: {
          type: "boolean",
          description: "True to mark as read, false to mark as unread",
        },
      },
      required: ["identifiers", "read"],
    },
  },
  {
    name: "imbib_toggle_star",
    description: "Toggle the starred status of papers.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "List of paper identifiers",
        },
      },
      required: ["identifiers"],
    },
  },
  {
    name: "imbib_set_flag",
    description:
      "Set or clear a colored flag on papers. Flags are visual markers for workflow status. Set color to null to clear the flag.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "List of paper identifiers",
        },
        color: {
          type: "string",
          description:
            'Flag color: "red", "amber", "blue", "gray", or null to clear',
        },
        style: {
          type: "string",
          description: 'Flag style: "solid" (default), "dashed", or "dotted"',
        },
        length: {
          type: "string",
          description: 'Flag length: "full" (default), "half", or "quarter"',
        },
      },
      required: ["identifiers"],
    },
  },
  {
    name: "imbib_add_tag",
    description:
      "Add a tag to papers. Tags use hierarchical paths like 'methods/sims' or 'topic/cosmology'. Parent tags are created automatically.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "List of paper identifiers",
        },
        tag: {
          type: "string",
          description:
            'Tag path (e.g., "methods/sims", "to-read", "project/thesis")',
        },
      },
      required: ["identifiers", "tag"],
    },
  },
  {
    name: "imbib_remove_tag",
    description: "Remove a tag from papers.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "List of paper identifiers",
        },
        tag: {
          type: "string",
          description: "Tag path to remove",
        },
      },
      required: ["identifiers", "tag"],
    },
  },
  {
    name: "imbib_list_tags",
    description:
      "List all tags in the library with their usage counts. Useful for finding existing tags before tagging papers.",
    inputSchema: {
      type: "object",
      properties: {
        prefix: {
          type: "string",
          description: "Filter tags by path prefix (e.g., 'methods')",
        },
      },
    },
  },
  {
    name: "imbib_create_collection",
    description:
      "Create a new collection to organize papers. Collections can be regular (manual) or smart (auto-populated by predicate).",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Name for the new collection",
        },
        libraryID: {
          type: "string",
          description: "Library UUID (optional, uses default if not specified)",
        },
        isSmartCollection: {
          type: "boolean",
          description: "Whether this is a smart collection (default: false)",
        },
        predicate: {
          type: "string",
          description:
            "Predicate string for smart collections (e.g., 'isRead == false')",
        },
      },
      required: ["name"],
    },
  },
  {
    name: "imbib_delete_collection",
    description:
      "Delete a collection. This does not delete the papers in the collection.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Collection UUID to delete",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "imbib_add_to_collection",
    description: "Add papers to an existing collection.",
    inputSchema: {
      type: "object",
      properties: {
        collectionID: {
          type: "string",
          description: "Collection UUID",
        },
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "List of paper identifiers to add",
        },
      },
      required: ["collectionID", "identifiers"],
    },
  },
  {
    name: "imbib_remove_from_collection",
    description: "Remove papers from a collection (does not delete them).",
    inputSchema: {
      type: "object",
      properties: {
        collectionID: {
          type: "string",
          description: "Collection UUID",
        },
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "List of paper identifiers to remove",
        },
      },
      required: ["collectionID", "identifiers"],
    },
  },
  {
    name: "imbib_list_libraries",
    description:
      "List all libraries in imbib. Libraries are top-level containers for papers.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "imbib_create_library",
    description:
      "Create a new library in imbib. Libraries are top-level containers for papers, separate from collections. Use this when asked to create a new library for a topic or project.",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Name for the new library",
        },
      },
      required: ["name"],
    },
  },
  {
    name: "imbib_collection_papers",
    description: "List all papers in a specific collection.",
    inputSchema: {
      type: "object",
      properties: {
        collectionID: {
          type: "string",
          description: "Collection UUID",
        },
        limit: {
          type: "number",
          description: "Maximum papers to return (default: 50)",
        },
      },
      required: ["collectionID"],
    },
  },
  {
    name: "imbib_download_pdfs",
    description:
      "Download PDFs for papers. Queues downloads for papers that have known PDF URLs.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "List of paper identifiers",
        },
      },
      required: ["identifiers"],
    },
  },
  // --------------------------------------------------------------------------
  // Collaboration Operations
  // --------------------------------------------------------------------------
  {
    name: "imbib_list_participants",
    description:
      "List all participants in a shared library. Shows who has access, their permissions, and share status.",
    inputSchema: {
      type: "object",
      properties: {
        libraryID: {
          type: "string",
          description: "Library UUID",
        },
      },
      required: ["libraryID"],
    },
  },
  {
    name: "imbib_get_library_activity",
    description:
      "Get recent activity feed for a library. Shows who added, modified, or removed papers and other collaborative actions.",
    inputSchema: {
      type: "object",
      properties: {
        libraryID: {
          type: "string",
          description: "Library UUID",
        },
        limit: {
          type: "number",
          description: "Maximum activities to return (default: 50)",
        },
      },
      required: ["libraryID"],
    },
  },
  {
    name: "imbib_list_comments",
    description:
      "List all comments on a paper. Comments support threaded replies for discussions.",
    inputSchema: {
      type: "object",
      properties: {
        citeKey: {
          type: "string",
          description: "The cite key of the paper",
        },
      },
      required: ["citeKey"],
    },
  },
  {
    name: "imbib_add_comment",
    description:
      "Add a comment to a paper. Can be a top-level comment or a reply to an existing comment.",
    inputSchema: {
      type: "object",
      properties: {
        citeKey: {
          type: "string",
          description: "The cite key of the paper",
        },
        text: {
          type: "string",
          description: "The comment text",
        },
        parentCommentID: {
          type: "string",
          description: "UUID of parent comment if this is a reply (optional)",
        },
      },
      required: ["citeKey", "text"],
    },
  },
  {
    name: "imbib_delete_comment",
    description: "Delete a comment from a paper.",
    inputSchema: {
      type: "object",
      properties: {
        commentID: {
          type: "string",
          description: "UUID of the comment to delete",
        },
      },
      required: ["commentID"],
    },
  },
  {
    name: "imbib_list_assignments",
    description:
      "List paper reading assignments in a library. Shows who is assigned to read which papers.",
    inputSchema: {
      type: "object",
      properties: {
        libraryID: {
          type: "string",
          description: "Library UUID",
        },
      },
      required: ["libraryID"],
    },
  },
  {
    name: "imbib_list_paper_assignments",
    description: "List all assignments for a specific paper.",
    inputSchema: {
      type: "object",
      properties: {
        citeKey: {
          type: "string",
          description: "The cite key of the paper",
        },
      },
      required: ["citeKey"],
    },
  },
  {
    name: "imbib_create_assignment",
    description:
      "Assign a paper to someone for reading. Can include notes and a due date.",
    inputSchema: {
      type: "object",
      properties: {
        citeKey: {
          type: "string",
          description: "The cite key of the paper to assign",
        },
        assigneeName: {
          type: "string",
          description: "Name of the person to assign (from participants)",
        },
        libraryID: {
          type: "string",
          description: "Library UUID (for validation and context)",
        },
        note: {
          type: "string",
          description: "Optional note about the assignment",
        },
        dueDate: {
          type: "string",
          description: "Optional due date (ISO8601 format)",
        },
      },
      required: ["citeKey", "assigneeName", "libraryID"],
    },
  },
  {
    name: "imbib_delete_assignment",
    description: "Delete a paper assignment.",
    inputSchema: {
      type: "object",
      properties: {
        assignmentID: {
          type: "string",
          description: "UUID of the assignment to delete",
        },
      },
      required: ["assignmentID"],
    },
  },
  {
    name: "imbib_share_library",
    description:
      "Share a library via CloudKit. Creates a share URL that can be sent to collaborators.",
    inputSchema: {
      type: "object",
      properties: {
        libraryID: {
          type: "string",
          description: "Library UUID to share",
        },
      },
      required: ["libraryID"],
    },
  },
  {
    name: "imbib_unshare_library",
    description:
      "Stop sharing a library or leave a shared library you're participating in.",
    inputSchema: {
      type: "object",
      properties: {
        libraryID: {
          type: "string",
          description: "Library UUID",
        },
        keepCopy: {
          type: "boolean",
          description:
            "If leaving a shared library, whether to keep a local copy of the papers (default: true)",
        },
      },
      required: ["libraryID"],
    },
  },
  {
    name: "imbib_set_participant_permission",
    description:
      "Change a participant's permission level in a shared library. Only the share owner can do this.",
    inputSchema: {
      type: "object",
      properties: {
        libraryID: {
          type: "string",
          description: "Library UUID",
        },
        participantID: {
          type: "string",
          description: "The participant's ID",
        },
        permission: {
          type: "string",
          enum: ["readOnly", "readWrite"],
          description: "The new permission level",
        },
      },
      required: ["libraryID", "participantID", "permission"],
    },
  },
  // --------------------------------------------------------------------------
  // Annotation and Notes Operations
  // --------------------------------------------------------------------------
  {
    name: "imbib_list_annotations",
    description:
      "List PDF annotations on a paper. Includes highlights, underlines, notes, and text comments made on the PDF.",
    inputSchema: {
      type: "object",
      properties: {
        citeKey: {
          type: "string",
          description: "The cite key of the paper",
        },
        pageNumber: {
          type: "number",
          description: "Filter to a specific page number (optional)",
        },
      },
      required: ["citeKey"],
    },
  },
  {
    name: "imbib_add_annotation",
    description:
      "Add a PDF annotation to a paper. Supports highlights, underlines, strikethroughs, notes, and free text.",
    inputSchema: {
      type: "object",
      properties: {
        citeKey: {
          type: "string",
          description: "The cite key of the paper",
        },
        type: {
          type: "string",
          enum: ["highlight", "underline", "strikethrough", "note", "freeText"],
          description: "Type of annotation",
        },
        pageNumber: {
          type: "number",
          description: "Page number (1-indexed)",
        },
        contents: {
          type: "string",
          description: "Text content for note or freeText annotations",
        },
        selectedText: {
          type: "string",
          description: "The text being highlighted/underlined (for markup annotations)",
        },
        color: {
          type: "string",
          description: "Hex color string (e.g., '#FFFF00' for yellow). Uses default if not specified.",
        },
      },
      required: ["citeKey", "type", "pageNumber"],
    },
  },
  {
    name: "imbib_delete_annotation",
    description: "Delete a PDF annotation.",
    inputSchema: {
      type: "object",
      properties: {
        annotationID: {
          type: "string",
          description: "UUID of the annotation to delete",
        },
      },
      required: ["annotationID"],
    },
  },
  {
    name: "imbib_get_notes",
    description:
      "Get the notes (BibTeX note field) for a paper. These are free-form text notes about the paper stored in the bibliography.",
    inputSchema: {
      type: "object",
      properties: {
        citeKey: {
          type: "string",
          description: "The cite key of the paper",
        },
      },
      required: ["citeKey"],
    },
  },
  {
    name: "imbib_update_notes",
    description:
      "Update the notes (BibTeX note field) for a paper. Set to null to clear notes.",
    inputSchema: {
      type: "object",
      properties: {
        citeKey: {
          type: "string",
          description: "The cite key of the paper",
        },
        notes: {
          type: "string",
          description: "The notes text, or null to clear",
        },
      },
      required: ["citeKey"],
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
      // Read operations
      case "imbib_search_library":
        return this.searchLibrary(args);
      case "imbib_search_sources":
        return this.searchSources(args);
      case "imbib_get_paper":
        return this.getPaper(args);
      case "imbib_export_bibtex":
        return this.exportBibTeX(args);
      case "imbib_list_collections":
        return this.listCollections();
      case "imbib_status":
        return this.getStatus();
      case "imbib_get_logs":
        return this.getLogs(args);
      case "imbib_list_libraries":
        return this.listLibraries();
      case "imbib_create_library":
        return this.createLibrary(args);
      case "imbib_list_tags":
        return this.listTags(args);
      case "imbib_collection_papers":
        return this.collectionPapers(args);

      // Write operations
      case "imbib_add_papers":
        return this.addPapers(args);
      case "imbib_delete_papers":
        return this.deletePapers(args);
      case "imbib_mark_read":
        return this.markRead(args);
      case "imbib_toggle_star":
        return this.toggleStar(args);
      case "imbib_set_flag":
        return this.setFlag(args);
      case "imbib_add_tag":
        return this.addTag(args);
      case "imbib_remove_tag":
        return this.removeTag(args);
      case "imbib_create_collection":
        return this.createCollection(args);
      case "imbib_delete_collection":
        return this.deleteCollection(args);
      case "imbib_add_to_collection":
        return this.addToCollection(args);
      case "imbib_add_to_library":
        return this.addToLibrary(args);
      case "imbib_remove_from_collection":
        return this.removeFromCollection(args);
      case "imbib_download_pdfs":
        return this.downloadPDFs(args);

      // Collaboration operations
      case "imbib_list_participants":
        return this.listParticipants(args);
      case "imbib_get_library_activity":
        return this.getLibraryActivity(args);
      case "imbib_list_comments":
        return this.listComments(args);
      case "imbib_add_comment":
        return this.addComment(args);
      case "imbib_delete_comment":
        return this.deleteComment(args);
      case "imbib_list_assignments":
        return this.listAssignments(args);
      case "imbib_list_paper_assignments":
        return this.listPaperAssignments(args);
      case "imbib_create_assignment":
        return this.createAssignment(args);
      case "imbib_delete_assignment":
        return this.deleteAssignment(args);
      case "imbib_share_library":
        return this.shareLibrary(args);
      case "imbib_unshare_library":
        return this.unshareLibrary(args);
      case "imbib_set_participant_permission":
        return this.setParticipantPermission(args);

      // Annotation and notes operations
      case "imbib_list_annotations":
        return this.listAnnotations(args);
      case "imbib_add_annotation":
        return this.addAnnotation(args);
      case "imbib_delete_annotation":
        return this.deleteAnnotation(args);
      case "imbib_get_notes":
        return this.getNotes(args);
      case "imbib_update_notes":
        return this.updateNotes(args);

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

  private async searchSources(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const query = String(args?.query || "");
    if (!query) {
      return {
        content: [{ type: "text", text: "Error: query is required" }],
      };
    }
    const source = args?.source as string | undefined;
    const limit = args?.limit as number | undefined;

    const result = await this.client.searchExternal(query, {
      source,
      limit: limit ?? 20,
    });

    if (result.results.length === 0) {
      return {
        content: [
          {
            type: "text",
            text: `No external results found for "${query}" (source: ${result.source})`,
          },
        ],
      };
    }

    const resultList = result.results
      .map((r) => {
        const authors =
          r.authors.length > 3
            ? `${r.authors.slice(0, 3).join(", ")} et al.`
            : r.authors.join(", ");
        const year = r.year ? ` (${r.year})` : "";
        const venue = r.venue ? ` - ${r.venue}` : "";
        const ids: string[] = [];
        if (r.doi) ids.push(`DOI: ${r.doi}`);
        if (r.arxivID) ids.push(`arXiv: ${r.arxivID}`);
        if (r.bibcode) ids.push(`bibcode: ${r.bibcode}`);
        const idStr = ids.length > 0 ? `\n  ${ids.join(", ")}` : "";
        return `- ${r.title}${year}\n  ${authors}${venue}${idStr}\n  → Add with identifier: \`${r.identifier}\``;
      })
      .join("\n\n");

    return {
      content: [
        {
          type: "text",
          text: `Found ${result.count} results from ${result.source} for "${query}":\n\n${resultList}\n\nTo add papers to the library, use imbib_add_papers with the identifiers listed above.`,
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
          text: `# imbib Logs (${result.data.entries.length} of ${result.data.count} filtered, ${result.data.totalInStore} total)\n\n\`\`\`\n${lines.join("\n")}\n\`\`\``,
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

  // --------------------------------------------------------------------------
  // Additional Read Operations
  // --------------------------------------------------------------------------

  private async createLibrary(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const name = String(args?.name || "");
    if (!name) {
      return {
        content: [{ type: "text", text: "Error: name is required" }],
      };
    }

    const result = await this.client.createLibrary(name);

    return {
      content: [
        {
          type: "text",
          text: `Created library **${result.name}** (ID: ${result.id}). You can now add papers to this library using imbib_add_papers with the library parameter set to "${result.id}".`,
        },
      ],
    };
  }

  private async listLibraries(): Promise<{
    content: Array<{ type: string; text: string }>;
  }> {
    const libraries = await this.client.listLibraries();

    if (libraries.length === 0) {
      return {
        content: [{ type: "text", text: "No libraries found" }],
      };
    }

    const list = libraries
      .map((lib) => {
        const markers = [];
        if (lib.isDefault) markers.push("default");
        if (lib.isInbox) markers.push("inbox");
        const suffix = markers.length > 0 ? ` (${markers.join(", ")})` : "";
        return `- **${lib.name}**${suffix}: ${lib.paperCount} papers, ${lib.collectionCount} collections`;
      })
      .join("\n");

    return {
      content: [
        {
          type: "text",
          text: `# Libraries (${libraries.length})\n\n${list}`,
        },
      ],
    };
  }

  private async listTags(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const prefix = args?.prefix as string | undefined;
    const tags = await this.client.listTags(prefix);

    if (tags.length === 0) {
      const msg = prefix
        ? `No tags found matching prefix "${prefix}"`
        : "No tags found in library";
      return { content: [{ type: "text", text: msg }] };
    }

    const list = tags
      .map((t) => `- **${t.canonicalPath}** (${t.publicationCount} papers, used ${t.useCount}x)`)
      .join("\n");

    return {
      content: [
        {
          type: "text",
          text: `# Tags (${tags.length})\n\n${list}`,
        },
      ],
    };
  }

  private async collectionPapers(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const collectionID = args?.collectionID as string | undefined;
    if (!collectionID) {
      return {
        content: [{ type: "text", text: "Error: collectionID is required" }],
      };
    }

    const limit = (args?.limit as number) ?? 50;
    const papers = await this.client.listCollectionPapers(collectionID, { limit });

    if (papers.length === 0) {
      return {
        content: [{ type: "text", text: "No papers in this collection" }],
      };
    }

    const list = this.formatPaperList(papers);
    return {
      content: [
        {
          type: "text",
          text: `# Collection Papers (${papers.length})\n\n${list}`,
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Write Operations
  // --------------------------------------------------------------------------

  private async addPapers(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const identifiers = args?.identifiers as string[] | undefined;
    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }

    const result = await this.client.addPapers(identifiers, {
      library: args?.library as string | undefined,
      collection: args?.collection as string | undefined,
      downloadPDFs: args?.downloadPDFs as boolean | undefined,
    });

    const lines: string[] = [`# Add Papers Result`];

    if (result.added.length > 0) {
      lines.push("", `## Added (${result.added.length})`);
      for (const paper of result.added) {
        lines.push(`- **${paper.citeKey}**: ${paper.title}`);
      }
    }

    if (result.duplicates.length > 0) {
      const hasTarget = args?.library || args?.collection;
      lines.push("", `## Already Existed (${result.duplicates.length})${hasTarget ? " — assigned to target library/collection" : ""}`);
      for (const dup of result.duplicates) {
        lines.push(`- ${dup}`);
      }
    }

    if (Object.keys(result.failed).length > 0) {
      lines.push("", `## Failed`);
      for (const [id, error] of Object.entries(result.failed)) {
        lines.push(`- **${id}**: ${error}`);
      }
    }

    return { content: [{ type: "text", text: lines.join("\n") }] };
  }

  private async deletePapers(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const identifiers = args?.identifiers as string[] | undefined;
    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }

    const result = await this.client.deletePapers(identifiers);
    return {
      content: [
        { type: "text", text: `Deleted ${result.deleted} paper(s)` },
      ],
    };
  }

  private async markRead(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const identifiers = args?.identifiers as string[] | undefined;
    const read = args?.read as boolean | undefined;

    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }
    if (read === undefined) {
      return {
        content: [{ type: "text", text: "Error: read boolean is required" }],
      };
    }

    const result = await this.client.markRead(identifiers, read);
    const status = read ? "read" : "unread";
    return {
      content: [
        { type: "text", text: `Marked ${result.updated} paper(s) as ${status}` },
      ],
    };
  }

  private async toggleStar(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const identifiers = args?.identifiers as string[] | undefined;
    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }

    const result = await this.client.toggleStar(identifiers);
    return {
      content: [
        { type: "text", text: `Toggled star on ${result.updated} paper(s)` },
      ],
    };
  }

  private async setFlag(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const identifiers = args?.identifiers as string[] | undefined;
    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }

    const color = args?.color as string | null | undefined;
    const style = args?.style as string | undefined;
    const length = args?.length as string | undefined;

    const result = await this.client.setFlag(identifiers, color ?? null, style, length);
    const action = color ? `Set ${color} flag on` : "Cleared flag from";
    return {
      content: [{ type: "text", text: `${action} ${result.updated} paper(s)` }],
    };
  }

  private async addTag(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const identifiers = args?.identifiers as string[] | undefined;
    const tag = args?.tag as string | undefined;

    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }
    if (!tag) {
      return {
        content: [{ type: "text", text: "Error: tag is required" }],
      };
    }

    const result = await this.client.addTag(identifiers, tag);
    return {
      content: [
        { type: "text", text: `Added tag "${tag}" to ${result.updated} paper(s)` },
      ],
    };
  }

  private async removeTag(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const identifiers = args?.identifiers as string[] | undefined;
    const tag = args?.tag as string | undefined;

    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }
    if (!tag) {
      return {
        content: [{ type: "text", text: "Error: tag is required" }],
      };
    }

    const result = await this.client.removeTag(identifiers, tag);
    return {
      content: [
        { type: "text", text: `Removed tag "${tag}" from ${result.updated} paper(s)` },
      ],
    };
  }

  private async createCollection(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const name = args?.name as string | undefined;
    if (!name) {
      return {
        content: [{ type: "text", text: "Error: name is required" }],
      };
    }

    const collection = await this.client.createCollection(name, {
      libraryID: args?.libraryID as string | undefined,
      isSmartCollection: args?.isSmartCollection as boolean | undefined,
      predicate: args?.predicate as string | undefined,
    });

    const smart = collection.isSmartCollection ? " (Smart)" : "";
    return {
      content: [
        {
          type: "text",
          text: `Created collection "${collection.name}"${smart}\n\nID: ${collection.id}`,
        },
      ],
    };
  }

  private async deleteCollection(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const id = args?.id as string | undefined;
    if (!id) {
      return {
        content: [{ type: "text", text: "Error: id is required" }],
      };
    }

    const result = await this.client.deleteCollection(id);
    return {
      content: [
        { type: "text", text: result.deleted ? "Collection deleted" : "Collection not found" },
      ],
    };
  }

  private async addToCollection(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const collectionID = args?.collectionID as string | undefined;
    const identifiers = args?.identifiers as string[] | undefined;

    if (!collectionID) {
      return {
        content: [{ type: "text", text: "Error: collectionID is required" }],
      };
    }
    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }

    const result = await this.client.addToCollection(collectionID, identifiers);
    return {
      content: [
        { type: "text", text: `Added ${result.updated} paper(s) to collection` },
      ],
    };
  }

  private async addToLibrary(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const libraryID = args?.libraryID as string | undefined;
    const identifiers = args?.identifiers as string[] | undefined;

    if (!libraryID) {
      return {
        content: [{ type: "text", text: "Error: libraryID is required" }],
      };
    }
    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }

    const result = await this.client.addToLibrary(libraryID, identifiers);
    return {
      content: [
        { type: "text", text: `Assigned ${result.assigned.length} paper(s) to library. Not found: ${result.notFound.length}` },
      ],
    };
  }

  private async removeFromCollection(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const collectionID = args?.collectionID as string | undefined;
    const identifiers = args?.identifiers as string[] | undefined;

    if (!collectionID) {
      return {
        content: [{ type: "text", text: "Error: collectionID is required" }],
      };
    }
    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }

    const result = await this.client.removeFromCollection(collectionID, identifiers);
    return {
      content: [
        { type: "text", text: `Removed ${result.updated} paper(s) from collection` },
      ],
    };
  }

  private async downloadPDFs(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const identifiers = args?.identifiers as string[] | undefined;
    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers array is required" }],
      };
    }

    const result = await this.client.downloadPDFs(identifiers);

    const lines: string[] = [`# Download PDFs Result`];

    if (result.downloaded.length > 0) {
      lines.push("", `## Queued for download (${result.downloaded.length})`);
      for (const key of result.downloaded) {
        lines.push(`- ${key}`);
      }
    }

    if (result.alreadyHad.length > 0) {
      lines.push("", `## Already had PDF (${result.alreadyHad.length})`);
      for (const key of result.alreadyHad) {
        lines.push(`- ${key}`);
      }
    }

    if (Object.keys(result.failed).length > 0) {
      lines.push("", `## Failed`);
      for (const [id, error] of Object.entries(result.failed)) {
        lines.push(`- **${id}**: ${error}`);
      }
    }

    return { content: [{ type: "text", text: lines.join("\n") }] };
  }

  // --------------------------------------------------------------------------
  // Collaboration Operations
  // --------------------------------------------------------------------------

  private async listParticipants(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const libraryID = args?.libraryID as string | undefined;
    if (!libraryID) {
      return {
        content: [{ type: "text", text: "Error: libraryID is required" }],
      };
    }

    const participants = await this.client.listParticipants(libraryID);

    if (participants.length === 0) {
      return {
        content: [{ type: "text", text: "No participants found (library may not be shared)" }],
      };
    }

    const list = participants
      .map((p) => {
        const name = p.displayName || p.email || p.id;
        const owner = p.isOwner ? " (Owner)" : "";
        const status = p.status !== "accepted" ? ` [${p.status}]` : "";
        return `- **${name}**${owner}: ${p.permission}${status}`;
      })
      .join("\n");

    return {
      content: [
        {
          type: "text",
          text: `# Library Participants (${participants.length})\n\n${list}`,
        },
      ],
    };
  }

  private async getLibraryActivity(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const libraryID = args?.libraryID as string | undefined;
    if (!libraryID) {
      return {
        content: [{ type: "text", text: "Error: libraryID is required" }],
      };
    }

    const limit = args?.limit as number | undefined;
    const activities = await this.client.getLibraryActivity(libraryID, limit);

    if (activities.length === 0) {
      return {
        content: [{ type: "text", text: "No recent activity" }],
      };
    }

    const list = activities
      .map((a) => {
        const actor = a.actorDisplayName || "Someone";
        const target = a.targetTitle ? ` "${a.targetTitle}"` : "";
        const detail = a.detail ? ` (${a.detail})` : "";
        const date = new Date(a.date).toLocaleString();
        return `- [${date}] **${actor}** ${a.activityType}${target}${detail}`;
      })
      .join("\n");

    return {
      content: [
        {
          type: "text",
          text: `# Library Activity (${activities.length})\n\n${list}`,
        },
      ],
    };
  }

  private async listComments(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKey = args?.citeKey as string | undefined;
    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }

    const comments = await this.client.listComments(citeKey);

    if (comments.length === 0) {
      return {
        content: [{ type: "text", text: "No comments on this paper" }],
      };
    }

    const formatComment = (c: Comment, indent: number = 0): string => {
      const prefix = "  ".repeat(indent);
      const author = c.authorDisplayName || "Anonymous";
      const date = new Date(c.dateCreated).toLocaleString();
      let text = `${prefix}- **${author}** (${date}):\n${prefix}  ${c.text}`;
      if (c.replies && c.replies.length > 0) {
        text += "\n" + c.replies.map((r) => formatComment(r, indent + 1)).join("\n");
      }
      return text;
    };

    const list = comments.map((c) => formatComment(c)).join("\n\n");

    return {
      content: [
        {
          type: "text",
          text: `# Comments on ${citeKey} (${comments.length})\n\n${list}`,
        },
      ],
    };
  }

  private async addComment(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKey = args?.citeKey as string | undefined;
    const text = args?.text as string | undefined;

    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }
    if (!text) {
      return {
        content: [{ type: "text", text: "Error: text is required" }],
      };
    }

    const parentCommentID = args?.parentCommentID as string | undefined;
    const comment = await this.client.addComment(citeKey, text, parentCommentID);

    const replyInfo = parentCommentID ? " (reply)" : "";
    return {
      content: [
        {
          type: "text",
          text: `Added comment${replyInfo} to ${citeKey}\n\nComment ID: ${comment.id}`,
        },
      ],
    };
  }

  private async deleteComment(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const commentID = args?.commentID as string | undefined;
    if (!commentID) {
      return {
        content: [{ type: "text", text: "Error: commentID is required" }],
      };
    }

    const result = await this.client.deleteComment(commentID);
    return {
      content: [
        { type: "text", text: result.deleted ? "Comment deleted" : "Comment not found" },
      ],
    };
  }

  private async listAssignments(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const libraryID = args?.libraryID as string | undefined;
    if (!libraryID) {
      return {
        content: [{ type: "text", text: "Error: libraryID is required" }],
      };
    }

    const assignments = await this.client.listLibraryAssignments(libraryID);

    if (assignments.length === 0) {
      return {
        content: [{ type: "text", text: "No assignments in this library" }],
      };
    }

    const list = this.formatAssignmentList(assignments);
    return {
      content: [
        {
          type: "text",
          text: `# Library Assignments (${assignments.length})\n\n${list}`,
        },
      ],
    };
  }

  private async listPaperAssignments(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKey = args?.citeKey as string | undefined;
    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }

    const assignments = await this.client.listPaperAssignments(citeKey);

    if (assignments.length === 0) {
      return {
        content: [{ type: "text", text: "No assignments for this paper" }],
      };
    }

    const list = this.formatAssignmentList(assignments);
    return {
      content: [
        {
          type: "text",
          text: `# Assignments for ${citeKey} (${assignments.length})\n\n${list}`,
        },
      ],
    };
  }

  private async createAssignment(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKey = args?.citeKey as string | undefined;
    const assigneeName = args?.assigneeName as string | undefined;
    const libraryID = args?.libraryID as string | undefined;

    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }
    if (!assigneeName) {
      return {
        content: [{ type: "text", text: "Error: assigneeName is required" }],
      };
    }
    if (!libraryID) {
      return {
        content: [{ type: "text", text: "Error: libraryID is required" }],
      };
    }

    const assignment = await this.client.createAssignment(citeKey, assigneeName, libraryID, {
      note: args?.note as string | undefined,
      dueDate: args?.dueDate as string | undefined,
    });

    const dueInfo = assignment.dueDate ? ` (due: ${assignment.dueDate})` : "";
    return {
      content: [
        {
          type: "text",
          text: `Assigned "${assignment.publicationTitle || citeKey}" to ${assigneeName}${dueInfo}\n\nAssignment ID: ${assignment.id}`,
        },
      ],
    };
  }

  private async deleteAssignment(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const assignmentID = args?.assignmentID as string | undefined;
    if (!assignmentID) {
      return {
        content: [{ type: "text", text: "Error: assignmentID is required" }],
      };
    }

    const result = await this.client.deleteAssignment(assignmentID);
    return {
      content: [
        { type: "text", text: result.deleted ? "Assignment deleted" : "Assignment not found" },
      ],
    };
  }

  private async shareLibrary(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const libraryID = args?.libraryID as string | undefined;
    if (!libraryID) {
      return {
        content: [{ type: "text", text: "Error: libraryID is required" }],
      };
    }

    const result = await this.client.shareLibrary(libraryID);

    const lines = [`# Library Shared`, "", `**Library ID:** ${result.libraryID}`];
    if (result.shareURL) {
      lines.push(`**Share URL:** ${result.shareURL}`);
      lines.push("", "Send this URL to collaborators to invite them to the library.");
    }

    return {
      content: [{ type: "text", text: lines.join("\n") }],
    };
  }

  private async unshareLibrary(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const libraryID = args?.libraryID as string | undefined;
    if (!libraryID) {
      return {
        content: [{ type: "text", text: "Error: libraryID is required" }],
      };
    }

    const keepCopy = args?.keepCopy as boolean | undefined;
    const result = await this.client.unshareLibrary(libraryID, keepCopy);

    const keptCopy = keepCopy !== false ? " (kept local copy)" : "";
    return {
      content: [
        {
          type: "text",
          text: result.unshared
            ? `Library unshared/left successfully${keptCopy}`
            : "Failed to unshare library",
        },
      ],
    };
  }

  private async setParticipantPermission(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const libraryID = args?.libraryID as string | undefined;
    const participantID = args?.participantID as string | undefined;
    const permission = args?.permission as "readOnly" | "readWrite" | undefined;

    if (!libraryID) {
      return {
        content: [{ type: "text", text: "Error: libraryID is required" }],
      };
    }
    if (!participantID) {
      return {
        content: [{ type: "text", text: "Error: participantID is required" }],
      };
    }
    if (!permission || (permission !== "readOnly" && permission !== "readWrite")) {
      return {
        content: [{ type: "text", text: "Error: permission must be 'readOnly' or 'readWrite'" }],
      };
    }

    const result = await this.client.setParticipantPermission(libraryID, participantID, permission);
    return {
      content: [
        {
          type: "text",
          text: result.updated
            ? `Updated participant permission to ${permission}`
            : "Failed to update permission",
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Helpers
  // --------------------------------------------------------------------------

  private formatPaperList(papers: Paper[]): string {
    return papers
      .map((p) => {
        const authors =
          p.authors.length > 3
            ? `${p.authors.slice(0, 3).join(", ")} et al.`
            : p.authors.join(", ");
        const year = p.year ? ` (${p.year})` : "";
        const venue = p.venue ? ` - ${p.venue}` : "";
        const pdf = p.hasPDF ? " [PDF]" : "";
        const starred = p.isStarred ? " *" : "";
        const flag = p.flag ? ` [${p.flag.color}]` : "";
        const tags = p.tags && p.tags.length > 0 ? ` {${p.tags.join(", ")}}` : "";
        return `- **${p.citeKey}**: ${p.title}${year}\n  ${authors}${venue}${pdf}${starred}${flag}${tags}`;
      })
      .join("\n\n");
  }

  private formatAssignmentList(assignments: Assignment[]): string {
    return assignments
      .map((a) => {
        const paper = a.publicationCiteKey || a.publicationTitle || a.publicationID;
        const assignee = a.assigneeName || "Unassigned";
        const assignedBy = a.assignedByName ? ` (by ${a.assignedByName})` : "";
        const dueDate = a.dueDate ? `\n  Due: ${new Date(a.dueDate).toLocaleDateString()}` : "";
        const note = a.note ? `\n  Note: ${a.note}` : "";
        const date = new Date(a.dateCreated).toLocaleDateString();
        return `- **${paper}** → ${assignee}${assignedBy} (${date})${dueDate}${note}`;
      })
      .join("\n\n");
  }

  // --------------------------------------------------------------------------
  // Annotation and Notes Operations
  // --------------------------------------------------------------------------

  private async listAnnotations(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKey = args?.citeKey as string | undefined;
    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }

    const pageNumber = args?.pageNumber as number | undefined;
    const annotations = await this.client.listAnnotations(citeKey, pageNumber);

    if (annotations.length === 0) {
      const pageInfo = pageNumber ? ` on page ${pageNumber}` : "";
      return {
        content: [{ type: "text", text: `No annotations${pageInfo} on this paper` }],
      };
    }

    const list = annotations
      .map((a) => {
        const author = a.author ? ` by ${a.author}` : "";
        const text = a.selectedText ? `\n  "${a.selectedText}"` : "";
        const contents = a.contents ? `\n  Note: ${a.contents}` : "";
        const date = new Date(a.dateCreated).toLocaleDateString();
        return `- **${a.type}** (page ${a.pageNumber}, ${a.color})${author} - ${date}${text}${contents}`;
      })
      .join("\n\n");

    const pageInfo = pageNumber ? ` on page ${pageNumber}` : "";
    return {
      content: [
        {
          type: "text",
          text: `# Annotations${pageInfo} on ${citeKey} (${annotations.length})\n\n${list}`,
        },
      ],
    };
  }

  private async addAnnotation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKey = args?.citeKey as string | undefined;
    const type = args?.type as string | undefined;
    const pageNumber = args?.pageNumber as number | undefined;

    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }
    if (!type) {
      return {
        content: [{ type: "text", text: "Error: type is required" }],
      };
    }
    if (pageNumber === undefined) {
      return {
        content: [{ type: "text", text: "Error: pageNumber is required" }],
      };
    }

    const annotation = await this.client.addAnnotation(citeKey, type, pageNumber, {
      contents: args?.contents as string | undefined,
      selectedText: args?.selectedText as string | undefined,
      color: args?.color as string | undefined,
    });

    return {
      content: [
        {
          type: "text",
          text: `Added ${annotation.type} annotation to page ${annotation.pageNumber}\n\nAnnotation ID: ${annotation.id}`,
        },
      ],
    };
  }

  private async deleteAnnotation(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const annotationID = args?.annotationID as string | undefined;
    if (!annotationID) {
      return {
        content: [{ type: "text", text: "Error: annotationID is required" }],
      };
    }

    const result = await this.client.deleteAnnotation(annotationID);
    return {
      content: [
        { type: "text", text: result.deleted ? "Annotation deleted" : "Annotation not found" },
      ],
    };
  }

  private async getNotes(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKey = args?.citeKey as string | undefined;
    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }

    const notes = await this.client.getNotes(citeKey);

    if (!notes) {
      return {
        content: [{ type: "text", text: `No notes for ${citeKey}` }],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: `# Notes for ${citeKey}\n\n${notes}`,
        },
      ],
    };
  }

  private async updateNotes(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const citeKey = args?.citeKey as string | undefined;
    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }

    // notes can be a string or null/undefined to clear
    const notes = args?.notes as string | null | undefined;

    const result = await this.client.updateNotes(citeKey, notes ?? null);
    const action = result.notes ? "Updated notes" : "Cleared notes";
    return {
      content: [{ type: "text", text: `${action} for ${citeKey}` }],
    };
  }
}
