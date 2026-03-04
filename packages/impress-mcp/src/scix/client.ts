/**
 * HTTP client for NASA ADS / SciX API
 *
 * Reads the API key from the ADS_API_KEY environment variable.
 * The ADS and SciX APIs share the same endpoint — the credential
 * determines which portal's branding is used.
 */

const ADS_BASE_URL = "https://api.adsabs.harvard.edu/v1";

// ============================================================================
// Types
// ============================================================================

export interface ScixPaper {
  bibcode: string;
  title?: string[];
  author?: string[];
  year?: string;
  pub?: string;
  doi?: string[];
  identifier?: string[];
  abstract?: string;
  citation_count?: number;
  read_count?: number;
  links_data?: string[];
}

export interface ScixSearchResponse {
  responseHeader: { status: number; QTime: number; params: Record<string, unknown> };
  response: { numFound: number; start: number; docs: ScixPaper[] };
}

export interface ScixLibrary {
  id: string;
  name: string;
  description: string;
  num_documents: number;
  owner: string;
  permission: string;
  public: boolean;
  date_created: string;
  date_last_modified: string;
}

export interface ScixLibraryDocument {
  metadata: ScixLibrary;
  solr: { response: { numFound: number; docs: ScixPaper[] } } | null;
  documents: string[];
}

// ============================================================================
// Client
// ============================================================================

export class ScixClient {
  private apiKey: string;

  constructor(apiKey: string) {
    this.apiKey = apiKey;
  }

  static fromEnv(): ScixClient | null {
    const key = process.env.ADS_API_KEY ?? process.env.SCIX_API_KEY;
    if (!key) return null;
    return new ScixClient(key);
  }

  private headers(): Record<string, string> {
    return {
      Authorization: `Bearer ${this.apiKey}`,
      "Content-Type": "application/json",
    };
  }

  private async request(
    path: string,
    options: { method?: string; body?: unknown } = {}
  ): Promise<unknown> {
    const url = `${ADS_BASE_URL}${path}`;
    const method = options.method ?? "GET";

    const init: RequestInit = {
      method,
      headers: this.headers(),
    };
    if (options.body !== undefined) {
      init.body = JSON.stringify(options.body);
    }

    const response = await fetch(url, init);
    if (!response.ok) {
      const text = await response.text().catch(() => "");
      throw new Error(`ADS API error ${response.status}: ${text}`);
    }
    return await response.json();
  }

  // --------------------------------------------------------------------------
  // Search
  // --------------------------------------------------------------------------

  async search(
    query: string,
    options: {
      fl?: string;
      rows?: number;
      start?: number;
      sort?: string;
    } = {}
  ): Promise<ScixSearchResponse> {
    const params = new URLSearchParams({ q: query });
    params.set(
      "fl",
      options.fl ??
        "bibcode,title,author,year,pub,doi,identifier,abstract,citation_count,read_count"
    );
    params.set("rows", String(options.rows ?? 20));
    params.set("start", String(options.start ?? 0));
    if (options.sort) params.set("sort", options.sort);

    return (await this.request(`/search/query?${params.toString()}`)) as ScixSearchResponse;
  }

  // --------------------------------------------------------------------------
  // Export
  // --------------------------------------------------------------------------

  async exportBibTeX(bibcodes: string[]): Promise<string> {
    const data = (await this.request("/export/bibtex", {
      method: "POST",
      body: { bibcode: bibcodes },
    })) as { export: string };
    return data.export;
  }

  async exportRIS(bibcodes: string[]): Promise<string> {
    const data = (await this.request("/export/ris", {
      method: "POST",
      body: { bibcode: bibcodes },
    })) as { export: string };
    return data.export;
  }

  // --------------------------------------------------------------------------
  // Related papers
  // --------------------------------------------------------------------------

  async getReferences(bibcode: string): Promise<ScixSearchResponse> {
    const query = `references(bibcode:${bibcode})`;
    return this.search(query, { rows: 200 });
  }

  async getCitations(bibcode: string): Promise<ScixSearchResponse> {
    const query = `citations(bibcode:${bibcode})`;
    return this.search(query, { rows: 200 });
  }

  // --------------------------------------------------------------------------
  // Libraries (biblib)
  // --------------------------------------------------------------------------

  async listLibraries(): Promise<ScixLibrary[]> {
    const data = (await this.request("/biblib/libraries")) as {
      libraries: ScixLibrary[];
    };
    return data.libraries;
  }

  async getLibrary(libraryID: string, rows = 100): Promise<ScixLibraryDocument> {
    const params = new URLSearchParams({
      fl: "bibcode,title,author,year",
      rows: String(rows),
    });
    return (await this.request(
      `/biblib/documents/${libraryID}?${params.toString()}`
    )) as ScixLibraryDocument;
  }

  async createLibrary(
    name: string,
    description = "",
    isPublic = false,
    bibcodes: string[] = []
  ): Promise<{ id: string; name: string }> {
    const data = (await this.request("/biblib/libraries", {
      method: "POST",
      body: { name, description, public: isPublic, bibcodes },
    })) as { id: string; name: string };
    return data;
  }

  async addToLibrary(libraryID: string, bibcodes: string[]): Promise<void> {
    await this.request(`/biblib/documents/${libraryID}`, {
      method: "POST",
      body: { action: "add", bibcode: bibcodes },
    });
  }

  async removeFromLibrary(libraryID: string, bibcodes: string[]): Promise<void> {
    await this.request(`/biblib/documents/${libraryID}`, {
      method: "POST",
      body: { action: "remove", bibcode: bibcodes },
    });
  }

  async deleteLibrary(libraryID: string): Promise<void> {
    await this.request(`/biblib/libraries/${libraryID}`, { method: "DELETE" });
  }
}
