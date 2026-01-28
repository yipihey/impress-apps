/**
 * HTTP client for imbib API
 */

export interface Paper {
  id: string;
  citeKey: string;
  title: string;
  authors: string[];
  year?: number;
  venue?: string;
  abstract?: string;
  doi?: string;
  arxivID?: string;
  bibtex: string;
  isRead: boolean;
  isStarred: boolean;
  hasPDF: boolean;
  citationCount?: number;
  webURL?: string;
  pdfURLs?: string[];
  dateAdded: string;
  dateModified: string;
}

export interface Collection {
  id: string;
  name: string;
  paperCount: number;
  isSmartCollection: boolean;
  libraryID?: string;
  libraryName?: string;
}

export interface ImbibStatus {
  status: string;
  version: string;
  libraryCount: number;
  collectionCount: number;
  serverPort: number;
}

export interface SearchResponse {
  status: string;
  query: string;
  count: number;
  limit: number;
  offset: number;
  papers: Paper[];
}

export interface ExportResponse {
  status: string;
  format: string;
  paperCount: number;
  content: string;
}

export class ImbibClient {
  constructor(private baseURL: string) {}

  /**
   * Check if imbib is running and accessible.
   */
  async checkStatus(): Promise<ImbibStatus | null> {
    try {
      const response = await fetch(`${this.baseURL}/api/status`, {
        signal: AbortSignal.timeout(2000),
      });
      if (!response.ok) return null;
      return (await response.json()) as ImbibStatus;
    } catch {
      return null;
    }
  }

  /**
   * Search the library for papers.
   */
  async searchLibrary(
    query: string,
    options: { limit?: number; offset?: number } = {}
  ): Promise<SearchResponse> {
    const params = new URLSearchParams({ q: query });
    if (options.limit) params.set("limit", String(options.limit));
    if (options.offset) params.set("offset", String(options.offset));

    const response = await fetch(
      `${this.baseURL}/api/search?${params.toString()}`
    );
    if (!response.ok) {
      throw new Error(`Search failed: ${response.statusText}`);
    }
    return (await response.json()) as SearchResponse;
  }

  /**
   * Get a specific paper by cite key.
   */
  async getPaper(citeKey: string): Promise<Paper | null> {
    const response = await fetch(
      `${this.baseURL}/api/papers/${encodeURIComponent(citeKey)}`
    );
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get paper failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; paper: Paper };
    return data.paper;
  }

  /**
   * Export papers as BibTeX.
   */
  async exportBibTeX(citeKeys: string[]): Promise<ExportResponse> {
    const params = new URLSearchParams({
      keys: citeKeys.join(","),
      format: "bibtex",
    });

    const response = await fetch(
      `${this.baseURL}/api/export?${params.toString()}`
    );
    if (!response.ok) {
      throw new Error(`Export failed: ${response.statusText}`);
    }
    return (await response.json()) as ExportResponse;
  }

  /**
   * List all collections.
   */
  async listCollections(): Promise<Collection[]> {
    const response = await fetch(`${this.baseURL}/api/collections`);
    if (!response.ok) {
      throw new Error(`List collections failed: ${response.statusText}`);
    }
    const data = (await response.json()) as {
      status: string;
      count: number;
      collections: Collection[];
    };
    return data.collections;
  }
}
