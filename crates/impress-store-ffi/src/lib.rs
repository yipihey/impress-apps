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
    operation::{OperationIntent, OperationSpec, OperationType, RetentionTier},
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

/// A flat representation of a typed reference (graph edge) on an item.
///
/// `edge_type` is the JSON-serialized `EdgeType` enum with surrounding quotes
/// stripped — e.g. `"Cites"`, `"RelatesTo"`, or `{"Custom":"my-edge"}` for
/// custom edges.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedReferenceRow {
    pub target_id: String,
    pub edge_type: String,
}

/// One operation from an item's history, shaped for history-panel display.
///
/// `field_names` lists the payload fields the operation touched (empty for
/// envelope ops like tag/flag/read). `is_body_edit` is the UI noise filter:
/// true when the op touched only manuscript body fields, so consecutive
/// body-save runs can be collapsed into one display row.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedOperationRow {
    pub id: String,
    pub target_id: String,
    /// Serialized op type: set_payload | add_tag | set_flag | add_reference | ...
    pub op_type: String,
    pub field_names: Vec<String>,
    pub is_body_edit: bool,
    pub intent: String,
    pub reason: Option<String>,
    pub author: String,
    pub author_kind: String,
    pub date_ms: i64,
    pub logical_clock: u64,
    pub batch_id: Option<String>,
}

/// An item's payload replayed to a point in time (`effective_state_at`).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedEffectiveState {
    pub payload_json: String,
    pub as_of_clock: u64,
    /// Number of operations replayed (0 for the current-state fast path).
    pub operation_count: u32,
}

