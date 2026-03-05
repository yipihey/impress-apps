//! impress-store-ffi: UniFFI bindings for the shared impress-core SqliteItemStore.
//!
//! Provides a thin FFI layer that Swift apps use to read and write items to the
//! shared `impress.sqlite` database. All five impress apps (imbib, impart, imprint,
//! implore, impel) call through this crate rather than each duplicating UniFFI
//! wrappers for the same generic item operations.
//!
//! ## Usage from Swift
//!
//! ```swift
//! let store = try SharedStore.open(path: SharedWorkspace.databaseURL.path)
//! try store.upsertItem(
//!     id: publicationID,
//!     schemaRef: "bibliography-entry",
//!     payloadJson: payloadJSON
//! )
//! ```

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::Arc;

use impress_core::{
    item::{ActorKind, FlagState, Item, ItemId, Priority, Value, Visibility},
    query::{ItemQuery, Predicate, SortDescriptor},
    sqlite_store::SqliteItemStore,
    store::{FieldMutation, ItemStore, StoreError},
};

// Setup UniFFI proc-macro scaffolding (native builds only).
#[cfg(feature = "native")]
uniffi::setup_scaffolding!();

// ─── Error type ──────────────────────────────────────────────────────────────

/// Errors returned by the shared store FFI.
#[cfg_attr(feature = "native", derive(uniffi::Error))]
#[derive(Debug, thiserror::Error)]
pub enum SharedStoreError {
    #[error("Not found: {message}")]
    NotFound { message: String },
    #[error("Already exists: {message}")]
    AlreadyExists { message: String },
    #[error("Invalid argument: {message}")]
    InvalidArgument { message: String },
    #[error("Storage error: {message}")]
    Storage { message: String },
}

impl From<StoreError> for SharedStoreError {
    fn from(e: StoreError) -> Self {
        match e {
            StoreError::NotFound(id) => SharedStoreError::NotFound {
                message: id.to_string(),
            },
            StoreError::AlreadyExists(id) => SharedStoreError::AlreadyExists {
                message: id.to_string(),
            },
            StoreError::Storage(msg) => SharedStoreError::Storage { message: msg },
            StoreError::SchemaNotFound(s) => SharedStoreError::InvalidArgument {
                message: format!("schema not found: {s}"),
            },
            StoreError::Validation(msg) => SharedStoreError::InvalidArgument { message: msg },
        }
    }
}

// ─── Row type (returned to Swift) ────────────────────────────────────────────

/// A flat representation of a single item, suitable for Swift consumption.
///
/// `payload_json` is a JSON object string containing domain-specific fields.
/// Parse it in Swift with `JSONDecoder` using the schema-specific payload type.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedItemRow {
    pub id: String,
    pub schema_ref: String,
    pub payload_json: String,
    /// Item creation timestamp in milliseconds since Unix epoch.
    pub created_ms: i64,
    pub is_read: bool,
    pub is_starred: bool,
    pub tags: Vec<String>,
    /// Flag color if the item is flagged (e.g. "red", "amber", "blue", "gray").
    pub flag_color: Option<String>,
}

// ─── Store object ────────────────────────────────────────────────────────────

