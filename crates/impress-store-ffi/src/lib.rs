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
    reference::{EdgeType, TypedReference},
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
    /// Last-modified timestamp in milliseconds since Unix epoch (watermark
    /// polling: pass back as `modified_after_ms` in `SharedItemQuery`).
    pub modified_ms: i64,
    /// Envelope parent item id (folder/account/collection chains), if any.
    pub parent_id: Option<String>,
    pub is_read: bool,
    pub is_starred: bool,
    pub tags: Vec<String>,
    /// Flag color if the item is flagged (e.g. "red", "amber", "blue", "gray").
    pub flag_color: Option<String>,
}

/// Full-envelope upsert row (Stage 0 of the GUI unification). Unlike
/// `upsert_item`, this carries the envelope fields migrations need: a real
/// creation timestamp (mail must sort by message date, not import time), the
/// parent chain (message→folder→account, figure→folder), tags, read/starred.
/// `None` fields keep defaults on insert and are left untouched on update.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedItemUpsert {
    pub id: String,
    pub schema_ref: String,
    pub payload_json: String,
    pub parent_id: Option<String>,
    pub tags: Vec<String>,
    pub created_ms: Option<i64>,
    pub is_read: Option<bool>,
    pub is_starred: Option<bool>,
}

/// Outcome of a batch upsert.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedBatchResult {
    pub inserted: u32,
    pub updated: u32,
}

/// One payload-field equality filter. `value_json` is a JSON scalar
/// (`"draft"`, `42`, `true`) so the type survives the FFI boundary.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedFieldEq {
    pub field: String,
    pub value_json: String,
}

/// Flat, UniFFI-friendly query over items — compiles to `ItemQuery`
/// predicates. All filters are ANDed.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedItemQuery {
    pub schema_ref: Option<String>,
    /// Envelope parent filter (children of a folder/account/collection).
    pub parent_id: Option<String>,
    pub payload_eq: Vec<SharedFieldEq>,
    /// Only items modified strictly after this watermark (ms since epoch).
    pub modified_after_ms: Option<i64>,
    /// Sort field: "created" | "modified" | "payload.<field>". Empty = modified.
    pub sort_field: String,
    pub ascending: bool,
    /// 0 = default of 100.
    pub limit: u32,
    pub offset: u32,
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

// ─── Sync engine DTOs (ADR-0007 Phase 3, Phase C) ────────────────────────────
//
// FFI mirrors of `impress_core::sync::*`. Field names are kept byte-identical
// to the imbib-core mirrors so the Swift CKRecord codec can share one shape
// across both embeddings.

/// One pending sync-outbox entry: `(seq, kind, record_name)`.
///
/// `kind` is one of `item | reference | delete_item | delete_reference`;
/// `record_name` is the lowercased item UUID, or the raw `src|tgt|edge`
/// triple for reference kinds.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SyncOutboxEntry {
    pub seq: i64,
    pub kind: String,
    pub record_name: String,
}

/// One syncable envelope item (see `impress_core::sync::SyncItemRecord`).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SyncItemRecord {
    pub id: String,
    pub schema_ref: String,
    pub payload_json: String,
    pub logical_clock: u64,
    pub author_kind: String,
    pub author_id: String,
    pub origin: String,
    pub created_ms: i64,
    pub modified_ms: i64,
    pub tag_paths: Vec<String>,
    pub is_read: bool,
    pub is_starred: bool,
    pub flag_color: Option<String>,
    pub flag_style: Option<String>,
    pub flag_length: Option<String>,
    pub priority: String,
    pub parent_id: Option<String>,
    pub envelope_json: String,
}

/// One typed edge, CKRecord-named (`ref_<sha256(src|tgt|edge)[..32]>`).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SyncReferenceRecord {
    pub record_name: String,
    pub source_id: String,
    pub target_id: String,
    pub edge_type: String,
    pub metadata: Option<String>,
    pub logical_clock: u64,
}

/// One deletion marker (`ImpressTombstone` CKRecord).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SyncTombstoneRecord {
    pub record_name: String,
    pub schema_ref: String,
    pub deleted_at_ms: i64,
    pub origin: String,
}

