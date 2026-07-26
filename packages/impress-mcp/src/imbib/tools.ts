/**
 * MCP tool definitions for imbib
 */

import { text, isInlineable, type ToolResult, type ToolContent } from "../content.js";
import { rasterizePDFPage } from "../raster.js";
import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import {
  ImbibClient,
  type Paper,
  type Artifact,
  type Participant,
  type Activity,
  type Comment,
  type Assignment,
  type Annotation,
  type RecentPaper,
  type SmartSearch,
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
    name: "imbib_recent_activity",
    description:
      "What the USER was recently working on: papers they viewed or added by hand, most recent first, each carrying activity_kind ('viewed' or 'added') and activity_at. This is imbib's 'Recent' virtual library, and it is the right opener for 'what was I just reading?' / 'pick up where I left off'. Automated ingest is deliberately excluded — inbox feeds, smart-search refreshes and group feeds never record activity, so this list is genuinely the user's own trail. For newly ARRIVED papers regardless of who put them there, use imbib_recent_papers instead.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "number",
          description:
            "Maximum papers to return. Defaults to the user's 'Recent papers to keep' preference.",
        },
      },
    },
  },
  {
    name: "imbib_recent_papers",
    description:
      "Papers most recently ADDED to the library, by creation date. Includes everything that arrived through automated ingest (inbox feeds, smart-search refreshes, group feeds), so it answers 'what's new?' rather than 'what was I doing?'. For the latter — the user's own viewing/adding trail — use imbib_recent_activity. Scope to one library or collection with parentId.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "number", description: "Maximum papers to return (default 50)" },
        parentId: {
          type: "string",
          description:
            "Optional library or collection UUID to scope the listing (from imbib_list_libraries / imbib_list_collections)",
        },
      },
    },
  },
  {
    name: "imbib_starred_papers",
    description:
      "List the user's starred papers, most recently added first. Stars are the user's manual 'this one matters' marker — set/clear them with imbib_toggle_star. Complements imbib_recent_activity (chronological) with a curated set. If you only need the number, use imbib_count_papers, which does not fetch rows.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "number", description: "Maximum papers to return (default 50)" },
        parentId: {
          type: "string",
          description: "Optional library or collection UUID to scope the listing",
        },
      },
    },
  },
  {
    name: "imbib_count_papers",
    description:
      "Get a single count — unread, starred, flagged, or by-tag — without fetching any paper rows. Use whenever the user asks 'how many …'; it is far cheaper than listing and lengthing the result, and unlike imbib_list_tags it does not walk the whole tag vocabulary.",
    inputSchema: {
      type: "object",
      properties: {
        kind: {
          type: "string",
          enum: ["unread", "starred", "flagged", "by-tag"],
          description: "Which count to take",
        },
        parentId: {
          type: "string",
          description:
            "Optional library/collection UUID to scope 'unread', 'starred' and 'by-tag'",
        },
        color: {
          type: "string",
          description:
            "For kind='flagged': restrict to one flag color (red/amber/blue/gray). Omit for all flagged papers.",
        },
        tag: {
          type: "string",
          description:
            "For kind='by-tag' (required): the tag path, e.g. 'ai/field/cosmology'",
        },
      },
      required: ["kind"],
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
    name: "imbib_render_plot",
    description:
      "Render a native plot (impress-plot) from a declarative spec to SVG. Spec: {title?, x?: {scale: 'linear'|'log', min?, max?, label?}, y?: {...}, series: [{kind: 'line'|'scatter'|'contour', xs: number[], ys: number[], color?: {r,g,b}}], colormap?: 'viridis'|'magma'|'plasma'|'inferno'|'cividis'|'turbo'|'greys', strategy?: 'auto'|'vector'|'raster', width?, height?, contourLevels?}. Pass specId (UUID) instead of spec to render a SAVED spec from the store. Auto-picks vector below ~10k points, raster 2D-histogram above; kind 'contour' draws density iso-lines (vector) over a heatmap underlay, with inline level labels (disable via contourLabels: false) and an optional per-level line-style cycle contourLineStyles: ['solid','dashed','dotted','dashDotted'] for traceability; contourLevelValues: number[] pins explicit levels. Alternatively pass gridSpec {values: number[] (row-major, iy*nx+ix, iy 0 = low y), nx, ny, xMin, xMax, yMin, yMax, style: 'heatmap'|'contour'|'both', colormap?, logScale?, contourLevelValues?, smoothSigma?} to render a direct z-grid field (analytic function, simulation slice) with no binning.",
    inputSchema: {
      type: "object",
      properties: {
        spec: {
          type: "object",
          description: "The plot spec (see tool description for shape)",
        },
      },
      required: ["spec"],
    },
  },
  {
    name: "imbib_list_plot_specs",
    description:
      "List SAVED plot specs from the shared store (name, id, kind). Saved specs are reusable declarative figures; render one via imbib_render_plot with specId.",
    inputSchema: { type: "object", properties: {} },
  },
  {
    name: "imbib_save_plot_spec",
    description:
      "Save a plot spec (series `spec` or `gridSpec`) into the shared store under a name, so it can be re-rendered/edited later from either app.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Display name" },
        spec: { type: "object", description: "Series spec (same shape as imbib_render_plot)" },
        gridSpec: { type: "object", description: "Grid spec (alternative to spec)" },
        dataSource: { type: "string", description: "Optional provenance note" },
      },
      required: ["name"],
    },
  },
  {
    name: "imbib_save_plot_figure",
    description:
      "Save a plot spec's raster heatmap as a figure in a manuscript's app-group figures/ directory and return the Typst snippet to insert into the manuscript source. The manuscript compile resolves the image automatically.",
    inputSchema: {
      type: "object",
      properties: {
        manuscriptId: {
          type: "string",
          description: "The manuscript UUID",
        },
        spec: {
          type: "object",
          description: "The plot spec (same shape as imbib_render_plot)",
        },
        name: {
          type: "string",
          description: "Figure file name (sanitized; .png appended)",
        },
      },
      required: ["manuscriptId", "spec"],
    },
  },
  // --------------------------------------------------------------------------
  // Manuscripts
  //
  // Manuscripts are rows in the shared impress store (ADR-0018), authored in
  // imprint but served by imbib — and imbib is the only impress app whose HTTP
  // surface is reachable from iOS, so these are the manuscript tools that work
  // when the user is on their phone. Body writes are compare-and-set.
  // --------------------------------------------------------------------------
  {
    name: "imbib_list_manuscripts",
    description:
      "List the manuscripts in the shared impress store: UUID, title, format ('typst'/'latex'/unset) and status. Metadata only — no body text. START HERE for any manuscript request: every other imbib manuscript tool needs the UUID this returns. Read the text with imbib_get_manuscript. Prefer this over imprint_list_manuscripts whenever the agent may be driving imbib remotely: imprint's HTTP router is macOS-only, imbib's works from the phone too.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "imbib_get_manuscript",
    description:
      "Read one manuscript: its full body text plus its contentHash. ALWAYS call this immediately before imbib_write_manuscript_body — the contentHash is the compare-and-set token that authorises your write, and it is the only thing stopping you from silently overwriting an edit the user made on their phone while you were thinking. Use imbib_list_manuscripts to find the UUID.",
    inputSchema: {
      type: "object",
      properties: {
        manuscriptId: {
          type: "string",
          description: "Manuscript UUID (from imbib_list_manuscripts)",
        },
      },
      required: ["manuscriptId"],
    },
  },
  {
    name: "imbib_create_manuscript",
    description:
      "Create a NEW manuscript row and return its UUID. For changing an existing document use imbib_write_manuscript_body instead. Note: imbib exposes no delete-manuscript route, so a manuscript created here can only be removed from inside the app — do not create scratch/test manuscripts in the user's store.",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string", description: "Manuscript title (required)" },
        body: {
          type: "string",
          description: "Optional initial source text (default: empty)",
        },
        format: {
          type: "string",
          enum: ["typst", "latex"],
          description:
            "Source format (default 'typst'). Only typst manuscripts can be compiled by imbib_compile_manuscript.",
        },
        authors: {
          type: "array",
          items: { type: "string" },
          description: "Optional author names",
        },
      },
      required: ["title"],
    },
  },
  {
    name: "imbib_write_manuscript_body",
    description:
      "Replace a manuscript's ENTIRE body text, compare-and-set. There is no patch/append/insert route — send the whole document. Requires expectedHash: the contentHash returned by imbib_get_manuscript for the exact text you edited. If the stored text has moved since that read (the user typed on their phone, another agent wrote), the call reports a CONFLICT and writes NOTHING; the correct response is to re-read with imbib_get_manuscript, re-apply your edit to the NEW text, and write again with the NEW hash. Never retry the same hash, and never set unconditional:true to force a stale write past a conflict — that destroys the user's writing. Verify the result with imbib_compile_manuscript.",
    inputSchema: {
      type: "object",
      properties: {
        manuscriptId: { type: "string", description: "Manuscript UUID" },
        body: {
          type: "string",
          description: "The complete new body text (replaces everything)",
        },
        expectedHash: {
          type: "string",
          description:
            "contentHash from the imbib_get_manuscript call whose text you edited. Required unless unconditional:true.",
        },
        unconditional: {
          type: "boolean",
          description:
            "Escape hatch: write without a hash check. Only legitimate for a manuscript whose contentHash is null (never had a body). Using it to resolve a conflict overwrites concurrent edits.",
        },
      },
      required: ["manuscriptId", "body"],
    },
  },
  {
    name: "imbib_compile_manuscript",
    description:
      "Compile a Typst manuscript headlessly, with the store-backed virtual bibliography (@citeKey references are resolved against the imbib library). Returns pass/fail, warnings/errors, PDF size, and citedKeys vs resolvedKeys — keys in the first list but not the second are your BROKEN citations. By default also renders page 1 as an image so the user can actually see the result in the conversation; set preview:false to skip that. LaTeX-format manuscripts are refused by this route. Use after every imbib_write_manuscript_body to confirm the document still builds.",
    inputSchema: {
      type: "object",
      properties: {
        manuscriptId: { type: "string", description: "Manuscript UUID" },
        preview: {
          type: "boolean",
          description:
            "Render page 1 of the PDF as an inline image (default true). Set false for a text-only verification.",
        },
      },
      required: ["manuscriptId"],
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
      "Delete papers from the imbib library. DESTRUCTIVE AND NOT UNDOABLE: this route removes the rows outright and writes nothing to the operation log, so imbib_undo cannot bring them back (verified live 2026-07-25). The only safety net is an imbib_create_backup taken beforehand — do that whenever the instruction is spoken, bulk, or at all ambiguous about which papers are meant, and confirm the list with the user first. To take papers out of the user's way without destroying them, prefer imbib_remove_from_collection, or move them to the Dismissed library (imbib's trash) with imbib_add_to_library.",
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
  // --------------------------------------------------------------------------
  // Undo — the safety net under every destructive tool above
  // --------------------------------------------------------------------------
  {
    name: "imbib_recent_undo_groups",
    description:
      "List the most recent revertible store operations, newest first: operation_id, a human description, timestamp, and (when one user action touched several rows) batch_id. This is the 'what did I just change?' / 'can I take that back?' tool — call it right after a mutation to capture the id that reverses it, then pass that id to imbib_undo. IMPORTANT — the log covers EDITS, not deletions: field changes (title, abstract, notes, read/star/flag, manuscript body writes) and tag attach/detach via imbib_add_tag / imbib_remove_tag are recorded and revertible. Deleting papers, collections, libraries, smart searches or tags is NOT recorded and CANNOT be undone this way — the only protection there is an imbib_create_backup taken beforehand. Verified live 2026-07-25.",
    inputSchema: {
      type: "object",
      properties: {
        maxEntries: {
          type: "number",
          description: "How many groups to return, newest first (default 25)",
        },
      },
    },
  },
  {
    name: "imbib_undo",
    description:
      "Reverse a store change recorded by imbib_recent_undo_groups by applying its inverse. Pass batchId when the group has one — a batch covers every operation the user's single action produced, so undoing one operation of a multi-row edit would leave the rest changed. Otherwise pass operationId. Ids come ONLY from imbib_recent_undo_groups; they cannot be constructed and do not survive imbib_restore_backup. Scope, exactly: it reverts recorded EDITS (fields, notes, read/star/flag, manuscript body writes, tag attach/detach). It cannot resurrect anything deleted — papers, collections, smart searches, tags — because those routes do not write to the operation log; nor does it touch files on disk, so it cannot bring back a pruned backup or a removed PDF.",
    inputSchema: {
      type: "object",
      properties: {
        operationId: {
          type: "string",
          description: "operation_id from imbib_recent_undo_groups (single operation)",
        },
        batchId: {
          type: "string",
          description:
            "batch_id from imbib_recent_undo_groups — preferred when present; reverses the whole action",
        },
      },
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
      "Attach a tag to specific papers. Tags use hierarchical paths like 'methods/sims' or 'topic/cosmology'; missing tags (and their parents) are created automatically, so you do NOT need imbib_create_tag first. This changes tag MEMBERSHIP; to manage the tag vocabulary itself use imbib_create_tag / imbib_rename_tag / imbib_delete_tag.",
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
    description:
      "Detach a tag from the papers you name. The tag itself survives and stays on every other paper — to remove it from the library entirely use imbib_delete_tag. This one IS recorded in the operation log, so it can be reversed with imbib_recent_undo_groups + imbib_undo.",
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
  // --------------------------------------------------------------------------
  // Tag vocabulary management.
  //
  // These operate on the tag TREE, library-wide. Attaching/detaching tags on
  // individual papers is imbib_add_tag / imbib_remove_tag above.
  // --------------------------------------------------------------------------
  {
    name: "imbib_create_tag",
    description:
      "Create a tag in the library's tag vocabulary, optionally with light/dark display colors. Paths are hierarchical with '/' (e.g. 'method/mcmc'). This does NOT put the tag on any paper — imbib_add_tag does that, and it creates missing tags implicitly, so reach for this tool only when the user wants a category to exist up front or wants to give a brand-new tag a color.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Hierarchical tag path, e.g. 'project/thesis'",
        },
        colorLight: {
          type: "string",
          description: "Optional hex color for light appearance, e.g. '#336699'",
        },
        colorDark: {
          type: "string",
          description: "Optional hex color for dark appearance",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "imbib_rename_tag",
    description:
      "Rename or re-parent a tag path across the whole library; every paper carrying it keeps it under the new path. This is the tool for reorganising a tag hierarchy (e.g. 'cosmology' → 'topic/cosmology'). Distinct from imbib_remove_tag, which detaches a tag from named papers without touching the vocabulary. Not undoable by imbib_undo (tag CRUD bypasses the operation log) — but it is trivially reversible by renaming back, as long as you remember the old path.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Existing tag path" },
        newPath: { type: "string", description: "New tag path" },
      },
      required: ["path", "newPath"],
    },
  },
  {
    name: "imbib_set_tag_color",
    description:
      "Set a tag's light and/or dark display colors (hex, e.g. '#336699'). Purely cosmetic — tag membership and hierarchy are untouched. To create a tag with colors in one step use imbib_create_tag.",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Tag path to recolor" },
        colorLight: { type: "string", description: "Hex color for light appearance" },
        colorDark: { type: "string", description: "Hex color for dark appearance" },
      },
      required: ["path"],
    },
  },
  {
    name: "imbib_delete_tag",
    description:
      "Delete a tag from the library vocabulary; it is detached from EVERY paper that carried it, including papers the user never mentioned. When they only want it off certain papers, use imbib_remove_tag instead — that IS undoable, this is not: tag CRUD bypasses the operation log, so imbib_undo cannot restore the tag or its memberships (verified live 2026-07-25). Check the blast radius first with imbib_count_papers (kind:'by-tag').",
    inputSchema: {
      type: "object",
      properties: {
        path: { type: "string", description: "Tag path to delete" },
      },
      required: ["path"],
    },
  },
  {
    name: "imbib_list_tags",
    description:
      "List tags in the library with their usage counts. Useful for finding existing tags before tagging papers. EXPENSIVE on a large library: imbib recomputes a count for every tag in the vocabulary (the prefix filter is applied after that), which on a few thousand tags takes minutes and blocks the app's UI while it runs. When you only need one number use imbib_count_papers (kind:'by-tag'); when you only need to attach a tag, just call imbib_add_tag, which creates missing tags on the fly.",
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
          description:
            "Library UUID from imbib_list_libraries. Nominally optional, but when the store has no library flagged as default the route fails with 'No library found to create collection in' — so pass it explicitly.",
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
      "Delete a collection. The papers inside it are NOT deleted — they stay in their libraries. The collection itself is gone for good, though: this route bypasses the operation log, so imbib_undo cannot restore it (verified live 2026-07-25). Only an earlier imbib_create_backup can.",
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
    name: "imbib_list_smart_searches",
    description:
      "List saved smart searches. Pass the Exploration library's ID to enumerate the rows of imbib's Exploration sidebar section.",
    inputSchema: {
      type: "object",
      properties: {
        libraryID: {
          type: "string",
          description: "Library UUID to scope the listing (optional; omit for all libraries)",
        },
      },
    },
  },
  {
    name: "imbib_get_smart_search",
    description:
      "Fetch one smart search by UUID: its query string, owning library, result cap, and its feeds-to-inbox / auto-refresh settings. Use to inspect or confirm a search before changing or deleting it; find the UUID with imbib_list_smart_searches.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Smart search UUID" },
      },
      required: ["id"],
    },
  },
  {
    name: "imbib_create_smart_search",
    description:
      "Save a query as a smart search (an Exploration sidebar row) in a library — the 'keep an eye on this topic' tool. To run a search ONCE without saving anything, use imbib_search_library (the local library) or imbib_search_sources (external databases) instead. feedsToInbox routes new hits into the user's Inbox and autoRefreshEnabled makes imbib re-run the query on a timer; both default OFF, so turn them on only when the user explicitly asks for an ongoing feed rather than a saved query. List with imbib_list_smart_searches, remove with imbib_delete_smart_searches.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Display name for the sidebar row" },
        query: {
          type: "string",
          description:
            "The saved query string (same syntax as imbib_search_sources, e.g. 'author:Abel star formation')",
        },
        libraryID: {
          type: "string",
          description:
            "UUID of the library that owns the search (from imbib_list_libraries; usually the 'Exploration' library)",
        },
        maxResults: {
          type: "number",
          description: "Cap on results the search keeps (default 100)",
        },
        feedsToInbox: {
          type: "boolean",
          description:
            "Route new hits into the Inbox (default false). Only enable when the user wants an ongoing feed.",
        },
        autoRefreshEnabled: {
          type: "boolean",
          description: "Re-run the query on a timer (default false)",
        },
        refreshIntervalSeconds: {
          type: "number",
          description: "Timer interval when autoRefreshEnabled (default 3600)",
        },
        sourceIDs: {
          type: "array",
          items: { type: "string" },
          description:
            "Optional list of source plugin ids to search (ads, arxiv, crossref, …). Omit for the user's defaults.",
        },
      },
      required: ["name", "query", "libraryID"],
    },
  },
  {
    name: "imbib_delete_smart_searches",
    description:
      "Delete one or more smart searches (Exploration sidebar rows). Only the search definitions are removed — papers they pulled into the library stay. The definitions themselves are not recoverable: this route bypasses the operation log, so imbib_undo cannot restore them (verified live 2026-07-25). Read one back with imbib_get_smart_search first if you might need to recreate it via imbib_create_smart_search.",
    inputSchema: {
      type: "object",
      properties: {
        identifiers: {
          type: "array",
          items: { type: "string" },
          description: "Smart search UUIDs to delete",
        },
      },
      required: ["identifiers"],
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
      "NOT AVAILABLE: library sharing between users is not implemented — this endpoint always returns a sharingUnavailable error. (Multi-device sync of your OWN library does exist; see ADR-0020.) Would list participants of a shared library.",
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
    name: "imbib_list_item_comments",
    description:
      "List comments on any item by UUID (publication, artifact, or other item type).",
    inputSchema: {
      type: "object",
      properties: {
        itemID: {
          type: "string",
          description: "UUID of the item to get comments for",
        },
      },
      required: ["itemID"],
    },
  },
  {
    name: "imbib_add_item_comment",
    description:
      "Add a comment to any item by UUID (publication, artifact, or other item type).",
    inputSchema: {
      type: "object",
      properties: {
        itemID: {
          type: "string",
          description: "UUID of the item to comment on",
        },
        text: {
          type: "string",
          description: "Comment text (supports markdown)",
        },
        parentCommentID: {
          type: "string",
          description: "Optional parent comment UUID for threaded replies",
        },
      },
      required: ["itemID", "text"],
    },
  },
  {
    name: "imbib_edit_comment",
    description: "Edit the text of an existing comment.",
    inputSchema: {
      type: "object",
      properties: {
        commentID: {
          type: "string",
          description: "UUID of the comment to edit",
        },
        text: {
          type: "string",
          description: "New comment text",
        },
      },
      required: ["commentID", "text"],
    },
  },
  // NOTE: imbib_sync_comments is gone. Its route (POST /api/sync/comments) was
  // deleted in 5400ae1 with the dead CloudKit comment stack — see the tombstone
  // at HTTPAutomationRouter.swift:857 — so every call 404'd. The live sync
  // surface is imbib_sync_status + imbib_sync_nudge below.
  {
    name: "imbib_sync_status",
    description:
      "Report imbib's CloudKit sync engine state — the same snapshot the app's Settings pane renders, so the two cannot disagree. The field to read first is reason_code: it is the machine-readable verdict for WHY sync is or is not running ('available', 'disabled_by_user', 'not_entitled', 'account_unavailable', 'lease_held_by_other', 'account_check_failed', 'unit_test_process'). Also reports enabled/available, engine_running, lease_holder (which impress app currently owns the sync lease), the queue depths outbox / pending_refs / tombstones (these accumulate even while sync is OFF, which is what makes turning it on later safe), bootstrap_done, last push/pull times, last_error, merge_report, container and zone. Use this to diagnose 'my change hasn't shown up on my phone'; use imbib_sync_nudge to actually push it. This is whole-library graph sync (ADR-0007 Phase 3) and has nothing to do with comment sync, which no longer exists.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "imbib_sync_nudge",
    description:
      "Ask imbib's sync engine for an immediate push+pull instead of waiting for its own schedule. THIS IS THE TOOL THAT DELIVERS YOUR WORK TO THE USER'S OTHER DEVICES: every change made through the other imbib tools lands in the local store first and only reaches their phone on the next sync pass. Call it after finishing a batch of edits, and whenever the user says 'send that to my phone' or 'why can't I see it yet'. Refusal is a normal answer, not an error — it reports accepted:false with a reason (sync off, not entitled, no iCloud account, another app holds the lease); imbib_sync_status gives the full diagnosis.",
    inputSchema: {
      type: "object",
      properties: {},
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
      "NOT AVAILABLE: library sharing between users is not implemented — this endpoint always returns a sharingUnavailable error. (Multi-device sync of your OWN library does exist; see ADR-0020.) Would share a library with collaborators.",
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
      "NOT AVAILABLE: library sharing between users is not implemented — this endpoint always returns a sharingUnavailable error. (Multi-device sync of your OWN library does exist; see ADR-0020.) Would stop sharing a library, or leave one you are participating in.",
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
      "NOT AVAILABLE: library sharing between users is not implemented — this endpoint always returns a sharingUnavailable error. (Multi-device sync of your OWN library does exist; see ADR-0020.) Would change a participant's permission level in a shared library.",
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
  // --------------------------------------------------------------------------
  // Research Artifact Operations
  // --------------------------------------------------------------------------
  {
    name: "imbib_create_artifact",
    description:
      "Create a research artifact in imbib. Artifacts are non-paper items: notes, webpages, datasets, presentations, posters, media, code, or general files.",
    inputSchema: {
      type: "object",
      properties: {
        type: {
          type: "string",
          enum: [
            "impress/artifact/presentation",
            "impress/artifact/poster",
            "impress/artifact/dataset",
            "impress/artifact/webpage",
            "impress/artifact/note",
            "impress/artifact/media",
            "impress/artifact/code",
            "impress/artifact/general",
          ],
          description:
            "The artifact type schema URI",
        },
        title: {
          type: "string",
          description: "Title of the artifact",
        },
        sourceURL: {
          type: "string",
          description: "Source URL (e.g., webpage URL)",
        },
        notes: {
          type: "string",
          description: "Free-form notes about the artifact",
        },
        tags: {
          type: "array",
          items: { type: "string" },
          description: 'Tags to apply (e.g., ["meeting-notes", "project/thesis"])',
        },
      },
      required: ["type", "title"],
    },
  },
  {
    name: "imbib_search_artifacts",
    description:
      "Search research artifacts by title, notes, or other metadata. Returns matching artifacts.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Search query (matches title, notes, source URL)",
        },
        type: {
          type: "string",
          description:
            "Optional type filter (e.g., 'impress/artifact/webpage')",
        },
      },
      required: ["query"],
    },
  },
  {
    name: "imbib_list_artifacts",
    description:
      "List research artifacts, optionally filtered by type. Returns recent artifacts sorted by creation date.",
    inputSchema: {
      type: "object",
      properties: {
        type: {
          type: "string",
          description:
            "Optional type filter (e.g., 'impress/artifact/note')",
        },
        limit: {
          type: "number",
          description: "Maximum number of results (default: 50)",
        },
        offset: {
          type: "number",
          description: "Pagination offset (default: 0)",
        },
      },
    },
  },
  {
    name: "imbib_get_artifact",
    description:
      "Get detailed information about a specific research artifact by ID.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Artifact UUID",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "imbib_delete_artifact",
    description:
      "Delete a research artifact. This permanently removes it.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Artifact UUID to delete",
        },
      },
      required: ["id"],
    },
  },
  {
    name: "imbib_tag_artifact",
    description:
      "Add a tag to a research artifact. Tags use hierarchical paths like 'project/thesis'.",
    inputSchema: {
      type: "object",
      properties: {
        id: {
          type: "string",
          description: "Artifact UUID",
        },
        tag: {
          type: "string",
          description: "Tag path to add",
        },
      },
      required: ["id", "tag"],
    },
  },
  {
    name: "imbib_link_artifact_to_paper",
    description:
      "Link a research artifact to a paper in the bibliography. Creates a bidirectional relationship.",
    inputSchema: {
      type: "object",
      properties: {
        artifactID: {
          type: "string",
          description: "Artifact UUID",
        },
        citeKey: {
          type: "string",
          description: "Cite key of the paper to link to",
        },
      },
      required: ["artifactID", "citeKey"],
    },
  },
  {
    name: "imbib_resolve_identifier",
    description:
      "Atomic citation resolution. One call cascades: local library → extract DOI/arXiv/bibcode from a BibTeX fragment → import if identifier found → external search (ADS / arXiv / Crossref) if nothing matches. Returns one of: 'local-identifier', 'local-search', 'local-search-ambiguous', 'imported-identifier', 'duplicate', 'external-candidates', or 'not-found'. Use this BEFORE imprint_insert_citation_in_section when starting from a query, DOI, arXiv id, or stub BibTeX — it gives you the cite key + BibTeX in one round-trip.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Free-form query — a title, author+year, DOI, arXiv id, or cite key. Optional if 'bibtex' is provided.",
        },
        bibtex: {
          type: "string",
          description: "BibTeX fragment. The server extracts DOI / arXiv / bibcode / PMID from it and uses that for the cascade.",
        },
        library: {
          type: "string",
          description: "Library UUID to add the paper to when it's imported. Optional — defaults to imbib's default library.",
        },
        downloadPDFs: {
          type: "boolean",
          description: "If true, imbib will also try to fetch the PDF after importing.",
        },
      },
    },
  },
  {
    name: "imbib_create_backup",
    description:
      "Create a library backup: a consistent SQLite snapshot of the entire shared impress store (papers, tags, collections, flags, manuscripts, annotations, artifacts), taken safely while imbib/imprint/impel keep writing. Portable — the file opens in plain sqlite3 with no impress software. Use before risky bulk operations (large imports, deduplication, mass tagging).",
    inputSchema: {
      type: "object",
      properties: {
        label: {
          type: "string",
          description: "Optional human label recorded in the manifest, e.g. 'before ADS bulk import'.",
        },
        directory: {
          type: "string",
          description: "Optional destination directory. Defaults to ~/Library/Application Support/imbib/Backups.",
        },
      },
    },
  },
  {
    name: "imbib_list_backups",
    description:
      "List library backups, newest first, with their creation time, label, item counts and size.",
    inputSchema: {
      type: "object",
      properties: {
        directory: {
          type: "string",
          description: "Optional directory to list. Defaults to the standard backups folder.",
        },
      },
    },
  },
  {
    name: "imbib_prune_backups",
    description:
      "Retention sweep: keep the N newest backups in a directory and delete the rest, along with their manifests. Use to stop imbib_create_backup snapshots accumulating. DESTRUCTIVE and NOT recoverable by imbib_undo — undo covers store rows, never files on disk. Run imbib_list_backups first and confirm the number with the user; keep:0 deletes every backup. To remove one specific snapshot instead, use imbib_delete_backup.",
    inputSchema: {
      type: "object",
      properties: {
        keep: {
          type: "number",
          description:
            "How many of the newest backups to retain. Everything older is deleted. 0 deletes all of them.",
        },
        directory: {
          type: "string",
          description:
            "Optional directory to prune. Defaults to the standard backups folder.",
        },
      },
      required: ["keep"],
    },
  },
  {
    name: "imbib_inspect_backup",
    description:
      "Validate a backup file without touching the live store: SQLite integrity check, required tables, and a SHA-256 match against its manifest. Returns valid=false plus reasons for a corrupt or tampered file. Always run this before imbib_restore_backup.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Absolute path of the .impressbackup file.",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "imbib_restore_backup",
    description:
      "DESTRUCTIVE. Replace the entire shared store (imbib AND imprint AND impel data) with a backup. The backup is validated first and the current state is snapshotted to a safety folder before anything changes. Refuses with code 'sync_enabled' while iCloud sync is on, because restored rows carry old clocks and other devices would overwrite them — turn sync off first rather than passing force. imbib must be relaunched afterwards. Ask the user to confirm before calling this.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Absolute path of the .impressbackup file to restore.",
        },
        force: {
          type: "boolean",
          description: "Restore even though iCloud sync is enabled. Only with explicit user consent — the restore may be overwritten by other devices.",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "imbib_delete_backup",
    description: "Delete one backup file and its JSON manifest sidecar.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Absolute path of the .impressbackup file.",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "imbib_list_templates",
    description:
      "List the available journal/conference manuscript templates, optionally filtered by category or search term. Use before creating a manuscript from a template to find the right template id. 25 templates ship built in, including: generic, mnras, apj, apjs, jcap, aa, araa, prd, prl, jhep, neurips, icml, jcp, nature, science, pnas, plos, elife, cell, nejm, lancet, bmj, jama, bioinformatics, naturemed.",
    inputSchema: {
      type: "object",
      properties: {
        category: {
          type: "string",
          description: "Filter by category: journal, conference, thesis, report, or custom.",
        },
        query: {
          type: "string",
          description: "Free-text search over template name, description and tags (e.g. 'astronomy', 'machine learning', 'Nature').",
        },
      },
    },
  },
  {
    name: "imbib_create_manuscript_from_template",
    description:
      "Start a new manuscript in a journal's required format (e.g. ApJ, MNRAS, Nature, NeurIPS). Use this instead of creating a blank manuscript whenever the user names a journal or conference. Pre-fills the template's page style, title block, authors/affiliations, abstract, keywords and — unless include_sections is false — the standard section skeleton. Find the template id with imbib_list_templates.",
    inputSchema: {
      type: "object",
      properties: {
        template_id: {
          type: "string",
          description: "Template id from imbib_list_templates (e.g. 'apj', 'mnras', 'neurips', 'generic').",
        },
        title: {
          type: "string",
          description: "Manuscript title.",
        },
        authors: {
          type: "array",
          items: { type: "string" },
          description: "Author names, in order.",
        },
        affiliations: {
          type: "array",
          items: { type: "string" },
          description: "Affiliations, in the order referenced by the authors.",
        },
        abstract: {
          type: "string",
          description: "Abstract text.",
        },
        keywords: {
          type: "array",
          items: { type: "string" },
          description: "Keywords / subject terms.",
        },
        include_sections: {
          type: "boolean",
          description: "Include the template's standard section skeleton (Introduction, Methods, ...). Default true.",
        },
      },
      required: ["template_id", "title"],
    },
  },
];

