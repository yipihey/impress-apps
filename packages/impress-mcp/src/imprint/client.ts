/**
 * HTTP client for imprint API
 */

export interface Document {
  id: string;
  title: string;
  authors: string[];
  modifiedAt: string;
  createdAt: string;
  citationCount?: number;
  bibliography?: string[];
  linkedImbibManuscriptID?: string;
}

export interface DocumentContent {
  id: string;
  source: string;
  bibliography: Record<string, string>;
}

export interface ImprintStatus {
  status: string;
  app: string;
  version: string;
  port: number;
  openDocuments: number;
}

export interface DocumentListResponse {
  status: string;
  count: number;
  documents: Document[];
}

export interface OutlineItem {
  level: number;
  title: string;
  line: number;
  position: number;
}

export interface OutlineResponse {
  status: string;
  id: string;
  outline: OutlineItem[];
}

export interface Citation {
  citeKey: string;
  bibtex: string;
}

export interface BibliographyResponse {
  status: string;
  id: string;
  count: number;
  citations: Citation[];
}

export interface CitationUsage {
  citeKey: string;
  position: number;
  length: number;
}

export interface CitationUsagesResponse {
  status: string;
  id: string;
  usages: CitationUsage[];
}

export interface SearchMatch {
  position: number;
  length: number;
  text: string;
}

export interface SearchResponse {
  status: string;
  id: string;
  query: string;
  matchCount: number;
  matches: SearchMatch[];
}

export interface SearchOptions {
  regex?: boolean;
  caseSensitive?: boolean;
}

export interface LogEntry {
  id: string;
  timestamp: string;
  level: string;
  category: string;
  message: string;
}

export interface LogsResponse {
  status: string;
  data: {
    entries: LogEntry[];
    count: number;
    totalInStore: number;
  };
}

export interface LogsQueryOptions {
  limit?: number;
  offset?: number;
  level?: string;
  category?: string;
  search?: string;
  after?: string;
}

export class ImprintClient {
  constructor(private baseURL: string) {}

  /**
   * Check if imprint is running and accessible.
   */
  async checkStatus(): Promise<ImprintStatus | null> {
    try {
      const response = await fetch(`${this.baseURL}/api/status`, {
        signal: AbortSignal.timeout(2000),
      });
      if (!response.ok) return null;
      return (await response.json()) as ImprintStatus;
    } catch {
      return null;
    }
  }

  /**
   * List all open documents.
   */
  async listDocuments(): Promise<DocumentListResponse> {
    const response = await fetch(`${this.baseURL}/api/documents`);
    if (!response.ok) {
      throw new Error(`List documents failed: ${response.statusText}`);
    }
    return (await response.json()) as DocumentListResponse;
  }