/// Outcome counters for one remote-apply call.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SyncApplyReport {
    pub applied: u32,
    pub skipped_lww: u32,
    pub deferred: u32,
    pub resurrected: u32,
    pub conflict_backups: u32,
}

/// Live sync queue depths.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SyncCounts {
    pub outbox: u32,
    pub pending_refs: u32,
    pub tombstones: u32,
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

    /// Full-envelope upsert (Stage 0): like `upsert_item` but with real
    /// timestamps, parent chain, tags, and read/starred state. Insert sets
    /// everything; update applies payload additively plus any envelope field
    /// that is `Some`.
    pub fn upsert_item_v2(&self, row: SharedItemUpsert) -> Result<(), SharedStoreError> {
        let item_id: ItemId = row
            .id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {}", row.id),
            })?;
        let payload: BTreeMap<String, Value> =
            serde_json::from_str(&row.payload_json).map_err(|e| {
                SharedStoreError::InvalidArgument {
                    message: format!("invalid payload JSON: {e}"),
                }
            })?;

        let item = build_item_from_upsert(item_id, &row, payload.clone())?;
        match self.inner.insert(item) {
            Ok(_) => Ok(()),
            Err(StoreError::AlreadyExists(_)) => {
                self.inner
                    .update(item_id, upsert_update_mutations(&row, payload)?)?;
                Ok(())
            }
            Err(e) => Err(e.into()),
        }
    }

    /// Batch upsert in as few transactions as possible: new rows insert in a
    /// SINGLE transaction (`insert_batch`); pre-existing rows update
    /// individually. Designed for migration backfills (idempotent re-runs:
    /// deterministic ids make every row an update the second time).
    pub fn upsert_items(
        &self,
        rows: Vec<SharedItemUpsert>,
    ) -> Result<SharedBatchResult, SharedStoreError> {
        let mut to_insert: Vec<Item> = Vec::with_capacity(rows.len());
        let mut to_update: Vec<(ItemId, Vec<FieldMutation>)> = Vec::new();

        for row in &rows {
            let item_id: ItemId =
                row.id
                    .parse()
                    .map_err(|_| SharedStoreError::InvalidArgument {
                        message: format!("invalid UUID: {}", row.id),
                    })?;
            let payload: BTreeMap<String, Value> = serde_json::from_str(&row.payload_json)
                .map_err(|e| SharedStoreError::InvalidArgument {
                    message: format!("invalid payload JSON in {}: {e}", row.id),
                })?;
            if self.inner.get(item_id)?.is_some() {
                to_update.push((item_id, upsert_update_mutations(row, payload)?));
            } else {
                to_insert.push(build_item_from_upsert(item_id, row, payload)?);
            }
        }

        let inserted = to_insert.len() as u32;
        let updated = to_update.len() as u32;
        if !to_insert.is_empty() {
            self.inner.insert_batch(to_insert)?;
        }
        for (id, mutations) in to_update {
            if !mutations.is_empty() {
                self.inner.update(id, mutations)?;
            }
        }
        Ok(SharedBatchResult { inserted, updated })
    }

    /// Add a typed reference (graph edge) from `source_id` to `target_id`.
    /// `edge_type` uses the `SharedReferenceRow` convention (`Cites`,
    /// `Contains`, …); unknown strings become custom edges.
    pub fn add_reference(
        &self,
        source_id: String,
        target_id: String,
        edge_type: String,
    ) -> Result<(), SharedStoreError> {
        let source: ItemId = source_id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {source_id}"),
            })?;
        let target: ItemId = target_id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {target_id}"),
            })?;
        let reference = TypedReference {
            target,
            edge_type: parse_edge_type(&edge_type),
            metadata: None,
        };
        self.inner
            .update(source, vec![FieldMutation::AddReference(reference)])?;
        Ok(())
    }

    /// Remove a typed reference previously added with `add_reference`.
    pub fn remove_reference(
        &self,
        source_id: String,
        target_id: String,
        edge_type: String,
    ) -> Result<(), SharedStoreError> {
        let source: ItemId = source_id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {source_id}"),
            })?;
        let target: ItemId = target_id
            .parse()
            .map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid UUID: {target_id}"),
            })?;
        self.inner.update(
            source,
            vec![FieldMutation::RemoveReference(
                target,
                parse_edge_type(&edge_type),
            )],
        )?;
        Ok(())
    }

    /// Set (or clear, with `nil`) an item's envelope parent — folder moves,
    /// unfiling. `upsert_item*`'s update path never touches the parent, so
    /// moves must be explicit.
    pub fn set_parent(
        &self,
        id: String,
        parent_id: Option<String>,
    ) -> Result<(), SharedStoreError> {
        let item_id: ItemId = id.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid UUID: {id}"),
        })?;
        let parent: Option<ItemId> = match parent_id {
            Some(p) => Some(p.parse().map_err(|_| SharedStoreError::InvalidArgument {
                message: format!("invalid parent UUID: {p}"),
            })?),
            None => None,
        };
        self.inner
            .update(item_id, vec![FieldMutation::SetParent(parent)])?;
        Ok(())
    }

    /// Flat predicate query (Stage 0): schema/parent/payload-equality/
    /// modified-watermark filters, ANDed, with created/modified/payload sort.
    pub fn query_items(
        &self,
        query: SharedItemQuery,
    ) -> Result<Vec<SharedItemRow>, SharedStoreError> {
        let q = compile_shared_query(&query, false)?;
        let items = self.inner.query(&q)?;
        Ok(items.into_iter().map(item_to_row).collect())
    }

    /// Count of items matching `query` (limit/offset/sort ignored).
    pub fn count_items(&self, query: SharedItemQuery) -> Result<u32, SharedStoreError> {
        let q = compile_shared_query(&query, true)?;
        Ok(self.inner.count(&q)? as u32)
    }

    /// Declare record schemas whose items never enter the CloudKit sync
    /// outbox because they have their own sync protocol (mail = IMAP).
    /// Additive; also drains already-queued rows for those schemas. Items
    /// remain fully durable — this is NOT retention `ephemeral`.
    pub fn add_sync_excluded_schemas(&self, schemas: Vec<String>) -> Result<(), SharedStoreError> {
        self.inner.add_sync_excluded_schemas(&schemas)?;
        Ok(())
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

    // ─── CloudKit sync engine surface (ADR-0007 Phase 3, Phase C) ──────────
    //
    // Thin delegation to the Rust apply/snapshot engine in
    // `impress_core::sync`. Field shapes match the imbib-core mirrors.

    /// Pending outbox entries in queue order (push cursor).
    pub fn sync_outbox_entries(
        &self,
        limit: u32,
    ) -> Result<Vec<SyncOutboxEntry>, SharedStoreError> {
        let entries = self.inner.sync_outbox_entries(limit)?;
        Ok(entries
            .into_iter()
            .map(|(seq, kind, record_name)| SyncOutboxEntry {
                seq,
                kind,
                record_name,
            })
            .collect())
    }

    /// Remove confirmed-pushed outbox rows by sequence number.
    pub fn sync_outbox_remove(&self, seqs: Vec<i64>) -> Result<(), SharedStoreError> {
        self.inner.sync_outbox_remove(seqs)?;
        Ok(())
    }

    /// Snapshot outbox `item` entries into wire records (op items,
    /// ephemeral rows and already-deleted rows are omitted).
    pub fn sync_snapshot_items(
        &self,
        ids: Vec<String>,
    ) -> Result<Vec<SyncItemRecord>, SharedStoreError> {
        let records = self.inner.sync_snapshot_items(ids)?;
        Ok(records.into_iter().map(sync_item_to_ffi).collect())
    }

    /// Snapshot outbox `reference` entries (raw `src|tgt|edge` names) into
    /// wire records with hashed `ref_` record names.
    pub fn sync_snapshot_references(
        &self,
        record_names: Vec<String>,
    ) -> Result<Vec<SyncReferenceRecord>, SharedStoreError> {
        let records = self.inner.sync_snapshot_references(record_names)?;
        Ok(records.into_iter().map(sync_reference_to_ffi).collect())
    }

    /// Local tombstones since `since_ms`, as wire records.
    pub fn sync_local_tombstones(
        &self,
        since_ms: i64,
    ) -> Result<Vec<SyncTombstoneRecord>, SharedStoreError> {
        let records = self.inner.sync_local_tombstones(since_ms)?;
        Ok(records.into_iter().map(sync_tombstone_to_ffi).collect())
    }

    /// Merge fetched remote item records (whole-record LWW in Rust,
    /// suppressed capture, FTS refreshed, manuscript conflict backups).
    pub fn sync_apply_remote_items(
        &self,
        records: Vec<SyncItemRecord>,
    ) -> Result<SyncApplyReport, SharedStoreError> {
        let report = self
            .inner
            .sync_apply_remote_items(records.into_iter().map(sync_item_from_ffi).collect())?;
        Ok(sync_report_to_ffi(report))
    }

    /// Apply fetched remote reference records; missing endpoints defer.
    pub fn sync_apply_remote_references(
        &self,
        refs: Vec<SyncReferenceRecord>,
    ) -> Result<SyncApplyReport, SharedStoreError> {
        let report = self.inner.sync_apply_remote_references(
            refs.into_iter().map(sync_reference_from_ffi).collect(),
        )?;
        Ok(sync_report_to_ffi(report))
    }

    /// Re-attempt all deferred references (call after each item batch).
    pub fn sync_retry_pending_references(&self) -> Result<SyncApplyReport, SharedStoreError> {
        Ok(sync_report_to_ffi(
            self.inner.sync_retry_pending_references()?,
        ))
    }

    /// Apply CKRecord deletions: `ref_...` names delete edges, item-UUID
    /// names run the tombstone rule with `deleted_at = now`.
    pub fn sync_apply_remote_deletions(
        &self,
        record_names: Vec<String>,
    ) -> Result<SyncApplyReport, SharedStoreError> {
        Ok(sync_report_to_ffi(
            self.inner.sync_apply_remote_deletions(record_names)?,
        ))
    }

    /// Apply fetched `ImpressTombstone` records (edit-after-delete
    /// resurrects and re-pushes; ties → delete wins).
    pub fn sync_apply_remote_tombstones(
        &self,
        tombstones: Vec<SyncTombstoneRecord>,
    ) -> Result<SyncApplyReport, SharedStoreError> {
        let report = self.inner.sync_apply_remote_tombstones(
            tombstones
                .into_iter()
                .map(sync_tombstone_from_ffi)
                .collect(),
        )?;
        Ok(sync_report_to_ffi(report))
    }

    /// Read a sync-namespaced metadata value (`"sync."`-prefixed keys only).
    pub fn sync_metadata_get(&self, key: String) -> Result<Option<String>, SharedStoreError> {
        Ok(self.inner.sync_metadata_get(&key)?)
    }

    /// Write (or clear, with `nil`) a sync-namespaced metadata value.
    pub fn sync_metadata_set(
        &self,
        key: String,
        value: Option<String>,
    ) -> Result<(), SharedStoreError> {
        self.inner.sync_metadata_set(&key, value)?;
        Ok(())
    }

    /// Read the archived CKRecord system fields for a record, if any.
    pub fn sync_record_state_get(
        &self,
        record_name: String,
    ) -> Result<Option<Vec<u8>>, SharedStoreError> {
        Ok(self.inner.sync_record_state_get(&record_name)?)
    }

    /// Archive CKRecord system fields for a record.
    pub fn sync_record_state_set(
        &self,
        record_name: String,
        blob: Vec<u8>,
    ) -> Result<(), SharedStoreError> {
        self.inner.sync_record_state_set(&record_name, blob)?;
        Ok(())
    }

    /// Drop the archived system fields for a record.
    pub fn sync_record_state_delete(&self, record_name: String) -> Result<(), SharedStoreError> {
        self.inner.sync_record_state_delete(&record_name)?;
        Ok(())
    }

    /// Live sync queue depths (outbox / deferred refs / tombstones).
    pub fn sync_status_counts(&self) -> Result<SyncCounts, SharedStoreError> {
        let counts = self.inner.sync_status_counts()?;
        Ok(SyncCounts {
            outbox: counts.outbox,
            pending_refs: counts.pending_refs,
            tombstones: counts.tombstones,
        })
    }
}

