/**
 * HTTP client for imbib API
 */

export interface Flag {
  color: string;  // "red"|"amber"|"blue"|"gray"
  style: string;  // "solid"|"dashed"|"dotted"
  length: string; // "full"|"half"|"quarter"
}

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
  tags?: string[];
  flag?: Flag | null;
  collectionIDs?: string[];
  libraryIDs?: string[];
  notes?: string;
  annotationCount?: number;
}

export interface Collection {
  id: string;
  name: string;
  paperCount: number;
  isSmartCollection: boolean;
  libraryID?: string;
  libraryName?: string;
}

/** A saved query. In the Exploration library these are the sidebar's Exploration rows. */
export interface SmartSearch {
  id: string;
  name: string;
  query: string;
  library_id: string;
  max_results?: number;
  feeds_to_inbox?: boolean;
  auto_refresh_enabled?: boolean;
  refresh_interval_seconds?: number;
  source_ids?: string[];
}

export interface Library {
  id: string;
  name: string;
  paperCount: number;
  collectionCount: number;
  isDefault: boolean;
  isInbox: boolean;
  isShared: boolean;
  isShareOwner: boolean;
  participantCount: number;
  canEdit: boolean;
}

export interface Participant {
  id: string;
  displayName?: string;
  email?: string;
  permission: "readOnly" | "readWrite";
  isOwner: boolean;
  status: "accepted" | "pending" | "removed";
}

export interface Activity {
  id: string;
  activityType: string;
  actorDisplayName?: string;
  targetTitle?: string;
  targetID?: string;
  detail?: string;
  date: string;
}

export interface Comment {
  id: string;
  text: string;
  authorDisplayName?: string;
  authorIdentifier?: string;
  dateCreated: string;
  dateModified: string;
  parentCommentID?: string;
  replies: Comment[];
}

export interface Assignment {
  id: string;
  publicationID: string;
  publicationTitle?: string;
  publicationCiteKey?: string;
  assigneeName?: string;
  assignedByName?: string;
  note?: string;
  dateCreated: string;
  dueDate?: string;
  libraryID?: string;
}

export interface Annotation {
  id: string;
  type: string;  // "highlight" | "underline" | "strikethrough" | "note" | "freeText" | "ink"
  pageNumber: number;
  contents?: string;
  selectedText?: string;
  color: string;  // Hex color string e.g. "#FFFF00"
  author?: string;
  dateCreated: string;
  dateModified: string;
}

export interface Artifact {
  id: string;
  type: string;   // e.g. "impress/artifact/webpage"
  typeName: string;  // e.g. "Web Page"
  title: string;
  isRead: boolean;
  isStarred: boolean;
  created: string;
  tags: string[];
  sourceURL?: string;
  notes?: string;
  fileName?: string;
  fileSize?: number;
  fileMimeType?: string;
  originalAuthor?: string;
  captureContext?: string;
  eventName?: string;
  flagColor?: string;
}

export interface ShareResult {
  libraryID: string;
  shareURL?: string;
  isShared: boolean;
}

export interface Tag {
  id: string;
  name: string;
  canonicalPath: string;
  parentPath?: string;
  useCount: number;
  publicationCount: number;
}

export interface AddPapersResponse {
  status: string;
  added: Paper[];
  duplicates: string[];
  failed: Record<string, string>;
}

export interface DownloadResponse {
  status: string;
  downloaded: string[];
  alreadyHad: string[];
  failed: Record<string, string>;
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

export interface ExternalSearchResult {
  title: string;
  authors: string[];
  year?: number;
  venue: string;
  abstract: string;
  sourceID: string;
  identifier: string;
  doi?: string;
  arxivID?: string;
  bibcode?: string;
}

export interface ExternalSearchResponse {
  status: string;
  query: string;
  source: string;
  count: number;
  results: ExternalSearchResult[];
}

export interface ExportResponse {
  status: string;
  format: string;
  paperCount: number;
  content: string;
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

/** A row of `GET /api/manuscripts` — metadata only, never the body. */
export interface ManuscriptSummary {
  id: string;
  title: string;
  format: string;   // "typst" | "latex" | "" (unset)
  status: string;   // "draft" | …
}

/**
 * `GET /api/manuscripts/{id}`. `contentHash` is the CAS cookie: it must be
 * handed back to `setManuscriptBody` for the write to be accepted.
 */
export interface ManuscriptDetail {
  id: string;
  title: string;
  format: string;
  manuscriptStatus: string;
  body: string;
  contentHash: string | null;
  bodyIsBlobRef: boolean;
}

/**
 * Outcome of a compare-and-set body write. `conflict` means the stored hash
 * moved under us and NOTHING was written — re-read, rebase, retry.
 */
export interface ManuscriptWriteResult {
  applied: boolean;
  conflict: boolean;
  newHash?: string;
  storedHash?: string;
  notFound?: boolean;
}

/** `POST /api/manuscripts/{id}/compile`. */
export interface ManuscriptCompileResult {
  status: string;           // "ok" | "error"
  pdfBytes?: number;
  citedKeys?: string[];     // @keys found in the source
  resolvedKeys?: string[];  // subset that matched a library entry
  bibliographyBytes?: number;
  warnings?: string[];
  errors?: string[];
  reason?: string;
  pdfBase64?: string;       // only when include_pdf was requested
}

/** A revertible store operation from `GET /api/undo/recent`. */
export interface UndoGroup {
  operation_id: string;
  operation_count: number;
  description: string;
  timestamp: number;   // epoch milliseconds
  batch_id?: string;   // present when the action spanned several operations
}

/**
 * The snake_case paper shape returned by imbib's recent/starred/query routes
 * (`bibToDict`). Deliberately NOT the camelCase `Paper` above — these routes
 * return a lighter row and never include BibTeX.
 */
export interface RecentPaper {
  id: string;
  cite_key: string;
  title: string;
  authors: string;    // one pre-joined string, not an array
  is_read: boolean;
  is_starred: boolean;
  has_pdf: boolean;
  tags: string[];
  year?: number;
  venue?: string;
  doi?: string;
  arxiv_id?: string;
  flag_color?: string;
  activity_kind?: string;  // recent-activity only: "viewed" | "added"
  activity_at?: number;    // recent-activity only: epoch milliseconds
}

/**
 * `GET /api/sync/status` — the ADR-0007 Phase-3 CloudKit engine snapshot.
 * `reason_code` is the machine-readable verdict that explains WHY sync is or
 * is not running.
 */
export interface SyncStatus {
  enabled: boolean;
  available: boolean;
  reason_code: string;   // available | disabled_by_user | not_entitled |
                         // account_unavailable | lease_held_by_other |
                         // account_check_failed | unit_test_process
  explanation?: string;
  account_status?: string | null;
  lease_holder?: string | null;
  engine_running?: boolean;
  last_push_ms?: number | null;
  last_pull_ms?: number | null;
  outbox?: number;
  pending_refs?: number;
  tombstones?: number;
  bootstrap_done?: boolean;
  merge_report?: Record<string, unknown> | null;
  last_error?: string | null;
  container?: string;
  zone?: string;
}

/**
 * Thrown when imbib answers 401/403. Distinct from a generic failure so
 * callers that otherwise swallow errors (`checkStatus`) can still surface it:
 * a stale `IMBIB_TOKEN` used to show up as `"Search failed: Unauthorized"`,
 * which tells the agent nothing about the fix.
 */
export class ImbibAuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ImbibAuthError";
  }
}

