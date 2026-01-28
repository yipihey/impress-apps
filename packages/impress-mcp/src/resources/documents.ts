/**
 * MCP resource provider for imprint documents
 */

import type { Resource } from "@modelcontextprotocol/sdk/types.js";
import { ImprintClient } from "../imprint/client.js";

export class DocumentResources {
  constructor(private client: ImprintClient) {}

  /**
   * List available document resources.
   */
  async list(): Promise<Resource[]> {
    try {
      const status = await this.client.checkStatus();
      if (!status) return [];

      const docs = await this.client.listDocuments();

      // Return each open document as a resource
      const docResources: Resource[] = docs.documents.map((doc) => ({
        uri: `impress://imprint/documents/${doc.id}`,
        mimeType: "text/x-typst",
        name: doc.title,
        description: `imprint document (${doc.authors.join(", ") || "No authors"})`,
      }));

      // Also provide a summary resource
      return [
        {
          uri: "impress://imprint/documents",
          mimeType: "application/json",
          name: "Open Documents",
          description: `${status.openDocuments} currently open imprint documents`,
        },
        ...docResources,
      ];
    } catch {
      return [];
    }
  }

  /**
   * Read a document resource.
   */
  async read(
    uri: string
  ): Promise<{ contents: Array<{ uri: string; mimeType: string; text: string }> }> {
    const path = uri.replace("impress://imprint/", "");

    if (path === "documents") {
      return this.readDocumentList(uri);
    }

    if (path.startsWith("documents/")) {
      const docId = path.replace("documents/", "");
      return this.readDocument(uri, docId);
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

  private async readDocumentList(
    uri: string
  ): Promise<{ contents: Array<{ uri: string; mimeType: string; text: string }> }> {
    const docs = await this.client.listDocuments();

    const summary = {
      openDocuments: docs.count,
      documents: docs.documents.map((d) => ({
        id: d.id,
        title: d.title,
        authors: d.authors,
        modifiedAt: d.modifiedAt,
        citationCount: d.citationCount,
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

  private async readDocument(
    uri: string,
    docId: string
  ): Promise<{ contents: Array<{ uri: string; mimeType: string; text: string }> }> {
    const content = await this.client.getDocumentContent(docId);

    if (!content) {
      return {
        contents: [
          {
            uri,
            mimeType: "text/plain",
            text: `Document not found: ${docId}`,
          },
        ],
      };
    }

    // Return the Typst source as the main content
    return {
      contents: [
        {
          uri,
          mimeType: "text/x-typst",
          text: content.source,
        },
      ],
    };
  }
}