// ─── Private helpers ─────────────────────────────────────────────────────────

fn sync_item_to_ffi(r: impress_core::sync::SyncItemRecord) -> SyncItemRecord {
    SyncItemRecord {
        id: r.id,
        schema_ref: r.schema_ref,
        payload_json: r.payload_json,
        logical_clock: r.logical_clock,
        author_kind: r.author_kind,
        author_id: r.author_id,
        origin: r.origin,
        created_ms: r.created_ms,
        modified_ms: r.modified_ms,
        tag_paths: r.tag_paths,
        is_read: r.is_read,
        is_starred: r.is_starred,
        flag_color: r.flag_color,
        flag_style: r.flag_style,
        flag_length: r.flag_length,
        priority: r.priority,
        parent_id: r.parent_id,
        envelope_json: r.envelope_json,
    }
}

fn sync_item_from_ffi(r: SyncItemRecord) -> impress_core::sync::SyncItemRecord {
    impress_core::sync::SyncItemRecord {
        id: r.id,
        schema_ref: r.schema_ref,
        payload_json: r.payload_json,
        logical_clock: r.logical_clock,
        author_kind: r.author_kind,
        author_id: r.author_id,
        origin: r.origin,
        created_ms: r.created_ms,
        modified_ms: r.modified_ms,
        tag_paths: r.tag_paths,
        is_read: r.is_read,
        is_starred: r.is_starred,
        flag_color: r.flag_color,
        flag_style: r.flag_style,
        flag_length: r.flag_length,
        priority: r.priority,
        parent_id: r.parent_id,
        envelope_json: r.envelope_json,
    }
}

