import { SharedStoreClient } from "./client.js";

export const SHARED_STORE_TOOLS = [
  {
    name: "impress_search_all",
    description: "Full-text search across ALL impress items (papers, emails, tasks, figures, manuscript sections). Returns results from any app that has written to the shared store.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search query" },
        schemas: {
          type: "array",
          items: { type: "string" },
          description: "Optional: filter by schema IDs (e.g. 'bibliography-entry@1.0.0', 'email-message@1.0.0')"
        },
        limit: { type: "number", description: "Max results (default 20)" }
      },
      required: ["query"]
    }
  },
  {
    name: "impress_get_item",
    description: "Fetch a specific item from the shared store by its UUID.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string", description: "Item UUID" }
      },
      required: ["id"]
    }
  },
  {
    name: "impress_get_related",
    description: "Get items related to a given item via edges (citations, attachments, etc.).",
    inputSchema: {
      type: "object",
      properties: {
        item_id: { type: "string", description: "Source item UUID" },
        edge_type: { type: "string", description: "Optional: filter by edge type (e.g. 'Cites', 'Attaches')" }
      },
      required: ["item_id"]
    }
  }
] as const;

export class SharedStoreTools {
  constructor(private client: SharedStoreClient) {}

  async handleTool(name: string, args: Record<string, unknown>): Promise<string> {
    switch (name) {
      case "impress_search_all": {
        const query = String(args.query ?? "");
        const schemas = Array.isArray(args.schemas) ? args.schemas.map(String) : undefined;
        const limit = typeof args.limit === "number" ? args.limit : 20;
        const results = this.client.searchItems(query, schemas, limit);
        if (results.length === 0) return "No items found matching the query.";
        return JSON.stringify(results, null, 2);
      }
      case "impress_get_item": {
        const id = String(args.id ?? "");
        const item = this.client.getItem(id);
        if (!item) return `No item found with ID: ${id}`;
        return JSON.stringify(item, null, 2);
      }
      case "impress_get_related": {
        const itemId = String(args.item_id ?? "");
        const edgeType = typeof args.edge_type === "string" ? args.edge_type : undefined;
        const edges = this.client.getEdges(itemId, edgeType);
        if (edges.length === 0) return `No related items found for ID: ${itemId}`;
        return JSON.stringify(edges, null, 2);
      }
      default:
        return `Unknown shared-store tool: ${name}`;
    }
  }
}