/// A handle to the shared impress-core SQLite database.
///
/// Construct with `SharedStore.open(path:)` or `SharedStore.openInMemory()`.
/// The handle is thread-safe (`Sync + Send`) via the underlying `SqliteItemStore`.
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct SharedStore {
    inner: SqliteItemStore,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedStore {
    /// Open (or create) the shared impress-core database at `path`.
    ///
    /// Call `SharedWorkspace.ensureDirectoryExists()` before opening to ensure
    /// the parent directory exists. Safe to call from multiple processes — SQLite
    /// WAL mode provides concurrent-reader, exclusive-writer access.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(path: String) -> Result<Arc<Self>, SharedStoreError> {
        let store = SqliteItemStore::open(Path::new(&path))
            .map_err(|e| SharedStoreError::Storage {
                message: e.to_string(),
            })?;
        Ok(Arc::new(SharedStore { inner: store }))
    }

    /// Open an ephemeral in-memory store. Intended for unit tests only.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open_in_memory() -> Result<Arc<Self>, SharedStoreError> {
        let store = SqliteItemStore::open_in_memory().map_err(|e| SharedStoreError::Storage {
            message: e.to_string(),
        })?;
        Ok(Arc::new(SharedStore { inner: store }))
    }

    /// Insert or update an item.
    ///
    /// - `id`: Stable UUID string (use the app-domain item ID for idempotency).
    /// - `schema_ref`: Schema identifier, e.g. `"bibliography-entry"`.
    /// - `payload_json`: JSON object with domain-specific fields.
    ///
    /// If an item with `id` already exists, its payload fields are updated
    /// to match `payload_json`. Fields not present in `payload_json` are left
    /// unchanged (additive semantics, not replace-all).
    pub fn upsert_item(
        &self,
        id: String,
        schema_ref: String,
        payload_json: String,
    ) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {id}"),
            })?;

        let payload: BTreeMap<String, Value> =
            serde_json::from_str(&payload_json).map_err(|e| SharedStoreError::InvalidArgument {
                message: format!("invalid payload JSON: {e}"),
            })?;

        let item = build_item(item_id, schema_ref, payload.clone());

        match self.inner.insert(item) {
            Ok(_) => Ok(()),
            Err(StoreError::AlreadyExists(_)) => {
                // Update each payload field individually (additive upsert).
                let mutations: Vec<FieldMutation> = payload
                    .into_iter()
                    .map(|(k, v)| FieldMutation::SetPayload(k, v))
                    .collect();
                if !mutations.is_empty() {
                    self.inner.update(item_id, mutations)?;
                }
                Ok(())
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Retrieve a single item by ID, or `nil` if not found.
    pub fn get_item(&self, id: String) -> Result<Option<SharedItemRow>, SharedStoreError> {
        let item_id: ItemId = id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {id}"),
            })?;
        let item = self.inner.get(item_id)?;
        Ok(item.map(item_to_row))
    }

    /// Delete an item by ID.
    ///
    /// Returns `NotFound` if no item with `id` exists.
    pub fn delete_item(&self, id: String) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {id}"),
            })?;
        self.inner.delete(item_id)?;
        Ok(())
    }

    /// List items by schema, sorted by creation time (newest first).
    ///
    /// - `schema_ref`: e.g. `"bibliography-entry"`.
    /// - `limit`: Maximum number of results (0 = default of 100).
    /// - `offset`: Pagination offset.
    pub fn query_by_schema(
        &self,
        schema_ref: String,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<SharedItemRow>, SharedStoreError> {
        let effective_limit = if limit == 0 { 100 } else { limit as usize };
        let q = ItemQuery {
            schema: Some(schema_ref),
            predicates: vec![],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            limit: Some(effective_limit),
            offset: Some(offset as usize),
        };
        let items = self.inner.query(&q)?;
        Ok(items.into_iter().map(item_to_row).collect())
    }

    /// Full-text search across all items, with optional schema filter.
    ///
    /// Searches the FTS5 index (title, author_text, abstract_text, note fields).
    /// Matches items where any of those fields contains `query`.
    pub fn search(
        &self,
        query: String,
        schema_filter: Option<String>,
        limit: u32,
    ) -> Result<Vec<SharedItemRow>, SharedStoreError> {
        let effective_limit = if limit == 0 { 50 } else { limit as usize };
        let mut predicates = vec![Predicate::Contains("title".into(), query.clone())];
        // OR search across abstract too
        predicates = vec![Predicate::Or(vec![
            Predicate::Contains("title".into(), query.clone()),
            Predicate::Contains("abstract_text".into(), query),
        ])];

        let q = ItemQuery {
            schema: schema_filter,
            predicates,
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            limit: Some(effective_limit),
            offset: None,
        };
        let items = self.inner.query(&q)?;
        Ok(items.into_iter().map(item_to_row).collect())
    }

    /// Mark an item as read or unread.
    pub fn set_read(&self, id: String, is_read: bool) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {id}"),
            })?;
        self.inner
            .update(item_id, vec![FieldMutation::SetRead(is_read)])?;
        Ok(())
    }

    /// Mark an item as starred or unstarred.
    pub fn set_starred(&self, id: String, is_starred: bool) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {id}"),
            })?;
        self.inner
            .update(item_id, vec![FieldMutation::SetStarred(is_starred)])?;
        Ok(())
    }

    /// Add a hierarchical tag to an item (e.g. `"methods/sims/hydro"`).
    pub fn add_tag(&self, id: String, tag: String) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {id}"),
            })?;
        self.inner
            .update(item_id, vec![FieldMutation::AddTag(tag)])?;
        Ok(())
    }

    /// Remove a tag from an item.
    pub fn remove_tag(&self, id: String, tag: String) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {id}"),
            })?;
        self.inner
            .update(item_id, vec![FieldMutation::RemoveTag(tag)])?;
        Ok(())
    }

    /// Set or clear a flag on an item.
    ///
    /// Pass `None` for `color` to clear the flag entirely.
    /// `style` and `length` are optional refinements (e.g. "dashed", "half").
    pub fn set_flag(
        &self,
        id: String,
        color: Option<String>,
        style: Option<String>,
        length: Option<String>,
    ) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {id}"),
            })?;
        let flag = color.map(|c| FlagState {
            color: c,
            style,
            length,
        });
        self.inner
            .update(item_id, vec![FieldMutation::SetFlag(flag)])?;
        Ok(())
    }
}