fn sync_reference_to_ffi(r: impress_core::sync::SyncReferenceRecord) -> SyncReferenceRecord {
    SyncReferenceRecord {
        record_name: r.record_name,
        source_id: r.source_id,
        target_id: r.target_id,
        edge_type: r.edge_type,
        metadata: r.metadata,
        logical_clock: r.logical_clock,
    }
}

fn sync_reference_from_ffi(r: SyncReferenceRecord) -> impress_core::sync::SyncReferenceRecord {
    impress_core::sync::SyncReferenceRecord {
        record_name: r.record_name,
        source_id: r.source_id,
        target_id: r.target_id,
        edge_type: r.edge_type,
        metadata: r.metadata,
        logical_clock: r.logical_clock,
    }
}

fn sync_tombstone_to_ffi(r: impress_core::sync::SyncTombstoneRecord) -> SyncTombstoneRecord {
    SyncTombstoneRecord {
        record_name: r.record_name,
        schema_ref: r.schema_ref,
        deleted_at_ms: r.deleted_at_ms,
        origin: r.origin,
    }
}

fn sync_tombstone_from_ffi(r: SyncTombstoneRecord) -> impress_core::sync::SyncTombstoneRecord {
    impress_core::sync::SyncTombstoneRecord {
        record_name: r.record_name,
        schema_ref: r.schema_ref,
        deleted_at_ms: r.deleted_at_ms,
        origin: r.origin,
    }
}

