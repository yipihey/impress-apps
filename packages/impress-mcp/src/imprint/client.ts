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
}
