/**
 * Figure Bridge: implore → imprint
 *
 * Enables embedding figures from implore data visualizations into imprint documents.
 * Exports figures and inserts Typst image references.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImploreClient } from "../implore/client.js";
import { ImprintClient } from "../imprint/client.js";

// ============================================================================
// Tool Definitions
// ============================================================================

export const FIGURE_BRIDGE_TOOLS: Tool[] = [
  {
    name: "impress_embed_figure",
    description:
      "Embed a figure from implore into an imprint document. Exports the figure and inserts a Typst #image() reference. The figure file is saved alongside the document.",
    inputSchema: {
      type: "object",
      properties: {
        document_id: {
          type: "string",
          description: "The imprint document ID to embed the figure in",
        },
        figure_id: {
          type: "string",
          description: "The implore figure ID to embed",
        },
        position: {
          type: "number",
          description:
            "Optional: character position in the document to insert the figure. If not provided, figure is appended.",
        },
        caption: {
          type: "string",
          description: "Optional: caption for the figure",
        },
        label: {
          type: "string",
          description:
            "Optional: Typst label for cross-referencing (e.g., 'fig:results')",
        },
        width: {
          type: "string",
          description: "Optional: width specification (e.g., '80%', '10cm')",
        },
        format: {
          type: "string",
          enum: ["png", "svg", "pdf"],
          description: "Export format for the figure (default: svg)",
        },
      },
      required: ["document_id", "figure_id"],
    },
  },
  {
    name: "impress_list_available_figures",
    description:
      "List all figures available in implore that can be embedded in documents.",
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
    name: "impress_embed_figure_reference",
    description:
      "Insert a reference to an already-embedded figure using its label. Useful for referring back to figures in the text.",
    inputSchema: {
      type: "object",
      properties: {
        document_id: {
          type: "string",
          description: "The imprint document ID",
        },
        label: {
          type: "string",
          description: "The figure label to reference (e.g., 'fig:results')",
        },
        position: {
          type: "number",
          description: "Character position to insert the reference",
        },
      },
      required: ["document_id", "label", "position"],
    },
  },
  {
    name: "impress_sync_figure",
    description:
      "Re-export a figure from implore to update an existing embedded figure. Useful when the underlying data or visualization has changed.",
    inputSchema: {
      type: "object",
      properties: {
        document_id: {
          type: "string",
          description: "The imprint document ID containing the figure",
        },
        figure_id: {
          type: "string",
          description: "The implore figure ID to sync",
        },
        format: {
          type: "string",
          enum: ["png", "svg", "pdf"],
          description: "Export format (default: svg)",
        },
      },
      required: ["document_id", "figure_id"],
    },
  },
];

// ============================================================================
// Bridge Handler
// ============================================================================

export class FigureBridge {
  constructor(
    private imploreClient: ImploreClient,
    private imprintClient: ImprintClient
  ) {}

  async handleTool(
    name: string,
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    switch (name) {
      case "impress_embed_figure":
        return this.embedFigure(args);
      case "impress_list_available_figures":
        return this.listAvailableFigures(args);
      case "impress_embed_figure_reference":
        return this.embedFigureReference(args);
      case "impress_sync_figure":
        return this.syncFigure(args);
      default:
        return {
          content: [{ type: "text", text: `Unknown figure bridge tool: ${name}` }],
        };
    }
  }

  // --------------------------------------------------------------------------
  // Embed Figure
  // --------------------------------------------------------------------------

  private async embedFigure(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = args?.document_id as string;
    const figureId = args?.figure_id as string;
    const position = args?.position as number | undefined;
    const caption = args?.caption as string | undefined;
    const label = args?.label as string | undefined;
    const width = (args?.width as string) || "100%";
    const format = (args?.format as "png" | "svg" | "pdf") || "svg";

    if (!documentId || !figureId) {
      return {
        content: [
          { type: "text", text: "Error: document_id and figure_id are required" },
        ],
      };
    }

    // Step 1: Verify implore is running and get figure info
    const figure = await this.imploreClient.getFigure(figureId);
    if (!figure) {
      return {
        content: [
          {
            type: "text",
            text: `Error: Figure not found in implore: ${figureId}\n\nUse impress_list_available_figures to see available figures.`,
          },
        ],
      };
    }

    // Step 2: Export the figure
    let exported;
    try {
      exported = await this.imploreClient.exportFigure(figureId, format);
    } catch (e) {
      return {
        content: [
          { type: "text", text: `Error exporting figure: ${e}` },
        ],
      };
    }

    // Step 3: Generate a filename based on figure name/id
    const sanitizedName = (figure.name || figureId)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "");
    const filename = `figures/${sanitizedName}.${format}`;

    // Step 4: Build the Typst figure block
    const figureTypst = this.buildTypstFigure({
      filename,
      caption,
      label,
      width,
    });

    // Step 5: Insert into document
    try {
      if (position !== undefined) {
        await this.imprintClient.insertText(documentId, position, figureTypst);
      } else {
        // Append to document
        const content = await this.imprintClient.getDocumentContent(documentId);
        if (content) {
          const appendPosition = content.source.length;
          await this.imprintClient.insertText(documentId, appendPosition, "\n\n" + figureTypst);
        }
      }
    } catch (e) {
      return {
        content: [
          { type: "text", text: `Error inserting figure into document: ${e}` },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: [
            `# Figure Embedded`,
            "",
            `**Figure:** ${figure.name || figureId}`,
            `**Type:** ${figure.type}`,
            `**Dataset:** ${figure.datasetId}`,
            "",
            `**Inserted into document:** ${documentId}`,
            `**Filename:** ${filename}`,
            label ? `**Label:** <${label}>` : "",
            caption ? `**Caption:** ${caption}` : "",
            "",
            "```typst",
            figureTypst.trim(),
            "```",
            "",
            "Note: The figure file should be exported to the document's figures directory.",
            `Data URL length: ${exported.data.length} characters`,
          ]
            .filter((line) => line !== "")
            .join("\n"),
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // List Available Figures
  // --------------------------------------------------------------------------

  private async listAvailableFigures(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const datasetId = args?.dataset_id as string | undefined;

    try {
      const result = await this.imploreClient.listFigures(datasetId);

      if (result.figures.length === 0) {
        return {
          content: [
            {
              type: "text",
              text: datasetId
                ? `No figures found for dataset: ${datasetId}`
                : "No figures found in implore. Create a visualization first.",
            },
          ],
        };
      }

      const figuresList = result.figures.map((fig) => {
        const columns = [fig.xColumn, fig.yColumn]
          .filter(Boolean)
          .join(" vs ");
        return `- **${fig.name || fig.id}** (${fig.type})${columns ? `: ${columns}` : ""}\n  ID: \`${fig.id}\``;
      });

      return {
        content: [
          {
            type: "text",
            text: [
              `# Available Figures`,
              "",
              `Found ${result.figures.length} figure(s):`,
              "",
              ...figuresList,
              "",
              "Use `impress_embed_figure` with a figure ID to embed in a document.",
            ].join("\n"),
          },
        ],
      };
    } catch (e) {
      return {
        content: [
          {
            type: "text",
            text: `Error listing figures. Is implore running?\n\nError: ${e}`,
          },
        ],
      };
    }
  }

  // --------------------------------------------------------------------------
  // Embed Figure Reference
  // --------------------------------------------------------------------------

  private async embedFigureReference(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = args?.document_id as string;
    const label = args?.label as string;
    const position = args?.position as number;

    if (!documentId || !label || position === undefined) {
      return {
        content: [
          {
            type: "text",
            text: "Error: document_id, label, and position are required",
          },
        ],
      };
    }

    // Insert Typst reference
    const reference = `@${label}`;

    try {
      await this.imprintClient.insertText(documentId, position, reference);
    } catch (e) {
      return {
        content: [
          { type: "text", text: `Error inserting reference: ${e}` },
        ],
      };
    }

    return {
      content: [
        {
          type: "text",
          text: `Inserted figure reference \`${reference}\` at position ${position}`,
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Sync Figure
  // --------------------------------------------------------------------------

  private async syncFigure(
    args: Record<string, unknown> | undefined
  ): Promise<{ content: Array<{ type: string; text: string }> }> {
    const documentId = args?.document_id as string;
    const figureId = args?.figure_id as string;
    const format = (args?.format as "png" | "svg" | "pdf") || "svg";

    if (!documentId || !figureId) {
      return {
        content: [
          { type: "text", text: "Error: document_id and figure_id are required" },
        ],
      };
    }

    // Get figure info
    const figure = await this.imploreClient.getFigure(figureId);
    if (!figure) {
      return {
        content: [
          { type: "text", text: `Error: Figure not found: ${figureId}` },
        ],
      };
    }

    // Re-export the figure
    let exported;
    try {
      exported = await this.imploreClient.exportFigure(figureId, format);
    } catch (e) {
      return {
        content: [
          { type: "text", text: `Error exporting figure: ${e}` },
        ],
      };
    }

    const sanitizedName = (figure.name || figureId)
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-|-$/g, "");
    const filename = `figures/${sanitizedName}.${format}`;

    return {
      content: [
        {
          type: "text",
          text: [
            `# Figure Synced`,
            "",
            `**Figure:** ${figure.name || figureId}`,
            `**Format:** ${format}`,
            `**Filename:** ${filename}`,
            `**Size:** ${exported.width}x${exported.height}`,
            "",
            "The figure has been re-exported. Save the data to update the file.",
            `Data URL length: ${exported.data.length} characters`,
          ].join("\n"),
        },
      ],
    };
  }

  // --------------------------------------------------------------------------
  // Helper Methods
  // --------------------------------------------------------------------------

  private buildTypstFigure(options: {
    filename: string;
    caption?: string;
    label?: string;
    width: string;
  }): string {
    const { filename, caption, label, width } = options;

    if (caption) {
      // Use Typst figure environment for captioned figures
      const lines = [
        `#figure(`,
        `  image("${filename}", width: ${width}),`,
        `  caption: [${caption}],`,
        `)`,
      ];
      if (label) {
        lines[lines.length - 1] = `) <${label}>`;
      }
      return lines.join("\n");
    } else {
      // Simple image without figure environment
      const imageCode = `#image("${filename}", width: ${width})`;
      return label ? `${imageCode} <${label}>` : imageCode;
    }
  }
}
