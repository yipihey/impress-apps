/**
 * MCP tools for implore (data visualization)
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImploreClient } from "./client.js";

export const IMPLORE_TOOLS: Tool[] = [
  {
    name: "implore_get_status",
    description:
      "Check if implore is running and get basic status information.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "implore_list_datasets",
    description:
      "List all open datasets in implore. Returns basic info about each dataset including columns and row counts.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "implore_get_dataset",
    description:
      "Get detailed information about a specific dataset including column statistics.",
    inputSchema: {
      type: "object",
      properties: {
        dataset_id: {
          type: "string",
          description: "The dataset ID",
        },
      },
      required: ["dataset_id"],
    },
  },
  {
    name: "implore_list_figures",
    description:
      "List all figures in implore. Optionally filter by dataset.",
    inputSchema: {
      type: "object",
      properties: {
        dataset_id: {
          type: "string",
          description: "Optional: filter figures by dataset ID",
        },
      },
      required: [],
    },
  },
  {
    name: "implore_get_figure",
    description:
      "Get detailed information about a specific figure including its configuration.",
    inputSchema: {
      type: "object",
      properties: {
        figure_id: {
          type: "string",
          description: "The figure ID",
        },
      },
      required: ["figure_id"],
    },
  },
  {
    name: "implore_export_figure",
    description:
      "Export a figure as PNG, SVG, or PDF. Returns the figure data encoded appropriately.",
    inputSchema: {
      type: "object",
      properties: {
        figure_id: {
          type: "string",
          description: "The figure ID to export",
        },
        format: {
          type: "string",
          enum: ["png", "svg", "pdf"],
          description: "Export format (default: png)",
        },
        width: {
          type: "number",
          description: "Optional: custom width in pixels",
        },
        height: {
          type: "number",
          description: "Optional: custom height in pixels",
        },
        scale: {
          type: "number",
          description: "Optional: scale factor (e.g., 2 for retina)",
        },
      },
      required: ["figure_id"],
    },
  },
  {
    name: "implore_create_figure",
    description:
      "Create a new figure from a dataset. Specify the chart type and column mappings.",
    inputSchema: {
      type: "object",
      properties: {
        dataset_id: {
          type: "string",
          description: "The dataset to visualize",
        },
        type: {
          type: "string",
          enum: ["scatter", "line", "bar", "histogram", "heatmap", "box", "violin"],
          description: "Chart type",
        },
        x_column: {
          type: "string",
          description: "Column for X axis",
        },
        y_column: {
          type: "string",
          description: "Column for Y axis",
        },
        color_column: {
          type: "string",
          description: "Optional: column for color encoding",
        },
        title: {
          type: "string",
          description: "Optional: figure title",
        },
        name: {
          type: "string",
          description: "Optional: internal name for the figure",
        },
      },
      required: ["dataset_id", "type"],
    },
  },
  {
    name: "implore_get_logs",
    description:
      "Get log entries from implore for debugging and monitoring.",
    inputSchema: {
      type: "object",
      properties: {
        limit: {
          type: "number",
          description: "Maximum number of entries (default: 50)",
        },
        level: {
          type: "string",
          description: "Filter by log level (info, warning, error)",
        },
        category: {
          type: "string",
          description: "Filter by category",
        },
        search: {
          type: "string",
          description: "Search in log messages",
        },
      },
      required: [],
    },
  },
];

export class ImploreToolHandler {
  constructor(private client: ImploreClient) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      case "implore_get_status":
        return this.getStatus();
      case "implore_list_datasets":
        return this.listDatasets();
      case "implore_get_dataset":
        return this.getDataset(args);
      case "implore_list_figures":
        return this.listFigures(args);
      case "implore_get_figure":
        return this.getFigure(args);
      case "implore_export_figure":
        return this.exportFigure(args);
      case "implore_create_figure":
        return this.createFigure(args);
      case "implore_get_logs":
        return this.getLogs(args);
      default:
        return {
          content: [{ type: "text", text: `Unknown implore tool: ${name}` }],
        };
    }
  }

  private async getStatus(): Promise<{ content: Array<{ type: string; text: string }> }> {
    const status = await this.client.checkStatus();
    if (!status) {
      return {
        content: [{ type: "text", text: "implore is not running or not accessible" }],
      };
    }
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(status, null, 2),
        },
      ],
    };
  }

  private async listDatasets(): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.listDatasets();
    return {
      content: [
        {
          type: "text",
          text: JSON.stringify(result, null, 2),
        },
      ],
    };
  }

  private async getDataset(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const datasetId = args?.dataset_id as string;
    if (!datasetId) {
      return { content: [{ type: "text", text: "Error: dataset_id is required" }] };
    }
    const dataset = await this.client.getDataset(datasetId);
    if (!dataset) {
      return { content: [{ type: "text", text: `Dataset not found: ${datasetId}` }] };
    }
    return {
      content: [{ type: "text", text: JSON.stringify(dataset, null, 2) }],
    };
  }

  private async listFigures(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const datasetId = args?.dataset_id as string | undefined;
    const result = await this.client.listFigures(datasetId);
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  private async getFigure(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const figureId = args?.figure_id as string;
    if (!figureId) {
      return { content: [{ type: "text", text: "Error: figure_id is required" }] };
    }
    const figure = await this.client.getFigure(figureId);
    if (!figure) {
      return { content: [{ type: "text", text: `Figure not found: ${figureId}` }] };
    }
    return {
      content: [{ type: "text", text: JSON.stringify(figure, null, 2) }],
    };
  }

  private async exportFigure(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const figureId = args?.figure_id as string;
    const format = (args?.format as "png" | "svg" | "pdf") || "png";
    const width = args?.width as number | undefined;
    const height = args?.height as number | undefined;
    const scale = args?.scale as number | undefined;

    if (!figureId) {
      return { content: [{ type: "text", text: "Error: figure_id is required" }] };
    }

    const exported = await this.client.exportFigure(figureId, format, {
      width,
      height,
      scale,
    });
    return {
      content: [{ type: "text", text: JSON.stringify(exported, null, 2) }],
    };
  }

  private async createFigure(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const datasetId = args?.dataset_id as string;
    const type = args?.type as string;

    if (!datasetId || !type) {
      return {
        content: [{ type: "text", text: "Error: dataset_id and type are required" }],
      };
    }

    const figure = await this.client.createFigure(datasetId, {
      type: type as any,
      name: args?.name as string | undefined,
      xColumn: args?.x_column as string | undefined,
      yColumn: args?.y_column as string | undefined,
      colorColumn: args?.color_column as string | undefined,
      title: args?.title as string | undefined,
    });
    return {
      content: [{ type: "text", text: JSON.stringify(figure, null, 2) }],
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
    });
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }
}
