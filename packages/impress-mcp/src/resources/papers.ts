/**
 * MCP resource provider for imbib papers
 */

import type { Resource } from "@modelcontextprotocol/sdk/types.js";
import { ImbibClient } from "../imbib/client.js";

export class PaperResources {
  constructor(private client: ImbibClient) {}

  /**
   * List available paper resources.
   */
  async list(): Promise<Resource[]> {
    try {
      const status = await this.client.checkStatus();
      if (!status) return [];

      // Provide a library resource
      return [
        {
          uri: "impress://imbib/library",
          mimeType: "application/json",
          name: "imbib Library",
          description: `Access to ${status.libraryCount} papers in the imbib library`,
        },
        {
          uri: "impress://imbib/collections",
          mimeType: "application/json",
          name: "imbib Collections",
          description: `${status.collectionCount} collections for organizing papers`,
        },
      ];
    } catch {
      return [];
    }
  }

  /**
   * Read a paper resource.
   */
  async read(
    uri: string
  ): Promise<{ contents: Array<{ uri: string; mimeType: string; text: string }> }> {
    const path = uri.replace("impress://imbib/", "");

    if (path === "library") {
      return this.readLibrary(uri);
    }

    if (path === "collections") {
      return this.readCollections(uri);
    }

    if (path.startsWith("papers/")) {
      const citeKey = path.replace("papers/", "");
      return this.readPaper(uri, citeKey);
    }

    return {
      contents: [
        {
          uri,
          mimeType: "text/plain",
          text: `Unknown resource: ${uri}`,
        },
      ],
    };
  }

  private async readLibrary(
    uri: string
  ): Promise<{ contents: Array<{ uri: string; mimeType: string; text: string }> }> {
    const result = await this.client.searchLibrary("", { limit: 100 });

    const summary = {
      totalPapers: result.count,
      papers: result.papers.map((p) => ({
        citeKey: p.citeKey,
        title: p.title,
        authors: p.authors,
        year: p.year,
        hasPDF: p.hasPDF,
        isStarred: p.isStarred,
      })),
    };

    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(summary, null, 2),
        },
      ],
    };
  }

  private async readCollections(
    uri: string
  ): Promise<{ contents: Array<{ uri: string; mimeType: string; text: string }> }> {
    const collections = await this.client.listCollections();

    const summary = {
      totalCollections: collections.length,
      collections: collections.map((c) => ({
        id: c.id,
        name: c.name,
        paperCount: c.paperCount,
        isSmartCollection: c.isSmartCollection,
      })),
    };

    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(summary, null, 2),
        },
      ],
    };
  }

  private async readPaper(
    uri: string,
    citeKey: string
  ): Promise<{ contents: Array<{ uri: string; mimeType: string; text: string }> }> {
    const paper = await this.client.getPaper(citeKey);

    if (!paper) {
      return {
        contents: [
          {
            uri,
            mimeType: "text/plain",
            text: `Paper not found: ${citeKey}`,
          },
        ],
      };
    }

    return {
      contents: [
        {
          uri,
          mimeType: "application/json",
          text: JSON.stringify(paper, null, 2),
        },
      ],
    };
  }
}
