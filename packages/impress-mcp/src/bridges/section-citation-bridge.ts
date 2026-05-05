/**
 * Section Citation Bridge: imbib ←→ imprint (token-efficient)
 *
 * One tool that does what the old multi-step dance used to: resolve a
 * query/DOI via imbib (local → identifier add → external cascade), then
 * insert the citation inside a specific imprint section — all in one call.
 *
 * This is the recommended way for agents to cite a paper today.
 */

import type { Tool } from "@modelcontextprotocol/sdk/types.js";
import { ImbibClient } from "../imbib/client.js";
import { ImprintClient } from "../imprint/client.js";

export const SECTION_CITATION_TOOLS: Tool[] = [
  {
    name: "impress_cite_in_section",
    description:
      "Atomic end-to-end citation flow. Given a query/DOI/arXiv id and a target imprint section, (1) asks imbib to resolve it — local library → identifier-based import → external sources — (2) inserts `@citeKey` inside the section, (3) adds the BibTeX entry to the document's bibliography. Returns the resolved paper plus the imprint operationId. If the resolution is ambiguous (multiple candidates), the paper is NOT cited automatically — candidates are returned for the agent to disambiguate.",
    inputSchema: {
      type: "object",
      properties: {
        query: {
          type: "string",
          description: "Title, author+year, DOI, arXiv id, or cite key.",
        },
        bibtex: {
          type: "string",
          description: "BibTeX fragment (optional) — used to extract an identifier when no direct one is given.",
        },
        documentId: {
          type: "string",
          description: "imprint document UUID.",
        },
        sectionKey: {
          type: "string",
          description: "Section UUID (from imprint_get_outline_v2) or integer index.",
        },
        position: {
          type: "number",
          description: "Character offset within the section body (0 = right after heading). Omit to append.",
        },
        libraryId: {
          type: "string",
          description: "imbib library UUID to add the paper to if a fetch is needed.",
        },
        wait: {
          type: "boolean",
          description: "If true, block until the insertion operation is applied before returning (default true).",
        },
      },
      required: ["query", "documentId", "sectionKey"],
    },
  },
];

export class SectionCitationBridge {
  constructor(
    private imbib: ImbibClient,
    private imprint: ImprintClient
  ) {}

  async handleTool(name: string, args: Record<string, unknown> | undefined) {
    if (name !== "impress_cite_in_section") {
      return { content: [{ type: "text", text: `Unknown tool: ${name}` }], isError: true };
    }
    const query = String(args?.query ?? "").trim();
    const bibtex = String(args?.bibtex ?? "").trim();
    const documentId = String(args?.documentId ?? "").trim();
    const sectionKey = String(args?.sectionKey ?? "").trim();
    if (!documentId || !sectionKey) {
      return err("documentId and sectionKey are required");
    }
    if (!query && !bibtex) {
      return err("provide at least one of 'query' or 'bibtex'");
    }
    const wait = (args?.wait as boolean | undefined) ?? true;

    const resolved = await this.imbib.resolveIdentifier({
      query,
      bibtex,
      library: args?.libraryId as string | undefined,
    });

    // Not an auto-citable path — return candidates for the agent to handle.
    if (
      resolved.via === "external-candidates" ||
      resolved.via === "local-search-ambiguous" ||
      resolved.via === "not-found"
    ) {
      return textBlock(`Did not auto-cite — ${resolved.via}.\n\n${JSON.stringify(resolved, null, 2)}`);
    }

    const paper = (resolved.paper ?? {}) as { citeKey?: string; bibtex?: string };
    if (!paper.citeKey) {
      return textBlock(`Resolver returned \`${resolved.via}\` but no paper payload:\n${JSON.stringify(resolved, null, 2)}`);
    }

    const insertResp = await this.imprint.insertCitationInSection(documentId, sectionKey, {
      citeKey: paper.citeKey,
      bibtex: paper.bibtex,
      position: args?.position as number | undefined,
    });

    let finalStatus = insertResp;
    if (wait && insertResp.operationId) {
      const status = await this.imprint.waitForOperation(insertResp.operationId, 5000);
      finalStatus = { ...insertResp, ...status } as typeof insertResp;
    }

    return textBlock(
      `Cited @${paper.citeKey} in document ${documentId} section ${sectionKey} (via ${resolved.via}).\n\n` +
        JSON.stringify({ resolved, imprint: finalStatus }, null, 2)
    );
  }
}

function textBlock(text: string): { content: Array<{ type: string; text: string }> } {
  return { content: [{ type: "text", text }] };
}

function err(msg: string): { content: Array<{ type: string; text: string }>; isError: boolean } {
  return { content: [{ type: "text", text: `Error: ${msg}` }], isError: true };
}
