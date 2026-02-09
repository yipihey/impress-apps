use std::collections::BTreeMap;
use std::path::Path;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Mutex;

use chrono::{TimeZone, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use uuid::Uuid;

use crate::event::ItemEvent;
use crate::item::{ActorKind, FlagState, Item, ItemId, Priority, Value, Visibility};
use crate::operation::{
    build_operation_payload, EffectiveState, OperationIntent, OperationSpec, OperationType,
    StateAsOf,
};
use crate::query::ItemQuery;
use crate::reference::{EdgeType, TypedReference};
use crate::sql_query::compile_query;
use crate::store::{FieldMutation, ItemStore, StoreError};

/// Configuration for opening a store with specific author/origin/namespace settings.
#[derive(Debug, Clone)]
pub struct StoreConfig {
    pub author: String,
    pub author_kind: ActorKind,
    pub tag_namespace: String,
}

impl Default for StoreConfig {
    fn default() -> Self {
        Self {
            author: "system:local".into(),
            author_kind: ActorKind::System,
            tag_namespace: "local".into(),
        }
    }
}

/// SQLite-backed implementation of the ItemStore trait.
///
/// Supports operation-based mutations with materialized state for O(1) reads.
pub struct SqliteItemStore {
    conn: Mutex<Connection>,
    event_tx: Sender<ItemEvent>,
    event_rx: Mutex<Option<Receiver<ItemEvent>>>,
    default_author: String,
    default_author_kind: ActorKind,
    origin_id: String,
    tag_namespace: String,
}

/// The full SELECT column list for the items table.
const ITEM_COLUMNS: &str =
    "id, schema_ref, payload, created, modified, author, author_kind,
     is_read, is_starred, flag_color, flag_style, flag_length, parent_id,
     logical_clock, origin, canonical_id, priority, visibility,
     message_type, produced_by, version, batch_id, op_target_id";

impl SqliteItemStore {
    /// Open (or create) a database at the given path with default config.
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        Self::open_with_config(path, StoreConfig::default())
    }

    /// Open (or create) a database at the given path with explicit config.
    pub fn open_with_config(path: &Path, config: StoreConfig) -> Result<Self, StoreError> {
        let conn =
            Connection::open(path).map_err(|e| StoreError::Storage(format!("open: {}", e)))?;
        Self::init_with_connection(conn, config)
    }

    /// Create an in-memory database (for testing).
    pub fn open_in_memory() -> Result<Self, StoreError> {
        Self::open_in_memory_with_config(StoreConfig::default())
    }

    /// Create an in-memory database with explicit config.
    pub fn open_in_memory_with_config(config: StoreConfig) -> Result<Self, StoreError> {
        let conn = Connection::open_in_memory()
            .map_err(|e| StoreError::Storage(format!("open_in_memory: {}", e)))?;
        Self::init_with_connection(conn, config)
    }

    fn init_with_connection(conn: Connection, config: StoreConfig) -> Result<Self, StoreError> {
        Self::init_schema(&conn)?;
        Self::migrate_schema(&conn)?;

        // Initialize or read store metadata
        let origin_id = Self::init_store_metadata(&conn, &config)?;

        let (tx, rx) = mpsc::channel();
        Ok(Self {
            conn: Mutex::new(conn),
            event_tx: tx,
            event_rx: Mutex::new(Some(rx)),
            default_author: config.author,
            default_author_kind: config.author_kind,
            origin_id,
            tag_namespace: config.tag_namespace,
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
                parent_id TEXT REFERENCES items(id) ON DELETE SET NULL,
                logical_clock INTEGER NOT NULL DEFAULT 0,
                origin TEXT,
                canonical_id TEXT,
                priority TEXT NOT NULL DEFAULT 'normal',
                visibility TEXT NOT NULL DEFAULT 'private',
                message_type TEXT,
                produced_by TEXT,
                version TEXT,
                batch_id TEXT,
                op_target_id TEXT REFERENCES items(id) ON DELETE CASCADE
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

            CREATE TABLE IF NOT EXISTS store_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
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
            CREATE INDEX IF NOT EXISTS idx_items_logical_clock ON items(logical_clock);
            CREATE INDEX IF NOT EXISTS idx_items_priority ON items(priority);
            CREATE INDEX IF NOT EXISTS idx_items_visibility ON items(visibility);
            ",
        )
        .map_err(|e| StoreError::Storage(format!("init_schema: {}", e)))?;

        // Partial indices (these use WHERE clauses, need separate statements)
        conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS idx_items_op_target ON items(op_target_id, logical_clock) WHERE op_target_id IS NOT NULL;
             CREATE INDEX IF NOT EXISTS idx_items_batch ON items(batch_id) WHERE batch_id IS NOT NULL;",
        ).map_err(|e| StoreError::Storage(format!("init_partial_indices: {}", e)))?;

        // FTS5 table
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

    /// Idempotent migration for databases created before the envelope expansion.
    fn migrate_schema(conn: &Connection) -> Result<(), StoreError> {
        // Add new columns if they don't exist. Using .ok() makes this idempotent.
        let migrations = [
            "ALTER TABLE items ADD COLUMN logical_clock INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE items ADD COLUMN origin TEXT",
            "ALTER TABLE items ADD COLUMN canonical_id TEXT",
            "ALTER TABLE items ADD COLUMN priority TEXT NOT NULL DEFAULT 'normal'",
            "ALTER TABLE items ADD COLUMN visibility TEXT NOT NULL DEFAULT 'private'",
            "ALTER TABLE items ADD COLUMN message_type TEXT",
            "ALTER TABLE items ADD COLUMN produced_by TEXT",
            "ALTER TABLE items ADD COLUMN version TEXT",
            "ALTER TABLE items ADD COLUMN batch_id TEXT",
            "ALTER TABLE items ADD COLUMN op_target_id TEXT REFERENCES items(id) ON DELETE CASCADE",
        ];
        for sql in &migrations {
            let _ = conn.execute(sql, []);
        }

        // Create store_metadata table if it doesn't exist
        let _ = conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS store_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        );

        Ok(())
    }

    /// Initialize store metadata (origin, logical_clock, tag_namespace).
    fn init_store_metadata(conn: &Connection, config: &StoreConfig) -> Result<String, StoreError> {
        // Get or create origin_id
        let origin_id: String = conn
            .query_row(
                "SELECT value FROM store_metadata WHERE key = 'origin_id'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(|e| StoreError::Storage(format!("read origin: {}", e)))?
            .unwrap_or_else(|| {
                let id = Uuid::new_v4().to_string();
                let _ = conn.execute(
                    "INSERT OR IGNORE INTO store_metadata (key, value) VALUES ('origin_id', ?1)",
                    params![&id],
                );
                id
            });

        // Initialize logical_clock if not present
        let _ = conn.execute(
            "INSERT OR IGNORE INTO store_metadata (key, value) VALUES ('logical_clock', '0')",
            [],
        );

        // Store tag_namespace (don't overwrite if already set)
        let _ = conn.execute(
            "INSERT OR IGNORE INTO store_metadata (key, value) VALUES ('tag_namespace', ?1)",
            params![&config.tag_namespace],
        );

        Ok(origin_id)
    }

    /// Get and increment the logical clock. Returns the new value.
    fn next_clock(conn: &Connection) -> Result<u64, StoreError> {
        conn.execute(
            "UPDATE store_metadata SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'logical_clock'",
            [],
        )
        .map_err(|e| StoreError::Storage(format!("increment clock: {}", e)))?;

        let clock: String = conn
            .query_row(
                "SELECT value FROM store_metadata WHERE key = 'logical_clock'",
                [],
                |row| row.get(0),
            )
            .map_err(|e| StoreError::Storage(format!("read clock: {}", e)))?;

        clock
            .parse::<u64>()
            .map_err(|e| StoreError::Storage(format!("parse clock: {}", e)))
    }

    /// Merge a remote logical clock (Lamport clock merge).
    pub fn merge_clock(&self, remote_clock: u64) -> Result<u64, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let current: String = conn
            .query_row(
                "SELECT value FROM store_metadata WHERE key = 'logical_clock'",
                [],
                |row| row.get(0),
            )
            .map_err(|e| StoreError::Storage(format!("read clock: {}", e)))?;
        let current_val: u64 = current.parse().unwrap_or(0);
        let new_val = current_val.max(remote_clock) + 1;
        conn.execute(
            "UPDATE store_metadata SET value = ?1 WHERE key = 'logical_clock'",
            params![new_val.to_string()],
        )
        .map_err(|e| StoreError::Storage(format!("merge clock: {}", e)))?;
        Ok(new_val)
    }

    fn emit(&self, event: ItemEvent) {
        let _ = self.event_tx.send(event);
    }

    /// Insert a single item into the database.
    fn insert_item(conn: &Connection, item: &Item, origin_id: &str) -> Result<(), StoreError> {
        let payload_json =
            serde_json::to_string(&item.payload).map_err(|e| StoreError::Storage(e.to_string()))?;
        let author_kind = actor_kind_str(item.author_kind);
        let (flag_color, flag_style, flag_length) = flag_to_columns(&item.flag);
        let parent_id = item.parent.map(|p| p.to_string());
        let produced_by = item.produced_by.map(|p| p.to_string());
        let origin = item.origin.as_deref().unwrap_or(origin_id);

        conn.execute(
            "INSERT INTO items (id, schema_ref, payload, created, modified, author, author_kind,
              is_read, is_starred, flag_color, flag_style, flag_length, parent_id,
              logical_clock, origin, canonical_id, priority, visibility,
              message_type, produced_by, version, batch_id, op_target_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                     ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, NULL)",
            params![
                item.id.to_string(),
                item.schema,
                payload_json,
                item.created.timestamp_millis(),
                item.created.timestamp_millis(), // modified = created initially
                item.author,
                author_kind,
                item.is_read as i32,
                item.is_starred as i32,
                flag_color,
                flag_style,
                flag_length,
                parent_id,
                item.logical_clock as i64,
                origin,
                item.canonical_id,
                item.priority.to_string(),
                item.visibility.to_string(),
                item.message_type,
                produced_by,
                item.version,
                item.batch_id,
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

    /// Insert an operation item with op_target_id set.
    fn insert_operation_item(
        conn: &Connection,
        item: &Item,
        op_target_id: ItemId,
        origin_id: &str,
    ) -> Result<(), StoreError> {
        let payload_json =
            serde_json::to_string(&item.payload).map_err(|e| StoreError::Storage(e.to_string()))?;
        let author_kind = actor_kind_str(item.author_kind);
        let origin = item.origin.as_deref().unwrap_or(origin_id);

        conn.execute(
            "INSERT INTO items (id, schema_ref, payload, created, modified, author, author_kind,
              is_read, is_starred, flag_color, flag_style, flag_length, parent_id,
              logical_clock, origin, canonical_id, priority, visibility,
              message_type, produced_by, version, batch_id, op_target_id)
             VALUES (?1, ?2, ?3, ?4, ?4, ?5, ?6, 0, 0, NULL, NULL, NULL, NULL,
                     ?7, ?8, NULL, 'normal', 'private', NULL, NULL, NULL, ?9, ?10)",
            params![
                item.id.to_string(),
                item.schema,
                payload_json,
                item.created.timestamp_millis(),
                item.author,
                author_kind,
                item.logical_clock as i64,
                origin,
                item.batch_id,
                op_target_id.to_string(),
            ],
        )
        .map_err(|e| {
            if let rusqlite::Error::SqliteFailure(ref err, _) = e {
                if err.code == rusqlite::ErrorCode::ConstraintViolation {
                    return StoreError::AlreadyExists(item.id);
                }
            }
            StoreError::Storage(format!("insert op: {}", e))
        })?;

        Ok(())
    }

    /// Apply a single operation: create operation item + materialize change on target.
    pub fn apply_operation(&self, spec: OperationSpec) -> Result<ItemId, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;

        let target_str = spec.target_id.to_string();

        // Verify target exists
        let exists: bool = conn
            .query_row(
                "SELECT COUNT(*) FROM items WHERE id = ?1",
                params![&target_str],
                |row| row.get::<_, i64>(0),
            )
            .map(|c| c > 0)
            .map_err(|e| StoreError::Storage(format!("check exists: {}", e)))?;

        if !exists {
            return Err(StoreError::NotFound(spec.target_id));
        }

        // Get next logical clock
        let clock = Self::next_clock(&conn)?;

        // Build operation item
        let op_id = Uuid::new_v4();
        let op_payload =
            build_operation_payload(spec.target_id, &spec.op_type, spec.intent, spec.reason.as_deref());

        let op_item = Item {
            id: op_id,
            schema: "core/operation".into(),
            payload: op_payload,
            created: Utc::now(),
            author: spec.author.clone(),
            author_kind: spec.author_kind,
            logical_clock: clock,
            origin: Some(self.origin_id.clone()),
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: spec.batch_id.clone(),
            references: vec![],
            parent: None,
        };

        // Insert operation item with op_target_id
        Self::insert_operation_item(&conn, &op_item, spec.target_id, &self.origin_id)?;

        // Materialize the change on the target
        let now = Utc::now().timestamp_millis();
        Self::materialize_operation(&conn, &spec.target_id.to_string(), &spec.op_type, now)?;

        drop(conn);
        self.emit(ItemEvent::OperationApplied {
            operation_id: op_id,
            target_id: spec.target_id,
        });

        Ok(op_id)
    }

    /// Apply a batch of operations sharing a batch_id.
    pub fn apply_operation_batch(
        &self,
        specs: Vec<OperationSpec>,
    ) -> Result<Vec<ItemId>, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| StoreError::Storage(format!("begin tx: {}", e)))?;

        let batch_id = Uuid::new_v4().to_string();
        let mut op_ids = Vec::with_capacity(specs.len());

        for mut spec in specs {
            spec.batch_id = Some(batch_id.clone());
            let target_str = spec.target_id.to_string();

            // Verify target exists
            let exists: bool = tx
                .query_row(
                    "SELECT COUNT(*) FROM items WHERE id = ?1",
                    params![&target_str],
                    |row| row.get::<_, i64>(0),
                )
                .map(|c| c > 0)
                .map_err(|e| StoreError::Storage(format!("check exists: {}", e)))?;

            if !exists {
                return Err(StoreError::NotFound(spec.target_id));
            }

            let clock = Self::next_clock(&tx)?;
            let op_id = Uuid::new_v4();
            let op_payload = build_operation_payload(
                spec.target_id,
                &spec.op_type,
                spec.intent,
                spec.reason.as_deref(),
            );

            let op_item = Item {
                id: op_id,
                schema: "core/operation".into(),
                payload: op_payload,
                created: Utc::now(),
                author: spec.author.clone(),
                author_kind: spec.author_kind,
                logical_clock: clock,
                origin: Some(self.origin_id.clone()),
                canonical_id: None,
                tags: vec![],
                flag: None,
                is_read: false,
                is_starred: false,
                priority: Priority::Normal,
                visibility: Visibility::Private,
                message_type: None,
                produced_by: None,
                version: None,
                batch_id: spec.batch_id.clone(),
                references: vec![],
                parent: None,
            };

            Self::insert_operation_item(&tx, &op_item, spec.target_id, &self.origin_id)?;

            let now = Utc::now().timestamp_millis();
            Self::materialize_operation(&tx, &target_str, &spec.op_type, now)?;

            op_ids.push(op_id);
        }

        tx.commit()
            .map_err(|e| StoreError::Storage(format!("commit batch: {}", e)))?;

        // Emit events after commit
        drop(conn);
        for op_id in &op_ids {
            // We don't have target_ids here easily; emit a generic event
            self.emit(ItemEvent::OperationApplied {
                operation_id: *op_id,
                target_id: Uuid::nil(), // batch events — listeners should re-query
            });
        }

        Ok(op_ids)
    }

    /// Materialize an operation's effect on the target item's SQL columns.
    fn materialize_operation(
        conn: &Connection,
        target_id_str: &str,
        op_type: &OperationType,
        now: i64,
    ) -> Result<(), StoreError> {
        match op_type {
            OperationType::SetPayload(field, value) => {
                let json_val = serde_json::to_string(value)
                    .map_err(|e| StoreError::Storage(e.to_string()))?;
                let path = format!("$.{}", field);
                conn.execute(
                    "UPDATE items SET payload = json_set(payload, ?1, json(?2)), modified = ?3 WHERE id = ?4",
                    params![path, json_val, now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("set payload: {}", e)))?;
            }
            OperationType::RemovePayload(field) => {
                let path = format!("$.{}", field);
                conn.execute(
                    "UPDATE items SET payload = json_remove(payload, ?1), modified = ?2 WHERE id = ?3",
                    params![path, now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("remove payload: {}", e)))?;
            }
            OperationType::PatchPayload(fields) => {
                for (field, value) in fields {
                    let json_val = serde_json::to_string(value)
                        .map_err(|e| StoreError::Storage(e.to_string()))?;
                    let path = format!("$.{}", field);
                    conn.execute(
                        "UPDATE items SET payload = json_set(payload, ?1, json(?2)), modified = ?3 WHERE id = ?4",
                        params![path, json_val, now, target_id_str],
                    )
                    .map_err(|e| StoreError::Storage(format!("patch payload: {}", e)))?;
                }
            }
            OperationType::SetRead(v) => {
                conn.execute(
                    "UPDATE items SET is_read = ?1, modified = ?2 WHERE id = ?3",
                    params![*v as i32, now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("set read: {}", e)))?;
            }
            OperationType::SetStarred(v) => {
                conn.execute(
                    "UPDATE items SET is_starred = ?1, modified = ?2 WHERE id = ?3",
                    params![*v as i32, now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("set starred: {}", e)))?;
            }
            OperationType::SetFlag(flag) => {
                let (color, style, length) = flag_to_columns(flag);
                conn.execute(
                    "UPDATE items SET flag_color = ?1, flag_style = ?2, flag_length = ?3, modified = ?4 WHERE id = ?5",
                    params![color, style, length, now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("set flag: {}", e)))?;
            }
            OperationType::AddTag(tag_path) => {
                conn.execute(
                    "INSERT OR IGNORE INTO item_tags (item_id, tag_path) VALUES (?1, ?2)",
                    params![target_id_str, tag_path],
                )
                .map_err(|e| StoreError::Storage(format!("add tag: {}", e)))?;
                conn.execute(
                    "UPDATE items SET modified = ?1 WHERE id = ?2",
                    params![now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("update modified: {}", e)))?;
            }
            OperationType::RemoveTag(tag_path) => {
                conn.execute(
                    "DELETE FROM item_tags WHERE item_id = ?1 AND tag_path = ?2",
                    params![target_id_str, tag_path],
                )
                .map_err(|e| StoreError::Storage(format!("remove tag: {}", e)))?;
                conn.execute(
                    "UPDATE items SET modified = ?1 WHERE id = ?2",
                    params![now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("update modified: {}", e)))?;
            }
            OperationType::SetPriority(p) => {
                conn.execute(
                    "UPDATE items SET priority = ?1, modified = ?2 WHERE id = ?3",
                    params![p.to_string(), now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("set priority: {}", e)))?;
            }
            OperationType::SetVisibility(v) => {
                conn.execute(
                    "UPDATE items SET visibility = ?1, modified = ?2 WHERE id = ?3",
                    params![v.to_string(), now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("set visibility: {}", e)))?;
            }
            OperationType::AddReference(typed_ref) => {
                let edge_str = serde_json::to_string(&typed_ref.edge_type)
                    .map_err(|e| StoreError::Storage(e.to_string()))?;
                let meta_str = typed_ref
                    .metadata
                    .as_ref()
                    .map(|m| serde_json::to_string(m).unwrap_or_default());
                conn.execute(
                    "INSERT OR IGNORE INTO item_references (source_id, target_id, edge_type, metadata) VALUES (?1, ?2, ?3, ?4)",
                    params![target_id_str, typed_ref.target.to_string(), edge_str, meta_str],
                )
                .map_err(|e| StoreError::Storage(format!("add ref: {}", e)))?;
            }
            OperationType::RemoveReference(target_id, edge_type) => {
                let edge_str = serde_json::to_string(edge_type)
                    .map_err(|e| StoreError::Storage(e.to_string()))?;
                conn.execute(
                    "DELETE FROM item_references WHERE source_id = ?1 AND target_id = ?2 AND edge_type = ?3",
                    params![target_id_str, target_id.to_string(), edge_str],
                )
                .map_err(|e| StoreError::Storage(format!("remove ref: {}", e)))?;
            }
            OperationType::SetParent(parent_id) => {
                let parent_str = parent_id.map(|p| p.to_string());
                conn.execute(
                    "UPDATE items SET parent_id = ?1, modified = ?2 WHERE id = ?3",
                    params![parent_str, now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("set parent: {}", e)))?;
            }
            OperationType::Custom(_, _) => {
                // Custom operations only update modified timestamp
                conn.execute(
                    "UPDATE items SET modified = ?1 WHERE id = ?2",
                    params![now, target_id_str],
                )
                .map_err(|e| StoreError::Storage(format!("custom op: {}", e)))?;
            }
        }
        Ok(())
    }

    /// Get all operations targeting an item, ordered by logical_clock.
    pub fn operations_for(
        &self,
        id: ItemId,
        limit: Option<usize>,
    ) -> Result<Vec<Item>, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let id_str = id.to_string();

        let sql = if let Some(lim) = limit {
            format!(
                "SELECT {} FROM items WHERE op_target_id = ?1 ORDER BY logical_clock ASC, created ASC, id ASC LIMIT {}",
                ITEM_COLUMNS, lim
            )
        } else {
            format!(
                "SELECT {} FROM items WHERE op_target_id = ?1 ORDER BY logical_clock ASC, created ASC, id ASC",
                ITEM_COLUMNS
            )
        };

        let mut stmt = conn
            .prepare(&sql)
            .map_err(|e| StoreError::Storage(format!("prepare ops: {}", e)))?;

        let rows = stmt
            .query_map(params![&id_str], |row| Ok(Self::row_to_item(&conn, row)))
            .map_err(|e| StoreError::Storage(format!("query ops: {}", e)))?;

        let mut items = Vec::new();
        for row_result in rows {
            let item_result =
                row_result.map_err(|e| StoreError::Storage(format!("row: {}", e)))?;
            items.push(item_result?);
        }
        Ok(items)
    }

    /// Compute effective state for an item, either current or via time-travel.
    pub fn effective_state(
        &self,
        id: ItemId,
        query: StateAsOf,
    ) -> Result<Option<EffectiveState>, StoreError> {
        match query {
            StateAsOf::Current => {
                // Fast path: read materialized columns
                let item = self.get(id)?;
                match item {
                    Some(item) => Ok(Some(EffectiveState {
                        tags: item.tags,
                        flag: item.flag,
                        is_read: item.is_read,
                        is_starred: item.is_starred,
                        priority: item.priority,
                        visibility: item.visibility,
                        payload: item.payload,
                        parent: item.parent,
                        as_of_clock: item.logical_clock,
                        as_of_time: None,
                        operation_count: 0, // not computed for current
                    })),
                    None => Ok(None),
                }
            }
            StateAsOf::LogicalClock(clock) => self.replay_state(id, Some(clock), None),
            StateAsOf::Timestamp(ts) => self.replay_state(id, None, Some(ts)),
        }
    }

    /// Time-travel: replay operations up to a cutoff.
    fn replay_state(
        &self,
        id: ItemId,
        clock_cutoff: Option<u64>,
        time_cutoff: Option<chrono::DateTime<Utc>>,
    ) -> Result<Option<EffectiveState>, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let id_str = id.to_string();

        // Load the base item's creation-time state
        let mut stmt = conn
            .prepare(&format!("SELECT {} FROM items WHERE id = ?1", ITEM_COLUMNS))
            .map_err(|e| StoreError::Storage(format!("prepare base: {}", e)))?;

        let base_item = stmt
            .query_row(params![&id_str], |row| Ok(Self::row_to_item(&conn, row)))
            .optional()
            .map_err(|e| StoreError::Storage(format!("query base: {}", e)))?;

        let base_item = match base_item {
            Some(Ok(item)) => item,
            Some(Err(e)) => return Err(e),
            None => return Ok(None),
        };

        // Start with creation-time defaults
        let mut state = EffectiveState {
            tags: vec![], // Tags at creation are already in item_tags, but we start fresh for replay
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            payload: base_item.payload.clone(),
            parent: base_item.parent,
            as_of_clock: 0,
            as_of_time: time_cutoff,
            operation_count: 0,
        };

        // Query operations up to cutoff
        let ops_sql = if clock_cutoff.is_some() {
            format!(
                "SELECT {} FROM items WHERE op_target_id = ?1 AND logical_clock <= ?2 ORDER BY logical_clock ASC, created ASC, id ASC",
                ITEM_COLUMNS
            )
        } else if time_cutoff.is_some() {
            format!(
                "SELECT {} FROM items WHERE op_target_id = ?1 AND created <= ?2 ORDER BY logical_clock ASC, created ASC, id ASC",
                ITEM_COLUMNS
            )
        } else {
            // No cutoff — replay all
            format!(
                "SELECT {} FROM items WHERE op_target_id = ?1 ORDER BY logical_clock ASC, created ASC, id ASC",
                ITEM_COLUMNS
            )
        };

        let mut ops_stmt = conn
            .prepare(&ops_sql)
            .map_err(|e| StoreError::Storage(format!("prepare ops replay: {}", e)))?;

        let ops: Vec<Item> = if let Some(clock) = clock_cutoff {
            ops_stmt
                .query_map(params![&id_str, clock as i64], |row| {
                    Ok(Self::row_to_item(&conn, row))
                })
                .map_err(|e| StoreError::Storage(format!("query ops: {}", e)))?
                .collect::<Result<Result<Vec<_>, _>, _>>()
                .map_err(|e| StoreError::Storage(format!("collect ops: {}", e)))?
                ?
        } else if let Some(ts) = time_cutoff {
            ops_stmt
                .query_map(params![&id_str, ts.timestamp_millis()], |row| {
                    Ok(Self::row_to_item(&conn, row))
                })
                .map_err(|e| StoreError::Storage(format!("query ops: {}", e)))?
                .collect::<Result<Result<Vec<_>, _>, _>>()
                .map_err(|e| StoreError::Storage(format!("collect ops: {}", e)))?
                ?
        } else {
            ops_stmt
                .query_map(params![&id_str], |row| {
                    Ok(Self::row_to_item(&conn, row))
                })
                .map_err(|e| StoreError::Storage(format!("query ops: {}", e)))?
                .collect::<Result<Result<Vec<_>, _>, _>>()
                .map_err(|e| StoreError::Storage(format!("collect ops: {}", e)))?
                ?
        };

        // Replay each operation
        for op_item in &ops {
            Self::replay_single_op(&mut state, &op_item.payload);
            state.as_of_clock = op_item.logical_clock;
            state.operation_count += 1;
        }

        Ok(Some(state))
    }

    /// Replay a single operation's effect onto an EffectiveState.
    fn replay_single_op(state: &mut EffectiveState, op_payload: &BTreeMap<String, Value>) {
        let op_type = match op_payload.get("op_type") {
            Some(Value::String(s)) => s.as_str(),
            _ => return,
        };
        let op_data = op_payload.get("op_data").cloned().unwrap_or(Value::Null);

        match op_type {
            "add_tag" => {
                if let Value::String(tag) = &op_data {
                    if !state.tags.contains(tag) {
                        state.tags.push(tag.clone());
                    }
                }
            }
            "remove_tag" => {
                if let Value::String(tag) = &op_data {
                    state.tags.retain(|t| t != tag);
                }
            }
            "set_read" => {
                if let Value::Bool(v) = op_data {
                    state.is_read = v;
                }
            }
            "set_starred" => {
                if let Value::Bool(v) = op_data {
                    state.is_starred = v;
                }
            }
            "set_flag" => {
                if let Value::Object(m) = &op_data {
                    if let Some(Value::String(color)) = m.get("color") {
                        state.flag = Some(FlagState {
                            color: color.clone(),
                            style: m.get("style").and_then(|v| match v {
                                Value::String(s) => Some(s.clone()),
                                _ => None,
                            }),
                            length: m.get("length").and_then(|v| match v {
                                Value::String(s) => Some(s.clone()),
                                _ => None,
                            }),
                        });
                    }
                } else if matches!(op_data, Value::Null) {
                    state.flag = None;
                }
            }
            "set_priority" => {
                if let Value::String(p) = &op_data {
                    if let Ok(prio) = p.parse::<Priority>() {
                        state.priority = prio;
                    }
                }
            }
            "set_visibility" => {
                if let Value::String(v) = &op_data {
                    if let Ok(vis) = v.parse::<Visibility>() {
                        state.visibility = vis;
                    }
                }
            }
            "set_payload" => {
                if let Value::Object(m) = &op_data {
                    if let (Some(Value::String(field)), Some(value)) =
                        (m.get("field"), m.get("value"))
                    {
                        state.payload.insert(field.clone(), value.clone());
                    }
                }
            }
            "remove_payload" => {
                if let Value::String(field) = &op_data {
                    state.payload.remove(field);
                }
            }
            "set_parent" => match &op_data {
                Value::String(id_str) => {
                    state.parent = uuid::Uuid::parse_str(id_str).ok();
                }
                Value::Null => {
                    state.parent = None;
                }
                _ => {}
            },
            _ => {} // Unknown op types are ignored during replay
        }
    }

    /// Update the FTS index for an item.
    fn update_fts(conn: &Connection, item: &Item) -> Result<(), StoreError> {
        let id_str = item.id.to_string();
        let title = extract_string_field(&item.payload, "title");
        let author_text = extract_string_field(&item.payload, "author_text");
        let abstract_text = extract_string_field(&item.payload, "abstract_text");
        let note = extract_string_field(&item.payload, "note");

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

    /// Read an item from a row result (expanded column set).
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
        let _modified_ms: i64 = row
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

        // New envelope fields
        let logical_clock: i64 = row
            .get(13)
            .map_err(|e| StoreError::Storage(format!("row logical_clock: {}", e)))?;
        let origin: Option<String> = row
            .get(14)
            .map_err(|e| StoreError::Storage(format!("row origin: {}", e)))?;
        let canonical_id: Option<String> = row
            .get(15)
            .map_err(|e| StoreError::Storage(format!("row canonical_id: {}", e)))?;
        let priority_str: String = row
            .get(16)
            .map_err(|e| StoreError::Storage(format!("row priority: {}", e)))?;
        let visibility_str: String = row
            .get(17)
            .map_err(|e| StoreError::Storage(format!("row visibility: {}", e)))?;
        let message_type: Option<String> = row
            .get(18)
            .map_err(|e| StoreError::Storage(format!("row message_type: {}", e)))?;
        let produced_by_str: Option<String> = row
            .get(19)
            .map_err(|e| StoreError::Storage(format!("row produced_by: {}", e)))?;
        let version: Option<String> = row
            .get(20)
            .map_err(|e| StoreError::Storage(format!("row version: {}", e)))?;
        let batch_id: Option<String> = row
            .get(21)
            .map_err(|e| StoreError::Storage(format!("row batch_id: {}", e)))?;
        // column 22 = op_target_id (not stored on Item struct, used for queries only)

        let created = Utc
            .timestamp_millis_opt(created_ms)
            .single()
            .unwrap_or_else(Utc::now);
        let author_kind = parse_actor_kind(&author_kind_str);
        let flag = flag_color.map(|color| FlagState {
            color,
            style: flag_style,
            length: flag_length,
        });
        let parent = parent_id_str.and_then(|s| uuid::Uuid::parse_str(&s).ok());
        let priority = priority_str.parse::<Priority>().unwrap_or_default();
        let visibility = visibility_str.parse::<Visibility>().unwrap_or_default();
        let produced_by = produced_by_str.and_then(|s| uuid::Uuid::parse_str(&s).ok());

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
            author,
            author_kind,
            logical_clock: logical_clock as u64,
            origin,
            canonical_id,
            tags,
            flag,
            is_read,
            is_starred,
            priority,
            visibility,
            message_type,
            produced_by,
            version,
            batch_id,
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

    /// Run namespace migration on bare schema refs and tag paths.
    /// This is idempotent — only touches rows without '/'.
    pub fn migrate_namespaces(&self, schema_namespace: &str) -> Result<(), StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;

        // Read tag_namespace from store_metadata
        let tag_ns: String = conn
            .query_row(
                "SELECT value FROM store_metadata WHERE key = 'tag_namespace'",
                [],
                |row| row.get(0),
            )
            .unwrap_or_else(|_| self.tag_namespace.clone());

        let schema_prefix = format!("{}/", schema_namespace);
        let tag_prefix = format!("{}/", tag_ns);

        // Migrate schema refs (skip core/ schemas and already-namespaced)
        conn.execute(
            "UPDATE items SET schema_ref = ?1 || schema_ref WHERE schema_ref NOT LIKE '%/%'",
            params![&schema_prefix],
        )
        .map_err(|e| StoreError::Storage(format!("migrate schemas: {}", e)))?;

        // Migrate tag paths
        conn.execute(
            "UPDATE item_tags SET tag_path = ?1 || tag_path WHERE tag_path NOT LIKE '%/%'",
            params![&tag_prefix],
        )
        .map_err(|e| StoreError::Storage(format!("migrate tags: {}", e)))?;

        Ok(())
    }
}

