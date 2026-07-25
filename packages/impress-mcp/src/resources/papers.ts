/**
 * MCP resource provider for imbib papers
 */

import type { Resource } from "@modelcontextprotocol/sdk/types.js";
import { ImbibClient } from "../imbib/client.js";

/**
 * Shown when imbib is unreachable. Returning an empty list here (the old
 * behaviour) made the library silently vanish from the agent's view, which
 * reads as "the user has no papers" rather than "the app is closed".
 */
const IMBIB_DOWN =
  "imbib is not responding on its HTTP API, so the library cannot be read. " +
  "Ask the user to open imbib and enable Settings → General → Automation → " +
  "Enable HTTP Server. If IMBIB_BASE_URL points at their phone, imbib must be " +
  "open on the phone and reachable on the tailnet. This is a connectivity " +
  "problem, not an empty library — do not report the library as empty.";

export class PaperResources {
  constructor(private client: ImbibClient) {}

  /**
   * List available paper resources.
   */
  async list(): Promise<Resource[]> {
    try {
      const status = await this.client.checkStatus();
      if (!status) return [PaperResources.offlineResource()];

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
      return [PaperResources.offlineResource()];
    }
  }

  private static offlineResource(): Resource {
    return {
      uri: "impress://imbib/library",
      mimeType: "text/plain",
      name: "imbib Library (app not running)",
      description: IMBIB_DOWN,
    };
  }

  /**
   * Read a paper resource.
   *
   * `papers/{citeKey}` is also advertised as a resource template from the
   * server, since it is addressable but not enumerable.
   */
  async read(
    uri: string
  ): Promise<{ contents: Array<{ uri: string; mimeType: string; text: string }> }> {
    const path = uri.replace("impress://imbib/", "");

    try {
      if (path === "library") {
        return await this.readLibrary(uri);
      }

      if (path === "collections") {
        return await this.readCollections(uri);
      }

      if (path.startsWith("papers/")) {
        const citeKey = path.replace("papers/", "");
        return await this.readPaper(uri, citeKey);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        contents: [
          { uri, mimeType: "text/plain", text: `${IMBIB_DOWN}\n\nUnderlying error: ${message}` },
        ],
      };
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