fn sync_report_to_ffi(r: impress_core::sync::SyncApplyReport) -> SyncApplyReport {
    SyncApplyReport {
        applied: r.applied,
        skipped_lww: r.skipped_lww,
        deferred: r.deferred,
        resurrected: r.resurrected,
        conflict_backups: r.conflict_backups,
    }
}

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
        modified_ms: item.modified.timestamp_millis(),
        parent_id: item.parent.map(|p| p.to_string()),
        is_read: item.is_read,
        is_starred: item.is_starred,
        tags: item.tags,
        flag_color,
    }
}

/// Mutations for the UPDATE path of an upsert: payload fields additively,
/// plus any envelope field the caller supplied. Parent is deliberately NOT
/// updated here (moves are semantic — use `set_parent`); `created_ms` is
/// immutable after insert.
fn upsert_update_mutations(
    row: &SharedItemUpsert,
    payload: BTreeMap<String, Value>,
) -> Result<Vec<FieldMutation>, SharedStoreError> {
    let mut mutations: Vec<FieldMutation> = payload
        .into_iter()
        .map(|(k, v)| FieldMutation::SetPayload(k, v))
        .collect();
    if let Some(r) = row.is_read {
        mutations.push(FieldMutation::SetRead(r));
    }
    if let Some(s) = row.is_starred {
        mutations.push(FieldMutation::SetStarred(s));
    }
    for tag in &row.tags {
        mutations.push(FieldMutation::AddTag(tag.clone()));
    }
    Ok(mutations)
}

