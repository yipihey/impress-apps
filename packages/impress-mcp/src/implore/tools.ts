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

  // RG Volume Viewer Tools
  {
    name: "implore_rg_load",
    description:
      "Load an RG turbulence .npz file into implore's volume viewer. Returns dataset info (grid size, quantities, etc.).",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Absolute path to the .npz file",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "implore_rg_state",
    description:
      "Get the current RG viewer state including quantity, axis, position, colormap, and dataset info.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "implore_rg_control",
    description:
      "Change RG viewer parameters: quantity, axis, slice position, colormap. All fields are optional — only specified fields are changed.",
    inputSchema: {
      type: "object",
      properties: {
        quantity: {
          type: "string",
          description: "Derived quantity to visualize (e.g., velocity_magnitude, vorticity_magnitude)",
        },
        axis: {
          type: "string",
          enum: ["x", "y", "z"],
          description: "Slice axis",
        },
        position: {
          type: "number",
          description: "Slice position along the axis (0 to gridSize-1)",
        },
        colormap: {
          type: "string",
          description: "Colormap name (coolwarm, viridis, inferno, plasma, magma)",
        },
      },
      required: [],
    },
  },
  {
    name: "implore_rg_slice_png",
    description:
      "Export the current RG slice as a PNG image. Returns base64-encoded PNG data. Use implore_rg_slice_save to write to disk for visual inspection with Read tool.",
    inputSchema: {
      type: "object",
      properties: {
        format: {
          type: "string",
          enum: ["base64"],
          description: "Response format (default: base64 JSON)",
        },
      },
      required: [],
    },
  },
  {
    name: "implore_rg_slice_save",
    description:
      "Save the current RG slice as a PNG file to disk. Use this to export a slice, then use the Read tool to visually inspect the image.",
    inputSchema: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Absolute path to save the PNG file (e.g., /tmp/slice.png)",
        },
      },
      required: ["path"],
    },
  },
  {
    name: "implore_rg_slice_raw",
    description:
      "Get raw f32 values of the current or specified slice. Returns numeric array with min/max/mean/std statistics.",
    inputSchema: {
      type: "object",
      properties: {
        quantity: {
          type: "string",
          description: "Optional: override quantity",
        },
        axis: {
          type: "string",
          enum: ["x", "y", "z"],
          description: "Optional: override axis",
        },
        position: {
          type: "number",
          description: "Optional: override position",
        },
        downsample: {
          type: "number",
          description: "Optional: downsample factor (e.g., 4 to reduce 256x256 to 64x64)",
        },
      },
      required: [],
    },
  },
  {
    name: "implore_rg_statistics",
    description:
      "Get statistics (min, max, mean, std) for a 2D slice or entire 3D field volume.",
    inputSchema: {
      type: "object",
      properties: {
        quantity: {
          type: "string",
          description: "Optional: quantity name (defaults to current)",
        },
        scope: {
          type: "string",
          enum: ["slice", "field"],
          description: "Statistics scope: 'slice' for current 2D slice, 'field' for full 3D volume (default: slice)",
        },
      },
      required: [],
    },
  },
  {
    name: "implore_rg_batch",
    description:
      "Capture multiple slice positions at once. Returns array of {position, min, max, png_base64} without changing the viewer state.",
    inputSchema: {
      type: "object",
      properties: {
        positions: {
          type: "array",
          items: { type: "number" },
          description: "Array of slice positions to capture",
        },
        quantity: {
          type: "string",
          description: "Optional: quantity name",
        },
        axis: {
          type: "string",
          enum: ["x", "y", "z"],
          description: "Optional: slice axis",
        },
        colormap: {
          type: "string",
          description: "Optional: colormap name",
        },
      },
      required: ["positions"],
    },
  },
  {
    name: "implore_rg_colormaps",
    description:
      "List available colormap names for the RG viewer.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },

  // 1D Plot Tools
  {
    name: "implore_plot_series",
    description:
      "Plot one or more named 1D data series as a line chart (SVG). Returns SVG string. Data series come from loaded .npz files — use implore_rg_state to see available series names.",
    inputSchema: {
      type: "object",
      properties: {
        series: {
          type: "array",
          items: { type: "string" },
          description: "Array of data series names to plot (from RgDatasetInfo.dataSeriesNames)",
        },
        title: {
          type: "string",
          description: "Optional: plot title",
        },
      },
      required: ["series"],
    },
  },
  {
    name: "implore_rg_cascade_plot",
    description:
      "Generate the canonical cascade statistics plot (mu vs cascade level). Returns SVG string. Only works if the loaded .npz has cascade statistics.",
    inputSchema: {
      type: "object",
      properties: {},
      required: [],
    },
  },
  {
    name: "implore_plot_histogram",
    description:
      "Plot a histogram of a 3D field's value distribution. Returns SVG string with automatic binning, KDE overlay, and statistics.",
    inputSchema: {
      type: "object",
      properties: {
        quantity: {
          type: "string",
          description: "Derived quantity name (e.g., velocity_magnitude, vorticity_magnitude). Defaults to current viewer quantity.",
        },
        bins: {
          type: "number",
          description: "Number of bins (0 or omit for automatic Freedman-Diaconis binning)",
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
      // RG viewer tools
      case "implore_rg_load":
        return this.rgLoad(args);
      case "implore_rg_state":
        return this.rgState();
      case "implore_rg_control":
        return this.rgControl(args);
      case "implore_rg_slice_png":
        return this.rgSlicePng(args);
      case "implore_rg_slice_save":
        return this.rgSliceSave(args);
      case "implore_rg_slice_raw":
        return this.rgSliceRaw(args);
      case "implore_rg_statistics":
        return this.rgStatistics(args);
      case "implore_rg_batch":
        return this.rgBatch(args);
      case "implore_rg_colormaps":
        return this.rgColormaps();
      // 1D Plot tools
      case "implore_plot_series":
        return this.plotSeries(args);
      case "implore_rg_cascade_plot":
        return this.rgCascadePlot();
      case "implore_plot_histogram":
        return this.plotHistogram(args);
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

  // RG Viewer Tool Handlers

  private async rgLoad(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const path = args?.path as string;
    if (!path) {
      return { content: [{ type: "text", text: "Error: path is required" }] };
    }
    const result = await this.client.rgLoad(path);
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  private async rgState(): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.rgGetState();
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  private async rgControl(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.rgControl({
      quantity: args?.quantity as string | undefined,
      axis: args?.axis as string | undefined,
      position: args?.position as number | undefined,
      colormap: args?.colormap as string | undefined,
    });
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  private async rgSlicePng(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.rgSlicePng(args?.format as string);
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  private async rgSliceSave(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const path = args?.path as string;
    if (!path) {
      return { content: [{ type: "text", text: "Error: path is required" }] };
    }
    const result = await this.client.rgSliceSave(path);
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  private async rgSliceRaw(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.rgSliceRaw({
      quantity: args?.quantity as string | undefined,
      axis: args?.axis as string | undefined,
      position: args?.position as number | undefined,
      downsample: args?.downsample as number | undefined,
    });
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  private async rgStatistics(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.rgStatistics({
      quantity: args?.quantity as string | undefined,
      scope: args?.scope as string | undefined,
    });
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  private async rgBatch(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const positions = args?.positions as number[];
    if (!positions || !Array.isArray(positions)) {
      return { content: [{ type: "text", text: "Error: positions (array) is required" }] };
    }
    const result = await this.client.rgBatch({
      positions,
      quantity: args?.quantity as string | undefined,
      axis: args?.axis as string | undefined,
      colormap: args?.colormap as string | undefined,
    });
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  private async rgColormaps(): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.rgColormaps();
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
    };
  }

  // 1D Plot Tool Handlers

  private async plotSeries(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const series = args?.series as string[];
    if (!series || !Array.isArray(series) || series.length === 0) {
      return { content: [{ type: "text", text: "Error: series (non-empty array of strings) is required" }] };
    }
    const title = (args?.title as string) || undefined;
    const result = await this.client.plotSeries(series, title);
    return {
      content: [{ type: "text", text: result }],
    };
  }

  private async rgCascadePlot(): Promise<{ content: Array<{ type: string; text: string }> }> {
    const result = await this.client.rgCascadePlot();
    return {
      content: [{ type: "text", text: result }],
    };
  }

  private async plotHistogram(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const quantity = args?.quantity as string | undefined;
    const bins = args?.bins as number | undefined;
    const result = await this.client.plotHistogram(quantity, bins);
    return {
      content: [{ type: "text", text: result }],
    };
  }
}
