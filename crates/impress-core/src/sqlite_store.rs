use std::collections::BTreeMap;
use std::path::Path;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Mutex;

use chrono::{TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension};

use crate::event::ItemEvent;
use crate::item::{ActorKind, FlagState, Item, ItemId, Value};
use crate::query::ItemQuery;
use crate::reference::{EdgeType, TypedReference};
use crate::sql_query::compile_query;
use crate::store::{FieldMutation, ItemStore, StoreError};

/// SQLite-backed implementation of the ItemStore trait.
pub struct SqliteItemStore {
    conn: Mutex<Connection>,
    event_tx: Sender<ItemEvent>,
    event_rx: Mutex<Option<Receiver<ItemEvent>>>,
}

impl SqliteItemStore {
    /// Open (or create) a database at the given path.
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        let conn =
            Connection::open(path).map_err(|e| StoreError::Storage(format!("open: {}", e)))?;
        Self::init_with_connection(conn)
    }

    /// Create an in-memory database (for testing).
    pub fn open_in_memory() -> Result<Self, StoreError> {
        let conn = Connection::open_in_memory()
            .map_err(|e| StoreError::Storage(format!("open_in_memory: {}", e)))?;
        Self::init_with_connection(conn)
    }

    fn init_with_connection(conn: Connection) -> Result<Self, StoreError> {
        Self::init_schema(&conn)?;
        let (tx, rx) = mpsc::channel();
        Ok(Self {
            conn: Mutex::new(conn),
            event_tx: tx,
            event_rx: Mutex::new(Some(rx)),
        })
    }

    fn init_schema(conn: &Connection) -> Result<(), StoreError> {
        conn.execute_batch(
            "
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                schema_ref TEXT NOT NULL,
                payload TEXT NOT NULL,
                created INTEGER NOT NULL,
                modified INTEGER NOT NULL,
                author TEXT NOT NULL,
                author_kind TEXT NOT NULL,
                is_read INTEGER NOT NULL DEFAULT 0,
                is_starred INTEGER NOT NULL DEFAULT 0,
                flag_color TEXT,
                flag_style TEXT,
                flag_length TEXT,
                parent_id TEXT REFERENCES items(id) ON DELETE SET NULL
            );

            CREATE TABLE IF NOT EXISTS item_tags (
                item_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                tag_path TEXT NOT NULL,
                PRIMARY KEY (item_id, tag_path)
            );

            CREATE TABLE IF NOT EXISTS item_references (
                source_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                target_id TEXT NOT NULL REFERENCES items(id) ON DELETE CASCADE,
                edge_type TEXT NOT NULL,
                metadata TEXT,
                PRIMARY KEY (source_id, target_id, edge_type)
            );

            CREATE INDEX IF NOT EXISTS idx_items_schema ON items(schema_ref);
            CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_id);
            CREATE INDEX IF NOT EXISTS idx_items_created ON items(created);
            CREATE INDEX IF NOT EXISTS idx_items_modified ON items(modified);
            CREATE INDEX IF NOT EXISTS idx_items_flag ON items(flag_color);
            CREATE INDEX IF NOT EXISTS idx_items_read ON items(is_read);
            CREATE INDEX IF NOT EXISTS idx_items_starred ON items(is_starred);
            CREATE INDEX IF NOT EXISTS idx_item_tags_path ON item_tags(tag_path);
            CREATE INDEX IF NOT EXISTS idx_item_refs_target ON item_references(target_id, edge_type);
            ",
        )
        .map_err(|e| StoreError::Storage(format!("init_schema: {}", e)))?;

        // FTS5 table — standalone (not external content) for simplicity.
        // We store the item_id and manage inserts/deletes ourselves.
        conn.execute_batch(
            "
            CREATE VIRTUAL TABLE IF NOT EXISTS items_fts USING fts5(
                item_id UNINDEXED,
                title, author_text, abstract_text, note
            );
            ",
        )
        .map_err(|e| StoreError::Storage(format!("init_fts: {}", e)))?;

        Ok(())
    }

    fn emit(&self, event: ItemEvent) {
        // Ignore send errors (receiver may be dropped)
        let _ = self.event_tx.send(event);
    }

    /// Insert a single item into the database.
    fn insert_item(conn: &Connection, item: &Item) -> Result<(), StoreError> {
        let payload_json =
            serde_json::to_string(&item.payload).map_err(|e| StoreError::Storage(e.to_string()))?;
        let author_kind = match item.author_kind {
            ActorKind::Human => "human",
            ActorKind::Agent => "agent",
            ActorKind::System => "system",
        };
        let (flag_color, flag_style, flag_length) = match &item.flag {
            Some(f) => (
                Some(f.color.clone()),
                f.style.clone(),
                f.length.clone(),
            ),
            None => (None, None, None),
        };
        let parent_id = item.parent.map(|p| p.to_string());

        conn.execute(
            "INSERT INTO items (id, schema_ref, payload, created, modified, author, author_kind, is_read, is_starred, flag_color, flag_style, flag_length, parent_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                item.id.to_string(),
                item.schema,
                payload_json,
                item.created.timestamp_millis(),
                item.modified.timestamp_millis(),
                item.author,
                author_kind,
                item.is_read as i32,
                item.is_starred as i32,
                flag_color,
                flag_style,
                flag_length,
                parent_id,
            ],
        )
        .map_err(|e| {
            if let rusqlite::Error::SqliteFailure(ref err, _) = e {
                if err.code == rusqlite::ErrorCode::ConstraintViolation {
                    return StoreError::AlreadyExists(item.id);
                }
            }
            StoreError::Storage(format!("insert: {}", e))
        })?;

        // Insert tags
        for tag in &item.tags {
            conn.execute(
                "INSERT OR IGNORE INTO item_tags (item_id, tag_path) VALUES (?1, ?2)",
                params![item.id.to_string(), tag],
            )
            .map_err(|e| StoreError::Storage(format!("insert tag: {}", e)))?;
        }

        // Insert references
        for r in &item.references {
            let edge_str = serde_json::to_string(&r.edge_type)
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            let meta_str = r
                .metadata
                .as_ref()
                .map(|m| serde_json::to_string(m).unwrap_or_default());
            conn.execute(
                "INSERT OR IGNORE INTO item_references (source_id, target_id, edge_type, metadata) VALUES (?1, ?2, ?3, ?4)",
                params![item.id.to_string(), r.target.to_string(), edge_str, meta_str],
            )
            .map_err(|e| StoreError::Storage(format!("insert ref: {}", e)))?;
        }

        // Update FTS index
        Self::update_fts(conn, item)?;

        Ok(())
    }

    /// Update the FTS index for an item.
    fn update_fts(conn: &Connection, item: &Item) -> Result<(), StoreError> {
        let id_str = item.id.to_string();
        let title = extract_string_field(&item.payload, "title");
        let author_text = extract_string_field(&item.payload, "author_text");
        let abstract_text = extract_string_field(&item.payload, "abstract_text");
        let note = extract_string_field(&item.payload, "note");

        // Only index if there's content
        if title.is_some() || author_text.is_some() || abstract_text.is_some() || note.is_some() {
            conn.execute(
                "INSERT INTO items_fts (item_id, title, author_text, abstract_text, note)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    id_str,
                    title.unwrap_or_default(),
                    author_text.unwrap_or_default(),
                    abstract_text.unwrap_or_default(),
                    note.unwrap_or_default(),
                ],
            )
            .map_err(|e| StoreError::Storage(format!("update_fts: {}", e)))?;
        }

        Ok(())
    }

    /// Delete FTS entries for an item.
    fn delete_fts(conn: &Connection, item_id_str: &str) -> Result<(), StoreError> {
        conn.execute(
            "DELETE FROM items_fts WHERE item_id = ?1",
            params![item_id_str],
        )
        .map_err(|e| StoreError::Storage(format!("delete_fts: {}", e)))?;
        Ok(())
    }

    /// Read an item from a row result.
    fn row_to_item(conn: &Connection, row: &rusqlite::Row<'_>) -> Result<Item, StoreError> {
        let id_str: String = row
            .get(0)
            .map_err(|e| StoreError::Storage(format!("row id: {}", e)))?;
        let id: ItemId =
            uuid::Uuid::parse_str(&id_str).map_err(|e| StoreError::Storage(e.to_string()))?;

        let schema_ref: String = row
            .get(1)
            .map_err(|e| StoreError::Storage(format!("row schema: {}", e)))?;
        let payload_json: String = row
            .get(2)
            .map_err(|e| StoreError::Storage(format!("row payload: {}", e)))?;
        let payload: BTreeMap<String, Value> = serde_json::from_str(&payload_json)
            .map_err(|e| StoreError::Storage(format!("parse payload: {}", e)))?;

        let created_ms: i64 = row
            .get(3)
            .map_err(|e| StoreError::Storage(format!("row created: {}", e)))?;
        let modified_ms: i64 = row
            .get(4)
            .map_err(|e| StoreError::Storage(format!("row modified: {}", e)))?;
        let author: String = row
            .get(5)
            .map_err(|e| StoreError::Storage(format!("row author: {}", e)))?;
        let author_kind_str: String = row
            .get(6)
            .map_err(|e| StoreError::Storage(format!("row author_kind: {}", e)))?;
        let is_read: bool = row
            .get(7)
            .map_err(|e| StoreError::Storage(format!("row is_read: {}", e)))?;
        let is_starred: bool = row
            .get(8)
            .map_err(|e| StoreError::Storage(format!("row is_starred: {}", e)))?;
        let flag_color: Option<String> = row
            .get(9)
            .map_err(|e| StoreError::Storage(format!("row flag_color: {}", e)))?;
        let flag_style: Option<String> = row
            .get(10)
            .map_err(|e| StoreError::Storage(format!("row flag_style: {}", e)))?;
        let flag_length: Option<String> = row
            .get(11)
            .map_err(|e| StoreError::Storage(format!("row flag_length: {}", e)))?;
        let parent_id_str: Option<String> = row
            .get(12)
            .map_err(|e| StoreError::Storage(format!("row parent_id: {}", e)))?;

        let created = Utc
            .timestamp_millis_opt(created_ms)
            .single()
            .unwrap_or_else(Utc::now);
        let modified = Utc
            .timestamp_millis_opt(modified_ms)
            .single()
            .unwrap_or_else(Utc::now);
        let author_kind = match author_kind_str.as_str() {
            "agent" => ActorKind::Agent,
            "system" => ActorKind::System,
            _ => ActorKind::Human,
        };
        let flag = flag_color.map(|color| FlagState {
            color,
            style: flag_style,
            length: flag_length,
        });
        let parent = parent_id_str
            .and_then(|s| uuid::Uuid::parse_str(&s).ok());

        // Load tags
        let id_str_owned = id.to_string();
        let tags = Self::load_tags(conn, &id_str_owned)?;

        // Load references
        let references = Self::load_references(conn, &id_str_owned)?;

        Ok(Item {
            id,
            schema: schema_ref,
            payload,
            created,
            modified,
            author,
            author_kind,
            tags,
            flag,
            is_read,
            is_starred,
            references,
            parent,
        })
    }

    fn load_tags(conn: &Connection, item_id: &str) -> Result<Vec<String>, StoreError> {
        let mut stmt = conn
            .prepare("SELECT tag_path FROM item_tags WHERE item_id = ?1 ORDER BY tag_path")
            .map_err(|e| StoreError::Storage(format!("prepare tags: {}", e)))?;
        let tags = stmt
            .query_map(params![item_id], |row| row.get(0))
            .map_err(|e| StoreError::Storage(format!("query tags: {}", e)))?
            .collect::<Result<Vec<String>, _>>()
            .map_err(|e| StoreError::Storage(format!("collect tags: {}", e)))?;
        Ok(tags)
    }

    fn load_references(
        conn: &Connection,
        item_id: &str,
    ) -> Result<Vec<TypedReference>, StoreError> {
        let mut stmt = conn
            .prepare("SELECT target_id, edge_type, metadata FROM item_references WHERE source_id = ?1")
            .map_err(|e| StoreError::Storage(format!("prepare refs: {}", e)))?;
        let refs = stmt
            .query_map(params![item_id], |row| {
                let target_str: String = row.get(0)?;
                let edge_str: String = row.get(1)?;
                let meta_str: Option<String> = row.get(2)?;
                Ok((target_str, edge_str, meta_str))
            })
            .map_err(|e| StoreError::Storage(format!("query refs: {}", e)))?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| StoreError::Storage(format!("collect refs: {}", e)))?;

        let mut result = Vec::new();
        for (target_str, edge_str, meta_str) in refs {
            let target = uuid::Uuid::parse_str(&target_str)
                .map_err(|e| StoreError::Storage(format!("parse ref target: {}", e)))?;
            let edge_type: EdgeType = serde_json::from_str(&edge_str)
                .map_err(|e| StoreError::Storage(format!("parse edge_type: {}", e)))?;
            let metadata: Option<BTreeMap<String, Value>> = meta_str
                .map(|s| serde_json::from_str(&s))
                .transpose()
                .map_err(|e| StoreError::Storage(format!("parse ref metadata: {}", e)))?;
            result.push(TypedReference {
                target,
                edge_type,
                metadata,
            });
        }
        Ok(result)
    }
}