/// Compile a `SharedItemQuery` into a core `ItemQuery`.
fn compile_shared_query(
    query: &SharedItemQuery,
    for_count: bool,
) -> Result<ItemQuery, SharedStoreError> {
    let mut predicates: Vec<Predicate> = Vec::new();
    if let Some(pid) = &query.parent_id {
        let parent: ItemId = pid.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid parent UUID: {pid}"),
        })?;
        predicates.push(Predicate::HasParent(parent));
    }
    for eq in &query.payload_eq {
        let value: Value = serde_json::from_str(&eq.value_json).map_err(|e| {
            SharedStoreError::InvalidArgument {
                message: format!("invalid value_json for {}: {e}", eq.field),
            }
        })?;
        predicates.push(Predicate::Eq(eq.field.clone(), value));
    }
    if let Some(ms) = query.modified_after_ms {
        // `modified` is stored as INTEGER milliseconds (see insert_item).
        predicates.push(Predicate::Gt("modified".into(), Value::Int(ms)));
    }

    let sort_field = if query.sort_field.is_empty() {
        "modified".to_string()
    } else {
        query.sort_field.clone()
    };

    Ok(ItemQuery {
        schema: query.schema_ref.clone(),
        predicates,
        sort: if for_count {
            vec![]
        } else {
            vec![SortDescriptor {
                field: sort_field,
                ascending: query.ascending,
            }]
        },
        limit: if for_count {
            None
        } else {
            Some(if query.limit == 0 {
                100
            } else {
                query.limit as usize
            })
        },
        offset: if for_count {
            None
        } else {
            Some(query.offset as usize)
        },
        ..ItemQuery::default()
    })
}

/// Parse an edge-type string in the `SharedReferenceRow` convention — the
/// serde name without quotes (`Cites`, `Contains`, …); anything unknown
/// becomes `Custom(<s>)`.
fn parse_edge_type(s: &str) -> EdgeType {
    serde_json::from_str::<EdgeType>(&format!("\"{s}\""))
        .unwrap_or_else(|_| EdgeType::Custom(s.to_string()))
}

/// Build a full `Item` from a `SharedItemUpsert` (insert path).
fn build_item_from_upsert(
    id: ItemId,
    row: &SharedItemUpsert,
    payload: BTreeMap<String, Value>,
) -> Result<Item, SharedStoreError> {
    use chrono::{TimeZone, Utc};

    let mut item = build_item(id, row.schema_ref.clone(), payload);
    if let Some(ms) = row.created_ms {
        let ts = Utc.timestamp_millis_opt(ms).single().ok_or_else(|| {
            SharedStoreError::InvalidArgument {
                message: format!("invalid created_ms: {ms}"),
            }
        })?;
        item.created = ts;
        item.modified = ts;
    }
    if let Some(pid) = &row.parent_id {
        item.parent = Some(pid.parse().map_err(|_| SharedStoreError::InvalidArgument {
            message: format!("invalid parent UUID: {pid}"),
        })?);
    }
    item.tags = row.tags.clone();
    if let Some(r) = row.is_read {
        item.is_read = r;
    }
    if let Some(s) = row.is_starred {
        item.is_starred = s;
    }
    Ok(item)
}