export class ImbibClient {
  constructor(
    private baseURL: string,
    private authToken?: string
  ) {}

  /**
   * fetch with the bearer token injected when configured (remote/tailnet
   * targets — e.g. imbib on the user's iPhone). Local no-token behavior
   * is unchanged.
   *
   * 401/403 is turned into an `ImbibAuthError` here rather than at each of
   * the ~40 call sites, so every tool reports the same actionable fix. This
   * is the failure mode of the phone workflow: the token is per-device and
   * is regenerated whenever Network Access is toggled.
   */
  private async authFetch(url: string | URL, init?: RequestInit): Promise<Response> {
    const response = await (this.authToken
      ? fetch(url, {
          ...(init ?? {}),
          headers: {
            ...((init?.headers as Record<string, string>) ?? {}),
            Authorization: `Bearer ${this.authToken}`,
          },
        })
      : fetch(url, init));

    if (response.status === 401 || response.status === 403) {
      throw new ImbibAuthError(
        `imbib at ${this.baseURL} rejected this request as unauthorized (HTTP ${response.status}). ` +
          (this.authToken
            ? "A bearer token WAS sent, so it is wrong or expired — tokens are regenerated whenever Network Access is toggled off and on. "
            : "NO bearer token was sent, but this imbib requires one. ") +
          "Fix: on the device serving that URL, open imbib → Settings → Automation API → Network Access, " +
          "copy the current access token, and set IMBIB_TOKEN in the MCP server's environment " +
          "(IMBIB_BASE_URL must point at the same device). Restart the MCP server afterwards."
      );
    }
    return response;
  }

  /**
   * Best-effort detail from a non-OK response body, appended to error text.
   * imbib's error payloads use `error` or `reason`; falling back to raw text
   * still beats `response.statusText` alone.
   */
  private async errorDetail(response: Response): Promise<string> {
    try {
      const body = await response.text();
      if (!body) return "";
      try {
        const parsed = JSON.parse(body) as Record<string, unknown>;
        const message = parsed.error ?? parsed.reason ?? parsed.message;
        if (typeof message === "string") return ` — ${message}`;
      } catch {
        /* not JSON; fall through to raw text */
      }
      return ` — ${body.slice(0, 300)}`;
    } catch {
      return "";
    }
  }

  /** Build a failure Error carrying status code and server-side detail. */
  private async failure(op: string, response: Response): Promise<Error> {
    return new Error(
      `${op} failed: HTTP ${response.status} ${response.statusText}${await this.errorDetail(response)}`
    );
  }

  /**
   * Render a native plot spec to SVG (impress-plot via imbib's Rust core).
   */
  async renderPlot(spec: Record<string, unknown>): Promise<unknown> {
    return this.renderPlotBody({ spec });
  }