export class ImbibTools {
  constructor(private client: ImbibClient) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
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
      case "imbib_render_plot":
        return this.renderPlot(args);
      case "imbib_list_plot_specs":
        return this.listPlotSpecs();
      case "imbib_save_plot_spec":
        return this.savePlotSpec(args);
      case "imbib_save_plot_figure":
        return this.savePlotFigure(args);
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
      case "imbib_recent_papers":
        return this.recentPapers(args);
      case "imbib_recent_activity":
        return this.recentActivity(args);
      case "imbib_starred_papers":
        return this.starredPapers(args);
      case "imbib_count_papers":
        return this.countPapers(args);

      // Manuscripts (CAS-safe write path)
      case "imbib_list_manuscripts":
        return this.listManuscripts();
      case "imbib_get_manuscript":
        return this.getManuscript(args);
      case "imbib_create_manuscript":
        return this.createManuscript(args);
      case "imbib_write_manuscript_body":
        return this.writeManuscriptBody(args);
      case "imbib_compile_manuscript":
        return this.compileManuscript(args);

      // Undo
      case "imbib_recent_undo_groups":
        return this.recentUndoGroups(args);
      case "imbib_undo":
        return this.undo(args);

      // Tag vocabulary management
      case "imbib_create_tag":
        return this.createTag(args);
      case "imbib_rename_tag":
        return this.renameTag(args);
      case "imbib_set_tag_color":
        return this.setTagColor(args);
      case "imbib_delete_tag":
        return this.deleteTag(args);

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
      case "imbib_list_smart_searches":
        return this.listSmartSearches(args);
      case "imbib_get_smart_search":
        return this.getSmartSearch(args);
      case "imbib_create_smart_search":
        return this.createSmartSearch(args);
      case "imbib_delete_smart_searches":
        return this.deleteSmartSearches(args);
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
      case "imbib_list_item_comments":
        return this.listItemComments(args);
      case "imbib_add_item_comment":
        return this.addItemComment(args);
      case "imbib_edit_comment":
        return this.editComment(args);
      case "imbib_sync_status":
        return this.getSyncStatus();
      case "imbib_sync_nudge":
        return this.syncNudge();