impl ItemStore for SqliteItemStore {
    fn insert(&self, item: Item) -> Result<ItemId, StoreError> {
        let conn = self.conn.lock().map_err(|e| StoreError::Storage(e.to_string()))?;
        let id = item.id;
        Self::insert_item(&conn, &item)?;
        drop(conn);
        self.emit(ItemEvent::Created(Box::new(item)));
        Ok(id)
    }

    fn insert_batch(&self, items: Vec<Item>) -> Result<Vec<ItemId>, StoreError> {
        let conn = self.conn.lock().map_err(|e| StoreError::Storage(e.to_string()))?;
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| StoreError::Storage(format!("begin tx: {}", e)))?;

        let mut ids = Vec::with_capacity(items.len());
        for item in &items {
            Self::insert_item(&tx, item)?;
            ids.push(item.id);
        }

        tx.commit()
            .map_err(|e| StoreError::Storage(format!("commit: {}", e)))?;

        drop(conn);
        for item in items {
            self.emit(ItemEvent::Created(Box::new(item)));
        }
        Ok(ids)
    }

    fn get(&self, id: ItemId) -> Result<Option<Item>, StoreError> {
        let conn = self.conn.lock().map_err(|e| StoreError::Storage(e.to_string()))?;
        let mut stmt = conn
            .prepare(
                "SELECT id, schema_ref, payload, created, modified, author, author_kind,
                        is_read, is_starred, flag_color, flag_style, flag_length, parent_id
                 FROM items WHERE id = ?1",
            )
            .map_err(|e| StoreError::Storage(format!("prepare get: {}", e)))?;

        let item = stmt
            .query_row(params![id.to_string()], |row| {
                Ok(Self::row_to_item(&conn, row))
            })
            .optional()
            .map_err(|e| StoreError::Storage(format!("query get: {}", e)))?;

        match item {
            Some(Ok(item)) => Ok(Some(item)),
            Some(Err(e)) => Err(e),
            None => Ok(None),
        }
    }

    fn update(&self, id: ItemId, mutations: Vec<FieldMutation>) -> Result<(), StoreError> {
        let conn = self.conn.lock().map_err(|e| StoreError::Storage(e.to_string()))?;
        let id_str = id.to_string();

        // Check item exists
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM items WHERE id = ?1",
                params![&id_str],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .map_err(|e| StoreError::Storage(format!("check exists: {}", e)))?;

        if !exists {
            return Err(StoreError::NotFound(id));
        }

        let now = Utc::now().timestamp_millis();
        let mut fts_needs_update = false;

        for mutation in &mutations {
            match mutation {
                FieldMutation::SetPayload(field, value) => {
                    let json_val = serde_json::to_string(value)
                        .map_err(|e| StoreError::Storage(e.to_string()))?;
                    let path = format!("$.{}", field);
                    conn.execute(
                        "UPDATE items SET payload = json_set(payload, ?1, json(?2)), modified = ?3 WHERE id = ?4",
                        params![path, json_val, now, &id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("set payload: {}", e)))?;
                    if matches!(field.as_str(), "title" | "author_text" | "abstract_text" | "note") {
                        fts_needs_update = true;
                    }
                }
                FieldMutation::RemovePayload(field) => {
                    let path = format!("$.{}", field);
                    conn.execute(
                        "UPDATE items SET payload = json_remove(payload, ?1), modified = ?2 WHERE id = ?3",
                        params![path, now, &id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("remove payload: {}", e)))?;
                    if matches!(field.as_str(), "title" | "author_text" | "abstract_text" | "note") {
                        fts_needs_update = true;
                    }
                }
                FieldMutation::SetRead(v) => {
                    conn.execute(
                        "UPDATE items SET is_read = ?1, modified = ?2 WHERE id = ?3",
                        params![*v as i32, now, &id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("set read: {}", e)))?;
                }
                FieldMutation::SetStarred(v) => {
                    conn.execute(
                        "UPDATE items SET is_starred = ?1, modified = ?2 WHERE id = ?3",
                        params![*v as i32, now, &id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("set starred: {}", e)))?;
                }
                FieldMutation::SetFlag(flag) => {
                    let (color, style, length) = match flag {
                        Some(f) => (Some(f.color.clone()), f.style.clone(), f.length.clone()),
                        None => (None, None, None),
                    };
                    conn.execute(
                        "UPDATE items SET flag_color = ?1, flag_style = ?2, flag_length = ?3, modified = ?4 WHERE id = ?5",
                        params![color, style, length, now, &id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("set flag: {}", e)))?;
                }
                FieldMutation::AddTag(tag_path) => {
                    conn.execute(
                        "INSERT OR IGNORE INTO item_tags (item_id, tag_path) VALUES (?1, ?2)",
                        params![&id_str, tag_path],
                    )
                    .map_err(|e| StoreError::Storage(format!("add tag: {}", e)))?;
                    conn.execute(
                        "UPDATE items SET modified = ?1 WHERE id = ?2",
                        params![now, &id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("update modified: {}", e)))?;
                }
                FieldMutation::RemoveTag(tag_path) => {
                    conn.execute(
                        "DELETE FROM item_tags WHERE item_id = ?1 AND tag_path = ?2",
                        params![&id_str, tag_path],
                    )
                    .map_err(|e| StoreError::Storage(format!("remove tag: {}", e)))?;
                    conn.execute(
                        "UPDATE items SET modified = ?1 WHERE id = ?2",
                        params![now, &id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("update modified: {}", e)))?;
                }
                FieldMutation::AddReference(typed_ref) => {
                    let edge_str = serde_json::to_string(&typed_ref.edge_type)
                        .map_err(|e| StoreError::Storage(e.to_string()))?;
                    let meta_str = typed_ref
                        .metadata
                        .as_ref()
                        .map(|m| serde_json::to_string(m).unwrap_or_default());
                    conn.execute(
                        "INSERT OR IGNORE INTO item_references (source_id, target_id, edge_type, metadata) VALUES (?1, ?2, ?3, ?4)",
                        params![&id_str, typed_ref.target.to_string(), edge_str, meta_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("add ref: {}", e)))?;
                }
                FieldMutation::RemoveReference(target_id, edge_type) => {
                    let edge_str = serde_json::to_string(edge_type)
                        .map_err(|e| StoreError::Storage(e.to_string()))?;
                    conn.execute(
                        "DELETE FROM item_references WHERE source_id = ?1 AND target_id = ?2 AND edge_type = ?3",
                        params![&id_str, target_id.to_string(), edge_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("remove ref: {}", e)))?;
                }
                FieldMutation::SetParent(parent_id) => {
                    let parent_str = parent_id.map(|p| p.to_string());
                    conn.execute(
                        "UPDATE items SET parent_id = ?1, modified = ?2 WHERE id = ?3",
                        params![parent_str, now, &id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("set parent: {}", e)))?;
                }
            }
        }

        // Rebuild FTS if needed
        if fts_needs_update {
            // Delete old FTS entry
            Self::delete_fts(&conn, &id_str)?;
            // Get updated item to re-index
            let mut stmt = conn
                .prepare("SELECT payload FROM items WHERE id = ?1")
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            let payload_json: String = stmt
                .query_row(params![&id_str], |row| row.get(0))
                .map_err(|e| StoreError::Storage(e.to_string()))?;
            let payload: BTreeMap<String, Value> =
                serde_json::from_str(&payload_json).unwrap_or_default();
            let title = extract_string_field(&payload, "title");
            let author_text = extract_string_field(&payload, "author_text");
            let abstract_text = extract_string_field(&payload, "abstract_text");
            let note = extract_string_field(&payload, "note");
            conn.execute(
                "INSERT INTO items_fts (item_id, title, author_text, abstract_text, note)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    &id_str,
                    title.unwrap_or_default(),
                    author_text.unwrap_or_default(),
                    abstract_text.unwrap_or_default(),
                    note.unwrap_or_default(),
                ],
            )
            .map_err(|e| StoreError::Storage(format!("reindex fts: {}", e)))?;
        }

        drop(conn);
        self.emit(ItemEvent::Updated {
            id,
            mutations,
        });
        Ok(())
    }

    fn delete(&self, id: ItemId) -> Result<(), StoreError> {
        let conn = self.conn.lock().map_err(|e| StoreError::Storage(e.to_string()))?;
        let id_str = id.to_string();

        // Delete FTS entry first
        Self::delete_fts(&conn, &id_str)?;

        // Foreign key CASCADE handles item_tags and item_references
        let rows = conn
            .execute("DELETE FROM items WHERE id = ?1", params![&id_str])
            .map_err(|e| StoreError::Storage(format!("delete: {}", e)))?;

        if rows == 0 {
            return Err(StoreError::NotFound(id));
        }

        drop(conn);
        self.emit(ItemEvent::Deleted(id));
        Ok(())
    }

    fn query(&self, q: &ItemQuery) -> Result<Vec<Item>, StoreError> {
        let conn = self.conn.lock().map_err(|e| StoreError::Storage(e.to_string()))?;
        let compiled = compile_query(q);

        let sql = format!(
            "SELECT id, schema_ref, payload, created, modified, author, author_kind,
                    is_read, is_starred, flag_color, flag_style, flag_length, parent_id
             FROM items {} {} {}",
            compiled.where_clause, compiled.order_clause, compiled.limit_offset
        );

        let params_ref: Vec<&dyn rusqlite::types::ToSql> =
            compiled.params.iter().map(|p| p as &dyn rusqlite::types::ToSql).collect();

        let mut stmt = conn
            .prepare(&sql)
            .map_err(|e| StoreError::Storage(format!("prepare query: {} (sql: {})", e, sql)))?;

        let rows = stmt
            .query_map(params_ref.as_slice(), |row| {
                Ok(Self::row_to_item(&conn, row))
            })
            .map_err(|e| StoreError::Storage(format!("query: {}", e)))?;

        let mut items = Vec::new();
        for row_result in rows {
            let item_result =
                row_result.map_err(|e| StoreError::Storage(format!("row: {}", e)))?;
            items.push(item_result?);
        }
        Ok(items)
    }

    fn count(&self, q: &ItemQuery) -> Result<usize, StoreError> {
        let conn = self.conn.lock().map_err(|e| StoreError::Storage(e.to_string()))?;
        let compiled = compile_query(q);

        let sql = format!("SELECT COUNT(*) FROM items {}", compiled.where_clause);
        let params_ref: Vec<&dyn rusqlite::types::ToSql> =
            compiled.params.iter().map(|p| p as &dyn rusqlite::types::ToSql).collect();

        let count: i64 = conn
            .query_row(&sql, params_ref.as_slice(), |row| row.get(0))
            .map_err(|e| StoreError::Storage(format!("count: {}", e)))?;

        Ok(count as usize)
    }

    fn neighbors(
        &self,
        id: ItemId,
        edge_types: &[EdgeType],
        depth: u32,
    ) -> Result<Vec<Item>, StoreError> {
        if depth == 0 {
            return Ok(Vec::new());
        }

        let conn = self.conn.lock().map_err(|e| StoreError::Storage(e.to_string()))?;
        let mut visited = std::collections::HashSet::new();
        let mut frontier = vec![id];
        let mut result = Vec::new();

        for _ in 0..depth {
            let mut next_frontier = Vec::new();
            for current_id in &frontier {
                if !visited.insert(*current_id) {
                    continue;
                }
                let id_str = current_id.to_string();

                // Get outgoing references matching edge types
                let edge_strs: Vec<String> = edge_types
                    .iter()
                    .map(|e| serde_json::to_string(e).unwrap_or_default())
                    .collect();
                let placeholders: Vec<String> =
                    (0..edge_strs.len()).map(|i| format!("?{}", i + 2)).collect();
                let sql = format!(
                    "SELECT target_id FROM item_references WHERE source_id = ?1 AND edge_type IN ({})",
                    placeholders.join(", ")
                );

                let mut params_vec: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
                params_vec.push(Box::new(id_str.clone()));
                for e in &edge_strs {
                    params_vec.push(Box::new(e.clone()));
                }
                let params_ref: Vec<&dyn rusqlite::types::ToSql> =
                    params_vec.iter().map(|p| p.as_ref()).collect();

                let mut stmt = conn.prepare(&sql).map_err(|e| StoreError::Storage(e.to_string()))?;
                let target_ids: Vec<String> = stmt
                    .query_map(params_ref.as_slice(), |row| row.get(0))
                    .map_err(|e| StoreError::Storage(e.to_string()))?
                    .collect::<Result<_, _>>()
                    .map_err(|e| StoreError::Storage(e.to_string()))?;

                for target_str in target_ids {
                    if let Ok(target_id) = uuid::Uuid::parse_str(&target_str) {
                        if !visited.contains(&target_id) {
                            next_frontier.push(target_id);
                        }
                    }
                }

                // Also get incoming references
                let sql_incoming = format!(
                    "SELECT source_id FROM item_references WHERE target_id = ?1 AND edge_type IN ({})",
                    placeholders.join(", ")
                );
                let mut params_vec_in: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();
                params_vec_in.push(Box::new(id_str));
                for e in &edge_strs {
                    params_vec_in.push(Box::new(e.clone()));
                }
                let params_ref_in: Vec<&dyn rusqlite::types::ToSql> =
                    params_vec_in.iter().map(|p| p.as_ref()).collect();

                let mut stmt_in = conn
                    .prepare(&sql_incoming)
                    .map_err(|e| StoreError::Storage(e.to_string()))?;
                let source_ids: Vec<String> = stmt_in
                    .query_map(params_ref_in.as_slice(), |row| row.get(0))
                    .map_err(|e| StoreError::Storage(e.to_string()))?
                    .collect::<Result<_, _>>()
                    .map_err(|e| StoreError::Storage(e.to_string()))?;

                for source_str in source_ids {
                    if let Ok(source_id) = uuid::Uuid::parse_str(&source_str) {
                        if !visited.contains(&source_id) {
                            next_frontier.push(source_id);
                        }
                    }
                }
            }

            // Fetch the items for this frontier
            for neighbor_id in &next_frontier {
                let neighbor_str = neighbor_id.to_string();
                let mut stmt = conn
                    .prepare(
                        "SELECT id, schema_ref, payload, created, modified, author, author_kind,
                                is_read, is_starred, flag_color, flag_style, flag_length, parent_id
                         FROM items WHERE id = ?1",
                    )
                    .map_err(|e| StoreError::Storage(e.to_string()))?;
                if let Some(item) = stmt
                    .query_row(params![&neighbor_str], |row| {
                        Ok(Self::row_to_item(&conn, row))
                    })
                    .optional()
                    .map_err(|e| StoreError::Storage(e.to_string()))?
                {
                    result.push(item?);
                }
            }

            frontier = next_frontier;
            if frontier.is_empty() {
                break;
            }
        }

        Ok(result)
    }

    fn subscribe(&self, _q: ItemQuery) -> Result<Receiver<ItemEvent>, StoreError> {
        let rx = self
            .event_rx
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?
            .take()
            .ok_or_else(|| {
                StoreError::Storage("subscribe: receiver already taken".to_string())
            })?;
        Ok(rx)
    }
}