  /**
   * Get a specific document's metadata.
   */
  async getDocument(id: string): Promise<Document | null> {
    const response = await fetch(`${this.baseURL}/api/documents/${id}`);
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get document failed: ${response.statusText}`);
    }
    const data = (await response.json()) as {
      status: string;
      document: Document;
    };
    return data.document;
  }

  /**
   * Get a document's source content.
   */
  async getDocumentContent(id: string): Promise<DocumentContent | null> {
    const response = await fetch(`${this.baseURL}/api/documents/${id}/content`);
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get content failed: ${response.statusText}`);
    }
    return (await response.json()) as DocumentContent;
  }

  /**
   * Create a new document.
   */
  async createDocument(options: {
    title?: string;
    source?: string;
  }): Promise<{ id: string; title: string }> {
    const response = await fetch(`${this.baseURL}/api/documents/create`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(options),
    });
    if (!response.ok) {
      throw new Error(`Create document failed: ${response.statusText}`);
    }
    const data = (await response.json()) as {
      status: string;
      id: string;
      title: string;
    };
    return { id: data.id, title: data.title };
  }

  /**
   * Trigger document compilation.
   */
  async compileDocument(id: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/api/documents/${id}/compile`, {
      method: "POST",
    });
    if (!response.ok) {
      throw new Error(`Compile failed: ${response.statusText}`);
    }
  }

  /**
   * Insert a citation into a document.
   */
  async insertCitation(
    id: string,
    citeKey: string,
    options: { bibtex?: string; position?: number } = {}
  ): Promise<void> {
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/insert-citation`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          citeKey,
          bibtex: options.bibtex,
          position: options.position,
        }),
      }
    );
    if (!response.ok) {
      throw new Error(`Insert citation failed: ${response.statusText}`);
    }
  }

  /**
   * Update document content.
   */
  async updateDocument(
    id: string,
    updates: { source?: string; title?: string }
  ): Promise<void> {
    const response = await fetch(`${this.baseURL}/api/documents/${id}/update`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(updates),
    });
    if (!response.ok) {
      throw new Error(`Update document failed: ${response.statusText}`);
    }
  }

  /**
   * Get document outline (headings structure).
   */
  async getOutline(id: string): Promise<OutlineResponse | null> {
    const response = await fetch(`${this.baseURL}/api/documents/${id}/outline`);
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get outline failed: ${response.statusText}`);
    }
    return (await response.json()) as OutlineResponse;
  }

  /**
   * Download compiled PDF as ArrayBuffer.
   */
  async getPDF(id: string): Promise<ArrayBuffer | null> {
    const response = await fetch(`${this.baseURL}/api/documents/${id}/pdf`);
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get PDF failed: ${response.statusText}`);
    }
    return await response.arrayBuffer();
  }

  /**
   * Get document bibliography.
   */
  async getBibliography(id: string): Promise<BibliographyResponse | null> {
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/bibliography`
    );
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get bibliography failed: ${response.statusText}`);
    }
    return (await response.json()) as BibliographyResponse;
  }

  /**
   * Get citation usages in document.
   */
  async getCitationUsages(id: string): Promise<CitationUsagesResponse | null> {
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/citations`
    );
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get citation usages failed: ${response.statusText}`);
    }
    return (await response.json()) as CitationUsagesResponse;
  }

  /**
   * Search for text in document.
   */
  async searchText(
    id: string,
    query: string,
    options: SearchOptions = {}
  ): Promise<SearchResponse | null> {
    const response = await fetch(`${this.baseURL}/api/documents/${id}/search`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query,
        regex: options.regex,
        caseSensitive: options.caseSensitive,
      }),
    });
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Search failed: ${response.statusText}`);
    }
    return (await response.json()) as SearchResponse;
  }

  /**
   * Replace text in document.
   */
  async replaceText(
    id: string,
    search: string,
    replacement: string,
    all: boolean = false
  ): Promise<void> {
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/replace`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ search, replacement, all }),
      }
    );
    if (!response.ok) {
      throw new Error(`Replace failed: ${response.statusText}`);
    }
  }

  /**
   * Insert text at position.
   */
  async insertText(id: string, position: number, text: string): Promise<void> {
    const response = await fetch(`${this.baseURL}/api/documents/${id}/insert`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ position, text }),
    });
    if (!response.ok) {
      throw new Error(`Insert failed: ${response.statusText}`);
    }
  }

  /**
   * Delete text range.
   */
  async deleteText(id: string, start: number, end: number): Promise<void> {
    const response = await fetch(`${this.baseURL}/api/documents/${id}/delete`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ start, end }),
    });
    if (!response.ok) {
      throw new Error(`Delete failed: ${response.statusText}`);
    }
  }

  /**
   * Add citation to document bibliography.
   */
  async addCitation(id: string, citeKey: string, bibtex: string): Promise<void> {
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/bibliography`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ citeKey, bibtex }),
      }
    );
    if (!response.ok) {
      throw new Error(`Add citation failed: ${response.statusText}`);
    }
  }

  /**
   * Remove citation from document bibliography.
   */
  async removeCitation(id: string, citeKey: string): Promise<void> {
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/bibliography/${encodeURIComponent(citeKey)}`,
      {
        method: "DELETE",
      }
    );
    if (!response.ok) {
      throw new Error(`Remove citation failed: ${response.statusText}`);
    }
  }

  /**
   * Update document metadata.
   */
  async updateMetadata(
    id: string,
    metadata: { title?: string; authors?: string[] }
  ): Promise<void> {
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/metadata`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(metadata),
      }
    );
    if (!response.ok) {
      throw new Error(`Update metadata failed: ${response.statusText}`);
    }
  }

  /**
   * Export document as LaTeX.
   */
  async exportLatex(id: string, template?: string): Promise<string> {
    const params = template ? `?template=${encodeURIComponent(template)}` : "";
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/export/latex${params}`
    );
    if (!response.ok) {
      throw new Error(`Export LaTeX failed: ${response.statusText}`);
    }
    return await response.text();
  }

  /**
   * Export document as plain text.
   */
  async exportText(id: string): Promise<string> {
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/export/text`
    );
    if (!response.ok) {
      throw new Error(`Export text failed: ${response.statusText}`);
    }
    return await response.text();
  }

  /**
   * Export document as Typst source with bibliography.
   */
  async exportTypst(
    id: string
  ): Promise<{ source: string; bibliography: Record<string, string> } | null> {
    const response = await fetch(
      `${this.baseURL}/api/documents/${id}/export/typst`
    );
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Export Typst failed: ${response.statusText}`);
    }
    const data = (await response.json()) as {
      status: string;
      id: string;
      source: string;
      bibliography: Record<string, string>;
    };
    return { source: data.source, bibliography: data.bibliography };
  }

  /**
   * Get log entries from imprint.
   */
  async getLogs(options: LogsQueryOptions = {}): Promise<LogsResponse> {
    const params = new URLSearchParams();
    if (options.limit !== undefined) params.set("limit", String(options.limit));
    if (options.offset !== undefined)
      params.set("offset", String(options.offset));
    if (options.level) params.set("level", options.level);
    if (options.category) params.set("category", options.category);
    if (options.search) params.set("search", options.search);
    if (options.after) params.set("after", options.after);

    const queryString = params.toString();
    const url = `${this.baseURL}/api/logs${queryString ? `?${queryString}` : ""}`;

    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Get logs failed: ${response.statusText}`);
    }
    return (await response.json()) as LogsResponse;
  }
}
