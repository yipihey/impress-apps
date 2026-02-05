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

    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`Get logs failed: ${response.statusText}`);
    }
    return (await response.json()) as LogsResponse;
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
    const response = await fetch(`${this.baseURL}/api/papers/add`, {
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
    const response = await fetch(`${this.baseURL}/api/papers`, {
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
    const response = await fetch(`${this.baseURL}/api/papers/read`, {
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
    const response = await fetch(`${this.baseURL}/api/papers/star`, {
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
    const response = await fetch(`${this.baseURL}/api/papers/flag`, {
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
    const response = await fetch(`${this.baseURL}/api/papers/tags`, {
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
    const response = await fetch(`${this.baseURL}/api/papers/tags`, {
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
    const response = await fetch(`${this.baseURL}/api/collections`, {
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
    const response = await fetch(`${this.baseURL}/api/collections/${id}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      throw new Error(`Delete collection failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: boolean };
    return { deleted: data.deleted };
  }

  /**
   * Add papers to a collection.
   */
  async addToCollection(
    collectionID: string,
    identifiers: string[]
  ): Promise<{ updated: number }> {
    const response = await fetch(`${this.baseURL}/api/collections/${collectionID}/papers`, {
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
   * Remove papers from a collection.
   */
  async removeFromCollection(
    collectionID: string,
    identifiers: string[]
  ): Promise<{ updated: number }> {
    const response = await fetch(`${this.baseURL}/api/collections/${collectionID}/papers`, {
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
    const response = await fetch(`${this.baseURL}/api/papers/download-pdfs`, {
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
    const response = await fetch(`${this.baseURL}/api/libraries`);
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

    const response = await fetch(url);
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

    const response = await fetch(url);
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
    const response = await fetch(`${this.baseURL}/api/tags/tree`);
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
    const response = await fetch(`${this.baseURL}/api/libraries/${libraryID}/participants`);
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

    const response = await fetch(url);
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
    const response = await fetch(
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
    const response = await fetch(
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
    const response = await fetch(`${this.baseURL}/api/comments/${commentID}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      throw new Error(`Delete comment failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: boolean };
    return { deleted: data.deleted };
  }

  /**
   * List assignments in a library.
   */
  async listLibraryAssignments(libraryID: string): Promise<Assignment[]> {
    const response = await fetch(`${this.baseURL}/api/libraries/${libraryID}/assignments`);
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
    const response = await fetch(
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
    const response = await fetch(`${this.baseURL}/api/assignments`, {
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
    const response = await fetch(`${this.baseURL}/api/assignments/${assignmentID}`, {
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
    const response = await fetch(`${this.baseURL}/api/libraries/${libraryID}/share`, {
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
    const response = await fetch(`${this.baseURL}/api/libraries/${libraryID}/share`, {
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
    const response = await fetch(
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

    const response = await fetch(url);
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
    const response = await fetch(
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
    const response = await fetch(`${this.baseURL}/api/annotations/${annotationID}`, {
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
    const response = await fetch(
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
    const response = await fetch(
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
}