  /**
   * Render with a full body: {spec} | {gridSpec} | {specId}.
   */
  async renderPlotBody(body: Record<string, unknown>): Promise<unknown> {
    const response = await this.authFetch(`${this.baseURL}/api/plot/render`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return await response.json();
  }

  /**
   * List saved plot specs from the shared store.
   */
  async listPlotSpecs(): Promise<unknown> {
    const response = await this.authFetch(`${this.baseURL}/api/plot/specs`);
    return await response.json();
  }

  /**
   * Save a plot spec ({name, spec|gridSpec, dataSource?}).
   */
  async savePlotSpec(body: Record<string, unknown>): Promise<unknown> {
    const response = await this.authFetch(`${this.baseURL}/api/plot/specs`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    return await response.json();
  }

  /**
   * Save a plot spec's raster as a manuscript figure; returns the Typst
   * snippet to insert into the manuscript source.
   */
  async savePlotFigure(
    manuscriptId: string,
    spec: Record<string, unknown>,
    name?: string
  ): Promise<unknown> {
    const response = await this.authFetch(
      `${this.baseURL}/api/manuscripts/${manuscriptId}/plot-figure`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ spec, name }),
      }
    );
    return await response.json();
  }

  /**
   * Check if imbib is running and accessible.
   */
  async checkStatus(): Promise<ImbibStatus | null> {
    try {
      const response = await this.authFetch(`${this.baseURL}/api/status`, {
        signal: AbortSignal.timeout(2000),
      });
      if (!response.ok) return null;
      return (await response.json()) as ImbibStatus;
    } catch (error) {
      // "not running" and "running but refusing my token" are different
      // diagnoses; only the former should collapse to null.
      if (error instanceof ImbibAuthError) throw error;
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

    const response = await this.authFetch(
      `${this.baseURL}/api/search?${params.toString()}`
    );
    if (!response.ok) {
      throw new Error(`Search failed: ${response.statusText}`);
    }
    return (await response.json()) as SearchResponse;
  }

  /**
   * Search external academic sources (ADS, arXiv, Crossref, etc.) for papers.
   */
  async searchExternal(
    query: string,
    options: { source?: string; limit?: number } = {}
  ): Promise<ExternalSearchResponse> {
    const params = new URLSearchParams({ q: query });
    if (options.source) params.set("source", options.source);
    if (options.limit) params.set("limit", String(options.limit));

    const response = await this.authFetch(
      `${this.baseURL}/api/search/external?${params.toString()}`
    );
    if (!response.ok) {
      throw new Error(`External search failed: ${response.statusText}`);
    }
    return (await response.json()) as ExternalSearchResponse;
  }

  /**
   * Get a specific paper by cite key.
   */
  async getPaper(citeKey: string): Promise<Paper | null> {
    const response = await this.authFetch(
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

    const response = await this.authFetch(
      `${this.baseURL}/api/export?${params.toString()}`
    );
    if (!response.ok) {
      throw new Error(`Export failed: ${response.statusText}`);
    }
    return (await response.json()) as ExportResponse;
  }

  /**
   * Get log entries from the app's in-memory log store.
   */
  async getLogs(options: {
    limit?: number;
    level?: string;
    category?: string;
    search?: string;
    after?: string;
  } = {}): Promise<LogsResponse> {
    const params = new URLSearchParams();
    if (options.limit) params.set("limit", String(options.limit));
    if (options.level) params.set("level", options.level);
    if (options.category) params.set("category", options.category);
    if (options.search) params.set("search", options.search);
    if (options.after) params.set("after", options.after);

    const query = params.toString();
    const url = query
      ? `${this.baseURL}/api/logs?${query}`
      : `${this.baseURL}/api/logs`;

    const response = await this.authFetch(url);
    if (!response.ok) {
      throw new Error(`Get logs failed: ${response.statusText}`);
    }
    return (await response.json()) as LogsResponse;
  }

  /**
   * List all collections.
   */
  async listCollections(): Promise<Collection[]> {
    const response = await this.authFetch(`${this.baseURL}/api/collections`);
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

  // --------------------------------------------------------------------------
  // Write Operations (POST/PUT/DELETE)
  // --------------------------------------------------------------------------

  /**
   * Add papers to the library by identifier (DOI, arXiv ID, etc.).
   */
  async addPapers(
    identifiers: string[],
    options: { collection?: string; library?: string; downloadPDFs?: boolean } = {}
  ): Promise<AddPapersResponse> {
    const response = await this.authFetch(`${this.baseURL}/api/papers/add`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        identifiers,
        collection: options.collection,
        library: options.library,
        downloadPDFs: options.downloadPDFs ?? false,
      }),
    });
    if (!response.ok) {
      throw new Error(`Add papers failed: ${response.statusText}`);
    }
    return (await response.json()) as AddPapersResponse;
  }

  /**
   * Delete papers from the library.
   */
  async deletePapers(identifiers: string[]): Promise<{ deleted: number }> {
    const response = await this.authFetch(`${this.baseURL}/api/papers`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identifiers }),
    });
    if (!response.ok) {
      throw new Error(`Delete papers failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: number };
    return { deleted: data.deleted };
  }

  /**
   * Mark papers as read or unread.
   */
  async markRead(identifiers: string[], read: boolean): Promise<{ updated: number }> {
    const response = await this.authFetch(`${this.baseURL}/api/papers/read`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identifiers, read }),
    });
    if (!response.ok) {
      throw new Error(`Mark read failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: number };
    return { updated: data.updated };
  }

  /**
   * Toggle star status for papers.
   */
  async toggleStar(identifiers: string[]): Promise<{ updated: number }> {
    const response = await this.authFetch(`${this.baseURL}/api/papers/star`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identifiers }),
    });
    if (!response.ok) {
      throw new Error(`Toggle star failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: number };
    return { updated: data.updated };
  }

  /**
   * Set a flag on papers.
   */
  async setFlag(
    identifiers: string[],
    color: string | null,
    style?: string,
    length?: string
  ): Promise<{ updated: number }> {
    const response = await this.authFetch(`${this.baseURL}/api/papers/flag`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identifiers, color, style, length }),
    });
    if (!response.ok) {
      throw new Error(`Set flag failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: number };
    return { updated: data.updated };
  }

  /**
   * Add a tag to papers.
   */
  async addTag(identifiers: string[], tag: string): Promise<{ updated: number }> {
    const response = await this.authFetch(`${this.baseURL}/api/papers/tags`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identifiers, action: "add", tag }),
    });
    if (!response.ok) {
      throw new Error(`Add tag failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: number };
    return { updated: data.updated };
  }

  /**
   * Remove a tag from papers.
   */
  async removeTag(identifiers: string[], tag: string): Promise<{ updated: number }> {
    const response = await this.authFetch(`${this.baseURL}/api/papers/tags`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identifiers, action: "remove", tag }),
    });
    if (!response.ok) {
      throw new Error(`Remove tag failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: number };
    return { updated: data.updated };
  }

  /**
   * Create a new collection.
   */
  async createCollection(
    name: string,
    options: { libraryID?: string; isSmartCollection?: boolean; predicate?: string } = {}
  ): Promise<Collection> {
    const response = await this.authFetch(`${this.baseURL}/api/collections`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name,
        libraryID: options.libraryID,
        isSmartCollection: options.isSmartCollection ?? false,
        predicate: options.predicate,
      }),
    });
    if (!response.ok) {
      throw new Error(`Create collection failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; collection: Collection };
    return data.collection;
  }

  /**
   * Delete a collection.
   */
  async deleteCollection(id: string): Promise<{ deleted: boolean }> {
    const response = await this.authFetch(`${this.baseURL}/api/collections/${id}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      throw new Error(`Delete collection failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: boolean };
    return { deleted: data.deleted };
  }

  /**
   * List smart searches (the rows of imbib's Exploration section when
   * `libraryID` is the Exploration library). Omit `libraryID` for all.
   */
  async listSmartSearches(libraryID?: string): Promise<SmartSearch[]> {
    const url = libraryID
      ? `${this.baseURL}/api/smart-searches?library_id=${encodeURIComponent(libraryID)}`
      : `${this.baseURL}/api/smart-searches`;
    const response = await this.authFetch(url);
    if (!response.ok) {
      throw new Error(`List smart searches failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; searches: SmartSearch[] };
    return data.searches ?? [];
  }

  /**
   * Delete one or more smart searches. Papers the searches pulled into their
   * library are left alone — only the search definitions are removed.
   */
  async deleteSmartSearches(ids: string[]): Promise<{ deleted: number }> {
    if (ids.length === 1) {
      const response = await this.authFetch(
        `${this.baseURL}/api/smart-searches/${ids[0]}`,
        { method: "DELETE" }
      );
      if (!response.ok) {
        throw new Error(`Delete smart search failed: ${response.statusText}`);
      }
      const data = (await response.json()) as { status: string; deleted: number };
      return { deleted: data.deleted };
    }
    const response = await this.authFetch(`${this.baseURL}/api/smart-searches`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identifiers: ids }),
    });
    if (!response.ok) {
      throw new Error(`Delete smart searches failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: number };
    return { deleted: data.deleted };
  }

  /**
   * Add papers to a collection.
   */
  async addToCollection(
    collectionID: string,
    identifiers: string[]
  ): Promise<{ updated: number }> {
    const response = await this.authFetch(`${this.baseURL}/api/collections/${collectionID}/papers`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "add", identifiers }),
    });
    if (!response.ok) {
      throw new Error(`Add to collection failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: number };
    return { updated: data.updated };
  }

  /**
   * Add papers to a library.
   */
  async addToLibrary(
    libraryID: string,
    identifiers: string[]
  ): Promise<{ assigned: string[]; notFound: string[] }> {
    const response = await this.authFetch(`${this.baseURL}/api/libraries/add-papers`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ libraryID, identifiers }),
    });
    if (!response.ok) {
      throw new Error(`Add to library failed: ${response.statusText}`);
    }
    const data = (await response.json()) as {
      status: string;
      assigned: string[];
      notFound: string[];
    };
    return { assigned: data.assigned, notFound: data.notFound };
  }

  /**
   * Remove papers from a collection.
   */
  async removeFromCollection(
    collectionID: string,
    identifiers: string[]
  ): Promise<{ updated: number }> {
    const response = await this.authFetch(`${this.baseURL}/api/collections/${collectionID}/papers`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ action: "remove", identifiers }),
    });
    if (!response.ok) {
      throw new Error(`Remove from collection failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: number };
    return { updated: data.updated };
  }

  /**
   * Download PDFs for papers.
   */
  async downloadPDFs(identifiers: string[]): Promise<DownloadResponse> {
    const response = await this.authFetch(`${this.baseURL}/api/papers/download-pdfs`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ identifiers }),
    });
    if (!response.ok) {
      throw new Error(`Download PDFs failed: ${response.statusText}`);
    }
    return (await response.json()) as DownloadResponse;
  }

  // --------------------------------------------------------------------------
  // Additional GET Operations
  // --------------------------------------------------------------------------

  /**
   * List all libraries.
   */
  async listLibraries(): Promise<Library[]> {
    const response = await this.authFetch(`${this.baseURL}/api/libraries`);
    if (!response.ok) {
      throw new Error(`List libraries failed: ${response.statusText}`);
    }
    const data = (await response.json()) as {
      status: string;
      count: number;
      libraries: Library[];
    };
    return data.libraries;
  }

  /**
   * Create a new library.
   */
  async createLibrary(name: string): Promise<Library> {
    const response = await this.authFetch(`${this.baseURL}/api/libraries`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name }),
    });
    if (!response.ok) {
      throw new Error(`Create library failed: ${response.statusText}`);
    }
    const data = (await response.json()) as {
      status: string;
      library: Library;
    };
    return data.library;
  }

  /**
   * List papers in a collection.
   */
  async listCollectionPapers(
    collectionID: string,
    options: { limit?: number; offset?: number } = {}
  ): Promise<Paper[]> {
    const params = new URLSearchParams();
    if (options.limit) params.set("limit", String(options.limit));
    if (options.offset) params.set("offset", String(options.offset));

    const query = params.toString();
    const url = query
      ? `${this.baseURL}/api/collections/${collectionID}/papers?${query}`
      : `${this.baseURL}/api/collections/${collectionID}/papers`;

    const response = await this.authFetch(url);
    if (!response.ok) {
      throw new Error(`List collection papers failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; papers: Paper[] };
    return data.papers;
  }

  /**
   * List all tags, optionally filtered by prefix.
   */
  async listTags(prefix?: string): Promise<Tag[]> {
    const params = new URLSearchParams();
    if (prefix) params.set("prefix", prefix);

    const query = params.toString();
    const url = query ? `${this.baseURL}/api/tags?${query}` : `${this.baseURL}/api/tags`;

    const response = await this.authFetch(url);
    if (!response.ok) {
      throw new Error(`List tags failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; tags: Tag[] };
    return data.tags;
  }

  /**
   * Get the tag tree as a formatted string.
   */
  async getTagTree(): Promise<string> {
    const response = await this.authFetch(`${this.baseURL}/api/tags/tree`);
    if (!response.ok) {
      throw new Error(`Get tag tree failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; tree: string };
    return data.tree;
  }

  // --------------------------------------------------------------------------
  // Collaboration Operations
  // --------------------------------------------------------------------------

  /**
   * List participants in a shared library.
   */
  async listParticipants(libraryID: string): Promise<Participant[]> {
    const response = await this.authFetch(`${this.baseURL}/api/libraries/${libraryID}/participants`);
    if (!response.ok) {
      throw new Error(`List participants failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; participants: Participant[] };
    return data.participants;
  }

  /**
   * Get recent activity in a library.
   */
  async getLibraryActivity(libraryID: string, limit?: number): Promise<Activity[]> {
    const params = new URLSearchParams();
    if (limit) params.set("limit", String(limit));

    const query = params.toString();
    const url = query
      ? `${this.baseURL}/api/libraries/${libraryID}/activity?${query}`
      : `${this.baseURL}/api/libraries/${libraryID}/activity`;

    const response = await this.authFetch(url);
    if (!response.ok) {
      throw new Error(`Get library activity failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; activities: Activity[] };
    return data.activities;
  }

  /**
   * List comments on a paper.
   */
  async listComments(citeKey: string): Promise<Comment[]> {
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/${encodeURIComponent(citeKey)}/comments`
    );
    if (!response.ok) {
      throw new Error(`List comments failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; comments: Comment[] };
    return data.comments;
  }

  /**
   * Add a comment to a paper.
   */
  async addComment(
    citeKey: string,
    text: string,
    parentCommentID?: string
  ): Promise<Comment> {
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/${encodeURIComponent(citeKey)}/comments`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text, parentCommentID }),
      }
    );
    if (!response.ok) {
      throw new Error(`Add comment failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; comment: Comment };
    return data.comment;
  }

  /**
   * Delete a comment.
   */
  async deleteComment(commentID: string): Promise<{ deleted: boolean }> {
    const response = await this.authFetch(`${this.baseURL}/api/comments/${commentID}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      throw new Error(`Delete comment failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: boolean };
    return { deleted: data.deleted };
  }

  /**
   * List comments for any item by UUID.
   */
  async listItemComments(
    itemID: string
  ): Promise<{ comments: Record<string, unknown>[]; total: number }> {
    const response = await this.authFetch(`${this.baseURL}/api/items/${itemID}/comments`);
    if (!response.ok) {
      throw new Error(`List item comments failed: ${response.statusText}`);
    }
    return (await response.json()) as {
      comments: Record<string, unknown>[];
      total: number;
    };
  }

  /**
   * Add a comment to any item by UUID.
   */
  async addItemComment(
    itemID: string,
    text: string,
    parentCommentID?: string
  ): Promise<{ comment: Record<string, unknown> }> {
    const body: Record<string, string> = { text };
    if (parentCommentID) body.parentCommentID = parentCommentID;

    const response = await this.authFetch(`${this.baseURL}/api/items/${itemID}/comments`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      throw new Error(`Add item comment failed: ${response.statusText}`);
    }
    return (await response.json()) as { comment: Record<string, unknown> };
  }

  /**
   * Edit an existing comment.
   */
  async editComment(
    commentID: string,
    text: string
  ): Promise<{ updated: boolean }> {
    const response = await this.authFetch(`${this.baseURL}/api/comments/${commentID}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text }),
    });
    if (!response.ok) {
      throw new Error(`Edit comment failed: ${response.statusText}`);
    }
    return (await response.json()) as { updated: boolean };
  }

  // NOTE: `syncComments()` (POST /api/sync/comments) was removed here to match
  // imbib: the route was deleted in 5400ae1 along with the dead CloudKit
  // comment stack (tombstone at HTTPAutomationRouter.swift:857) and every call
  // 404'd. The live sync surface is `getSyncStatus()` + `syncNudge()` below.

  /**
   * GET /api/sync/status — the real ADR-0007 Phase-3 CloudKit engine state,
   * identical to what imbib's Settings pane renders. Always 200; "off" and
   * "not entitled" are reported states, not errors.
   */
  async getSyncStatus(): Promise<SyncStatus> {
    const response = await this.authFetch(`${this.baseURL}/api/sync/status`);
    if (!response.ok) {
      throw await this.failure("Get sync status", response);
    }
    return (await response.json()) as SyncStatus;
  }

  /**
   * POST /api/sync/nudge — ask the engine for an immediate push+pull.
   * Never errors on a disabled engine: `accepted:false` plus a reason is a
   * normal outcome.
   */
  async syncNudge(): Promise<{ accepted: boolean; reason?: string }> {
    const response = await this.authFetch(`${this.baseURL}/api/sync/nudge`, {
      method: "POST",
    });
    if (!response.ok) {
      throw await this.failure("Sync nudge", response);
    }
    return (await response.json()) as { accepted: boolean; reason?: string };
  }

  // --------------------------------------------------------------------------
  // Manuscripts (CAS-safe write path)
  //
  // Manuscripts are first-class rows in the shared impress store (ADR-0018),
  // so imbib serves them even though the authoring GUI lives in imprint —
  // and imbib is the only app in the suite whose HTTP surface is reachable
  // from iOS. Body writes are compare-and-set on a content hash.
  // --------------------------------------------------------------------------

  /** GET /api/manuscripts — id/title/format/status only (no bodies). */
  async listManuscripts(): Promise<ManuscriptSummary[]> {
    const response = await this.authFetch(`${this.baseURL}/api/manuscripts`);
    if (!response.ok) {
      throw await this.failure("List manuscripts", response);
    }
    const data = (await response.json()) as { manuscripts?: ManuscriptSummary[] };
    return data.manuscripts ?? [];
  }

  /**
   * GET /api/manuscripts/{id} — full body plus the `contentHash` that
   * `setManuscriptBody` requires. Returns null when the id is unknown.
   */
  async getManuscript(id: string): Promise<ManuscriptDetail | null> {
    const response = await this.authFetch(
      `${this.baseURL}/api/manuscripts/${encodeURIComponent(id)}`
    );
    if (response.status === 404) return null;
    if (!response.ok) {
      throw await this.failure("Get manuscript", response);
    }
    return (await response.json()) as ManuscriptDetail;
  }

  /** POST /api/manuscripts — create. Returns the new row's id. */
  async createManuscript(input: {
    title: string;
    body?: string;
    format?: string;
    authors?: string[];
  }): Promise<{ id: string; title: string }> {
    const response = await this.authFetch(`${this.baseURL}/api/manuscripts`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: input.title,
        body: input.body ?? "",
        format: input.format ?? "typst",
        authors: input.authors ?? [],
      }),
    });
    if (!response.ok) {
      throw await this.failure("Create manuscript", response);
    }
    return (await response.json()) as { id: string; title: string };
  }

  /**
   * PUT /api/manuscripts/{id}/body — compare-and-set.
   *
   * `expectedHash` must be the `contentHash` from the read that produced the
   * text being edited. A mismatch answers HTTP 409 and the write is NOT
   * applied; the response carries `storedHash` so the caller can re-read and
   * rebase. Never returns a thrown error for the conflict case — a conflict
   * is data the caller must act on, not a transport failure.
   */
  async setManuscriptBody(
    id: string,
    body: string,
    expectedHash?: string
  ): Promise<ManuscriptWriteResult> {
    const response = await this.authFetch(
      `${this.baseURL}/api/manuscripts/${encodeURIComponent(id)}/body`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ body, expected_hash: expectedHash }),
      }
    );
    if (response.status === 409) {
      const data = (await response.json()) as { storedHash?: string };
      return { applied: false, conflict: true, storedHash: data.storedHash };
    }
    if (response.status === 404) {
      return { applied: false, conflict: false, notFound: true };
    }
    if (!response.ok) {
      throw await this.failure("Write manuscript body", response);
    }
    const data = (await response.json()) as { newHash?: string };
    return { applied: true, conflict: false, newHash: data.newHash };
  }

  /**
   * POST /api/manuscripts/{id}/compile — headless Typst compile with the
   * store-backed virtual bibliography (`@citeKey` → library BibTeX).
   * Status 422 (compile errors, or a LaTeX manuscript) still returns a
   * structured payload, so it is not treated as a transport failure.
   */
  async compileManuscript(
    id: string,
    includePDF = false
  ): Promise<ManuscriptCompileResult> {
    const response = await this.authFetch(
      `${this.baseURL}/api/manuscripts/${encodeURIComponent(id)}/compile`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ include_pdf: includePDF }),
      }
    );
    if (response.status === 404) {
      throw new Error(`Compile manuscript failed: no manuscript with id ${id}`);
    }
    if (!response.ok && response.status !== 422) {
      throw await this.failure("Compile manuscript", response);
    }
    return (await response.json()) as ManuscriptCompileResult;
  }

  // --------------------------------------------------------------------------
  // Undo — the safety net under every destructive tool
  // --------------------------------------------------------------------------

  /** GET /api/undo/recent?max_entries=N — newest store operations first. */
  async recentUndoGroups(maxEntries?: number): Promise<UndoGroup[]> {
    const suffix = maxEntries ? `?max_entries=${maxEntries}` : "";
    const response = await this.authFetch(`${this.baseURL}/api/undo/recent${suffix}`);
    if (!response.ok) {
      throw await this.failure("List recent undo groups", response);
    }
    const data = (await response.json()) as { groups?: UndoGroup[] };
    return data.groups ?? [];
  }

  /** POST /api/undo/operation/{id} — revert one operation. */
  async undoOperation(operationID: string): Promise<{ operationCount: number }> {
    const response = await this.authFetch(
      `${this.baseURL}/api/undo/operation/${encodeURIComponent(operationID)}`,
      { method: "POST" }
    );
    if (response.status === 404) {
      throw new Error(
        `Undo failed: no operation with id ${operationID}. ` +
          "Call imbib_recent_undo_groups for current, valid operation ids " +
          "(ids are per-store and do not survive a restore)."
      );
    }
    if (!response.ok) {
      throw await this.failure("Undo operation", response);
    }
    const data = (await response.json()) as { operation_count?: number };
    return { operationCount: data.operation_count ?? 0 };
  }

  /** POST /api/undo/batch/{id} — revert every operation in a batch at once. */
  async undoBatch(batchID: string): Promise<{ operationCount: number }> {
    const response = await this.authFetch(
      `${this.baseURL}/api/undo/batch/${encodeURIComponent(batchID)}`,
      { method: "POST" }
    );
    if (response.status === 404) {
      throw new Error(
        `Undo failed: no batch with id ${batchID}. ` +
          "Call imbib_recent_undo_groups — only some groups carry a batch_id " +
          "(a batch exists when several rows changed in one user-level action)."
      );
    }
    if (!response.ok) {
      throw await this.failure("Undo batch", response);
    }
    const data = (await response.json()) as { operation_count?: number };
    return { operationCount: data.operation_count ?? 0 };
  }

  // --------------------------------------------------------------------------
  // Recent / starred / counts — the "what was I just doing?" surface
  // --------------------------------------------------------------------------

  /** GET /api/papers/recent — recently ADDED (creation date), incl. feeds. */
  async queryRecent(options: { limit?: number; parentID?: string } = {}): Promise<RecentPaper[]> {
    const params = new URLSearchParams();
    if (options.limit) params.set("limit", String(options.limit));
    if (options.parentID) params.set("parent_id", options.parentID);
    const query = params.toString();
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/recent${query ? `?${query}` : ""}`
    );
    if (!response.ok) {
      throw await this.failure("Query recent papers", response);
    }
    const data = (await response.json()) as { papers?: RecentPaper[] };
    return data.papers ?? [];
  }

  /** GET /api/papers/recent-activity — papers the USER viewed or added. */
  async queryRecentActivity(options: { limit?: number } = {}): Promise<RecentPaper[]> {
    const suffix = options.limit ? `?limit=${options.limit}` : "";
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/recent-activity${suffix}`
    );
    if (!response.ok) {
      throw await this.failure("Query recent activity", response);
    }
    const data = (await response.json()) as { papers?: RecentPaper[] };
    return data.papers ?? [];
  }

  /** GET /api/papers/starred — starred papers, newest-added first. */
  async queryStarred(options: { limit?: number; parentID?: string } = {}): Promise<RecentPaper[]> {
    const params = new URLSearchParams();
    if (options.limit) params.set("limit", String(options.limit));
    if (options.parentID) params.set("parent_id", options.parentID);
    const query = params.toString();
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/starred${query ? `?${query}` : ""}`
    );
    if (!response.ok) {
      throw await this.failure("Query starred papers", response);
    }
    const data = (await response.json()) as { papers?: RecentPaper[] };
    return data.papers ?? [];
  }

  /**
   * GET /api/papers/count/{unread|starred|flagged|by-tag} — a scalar count,
   * far cheaper than fetching the rows to length them.
   */
  async countPapers(
    kind: "unread" | "starred" | "flagged" | "by-tag",
    options: { parentID?: string; color?: string; tag?: string } = {}
  ): Promise<number> {
    const params = new URLSearchParams();
    if (options.parentID) params.set("parent_id", options.parentID);
    if (kind === "flagged" && options.color) params.set("color", options.color);
    if (kind === "by-tag") {
      if (!options.tag) throw new Error("Count by-tag requires a 'tag' path");
      params.set("tag", options.tag);
    }
    const query = params.toString();
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/count/${kind}${query ? `?${query}` : ""}`
    );
    if (!response.ok) {
      throw await this.failure(`Count ${kind} papers`, response);
    }
    const data = (await response.json()) as { count?: number };
    return data.count ?? 0;
  }

  // --------------------------------------------------------------------------
  // Smart search creation / detail (deletion lives above)
  // --------------------------------------------------------------------------

  /** GET /api/smart-searches/{id}. Returns null when unknown. */
  async getSmartSearch(id: string): Promise<SmartSearch | null> {
    const response = await this.authFetch(
      `${this.baseURL}/api/smart-searches/${encodeURIComponent(id)}`
    );
    if (response.status === 404) return null;
    if (!response.ok) {
      throw await this.failure("Get smart search", response);
    }
    const data = (await response.json()) as { search: SmartSearch };
    return data.search;
  }

  /** POST /api/smart-searches — create a saved query in a library. */
  async createSmartSearch(input: {
    name: string;
    query: string;
    libraryID: string;
    maxResults?: number;
    feedsToInbox?: boolean;
    autoRefreshEnabled?: boolean;
    refreshIntervalSeconds?: number;
    sourceIDs?: string[];
  }): Promise<SmartSearch> {
    const response = await this.authFetch(`${this.baseURL}/api/smart-searches`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        name: input.name,
        query: input.query,
        library_id: input.libraryID,
        max_results: input.maxResults ?? 100,
        feeds_to_inbox: input.feedsToInbox ?? false,
        auto_refresh_enabled: input.autoRefreshEnabled ?? false,
        refresh_interval_seconds: input.refreshIntervalSeconds ?? 3600,
        // imbib takes the source list as a JSON *string* (source_ids_json).
        source_ids_json: input.sourceIDs ? JSON.stringify(input.sourceIDs) : undefined,
      }),
    });
    if (!response.ok) {
      throw await this.failure("Create smart search", response);
    }
    const data = (await response.json()) as { search: SmartSearch };
    return data.search;
  }

  // --------------------------------------------------------------------------
  // Tag vocabulary management (attaching tags to papers is addTag/removeTag)
  // --------------------------------------------------------------------------

  /** POST /api/tags — create a tag path, optionally with display colors. */
  async createTag(input: {
    path: string;
    colorLight?: string;
    colorDark?: string;
  }): Promise<void> {
    const response = await this.authFetch(`${this.baseURL}/api/tags`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        path: input.path,
        color_light: input.colorLight,
        color_dark: input.colorDark,
      }),
    });
    if (!response.ok) {
      throw await this.failure("Create tag", response);
    }
  }

  /** PUT /api/tags/{path}/rename — rename/re-parent a tag across all papers. */
  async renameTag(path: string, newPath: string): Promise<void> {
    const response = await this.authFetch(
      `${this.baseURL}/api/tags/${encodeURIComponent(path)}/rename`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ new_path: newPath }),
      }
    );
    if (!response.ok) {
      throw await this.failure("Rename tag", response);
    }
  }

  /** PUT /api/tags/{path} — set light/dark display colors. */
  async updateTagColor(
    path: string,
    colors: { colorLight?: string; colorDark?: string }
  ): Promise<void> {
    const response = await this.authFetch(
      `${this.baseURL}/api/tags/${encodeURIComponent(path)}`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          color_light: colors.colorLight,
          color_dark: colors.colorDark,
        }),
      }
    );
    if (!response.ok) {
      throw await this.failure("Update tag color", response);
    }
  }

  /** DELETE /api/tags/{path} — remove the tag from the vocabulary. */
  async deleteTag(path: string): Promise<void> {
    const response = await this.authFetch(
      `${this.baseURL}/api/tags/${encodeURIComponent(path)}`,
      { method: "DELETE" }
    );
    if (!response.ok) {
      throw await this.failure("Delete tag", response);
    }
  }

  /**
   * List assignments in a library.
   */
  async listLibraryAssignments(libraryID: string): Promise<Assignment[]> {
    const response = await this.authFetch(`${this.baseURL}/api/libraries/${libraryID}/assignments`);
    if (!response.ok) {
      throw new Error(`List assignments failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; assignments: Assignment[] };
    return data.assignments;
  }

  /**
   * List assignments for a specific paper.
   */
  async listPaperAssignments(citeKey: string): Promise<Assignment[]> {
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/${encodeURIComponent(citeKey)}/assignments`
    );
    if (!response.ok) {
      throw new Error(`List paper assignments failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; assignments: Assignment[] };
    return data.assignments;
  }

  /**
   * Create an assignment for a paper.
   */
  async createAssignment(
    citeKey: string,
    assigneeName: string,
    libraryID: string,
    options: { note?: string; dueDate?: string } = {}
  ): Promise<Assignment> {
    const response = await this.authFetch(`${this.baseURL}/api/assignments`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        citeKey,
        assigneeName,
        libraryID,
        note: options.note,
        dueDate: options.dueDate,
      }),
    });
    if (!response.ok) {
      throw new Error(`Create assignment failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; assignment: Assignment };
    return data.assignment;
  }

  /**
   * Delete an assignment.
   */
  async deleteAssignment(assignmentID: string): Promise<{ deleted: boolean }> {
    const response = await this.authFetch(`${this.baseURL}/api/assignments/${assignmentID}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      throw new Error(`Delete assignment failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: boolean };
    return { deleted: data.deleted };
  }

  /**
   * Share a library.
   */
  async shareLibrary(libraryID: string): Promise<ShareResult> {
    const response = await this.authFetch(`${this.baseURL}/api/libraries/${libraryID}/share`, {
      method: "POST",
    });
    if (!response.ok) {
      throw new Error(`Share library failed: ${response.statusText}`);
    }
    return (await response.json()) as ShareResult;
  }

  /**
   * Unshare a library or leave a shared library.
   */
  async unshareLibrary(libraryID: string, keepCopy?: boolean): Promise<{ unshared: boolean }> {
    const response = await this.authFetch(`${this.baseURL}/api/libraries/${libraryID}/share`, {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ keepCopy: keepCopy ?? true }),
    });
    if (!response.ok) {
      throw new Error(`Unshare library failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; unshared: boolean };
    return { unshared: data.unshared };
  }

  /**
   * Set a participant's permission level.
   */
  async setParticipantPermission(
    libraryID: string,
    participantID: string,
    permission: "readOnly" | "readWrite"
  ): Promise<{ updated: boolean }> {
    const response = await this.authFetch(
      `${this.baseURL}/api/libraries/${libraryID}/participants/${participantID}`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ permission }),
      }
    );
    if (!response.ok) {
      throw new Error(`Set participant permission failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: boolean };
    return { updated: data.updated };
  }

  // --------------------------------------------------------------------------
  // Annotation and Notes Operations
  // --------------------------------------------------------------------------

  /**
   * List PDF annotations for a paper.
   */
  async listAnnotations(citeKey: string, pageNumber?: number): Promise<Annotation[]> {
    const params = new URLSearchParams();
    if (pageNumber !== undefined) params.set("page", String(pageNumber));

    const query = params.toString();
    const url = query
      ? `${this.baseURL}/api/papers/${encodeURIComponent(citeKey)}/annotations?${query}`
      : `${this.baseURL}/api/papers/${encodeURIComponent(citeKey)}/annotations`;

    const response = await this.authFetch(url);
    if (!response.ok) {
      throw new Error(`List annotations failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; annotations: Annotation[] };
    return data.annotations;
  }

  /**
   * Add a PDF annotation to a paper.
   */
  async addAnnotation(
    citeKey: string,
    type: string,
    pageNumber: number,
    options: { contents?: string; selectedText?: string; color?: string } = {}
  ): Promise<Annotation> {
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/${encodeURIComponent(citeKey)}/annotations`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          type,
          pageNumber,
          contents: options.contents,
          selectedText: options.selectedText,
          color: options.color,
        }),
      }
    );
    if (!response.ok) {
      throw new Error(`Add annotation failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; annotation: Annotation };
    return data.annotation;
  }

  /**
   * Delete a PDF annotation.
   */
  async deleteAnnotation(annotationID: string): Promise<{ deleted: boolean }> {
    const response = await this.authFetch(`${this.baseURL}/api/annotations/${annotationID}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      throw new Error(`Delete annotation failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: boolean };
    return { deleted: data.deleted };
  }

  /**
   * Get the notes (BibTeX note field) for a paper.
   */
  async getNotes(citeKey: string): Promise<string | null> {
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/${encodeURIComponent(citeKey)}/notes`
    );
    if (!response.ok) {
      throw new Error(`Get notes failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; notes: string | null };
    return data.notes;
  }

  /**
   * Update the notes (BibTeX note field) for a paper.
   */
  async updateNotes(citeKey: string, notes: string | null): Promise<{ notes: string | null }> {
    const response = await this.authFetch(
      `${this.baseURL}/api/papers/${encodeURIComponent(citeKey)}/notes`,
      {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ notes }),
      }
    );
    if (!response.ok) {
      throw new Error(`Update notes failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; notes: string | null };
    return { notes: data.notes };
  }

  // --------------------------------------------------------------------------
  // Artifact Operations
  // --------------------------------------------------------------------------

  /**
   * List or search artifacts.
   */
  async listArtifacts(options: {
    type?: string;
    query?: string;
    limit?: number;
    offset?: number;
  } = {}): Promise<Artifact[]> {
    const params = new URLSearchParams();
    if (options.type) params.set("type", options.type);
    if (options.query) params.set("query", options.query);
    if (options.limit) params.set("limit", String(options.limit));
    if (options.offset) params.set("offset", String(options.offset));

    const query = params.toString();
    const url = query
      ? `${this.baseURL}/api/artifacts?${query}`
      : `${this.baseURL}/api/artifacts`;

    const response = await this.authFetch(url);
    if (!response.ok) {
      throw new Error(`List artifacts failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; artifacts: Artifact[] };
    return data.artifacts;
  }

  /**
   * Get a single artifact by ID.
   */
  async getArtifact(id: string): Promise<Artifact | null> {
    const response = await this.authFetch(`${this.baseURL}/api/artifacts/${id}`);
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get artifact failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; artifact: Artifact };
    return data.artifact;
  }

  /**
   * Create a new artifact.
   */
  async createArtifact(
    type: string,
    title: string,
    options: { sourceURL?: string; notes?: string; tags?: string[] } = {}
  ): Promise<Artifact> {
    const response = await this.authFetch(`${this.baseURL}/api/artifacts`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        type,
        title,
        sourceURL: options.sourceURL,
        notes: options.notes,
        tags: options.tags,
      }),
    });
    if (!response.ok) {
      throw new Error(`Create artifact failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; artifact: Artifact };
    return data.artifact;
  }

  /**
   * Delete an artifact.
   */
  async deleteArtifact(id: string): Promise<{ deleted: boolean }> {
    const response = await this.authFetch(`${this.baseURL}/api/artifacts/${id}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      throw new Error(`Delete artifact failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: boolean };
    return { deleted: data.deleted };
  }

  /**
   * Add a tag to an artifact.
   */
  async tagArtifact(id: string, tag: string): Promise<{ updated: boolean }> {
    const response = await this.authFetch(`${this.baseURL}/api/artifacts/${id}/tags`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ tag }),
    });
    if (!response.ok) {
      throw new Error(`Tag artifact failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: boolean };
    return { updated: data.updated };
  }

  /**
   * Remove a tag from an artifact.
   */
  async untagArtifact(id: string, tag: string): Promise<{ updated: boolean }> {
    const response = await this.authFetch(
      `${this.baseURL}/api/artifacts/${id}/tags/${encodeURIComponent(tag)}`,
      { method: "DELETE" }
    );
    if (!response.ok) {
      throw new Error(`Untag artifact failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; updated: boolean };
    return { updated: data.updated };
  }

  /**
   * Link an artifact to a publication by cite key.
   */
  async linkArtifactToPaper(
    artifactID: string,
    citeKey: string
  ): Promise<{ linked: boolean }> {
    const response = await this.authFetch(
      `${this.baseURL}/api/artifacts/${artifactID}/link`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ citeKey }),
      }
    );
    if (!response.ok) {
      throw new Error(`Link artifact failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; linked: boolean };
    return { linked: data.linked };
  }

  /**
   * Atomic citation resolution: cascades local → identifier add → external
   * search. See `/api/papers/resolve` in imbib's HTTPAutomationRouter.
   */
  async resolveIdentifier(input: {
    query?: string;
    bibtex?: string;
    library?: string;
    downloadPDFs?: boolean;
  }): Promise<ResolvedPaperResponse> {
    const res = await this.authFetch(`${this.baseURL}/api/papers/resolve`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query: input.query ?? "",
        bibtex: input.bibtex ?? "",
        library: input.library,
        download_pdfs: input.downloadPDFs ?? false,
      }),
    });
    if (!res.ok) {
      throw new Error(`Resolve identifier failed: ${res.statusText}`);
    }
    return (await res.json()) as ResolvedPaperResponse;
  }

  // ---------------------------------------------------------------------
  // Library backup & restore
  //
  // A backup is a consistent SQLite snapshot of the whole shared impress
  // store (imbib + imprint + impel), taken with VACUUM INTO while other
  // processes keep writing, plus a JSON manifest sidecar. Restore is
  // DESTRUCTIVE and refuses while CloudKit sync is enabled unless forced.
  // ---------------------------------------------------------------------

  /**
   * Create a whole-store snapshot. Returns the backup record.
   */
  async createBackup(options: { label?: string; directory?: string } = {}): Promise<
    Record<string, unknown>
  > {
    const response = await this.authFetch(`${this.baseURL}/api/backups`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        label: options.label,
        directory: options.directory,
      }),
    });
    const data = (await response.json()) as Record<string, unknown>;
    if (!response.ok) {
      throw new Error(`Create backup failed: ${data.error ?? response.statusText}`);
    }
    return (data.backup as Record<string, unknown>) ?? data;
  }

  /**
   * List backups, newest first.
   */
  async listBackups(directory?: string): Promise<{
    directory: string;
    backups: Array<Record<string, unknown>>;
  }> {
    const suffix = directory ? `?directory=${encodeURIComponent(directory)}` : "";
    const response = await this.authFetch(`${this.baseURL}/api/backups${suffix}`);
    if (!response.ok) {
      throw new Error(`List backups failed: ${response.statusText}`);
    }
    const data = (await response.json()) as {
      directory: string;
      backups: Array<Record<string, unknown>>;
    };
    return data;
  }

  /**
   * Validate a backup file without touching the live store.
   */
  async inspectBackup(path: string): Promise<Record<string, unknown>> {
    // encodeURIComponent, not URLSearchParams: the latter form-encodes spaces
    // as `+`, and imbib's query parser reads `+` literally.
    const response = await this.authFetch(
      `${this.baseURL}/api/backups/inspect?path=${encodeURIComponent(path)}`
    );
    const data = (await response.json()) as Record<string, unknown>;
    if (!response.ok) {
      throw new Error(`Inspect backup failed: ${data.error ?? response.statusText}`);
    }
    return data;
  }

  /**
   * DESTRUCTIVE: replace the live store's contents with a backup.
   * Returns 409 (`code: "sync_enabled"`) unless sync is off or `force`.
   */
  async restoreBackup(path: string, force = false): Promise<Record<string, unknown>> {
    const response = await this.authFetch(`${this.baseURL}/api/backups/restore`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path, force }),
    });
    const data = (await response.json()) as Record<string, unknown>;
    if (!response.ok) {
      const detail = data.issues ? ` (${(data.issues as string[]).join("; ")})` : "";
      throw new Error(`Restore failed: ${data.error ?? response.statusText}${detail}`);
    }
    return data;
  }

  /**
   * POST /api/backups/prune — keep the `keep` newest snapshots, delete the
   * rest (with their manifests). `keep: 0` deletes every backup.
   */
  async pruneBackups(keep: number, directory?: string): Promise<string[]> {
    const response = await this.authFetch(`${this.baseURL}/api/backups/prune`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ keep, directory }),
    });
    if (!response.ok) {
      throw await this.failure("Prune backups", response);
    }
    const data = (await response.json()) as { removed?: string[] };
    return data.removed ?? [];
  }

  /**
   * Delete a backup and its manifest sidecar.
   */
  async deleteBackup(path: string): Promise<boolean> {
    const response = await this.authFetch(
      `${this.baseURL}/api/backups?path=${encodeURIComponent(path)}`,
      { method: "DELETE" }
    );
    const data = (await response.json()) as { deleted?: boolean; error?: string };
    if (!response.ok) {
      throw new Error(`Delete backup failed: ${data.error ?? response.statusText}`);
    }
    return data.deleted ?? false;
  }

  // ---------------------------------------------------------------------
  // Manuscript templates (journal/conference styles, shared with imprint)
  // ---------------------------------------------------------------------

  /**
   * List the manuscript templates, optionally filtered by category or a
   * free-text query over name/description/tags.
   */
  async listTemplates(
    opts: { category?: string; query?: string } = {}
  ): Promise<ManuscriptTemplate[]> {
    const params = new URLSearchParams();
    if (opts.category) params.set("category", opts.category);
    if (opts.query) params.set("q", opts.query);
    const suffix = params.toString() ? `?${params.toString()}` : "";
    const response = await this.authFetch(`${this.baseURL}/api/templates${suffix}`);
    if (!response.ok) {
      throw await this.failure("List templates", response);
    }
    const data = (await response.json()) as {
      status: string;
      templates?: ManuscriptTemplate[];
    };
    return data.templates ?? [];
  }

  /**
   * Create a manuscript pre-formatted with a template's style.
   */
  async createManuscriptFromTemplate(
    input: TemplateManuscriptInput
  ): Promise<TemplateManuscriptResult> {
    const body: Record<string, unknown> = {
      template_id: input.templateId,
      title: input.title,
    };
    if (input.authors) body.authors = input.authors;
    if (input.affiliations) body.affiliations = input.affiliations;
    if (input.abstract !== undefined) body.abstract = input.abstract;
    if (input.keywords) body.keywords = input.keywords;
    if (input.includeSections !== undefined) body.include_sections = input.includeSections;
    const response = await this.authFetch(
      `${this.baseURL}/api/manuscripts/from-template`,
      {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      }
    );
    if (!response.ok) {
      throw await this.failure("Create manuscript from template", response);
    }
    return (await response.json()) as TemplateManuscriptResult;
  }
}

