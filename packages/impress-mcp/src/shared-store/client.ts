/**
 * SharedStoreClient — read-only access to the shared impress-core SQLite database.
 *
 * Opens the shared database at the group.com.impress.suite app group container path
 * and provides structured queries over the items table.
 */

import Database from "better-sqlite3";
import * as os from "os";
import * as path from "path";
import * as fs from "fs";

export interface SharedItem {
  id: string;
  schema_ref: string;
  payload: Record<string, unknown>;
  created: string;
  modified: string;
  is_read: boolean;
  is_starred: boolean;
  tags: string[];
  parent_id: string | null;
}

export interface SharedEdge {
  source_id: string;
  target_id: string;
  edge_type: string;
  metadata: Record<string, unknown> | null;
}

export class SharedStoreClient {
  private db: Database.Database | null = null;
  private dbPath: string;

  constructor() {
    this.dbPath = this.resolveSharedDBPath();
  }

  private resolveSharedDBPath(): string {
    // macOS app group container path
    const home = os.homedir();
    // Standard macOS app group container location
    const containerBase = path.join(
      home,
      "Library",
      "Group Containers",
      "group.com.impress.suite",
      "workspace"
    );
    return path.join(containerBase, "impress.sqlite");
  }

  connect(): boolean {
    if (!fs.existsSync(this.dbPath)) {
      return false;
    }
    try {
      this.db = new Database(this.dbPath, { readonly: true, fileMustExist: true });
      return true;
    } catch {
      this.db = null;
      return false;
    }
  }

  isConnected(): boolean {
    return this.db !== null;
  }

  getDbPath(): string {
    return this.dbPath;
  }

  /**
   * Full-text search across all items, optionally filtered by schema.
   */
  searchItems(query: string, schemas?: string[], limit = 20): SharedItem[] {
    if (!this.db) return [];
    try {
      let sql: string;
      const params: unknown[] = [];

      if (query.trim()) {
        // Use FTS if available, fallback to LIKE
        sql = `
          SELECT i.id, i.schema_ref, i.payload, i.created, i.modified,
                 i.is_read, i.is_starred, i.parent_id
          FROM items i
          WHERE (i.payload LIKE ? OR i.id LIKE ?)
          ${schemas && schemas.length > 0 ? "AND i.schema_ref IN (" + schemas.map(() => "?").join(",") + ")" : ""}
          ORDER BY i.modified DESC
          LIMIT ?
        `;
        const like = `%${query}%`;
        params.push(like, like);
        if (schemas && schemas.length > 0) params.push(...schemas);
        params.push(limit);
      } else {
        sql = `
          SELECT i.id, i.schema_ref, i.payload, i.created, i.modified,
                 i.is_read, i.is_starred, i.parent_id
          FROM items i
          ${schemas && schemas.length > 0 ? "WHERE i.schema_ref IN (" + schemas.map(() => "?").join(",") + ")" : ""}
          ORDER BY i.modified DESC
          LIMIT ?
        `;
        if (schemas && schemas.length > 0) params.push(...schemas);
        params.push(limit);
      }

      const rows = this.db.prepare(sql).all(...params) as Array<{
        id: string; schema_ref: string; payload: string;
        created: string; modified: string; is_read: number;
        is_starred: number; parent_id: string | null;
      }>;

      return rows.map(row => ({
        id: row.id,
        schema_ref: row.schema_ref,
        payload: this.parseJSON(row.payload),
        created: row.created,
        modified: row.modified,
        is_read: row.is_read === 1,
        is_starred: row.is_starred === 1,
        tags: [],
        parent_id: row.parent_id,
      }));
    } catch {
      return [];
    }
  }

  /**
   * Get a single item by ID.
   */
  getItem(id: string): SharedItem | null {
    if (!this.db) return null;
    try {
      const row = this.db.prepare(`
        SELECT id, schema_ref, payload, created, modified, is_read, is_starred, parent_id
        FROM items WHERE id = ?
      `).get(id) as { id: string; schema_ref: string; payload: string; created: string; modified: string; is_read: number; is_starred: number; parent_id: string | null } | undefined;
      if (!row) return null;
      return {
        id: row.id,
        schema_ref: row.schema_ref,
        payload: this.parseJSON(row.payload),
        created: row.created,
        modified: row.modified,
        is_read: row.is_read === 1,
        is_starred: row.is_starred === 1,
        tags: [],
        parent_id: row.parent_id,
      };
    } catch {
      return null;
    }
  }

  /**
   * Get edges (references) from an item.
   */
  getEdges(itemId: string, edgeType?: string): SharedEdge[] {
    if (!this.db) return [];
    try {
      // References stored in item_references table or embedded in payload
      // Try item_references table first
      const hasTable = this.db.prepare(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='item_references'"
      ).get();

      if (!hasTable) return [];

      const sql = edgeType
        ? "SELECT source_id, target_id, edge_type, metadata FROM item_references WHERE source_id = ? AND edge_type = ?"
        : "SELECT source_id, target_id, edge_type, metadata FROM item_references WHERE source_id = ?";
      const params = edgeType ? [itemId, edgeType] : [itemId];

      const rows = this.db.prepare(sql).all(...params) as Array<{
        source_id: string; target_id: string; edge_type: string; metadata: string | null;
      }>;

      return rows.map(row => ({
        source_id: row.source_id,
        target_id: row.target_id,
        edge_type: row.edge_type,
        metadata: row.metadata ? this.parseJSON(row.metadata) : null,
      }));
    } catch {
      return [];
    }
  }

  private parseJSON(s: string): Record<string, unknown> {
    try { return JSON.parse(s); } catch { return {}; }
  }

  close(): void {
    this.db?.close();
    this.db = null;
  }
}
