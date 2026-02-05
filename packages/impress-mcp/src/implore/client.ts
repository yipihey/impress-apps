/**
 * HTTP client for implore API (data visualization)
 */

export interface ImploreStatus {
  status: string;
  app: string;
  version: string;
  port: number;
  openDatasets: number;
}

export interface Dataset {
  id: string;
  name: string;
  path?: string;
  rowCount: number;
  columnCount: number;
  columns: ColumnInfo[];
  createdAt: string;
  modifiedAt: string;
}

export interface ColumnInfo {
  name: string;
  type: "numeric" | "categorical" | "datetime" | "text";
  nullCount: number;
  uniqueCount?: number;
  min?: number;
  max?: number;
  mean?: number;
}

export interface Figure {
  id: string;
  name: string;
  datasetId: string;
  type: "scatter" | "line" | "bar" | "histogram" | "heatmap" | "box" | "violin" | "custom";
  xColumn?: string;
  yColumn?: string;
  colorColumn?: string;
  facetColumn?: string;
  title?: string;
  width: number;
  height: number;
  createdAt: string;
  modifiedAt: string;
}

export interface FigureExport {
  id: string;
  format: "png" | "svg" | "pdf";
  width: number;
  height: number;
  data: string; // Base64-encoded for png/pdf, raw SVG string for svg
}

export interface DatasetsResponse {
  status: string;
  count: number;
  datasets: Dataset[];
}

export interface FiguresResponse {
  status: string;
  count: number;
  figures: Figure[];
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

export class ImploreClient {
  constructor(private baseURL: string) {}

  /**
   * Check if implore is running and accessible.
   */
  async checkStatus(): Promise<ImploreStatus | null> {
    try {
      const response = await fetch(`${this.baseURL}/api/status`, {
        signal: AbortSignal.timeout(2000),
      });
      if (!response.ok) return null;
      return (await response.json()) as ImploreStatus;
    } catch {
      return null;
    }
  }

  /**
   * List all open datasets.
   */
  async listDatasets(): Promise<DatasetsResponse> {
    const response = await fetch(`${this.baseURL}/api/datasets`);
    if (!response.ok) {
      throw new Error(`List datasets failed: ${response.statusText}`);
    }
    return (await response.json()) as DatasetsResponse;
  }

  /**
   * Get a specific dataset.
   */
  async getDataset(id: string): Promise<Dataset | null> {
    const response = await fetch(`${this.baseURL}/api/datasets/${id}`);
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get dataset failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; dataset: Dataset };
    return data.dataset;
  }

  /**
   * List all figures.
   */
  async listFigures(datasetId?: string): Promise<FiguresResponse> {
    const url = datasetId
      ? `${this.baseURL}/api/figures?dataset=${datasetId}`
      : `${this.baseURL}/api/figures`;
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`List figures failed: ${response.statusText}`);
    }
    return (await response.json()) as FiguresResponse;
  }

  /**
   * Get a specific figure.
   */
  async getFigure(id: string): Promise<Figure | null> {
    const response = await fetch(`${this.baseURL}/api/figures/${id}`);
    if (!response.ok) {
      if (response.status === 404) return null;
      throw new Error(`Get figure failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; figure: Figure };
    return data.figure;
  }

  /**
   * Export a figure in a specific format.
   */
  async exportFigure(
    id: string,
    format: "png" | "svg" | "pdf" = "png",
    options: { width?: number; height?: number; scale?: number } = {}
  ): Promise<FigureExport> {
    const params = new URLSearchParams({ format });
    if (options.width) params.set("width", String(options.width));
    if (options.height) params.set("height", String(options.height));
    if (options.scale) params.set("scale", String(options.scale));

    const response = await fetch(
      `${this.baseURL}/api/figures/${id}/export?${params.toString()}`
    );
    if (!response.ok) {
      throw new Error(`Export figure failed: ${response.statusText}`);
    }
    return (await response.json()) as FigureExport;
  }

  /**
   * Create a new figure from a dataset.
   */
  async createFigure(
    datasetId: string,
    options: {
      name?: string;
      type: Figure["type"];
      xColumn?: string;
      yColumn?: string;
      colorColumn?: string;
      title?: string;
      width?: number;
      height?: number;
    }
  ): Promise<Figure> {
    const response = await fetch(`${this.baseURL}/api/figures`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        datasetId,
        ...options,
      }),
    });
    if (!response.ok) {
      throw new Error(`Create figure failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; figure: Figure };
    return data.figure;
  }

  /**
   * Update a figure.
   */
  async updateFigure(
    id: string,
    updates: {
      name?: string;
      type?: Figure["type"];
      xColumn?: string;
      yColumn?: string;
      colorColumn?: string;
      title?: string;
      width?: number;
      height?: number;
    }
  ): Promise<Figure> {
    const response = await fetch(`${this.baseURL}/api/figures/${id}`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(updates),
    });
    if (!response.ok) {
      throw new Error(`Update figure failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; figure: Figure };
    return data.figure;
  }

  /**
   * Delete a figure.
   */
  async deleteFigure(id: string): Promise<{ deleted: boolean }> {
    const response = await fetch(`${this.baseURL}/api/figures/${id}`, {
      method: "DELETE",
    });
    if (!response.ok) {
      throw new Error(`Delete figure failed: ${response.statusText}`);
    }
    const data = (await response.json()) as { status: string; deleted: boolean };
    return { deleted: data.deleted };
  }

  /**
   * Get log entries from implore.
   */
  async getLogs(
    options: {
      limit?: number;
      level?: string;
      category?: string;
      search?: string;
      after?: string;
    } = {}
  ): Promise<LogsResponse> {
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
}