      // Library backup & restore
      case "imbib_create_backup":
        return this.createBackup(args);
      case "imbib_list_backups":
        return this.listBackups(args);
      case "imbib_prune_backups":
        return this.pruneBackups(args);
      case "imbib_inspect_backup":
        return this.inspectBackup(args);
      case "imbib_restore_backup":
        return this.restoreBackup(args);
      case "imbib_delete_backup":
        return this.deleteBackup(args);
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

      // Artifact operations
      case "imbib_create_artifact":
        return this.createArtifact(args);
      case "imbib_search_artifacts":
        return this.searchArtifacts(args);
      case "imbib_list_artifacts":
        return this.listArtifactsHandler(args);
      case "imbib_get_artifact":
        return this.getArtifact(args);
      case "imbib_delete_artifact":
        return this.deleteArtifact(args);
      case "imbib_tag_artifact":
        return this.tagArtifact(args);
      case "imbib_link_artifact_to_paper":
        return this.linkArtifactToPaper(args);

      case "imbib_resolve_identifier":
        return this.resolveIdentifier(args);

      case "imbib_list_templates":
        return this.listTemplates(args);
      case "imbib_create_manuscript_from_template":
        return this.createManuscriptFromTemplate(args);

      default:
        return {
          content: [{ type: "text", text: `Unknown imbib tool: ${name}` }],
        };
    }
  }

  private async renderPlot(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const result = await this.client.renderPlotBody({
      spec: args?.spec,
      gridSpec: args?.gridSpec,
      specId: args?.specId,
    });
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
  }

  private async listPlotSpecs(): Promise<ToolResult> {
    const result = await this.client.listPlotSpecs();
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
  }

  private async savePlotSpec(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    if (!args?.name) {
      return { content: [{ type: "text", text: "Error: name is required" }] };
    }
    const result = await this.client.savePlotSpec(args as Record<string, unknown>);
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
  }

  private async savePlotFigure(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const manuscriptId = String(args?.manuscriptId || "");
    const spec = args?.spec;
    if (!manuscriptId || !spec || typeof spec !== "object") {
      return {
        content: [
          { type: "text", text: "Error: manuscriptId and spec are required" },
        ],
      };
    }
    const result = await this.client.savePlotFigure(
      manuscriptId,
      spec as Record<string, unknown>,
      args?.name ? String(args.name) : undefined
    );
    return { content: [{ type: "text", text: JSON.stringify(result) }] };
  }

  private async searchLibrary(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
    content: ToolContent[];
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
  ): Promise<ToolResult> {
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
    content: ToolContent[];
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
  ): Promise<ToolResult> {
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
    content: ToolContent[];
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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

  private async listSmartSearches(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const libraryID = args?.libraryID as string | undefined;
    const searches = await this.client.listSmartSearches(libraryID);
    if (searches.length === 0) {
      return { content: [{ type: "text", text: "No smart searches found" }] };
    }
    const lines = searches.map((s) => `- **${s.name}** (${s.id}): \`${s.query}\``);
    return {
      content: [
        {
          type: "text",
          text: `Found ${searches.length} smart search(es):\n\n${lines.join("\n")}`,
        },
      ],
    };
  }

  private async deleteSmartSearches(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const identifiers = args?.identifiers as string[] | undefined;
    if (!identifiers || identifiers.length === 0) {
      return {
        content: [{ type: "text", text: "Error: identifiers is required" }],
      };
    }
    const result = await this.client.deleteSmartSearches(identifiers);
    return {
      content: [
        { type: "text", text: `Deleted ${result.deleted} of ${identifiers.length} smart search(es)` },
      ],
    };
  }

  private async addToCollection(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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

  private async listItemComments(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const itemID = args?.itemID as string | undefined;
    if (!itemID) {
      return {
        content: [{ type: "text", text: "Error: itemID is required" }],
      };
    }

    const result = await this.client.listItemComments(itemID);
    if (!result.comments || result.comments.length === 0) {
      return {
        content: [{ type: "text", text: "No comments found for this item." }],
      };
    }

    const lines = result.comments.map((c: Record<string, unknown>) => {
      const replies = (c.replies as Array<Record<string, unknown>>) || [];
      const replyText = replies.length > 0
        ? `\n  ${replies.map((r: Record<string, unknown>) => `  ↳ ${r.authorDisplayName || "Unknown"}: ${r.text}`).join("\n  ")}`
        : "";
      return `• ${c.authorDisplayName || "Unknown"} (${c.dateCreated}): ${c.text}${replyText}`;
    });
    return {
      content: [
        {
          type: "text",
          text: `${result.total} comment(s):\n\n${lines.join("\n\n")}`,
        },
      ],
    };
  }

  private async addItemComment(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const itemID = args?.itemID as string | undefined;
    const text = args?.text as string | undefined;
    const parentCommentID = args?.parentCommentID as string | undefined;

    if (!itemID || !text) {
      return {
        content: [{ type: "text", text: "Error: itemID and text are required" }],
      };
    }

    const result = await this.client.addItemComment(itemID, text, parentCommentID);
    return {
      content: [
        {
          type: "text",
          text: `Comment added (ID: ${result.comment?.id || "unknown"})`,
        },
      ],
    };
  }

  private async editComment(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const commentID = args?.commentID as string | undefined;
    const text = args?.text as string | undefined;

    if (!commentID || !text) {
      return {
        content: [{ type: "text", text: "Error: commentID and text are required" }],
      };
    }

    const result = await this.client.editComment(commentID, text);
    return {
      content: [
        {
          type: "text",
          text: result.updated ? "Comment updated" : "Failed to update comment",
        },
      ],
    };
  }


  // -----------------------------------------------------------------------
  // Library backup & restore
  // -----------------------------------------------------------------------

  private async createBackup(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const backup = await this.client.createBackup({
      label: args?.label as string | undefined,
      directory: args?.directory as string | undefined,
    });
    const manifest = (backup.manifest ?? {}) as Record<string, unknown>;
    return {
      content: [
        {
          type: "text",
          text: [
            `Backup created: ${backup.filename}`,
            `Path: ${backup.path}`,
            `Items: ${manifest.contentItemCount} (${manifest.publicationCount} publications)`,
            `Size: ${manifest.sizeString}`,
            `SHA-256: ${manifest.sha256}`,
          ].join("\n"),
        },
      ],
    };
  }

  private async listBackups(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const result = await this.client.listBackups(args?.directory as string | undefined);
    if (result.backups.length === 0) {
      return {
        content: [{ type: "text", text: `No backups in ${result.directory}` }],
      };
    }
    const list = result.backups
      .map((b) => {
        const m = (b.manifest ?? {}) as Record<string, unknown>;
        const label = m.label ? ` — "${m.label}"` : "";
        return `- **${b.filename}**${label}\n  ${m.createdAt} · ${m.contentItemCount} items · ${m.sizeString}\n  ${b.path}`;
      })
      .join("\n");
    return {
      content: [
        {
          type: "text",
          text: `# Backups (${result.backups.length}) in ${result.directory}\n\n${list}`,
        },
      ],
    };
  }

  private async inspectBackup(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const path = args?.path as string | undefined;
    if (!path) {
      return { content: [{ type: "text", text: "Error: path is required" }] };
    }
    const result = await this.client.inspectBackup(path);
    const manifest = result.manifest as Record<string, unknown> | undefined;
    const issues = (result.issues as string[] | undefined) ?? [];
    const lines = [`Valid: ${result.valid}`];
    if (issues.length > 0) lines.push(`Issues: ${issues.join("; ")}`);
    if (manifest) {
      lines.push(
        `Created: ${manifest.createdAt}`,
        `App: ${manifest.app} ${manifest.appVersion}`,
        `Items: ${manifest.contentItemCount} (${manifest.publicationCount} publications)`,
        `Size: ${manifest.sizeString}`
      );
    }
    return { content: [{ type: "text", text: lines.join("\n") }] };
  }

  private async restoreBackup(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const path = args?.path as string | undefined;
    if (!path) {
      return { content: [{ type: "text", text: "Error: path is required" }] };
    }
    const result = await this.client.restoreBackup(path, (args?.force as boolean) ?? false);
    return {
      content: [
        {
          type: "text",
          text: [
            `Restored from ${path}`,
            `Items: ${result.itemCountBefore} → ${result.itemCountAfter}`,
            `Safety snapshot of the replaced state: ${result.safetySnapshot ?? "none"}`,
            `Sync bookkeeping cleared: ${result.clearedSyncState}`,
            "Relaunch imbib (and any running imprint/impel) so their caches match the restored database.",
          ].join("\n"),
        },
      ],
    };
  }

  private async deleteBackup(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const path = args?.path as string | undefined;
    if (!path) {
      return { content: [{ type: "text", text: "Error: path is required" }] };
    }
    const deleted = await this.client.deleteBackup(path);
    return {
      content: [
        { type: "text", text: deleted ? `Deleted ${path}` : `No backup at ${path}` },
      ],
    };
  }

  /**
   * Render the real ADR-0007 Phase-3 snapshot. `reason_code` leads because it
   * is the field that explains *why* nothing is syncing; the counters below it
   * are meaningful even when the engine is off.
   */
  private async getSyncStatus(): Promise<ToolResult> {
    const s = await this.client.getSyncStatus();
    const stamp = (ms?: number | null) =>
      ms ? new Date(ms).toISOString() : "never";

    const lines = [
      "# imbib sync (CloudKit graph sync, ADR-0007 Phase 3)",
      "",
      `**Verdict (reason_code):** ${s.reason_code}`,
      s.explanation ? `**Explanation:** ${s.explanation}` : "",
      "",
      `Enabled: ${s.enabled}   Available: ${s.available}   Engine running: ${s.engine_running ?? "unknown"}`,
      `Lease holder: ${s.lease_holder ?? "none"}   iCloud account: ${s.account_status ?? "unknown"}`,
      `Bootstrap done: ${s.bootstrap_done ?? "unknown"}`,
      `Last push: ${stamp(s.last_push_ms)}   Last pull: ${stamp(s.last_pull_ms)}`,
      "",
      "## Queues (these fill up even while sync is off)",
      `  Outbox: ${s.outbox ?? 0}   Pending refs: ${s.pending_refs ?? 0}   Tombstones: ${s.tombstones ?? 0}`,
      "",
      `Container: ${s.container ?? "?"}   Zone: ${s.zone ?? "?"}`,
      s.last_error ? `\n**Last error:** ${s.last_error}` : "",
      s.merge_report
        ? `\nMerge report: ${JSON.stringify(s.merge_report)}`
        : "",
      "",
      s.reason_code === "available"
        ? "Sync is healthy. Use imbib_sync_nudge to push pending work to the user's other devices now."
        : "Sync is NOT running — changes will stay on this device until the reason_code above is resolved.",
    ].filter((line) => line !== "");

    return text(lines.join("\n"));
  }

  private async syncNudge(): Promise<ToolResult> {
    const result = await this.client.syncNudge();
    if (result.accepted) {
      return text(
        "Sync pass requested — imbib is pushing local changes and pulling remote ones now.\n" +
          "It completes asynchronously; call imbib_sync_status and check last_push_ms / outbox to confirm it landed."
      );
    }
    return text(
      `Sync was NOT started: ${result.reason ?? "no reason given"}\n\n` +
        "This is a refusal, not a failure — the engine cannot run right now. " +
        "Call imbib_sync_status and read reason_code for the full diagnosis; " +
        "until it is resolved, changes stay on this device only."
    );
  }

  // --------------------------------------------------------------------------
  // Manuscripts
  // --------------------------------------------------------------------------

  private async listManuscripts(): Promise<ToolResult> {
    const rows = await this.client.listManuscripts();
    if (rows.length === 0) {
      return text("No manuscripts in the shared impress store.");
    }
    const lines = rows.map(
      (m) =>
        `- **${m.title}**\n  id: ${m.id}   format: ${m.format || "(unset)"}   status: ${m.status}`
    );
    return text(
      `# Manuscripts (${rows.length})\n\n${lines.join("\n")}\n\n` +
        "Read one with imbib_get_manuscript (returns body + contentHash for CAS writes)."
    );
  }

  private async getManuscript(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const id = args?.manuscriptId as string | undefined;
    if (!id) return text("Error: manuscriptId is required");

    const m = await this.client.getManuscript(id);
    if (!m) {
      return text(
        `No manuscript with id ${id}. Call imbib_list_manuscripts for valid UUIDs.`
      );
    }
    return text(
      [
        `# ${m.title}`,
        "",
        `id: ${m.id}`,
        `format: ${m.format || "(unset)"}   status: ${m.manuscriptStatus}`,
        `contentHash: ${m.contentHash ?? "null (no body has ever been written)"}`,
        m.bodyIsBlobRef ? "body is stored as a blob ref" : "",
        "",
        "Pass that contentHash as expectedHash to imbib_write_manuscript_body;",
        "it is what prevents your write from clobbering a concurrent edit.",
        "",
        "## Body",
        "",
        m.body,
      ]
        .filter((line) => line !== "")
        .join("\n")
    );
  }

  private async createManuscript(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const title = args?.title as string | undefined;
    if (!title) return text("Error: title is required");

    const created = await this.client.createManuscript({
      title,
      body: args?.body as string | undefined,
      format: args?.format as string | undefined,
      authors: args?.authors as string[] | undefined,
    });
    return text(
      `Created manuscript "${created.title}"\nid: ${created.id}\n\n` +
        "Read it with imbib_get_manuscript to obtain the contentHash before writing to it."
    );
  }

  /**
   * The CAS write. A 409 is reported as a normal (non-error) result with
   * explicit rebase instructions — an agent that retries the same hash, or
   * reaches for `unconditional`, destroys the user's concurrent edits.
   */
  private async writeManuscriptBody(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const id = args?.manuscriptId as string | undefined;
    const body = args?.body as string | undefined;
    const expectedHash = args?.expectedHash as string | undefined;
    const unconditional = args?.unconditional === true;

    if (!id) return text("Error: manuscriptId is required");
    if (typeof body !== "string") return text("Error: body is required");
    if (!expectedHash && !unconditional) {
      return text(
        "Refused: no expectedHash supplied.\n\n" +
          "Call imbib_get_manuscript first, edit the body it returns, and pass that call's " +
          "contentHash as expectedHash. Writing without a hash overwrites whatever is stored, " +
          "including edits the user just made on another device. If this manuscript genuinely " +
          "has no body yet (contentHash was null), pass unconditional:true."
      );
    }

    const result = await this.client.setManuscriptBody(id, body, expectedHash);

    if (result.notFound) {
      return text(
        `No manuscript with id ${id}. Call imbib_list_manuscripts for valid UUIDs.`
      );
    }

    if (result.conflict) {
      return text(
        [
          "CONFLICT — nothing was written.",
          "",
          `You sent expectedHash ${expectedHash}, but the manuscript's current hash is ${result.storedHash}.`,
          "Someone else changed the text after your read (the user typing on their phone, or another agent).",
          "",
          "Recover like this, in order:",
          "  1. imbib_get_manuscript to fetch the CURRENT body and contentHash.",
          "  2. Re-apply your intended edit to that new text — do not reuse the text you had.",
          "  3. imbib_write_manuscript_body again with the NEW contentHash.",
          "",
          "Do NOT retry with the same expectedHash (it will conflict again), and do NOT pass",
          "unconditional:true to force it through — that discards the other edit permanently.",
        ].join("\n")
      );
    }

    return text(
      `Manuscript body written.\nNew contentHash: ${result.newHash}\n\n` +
        "Use that hash for your next write. Verify the document still builds with imbib_compile_manuscript."
    );
  }

  /**
   * Compile + (by default) show page 1.
   *
   * The PDF base64 is deliberately never returned as text: it is not a valid
   * MCP image type and dumping it would spend enormous context to display
   * nothing. Instead the first page is rasterised to PNG so the result is
   * actually visible — which matters because when the user is on their phone
   * the conversation is the only display surface they have.
   */
  private async compileManuscript(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const id = args?.manuscriptId as string | undefined;
    if (!id) return text("Error: manuscriptId is required");
    const wantPreview = args?.preview !== false;

    const result = await this.client.compileManuscript(id, wantPreview);

    const cited = result.citedKeys ?? [];
    const resolved = result.resolvedKeys ?? [];
    const unresolved = cited.filter((k) => !resolved.includes(k));

    const lines: string[] = [
      result.status === "ok" ? "# Compile OK" : "# Compile FAILED",
      "",
    ];
    if (result.reason) lines.push(`Reason: ${result.reason}`, "");
    if (result.pdfBytes !== undefined) {
      lines.push(`PDF: ${result.pdfBytes.toLocaleString()} bytes`);
    }
    lines.push(
      `Citations: ${cited.length} cited, ${resolved.length} resolved against the imbib library`
    );
    if (unresolved.length > 0) {
      lines.push(
        `**Unresolved @keys (these will render as broken citations):** ${unresolved.join(", ")}`,
        "Add the missing papers with imbib_add_papers or imbib_resolve_identifier, then recompile."
      );
    }
    if (result.bibliographyBytes) {
      lines.push(`Virtual bibliography: ${result.bibliographyBytes} bytes`);
    }
    if (result.errors?.length) {
      lines.push("", "## Errors", ...result.errors.map((e) => `- ${e}`));
    }
    if (result.warnings?.length) {
      lines.push("", "## Warnings", ...result.warnings.map((w) => `- ${w}`));
    }

    if (wantPreview && result.pdfBase64) {
      // The PDF bytes are never returned as text: base64 is not a valid MCP
      // image type, so dumping it would spend enormous context and display
      // nothing. Rasterise page 1 instead (shared helper, PDFKit via JXA).
      const raster = await rasterizePDFPage(Buffer.from(result.pdfBase64, "base64"), {
        basename: `manuscript-${id}`,
      });
      if (raster.ok && isInlineable(raster.base64)) {
        return {
          content: [
            { type: "image", data: raster.base64, mimeType: "image/png" },
            {
              type: "text",
              text: [
                ...lines,
                "",
                `(image: page 1 of ${raster.pageCount}; full PDF staged at ${raster.pdfPath})`,
              ].join("\n"),
            },
          ],
        };
      }
      lines.push(
        "",
        raster.ok
          ? `(page-1 preview omitted: the raster exceeded the inline image budget. Full PDF: ${raster.pdfPath})`
          : `(page-1 preview unavailable: ${raster.error})`
      );
    }

    return text(lines.join("\n"));
  }

  // --------------------------------------------------------------------------
  // Undo
  // --------------------------------------------------------------------------

  private async recentUndoGroups(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const maxEntries = args?.maxEntries as number | undefined;
    const groups = await this.client.recentUndoGroups(maxEntries);
    if (groups.length === 0) {
      return text("No revertible operations recorded.");
    }
    const lines = groups.map((g) => {
      const when = new Date(g.timestamp).toISOString();
      const batch = g.batch_id ? `\n  batch_id: ${g.batch_id}  (prefer this)` : "";
      return `- ${g.description} (${g.operation_count} op${g.operation_count === 1 ? "" : "s"}, ${when})\n  operation_id: ${g.operation_id}${batch}`;
    });
    return text(
      `# Recent revertible operations (${groups.length}, newest first)\n\n${lines.join("\n")}\n\n` +
        "Reverse one with imbib_undo. Pass batchId when a group has one — it covers the whole user action."
    );
  }

  private async undo(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const operationId = args?.operationId as string | undefined;
    const batchId = args?.batchId as string | undefined;
    if (!operationId && !batchId) {
      return text(
        "Error: pass operationId or batchId (get them from imbib_recent_undo_groups; prefer batchId when present)."
      );
    }
    if (batchId) {
      const result = await this.client.undoBatch(batchId);
      // imbib answers 200 with a zero count for a batch id it has never seen,
      // so a count of 0 means "nothing matched", not "reverted successfully".
      if (result.operationCount === 0) {
        return text(
          `NOTHING was undone: no operations are recorded under batch ${batchId}. ` +
            "Either the id is wrong, or that action never reached the operation log " +
            "(deletes of papers/collections/smart-searches/tags are not recorded). " +
            "Call imbib_recent_undo_groups to see what is actually revertible."
        );
      }
      return text(
        `Reverted batch ${batchId} — ${result.operationCount} operation(s) undone.\n` +
          "Confirm with imbib_recent_undo_groups or by re-reading the affected records."
      );
    }
    const result = await this.client.undoOperation(operationId as string);
    if (result.operationCount === 0) {
      return text(
        `NOTHING was undone for operation ${operationId} — no inverse was applied. ` +
          "Call imbib_recent_undo_groups and confirm the id is still listed."
      );
    }
    return text(
      `Reverted operation ${operationId} — ${result.operationCount} operation(s) undone.\n` +
        "If the original action touched several rows, check imbib_recent_undo_groups for a batch_id and undo that instead."
    );
  }

  // --------------------------------------------------------------------------
  // Recent / starred / counts
  // --------------------------------------------------------------------------

  private async recentPapers(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const papers = await this.client.queryRecent({
      limit: args?.limit as number | undefined,
      parentID: args?.parentId as string | undefined,
    });
    if (papers.length === 0) return text("No recently added papers.");
    return text(
      `# Recently added (${papers.length})\n\n${this.formatRecentPapers(papers)}\n\n` +
        "This includes automated ingest. For what the USER actually touched, use imbib_recent_activity."
    );
  }

  private async recentActivity(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const papers = await this.client.queryRecentActivity({
      limit: args?.limit as number | undefined,
    });
    if (papers.length === 0) {
      return text(
        "No recent user activity recorded. (Papers arriving via feeds do not count as activity — try imbib_recent_papers.)"
      );
    }
    return text(
      `# Recent activity — what the user has been working on (${papers.length})\n\n${this.formatRecentPapers(papers)}`
    );
  }

  private async starredPapers(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const papers = await this.client.queryStarred({
      limit: args?.limit as number | undefined,
      parentID: args?.parentId as string | undefined,
    });
    if (papers.length === 0) return text("No starred papers.");
    return text(
      `# Starred papers (${papers.length})\n\n${this.formatRecentPapers(papers)}`
    );
  }

  private async countPapers(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const kind = args?.kind as
      | "unread"
      | "starred"
      | "flagged"
      | "by-tag"
      | undefined;
    if (!kind) {
      return text("Error: kind is required (unread | starred | flagged | by-tag)");
    }
    if (kind === "by-tag" && !args?.tag) {
      return text("Error: kind='by-tag' also requires tag (e.g. 'ai/field/cosmology')");
    }
    const count = await this.client.countPapers(kind, {
      parentID: args?.parentId as string | undefined,
      color: args?.color as string | undefined,
      tag: args?.tag as string | undefined,
    });
    const scope: string[] = [];
    if (args?.parentId) scope.push(`in ${args.parentId}`);
    if (kind === "flagged" && args?.color) scope.push(`color ${args.color}`);
    if (kind === "by-tag") scope.push(`tag '${args?.tag}'`);
    const suffix = scope.length ? ` (${scope.join(", ")})` : "";
    return text(`${count} ${kind} paper(s)${suffix}`);
  }

  /** Compact renderer for the snake_case rows the query routes return. */
  private formatRecentPapers(papers: RecentPaper[]): string {
    return papers
      .map((p) => {
        const bits: string[] = [];
        if (p.activity_kind) {
          bits.push(
            `${p.activity_kind}${p.activity_at ? ` ${new Date(p.activity_at).toISOString()}` : ""}`
          );
        }
        if (p.year) bits.push(String(p.year));
        if (p.venue) bits.push(p.venue);
        if (!p.is_read) bits.push("unread");
        if (p.is_starred) bits.push("starred");
        if (p.has_pdf) bits.push("PDF");
        const meta = bits.length ? `\n  ${bits.join(" · ")}` : "";
        const tags = p.tags.length ? `\n  tags: ${p.tags.join(", ")}` : "";
        return `- **${p.title}**\n  ${p.cite_key} — ${p.authors}${meta}${tags}`;
      })
      .join("\n");
  }

  // --------------------------------------------------------------------------
  // Smart search create / detail
  // --------------------------------------------------------------------------

  private async getSmartSearch(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const id = args?.id as string | undefined;
    if (!id) return text("Error: id is required");
    const s = await this.client.getSmartSearch(id);
    if (!s) {
      return text(
        `No smart search with id ${id}. Call imbib_list_smart_searches for valid UUIDs.`
      );
    }
    return text(this.formatSmartSearch(s));
  }

  private async createSmartSearch(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const name = args?.name as string | undefined;
    const query = args?.query as string | undefined;
    const libraryID = args?.libraryID as string | undefined;
    if (!name) return text("Error: name is required");
    if (typeof query !== "string") return text("Error: query is required");
    if (!libraryID) {
      return text(
        "Error: libraryID is required — get one from imbib_list_libraries (usually the 'Exploration' library)."
      );
    }
    const s = await this.client.createSmartSearch({
      name,
      query,
      libraryID,
      maxResults: args?.maxResults as number | undefined,
      feedsToInbox: args?.feedsToInbox as boolean | undefined,
      autoRefreshEnabled: args?.autoRefreshEnabled as boolean | undefined,
      refreshIntervalSeconds: args?.refreshIntervalSeconds as number | undefined,
      sourceIDs: args?.sourceIDs as string[] | undefined,
    });
    return text(`Created smart search.\n\n${this.formatSmartSearch(s)}`);
  }

  private formatSmartSearch(s: SmartSearch): string {
    return [
      `**${s.name}**`,
      `  id: ${s.id}`,
      `  query: ${s.query}`,
      `  library: ${s.library_id}`,
      `  max results: ${s.max_results ?? "?"}`,
      `  feeds to inbox: ${s.feeds_to_inbox ?? false}   auto refresh: ${s.auto_refresh_enabled ?? false}` +
        (s.auto_refresh_enabled
          ? ` (every ${s.refresh_interval_seconds ?? "?"}s)`
          : ""),
      s.source_ids?.length ? `  sources: ${s.source_ids.join(", ")}` : "",
    ]
      .filter((line) => line !== "")
      .join("\n");
  }

  // --------------------------------------------------------------------------
  // Tag vocabulary management
  // --------------------------------------------------------------------------

  private async createTag(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const path = args?.path as string | undefined;
    if (!path) return text("Error: path is required");
    await this.client.createTag({
      path,
      colorLight: args?.colorLight as string | undefined,
      colorDark: args?.colorDark as string | undefined,
    });
    return text(
      `Tag '${path}' created in the vocabulary. It is not on any paper yet — use imbib_add_tag for that.`
    );
  }

  private async renameTag(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const path = args?.path as string | undefined;
    const newPath = args?.newPath as string | undefined;
    if (!path || !newPath) return text("Error: path and newPath are required");
    await this.client.renameTag(path, newPath);
    return text(
      `Renamed tag '${path}' → '${newPath}' across the whole library.\n` +
        `imbib_undo does not cover tag CRUD — to reverse this, rename '${newPath}' back to '${path}'.`
    );
  }

  private async setTagColor(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const path = args?.path as string | undefined;
    if (!path) return text("Error: path is required");
    const colorLight = args?.colorLight as string | undefined;
    const colorDark = args?.colorDark as string | undefined;
    if (!colorLight && !colorDark) {
      return text("Error: pass colorLight and/or colorDark");
    }
    await this.client.updateTagColor(path, { colorLight, colorDark });
    return text(`Updated colors for tag '${path}'.`);
  }

  private async deleteTag(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const path = args?.path as string | undefined;
    if (!path) return text("Error: path is required");
    await this.client.deleteTag(path);
    return text(
      `Deleted tag '${path}' — it is now off every paper that carried it.\n` +
        "This is not undoable: tag CRUD bypasses the operation log, so imbib_undo cannot restore it. " +
        "Recreating the tag with imbib_create_tag does NOT restore which papers had it."
    );
  }

  private async pruneBackups(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const keep = args?.keep;
    if (typeof keep !== "number" || keep < 0 || !Number.isInteger(keep)) {
      return text("Error: keep must be a non-negative integer");
    }
    const removed = await this.client.pruneBackups(
      keep,
      args?.directory as string | undefined
    );
    if (removed.length === 0) {
      return text(`Nothing pruned — there were at most ${keep} backup(s) already.`);
    }
    return text(
      `Pruned ${removed.length} backup(s), keeping the ${keep} newest:\n` +
        removed.map((p) => `- ${p}`).join("\n") +
        "\n\nThese are gone from disk; imbib_undo cannot bring them back."
    );
  }

  private async listAssignments(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  // Artifact Operations
  // --------------------------------------------------------------------------

  private async createArtifact(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const artifactType = args?.type as string | undefined;
    const title = args?.title as string | undefined;

    if (!artifactType) {
      return {
        content: [{ type: "text", text: "Error: type is required" }],
      };
    }
    if (!title) {
      return {
        content: [{ type: "text", text: "Error: title is required" }],
      };
    }

    const artifact = await this.client.createArtifact(artifactType, title, {
      sourceURL: args?.sourceURL as string | undefined,
      notes: args?.notes as string | undefined,
      tags: args?.tags as string[] | undefined,
    });

    return {
      content: [
        {
          type: "text",
          text: `Created ${artifact.typeName} artifact: **${artifact.title}**\n\nID: ${artifact.id}`,
        },
      ],
    };
  }

  private async searchArtifacts(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const query = String(args?.query || "");
    if (!query) {
      return {
        content: [{ type: "text", text: "Error: query is required" }],
      };
    }

    const artifactType = args?.type as string | undefined;
    const artifacts = await this.client.listArtifacts({
      query,
      type: artifactType,
    });

    if (artifacts.length === 0) {
      return {
        content: [
          { type: "text", text: `No artifacts found matching "${query}"` },
        ],
      };
    }

    const list = this.formatArtifactList(artifacts);
    return {
      content: [
        {
          type: "text",
          text: `Found ${artifacts.length} artifacts matching "${query}":\n\n${list}`,
        },
      ],
    };
  }

  private async listArtifactsHandler(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const artifactType = args?.type as string | undefined;
    const limit = args?.limit as number | undefined;
    const offset = args?.offset as number | undefined;

    const artifacts = await this.client.listArtifacts({
      type: artifactType,
      limit: limit ?? 50,
      offset,
    });

    if (artifacts.length === 0) {
      const typeInfo = artifactType ? ` of type ${artifactType}` : "";
      return {
        content: [{ type: "text", text: `No artifacts found${typeInfo}` }],
      };
    }

    const list = this.formatArtifactList(artifacts);
    const typeInfo = artifactType ? ` (${artifactType})` : "";
    return {
      content: [
        {
          type: "text",
          text: `# Artifacts${typeInfo} (${artifacts.length})\n\n${list}`,
        },
      ],
    };
  }

  private async getArtifact(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const id = args?.id as string | undefined;
    if (!id) {
      return {
        content: [{ type: "text", text: "Error: id is required" }],
      };
    }

    const artifact = await this.client.getArtifact(id);
    if (!artifact) {
      return {
        content: [{ type: "text", text: `Artifact not found: ${id}` }],
      };
    }

    const info = [
      `# ${artifact.title}`,
      "",
      `**Type:** ${artifact.typeName}`,
      `**ID:** ${artifact.id}`,
      `**Created:** ${new Date(artifact.created).toLocaleString()}`,
      artifact.sourceURL ? `**Source:** ${artifact.sourceURL}` : null,
      artifact.originalAuthor ? `**Author:** ${artifact.originalAuthor}` : null,
      artifact.fileName ? `**File:** ${artifact.fileName}` : null,
      artifact.fileSize
        ? `**Size:** ${(artifact.fileSize / 1024).toFixed(1)} KB`
        : null,
      artifact.tags.length > 0
        ? `**Tags:** ${artifact.tags.join(", ")}`
        : null,
      "",
      artifact.notes ? `## Notes\n\n${artifact.notes}` : null,
    ]
      .filter(Boolean)
      .join("\n");

    return {
      content: [{ type: "text", text: info }],
    };
  }

  private async deleteArtifact(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const id = args?.id as string | undefined;
    if (!id) {
      return {
        content: [{ type: "text", text: "Error: id is required" }],
      };
    }

    const result = await this.client.deleteArtifact(id);
    return {
      content: [
        {
          type: "text",
          text: result.deleted
            ? "Artifact deleted"
            : "Artifact not found",
        },
      ],
    };
  }

  private async tagArtifact(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const id = args?.id as string | undefined;
    const tag = args?.tag as string | undefined;

    if (!id) {
      return {
        content: [{ type: "text", text: "Error: id is required" }],
      };
    }
    if (!tag) {
      return {
        content: [{ type: "text", text: "Error: tag is required" }],
      };
    }

    await this.client.tagArtifact(id, tag);
    return {
      content: [
        { type: "text", text: `Added tag "${tag}" to artifact ${id}` },
      ],
    };
  }

  private async linkArtifactToPaper(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const artifactID = args?.artifactID as string | undefined;
    const citeKey = args?.citeKey as string | undefined;

    if (!artifactID) {
      return {
        content: [{ type: "text", text: "Error: artifactID is required" }],
      };
    }
    if (!citeKey) {
      return {
        content: [{ type: "text", text: "Error: citeKey is required" }],
      };
    }

    await this.client.linkArtifactToPaper(artifactID, citeKey);
    return {
      content: [
        {
          type: "text",
          text: `Linked artifact ${artifactID} to paper ${citeKey}`,
        },
      ],
    };
  }

  private formatArtifactList(artifacts: Artifact[]): string {
    return artifacts
      .map((a) => {
        const tags =
          a.tags.length > 0 ? ` {${a.tags.join(", ")}}` : "";
        const source = a.sourceURL ? `\n  Source: ${a.sourceURL}` : "";
        const file = a.fileName ? `\n  File: ${a.fileName}` : "";
        const starred = a.isStarred ? " *" : "";
        const date = new Date(a.created).toLocaleDateString();
        return `- **${a.title}** [${a.typeName}]${starred} (${date})\n  ID: ${a.id}${source}${file}${tags}`;
      })
      .join("\n\n");
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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
  ): Promise<ToolResult> {
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

  private async resolveIdentifier(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const query = (args?.query as string | undefined) ?? "";
    const bibtex = (args?.bibtex as string | undefined) ?? "";
    if (!query.trim() && !bibtex.trim()) {
      return { content: [{ type: "text", text: "Error: provide at least 'query' or 'bibtex'" }] };
    }
    const result = await this.client.resolveIdentifier({
      query,
      bibtex,
      library: args?.library as string | undefined,
      downloadPDFs: args?.downloadPDFs as boolean | undefined,
    });
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  }

  // MARK: - Manuscript templates

  private async listTemplates(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const category = args?.category ? String(args.category) : undefined;
    const query = args?.query ? String(args.query) : undefined;
    try {
      const templates = await this.client.listTemplates({ category, query });
      if (templates.length === 0) {
        const filter = [
          category ? `category '${category}'` : "",
          query ? `query '${query}'` : "",
        ]
          .filter(Boolean)
          .join(" and ");
        return text(
          filter
            ? `No manuscript templates match ${filter}.`
            : "No manuscript templates available."
        );
      }
      // Group by category so the agent can scan for the right family fast.
      const byCategory = new Map<string, typeof templates>();
      for (const t of templates) {
        const key = t.category || "other";
        const bucket = byCategory.get(key);
        if (bucket) bucket.push(t);
        else byCategory.set(key, [t]);
      }
      const blocks = [...byCategory.entries()].map(([cat, group]) => {
        const lines = group.map((t) => {
          const desc = t.description ? ` — ${t.description}` : "";
          const publisher = t.journal?.publisher ? ` (${t.journal.publisher})` : "";
          return `- \`${t.id}\` · ${t.name}${publisher}${desc}`;
        });
        return `## ${cat}\n${lines.join("\n")}`;
      });
      return text(
        `# Manuscript templates (${templates.length})\n\n${blocks.join("\n\n")}\n\n` +
          `Create one with imbib_create_manuscript_from_template (template_id + title).`
      );
    } catch (e) {
      return text(
        `Error: list templates failed: ${e instanceof Error ? e.message : String(e)}`
      );
    }
  }

  private async createManuscriptFromTemplate(
    args: Record<string, unknown> | undefined
  ): Promise<ToolResult> {
    const templateId = String(args?.template_id || "");
    const title = String(args?.title || "");
    if (!templateId) {
      return text("Error: template_id is required (see imbib_list_templates)");
    }
    if (!title) {
      return text("Error: title is required");
    }
    try {
      const r = await this.client.createManuscriptFromTemplate({
        templateId,
        title,
        authors: args?.authors as string[] | undefined,
        affiliations: args?.affiliations as string[] | undefined,
        abstract: args?.abstract as string | undefined,
        keywords: args?.keywords as string[] | undefined,
        includeSections: args?.include_sections as boolean | undefined,
      });
      return text(
        `Created **${r.title}** from template \`${r.template_id}\`\n` +
          `manuscript id: ${r.id}\n` +
          (r.body_length !== undefined ? `body: ${r.body_length} characters\n` : "")
      );
    } catch (e) {
      return text(
        `Error: create manuscript from template failed: ${e instanceof Error ? e.message : String(e)}`
      );
    }
  }
}