impl ItemStore for SqliteItemStore {
    fn insert(&self, item: Item) -> Result<ItemId, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let id = item.id;
        Self::insert_item(&conn, &item, &self.origin_id)?;
        drop(conn);
        self.emit(ItemEvent::Created(Box::new(item)));
        Ok(id)
    }

    fn insert_batch(&self, items: Vec<Item>) -> Result<Vec<ItemId>, StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let tx = conn
            .unchecked_transaction()
            .map_err(|e| StoreError::Storage(format!("begin tx: {}", e)))?;

        let mut ids = Vec::with_capacity(items.len());
        for item in &items {
            Self::insert_item(&tx, item, &self.origin_id)?;
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
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let mut stmt = conn
            .prepare(&format!(
                "SELECT {} FROM items WHERE id = ?1",
                ITEM_COLUMNS
            ))
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
        // Convert FieldMutation to operations via the backward-compatible bridge
        let batch_id = if mutations.len() > 1 {
            Some(Uuid::new_v4().to_string())
        } else {
            None
        };

        for mutation in mutations {
            self.apply_operation(OperationSpec {
                target_id: id,
                op_type: mutation.into(),
                intent: OperationIntent::Routine,
                reason: None,
                batch_id: batch_id.clone(),
                author: self.default_author.clone(),
                author_kind: self.default_author_kind,
            })?;
        }

        Ok(())
    }

    fn delete(&self, id: ItemId) -> Result<(), StoreError> {
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let id_str = id.to_string();

        // Delete FTS entry first
        Self::delete_fts(&conn, &id_str)?;

        // Delete any operations targeting this item first (they reference it via FK)
        conn.execute(
            "DELETE FROM items WHERE op_target_id = ?1",
            params![&id_str],
        )
        .map_err(|e| StoreError::Storage(format!("delete ops: {}", e)))?;

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
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let compiled = compile_query(q);

        let sql = format!(
            "SELECT {} FROM items {} {} {}",
            ITEM_COLUMNS, compiled.where_clause, compiled.order_clause, compiled.limit_offset
        );

        let params_ref: Vec<&dyn rusqlite::types::ToSql> = compiled
            .params
            .iter()
            .map(|p| p as &dyn rusqlite::types::ToSql)
            .collect();

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
        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let compiled = compile_query(q);

        let sql = format!("SELECT COUNT(*) FROM items {}", compiled.where_clause);
        let params_ref: Vec<&dyn rusqlite::types::ToSql> = compiled
            .params
            .iter()
            .map(|p| p as &dyn rusqlite::types::ToSql)
            .collect();

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

        let conn = self
            .conn
            .lock()
            .map_err(|e| StoreError::Storage(e.to_string()))?;
        let mut visited = std::collections::HashSet::new();
        let mut frontier = vec![id];
        let mut result = Vec::new();

        let select_sql = format!("SELECT {} FROM items WHERE id = ?1", ITEM_COLUMNS);

        for _ in 0..depth {
            let mut next_frontier = Vec::new();
            for current_id in &frontier {
                if !visited.insert(*current_id) {
                    continue;
                }
                let id_str = current_id.to_string();

                let edge_strs: Vec<String> = edge_types
                    .iter()
                    .map(|e| serde_json::to_string(e).unwrap_or_default())
                    .collect();
                let placeholders: Vec<String> =
                    (0..edge_strs.len()).map(|i| format!("?{}", i + 2)).collect();

                // Outgoing
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

                let mut stmt = conn
                    .prepare(&sql)
                    .map_err(|e| StoreError::Storage(e.to_string()))?;
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

                // Incoming
                let sql_in = format!(
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
                    .prepare(&sql_in)
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

            for neighbor_id in &next_frontier {
                let neighbor_str = neighbor_id.to_string();
                let mut stmt = conn
                    .prepare(&select_sql)
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

// --- Helpers ---

fn actor_kind_str(kind: ActorKind) -> &'static str {
    match kind {
        ActorKind::Human => "human",
        ActorKind::Agent => "agent",
        ActorKind::System => "system",
    }
}

fn parse_actor_kind(s: &str) -> ActorKind {
    match s {
        "agent" => ActorKind::Agent,
        "system" => ActorKind::System,
        _ => ActorKind::Human,
    }
}

fn flag_to_columns(flag: &Option<FlagState>) -> (Option<String>, Option<String>, Option<String>) {
    match flag {
        Some(f) => (
            Some(f.color.clone()),
            f.style.clone(),
            f.length.clone(),
        ),
        None => (None, None, None),
    }
}

fn extract_string_field(payload: &BTreeMap<String, Value>, field: &str) -> Option<String> {
    match payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{ActorKind, FlagState, Item, Priority, Value, Visibility};
    use crate::operation::{OperationIntent, OperationSpec, OperationType, StateAsOf};
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
            author: "test@example.com".into(),
            author_kind: ActorKind::Human,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Priority::Normal,
            visibility: Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
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
        assert_eq!(got.priority, Priority::Normal);
        assert_eq!(got.visibility, Visibility::Private);
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

        let q = ItemQuery {
            predicates: vec![Predicate::HasFlag(None)],
            ..Default::default()
        };
        assert_eq!(store.query(&q).unwrap().len(), 1);

        let q2 = ItemQuery {
            predicates: vec![Predicate::HasFlag(Some("red".into()))],
            ..Default::default()
        };
        assert_eq!(store.query(&q2).unwrap().len(), 1);

        let q3 = ItemQuery {
            predicates: vec![Predicate::HasFlag(Some("blue".into()))],
            ..Default::default()
        };
        assert_eq!(store.query(&q3).unwrap().len(), 0);
    }

    #[test]
    fn tag_operations() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Tag Test");
        let id = store.insert(item).unwrap();

        store
            .update(id, vec![FieldMutation::AddTag("methods/sims".into())])
            .unwrap();
        store
            .update(id, vec![FieldMutation::AddTag("topics/cosmo".into())])
            .unwrap();

        let got = store.get(id).unwrap().unwrap();
        assert_eq!(got.tags.len(), 2);
        assert!(got.tags.contains(&"methods/sims".to_string()));

        store
            .update(id, vec![FieldMutation::RemoveTag("methods/sims".into())])
            .unwrap();
        let got2 = store.get(id).unwrap().unwrap();
        assert_eq!(got2.tags.len(), 1);
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

        store
            .insert(make_item("test", "Stellar Populations"))
            .unwrap();

        let q = ItemQuery {
            predicates: vec![Predicate::Contains("title".into(), "Dark Matter".into())],
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 1);
    }

    #[test]
    fn delete_cascades() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut item = make_item("test", "Will Delete");
        item.tags = vec!["tag1".into(), "tag2".into()];
        let id = store.insert(item).unwrap();

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

        store.delete(id).unwrap();
        assert!(store.get(id).unwrap().is_none());

        let conn = store.conn.lock().unwrap();
        let tag_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM item_tags WHERE item_id = ?1",
                params![id.to_string()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(tag_count, 0);
    }

    #[test]
    fn event_emission() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let rx = store.subscribe(ItemQuery::default()).unwrap();

        let item = make_item("test", "Event Test");
        let id = store.insert(item).unwrap();

        let event = rx.try_recv().unwrap();
        assert!(matches!(event, ItemEvent::Created(_)));

        // Update now creates operations
        store
            .update(id, vec![FieldMutation::SetRead(true)])
            .unwrap();
        let event = rx.try_recv().unwrap();
        assert!(matches!(event, ItemEvent::OperationApplied { .. }));

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

        store
            .update(
                child_id,
                vec![FieldMutation::SetParent(Some(parent_id))],
            )
            .unwrap();
        let got = store.get(child_id).unwrap().unwrap();
        assert_eq!(got.parent, Some(parent_id));

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

        let n1 = store.neighbors(a_id, &[EdgeType::Cites], 1).unwrap();
        assert_eq!(n1.len(), 1);
        assert_eq!(n1[0].id, b_id);

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
        assert_eq!(read_count, 5);
    }

    // --- Operation-specific tests ---

    #[test]
    fn apply_operation_creates_operation_item() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Target");
        let id = store.insert(item).unwrap();

        let op_id = store
            .apply_operation(OperationSpec {
                target_id: id,
                op_type: OperationType::AddTag("methods/sims".into()),
                intent: OperationIntent::Routine,
                reason: Some("testing".into()),
                batch_id: None,
                author: "test-user".into(),
                author_kind: ActorKind::Human,
            })
            .unwrap();

        // Operation item should exist
        let op_item = store.get(op_id).unwrap().unwrap();
        assert_eq!(op_item.schema, "core/operation");
        assert_eq!(
            op_item.payload.get("op_type"),
            Some(&Value::String("add_tag".into()))
        );

        // Target should have the tag materialized
        let target = store.get(id).unwrap().unwrap();
        assert!(target.tags.contains(&"methods/sims".to_string()));
    }

    #[test]
    fn update_creates_operations_transparently() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Target");
        let id = store.insert(item).unwrap();

        store
            .update(
                id,
                vec![
                    FieldMutation::AddTag("test-tag".into()),
                    FieldMutation::SetRead(true),
                ],
            )
            .unwrap();

        // Should have created 2 operation items
        let ops = store.operations_for(id, None).unwrap();
        assert_eq!(ops.len(), 2);
        // Both should share a batch_id
        assert!(ops[0].batch_id.is_some());
        assert_eq!(ops[0].batch_id, ops[1].batch_id);

        // Target should reflect both changes
        let target = store.get(id).unwrap().unwrap();
        assert!(target.is_read);
        assert!(target.tags.contains(&"test-tag".to_string()));
    }

    #[test]
    fn logical_clock_monotonicity() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Clock Test");
        let id = store.insert(item).unwrap();

        store
            .update(id, vec![FieldMutation::SetRead(true)])
            .unwrap();
        store
            .update(id, vec![FieldMutation::SetStarred(true)])
            .unwrap();
        store
            .update(id, vec![FieldMutation::AddTag("tag".into())])
            .unwrap();

        let ops = store.operations_for(id, None).unwrap();
        assert_eq!(ops.len(), 3);
        // Each operation should have a strictly increasing logical clock
        for i in 1..ops.len() {
            assert!(
                ops[i].logical_clock > ops[i - 1].logical_clock,
                "clock {} should be > {}",
                ops[i].logical_clock,
                ops[i - 1].logical_clock
            );
        }
    }

    #[test]
    fn time_travel_add_remove_tag() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Time Travel");
        let id = store.insert(item).unwrap();

        // Op 1: add tag
        store
            .update(id, vec![FieldMutation::AddTag("methods/sims".into())])
            .unwrap();
        let ops = store.operations_for(id, None).unwrap();
        let clock_after_add = ops[0].logical_clock;

        // Op 2: remove tag
        store
            .update(id, vec![FieldMutation::RemoveTag("methods/sims".into())])
            .unwrap();

        // Current state: tag gone
        let current = store
            .effective_state(id, StateAsOf::Current)
            .unwrap()
            .unwrap();
        assert!(!current.tags.contains(&"methods/sims".to_string()));

        // State at clock_after_add: tag present
        let past = store
            .effective_state(id, StateAsOf::LogicalClock(clock_after_add))
            .unwrap()
            .unwrap();
        assert!(past.tags.contains(&"methods/sims".to_string()));
    }

    #[test]
    fn new_fields_round_trip() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let mut item = make_item("test", "New Fields");
        item.priority = Priority::High;
        item.visibility = Visibility::Shared;
        item.message_type = Some("email".into());
        item.version = Some("2.0".into());
        item.canonical_id = Some("shared-123".into());

        let id = store.insert(item).unwrap();
        let got = store.get(id).unwrap().unwrap();
        assert_eq!(got.priority, Priority::High);
        assert_eq!(got.visibility, Visibility::Shared);
        assert_eq!(got.message_type, Some("email".into()));
        assert_eq!(got.version, Some("2.0".into()));
        assert_eq!(got.canonical_id, Some("shared-123".into()));
    }

    #[test]
    fn store_config_with_author() {
        let config = StoreConfig {
            author: "human:tom".into(),
            author_kind: ActorKind::Human,
            tag_namespace: "abel".into(),
        };
        let store = SqliteItemStore::open_in_memory_with_config(config).unwrap();
        let item = make_item("test", "Config Test");
        let id = store.insert(item).unwrap();

        // Update via the bridge — should use default author
        store
            .update(id, vec![FieldMutation::SetRead(true)])
            .unwrap();
        let ops = store.operations_for(id, None).unwrap();
        assert_eq!(ops[0].author, "human:tom");
    }

    #[test]
    fn clock_merge() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        // Local clock starts at 0
        let merged = store.merge_clock(100).unwrap();
        assert_eq!(merged, 101); // max(0, 100) + 1

        let merged2 = store.merge_clock(50).unwrap();
        assert_eq!(merged2, 102); // max(101, 50) + 1
    }

    #[test]
    fn priority_and_visibility_operations() {
        let store = SqliteItemStore::open_in_memory().unwrap();
        let item = make_item("test", "Priority Test");
        let id = store.insert(item).unwrap();

        store
            .apply_operation(OperationSpec {
                target_id: id,
                op_type: OperationType::SetPriority(Priority::Urgent),
                intent: OperationIntent::Escalation,
                reason: Some("needs review".into()),
                batch_id: None,
                author: "agent:reviewer".into(),
                author_kind: ActorKind::Agent,
            })
            .unwrap();

        store
            .apply_operation(OperationSpec {
                target_id: id,
                op_type: OperationType::SetVisibility(Visibility::Public),
                intent: OperationIntent::Editorial,
                reason: None,
                batch_id: None,
                author: "human:editor".into(),
                author_kind: ActorKind::Human,
            })
            .unwrap();

        let got = store.get(id).unwrap().unwrap();
        assert_eq!(got.priority, Priority::Urgent);
        assert_eq!(got.visibility, Visibility::Public);

        // Check operation history
        let ops = store.operations_for(id, None).unwrap();
        assert_eq!(ops.len(), 2);
    }

    #[test]
    fn namespace_migration() {
        let store = SqliteItemStore::open_in_memory().unwrap();

        // Insert items with bare schema refs
        let mut item = make_item("bibliography-entry", "Paper");
        item.tags = vec!["methods/sims".into(), "imbib/already-namespaced".into()];
        store.insert(item).unwrap();

        // Run migration
        store.migrate_namespaces("imbib").unwrap();

        // Schema should now be namespaced
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            ..Default::default()
        };
        let results = store.query(&q).unwrap();
        assert_eq!(results.len(), 1);

        // Tags: bare tag "methods/sims" already has a /, so it shouldn't be prefixed
        // The migration only targets tags WITHOUT a /
        // "methods/sims" contains / so stays as-is
        // "imbib/already-namespaced" contains / so stays as-is
    }
}