/// The allowed `manuscript.format` payload values (single source of truth:
/// `impress_core::manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS`). Exposed so
/// app-side format enums can assert parity without duplicating the list.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn supported_manuscript_formats() -> Vec<String> {
    impress_core::manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS
        .iter()
        .map(|s| s.to_string())
        .collect()
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sync_excluded_schemas_bypass_and_drain_outbox() {
        let store = SharedStore::open_in_memory().expect("open");
        let a = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                a.clone(),
                "email-message".into(),
                r#"{"subject": "s", "body": "b", "from": "f"}"#.into(),
            )
            .expect("insert email");
        let before = store.sync_outbox_entries(100).expect("outbox");
        assert!(
            before.iter().any(|e| e.record_name == a.to_lowercase()),
            "pre-exclusion insert must enqueue"
        );

        store
            .add_sync_excluded_schemas(vec!["email-message".into()])
            .expect("exclude");
        let drained = store.sync_outbox_entries(100).expect("outbox2");
        assert!(
            !drained.iter().any(|e| e.record_name == a.to_lowercase()),
            "exclusion must drain queued rows for the schema"
        );

        let b = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                b.clone(),
                "email-message".into(),
                r#"{"subject": "s2", "body": "b2", "from": "f2"}"#.into(),
            )
            .expect("insert email 2");
        let after = store.sync_outbox_entries(100).expect("outbox3");
        assert!(
            !after.iter().any(|e| e.record_name == b.to_lowercase()),
            "post-exclusion inserts must bypass the outbox"
        );
        // Durability is untouched: the rows are still real items.
        assert!(store.get_item(b).expect("get").is_some());
    }

    #[test]
    fn upsert_item_v2_carries_envelope_fields() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        let folder_id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                folder_id.clone(),
                "mail-folder".into(),
                r#"{"name": "Inbox", "role": "inbox"}"#.into(),
            )
            .expect("folder");

        store
            .upsert_item_v2(SharedItemUpsert {
                id: id.clone(),
                schema_ref: "email-message".into(),
                payload_json:
                    r#"{"subject": "Referee report", "body": "dark matter comments", "from": "ed@apj.org"}"#
                        .into(),
                parent_id: Some(folder_id.clone()),
                tags: vec!["referee".into()],
                created_ms: Some(1_600_000_000_000),
                is_read: Some(true),
                is_starred: None,
            })
            .expect("upsert v2");

        let row = store.get_item(id.clone()).expect("get").expect("exists");
        assert_eq!(
            row.created_ms, 1_600_000_000_000,
            "created must be the message date"
        );
        assert_eq!(row.parent_id.as_deref(), Some(folder_id.as_str()));
        assert!(row.is_read);
        assert_eq!(row.tags, vec!["referee".to_string()]);
    }

    #[test]
    fn mail_payloads_are_full_text_searchable() {
        let store = SharedStore::open_in_memory().expect("open");
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                id.clone(),
                "email-message".into(),
                r#"{"subject": "Reionization draft", "body": "the epoch of reionization ended", "from": "colleague@example.org"}"#
                    .into(),
            )
            .expect("upsert email");

        // Search matches via the COALESCE mapping (subject→title, body→body).
        let hits = store
            .search("reionization".into(), None, 10)
            .expect("search");
        assert!(
            hits.iter().any(|r| r.id == id),
            "email must be findable by subject/body text"
        );
    }

    #[test]
    fn query_items_filters_parent_payload_and_watermark() {
        let store = SharedStore::open_in_memory().expect("open");
        let folder = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                folder.clone(),
                "mail-folder".into(),
                r#"{"name": "F"}"#.into(),
            )
            .expect("folder");

        let in_folder = uuid::Uuid::new_v4().to_string();
        let elsewhere = uuid::Uuid::new_v4().to_string();
        for (id, parent, status) in [
            (&in_folder, Some(folder.clone()), "draft"),
            (&elsewhere, None, "dismissed"),
        ] {
            store
                .upsert_item_v2(SharedItemUpsert {
                    id: id.clone(),
                    schema_ref: "manuscript".into(),
                    payload_json: format!(
                        r#"{{"title": "T", "status": "{status}", "current_revision_ref": "{id}"}}"#
                    ),
                    parent_id: parent,
                    tags: vec![],
                    created_ms: None,
                    is_read: None,
                    is_starred: None,
                })
                .expect("upsert");
        }

        let by_parent = store
            .query_items(SharedItemQuery {
                schema_ref: Some("manuscript".into()),
                parent_id: Some(folder.clone()),
                payload_eq: vec![],
                modified_after_ms: None,
                sort_field: String::new(),
                ascending: false,
                limit: 0,
                offset: 0,
            })
            .expect("query parent");
        assert_eq!(by_parent.len(), 1);
        assert_eq!(by_parent[0].id, in_folder);

        let dismissed = store
            .query_items(SharedItemQuery {
                schema_ref: Some("manuscript".into()),
                parent_id: None,
                payload_eq: vec![SharedFieldEq {
                    field: "status".into(),
                    value_json: "\"dismissed\"".into(),
                }],
                modified_after_ms: None,
                sort_field: String::new(),
                ascending: false,
                limit: 0,
                offset: 0,
            })
            .expect("query status");
        assert_eq!(dismissed.len(), 1);
        assert_eq!(dismissed[0].id, elsewhere);

        // Watermark: everything is newer than 0, nothing is newer than
        // far-future.
        let all = store
            .count_items(SharedItemQuery {
                schema_ref: Some("manuscript".into()),
                parent_id: None,
                payload_eq: vec![],
                modified_after_ms: Some(0),
                sort_field: String::new(),
                ascending: false,
                limit: 0,
                offset: 0,
            })
            .expect("count");
        assert_eq!(all, 2);
        let none = store
            .count_items(SharedItemQuery {
                schema_ref: Some("manuscript".into()),
                parent_id: None,
                payload_eq: vec![],
                modified_after_ms: Some(4_102_444_800_000),
                sort_field: String::new(),
                ascending: false,
                limit: 0,
                offset: 0,
            })
            .expect("count none");
        assert_eq!(none, 0);
    }

    #[test]
    fn upsert_items_batch_is_idempotent() {
        let store = SharedStore::open_in_memory().expect("open");
        let ids: Vec<String> = (0..5).map(|_| uuid::Uuid::new_v4().to_string()).collect();
        let rows: Vec<SharedItemUpsert> = ids
            .iter()
            .enumerate()
            .map(|(i, id)| SharedItemUpsert {
                id: id.clone(),
                schema_ref: "email-message".into(),
                payload_json: format!(r#"{{"subject": "msg {i}", "body": "b", "from": "a@b.c"}}"#),
                parent_id: None,
                tags: vec![],
                created_ms: Some(1_600_000_000_000 + i as i64),
                is_read: None,
                is_starred: None,
            })
            .collect();

        let first = store.upsert_items(rows.clone()).expect("first batch");
        assert_eq!((first.inserted, first.updated), (5, 0));
        // Deterministic ids: the re-run must update, not duplicate.
        let second = store.upsert_items(rows).expect("second batch");
        assert_eq!((second.inserted, second.updated), (0, 5));
        assert_eq!(
            store
                .count_by_schema("email-message".into())
                .expect("count"),
            5
        );
    }

    #[test]
    fn references_and_parent_moves() {
        let store = SharedStore::open_in_memory().expect("open");
        let a = uuid::Uuid::new_v4().to_string();
        let b = uuid::Uuid::new_v4().to_string();
        for id in [&a, &b] {
            store
                .upsert_item(id.clone(), "figure".into(), r#"{"format": "svg"}"#.into())
                .expect("upsert");
        }

        store
            .add_reference(a.clone(), b.clone(), "DerivedFrom".into())
            .expect("add ref");
        let refs = store.get_item_references(a.clone()).expect("refs");
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[0].target_id, b);
        store
            .remove_reference(a.clone(), b.clone(), "DerivedFrom".into())
            .expect("remove ref");
        assert!(store
            .get_item_references(a.clone())
            .expect("refs2")
            .is_empty());

        store
            .set_parent(a.clone(), Some(b.clone()))
            .expect("set parent");
        assert_eq!(
            store
                .get_item(a.clone())
                .expect("get")
                .unwrap()
                .parent_id
                .as_deref(),
            Some(b.as_str())
        );
        store.set_parent(a.clone(), None).expect("clear parent");
        assert_eq!(store.get_item(a).expect("get").unwrap().parent_id, None);
    }

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