export interface TemplatePageDefaults {
  size?: string;
  columns?: number;
  font_size?: number;
  margin_top?: number;
  margin_bottom?: number;
  margin_left?: number;
  margin_right?: number;
}

export interface TemplateJournalInfo {
  publisher?: string;
  url?: string;
  latex_class?: string;
  issn?: string;
}

export interface ManuscriptTemplate {
  id: string;
  name: string;
  version?: string;
  description?: string;
  author?: string;
  license?: string;
  category?: string;
  tags?: string[];
  is_builtin?: boolean;
  page_defaults?: TemplatePageDefaults;
  journal?: TemplateJournalInfo;
}

export interface TemplateManuscriptInput {
  templateId: string;
  title: string;
  authors?: string[];
  affiliations?: string[];
  abstract?: string;
  keywords?: string[];
  includeSections?: boolean;
}

export interface TemplateManuscriptResult {
  status: string;
  id: string;
  title: string;
  template_id: string;
  body_length?: number;
}

/**
 * Response from `POST /api/papers/resolve`. One of `paper` or `candidates`
 * will be populated depending on which cascade step succeeded.
 */
export interface ResolvedPaperResponse {
  status: string;
  via:
    | "local-identifier"
    | "local-search"
    | "local-search-ambiguous"
    | "imported-identifier"
    | "duplicate"
    | "external-candidates"
    | "not-found";
  paper?: Record<string, unknown>;
  candidates?: Array<Record<string, unknown>>;
  duplicates?: string[];
  identifier?: { kind: string; value: string };
  reason?: string;
}