/// Result of a guarded (compare-and-set) upsert.
///
/// `applied == false` means the guard rejected the write; `stored_guard`
/// carries the value the store currently holds for the guard field (None if
/// the field is unset or the item is missing).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct GuardedUpsertOutcome {
    pub applied: bool,
    pub stored_guard: Option<String>,
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
        let store =
            SqliteItemStore::open(Path::new(&path)).map_err(|e| SharedStoreError::Storage {
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
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
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
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        let item = self.inner.get(item_id)?;
        Ok(item.map(item_to_row))
    }

    /// Delete an item by ID.
    ///
    /// Returns `NotFound` if no item with `id` exists.
    pub fn delete_item(&self, id: String) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
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
            ..ItemQuery::default()
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
            ..ItemQuery::default()
        };
        let items = self.inner.query(&q)?;
        Ok(items.into_iter().map(item_to_row).collect())
    }

    /// Mark an item as read or unread.
    pub fn set_read(&self, id: String, is_read: bool) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        self.inner
            .update(item_id, vec![FieldMutation::SetRead(is_read)])?;
        Ok(())
    }

    /// Mark an item as starred or unstarred.
    pub fn set_starred(&self, id: String, is_starred: bool) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        self.inner
            .update(item_id, vec![FieldMutation::SetStarred(is_starred)])?;
        Ok(())
    }

    /// Add a hierarchical tag to an item (e.g. `"methods/sims/hydro"`).
    pub fn add_tag(&self, id: String, tag: String) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        self.inner
            .update(item_id, vec![FieldMutation::AddTag(tag)])?;
        Ok(())
    }

    /// Remove a tag from an item.
    pub fn remove_tag(&self, id: String, tag: String) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
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
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
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

    /// List the typed references (graph edges) of an item.
    ///
    /// Returns `NotFound` if no item with `id` exists.
    pub fn get_item_references(
        &self,
        id: String,
    ) -> Result<Vec<SharedReferenceRow>, SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        let item = self
            .inner
            .get(item_id)?
            .ok_or(SharedStoreError::NotFound { message: id })?;
        Ok(item
            .references
            .into_iter()
            .map(|r| SharedReferenceRow {
                target_id: r.target.to_string(),
                edge_type: serde_json::to_string(&r.edge_type)
                    .unwrap_or_default()
                    .trim_matches('"')
                    .to_string(),
            })
            .collect())
    }

    /// Resolve a review-request item with an attributed human write.
    ///
    /// Validates that the item exists and has schema `review-request@1.0.0`,
    /// then applies two operations authored by `resolved_by` (Human, Editorial,
    /// Durable): `SetPayload("resolution", resolution)` and
    /// `SetPayload("resolved_by", resolved_by)`. Unlike `upsert_item` (which
    /// writes as the local system actor), this preserves the human author in
    /// the operation audit trail.
    pub fn resolve_review(
        &self,
        id: String,
        resolution: String,
        resolved_by: String,
    ) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        let item = self
            .inner
            .get(item_id)?
            .ok_or_else(|| SharedStoreError::NotFound {
                message: id.clone(),
            })?;
        if item.schema != "review-request@1.0.0" {
            return Err(SharedStoreError::InvalidArgument {
                message: format!(
                    "resolve_review requires schema review-request@1.0.0, got {}",
                    item.schema
                ),
            });
        }

        let ops = [
            OperationType::SetPayload("resolution".into(), Value::String(resolution)),
            OperationType::SetPayload("resolved_by".into(), Value::String(resolved_by.clone())),
        ];
        for op_type in ops {
            self.inner.apply_operation(OperationSpec {
                target_id: item_id,
                op_type,
                intent: OperationIntent::Editorial,
                reason: None,
                batch_id: None,
                author: resolved_by.clone(),
                author_kind: ActorKind::Human,
                retention: RetentionTier::Durable,
            })?;
        }
        Ok(())
    }

    /// Count items with the given schema (e.g. for sidebar badges).
    pub fn count_by_schema(&self, schema_ref: String) -> Result<u32, SharedStoreError> {
        let q = ItemQuery {
            schema: Some(schema_ref),
            ..ItemQuery::default()
        };
        let count = self.inner.count(&q)?;
        Ok(count as u32)
    }

    // ─── History / versions (GUI-meld plan §History) ────────────────────────

    /// All operations targeting an item, oldest first, shaped for the Info-tab
    /// History section. `limit = 0` returns everything.
    pub fn operations_for(
        &self,
        id: String,
        limit: u32,
    ) -> Result<Vec<SharedOperationRow>, SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        let lim = if limit == 0 {
            None
        } else {
            Some(limit as usize)
        };
        let ops = self.inner.operations_for(item_id, lim)?;
        Ok(ops.iter().map(operation_item_to_row).collect())
    }

    /// Replay an item's state as of a logical clock value (time-travel for
    /// the "View state here" history action). Returns None for unknown items.
    pub fn effective_state_at(
        &self,
        id: String,
        logical_clock: u64,
    ) -> Result<Option<SharedEffectiveState>, SharedStoreError> {
        use impress_core::operation::StateAsOf;
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        let state = self
            .inner
            .effective_state(item_id, StateAsOf::LogicalClock(logical_clock))?;
        Ok(state.map(|s| SharedEffectiveState {
            payload_json: serde_json::to_string(&s.payload).unwrap_or_else(|_| "{}".into()),
            as_of_clock: s.as_of_clock,
            operation_count: s.operation_count as u32,
        }))
    }

    /// Compare-and-set upsert: apply `payload_json` only when the stored
    /// value of `guard_field` (a payload string field, e.g.
    /// `body_content_hash`) equals `expected`. Pass `expected = None` to
    /// require the field to be unset/missing.
    ///
    /// Inserting a NEW item succeeds only when `expected` is None (there is
    /// nothing to guard against); a guarded write to a deleted item reports
    /// a conflict with `stored_guard = None`.
    ///
    /// The check-then-write runs as two store calls; the residual
    /// cross-process race window is closed by the Darwin change-notification
    /// path (GUI-meld Phase 4). The guard deterministically catches the
    /// common stale-editor case.
    pub fn upsert_item_guarded(
        &self,
        id: String,
        schema_ref: String,
        payload_json: String,
        guard_field: String,
        expected: Option<String>,
    ) -> Result<GuardedUpsertOutcome, SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        let existing = self.inner.get(item_id)?;

        let stored_guard =
            existing
                .as_ref()
                .and_then(|item| match item.payload.get(guard_field.as_str()) {
                    Some(Value::String(s)) => Some(s.clone()),
                    _ => None,
                });

        let guard_ok = match (&existing, &expected) {
            (None, None) => true,     // fresh insert, nothing to guard
            (None, Some(_)) => false, // expected a value but item is gone
            (Some(_), exp) => stored_guard.as_deref() == exp.as_deref(),
        };
        if !guard_ok {
            return Ok(GuardedUpsertOutcome {
                applied: false,
                stored_guard,
            });
        }

        self.upsert_item(id, schema_ref, payload_json)?;
        Ok(GuardedUpsertOutcome {
            applied: true,
            stored_guard,
        })
    }

    /// Create an immutable `manuscript-revision` snapshot of a manuscript's
    /// current body and advance its `current_revision_ref` (ADR-0011 D45).
    /// Delegates to `impress_core::manuscript_ops` so this FFI and
    /// imbib-core's ImbibStore share one implementation.
    pub fn create_manuscript_revision(
        &self,
        manuscript_id: String,
        revision_tag: String,
        snapshot_reason: String,
        author: String,
    ) -> Result<SharedItemRow, SharedStoreError> {
        let item_id: ItemId =
            manuscript_id
                .parse()
                .map_err(|_| SharedStoreError::InvalidArgument {
                    message: format!("invalid UUID: {manuscript_id}"),
                })?;
        let revision = impress_core::manuscript_ops::create_revision(
            &self.inner,
            item_id,
            &revision_tag,
            &snapshot_reason,
            &author,
            ActorKind::Human,
        )?;
        Ok(item_to_row(revision))
    }

    /// List a manuscript's revision snapshots, newest first.
    pub fn list_manuscript_revisions(
        &self,
        manuscript_id: String,
    ) -> Result<Vec<SharedItemRow>, SharedStoreError> {
        let item_id: ItemId =
            manuscript_id
                .parse()
                .map_err(|_| SharedStoreError::InvalidArgument {
                    message: format!("invalid UUID: {manuscript_id}"),
                })?;
        let items = impress_core::manuscript_ops::list_revisions(&self.inner, item_id)?;
        Ok(items.into_iter().map(item_to_row).collect())
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

/// Manuscript body fields — an operation touching only these is a "body edit"
/// for history-display collapsing.
const BODY_FIELDS: [&str; 3] = ["body_content", "body_content_hash", "body_modified_at"];

/// Shape a `core/operation` item into a SharedOperationRow, extracting the
/// touched payload field names from the op_data encoding
/// (see `impress_core::operation::serialize_op_type`).
fn operation_item_to_row(item: &Item) -> SharedOperationRow {
    let payload = &item.payload;
    let get_str = |key: &str| -> Option<String> {
        match payload.get(key) {
            Some(Value::String(s)) => Some(s.clone()),
            _ => None,
        }
    };
    let op_type = get_str("op_type").unwrap_or_default();

    let field_names: Vec<String> = match (op_type.as_str(), payload.get("op_data")) {
        ("set_payload", Some(Value::Object(m))) => match m.get("field") {
            Some(Value::String(f)) => vec![f.clone()],
            _ => vec![],
        },
        ("remove_payload", Some(Value::String(f))) => vec![f.clone()],
        ("patch_payload", Some(Value::Object(m))) => m.keys().cloned().collect(),
        _ => vec![],
    };
    let is_body_edit = !field_names.is_empty()
        && field_names
            .iter()
            .all(|f| BODY_FIELDS.contains(&f.as_str()));

    SharedOperationRow {
        id: item.id.to_string(),
        target_id: get_str("target_id").unwrap_or_default(),
        op_type,
        field_names,
        is_body_edit,
        intent: get_str("intent").unwrap_or_else(|| "routine".into()),
        reason: get_str("reason"),
        author: item.author.clone(),
        author_kind: format!("{:?}", item.author_kind).to_lowercase(),
        date_ms: item.created.timestamp_millis(),
        logical_clock: item.logical_clock,
        batch_id: item.batch_id.clone(),
    }
}

fn item_to_row(item: Item) -> SharedItemRow {
    let payload_json = serde_json::to_string(&item.payload).unwrap_or_else(|_| "{}".into());
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
            .upsert_item(
                id.clone(),
                "task".into(),
                r#"{"title": "to delete"}"#.into(),
            )
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
            .upsert_item(
                id1.clone(),
                "bibliography-entry".into(),
                r#"{"title": "P1"}"#.into(),
            )
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
            .upsert_item(
                id.clone(),
                "bibliography-entry".into(),
                r#"{"title": "P"}"#.into(),
            )
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
            .upsert_item(
                id.clone(),
                "bibliography-entry".into(),
                r#"{"title": "P"}"#.into(),
            )
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
            .upsert_item(
                id.clone(),
                "bibliography-entry".into(),
                r#"{"title": "P"}"#.into(),
            )
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
        let p: serde_json::Value = serde_json::from_str(&row.payload_json).expect("parse payload");
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
        store
            .add_tag(id.clone(), "physics/relativity".into())
            .expect("tag");
        store.set_read(id.clone(), true).expect("read");
        store.set_starred(id.clone(), true).expect("star");
        store
            .set_flag(
                id.clone(),
                Some("amber".into()),
                Some("dashed".into()),
                None,
            )
            .expect("flag");

        let row = store.get_item(id).expect("get").expect("exists");
        assert!(row.is_read);
        assert!(row.is_starred);
        assert!(row.tags.contains(&"physics/relativity".to_string()));
        assert_eq!(row.flag_color, Some("amber".to_string()));
    }

    #[test]
    fn resolve_review_writes_attributed_operations() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                id.clone(),
                "review-request@1.0.0".into(),
                r#"{"question": "Apply these tags?", "context_proposed_tags": ["ai/cosmology"]}"#
                    .into(),
            )
            .expect("upsert review request");

        store
            .resolve_review(id.clone(), "approved".into(), "tom".into())
            .expect("resolve");

        // Payload materialized
        let row = store.get_item(id.clone()).expect("get").expect("row");
        let payload: serde_json::Value =
            serde_json::from_str(&row.payload_json).expect("parse payload");
        assert_eq!(payload["resolution"], "approved");
        assert_eq!(payload["resolved_by"], "tom");

        // Operation items carry the human author (not system:local)
        let item_id: ItemId = id.parse().unwrap();
        let ops = store.inner.operations_for(item_id, None).expect("ops");
        let set_payload_ops: Vec<_> = ops
            .iter()
            .filter(|op| op.payload.get("op_type") == Some(&Value::String("set_payload".into())))
            .collect();
        assert_eq!(
            set_payload_ops.len(),
            2,
            "expected two SetPayload operations"
        );
        for op in &set_payload_ops {
            assert_eq!(op.schema, "core/operation");
            assert_eq!(op.author, "tom");
            assert_eq!(op.author_kind, ActorKind::Human);
            assert_eq!(
                op.payload.get("intent"),
                Some(&Value::String("editorial".into()))
            );
        }
    }

    #[test]
    fn resolve_review_rejects_wrong_schema() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                id.clone(),
                "task".into(),
                r#"{"title": "not a review"}"#.into(),
            )
            .expect("upsert");

        let err = store
            .resolve_review(id, "approved".into(), "tom".into())
            .expect_err("must reject wrong schema");
        match err {
            SharedStoreError::InvalidArgument { message } => {
                assert!(message.contains("review-request@1.0.0"), "{message}");
            }
            other => panic!("expected InvalidArgument, got {other:?}"),
        }

        // Missing item -> NotFound
        let missing = uuid::Uuid::new_v4().to_string();
        let err = store
            .resolve_review(missing, "approved".into(), "tom".into())
            .expect_err("must reject missing item");
        assert!(matches!(err, SharedStoreError::NotFound { .. }));
    }

    #[test]
    fn references_round_trip() {
        use impress_core::reference::{EdgeType, TypedReference};

        let store = SharedStore::open_in_memory().expect("open");
        let source_id = uuid::Uuid::new_v4().to_string();
        let target_id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                source_id.clone(),
                "review-request@1.0.0".into(),
                r#"{"question": "q"}"#.into(),
            )
            .expect("upsert source");
        store
            .upsert_item(
                target_id.clone(),
                "imbib/bibliography-entry".into(),
                r#"{"title": "P"}"#.into(),
            )
            .expect("upsert target");

        // Empty at first
        let refs = store.get_item_references(source_id.clone()).expect("refs");
        assert!(refs.is_empty());

        // Add references via the inner store (enum + custom variants)
        let source_uuid: ItemId = source_id.parse().unwrap();
        let target_uuid: ItemId = target_id.parse().unwrap();
        store
            .inner
            .update(
                source_uuid,
                vec![
                    FieldMutation::AddReference(TypedReference {
                        target: target_uuid,
                        edge_type: EdgeType::OperatesOn,
                        metadata: None,
                    }),
                    FieldMutation::AddReference(TypedReference {
                        target: target_uuid,
                        edge_type: EdgeType::Custom("proposed-for".into()),
                        metadata: None,
                    }),
                ],
            )
            .expect("add references");

        let refs = store.get_item_references(source_id).expect("refs");
        assert_eq!(refs.len(), 2);
        assert!(refs.iter().all(|r| r.target_id == target_id));
        let edge_types: Vec<&str> = refs.iter().map(|r| r.edge_type.as_str()).collect();
        assert!(edge_types.contains(&"OperatesOn"), "{edge_types:?}");
        assert!(
            edge_types.contains(&r#"{"Custom":"proposed-for"}"#),
            "{edge_types:?}"
        );

        // Missing item -> NotFound
        let err = store
            .get_item_references(uuid::Uuid::new_v4().to_string())
            .expect_err("missing");
        assert!(matches!(err, SharedStoreError::NotFound { .. }));
    }

    #[test]
    fn upsert_item_guarded_applies_and_conflicts() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();

        // Fresh insert: no guard expectation → applied.
        let out = store
            .upsert_item_guarded(
                id.clone(),
                "manuscript".into(),
                r#"{"title":"M","status":"draft","body_content":"v1","body_content_hash":"h1"}"#
                    .into(),
                "body_content_hash".into(),
                None,
            )
            .expect("insert");
        assert!(out.applied);

        // Correct guard → applied.
        let out = store
            .upsert_item_guarded(
                id.clone(),
                "manuscript".into(),
                r#"{"body_content":"v2","body_content_hash":"h2"}"#.into(),
                "body_content_hash".into(),
                Some("h1".into()),
            )
            .expect("guarded update");
        assert!(out.applied);
        assert_eq!(out.stored_guard.as_deref(), Some("h1"));

        // Stale guard → conflict, nothing written.
        let out = store
            .upsert_item_guarded(
                id.clone(),
                "manuscript".into(),
                r#"{"body_content":"lost-update","body_content_hash":"h3"}"#.into(),
                "body_content_hash".into(),
                Some("h1".into()),
            )
            .expect("guarded call");
        assert!(!out.applied);
        assert_eq!(out.stored_guard.as_deref(), Some("h2"));
        let row = store.get_item(id.clone()).unwrap().unwrap();
        let p: serde_json::Value = serde_json::from_str(&row.payload_json).unwrap();
        assert_eq!(p["body_content"], "v2", "conflicting write must not land");

        // Guarded write to a missing item → conflict with stored_guard None.
        let missing = uuid::Uuid::new_v4().to_string();
        let out = store
            .upsert_item_guarded(
                missing,
                "manuscript".into(),
                r#"{"body_content":"x"}"#.into(),
                "body_content_hash".into(),
                Some("h1".into()),
            )
            .expect("guarded call on missing");
        assert!(!out.applied);
        assert!(out.stored_guard.is_none());
    }

    #[test]
    fn operations_for_and_effective_state_time_travel() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                id.clone(),
                "manuscript".into(),
                r#"{"title":"T","status":"draft","body_content":"v1"}"#.into(),
            )
            .expect("insert");
        store
            .upsert_item(
                id.clone(),
                "manuscript".into(),
                r#"{"body_content":"v2","body_content_hash":"h2"}"#.into(),
            )
            .expect("update body");
        store
            .upsert_item(
                id.clone(),
                "manuscript".into(),
                r#"{"title":"Renamed"}"#.into(),
            )
            .expect("update title");

        let ops = store.operations_for(id.clone(), 0).expect("ops");
        assert!(ops.len() >= 3, "each field update is an operation");
        let body_ops: Vec<_> = ops.iter().filter(|o| o.is_body_edit).collect();
        assert!(!body_ops.is_empty(), "body edits classified");
        assert!(
            ops.iter()
                .any(|o| !o.is_body_edit && o.field_names.contains(&"title".to_string())),
            "title edit is a metadata op"
        );

        // Time-travel: state before the title rename must still say "T".
        let rename_clock = ops
            .iter()
            .filter(|o| o.field_names.contains(&"title".to_string()))
            .map(|o| o.logical_clock)
            .max()
            .unwrap();
        let past = store
            .effective_state_at(id.clone(), rename_clock.saturating_sub(1))
            .expect("time travel")
            .expect("state exists");
        let p: serde_json::Value = serde_json::from_str(&past.payload_json).unwrap();
        assert_eq!(p["title"], "T", "pre-rename state must show old title");

        // Current state shows the rename.
        let row = store.get_item(id).unwrap().unwrap();
        let cur: serde_json::Value = serde_json::from_str(&row.payload_json).unwrap();
        assert_eq!(cur["title"], "Renamed");
    }

    #[test]
    fn count_by_schema_counts_matching() {
        let store = SharedStore::open_in_memory().expect("open");
        for i in 0..3 {
            store
                .upsert_item(
                    uuid::Uuid::new_v4().to_string(),
                    "review-request@1.0.0".into(),
                    format!(r#"{{"question": "q{i}"}}"#),
                )
                .expect("upsert");
        }
        store
            .upsert_item(
                uuid::Uuid::new_v4().to_string(),
                "task".into(),
                r#"{"title": "t"}"#.into(),
            )
            .expect("upsert task");

        assert_eq!(
            store
                .count_by_schema("review-request@1.0.0".into())
                .expect("count"),
            3
        );
        assert_eq!(store.count_by_schema("task".into()).expect("count"), 1);
        assert_eq!(store.count_by_schema("nothing".into()).expect("count"), 0);
    }

    #[test]
    fn cross_schema_isolation() {
        // Simulates multiple apps writing to the same store
        let store = SharedStore::open_in_memory().expect("open");
        let pub_id = uuid::Uuid::new_v4().to_string();
        let task_id = uuid::Uuid::new_v4().to_string();
        let email_id = uuid::Uuid::new_v4().to_string();

        store
            .upsert_item(
                pub_id.clone(),
                "imbib/bibliography-entry".into(),
                r#"{"cite_key": "Smith2024", "entry_type": "article", "title": "A Paper"}"#.into(),
            )
            .expect("upsert pub");
        store
            .upsert_item(
                task_id.clone(),
                "task".into(),
                r#"{"title": "Review paper", "state": "pending"}"#.into(),
            )
            .expect("upsert task");
        store
            .upsert_item(
                email_id.clone(),
                "email-message".into(),
                r#"{"subject": "Re: paper review", "body": "LGTM"}"#.into(),
            )
            .expect("upsert email");

        // Each schema query returns only its own items
        let pubs = store
            .query_by_schema("imbib/bibliography-entry".into(), 10, 0)
            .expect("query pubs");
        assert_eq!(pubs.len(), 1);
        assert_eq!(pubs[0].id, pub_id);

        let tasks = store
            .query_by_schema("task".into(), 10, 0)
            .expect("query tasks");
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].id, task_id);

        let emails = store
            .query_by_schema("email-message".into(), 10, 0)
            .expect("query emails");
        assert_eq!(emails.len(), 1);
        assert_eq!(emails[0].id, email_id);
    }
}