/// Extract a string field from a payload BTreeMap.
fn extract_string_field(payload: &BTreeMap<String, Value>, field: &str) -> Option<String> {
    match payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{ActorKind, FlagState, Item, Value};
    use crate::query::{ItemQuery, Predicate, SortDescriptor};
    use crate::reference::{EdgeType, TypedReference};
    use chrono::Utc;
    use std::collections::BTreeMap;
    use uuid::Uuid;

    fn make_item(schema: &str, title: &str) -> Item {
        let mut payload = BTreeMap::new();
        payload.insert("title".into(), Value::String(title.into()));
        payload.insert(
            "author_text".into(),
            Value::String("Test Author".into()),
        );
        Item {
            id: Uuid::new_v4(),
            schema: schema.into(),
            payload,
            created: Utc::now(),
            modified: Utc::now(),
            author: "test@example.com".into(),
            author_kind: ActorKind::Human,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            references: vec![],
            parent: None,
        }
    }

    #[test]
    fn insert_and_get_round_trip() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("bibliography-entry", "Dark Matter in Galaxies");
        let id = store.insert(item.clone()).unwrap();
        let got = store.get(id).unwrap().unwrap();
        assert_eq!(got.id, item.id);
        assert_eq!(got.schema, item.schema);
        assert_eq!(got.payload, item.payload);
        assert_eq!(got.is_read, item.is_read);
        assert_eq!(got.is_starred, item.is_starred);
    }

    #[test]
    fn insert_duplicate_fails() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Test");
        store.insert(item.clone()).unwrap();
        let err = store.insert(item).unwrap_err();
        assert!(matches!(err, StoreError::AlreadyExists(_)));
    }

    #[test]
    fn batch_insert() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let items: Vec<Item> = (0..10)
            .map(|i| make_item("test", &format!("Item {}", i)))
            .collect();
        let ids = store.insert_batch(items).unwrap();
        assert_eq!(ids.len(), 10);
        let count = store.count(&ItemQuery::default()).unwrap();
        assert_eq!(count, 10);
    }

    #[test]
    fn query_by_schema() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        store
            .insert(make_item("bibliography-entry", "Paper 1"))
            .unwrap();
        store.insert(make_item("chat-message", "Hello")).unwrap();
        store
            .insert(make_item("bibliography-entry", "Paper 2"))
            .unwrap();

        let q = ItemQuery {
            schema: Some("bibliography-entry".into()),
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn query_is_read() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut item1 = make_item("test", "Read Paper");
        item1.is_read = true;
        store.insert(item1).unwrap();
        store.insert(make_item("test", "Unread Paper")).unwrap();

        let q = ItemQuery {
            predicates: vec![Predicate::IsRead(true)],
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].is_read);
    }

    #[test]
    fn query_is_starred() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut item1 = make_item("test", "Starred");
        item1.is_starred = true;
        store.insert(item1).unwrap();
        store.insert(make_item("test", "Not Starred")).unwrap();

        let q = ItemQuery {
            predicates: vec![Predicate::IsStarred(true)],
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].is_starred);
    }

    #[test]
    fn query_has_flag() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut flagged = make_item("test", "Flagged");
        flagged.flag = Some(FlagState {
            color: "red".into(),
            style: None,
            length: None,
        });
        store.insert(flagged).unwrap();
        store.insert(make_item("test", "Unflagged")).unwrap();

        // Any flag
        let q = ItemQuery {
            predicates: vec![Predicate::HasFlag(None)],
            ..Default::default()
        };
        assert_eq!(store.query(&q).unwrap().len(), 1);

        // Specific flag
        let q2 = ItemQuery {
            predicates: vec![Predicate::HasFlag(Some("red".into()))],
            ..Default::default()
        };
        assert_eq!(store.query(&q2).unwrap().len(), 1);

        // Non-matching flag
        let q3 = ItemQuery {
            predicates: vec![Predicate::HasFlag(Some("blue".into()))],
            ..Default::default()
        };
        assert_eq!(store.query(&q3).unwrap().len(), 0);
    }

    #[test]
    fn query_has_parent() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let parent = make_item("library", "My Library");
        let parent_id = parent.id;
        store.insert(parent).unwrap();

        let mut child = make_item("bibliography-entry", "Child Paper");
        child.parent = Some(parent_id);
        store.insert(child).unwrap();
        store.insert(make_item("bibliography-entry", "Orphan")).unwrap();

        let q = ItemQuery {
            predicates: vec![Predicate::HasParent(parent_id)],
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].parent, Some(parent_id));
    }

    #[test]
    fn query_has_tag() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut tagged = make_item("test", "Tagged Paper");
        tagged.tags = vec!["methods/sims/hydro".into(), "topics/cosmology".into()];
        store.insert(tagged.clone()).unwrap();
        store.insert(make_item("test", "Untagged")).unwrap();

        // Exact tag
        let q = ItemQuery {
            predicates: vec![Predicate::HasTag("topics/cosmology".into())],
            ..Default::default()
        };
        assert_eq!(store.query(&q).unwrap().len(), 1);

        // Prefix match
        let q2 = ItemQuery {
            predicates: vec![Predicate::HasTag("methods".into())],
            ..Default::default()
        };
        assert_eq!(store.query(&q2).unwrap().len(), 1);

        // Deeper prefix
        let q3 = ItemQuery {
            predicates: vec![Predicate::HasTag("methods/sims".into())],
            ..Default::default()
        };
        assert_eq!(store.query(&q3).unwrap().len(), 1);
    }

    #[test]
    fn query_payload_field() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut item = make_item("test", "DOI Paper");
        item.payload
            .insert("doi".into(), Value::String("10.1234/test".into()));
        store.insert(item).unwrap();
        store.insert(make_item("test", "No DOI")).unwrap();

        let q = ItemQuery {
            predicates: vec![Predicate::Eq(
                "payload.doi".into(),
                Value::String("10.1234/test".into()),
            )],
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn query_nested_and_or_not() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut item1 = make_item("test", "Read+Red");
        item1.is_read = true;
        item1.flag = Some(FlagState {
            color: "red".into(),
            style: None,
            length: None,
        });
        store.insert(item1).unwrap();

        let mut item2 = make_item("test", "Unread+Blue");
        item2.flag = Some(FlagState {
            color: "blue".into(),
            style: None,
            length: None,
        });
        store.insert(item2).unwrap();

        store.insert(make_item("test", "Unread+NoFlag")).unwrap();

        // NOT read AND (flag=red OR flag=blue)
        let q = ItemQuery {
            predicates: vec![Predicate::And(vec![
                Predicate::Not(Box::new(Predicate::IsRead(true))),
                Predicate::Or(vec![
                    Predicate::HasFlag(Some("red".into())),
                    Predicate::HasFlag(Some("blue".into())),
                ]),
            ])],
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].flag.as_ref().unwrap().color,
            "blue"
        );
    }

    #[test]
    fn query_sort_by_created() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        // Insert with slightly different timestamps
        for i in 0..5 {
            let mut item = make_item("test", &format!("Item {}", i));
            item.created = Utc::now() + chrono::Duration::milliseconds(i * 100);
            store.insert(item).unwrap();
        }

        let q = ItemQuery {
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        for i in 1..results.len() {
            assert!(results[i].created >= results[i - 1].created);
        }
    }

    #[test]
    fn query_limit_offset() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        for i in 0..20 {
            store
                .insert(make_item("test", &format!("Item {}", i)))
                .unwrap();
        }

        let q = ItemQuery {
            limit: Some(5),
            offset: Some(3),
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 5);
    }

    #[test]
    fn tag_operations() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Tag Test");
        let id = store.insert(item).unwrap();

        // Add tags
        store
            .update(id, vec![FieldMutation::AddTag("methods/sims".into())])
            .unwrap();
        store
            .update(id, vec![FieldMutation::AddTag("topics/cosmo".into())])
            .unwrap();

        let got = store.get(id).unwrap().unwrap();
        assert_eq!(got.tags.len(), 2);
        assert!(got.tags.contains(&"methods/sims".to_string()));

        // Remove tag
        store
            .update(id, vec![FieldMutation::RemoveTag("methods/sims".into())])
            .unwrap();
        let got2 = store.get(id).unwrap().unwrap();
        assert_eq!(got2.tags.len(), 1);
        assert!(!got2.tags.contains(&"methods/sims".to_string()));
    }

    #[test]
    fn reference_operations() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item1 = make_item("test", "Paper A");
        let item2 = make_item("test", "Paper B");
        let id1 = item1.id;
        let id2 = item2.id;
        store.insert(item1).unwrap();
        store.insert(item2).unwrap();

        // Add reference
        store
            .update(
                id1,
                vec![FieldMutation::AddReference(TypedReference {
                    target: id2,
                    edge_type: EdgeType::Cites,
                    metadata: None,
                })],
            )
            .unwrap();

        let got = store.get(id1).unwrap().unwrap();
        assert_eq!(got.references.len(), 1);
        assert_eq!(got.references[0].target, id2);
        assert_eq!(got.references[0].edge_type, EdgeType::Cites);

        // Remove reference
        store
            .update(
                id1,
                vec![FieldMutation::RemoveReference(id2, EdgeType::Cites)],
            )
            .unwrap();
        let got2 = store.get(id1).unwrap().unwrap();
        assert_eq!(got2.references.len(), 0);
    }

    #[test]
    fn fts_search() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut item1 = make_item("test", "Dark Matter in Galaxy Clusters");
        item1.payload.insert(
            "abstract_text".into(),
            Value::String("We study dark matter distributions".into()),
        );
        store.insert(item1).unwrap();

        let mut item2 = make_item("test", "Stellar Populations");
        item2.payload.insert(
            "abstract_text".into(),
            Value::String("Main sequence stars in the Milky Way".into()),
        );
        store.insert(item2).unwrap();

        let q = ItemQuery {
            predicates: vec![Predicate::Contains("title".into(), "Dark Matter".into())],
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].payload.get("title"),
            Some(&Value::String("Dark Matter in Galaxy Clusters".into()))
        );
    }

    #[test]
    fn delete_cascades() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut item = make_item("test", "Will Delete");
        item.tags = vec!["tag1".into(), "tag2".into()];
        let id = store.insert(item).unwrap();

        // Add a second item for reference targets
        let item2 = make_item("test", "Ref Target");
        let id2 = item2.id;
        store.insert(item2).unwrap();

        store
            .update(
                id,
                vec![FieldMutation::AddReference(TypedReference {
                    target: id2,
                    edge_type: EdgeType::Cites,
                    metadata: None,
                })],
            )
            .unwrap();

        // Delete
        store.delete(id).unwrap();

        // Item should be gone
        assert!(store.get(id).unwrap().is_none());

        // Tags and references should be cleaned up (no orphans)
        let conn = store.conn.lock().unwrap();
        let tag_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM item_tags WHERE item_id = ?1",
                params![id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(tag_count, 0);

        let ref_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM item_references WHERE source_id = ?1",
                params![id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(ref_count, 0);
    }

    #[test]
    fn event_emission() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let rx = store.subscribe(ItemQuery::default()).unwrap();

        let item = make_item("test", "Event Test");
        let id = store.insert(item).unwrap();

        // Should have received Created event
        let event = rx.try_recv().unwrap();
        assert!(matches!(event, ItemEvent::Created(_)));

        // Update
        store
            .update(id, vec![FieldMutation::SetRead(true)])
            .unwrap();
        let event = rx.try_recv().unwrap();
        assert!(matches!(event, ItemEvent::Updated { .. }));

        // Delete
        store.delete(id).unwrap();
        let event = rx.try_recv().unwrap();
        assert!(matches!(event, ItemEvent::Deleted(_)));
    }

    #[test]
    fn update_nonexistent_fails() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let err = store
            .update(Uuid::new_v4(), vec![FieldMutation::SetRead(true)])
            .unwrap_err();
        assert!(matches!(err, StoreError::NotFound(_)));
    }

    #[test]
    fn delete_nonexistent_fails() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let err = store.delete(Uuid::new_v4()).unwrap_err();
        assert!(matches!(err, StoreError::NotFound(_)));
    }

    #[test]
    fn get_nonexistent_returns_none() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let result = store.get(Uuid::new_v4()).unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn set_flag_and_clear() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Flag Test");
        let id = store.insert(item).unwrap();

        // Set flag
        store
            .update(
                id,
                vec![FieldMutation::SetFlag(Some(FlagState {
                    color: "amber".into(),
                    style: Some("dashed".into()),
                    length: Some("short".into()),
                }))],
            )
            .unwrap();
        let got = store.get(id).unwrap().unwrap();
        let flag = got.flag.unwrap();
        assert_eq!(flag.color, "amber");
        assert_eq!(flag.style, Some("dashed".into()));
        assert_eq!(flag.length, Some("short".into()));

        // Clear flag
        store
            .update(id, vec![FieldMutation::SetFlag(None)])
            .unwrap();
        let got2 = store.get(id).unwrap().unwrap();
        assert!(got2.flag.is_none());
    }

    #[test]
    fn set_and_remove_payload() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Payload Test");
        let id = store.insert(item).unwrap();

        // Set new field
        store
            .update(
                id,
                vec![FieldMutation::SetPayload(
                    "doi".into(),
                    Value::String("10.1234/test".into()),
                )],
            )
            .unwrap();
        let got = store.get(id).unwrap().unwrap();
        assert_eq!(
            got.payload.get("doi"),
            Some(&Value::String("10.1234/test".into()))
        );

        // Remove field
        store
            .update(id, vec![FieldMutation::RemovePayload("doi".into())])
            .unwrap();
        let got2 = store.get(id).unwrap().unwrap();
        assert!(got2.payload.get("doi").is_none());
    }

    #[test]
    fn set_parent() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let parent = make_item("library", "Parent");
        let parent_id = parent.id;
        store.insert(parent).unwrap();

        let child = make_item("test", "Child");
        let child_id = store.insert(child).unwrap();

        // Set parent
        store
            .update(
                child_id,
                vec![FieldMutation::SetParent(Some(parent_id))],
            )
            .unwrap();
        let got = store.get(child_id).unwrap().unwrap();
        assert_eq!(got.parent, Some(parent_id));

        // Clear parent
        store
            .update(child_id, vec![FieldMutation::SetParent(None)])
            .unwrap();
        let got2 = store.get(child_id).unwrap().unwrap();
        assert!(got2.parent.is_none());
    }

    #[test]
    fn neighbors_traversal() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let a = make_item("test", "A");
        let b = make_item("test", "B");
        let c = make_item("test", "C");
        let a_id = a.id;
        let b_id = b.id;
        let c_id = c.id;
        store.insert(a).unwrap();
        store.insert(b).unwrap();
        store.insert(c).unwrap();

        // A → B → C via Cites
        store
            .update(
                a_id,
                vec![FieldMutation::AddReference(TypedReference {
                    target: b_id,
                    edge_type: EdgeType::Cites,
                    metadata: None,
                })],
            )
            .unwrap();
        store
            .update(
                b_id,
                vec![FieldMutation::AddReference(TypedReference {
                    target: c_id,
                    edge_type: EdgeType::Cites,
                    metadata: None,
                })],
            )
            .unwrap();

        // Depth 1 from A: should get B
        let n1 = store.neighbors(a_id, &[EdgeType::Cites], 1).unwrap();
        assert_eq!(n1.len(), 1);
        assert_eq!(n1[0].id, b_id);

        // Depth 2 from A: should get B and C
        let n2 = store.neighbors(a_id, &[EdgeType::Cites], 2).unwrap();
        assert_eq!(n2.len(), 2);
    }

    #[test]
    fn count_query() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        for i in 0..15 {
            let mut item = make_item("test", &format!("Item {}", i));
            if i % 3 == 0 {
                item.is_read = true;
            }
            store.insert(item).unwrap();
        }

        let total = store.count(&ItemQuery::default()).unwrap();
        assert_eq!(total, 15);

        let read_q = ItemQuery {
            predicates: vec![Predicate::IsRead(true)],
            ..Default::default()
        };
        let read_count = store.count(&read_q).unwrap();
        assert_eq!(read_count, 5); // 0,3,6,9,12
    }

    #[test]
    fn fts_update_on_payload_change() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Original Title");
        let id = store.insert(item).unwrap();

        // Search original
        let q = ItemQuery {
            predicates: vec![Predicate::Contains("title".into(), "Original".into())],
            ..Default::default()
        };
        assert_eq!(store.query(&q).unwrap().len(), 1);

        // Update title
        store
            .update(
                id,
                vec![FieldMutation::SetPayload(
                    "title".into(),
                    Value::String("Updated Title".into()),
                )],
            )
            .unwrap();

        // Old search should find nothing
        assert_eq!(store.query(&q).unwrap().len(), 0);

        // New search should find it
        let q2 = ItemQuery {
            predicates: vec![Predicate::Contains("title".into(), "Updated".into())],
            ..Default::default()
        };
        assert_eq!(store.query(&q2).unwrap().len(), 1);
    }
}