// ─── Private helpers ─────────────────────────────────────────────────────────

fn build_item(id: ItemId, schema: String, payload: BTreeMap<String, Value>) -> Item {
    use chrono::Utc;

    Item {
        id,
        schema,
        payload,
        created: Utc::now(),
        modified: Utc::now(),
        author: "local".into(),
        author_kind: ActorKind::Human,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::None,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    }
}

fn item_to_row(item: Item) -> SharedItemRow {
    let payload_json =
        serde_json::to_string(&item.payload).unwrap_or_else(|_| "{}".into());
    let flag_color = item.flag.as_ref().map(|f| f.color.clone());
    SharedItemRow {
        id: item.id.to_string(),
        schema_ref: item.schema,
        payload_json,
        created_ms: item.created.timestamp_millis(),
        is_read: item.is_read,
        is_starred: item.is_starred,
        tags: item.tags,
        flag_color,
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_in_memory_and_upsert() {
        let store = SharedStore::open_in_memory().expect("open in-memory store");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                id.clone(),
                "bibliography-entry".into(),
                r#"{"title": "Test Paper", "authors": ["Smith, J"]}"#.into(),
            )
            .expect("upsert");

        let row = store.get_item(id.clone()).expect("get").expect("row");
        assert_eq!(row.schema_ref, "bibliography-entry");
        assert!(!row.is_read);
        assert!(!row.is_starred);
    }

    #[test]
    fn upsert_is_idempotent() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(id.clone(), "task".into(), r#"{"title": "v1"}"#.into())
            .expect("first upsert");
        store
            .upsert_item(id.clone(), "task".into(), r#"{"title": "v2"}"#.into())
            .expect("second upsert");

        let row = store.get_item(id).expect("get").expect("row");
        let payload: serde_json::Value =
            serde_json::from_str(&row.payload_json).expect("parse payload");
        assert_eq!(payload["title"], "v2");
    }

    #[test]
    fn delete_removes_item() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(id.clone(), "task".into(), r#"{"title": "to delete"}"#.into())
            .expect("upsert");
        store.delete_item(id.clone()).expect("delete");
        let row = store.get_item(id).expect("get");
        assert!(row.is_none());
    }

    #[test]
    fn query_by_schema_returns_matching() {
        let store = SharedStore::open_in_memory().expect("open");
        let id1 = uuid::Uuid::new_v4().to_string();
        let id2 = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(id1.clone(), "bibliography-entry".into(), r#"{"title": "P1"}"#.into())
            .expect("upsert1");
        store
            .upsert_item(id2.clone(), "task".into(), r#"{"title": "T1"}"#.into())
            .expect("upsert2");

        let rows = store
            .query_by_schema("bibliography-entry".into(), 10, 0)
            .expect("query");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].schema_ref, "bibliography-entry");
    }

    #[test]
    fn set_read_and_starred() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(id.clone(), "bibliography-entry".into(), r#"{"title": "P"}"#.into())
            .expect("upsert");

        store.set_read(id.clone(), true).expect("set_read");
        store.set_starred(id.clone(), true).expect("set_starred");

        let row = store.get_item(id).expect("get").expect("row");
        assert!(row.is_read);
        assert!(row.is_starred);
    }

    #[test]
    fn add_and_remove_tag() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(id.clone(), "bibliography-entry".into(), r#"{"title": "P"}"#.into())
            .expect("upsert");

        store
            .add_tag(id.clone(), "methods/sims".into())
            .expect("add_tag");
        let row = store.get_item(id.clone()).expect("get").expect("row");
        assert!(row.tags.contains(&"methods/sims".to_string()));

        store
            .remove_tag(id.clone(), "methods/sims".into())
            .expect("remove_tag");
        let row = store.get_item(id).expect("get").expect("row");
        assert!(!row.tags.contains(&"methods/sims".to_string()));
    }

    #[test]
    fn set_flag_appears_in_row() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(id.clone(), "bibliography-entry".into(), r#"{"title": "P"}"#.into())
            .expect("upsert");

        // Verify initially unflagged
        let row = store.get_item(id.clone()).expect("get").expect("row");
        assert!(row.flag_color.is_none());

        // Set a flag
        store
            .set_flag(id.clone(), Some("red".into()), None, None)
            .expect("set_flag");
        let row = store.get_item(id.clone()).expect("get").expect("row");
        assert_eq!(row.flag_color, Some("red".to_string()));

        // Clear the flag
        store
            .set_flag(id.clone(), None, None, None)
            .expect("clear_flag");
        let row = store.get_item(id).expect("get").expect("row");
        assert!(row.flag_color.is_none());
    }

    #[test]
    fn full_bibliography_entry_round_trip() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        let payload = r#"{
            "cite_key": "Einstein1905",
            "entry_type": "article",
            "title": "On the Electrodynamics of Moving Bodies",
            "author_text": "Einstein, Albert",
            "year": 1905,
            "journal": "Annalen der Physik",
            "volume": "17",
            "pages": "891-921",
            "doi": "10.1002/andp.19053221004",
            "abstract_text": "The laws by which the states of physical systems undergo change...",
            "keywords": ["relativity", "physics", "electrodynamics"]
        }"#;
        store
            .upsert_item(
                id.clone(),
                "imbib/bibliography-entry".into(),
                payload.into(),
            )
            .expect("upsert");

        // Read it back
        let row = store.get_item(id.clone()).expect("get").expect("exists");
        assert_eq!(row.schema_ref, "imbib/bibliography-entry");
        let p: serde_json::Value =
            serde_json::from_str(&row.payload_json).expect("parse payload");
        assert_eq!(p["title"], "On the Electrodynamics of Moving Bodies");
        assert_eq!(p["year"], 1905);
        assert_eq!(p["journal"], "Annalen der Physik");
        assert_eq!(p["doi"], "10.1002/andp.19053221004");

        // Verify it shows up in schema queries
        let rows = store
            .query_by_schema("imbib/bibliography-entry".into(), 10, 0)
            .expect("query");
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].id, id);

        // Verify tags/flags/read work on it
        store.add_tag(id.clone(), "physics/relativity".into()).expect("tag");
        store.set_read(id.clone(), true).expect("read");
        store.set_starred(id.clone(), true).expect("star");
        store.set_flag(id.clone(), Some("amber".into()), Some("dashed".into()), None).expect("flag");

        let row = store.get_item(id).expect("get").expect("exists");
        assert!(row.is_read);
        assert!(row.is_starred);
        assert!(row.tags.contains(&"physics/relativity".to_string()));
        assert_eq!(row.flag_color, Some("amber".to_string()));
    }

    #[test]
    fn cross_schema_isolation() {
        // Simulates multiple apps writing to the same store
        let store = SharedStore::open_in_memory().expect("open");
        let pub_id = uuid::Uuid::new_v4().to_string();
        let task_id = uuid::Uuid::new_v4().to_string();
        let email_id = uuid::Uuid::new_v4().to_string();

        store
            .upsert_item(pub_id.clone(), "imbib/bibliography-entry".into(),
                r#"{"cite_key": "Smith2024", "entry_type": "article", "title": "A Paper"}"#.into())
            .expect("upsert pub");
        store
            .upsert_item(task_id.clone(), "task".into(),
                r#"{"title": "Review paper", "state": "pending"}"#.into())
            .expect("upsert task");
        store
            .upsert_item(email_id.clone(), "email-message".into(),
                r#"{"subject": "Re: paper review", "body": "LGTM"}"#.into())
            .expect("upsert email");

        // Each schema query returns only its own items
        let pubs = store.query_by_schema("imbib/bibliography-entry".into(), 10, 0).expect("query pubs");
        assert_eq!(pubs.len(), 1);
        assert_eq!(pubs[0].id, pub_id);

        let tasks = store.query_by_schema("task".into(), 10, 0).expect("query tasks");
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].id, task_id);

        let emails = store.query_by_schema("email-message".into(), 10, 0).expect("query emails");
        assert_eq!(emails.len(), 1);
        assert_eq!(emails[0].id, email_id);
    }
}
