/**
 * MCP tool definitions for ADS / SciX
 *
 * These tools provide AI agents direct access to the NASA Astrophysics Data
 * System (ADS) and Science Explorer (SciX) APIs for searching, exporting,
 * and managing personal libraries.
 *
 * Credentials: set ADS_API_KEY (or SCIX_API_KEY) environment variable.
 * Keys are available at https://ui.adsabs.harvard.edu/user/settings/token
 * or https://scixplorer.org/user/settings/token
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ScixClient, type ScixPaper } from "./client.js";

// ============================================================================
// Tool Definitions
// ============================================================================

export const SCIX_TOOLS: Tool[] = [
  // --------------------------------------------------------------------------
  // Search
  // --------------------------------------------------------------------------
  {
    name: "scix_search",
    description:
      "Search the NASA ADS / SciX database for academic papers. Supports the full ADS query syntax: field qualifiers (author:, title:, abs:, year:, bibcode:, doi:), boolean operators (AND, OR, NOT), functional operators (citations(), references(), trending(), reviews(), similar()), and range queries. Returns papers with metadata including bibcodes which can be used for export and library management. Example queries: 'author:\"Einstein, A\" year:1905', 'abs:\"dark energy\" property:refereed year:2020-2024', 'citations(bibcode:2016PhRvL.116f1102A)'",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description:
            "ADS query string. Use field qualifiers like author:, title:, abs:, year:, bibcode:, doi:, property:refereed, database:astronomy",
        },
        rows: {
          type: "number",
          description: "Number of results to return (default: 20, max: 200)",
        },
        start: {
          type: "number",
          description: "Result offset for pagination (default: 0)",
        },
        sort: {
          type: "string",
          description:
            "Sort order, e.g. 'date desc', 'citation_count desc', 'score desc' (default: 'date desc')",
        },
      },
      required: ["query"],
    },
  },

  // --------------------------------------------------------------------------
  // Export
  // --------------------------------------------------------------------------
  {
    name: "scix_export_bibtex",
    description:
      "Export one or more papers as BibTeX given their ADS bibcodes. Use after scix_search to get the bibcodes. Returns the raw BibTeX string which can be added to a library or used directly in a Typst/LaTeX document.",
    inputSchema: {
      type: "object",
      properties: {
        bibcodes: {
          type: "array",
          items: { type: "string" },
          description: "List of ADS bibcodes to export (e.g. ['2016PhRvL.116f1102A'])",
        },
      },
      required: ["bibcodes"],
    },
  },

  // --------------------------------------------------------------------------
  // Related papers
  // --------------------------------------------------------------------------
  {
    name: "scix_get_references",
    description:
      "Get the reference list for a paper — i.e. papers cited BY this paper. Returns up to 200 results with metadata. Useful for exploring a paper's intellectual lineage.",
    inputSchema: {
      type: "object",
      properties: {
        bibcode: {
          type: "string",
          description: "ADS bibcode of the paper whose references to fetch",
        },
      },
      required: ["bibcode"],
    },
  },
  {
    name: "scix_get_citations",
    description:
      "Get the citation list for a paper — i.e. papers that cite THIS paper. Returns up to 200 results with metadata. Useful for finding follow-up work.",
    inputSchema: {
      type: "object",
      properties: {
        bibcode: {
          type: "string",
          description: "ADS bibcode of the paper whose citations to fetch",
        },
      },
      required: ["bibcode"],
    },
  },

  // --------------------------------------------------------------------------
  // Libraries
  // --------------------------------------------------------------------------
  {
    name: "scix_list_libraries",
    description:
      "List all personal ADS/SciX libraries (reading lists). Returns library metadata including IDs, names, descriptions, paper counts, and public/private status.",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "scix_get_library",
    description:
      "Get the contents of a specific ADS/SciX library. Returns library metadata and the list of bibcodes it contains.",
    inputSchema: {
      type: "object",
      properties: {
        library_id: {
          type: "string",
          description: "Library ID (from scix_list_libraries)",
        },
        rows: {
          type: "number",
          description: "Max number of papers to return (default: 100)",
        },
      },
      required: ["library_id"],
    },
  },
  {
    name: "scix_create_library",
    description:
      "Create a new ADS/SciX personal library. Optionally populate it with bibcodes immediately.",
    inputSchema: {
      type: "object",
      properties: {
        name: {
          type: "string",
          description: "Library name",
        },
        description: {
          type: "string",
          description: "Library description (optional)",
        },
        public: {
          type: "boolean",
          description: "Whether the library is publicly visible (default: false)",
        },
        bibcodes: {
          type: "array",
          items: { type: "string" },
          description: "Initial list of bibcodes to add (optional)",
        },
      },
      required: ["name"],
    },
  },
  {
    name: "scix_add_to_library",
    description:
      "Add papers (by bibcode) to an existing ADS/SciX library. Use scix_list_libraries to find the library_id.",
    inputSchema: {
      type: "object",
      properties: {
        library_id: {
          type: "string",
          description: "Library ID",
        },
        bibcodes: {
          type: "array",
          items: { type: "string" },
          description: "List of bibcodes to add",
        },
      },
      required: ["library_id", "bibcodes"],
    },
  },
  {
    name: "scix_remove_from_library",
    description:
      "Remove papers (by bibcode) from an ADS/SciX library.",
    inputSchema: {
      type: "object",
      properties: {
        library_id: {
          type: "string",
          description: "Library ID",
        },
        bibcodes: {
          type: "array",
          items: { type: "string" },
          description: "List of bibcodes to remove",
        },
      },
      required: ["library_id", "bibcodes"],
    },
  },
  {
    name: "scix_delete_library",
    description:
      "Permanently delete an ADS/SciX library. This cannot be undone. Requires owner permission.",
    inputSchema: {
      type: "object",
      properties: {
        library_id: {
          type: "string",
          description: "Library ID to delete",
        },
      },
      required: ["library_id"],
    },
  },
];

// ============================================================================
// Helper: format paper list
// ============================================================================

function formatPapers(papers: ScixPaper[], maxAbstractLen = 300): string {
  if (papers.length === 0) return "No results found.";
  return papers
    .map((p, i) => {
      const title = p.title?.[0] ?? "(no title)";
      const authors = p.author?.slice(0, 3).join("; ") ?? "";
      const authorSuffix = (p.author?.length ?? 0) > 3 ? " et al." : "";
      const year = p.year ?? "";
      const pub = p.pub ? ` — ${p.pub}` : "";
      const doi = p.doi?.[0] ? ` DOI:${p.doi[0]}` : "";
      const cites = p.citation_count !== undefined ? ` [${p.citation_count} citations]` : "";
      let abstract = "";
      if (p.abstract) {
        const trimmed = p.abstract.slice(0, maxAbstractLen);
        abstract = `\n  Abstract: ${trimmed}${p.abstract.length > maxAbstractLen ? "..." : ""}`;
      }
      return `${i + 1}. ${title}\n   ${authors}${authorSuffix} (${year})${pub}${doi}${cites}\n   Bibcode: ${p.bibcode}${abstract}`;
    })
    .join("\n\n");
}

// ============================================================================
// Tool Handler
// ============================================================================

export class ScixTools {
  constructor(private client: ScixClient) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }>; isError?: boolean }> {
    const a = args ?? {};
    const text = await this.dispatch(name, a);
    return { content: [{ type: "text", text }] };
  }

  private async dispatch(name: string, a: Record<string, unknown>): Promise<string> {
    switch (name) {
      case "scix_search": {
        const result = await this.client.search(String(a.query), {
          rows: a.rows !== undefined ? Number(a.rows) : 20,
          start: a.start !== undefined ? Number(a.start) : 0,
          sort: a.sort as string | undefined,
        });
        const { numFound, docs } = result.response;
        const header = `Found ${numFound.toLocaleString()} results${docs.length < numFound ? ` (showing ${docs.length})` : ""}:\n\n`;
        return header + formatPapers(docs);
      }

      case "scix_export_bibtex": {
        const bibcodes = a.bibcodes as string[];
        const bibtex = await this.client.exportBibTeX(bibcodes);
        return bibtex || "(empty response)";
      }

      case "scix_get_references": {
        const result = await this.client.getReferences(String(a.bibcode));
        const { numFound, docs } = result.response;
        const header = `${numFound} references for ${a.bibcode as string}${docs.length < numFound ? ` (showing ${docs.length})` : ""}:\n\n`;
        return header + formatPapers(docs);
      }

      case "scix_get_citations": {
        const result = await this.client.getCitations(String(a.bibcode));
        const { numFound, docs } = result.response;
        const header = `${numFound} citations for ${a.bibcode as string}${docs.length < numFound ? ` (showing ${docs.length})` : ""}:\n\n`;
        return header + formatPapers(docs);
      }

      case "scix_list_libraries": {
        const libraries = await this.client.listLibraries();
        if (libraries.length === 0) return "No libraries found.";
        return libraries
          .map(
            (lib) =>
              `• ${lib.name} (${lib.num_documents} papers)${lib.public ? " [public]" : ""}\n  ID: ${lib.id}\n  ${lib.description || "(no description)"}`
          )
          .join("\n\n");
      }

      case "scix_get_library": {
        const lib = await this.client.getLibrary(
          String(a.library_id),
          a.rows !== undefined ? Number(a.rows) : 100
        );
        const meta = lib.metadata;
        const header = `Library: ${meta.name} (${meta.num_documents} papers)\nID: ${meta.id}\n${meta.description || "(no description)"}\nPublic: ${meta.public}\n\n`;
        const papers = lib.solr?.response?.docs ?? [];
        if (papers.length === 0) {
          const bibcodes = lib.documents ?? [];
          if (bibcodes.length === 0) return header + "Empty library.";
          return header + `Bibcodes:\n${bibcodes.join("\n")}`;
        }
        return header + formatPapers(papers, 0);
      }

      case "scix_create_library": {
        const result = await this.client.createLibrary(
          String(a.name),
          a.description ? String(a.description) : "",
          a.public === true,
          Array.isArray(a.bibcodes) ? (a.bibcodes as string[]) : []
        );
        return `Created library "${result.name}" with ID: ${result.id}`;
      }

      case "scix_add_to_library": {
        const bibcodes = a.bibcodes as string[];
        await this.client.addToLibrary(String(a.library_id), bibcodes);
        return `Added ${bibcodes.length} paper(s) to library ${a.library_id as string}.`;
      }

      case "scix_remove_from_library": {
        const bibcodes = a.bibcodes as string[];
        await this.client.removeFromLibrary(String(a.library_id), bibcodes);
        return `Removed ${bibcodes.length} paper(s) from library ${a.library_id as string}.`;
      }

      case "scix_delete_library": {
        await this.client.deleteLibrary(String(a.library_id));
        return `Deleted library ${a.library_id as string}.`;
      }

      default:
        return `Unknown scix tool: ${name}`;
    }
  }
}
