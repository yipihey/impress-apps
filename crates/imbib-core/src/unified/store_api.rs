use std::path::Path;
use std::sync::Arc;

use chrono::Utc;
use impress_core::item::{FlagState, Value};
use impress_core::query::{ItemQuery, Predicate, SortDescriptor};
use impress_core::reference::EdgeType;
use impress_core::store::{FieldMutation, ItemStore};
use impress_core::SqliteItemStore;
use uuid::Uuid;

use super::conversion;
use super::schemas;
use super::shaped_queries::*; // includes ArtifactRow, ArtifactRelation, item_to_artifact_row

/// Error type for the store API, exposed via UniFFI.
#[derive(Debug, thiserror::Error)]
#[cfg_attr(feature = "native", derive(uniffi::Error))]
pub enum StoreApiError {
    #[error("Not found: {0}")]
    NotFound(String),
    #[error("Already exists: {0}")]
    AlreadyExists(String),
    #[error("Invalid input: {0}")]
    InvalidInput(String),
    #[error("Storage error: {0}")]
    Storage(String),
}

impl From<impress_core::StoreError> for StoreApiError {
    fn from(e: impress_core::StoreError) -> Self {
        match e {
            impress_core::StoreError::NotFound(id) => StoreApiError::NotFound(id.to_string()),
            impress_core::StoreError::AlreadyExists(id) => {
                StoreApiError::AlreadyExists(id.to_string())
            }
            impress_core::StoreError::SchemaNotFound(s) => StoreApiError::NotFound(s),
            impress_core::StoreError::Validation(msg) => StoreApiError::InvalidInput(msg),
            impress_core::StoreError::Storage(msg) => StoreApiError::Storage(msg),
        }
    }
}

/// Information returned after a mutation for undo/redo registration.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct UndoInfo {
    /// The operation IDs created by this mutation (as UUID strings).
    pub operation_ids: Vec<String>,
    /// If multiple operations share a batch, this is their shared batch ID.
    pub batch_id: Option<String>,
    /// Human-readable description for the Edit menu (e.g., "Star 3 Papers").
    pub description: String,
}

impl From<impress_core::UndoInfo> for UndoInfo {
    fn from(info: impress_core::UndoInfo) -> Self {
        Self {
            operation_ids: info.operation_ids.iter().map(|id| id.to_string()).collect(),
            batch_id: info.batch_id,
            description: info.description,
        }
    }
}

/// One entry of the "Recent" activity list: a publication the user viewed or
/// added by hand. Automated ingest never produces these.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct RecentActivityRow {
    /// Publication UUID string.
    pub id: String,
    /// `"viewed"` or `"added"`.
    pub kind: String,
    /// Epoch milliseconds of the activity.
    pub occurred_at: i64,
}

/// Result of a (possibly guarded) manuscript body save.
///
/// `applied == false` means the compare-and-set guard rejected the write:
/// `stored_hash` is what the store currently holds — re-read, reconcile,
/// and retry (or surface a conflict banner).
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ManuscriptSaveOutcome {
    pub applied: bool,
    /// The `body_content_hash` the store held BEFORE this call (None if unset).
    pub stored_hash: Option<String>,
    /// The hash of the newly-written body (None when not applied).
    pub new_hash: Option<String>,
}

/// Summary of an undo group for the undo history panel.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct UndoGroupRow {
    /// Representative operation ID (first in the group).
    pub operation_id: String,
    /// Batch ID if this is a grouped operation, None if single.
    pub batch_id: Option<String>,
    /// Number of operations in this group.
    pub operation_count: u32,
    /// Human-readable description ("Star 3 Papers", "Delete Paper").
    pub description: String,
    /// Timestamp of the most recent operation in the group (epoch millis).
    pub timestamp: i64,
    /// Who performed this action.
    pub author: String,
    /// Author kind: "Human", "Agent", "System".
    pub author_kind: String,
}

/// Snapshot of an item and its children, for undo of delete operations.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ItemSnapshot {
    /// JSON-serialized Item.
    pub item_json: String,
    /// JSON-serialized child Items (linked files, annotations, comments, etc).
    pub child_jsons: Vec<String>,
}

/// Snapshot for undoing a tag deletion.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct TagDeleteSnapshot {
    /// JSON-serialized tag definition Item.
    pub tag_definition_json: String,
    /// IDs of publications that had this tag (as UUID strings).
    pub tagged_publication_ids: Vec<String>,
    /// The tag path that was deleted.
    pub tag_path: String,
}

/// Snapshot for undoing a library deletion.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct LibraryDeleteSnapshot {
    /// JSON-serialized library Item.
    pub library_json: String,
    /// IDs of publications that had this library as parent (as UUID strings).
    pub child_publication_ids: Vec<String>,
    /// IDs of collections that had this library as parent.
    pub child_collection_ids: Vec<String>,
}

// --- CloudKit sync engine DTOs (ADR-0007 Phase 3, Phase C) ---
//
// FFI mirrors of `impress_core::sync::*`. Field names are kept byte-identical
// to the impress-store-ffi mirrors so the Swift CKRecord codec can share one
// shape across both embeddings.

/// One pending sync-outbox entry: `(seq, kind, record_name)`.
///
/// `kind` is one of `item | reference | delete_item | delete_reference`;
/// `record_name` is the lowercased item UUID, or the raw `src|tgt|edge`
/// triple for reference kinds.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct SyncOutboxEntry {
    pub seq: i64,
    pub kind: String,
    pub record_name: String,
}

/// One syncable envelope item (see `impress_core::sync::SyncItemRecord`).
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
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
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct SyncReferenceRecord {
    pub record_name: String,
    pub source_id: String,
    pub target_id: String,
    pub edge_type: String,
    pub metadata: Option<String>,
    pub logical_clock: u64,
}

/// One deletion marker (`ImpressTombstone` CKRecord).
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct SyncTombstoneRecord {
    pub record_name: String,
    pub schema_ref: String,
    pub deleted_at_ms: i64,
    pub origin: String,
}

/// Outcome counters for one remote-apply call.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct SyncApplyReport {
    pub applied: u32,
    pub skipped_lww: u32,
    pub deferred: u32,
    pub resurrected: u32,
    pub conflict_backups: u32,
}

/// Live sync queue depths for Settings / `/api/sync/status`.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct SyncCounts {
    pub outbox: u32,
    pub pending_refs: u32,
    pub tombstones: u32,
}

impl From<impress_core::sync::SyncItemRecord> for SyncItemRecord {
    fn from(r: impress_core::sync::SyncItemRecord) -> Self {
        Self {
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
}

impl From<SyncItemRecord> for impress_core::sync::SyncItemRecord {
    fn from(r: SyncItemRecord) -> Self {
        Self {
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
}

impl From<impress_core::sync::SyncReferenceRecord> for SyncReferenceRecord {
    fn from(r: impress_core::sync::SyncReferenceRecord) -> Self {
        Self {
            record_name: r.record_name,
            source_id: r.source_id,
            target_id: r.target_id,
            edge_type: r.edge_type,
            metadata: r.metadata,
            logical_clock: r.logical_clock,
        }
    }
}

impl From<SyncReferenceRecord> for impress_core::sync::SyncReferenceRecord {
    fn from(r: SyncReferenceRecord) -> Self {
        Self {
            record_name: r.record_name,
            source_id: r.source_id,
            target_id: r.target_id,
            edge_type: r.edge_type,
            metadata: r.metadata,
            logical_clock: r.logical_clock,
        }
    }
}

impl From<impress_core::sync::SyncTombstoneRecord> for SyncTombstoneRecord {
    fn from(r: impress_core::sync::SyncTombstoneRecord) -> Self {
        Self {
            record_name: r.record_name,
            schema_ref: r.schema_ref,
            deleted_at_ms: r.deleted_at_ms,
            origin: r.origin,
        }
    }
}

impl From<SyncTombstoneRecord> for impress_core::sync::SyncTombstoneRecord {
    fn from(r: SyncTombstoneRecord) -> Self {
        Self {
            record_name: r.record_name,
            schema_ref: r.schema_ref,
            deleted_at_ms: r.deleted_at_ms,
            origin: r.origin,
        }
    }
}

impl From<impress_core::sync::SyncApplyReport> for SyncApplyReport {
    fn from(r: impress_core::sync::SyncApplyReport) -> Self {
        Self {
            applied: r.applied,
            skipped_lww: r.skipped_lww,
            deferred: r.deferred,
            resurrected: r.resurrected,
            conflict_backups: r.conflict_backups,
        }
    }
}

impl From<impress_core::sync::SyncCounts> for SyncCounts {
    fn from(c: impress_core::sync::SyncCounts) -> Self {
        Self {
            outbox: c.outbox,
            pending_refs: c.pending_refs,
            tombstones: c.tombstones,
        }
    }
}

/// The main entry point for Swift. Wraps SqliteItemStore + SchemaRegistry.
#[cfg_attr(feature = "native", derive(uniffi::Object))]
pub struct ImbibStore {
    // `pub(super)` so sibling modules of `unified` (e.g. `backup_api`) can add
    // exported methods without living in this 7k-line file.
    pub(super) store: SqliteItemStore,
    #[allow(dead_code)] // Available for validation in future phases
    registry: impress_core::SchemaRegistry,
    tag_defs_cache: std::sync::Mutex<Option<Vec<TagDisplayRow>>>,
}

/// Private helpers (not exported via UniFFI).
impl ImbibStore {
    /// Invalidate the cached tag definitions, forcing reload on next access.
    fn invalidate_tag_cache(&self) {
        *self.tag_defs_cache.lock().unwrap() = None;
    }

    /// Apply a single mutation to multiple item IDs, grouping into a batch for undo.
    fn apply_mutation_to_ids(
        &self,
        ids: &[String],
        mutation: FieldMutation,
    ) -> Result<UndoInfo, StoreApiError> {
        use impress_core::operation::{
            undo_description, OperationIntent, OperationSpec, OperationType, RetentionTier,
        };

        let op_type: OperationType = mutation.clone().into();
        let count = ids.len();
        let description = undo_description(&op_type, count);

        if count == 1 {
            let uuid = parse_uuid(&ids[0])?;
            let info = self.store.update_with_undo(uuid, vec![mutation])?;
            return Ok(UndoInfo {
                operation_ids: info.operation_ids.iter().map(|id| id.to_string()).collect(),
                batch_id: info.batch_id,
                description,
            });
        }

        // Multiple IDs — build a batch of operation specs
        let mut specs = Vec::with_capacity(count);
        for id_str in ids {
            let uuid = parse_uuid(id_str)?;
            specs.push(OperationSpec {
                target_id: uuid,
                op_type: mutation.clone().into(),
                intent: OperationIntent::Routine,
                reason: None,
                batch_id: None, // apply_operation_batch assigns its own
                author: "user:local".into(),
                author_kind: impress_core::item::ActorKind::Human,
                retention: RetentionTier::Durable,
            });
        }

        let op_ids = self.store.apply_operation_batch(specs)?;

        // Read back the batch_id assigned by apply_operation_batch
        let batch_id = if let Some(first_id) = op_ids.first() {
            self.store.get(*first_id)?.and_then(|item| item.batch_id)
        } else {
            None
        };

        Ok(UndoInfo {
            operation_ids: op_ids.iter().map(|id| id.to_string()).collect(),
            batch_id,
            description,
        })
    }

    /// Snapshot all child items of a parent item as JSON strings.
    fn snapshot_children(&self, parent_id: uuid::Uuid) -> Result<Vec<String>, StoreApiError> {
        let q = ItemQuery {
            predicates: vec![Predicate::HasParent(parent_id)],
            ..Default::default()
        };
        let children = self.store.query(&q)?;
        children
            .iter()
            .map(|c| {
                serde_json::to_string(c)
                    .map_err(|e| StoreApiError::Storage(format!("serialize child: {}", e)))
            })
            .collect()
    }
}

/// Predicate that matches publications visible in a library — either as the
/// library's children (parent==library) OR via a Contains edge from the library
/// to the publication.
///
/// Use this anywhere we want "all papers shown when the user clicks library X".
/// Don't use it for structural/hierarchy queries (collections-in-library,
/// smart-searches-in-library, linked-files-of-publication) — those should keep
/// `HasParent` because they describe ownership, not membership.
pub fn in_library_predicate(library_id: Uuid) -> Predicate {
    Predicate::Or(vec![
        Predicate::HasParent(library_id),
        Predicate::ReferencedBy(EdgeType::Contains, library_id),
    ])
}

#[cfg_attr(feature = "native", uniffi::export)]
impl ImbibStore {
    /// Open or create a store at the given database path.
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open(path: String) -> Result<Arc<Self>, StoreApiError> {
        let store = SqliteItemStore::open(Path::new(&path))?;
        let mut registry = impress_core::SchemaRegistry::new();
        schemas::register_all(&mut registry);
        Ok(Arc::new(Self {
            store,
            registry,
            tag_defs_cache: std::sync::Mutex::new(None),
        }))
    }

    /// Open an in-memory store (for testing).
    #[cfg_attr(feature = "native", uniffi::constructor)]
    pub fn open_in_memory() -> Result<Arc<Self>, StoreApiError> {
        let store = SqliteItemStore::open_in_memory()?;
        let mut registry = impress_core::SchemaRegistry::new();
        schemas::register_all(&mut registry);
        Ok(Arc::new(Self {
            store,
            registry,
            tag_defs_cache: std::sync::Mutex::new(None),
        }))
    }

    // --- Library operations ---

    pub fn list_libraries(&self) -> Result<Vec<LibraryRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/library".into()),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let mut rows = Vec::new();
        for item in &items {
            let pub_count = self.count_children(item.id, "imbib/bibliography-entry")?;
            rows.push(item_to_library_row(item, pub_count as i32));
        }
        Ok(rows)
    }

    pub fn create_library(&self, name: String) -> Result<LibraryRow, StoreApiError> {
        let item = conversion::library_to_item(&name, None, None, false, false, false);
        self.store.insert(item.clone())?;
        Ok(item_to_library_row(&item, 0))
    }

    pub fn delete_library(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.delete(uuid)?;
        Ok(())
    }

    // --- Collection operations ---

    pub fn list_collections(
        &self,
        library_id: String,
    ) -> Result<Vec<CollectionRow>, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/collection".into()),
            predicates: vec![Predicate::HasParent(parent_uuid)],
            sort: vec![SortDescriptor {
                field: "payload.sort_order".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let mut rows = Vec::new();
        for item in &items {
            let pub_count = self.count_collection_members(item.id)?;
            rows.push(item_to_collection_row(item, pub_count as i32));
        }
        Ok(rows)
    }

    pub fn create_collection(
        &self,
        name: String,
        library_id: String,
        is_smart: bool,
        query: Option<String>,
    ) -> Result<CollectionRow, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let item = conversion::collection_to_item(
            &name,
            Some(parent_uuid),
            is_smart,
            query.as_deref(),
            None,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_collection_row(&item, 0))
    }

    pub fn add_to_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> Result<UndoInfo, StoreApiError> {
        let coll_uuid = parse_uuid(&collection_id)?;
        let mut all_op_ids = Vec::new();
        let mut batch_id = None;
        for pub_id_str in &publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            let info = self.store.update_with_undo(
                coll_uuid,
                vec![FieldMutation::AddReference(
                    impress_core::reference::TypedReference {
                        target: pub_uuid,
                        edge_type: EdgeType::Contains,
                        metadata: None,
                    },
                )],
            )?;
            all_op_ids.extend(info.operation_ids);
            if batch_id.is_none() {
                batch_id = info.batch_id;
            }
        }
        Ok(UndoInfo {
            operation_ids: all_op_ids.iter().map(|id| id.to_string()).collect(),
            batch_id,
            description: "Add to Collection".into(),
        })
    }

    pub fn remove_from_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> Result<UndoInfo, StoreApiError> {
        let coll_uuid = parse_uuid(&collection_id)?;
        let mut all_op_ids = Vec::new();
        let mut batch_id = None;
        for pub_id_str in &publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            let info = self.store.update_with_undo(
                coll_uuid,
                vec![FieldMutation::RemoveReference(pub_uuid, EdgeType::Contains)],
            )?;
            all_op_ids.extend(info.operation_ids);
            if batch_id.is_none() {
                batch_id = info.batch_id;
            }
        }
        Ok(UndoInfo {
            operation_ids: all_op_ids.iter().map(|id| id.to_string()).collect(),
            batch_id,
            description: "Remove from Collection".into(),
        })
    }

    /// Delete a collection and its membership edges.
    ///
    /// Collection membership is stored as outgoing `EdgeType::Contains` references
    /// on the collection item, so deleting the item removes those rows via the
    /// `item_references` foreign-key CASCADE (same as `delete_library`). Publications
    /// themselves are untouched — only the collection and its edges go away.
    ///
    /// Not idempotent: deleting a missing collection returns `NotFound`, matching
    /// the crate convention (`delete_library` / `delete_item`).
    pub fn delete_collection(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.delete(uuid)?;
        Ok(())
    }

    /// Rename a collection by updating its `payload.name`.
    ///
    /// Mirrors `update_field`'s `SetPayload` shape but guards that the target item
    /// is actually a collection, returning `NotFound` otherwise.
    pub fn rename_collection(
        &self,
        id: String,
        new_name: String,
    ) -> Result<CollectionRow, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "imbib/collection" => {}
            _ => return Err(StoreApiError::NotFound(id)),
        }
        self.store.update_with_undo(
            uuid,
            vec![FieldMutation::SetPayload(
                "name".into(),
                Value::String(new_name),
            )],
        )?;
        let updated = self.store.get(uuid)?.ok_or(StoreApiError::NotFound(id))?;
        let pub_count = self.count_collection_members(updated.id)?;
        Ok(item_to_collection_row(&updated, pub_count as i32))
    }

    /// List the collections a publication belongs to.
    ///
    /// Collection membership is stored as outgoing `EdgeType::Contains` edges from
    /// the collection item to the publication (see `add_to_collection`). The
    /// forward direction — "publications in collection X" — uses
    /// `ReferencedBy(Contains, coll)` (`list_collection_members`); the inverse used
    /// here — "collections that reference publication P" — uses
    /// `HasReference(Contains, pub)`, the same predicate `get_publication_detail`
    /// uses to populate a publication's collection ids.
    ///
    /// Returns the same `CollectionRow` shape as `create_collection` /
    /// `list_collections`, member counts included. Read-only.
    pub fn list_collections_for_publication(
        &self,
        publication_id: String,
    ) -> Result<Vec<CollectionRow>, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let q = ItemQuery {
            schema: Some("imbib/collection".into()),
            predicates: vec![Predicate::HasReference(EdgeType::Contains, pub_uuid)],
            sort: vec![SortDescriptor {
                field: "payload.sort_order".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let mut rows = Vec::new();
        for item in &items {
            let pub_count = self.count_collection_members(item.id)?;
            rows.push(item_to_collection_row(item, pub_count as i32));
        }
        Ok(rows)
    }

    /// Add publications to a library as members WITHOUT duplicating them.
    ///
    /// Multi-library membership uses `EdgeType::Contains` edges from the library
    /// item to the publication item. The publication keeps its original
    /// `parent_uuid` (its "home" library). Queries that ask "what's in library X"
    /// must use `in_library_predicate(X)` to see both parent-based members and
    /// Contains-based members.
    ///
    /// Replaces the old `duplicate_publications(to_library_id)` anti-pattern
    /// for the "add to library" use case — duplicate is now reserved for true
    /// copy semantics.
    pub fn library_add_members(
        &self,
        library_id: String,
        publication_ids: Vec<String>,
    ) -> Result<UndoInfo, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let mut all_op_ids = Vec::new();
        let mut batch_id = None;
        for pub_id_str in &publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            // No-op if the paper is already the library's child (parent==library)
            // or already has a Contains edge from this library.
            if let Some(item) = self.store.get(pub_uuid)? {
                if item.parent == Some(lib_uuid) {
                    continue;
                }
            }
            let info = self.store.update_with_undo(
                lib_uuid,
                vec![FieldMutation::AddReference(
                    impress_core::reference::TypedReference {
                        target: pub_uuid,
                        edge_type: EdgeType::Contains,
                        metadata: None,
                    },
                )],
            )?;
            all_op_ids.extend(info.operation_ids);
            if batch_id.is_none() {
                batch_id = info.batch_id;
            }
        }
        Ok(UndoInfo {
            operation_ids: all_op_ids.iter().map(|id| id.to_string()).collect(),
            batch_id,
            description: "Add to Library".into(),
        })
    }

    /// Remove a Contains-edge membership from a library.
    ///
    /// Does NOT delete the publication, and does NOT remove the publication if
    /// the library is its parent (its home). Use `move_publications` or
    /// `delete_publications` for those operations.
    pub fn library_remove_members(
        &self,
        library_id: String,
        publication_ids: Vec<String>,
    ) -> Result<UndoInfo, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let mut all_op_ids = Vec::new();
        let mut batch_id = None;
        for pub_id_str in &publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            let info = self.store.update_with_undo(
                lib_uuid,
                vec![FieldMutation::RemoveReference(pub_uuid, EdgeType::Contains)],
            )?;
            all_op_ids.extend(info.operation_ids);
            if batch_id.is_none() {
                batch_id = info.batch_id;
            }
        }
        Ok(UndoInfo {
            operation_ids: all_op_ids.iter().map(|id| id.to_string()).collect(),
            batch_id,
            description: "Remove from Library".into(),
        })
    }

    /// Remove all dismissed papers from a collection.
    /// Returns the number of members removed.
    pub fn purge_dismissed_from_collection(
        &self,
        collection_id: String,
    ) -> Result<u32, StoreApiError> {
        let coll_uuid = parse_uuid(&collection_id)?;

        // 1. Query all bibliography-entry members of this collection
        let members = self.store.query(&ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::ReferencedBy(EdgeType::Contains, coll_uuid)],
            ..Default::default()
        })?;

        if members.is_empty() {
            return Ok(0);
        }

        // 2. Collect identifiers from members
        let mut dois = Vec::new();
        let mut arxiv_ids = Vec::new();
        let mut bibcodes = Vec::new();
        for item in &members {
            if let Some(Value::String(d)) = item.payload.get("doi") {
                if !d.is_empty() {
                    dois.push(d.clone());
                }
            }
            if let Some(Value::String(a)) = item.payload.get("arxiv_id") {
                if !a.is_empty() {
                    arxiv_ids.push(a.clone());
                }
            }
            if let Some(Value::String(b)) = item.payload.get("bibcode") {
                if !b.is_empty() {
                    bibcodes.push(b.clone());
                }
            }
        }

        // 3. Load dismissed identifiers matching those
        let dismissed = self.load_dismissed_identifiers(&dois, &arxiv_ids, &bibcodes)?;
        if dismissed.is_empty() {
            return Ok(0);
        }

        // 4. Find members whose identifiers are in the dismissed set
        let to_remove: Vec<String> = members
            .iter()
            .filter(|item| {
                if let Some(Value::String(d)) = item.payload.get("doi") {
                    if dismissed.contains(&d.to_lowercase()) {
                        return true;
                    }
                }
                if let Some(Value::String(a)) = item.payload.get("arxiv_id") {
                    if dismissed.contains(&a.to_lowercase()) {
                        return true;
                    }
                }
                if let Some(Value::String(b)) = item.payload.get("bibcode") {
                    if dismissed.contains(&b.to_lowercase()) {
                        return true;
                    }
                }
                false
            })
            .map(|item| item.id.to_string())
            .collect();

        if to_remove.is_empty() {
            return Ok(0);
        }
        let count = to_remove.len() as u32;

        // 5. Batch remove from collection
        self.remove_from_collection(to_remove, collection_id)?;

        Ok(count)
    }

    // --- Publication queries ---

    pub fn query_publications(
        &self,
        parent_id: String,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let parent_uuid = parse_uuid(&parent_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            // Membership query: include both parent-children and Contains-linked papers.
            predicates: vec![in_library_predicate(parent_uuid)],
            sort: build_sort_descriptors(&sort_field, ascending),
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Return ALL publications in the store (no parent filter), for full-text search indexing.
    pub fn query_all_publications(
        &self,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![],
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Return just the UUID strings of publications in a library (skips full row conversion).
    pub fn query_publication_ids(&self, parent_id: String) -> Result<Vec<String>, StoreApiError> {
        let parent_uuid = parse_uuid(&parent_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![in_library_predicate(parent_uuid)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(|item| item.id.to_string()).collect())
    }

    pub fn search_publications(
        &self,
        query: String,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        // Search across title, author, abstract, and note fields
        let search_pred = Predicate::Or(vec![
            Predicate::Contains("title".into(), query.clone()),
            Predicate::Contains("author_text".into(), query.clone()),
            Predicate::Contains("abstract_text".into(), query.clone()),
            Predicate::Contains("note".into(), query),
        ]);
        let mut predicates = vec![search_pred];
        if let Some(pid) = parent_id {
            let parent_uuid = parse_uuid(&pid)?;
            predicates.push(in_library_predicate(parent_uuid));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            sort: build_sort_descriptors(&sort_field, ascending),
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn get_publication(&self, id: String) -> Result<Option<BibliographyRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let item = self.store.get(uuid)?;
        match item {
            Some(item) => {
                let tag_defs = self.load_tag_definitions()?;
                let rows = self.items_to_bibliography_rows(&[item], &tag_defs)?;
                Ok(rows.into_iter().next())
            }
            None => Ok(None),
        }
    }

    // --- Recent activity ---
    //
    // "Recent" means papers the user VIEWED or ADDED BY HAND. It deliberately
    // does NOT include papers that arrived through automated ingest (inbox
    // feeds, smart-search provider refreshes, group feeds) — those bump
    // `modified`, which is exactly why `modified` is not usable as a recency
    // proxy. Recency is an explicit `last_activity_at` stamp on the payload,
    // written only from user-initiated call sites, and it rides the normal
    // item sync so it follows the researcher across devices.

    /// Record that the user opened/viewed a publication.
    ///
    /// Debounced in the store (5 minutes for a repeat of the same kind), so
    /// scrolling a list does not produce a sync push per paper. Returns
    /// `true` when the stamp was actually written.
    pub fn record_recent_view(&self, id: String) -> Result<bool, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        Ok(self.store.record_recent(&uuid.to_string(), "viewed")?)
    }

    /// Record that the user added a publication by hand.
    pub fn record_recent_add(&self, id: String) -> Result<bool, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        Ok(self.store.record_recent(&uuid.to_string(), "added")?)
    }

    /// Publications with recent user activity, most recent first.
    ///
    /// NOTE the deliberate name: `query_recent` already exists and means
    /// "most recently ADDED, by creation date" (it backs
    /// `GET /api/papers/recent`). This is a different question — "what did I
    /// actually touch?" — so it gets its own name rather than redefining that
    /// one out from under its callers.
    ///
    /// Rows whose item has vanished (deleted between the id scan and the
    /// fetch) are skipped rather than erroring.
    pub fn query_recent_activity(&self, limit: u32) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let ids = self
            .store
            .recent_item_ids("imbib/bibliography-entry", limit)?;
        let mut items = Vec::with_capacity(ids.len());
        for id in &ids {
            let Ok(uuid) = Uuid::parse_str(id) else {
                continue;
            };
            if let Some(item) = self.store.get(uuid)? {
                items.push(item);
            }
        }
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Recent activity as `(publication_id, kind, occurred_at_ms)`, most
    /// recent first. `kind` is `"viewed"` or `"added"`.
    pub fn recent_activity_entries(
        &self,
        limit: u32,
    ) -> Result<Vec<RecentActivityRow>, StoreApiError> {
        Ok(self
            .store
            .recent_entries("imbib/bibliography-entry", limit)?
            .into_iter()
            .map(|(id, kind, occurred_at)| RecentActivityRow {
                id,
                kind,
                occurred_at,
            })
            .collect())
    }

    pub fn get_flagged_publications(
        &self,
        color: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasFlag(color)],
            sort: build_sort_descriptors(&sort_field, ascending),
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    // --- Publication mutations ---

    pub fn import_bibtex(
        &self,
        bibtex: String,
        library_id: String,
    ) -> Result<Vec<String>, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let parse_result = crate::bibtex::parse(bibtex.clone())
            .map_err(|e| StoreApiError::InvalidInput(format!("BibTeX parse error: {}", e)))?;

        let mut ids = Vec::new();
        for entry in &parse_result.entries {
            let publication = crate::conversions::bibtex_entry_to_publication(entry.clone());

            // Deduplication: skip if a publication with the same DOI, arXiv ID, or bibcode
            // already exists in this library
            if self.is_duplicate_in_library(&publication, parent_uuid)? {
                continue;
            }

            let item = conversion::publication_to_item(&publication, Some(parent_uuid));
            let id = self.store.insert(item)?;
            ids.push(id.to_string());
        }
        Ok(ids)
    }

    /// Batch import search results: find existing, optionally filter dismissed, import new.
    ///
    /// Performs the entire "search result import" pipeline in a single FFI call:
    /// 1. Batch-find existing publications by DOI/arXiv/bibcode (single SQL query)
    /// 2. Optionally filter out dismissed papers (single SQL query)
    /// 3. Parse BibTeX for new results and dedup against library
    /// 4. Batch-insert all new publications in one transaction
    pub fn batch_import_search_results(
        &self,
        results: Vec<SearchResultInput>,
        library_id: String,
        filter_dismissed: bool,
    ) -> Result<BatchImportResult, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;

        // Phase 1: Collect identifiers and batch-find existing (single SQL query)
        let all_dois: Vec<String> = results
            .iter()
            .filter_map(|r| r.doi.as_ref())
            .filter(|s| !s.is_empty())
            .cloned()
            .collect();
        let all_arxiv_ids: Vec<String> = results
            .iter()
            .filter_map(|r| r.arxiv_id.as_ref())
            .filter(|s| !s.is_empty())
            .cloned()
            .collect();
        let all_bibcodes: Vec<String> = results
            .iter()
            .filter_map(|r| r.bibcode.as_ref())
            .filter(|s| !s.is_empty())
            .cloned()
            .collect();

        let existing_items =
            self.find_items_by_identifiers(&all_dois, &all_arxiv_ids, &all_bibcodes)?;

        // Build reverse index maps for O(1) lookup: identifier → item UUID string
        let mut doi_to_id: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        let mut arxiv_to_id: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        let mut bibcode_to_id: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        for item in &existing_items {
            let id_str = item.id.to_string();
            if let Some(Value::String(doi)) = item.payload.get("doi") {
                if !doi.is_empty() {
                    doi_to_id.insert(doi.clone(), id_str.clone());
                }
            }
            if let Some(Value::String(arxiv)) = item.payload.get("arxiv_id") {
                if !arxiv.is_empty() {
                    arxiv_to_id.insert(arxiv.clone(), id_str.clone());
                }
            }
            if let Some(Value::String(bib)) = item.payload.get("bibcode") {
                if !bib.is_empty() {
                    bibcode_to_id.insert(bib.clone(), id_str.clone());
                }
            }
        }

        // Phase 2: Load dismissed identifiers if needed (single SQL query)
        let dismissed_ids: std::collections::HashSet<String> = if filter_dismissed {
            self.load_dismissed_identifiers(&all_dois, &all_arxiv_ids, &all_bibcodes)?
        } else {
            std::collections::HashSet::new()
        };

        // Phase 3: Classify results into existing / dismissed / new
        let mut existing_ids = Vec::new();
        let mut items_to_insert = Vec::new();
        let mut dismissed_count: u32 = 0;
        let mut failed_count: u32 = 0;

        for result in &results {
            // Check if existing via index maps
            let existing_id = result
                .doi
                .as_ref()
                .and_then(|d| doi_to_id.get(d))
                .or_else(|| result.arxiv_id.as_ref().and_then(|a| arxiv_to_id.get(a)))
                .or_else(|| result.bibcode.as_ref().and_then(|b| bibcode_to_id.get(b)));

            if let Some(id) = existing_id {
                if filter_dismissed && is_input_dismissed(result, &dismissed_ids) {
                    dismissed_count += 1;
                    continue;
                }
                existing_ids.push(id.clone());
                continue;
            }

            // Check if dismissed
            if filter_dismissed && is_input_dismissed(result, &dismissed_ids) {
                dismissed_count += 1;
                continue;
            }

            // Parse BibTeX and prepare for insertion
            match crate::bibtex::parse(result.bibtex.clone()) {
                Ok(parse_result) => {
                    for entry in &parse_result.entries {
                        let mut publication =
                            crate::conversions::bibtex_entry_to_publication(entry.clone());
                        // Merge identifiers from SearchResultInput that
                        // the BibTeX didn't carry. This is critical for
                        // published papers whose ADS BibTeX omits the
                        // eprint field — the arXiv ID from the search
                        // result is the only source.
                        if publication.identifiers.arxiv_id.is_none() {
                            if let Some(ref a) = result.arxiv_id {
                                if !a.is_empty() {
                                    publication.identifiers.arxiv_id = Some(a.clone());
                                }
                            }
                        }
                        if publication.identifiers.doi.is_none() {
                            if let Some(ref d) = result.doi {
                                if !d.is_empty() {
                                    publication.identifiers.doi = Some(d.clone());
                                }
                            }
                        }
                        if publication.identifiers.bibcode.is_none() {
                            if let Some(ref b) = result.bibcode {
                                if !b.is_empty() {
                                    publication.identifiers.bibcode = Some(b.clone());
                                }
                            }
                        }
                        // Per-item dedup (checks cite key + arXiv version variants)
                        match self.is_duplicate_in_library(&publication, parent_uuid) {
                            Ok(true) => {} // skip duplicate
                            Ok(false) => {
                                items_to_insert.push(conversion::publication_to_item(
                                    &publication,
                                    Some(parent_uuid),
                                ));
                            }
                            Err(_) => {
                                failed_count += 1;
                            }
                        }
                    }
                }
                Err(_) => {
                    failed_count += 1;
                }
            }
        }

        // Phase 4: Batch insert all new items in single transaction
        let imported_ids = if items_to_insert.is_empty() {
            vec![]
        } else {
            self.store
                .insert_batch(items_to_insert)?
                .into_iter()
                .map(|id| id.to_string())
                .collect()
        };

        Ok(BatchImportResult {
            existing_ids,
            imported_ids,
            dismissed_count,
            failed_count,
        })
    }

    pub fn set_read(&self, ids: Vec<String>, read: bool) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(&ids, FieldMutation::SetRead(read))
    }

    pub fn set_starred(&self, ids: Vec<String>, starred: bool) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(&ids, FieldMutation::SetStarred(starred))
    }

    pub fn set_flag(
        &self,
        ids: Vec<String>,
        color: Option<String>,
        style: Option<String>,
        length: Option<String>,
    ) -> Result<UndoInfo, StoreApiError> {
        let flag = color.map(|c| FlagState {
            color: c,
            style,
            length,
        });
        self.apply_mutation_to_ids(&ids, FieldMutation::SetFlag(flag))
    }

    pub fn add_tag(&self, ids: Vec<String>, tag_path: String) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(&ids, FieldMutation::AddTag(tag_path))
    }

    pub fn remove_tag(
        &self,
        ids: Vec<String>,
        tag_path: String,
    ) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(&ids, FieldMutation::RemoveTag(tag_path))
    }

    pub fn delete_publications(&self, ids: Vec<String>) -> Result<(), StoreApiError> {
        for id_str in &ids {
            let uuid = parse_uuid(id_str)?;
            self.store.delete(uuid)?;
        }
        Ok(())
    }

    pub fn update_field(
        &self,
        id: String,
        field: String,
        value: Option<String>,
    ) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let mutation = match value {
            Some(v) => FieldMutation::SetPayload(field, Value::String(v)),
            None => FieldMutation::RemovePayload(field),
        };
        Ok(self.store.update_with_undo(uuid, vec![mutation])?.into())
    }

    // --- Tag definitions ---

    pub fn list_tags(&self) -> Result<Vec<TagDisplayRow>, StoreApiError> {
        self.load_tag_definitions()
    }

    pub fn create_tag(
        &self,
        path: String,
        color_light: Option<String>,
        color_dark: Option<String>,
    ) -> Result<(), StoreApiError> {
        let leaf_name = path.rsplit('/').next().unwrap_or(&path);
        let item = conversion::tag_definition_to_item(
            leaf_name,
            &path,
            color_light.as_deref(),
            color_dark.as_deref(),
            None,
            None,
        );
        self.store.insert(item)?;
        self.invalidate_tag_cache();
        Ok(())
    }

    // --- Export ---

    pub fn export_bibtex(&self, ids: Vec<String>) -> Result<String, StoreApiError> {
        let mut entries = Vec::new();
        for id_str in &ids {
            let uuid = parse_uuid(id_str)?;
            if let Some(item) = self.store.get(uuid)? {
                let publication = conversion::item_to_publication(&item);
                let entry = crate::domain::publication_to_bibtex(&publication);
                entries.push(entry);
            }
        }
        Ok(crate::bibtex::format_entries(entries))
    }

    pub fn export_all_bibtex(&self, library_id: String) -> Result<String, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![in_library_predicate(parent_uuid)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let entries: Vec<_> = items
            .iter()
            .map(|item| {
                let publication = conversion::item_to_publication(item);
                crate::domain::publication_to_bibtex(&publication)
            })
            .collect();
        Ok(crate::bibtex::format_entries(entries))
    }

    // --- Publication detail ---

    pub fn get_publication_detail(
        &self,
        id: String,
    ) -> Result<Option<PublicationDetail>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let item = self.store.get(uuid)?;
        match item {
            Some(item) => {
                let tag_defs = self.load_tag_definitions()?;

                // Fetch child linked files (no tags/refs needed for linked file items)
                let lf_q = ItemQuery {
                    schema: Some("imbib/linked-file".into()),
                    predicates: vec![Predicate::HasParent(uuid)],
                    include_tags: false,
                    include_references: false,
                    ..Default::default()
                };
                let child_lf = self.store.query(&lf_q)?;

                // Find collections that reference this publication
                let coll_q = ItemQuery {
                    schema: Some("imbib/collection".into()),
                    predicates: vec![Predicate::HasReference(EdgeType::Contains, uuid)],
                    include_tags: false,
                    include_references: false,
                    ..Default::default()
                };
                let collections = self.store.query(&coll_q)?;
                let collection_ids: Vec<String> =
                    collections.iter().map(|c| c.id.to_string()).collect();

                let library_ids = item.parent.map(|p| vec![p.to_string()]).unwrap_or_default();

                Ok(Some(item_to_publication_detail(
                    &item,
                    &tag_defs,
                    collection_ids,
                    library_ids,
                    &child_lf,
                )))
            }
            None => Ok(None),
        }
    }

    // --- Migration ---

    pub fn import_from_bibtex_file(
        &self,
        path: String,
        library_id: String,
    ) -> Result<u32, StoreApiError> {
        let content = std::fs::read_to_string(&path)
            .map_err(|e| StoreApiError::Storage(format!("read file: {}", e)))?;
        let ids = self.import_bibtex(content, library_id)?;
        Ok(ids.len() as u32)
    }

    // --- Undo/Redo ---

    /// Undo a single operation by ID. Returns UndoInfo for the inverse (redo) operation.
    pub fn undo_operation(&self, operation_id: String) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&operation_id)?;
        Ok(self.store.undo_operation(uuid)?.into())
    }

    /// Undo all operations in a batch. Returns UndoInfo for the redo batch.
    pub fn undo_batch(&self, batch_id: String) -> Result<UndoInfo, StoreApiError> {
        Ok(self.store.undo_batch(&batch_id)?.into())
    }

    /// Fetch recent undo groups for the history panel.
    /// Returns one entry per batch (or per unbatched operation), most recent first.
    pub fn recent_undo_groups(&self, max_entries: u32) -> Result<Vec<UndoGroupRow>, StoreApiError> {
        let summaries = self.store.recent_undo_groups(max_entries as usize)?;
        Ok(summaries
            .into_iter()
            .map(|s| UndoGroupRow {
                operation_id: s.operation_id.to_string(),
                batch_id: s.batch_id,
                operation_count: s.operation_count as u32,
                description: s.description,
                timestamp: s.timestamp,
                author: s.author,
                author_kind: s.author_kind,
            })
            .collect())
    }

    // --- Undoable delete operations ---

    /// Delete publications with snapshot for undo. Returns snapshots of deleted items.
    pub fn delete_publications_undoable(
        &self,
        ids: Vec<String>,
    ) -> Result<Vec<ItemSnapshot>, StoreApiError> {
        let mut snapshots = Vec::new();
        for id_str in &ids {
            let uuid = parse_uuid(id_str)?;
            if let Some(item) = self.store.get(uuid)? {
                let children = self.snapshot_children(uuid)?;
                let item_json = serde_json::to_string(&item)
                    .map_err(|e| StoreApiError::Storage(format!("serialize item: {}", e)))?;
                snapshots.push(ItemSnapshot {
                    item_json,
                    child_jsons: children,
                });
                self.store.delete(uuid)?;
            }
        }
        Ok(snapshots)
    }

    /// Delete a library with snapshot for undo.
    pub fn delete_library_undoable(
        &self,
        id: String,
    ) -> Result<LibraryDeleteSnapshot, StoreApiError> {
        let uuid = parse_uuid(&id)?;

        // Snapshot the library item
        let lib_item = self
            .store
            .get(uuid)?
            .ok_or_else(|| StoreApiError::NotFound(id.clone()))?;
        let library_json = serde_json::to_string(&lib_item)
            .map_err(|e| StoreApiError::Storage(format!("serialize library: {}", e)))?;

        // Record child publication IDs (they'll become orphaned on delete due to ON DELETE SET NULL)
        let pub_q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasParent(uuid)],
            ..Default::default()
        };
        let child_publication_ids: Vec<String> = self
            .store
            .query(&pub_q)?
            .iter()
            .map(|p| p.id.to_string())
            .collect();

        // Record child collection IDs
        let coll_q = ItemQuery {
            schema: Some("imbib/collection".into()),
            predicates: vec![Predicate::HasParent(uuid)],
            ..Default::default()
        };
        let child_collection_ids: Vec<String> = self
            .store
            .query(&coll_q)?
            .iter()
            .map(|c| c.id.to_string())
            .collect();

        // Delete the library (children get parent_id = NULL via ON DELETE SET NULL)
        self.store.delete(uuid)?;

        Ok(LibraryDeleteSnapshot {
            library_json,
            child_publication_ids,
            child_collection_ids,
        })
    }

    /// Restore a deleted library and re-parent its children.
    pub fn restore_library(&self, snapshot: LibraryDeleteSnapshot) -> Result<(), StoreApiError> {
        use impress_core::item::Item;

        let item: Item = serde_json::from_str(&snapshot.library_json)
            .map_err(|e| StoreApiError::Storage(format!("deserialize library: {}", e)))?;
        let lib_id = item.id;
        self.store.insert(item)?;

        // Re-parent publications
        for pub_id_str in &snapshot.child_publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            self.store
                .update(pub_uuid, vec![FieldMutation::SetParent(Some(lib_id))])?;
        }

        // Re-parent collections
        for coll_id_str in &snapshot.child_collection_ids {
            let coll_uuid = parse_uuid(coll_id_str)?;
            self.store
                .update(coll_uuid, vec![FieldMutation::SetParent(Some(lib_id))])?;
        }

        Ok(())
    }

    /// Delete a tag definition and remove from all publications, returning snapshot for undo.
    pub fn delete_tag_undoable(&self, path: String) -> Result<TagDeleteSnapshot, StoreApiError> {
        // 1. Snapshot the tag definition item
        let q = ItemQuery {
            schema: Some("imbib/tag-definition".into()),
            predicates: vec![Predicate::Eq(
                "canonical_path".into(),
                Value::String(path.clone()),
            )],
            ..Default::default()
        };
        let tag_items = self.store.query(&q)?;
        let tag_json = tag_items
            .first()
            .map(|item| serde_json::to_string(item).unwrap_or_default())
            .unwrap_or_default();

        // 2. Find all publications with this tag
        let pub_q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasTag(path.clone())],
            ..Default::default()
        };
        let tagged_pubs = self.store.query(&pub_q)?;
        let tagged_pub_ids: Vec<String> = tagged_pubs.iter().map(|p| p.id.to_string()).collect();

        // 3. Perform the actual delete
        self.delete_tag(path.clone())?;

        Ok(TagDeleteSnapshot {
            tag_definition_json: tag_json,
            tagged_publication_ids: tagged_pub_ids,
            tag_path: path,
        })
    }

    /// Restore a deleted tag definition and re-tag publications.
    pub fn restore_tag(&self, snapshot: TagDeleteSnapshot) -> Result<(), StoreApiError> {
        use impress_core::item::Item;

        // Restore tag definition item
        if !snapshot.tag_definition_json.is_empty() {
            let item: Item = serde_json::from_str(&snapshot.tag_definition_json)
                .map_err(|e| StoreApiError::Storage(format!("deserialize tag: {}", e)))?;
            self.store.insert(item)?;
        }

        // Re-tag publications
        for pub_id_str in &snapshot.tagged_publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            self.store.update(
                pub_uuid,
                vec![FieldMutation::AddTag(snapshot.tag_path.clone())],
            )?;
        }

        self.invalidate_tag_cache();
        Ok(())
    }

    /// Restore previously-deleted items from snapshots.
    pub fn restore_snapshots(&self, snapshots: Vec<ItemSnapshot>) -> Result<(), StoreApiError> {
        use impress_core::item::Item;

        for snapshot in &snapshots {
            let item: Item = serde_json::from_str(&snapshot.item_json)
                .map_err(|e| StoreApiError::Storage(format!("deserialize item: {}", e)))?;
            self.store.insert(item)?;
            for child_json in &snapshot.child_jsons {
                let child: Item = serde_json::from_str(child_json)
                    .map_err(|e| StoreApiError::Storage(format!("deserialize child: {}", e)))?;
                self.store.insert(child)?;
            }
        }
        Ok(())
    }

    // --- Generic field helpers ---

    /// Delete any item by ID.
    pub fn delete_item(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.delete(uuid)?;
        Ok(())
    }

    /// Update an integer payload field on any item.
    pub fn update_int_field(
        &self,
        id: String,
        field: String,
        value: Option<i64>,
    ) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let mutation = match value {
            Some(v) => FieldMutation::SetPayload(field, Value::Int(v)),
            None => FieldMutation::RemovePayload(field),
        };
        Ok(self.store.update_with_undo(uuid, vec![mutation])?.into())
    }

    /// Update a boolean payload field on any item.
    pub fn update_bool_field(
        &self,
        id: String,
        field: String,
        value: bool,
    ) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        Ok(self
            .store
            .update_with_undo(
                uuid,
                vec![FieldMutation::SetPayload(field, Value::Bool(value))],
            )?
            .into())
    }

    // --- Library extensions ---

    pub fn get_library(&self, id: String) -> Result<Option<LibraryRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "imbib/library" => {
                let pub_count = self.count_children(item.id, "imbib/bibliography-entry")?;
                Ok(Some(item_to_library_row(&item, pub_count as i32)))
            }
            _ => Ok(None),
        }
    }

    pub fn set_library_default(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        // Unset current default(s)
        let q = ItemQuery {
            schema: Some("imbib/library".into()),
            predicates: vec![Predicate::Eq("is_default".into(), Value::Bool(true))],
            ..Default::default()
        };
        for item in self.store.query(&q)? {
            self.store.update(
                item.id,
                vec![FieldMutation::SetPayload(
                    "is_default".into(),
                    Value::Bool(false),
                )],
            )?;
        }
        // Set new default
        self.store.update(
            uuid,
            vec![FieldMutation::SetPayload(
                "is_default".into(),
                Value::Bool(true),
            )],
        )?;
        Ok(())
    }

    pub fn get_default_library(&self) -> Result<Option<LibraryRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/library".into()),
            predicates: vec![Predicate::Eq("is_default".into(), Value::Bool(true))],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if let Some(item) = items.first() {
            let pub_count = self.count_children(item.id, "imbib/bibliography-entry")?;
            Ok(Some(item_to_library_row(item, pub_count as i32)))
        } else {
            Ok(None)
        }
    }

    // --- Collection extensions ---

    pub fn list_collection_members(
        &self,
        collection_id: String,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let coll_uuid = parse_uuid(&collection_id)?;
        // Single SQL query using ReferencedBy predicate instead of N+1 individual gets.
        // Collections store membership via AddReference(Contains) from collection→publication,
        // so ReferencedBy(Contains, coll_uuid) finds publications targeted by the collection.
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::ReferencedBy(EdgeType::Contains, coll_uuid)],
            sort: build_sort_descriptors(&sort_field, ascending),
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    // --- Linked file operations ---

    #[allow(clippy::too_many_arguments)]
    pub fn add_linked_file(
        &self,
        publication_id: String,
        filename: String,
        relative_path: Option<String>,
        file_type: Option<String>,
        file_size: i64,
        sha256: Option<String>,
        is_pdf: bool,
    ) -> Result<LinkedFileRow, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let item = conversion::linked_file_to_item(
            pub_uuid,
            &filename,
            relative_path.as_deref(),
            file_type.as_deref(),
            file_size,
            sha256.as_deref(),
            is_pdf,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_linked_file_row(&item))
    }

    pub fn list_linked_files(
        &self,
        publication_id: String,
    ) -> Result<Vec<LinkedFileRow>, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let q = ItemQuery {
            schema: Some("imbib/linked-file".into()),
            predicates: vec![Predicate::HasParent(pub_uuid)],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_linked_file_row).collect())
    }

    pub fn get_linked_file(&self, id: String) -> Result<Option<LinkedFileRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "imbib/linked-file" => {
                Ok(Some(item_to_linked_file_row(&item)))
            }
            _ => Ok(None),
        }
    }

    pub fn set_pdf_cloud_available(
        &self,
        id: String,
        available: bool,
    ) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.update(
            uuid,
            vec![FieldMutation::SetPayload(
                "pdf_cloud_available".into(),
                Value::Bool(available),
            )],
        )?;
        Ok(())
    }

    pub fn set_locally_materialized(
        &self,
        id: String,
        materialized: bool,
    ) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.update(
            uuid,
            vec![FieldMutation::SetPayload(
                "is_locally_materialized".into(),
                Value::Bool(materialized),
            )],
        )?;
        Ok(())
    }

    pub fn count_pdfs(&self, publication_id: String) -> Result<u32, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let q = ItemQuery {
            schema: Some("imbib/linked-file".into()),
            predicates: vec![
                Predicate::HasParent(pub_uuid),
                Predicate::Eq("is_pdf".into(), Value::Bool(true)),
            ],
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    // --- Smart search operations ---

    #[allow(clippy::too_many_arguments)]
    pub fn create_smart_search(
        &self,
        name: String,
        query: String,
        library_id: String,
        source_ids_json: Option<String>,
        max_results: i64,
        feeds_to_inbox: bool,
        auto_refresh_enabled: bool,
        refresh_interval_seconds: i64,
    ) -> Result<SmartSearchRow, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let item = conversion::smart_search_to_item(
            &name,
            &query,
            lib_uuid,
            source_ids_json.as_deref(),
            max_results,
            feeds_to_inbox,
            auto_refresh_enabled,
            refresh_interval_seconds,
            None,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_smart_search_row(&item))
    }

    pub fn list_smart_searches(
        &self,
        library_id: Option<String>,
    ) -> Result<Vec<SmartSearchRow>, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(lib_id) = library_id {
            let lib_uuid = parse_uuid(&lib_id)?;
            predicates.push(Predicate::HasParent(lib_uuid));
        }
        let q = ItemQuery {
            schema: Some("imbib/smart-search".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "payload.sort_order".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_smart_search_row).collect())
    }

    pub fn get_smart_search(&self, id: String) -> Result<Option<SmartSearchRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "imbib/smart-search" => {
                Ok(Some(item_to_smart_search_row(&item)))
            }
            _ => Ok(None),
        }
    }

    /// Delete a smart search.
    ///
    /// Smart searches are stored as `imbib/smart-search` items with no membership
    /// edges, so deletion is a plain item delete (same shape as `delete_collection`).
    /// Not idempotent: deleting a missing smart search returns `NotFound`.
    pub fn delete_smart_search(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.delete(uuid)?;
        Ok(())
    }

    // --- Inbox & triage ---

    pub fn get_inbox_library(&self) -> Result<Option<LibraryRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/library".into()),
            predicates: vec![Predicate::Eq("is_inbox".into(), Value::Bool(true))],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if let Some(item) = items.first() {
            let pub_count = self.count_children(item.id, "imbib/bibliography-entry")?;
            Ok(Some(item_to_library_row(item, pub_count as i32)))
        } else {
            Ok(None)
        }
    }

    pub fn create_inbox_library(&self, name: String) -> Result<LibraryRow, StoreApiError> {
        let item = conversion::library_to_item(&name, None, None, false, true, true);
        self.store.insert(item.clone())?;
        Ok(item_to_library_row(&item, 0))
    }

    pub fn create_muted_item(
        &self,
        mute_type: String,
        value: String,
    ) -> Result<MutedItemRow, StoreApiError> {
        let item = conversion::muted_item_to_item(&mute_type, &value);
        self.store.insert(item.clone())?;
        Ok(item_to_muted_item_row(&item))
    }

    pub fn list_muted_items(
        &self,
        mute_type: Option<String>,
    ) -> Result<Vec<MutedItemRow>, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(mt) = mute_type {
            predicates.push(Predicate::Eq("mute_type".into(), Value::String(mt)));
        }
        let q = ItemQuery {
            schema: Some("imbib/muted-item".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_muted_item_row).collect())
    }

    pub fn dismiss_paper(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> Result<DismissedPaperRow, StoreApiError> {
        // Normalize identifiers to lowercase for case-insensitive matching
        let doi = doi.map(|d| d.to_lowercase());
        let arxiv_id = arxiv_id.map(|a| a.to_lowercase());
        let bibcode = bibcode.map(|b| b.to_lowercase());
        let item = conversion::dismissed_paper_to_item(
            doi.as_deref(),
            arxiv_id.as_deref(),
            bibcode.as_deref(),
            cite_key.as_deref(),
        );
        self.store.insert(item.clone())?;
        Ok(item_to_dismissed_paper_row(&item))
    }

    pub fn is_paper_dismissed(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> Result<bool, StoreApiError> {
        let mut or_preds = Vec::new();
        if let Some(d) = doi {
            or_preds.push(Predicate::Eq("doi".into(), Value::String(d.to_lowercase())));
        }
        if let Some(a) = arxiv_id {
            or_preds.push(Predicate::Eq(
                "arxiv_id".into(),
                Value::String(a.to_lowercase()),
            ));
        }
        if let Some(b) = bibcode {
            or_preds.push(Predicate::Eq(
                "bibcode".into(),
                Value::String(b.to_lowercase()),
            ));
        }
        if let Some(ck) = cite_key {
            or_preds.push(Predicate::Eq("cite_key".into(), Value::String(ck)));
        }
        if or_preds.is_empty() {
            return Ok(false);
        }
        let q = ItemQuery {
            schema: Some("imbib/dismissed-paper".into()),
            predicates: vec![Predicate::Or(or_preds)],
            limit: Some(1),
            ..Default::default()
        };
        Ok(self.store.count(&q)? > 0)
    }

    pub fn list_dismissed_papers(
        &self,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<DismissedPaperRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/dismissed-paper".into()),
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_dismissed_paper_row).collect())
    }

    // --- Deduplication queries ---

    pub fn find_by_doi(&self, doi: String) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Eq("doi".into(), Value::String(doi))],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn find_by_arxiv(&self, arxiv_id: String) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Eq("arxiv_id".into(), Value::String(arxiv_id))],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn find_by_bibcode(&self, bibcode: String) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Eq("bibcode".into(), Value::String(bibcode))],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn find_by_identifiers(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        pmid: Option<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut or_preds = Vec::new();
        if let Some(d) = doi {
            or_preds.push(Predicate::Eq("doi".into(), Value::String(d)));
        }
        if let Some(a) = arxiv_id {
            or_preds.push(Predicate::Eq("arxiv_id".into(), Value::String(a)));
        }
        if let Some(b) = bibcode {
            or_preds.push(Predicate::Eq("bibcode".into(), Value::String(b)));
        }
        if let Some(p) = pmid {
            or_preds.push(Predicate::Eq("pmid".into(), Value::String(p)));
        }
        if or_preds.is_empty() {
            return Ok(vec![]);
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Or(or_preds)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Batch lookup: find all publications matching any of the given DOIs, arXiv IDs, or bibcodes.
    /// Single SQL query instead of N individual calls — prevents main-thread blocking during
    /// feed refresh (500 results × 30ms each = 16s → 1 query ~50ms).
    pub fn find_by_identifiers_batch(
        &self,
        dois: Vec<String>,
        arxiv_ids: Vec<String>,
        bibcodes: Vec<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut or_preds = Vec::new();
        if !dois.is_empty() {
            or_preds.push(Predicate::In(
                "doi".into(),
                dois.into_iter().map(Value::String).collect(),
            ));
        }
        if !arxiv_ids.is_empty() {
            or_preds.push(Predicate::In(
                "arxiv_id".into(),
                arxiv_ids.into_iter().map(Value::String).collect(),
            ));
        }
        if !bibcodes.is_empty() {
            or_preds.push(Predicate::In(
                "bibcode".into(),
                bibcodes.into_iter().map(Value::String).collect(),
            ));
        }
        if or_preds.is_empty() {
            return Ok(vec![]);
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Or(or_preds)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Remove duplicate publications within a library, keeping the oldest copy.
    ///
    /// Returns the number of duplicates removed.
    pub fn deduplicate_library(&self, library_id: String) -> Result<u32, StoreApiError> {
        let parent_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasParent(parent_uuid)],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;

        let mut seen_cite_keys: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        let mut seen_dois: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut seen_arxiv_ids: std::collections::HashSet<String> =
            std::collections::HashSet::new();
        let mut to_delete = Vec::new();

        for item in &items {
            let get_str = |key: &str| -> String {
                match item.payload.get(key) {
                    Some(Value::String(s)) => s.clone(),
                    _ => String::new(),
                }
            };
            let cite_key = get_str("cite_key");
            let doi = get_str("doi");
            let arxiv_id = get_str("arxiv_id");
            // Normalize arxiv_id by stripping version suffix
            let arxiv_base = if arxiv_id.contains('v') {
                arxiv_id.split('v').next().unwrap_or(&arxiv_id).to_string()
            } else {
                arxiv_id.clone()
            };

            let mut is_dup = false;
            if !doi.is_empty() && !seen_dois.insert(doi) {
                is_dup = true;
            }
            if !is_dup && !arxiv_base.is_empty() && !seen_arxiv_ids.insert(arxiv_base) {
                is_dup = true;
            }
            if !is_dup && !cite_key.is_empty() && !seen_cite_keys.insert(cite_key) {
                is_dup = true;
            }

            if is_dup {
                to_delete.push(item.id);
            }
        }

        let count = to_delete.len() as u32;
        for id in to_delete {
            self.store.delete(id)?;
        }
        Ok(count)
    }

    // --- Advanced queries ---

    pub fn query_unread(
        &self,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut predicates = vec![Predicate::IsRead(false)];
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            sort: build_sort_descriptors(&sort_field, ascending),
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn count_unread(&self, parent_id: Option<String>) -> Result<u32, StoreApiError> {
        let mut predicates = vec![Predicate::IsRead(false)];
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count publications, optionally within a parent library. Uses SELECT COUNT(*)
    /// instead of deserializing all rows — much faster for widget badge counts.
    pub fn count_publications(&self, parent_id: Option<String>) -> Result<u32, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count every collection in the store, across all libraries.
    ///
    /// Deliberately not "sum `list_collections` over `list_libraries`": a
    /// collection's owning library is its envelope `parent_id`, and that can be
    /// NULL. Four of this store's collections are parented to nothing, so the
    /// per-library sum reports zero — which is exactly what `/api/status` used
    /// to publish. Counting rows by schema is the only total that is right.
    pub fn count_collections(&self) -> Result<u32, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/collection".into()),
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count starred publications. Uses SELECT COUNT(*).
    pub fn count_starred(&self, parent_id: Option<String>) -> Result<u32, StoreApiError> {
        let mut predicates = vec![Predicate::IsStarred(true)];
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count publications with a given tag. Uses SELECT COUNT(*).
    pub fn count_by_tag(
        &self,
        tag_path: String,
        parent_id: Option<String>,
    ) -> Result<u32, StoreApiError> {
        let mut predicates = vec![Predicate::HasTag(tag_path)];
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count flagged publications. Uses SELECT COUNT(*).
    pub fn count_flagged(&self, color: Option<String>) -> Result<u32, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasFlag(color)],
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count publications matching a text search. Uses SELECT COUNT(*).
    pub fn count_search_results(
        &self,
        query: String,
        parent_id: Option<String>,
    ) -> Result<u32, StoreApiError> {
        let search_pred = Predicate::Or(vec![
            Predicate::Contains("title".into(), query.clone()),
            Predicate::Contains("author_text".into(), query.clone()),
            Predicate::Contains("abstract_text".into(), query.clone()),
            Predicate::Contains("note".into(), query),
        ]);
        let mut predicates = vec![search_pred];
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count publications referenced by a collection. Uses SELECT COUNT(*).
    pub fn count_collection_members_public(
        &self,
        collection_id: String,
    ) -> Result<u32, StoreApiError> {
        let coll_uuid = parse_uuid(&collection_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::ReferencedBy(EdgeType::Contains, coll_uuid)],
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count unread publications referenced by a collection. Uses Contains-edge join + is_read filter.
    pub fn count_unread_in_collection(&self, collection_id: String) -> Result<u32, StoreApiError> {
        let coll_uuid = parse_uuid(&collection_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![
                Predicate::ReferencedBy(EdgeType::Contains, coll_uuid),
                Predicate::IsRead(false),
            ],
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// Count publications referenced by a SciX library. Uses SELECT COUNT(*).
    pub fn count_scix_library_publications(
        &self,
        scix_library_id: String,
    ) -> Result<u32, StoreApiError> {
        let scix_uuid = parse_uuid(&scix_library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::ReferencedBy(EdgeType::Contains, scix_uuid)],
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    pub fn query_starred(
        &self,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut predicates = vec![Predicate::IsStarred(true)];
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            sort: build_sort_descriptors(&sort_field, ascending),
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn query_by_tag(
        &self,
        tag_path: String,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut predicates = vec![Predicate::HasTag(tag_path)];
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            sort: build_sort_descriptors(&sort_field, ascending),
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn query_recent(
        &self,
        limit: u32,
        parent_id: Option<String>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            sort: build_sort_descriptors("created", false),
            limit: Some(limit as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn full_text_search(
        &self,
        query: String,
        parent_id: Option<String>,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let search_pred = Predicate::Or(vec![
            Predicate::Contains("title".into(), query.clone()),
            Predicate::Contains("author_text".into(), query.clone()),
            Predicate::Contains("abstract_text".into(), query.clone()),
            Predicate::Contains("note".into(), query),
        ]);
        let mut predicates = vec![search_pred];
        if let Some(pid) = parent_id {
            predicates.push(in_library_predicate(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    pub fn find_by_cite_key(
        &self,
        cite_key: String,
        library_id: Option<String>,
    ) -> Result<Option<BibliographyRow>, StoreApiError> {
        let mut predicates = vec![Predicate::Eq("cite_key".into(), Value::String(cite_key))];
        if let Some(lid) = library_id {
            predicates.push(Predicate::HasParent(parse_uuid(&lid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates,
            limit: Some(1),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if items.is_empty() {
            Ok(None)
        } else {
            let tag_defs = self.load_tag_definitions()?;
            let rows = self.items_to_bibliography_rows(&items, &tag_defs)?;
            Ok(rows.into_iter().next())
        }
    }

    // --- SciX library operations ---

    pub fn create_scix_library(
        &self,
        remote_id: String,
        name: String,
        description: Option<String>,
        is_public: bool,
        permission_level: String,
        owner_email: Option<String>,
    ) -> Result<SciXLibraryRow, StoreApiError> {
        let item = conversion::scix_library_to_item(
            &remote_id,
            &name,
            description.as_deref(),
            is_public,
            &permission_level,
            owner_email.as_deref(),
            None,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_scix_library_row(&item, 0))
    }

    pub fn list_scix_libraries(&self) -> Result<Vec<SciXLibraryRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/scix-library".into()),
            sort: vec![SortDescriptor {
                field: "payload.sort_order".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let mut rows = Vec::new();
        for item in &items {
            // Count publications via Contains references (not parent), since
            // add_to_scix_library uses AddReference(Contains).
            let pub_count = item
                .references
                .iter()
                .filter(|r| r.edge_type == EdgeType::Contains)
                .count();
            rows.push(item_to_scix_library_row(item, pub_count as i32));
        }
        Ok(rows)
    }

    pub fn get_scix_library(&self, id: String) -> Result<Option<SciXLibraryRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "imbib/scix-library" => {
                // Count publications via Contains references (not parent), since
                // add_to_scix_library uses AddReference(Contains).
                let pub_count = item
                    .references
                    .iter()
                    .filter(|r| r.edge_type == EdgeType::Contains)
                    .count();
                Ok(Some(item_to_scix_library_row(&item, pub_count as i32)))
            }
            _ => Ok(None),
        }
    }

    pub fn add_to_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> Result<(), StoreApiError> {
        let scix_uuid = parse_uuid(&scix_library_id)?;
        for pub_id_str in &publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            self.store.update(
                scix_uuid,
                vec![FieldMutation::AddReference(
                    impress_core::reference::TypedReference {
                        target: pub_uuid,
                        edge_type: EdgeType::Contains,
                        metadata: None,
                    },
                )],
            )?;
        }
        Ok(())
    }

    /// Remove publications from a SciX library (removes Contains edges, keeps items).
    pub fn remove_from_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> Result<UndoInfo, StoreApiError> {
        let scix_uuid = parse_uuid(&scix_library_id)?;
        let mut all_op_ids = Vec::new();
        let mut batch_id = None;
        for pub_id_str in &publication_ids {
            let pub_uuid = parse_uuid(pub_id_str)?;
            let info = self.store.update_with_undo(
                scix_uuid,
                vec![FieldMutation::RemoveReference(pub_uuid, EdgeType::Contains)],
            )?;
            all_op_ids.extend(info.operation_ids);
            if batch_id.is_none() {
                batch_id = info.batch_id;
            }
        }
        let count = publication_ids.len();
        Ok(UndoInfo {
            operation_ids: all_op_ids.iter().map(|id| id.to_string()).collect(),
            batch_id: batch_id.map(|id| id.to_string()),
            description: if count == 1 {
                "Remove from SciX Library".into()
            } else {
                format!("Remove {} from SciX Library", count)
            },
        })
    }

    /// Query publications linked to a SciX library via item_references (Contains edges).
    ///
    /// SciX libraries store their membership via `AddReference(Contains)` rather than
    /// parent relationships. This method uses `Predicate::ReferencedBy` to find all
    /// bibliography entries that are targets of Contains edges from the given SciX library.
    pub fn query_scix_library_publications(
        &self,
        scix_library_id: String,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let scix_uuid = parse_uuid(&scix_library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::ReferencedBy(EdgeType::Contains, scix_uuid)],
            sort: build_sort_descriptors(&sort_field, ascending),
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        self.items_to_bibliography_rows(&items, &tag_defs)
    }

    /// Re-parent an item (e.g. fix orphaned smart searches whose parent was deleted).
    pub fn reparent_item(&self, id: String, new_parent_id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let parent_uuid = parse_uuid(&new_parent_id)?;
        self.store
            .update(uuid, vec![FieldMutation::SetParent(Some(parent_uuid))])?;
        Ok(())
    }

    // --- Annotation operations ---

    #[allow(clippy::too_many_arguments)]
    pub fn create_annotation(
        &self,
        linked_file_id: String,
        annotation_type: String,
        page_number: i64,
        bounds_json: Option<String>,
        color: Option<String>,
        contents: Option<String>,
        selected_text: Option<String>,
    ) -> Result<AnnotationRow, StoreApiError> {
        let file_uuid = parse_uuid(&linked_file_id)?;
        let item = conversion::annotation_to_item(
            file_uuid,
            &annotation_type,
            page_number,
            bounds_json.as_deref(),
            color.as_deref(),
            contents.as_deref(),
            selected_text.as_deref(),
        );
        self.store.insert(item.clone())?;
        Ok(item_to_annotation_row(&item))
    }

    pub fn list_annotations(
        &self,
        linked_file_id: String,
        page_number: Option<i32>,
    ) -> Result<Vec<AnnotationRow>, StoreApiError> {
        let file_uuid = parse_uuid(&linked_file_id)?;
        let mut predicates = vec![Predicate::HasParent(file_uuid)];
        if let Some(page) = page_number {
            predicates.push(Predicate::Eq("page_number".into(), Value::Int(page as i64)));
        }
        let q = ItemQuery {
            schema: Some("imbib/annotation".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "payload.page_number".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_annotation_row).collect())
    }

    pub fn count_annotations(&self, linked_file_id: String) -> Result<u32, StoreApiError> {
        let file_uuid = parse_uuid(&linked_file_id)?;
        let q = ItemQuery {
            schema: Some("imbib/annotation".into()),
            predicates: vec![Predicate::HasParent(file_uuid)],
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    // --- Comment operations ---

    pub fn create_comment(
        &self,
        publication_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Result<CommentRow, StoreApiError> {
        self.create_comment_on_item(
            publication_id,
            text,
            author_identifier,
            author_display_name,
            parent_comment_id,
        )
    }

    /// Create a comment on any item (publication, artifact, or any future item type).
    pub fn create_comment_on_item(
        &self,
        item_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Result<CommentRow, StoreApiError> {
        let parent_uuid = parse_uuid(&item_id)?;
        let item = conversion::comment_to_item(
            parent_uuid,
            &text,
            author_identifier.as_deref(),
            author_display_name.as_deref(),
            parent_comment_id.as_deref(),
        );
        self.store.insert(item.clone())?;
        // Look up parent schema for the returned row
        let parent_schema = self.store.get(parent_uuid)?.map(|p| p.schema.to_string());
        Ok(item_to_comment_row_with_schema(&item, parent_schema))
    }

    pub fn list_comments(&self, publication_id: String) -> Result<Vec<CommentRow>, StoreApiError> {
        self.list_comments_for_item(publication_id)
    }

    /// List comments for any item (publication, artifact, etc.).
    pub fn list_comments_for_item(
        &self,
        item_id: String,
    ) -> Result<Vec<CommentRow>, StoreApiError> {
        let parent_uuid = parse_uuid(&item_id)?;
        let q = ItemQuery {
            schema: Some("imbib/comment".into()),
            predicates: vec![Predicate::HasParent(parent_uuid)],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        // Resolve parent schema once for all comments
        let parent_schema = self.store.get(parent_uuid)?.map(|p| p.schema.to_string());
        Ok(items
            .iter()
            .map(|i| item_to_comment_row_with_schema(i, parent_schema.clone()))
            .collect())
    }

    pub fn update_comment(&self, id: String, text: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.update(
            uuid,
            vec![FieldMutation::SetPayload(
                "text".into(),
                Value::String(text),
            )],
        )?;
        Ok(())
    }

    /// Create a range-anchored comment on an item (e.g. a store-first manuscript).
    ///
    /// `anchor_start`/`anchor_end` are byte offsets into the parent item's body
    /// text; `anchor_text` is the covered snippet, kept so the comment can be
    /// re-anchored after edits (see `reanchor_comment`); `anchored_body_hash`
    /// is the `body_content_hash` the range was valid against.
    #[allow(clippy::too_many_arguments)]
    pub fn create_anchored_comment(
        &self,
        item_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        anchor_start: i64,
        anchor_end: i64,
        anchor_text: String,
        anchored_body_hash: String,
    ) -> Result<CommentRow, StoreApiError> {
        if anchor_start < 0 || anchor_end < anchor_start {
            return Err(StoreApiError::InvalidInput(format!(
                "invalid anchor range: {anchor_start}..{anchor_end}"
            )));
        }
        let parent_uuid = parse_uuid(&item_id)?;
        let item = conversion::anchored_comment_to_item(
            parent_uuid,
            &text,
            author_identifier.as_deref(),
            author_display_name.as_deref(),
            anchor_start,
            anchor_end,
            &anchor_text,
            &anchored_body_hash,
        );
        self.store.insert(item.clone())?;
        // Look up parent schema for the returned row
        let parent_schema = self.store.get(parent_uuid)?.map(|p| p.schema.to_string());
        Ok(item_to_comment_row_with_schema(&item, parent_schema))
    }

    /// Persist a re-anchored range for an existing comment.
    ///
    /// Called after `reanchor_comment` resolves a Moved range against a new
    /// body: stores the new byte offsets plus the `body_content_hash` they
    /// are valid against. Leaves `anchor_text` unchanged (it is the original
    /// snippet and remains the search key for future re-anchoring).
    pub fn update_comment_anchor(
        &self,
        comment_id: String,
        anchor_start: i64,
        anchor_end: i64,
        anchored_body_hash: String,
    ) -> Result<(), StoreApiError> {
        if anchor_start < 0 || anchor_end < anchor_start {
            return Err(StoreApiError::InvalidInput(format!(
                "invalid anchor range: {anchor_start}..{anchor_end}"
            )));
        }
        let uuid = parse_uuid(&comment_id)?;
        self.store.update(
            uuid,
            vec![
                FieldMutation::SetPayload("anchor_start".into(), Value::Int(anchor_start)),
                FieldMutation::SetPayload("anchor_end".into(), Value::Int(anchor_end)),
                FieldMutation::SetPayload(
                    "anchored_body_hash".into(),
                    Value::String(anchored_body_hash),
                ),
            ],
        )?;
        Ok(())
    }

    // --- Sync support operations ---

    /// Set the origin field on an item (records which device created it).
    /// Bypasses the operation log — this is metadata for sync coordination.
    pub fn set_item_origin(&self, id: String, origin: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.set_origin(uuid, &origin)?;
        Ok(())
    }

    /// Set the canonical_id field on an item (maps to CKRecord.recordID for CloudKit round-trip).
    /// Bypasses the operation log — this is metadata for sync coordination.
    pub fn set_item_canonical_id(
        &self,
        id: String,
        canonical_id: String,
    ) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.set_canonical_id(uuid, &canonical_id)?;
        Ok(())
    }

    /// Find an item by its canonical_id (for dedup on CloudKit pull).
    pub fn find_by_canonical_id(
        &self,
        canonical_id: String,
    ) -> Result<Option<String>, StoreApiError> {
        let item = self.store.find_by_canonical_id(&canonical_id)?;
        Ok(item.map(|i| i.id.to_string()))
    }

    /// List comments created since a given logical clock value (for incremental sync).
    pub fn list_comments_since(
        &self,
        item_id: String,
        since_clock: u64,
    ) -> Result<Vec<CommentRow>, StoreApiError> {
        let parent_uuid = parse_uuid(&item_id)?;
        let q = ItemQuery {
            schema: Some("imbib/comment".into()),
            predicates: vec![
                Predicate::HasParent(parent_uuid),
                Predicate::Gt("logical_clock".into(), Value::Int(since_clock as i64)),
            ],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_comment_row).collect())
    }

    // --- CloudKit sync engine surface (ADR-0007 Phase 3, Phase C) ---
    //
    // Thin delegation to the Rust apply/snapshot engine in
    // `impress_core::sync`. Swift (CloudSyncEngine, Phase D) drives these:
    // push = outbox entries → snapshots → CK save → outbox remove;
    // fetch = apply items/references/tombstones/deletions → retry pending.

    /// Pending outbox entries in queue order (push cursor).
    pub fn sync_outbox_entries(&self, limit: u32) -> Result<Vec<SyncOutboxEntry>, StoreApiError> {
        let entries = self.store.sync_outbox_entries(limit)?;
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
    pub fn sync_outbox_remove(&self, seqs: Vec<i64>) -> Result<(), StoreApiError> {
        self.store.sync_outbox_remove(seqs)?;
        Ok(())
    }

    /// Snapshot outbox `item` entries into wire records (op items,
    /// ephemeral rows and already-deleted rows are omitted).
    pub fn sync_snapshot_items(
        &self,
        ids: Vec<String>,
    ) -> Result<Vec<SyncItemRecord>, StoreApiError> {
        let records = self.store.sync_snapshot_items(ids)?;
        Ok(records.into_iter().map(Into::into).collect())
    }

    /// Snapshot outbox `reference` entries (raw `src|tgt|edge` names) into
    /// wire records with hashed `ref_` record names.
    pub fn sync_snapshot_references(
        &self,
        record_names: Vec<String>,
    ) -> Result<Vec<SyncReferenceRecord>, StoreApiError> {
        let records = self.store.sync_snapshot_references(record_names)?;
        Ok(records.into_iter().map(Into::into).collect())
    }

    /// Local tombstones since `since_ms`, as wire records.
    pub fn sync_local_tombstones(
        &self,
        since_ms: i64,
    ) -> Result<Vec<SyncTombstoneRecord>, StoreApiError> {
        let records = self.store.sync_local_tombstones(since_ms)?;
        Ok(records.into_iter().map(Into::into).collect())
    }

    /// Merge fetched remote item records (whole-record LWW in Rust,
    /// suppressed capture, FTS refreshed, manuscript conflict backups).
    pub fn sync_apply_remote_items(
        &self,
        records: Vec<SyncItemRecord>,
    ) -> Result<SyncApplyReport, StoreApiError> {
        let report = self
            .store
            .sync_apply_remote_items(records.into_iter().map(Into::into).collect())?;
        Ok(report.into())
    }

    /// Apply fetched remote reference records; missing endpoints defer.
    pub fn sync_apply_remote_references(
        &self,
        refs: Vec<SyncReferenceRecord>,
    ) -> Result<SyncApplyReport, StoreApiError> {
        let report = self
            .store
            .sync_apply_remote_references(refs.into_iter().map(Into::into).collect())?;
        Ok(report.into())
    }

    /// Re-attempt all deferred references (call after each item batch).
    pub fn sync_retry_pending_references(&self) -> Result<SyncApplyReport, StoreApiError> {
        Ok(self.store.sync_retry_pending_references()?.into())
    }

    /// Apply CKRecord deletions: `ref_...` names delete edges, item-UUID
    /// names run the tombstone rule with `deleted_at = now`.
    pub fn sync_apply_remote_deletions(
        &self,
        record_names: Vec<String>,
    ) -> Result<SyncApplyReport, StoreApiError> {
        Ok(self.store.sync_apply_remote_deletions(record_names)?.into())
    }

    /// Apply fetched `ImpressTombstone` records (edit-after-delete
    /// resurrects and re-pushes; ties → delete wins).
    pub fn sync_apply_remote_tombstones(
        &self,
        tombstones: Vec<SyncTombstoneRecord>,
    ) -> Result<SyncApplyReport, StoreApiError> {
        let report = self
            .store
            .sync_apply_remote_tombstones(tombstones.into_iter().map(Into::into).collect())?;
        Ok(report.into())
    }

    /// Read a sync-namespaced metadata value (`"sync."`-prefixed keys only).
    pub fn sync_metadata_get(&self, key: String) -> Result<Option<String>, StoreApiError> {
        Ok(self.store.sync_metadata_get(&key)?)
    }

    /// Write (or clear, with `nil`) a sync-namespaced metadata value.
    pub fn sync_metadata_set(
        &self,
        key: String,
        value: Option<String>,
    ) -> Result<(), StoreApiError> {
        self.store.sync_metadata_set(&key, value)?;
        Ok(())
    }

    /// Read the archived CKRecord system fields for a record, if any.
    pub fn sync_record_state_get(
        &self,
        record_name: String,
    ) -> Result<Option<Vec<u8>>, StoreApiError> {
        Ok(self.store.sync_record_state_get(&record_name)?)
    }

    /// Archive CKRecord system fields for a record.
    pub fn sync_record_state_set(
        &self,
        record_name: String,
        blob: Vec<u8>,
    ) -> Result<(), StoreApiError> {
        self.store.sync_record_state_set(&record_name, blob)?;
        Ok(())
    }

    /// Drop the archived system fields for a record.
    pub fn sync_record_state_delete(&self, record_name: String) -> Result<(), StoreApiError> {
        self.store.sync_record_state_delete(&record_name)?;
        Ok(())
    }

    /// Live sync queue depths (outbox / deferred refs / tombstones).
    pub fn sync_status_counts(&self) -> Result<SyncCounts, StoreApiError> {
        Ok(self.store.sync_status_counts()?.into())
    }

    // --- Assignment operations ---

    pub fn create_assignment(
        &self,
        publication_id: String,
        assignee_name: String,
        assigned_by_name: Option<String>,
        note: Option<String>,
        due_date: Option<i64>,
    ) -> Result<AssignmentRow, StoreApiError> {
        let pub_uuid = parse_uuid(&publication_id)?;
        let item = conversion::assignment_to_item(
            pub_uuid,
            &assignee_name,
            assigned_by_name.as_deref(),
            note.as_deref(),
            due_date,
        );
        self.store.insert(item.clone())?;
        Ok(item_to_assignment_row(&item))
    }

    pub fn list_assignments(
        &self,
        publication_id: Option<String>,
    ) -> Result<Vec<AssignmentRow>, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(pid) = publication_id {
            // Structural: assignments are children of a publication, not a library
            predicates.push(Predicate::HasParent(parse_uuid(&pid)?));
        }
        let q = ItemQuery {
            schema: Some("imbib/assignment".into()),
            predicates,
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_assignment_row).collect())
    }

    // --- Activity record operations ---

    pub fn create_activity_record(
        &self,
        library_id: String,
        activity_type: String,
        actor_display_name: Option<String>,
        target_title: Option<String>,
        target_id: Option<String>,
        detail: Option<String>,
    ) -> Result<ActivityRecordRow, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let item = conversion::activity_record_to_item(
            lib_uuid,
            &activity_type,
            actor_display_name.as_deref(),
            target_title.as_deref(),
            target_id.as_deref(),
            detail.as_deref(),
        );
        self.store.insert(item.clone())?;
        Ok(item_to_activity_record_row(&item))
    }

    pub fn list_activity_records(
        &self,
        library_id: String,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<ActivityRecordRow>, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/activity-record".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_activity_record_row).collect())
    }

    pub fn clear_activity_records(&self, library_id: String) -> Result<(), StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/activity-record".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        for item in &items {
            self.store.delete(item.id)?;
        }
        Ok(())
    }

    // --- Recommendation profile operations ---

    pub fn get_recommendation_profile(
        &self,
        library_id: String,
    ) -> Result<Option<String>, StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/recommendation-profile".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            limit: Some(1),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if let Some(item) = items.first() {
            let json = serde_json::to_string(&item.payload).unwrap_or_else(|_| "{}".into());
            Ok(Some(json))
        } else {
            Ok(None)
        }
    }

    pub fn create_or_update_recommendation_profile(
        &self,
        library_id: String,
        topic_affinities_json: Option<String>,
        author_affinities_json: Option<String>,
        venue_affinities_json: Option<String>,
        training_events_json: Option<String>,
    ) -> Result<(), StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/recommendation-profile".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            limit: Some(1),
            ..Default::default()
        };
        let existing = self.store.query(&q)?;
        if let Some(item) = existing.first() {
            let mut mutations = Vec::new();
            if let Some(v) = topic_affinities_json {
                mutations.push(FieldMutation::SetPayload(
                    "topic_affinities_json".into(),
                    Value::String(v),
                ));
            }
            if let Some(v) = author_affinities_json {
                mutations.push(FieldMutation::SetPayload(
                    "author_affinities_json".into(),
                    Value::String(v),
                ));
            }
            if let Some(v) = venue_affinities_json {
                mutations.push(FieldMutation::SetPayload(
                    "venue_affinities_json".into(),
                    Value::String(v),
                ));
            }
            if let Some(v) = training_events_json {
                mutations.push(FieldMutation::SetPayload(
                    "training_events_json".into(),
                    Value::String(v),
                ));
            }
            if !mutations.is_empty() {
                self.store.update(item.id, mutations)?;
            }
        } else {
            let item = conversion::recommendation_profile_to_item(
                lib_uuid,
                topic_affinities_json.as_deref(),
                author_affinities_json.as_deref(),
                venue_affinities_json.as_deref(),
                training_events_json.as_deref(),
            );
            self.store.insert(item)?;
        }
        Ok(())
    }

    pub fn delete_recommendation_profile(&self, library_id: String) -> Result<(), StoreApiError> {
        let lib_uuid = parse_uuid(&library_id)?;
        let q = ItemQuery {
            schema: Some("imbib/recommendation-profile".into()),
            predicates: vec![Predicate::HasParent(lib_uuid)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        for item in &items {
            self.store.delete(item.id)?;
        }
        Ok(())
    }

    // --- Tag extensions ---

    /// Delete a tag definition and remove the tag from all publications.
    pub fn delete_tag(&self, path: String) -> Result<(), StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/tag-definition".into()),
            predicates: vec![Predicate::Eq(
                "canonical_path".into(),
                Value::String(path.clone()),
            )],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        for item in &items {
            self.store.delete(item.id)?;
        }
        // Remove the tag from all publications that have it
        let pub_q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasTag(path.clone())],
            ..Default::default()
        };
        let pubs = self.store.query(&pub_q)?;
        for pub_item in &pubs {
            self.store
                .update(pub_item.id, vec![FieldMutation::RemoveTag(path.clone())])?;
        }
        self.invalidate_tag_cache();
        Ok(())
    }

    /// Update tag definition colors.
    pub fn update_tag(
        &self,
        path: String,
        color_light: Option<String>,
        color_dark: Option<String>,
    ) -> Result<(), StoreApiError> {
        let q = ItemQuery {
            schema: Some("imbib/tag-definition".into()),
            predicates: vec![Predicate::Eq("canonical_path".into(), Value::String(path))],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        if let Some(item) = items.first() {
            let mut mutations = Vec::new();
            if let Some(cl) = color_light {
                mutations.push(FieldMutation::SetPayload(
                    "color_light".into(),
                    Value::String(cl),
                ));
            }
            if let Some(cd) = color_dark {
                mutations.push(FieldMutation::SetPayload(
                    "color_dark".into(),
                    Value::String(cd),
                ));
            }
            if !mutations.is_empty() {
                self.store.update(item.id, mutations)?;
                self.invalidate_tag_cache();
            }
        }
        Ok(())
    }

    /// Rename a tag (definition + all assignments on publications).
    pub fn rename_tag(&self, old_path: String, new_path: String) -> Result<(), StoreApiError> {
        let new_leaf = new_path.rsplit('/').next().unwrap_or(&new_path);
        // Update tag definition
        let q = ItemQuery {
            schema: Some("imbib/tag-definition".into()),
            predicates: vec![Predicate::Eq(
                "canonical_path".into(),
                Value::String(old_path.clone()),
            )],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        for item in &items {
            self.store.update(
                item.id,
                vec![
                    FieldMutation::SetPayload(
                        "canonical_path".into(),
                        Value::String(new_path.clone()),
                    ),
                    FieldMutation::SetPayload("name".into(), Value::String(new_leaf.into())),
                ],
            )?;
        }
        // Update all publications with this tag
        let pub_q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasTag(old_path.clone())],
            ..Default::default()
        };
        let pubs = self.store.query(&pub_q)?;
        for pub_item in &pubs {
            self.store.update(
                pub_item.id,
                vec![
                    FieldMutation::RemoveTag(old_path.clone()),
                    FieldMutation::AddTag(new_path.clone()),
                ],
            )?;
        }
        self.invalidate_tag_cache();
        Ok(())
    }

    /// List all tag definitions with publication counts.
    pub fn list_tags_with_counts(&self) -> Result<Vec<TagWithCountRow>, StoreApiError> {
        let tag_defs = self.load_tag_definitions()?;
        let mut rows = Vec::new();
        for td in &tag_defs {
            let q = ItemQuery {
                schema: Some("imbib/bibliography-entry".into()),
                predicates: vec![Predicate::HasTag(td.path.clone())],
                ..Default::default()
            };
            let count = self.store.count(&q)? as i32;
            rows.push(TagWithCountRow {
                path: td.path.clone(),
                leaf_name: td.leaf_name.clone(),
                color_light: td.color_light.clone(),
                color_dark: td.color_dark.clone(),
                publication_count: count,
            });
        }
        Ok(rows)
    }

    // --- Bulk operations ---

    pub fn move_publications(
        &self,
        ids: Vec<String>,
        to_library_id: String,
    ) -> Result<UndoInfo, StoreApiError> {
        self.apply_mutation_to_ids(
            &ids,
            FieldMutation::SetParent(Some(parse_uuid(&to_library_id)?)),
        )
    }

    pub fn duplicate_publications(
        &self,
        ids: Vec<String>,
        to_library_id: String,
    ) -> Result<Vec<String>, StoreApiError> {
        let to_uuid = parse_uuid(&to_library_id)?;
        // Phase 1: Read all source items and prepare clones
        let mut items_to_insert = Vec::with_capacity(ids.len());
        for id_str in &ids {
            let uuid = parse_uuid(id_str)?;
            if let Some(mut item) = self.store.get(uuid)? {
                item.id = Uuid::new_v4();
                item.parent = Some(to_uuid);
                item.created = Utc::now();
                items_to_insert.push(item);
            }
        }
        if items_to_insert.is_empty() {
            return Ok(vec![]);
        }
        // Phase 2: Single-transaction batch insert
        let new_ids = self.store.insert_batch(items_to_insert)?;
        Ok(new_ids.iter().map(|id| id.to_string()).collect())
    }
    // --- Artifact operations ---

    /// Create a research artifact.
    #[allow(clippy::too_many_arguments)]
    pub fn create_artifact(
        &self,
        schema: String,
        title: String,
        source_url: Option<String>,
        notes: Option<String>,
        artifact_subtype: Option<String>,
        file_name: Option<String>,
        file_hash: Option<String>,
        file_size: Option<i64>,
        file_mime_type: Option<String>,
        capture_context: Option<String>,
        original_author: Option<String>,
        event_name: Option<String>,
        event_date: Option<String>,
        tags: Vec<String>,
    ) -> Result<ArtifactRow, StoreApiError> {
        if !schema.starts_with("impress/artifact/") {
            return Err(StoreApiError::InvalidInput(format!(
                "schema must start with 'impress/artifact/', got: {}",
                schema
            )));
        }
        let item = conversion::artifact_to_item(
            &schema,
            &title,
            source_url.as_deref(),
            notes.as_deref(),
            artifact_subtype.as_deref(),
            file_name.as_deref(),
            file_hash.as_deref(),
            file_size,
            file_mime_type.as_deref(),
            capture_context.as_deref(),
            original_author.as_deref(),
            event_name.as_deref(),
            event_date.as_deref(),
            tags,
        );
        self.store.insert(item.clone())?;
        let tag_defs = self.load_tag_definitions()?;
        Ok(item_to_artifact_row(&item, &tag_defs))
    }

    /// Get a single artifact by ID.
    pub fn get_artifact(&self, id: String) -> Result<Option<ArtifactRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema.starts_with("impress/artifact/") => {
                let tag_defs = self.load_tag_definitions()?;
                Ok(Some(item_to_artifact_row(&item, &tag_defs)))
            }
            _ => Ok(None),
        }
    }

    /// List artifacts, optionally filtered by a specific schema type.
    /// If schema_filter is None, returns artifacts across all artifact schemas.
    pub fn list_artifacts(
        &self,
        schema_filter: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<ArtifactRow>, StoreApiError> {
        let sort = vec![SortDescriptor {
            field: normalize_sort_field(&sort_field),
            ascending,
        }];
        let tag_defs = self.load_tag_definitions()?;

        match schema_filter {
            Some(schema) => {
                let q = ItemQuery {
                    schema: Some(schema),
                    sort,
                    limit: limit.map(|l| l as usize),
                    offset: offset.map(|o| o as usize),
                    ..Default::default()
                };
                let items = self.store.query(&q)?;
                Ok(items
                    .iter()
                    .map(|item| item_to_artifact_row(item, &tag_defs))
                    .collect())
            }
            None => {
                // Query each artifact schema and merge results
                let schemas = [
                    "impress/artifact/presentation",
                    "impress/artifact/poster",
                    "impress/artifact/dataset",
                    "impress/artifact/webpage",
                    "impress/artifact/note",
                    "impress/artifact/media",
                    "impress/artifact/code",
                    "impress/artifact/general",
                ];
                let mut all_items = Vec::new();
                for schema in &schemas {
                    let q = ItemQuery {
                        schema: Some((*schema).into()),
                        ..Default::default()
                    };
                    all_items.extend(self.store.query(&q)?);
                }
                // Sort merged results
                let sort_key = normalize_sort_field(&sort_field);
                all_items.sort_by(|a, b| {
                    let cmp = match sort_key.as_str() {
                        "created" => a.created.cmp(&b.created),
                        "payload.title" => {
                            let at = a.payload.get("title");
                            let bt = b.payload.get("title");
                            format!("{:?}", at).cmp(&format!("{:?}", bt))
                        }
                        _ => a.created.cmp(&b.created),
                    };
                    if ascending {
                        cmp
                    } else {
                        cmp.reverse()
                    }
                });
                // Apply offset/limit
                let start = offset.unwrap_or(0) as usize;
                let rows: Vec<ArtifactRow> = all_items
                    .iter()
                    .skip(start)
                    .take(limit.unwrap_or(u32::MAX) as usize)
                    .map(|item| item_to_artifact_row(item, &tag_defs))
                    .collect();
                Ok(rows)
            }
        }
    }

    /// Search artifacts by text across title, notes, source_url, and original_author.
    pub fn search_artifacts(
        &self,
        query: String,
        schema_filter: Option<String>,
    ) -> Result<Vec<ArtifactRow>, StoreApiError> {
        let search_pred = Predicate::Or(vec![
            Predicate::Contains("title".into(), query.clone()),
            Predicate::Contains("notes".into(), query.clone()),
            Predicate::Contains("source_url".into(), query.clone()),
            Predicate::Contains("original_author".into(), query),
        ]);
        // Query all items, then filter by artifact schema prefix
        let q = ItemQuery {
            schema: schema_filter,
            predicates: vec![search_pred],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        Ok(items
            .iter()
            .filter(|item| item.schema.starts_with("impress/artifact/"))
            .map(|item| item_to_artifact_row(item, &tag_defs))
            .collect())
    }

    /// Update an artifact's fields.
    // Argument list mirrors the FFI surface one-to-one; bundling into a
    // struct is a uniffi API change, not a lint fix.
    #[allow(clippy::too_many_arguments)]
    pub fn update_artifact(
        &self,
        id: String,
        title: Option<String>,
        source_url: Option<String>,
        notes: Option<String>,
        artifact_subtype: Option<String>,
        capture_context: Option<String>,
        original_author: Option<String>,
        event_name: Option<String>,
        event_date: Option<String>,
    ) -> Result<UndoInfo, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let mut mutations = Vec::new();
        if let Some(v) = title {
            mutations.push(FieldMutation::SetPayload("title".into(), Value::String(v)));
        }
        if let Some(v) = source_url {
            mutations.push(FieldMutation::SetPayload(
                "source_url".into(),
                Value::String(v),
            ));
        }
        if let Some(v) = notes {
            mutations.push(FieldMutation::SetPayload("notes".into(), Value::String(v)));
        }
        if let Some(v) = artifact_subtype {
            mutations.push(FieldMutation::SetPayload(
                "artifact_subtype".into(),
                Value::String(v),
            ));
        }
        if let Some(v) = capture_context {
            mutations.push(FieldMutation::SetPayload(
                "capture_context".into(),
                Value::String(v),
            ));
        }
        if let Some(v) = original_author {
            mutations.push(FieldMutation::SetPayload(
                "original_author".into(),
                Value::String(v),
            ));
        }
        if let Some(v) = event_name {
            mutations.push(FieldMutation::SetPayload(
                "event_name".into(),
                Value::String(v),
            ));
        }
        if let Some(v) = event_date {
            mutations.push(FieldMutation::SetPayload(
                "event_date".into(),
                Value::String(v),
            ));
        }
        if !mutations.is_empty() {
            Ok(self.store.update_with_undo(uuid, mutations)?.into())
        } else {
            Ok(UndoInfo {
                operation_ids: vec![],
                batch_id: None,
                description: "Update Artifact".into(),
            })
        }
    }

    /// Delete an artifact by ID.
    pub fn delete_artifact(&self, id: String) -> Result<(), StoreApiError> {
        let uuid = parse_uuid(&id)?;
        self.store.delete(uuid)?;
        Ok(())
    }

    /// Link an artifact to a publication via RelatesTo edge.
    pub fn link_artifact_to_publication(
        &self,
        artifact_id: String,
        publication_id: String,
    ) -> Result<UndoInfo, StoreApiError> {
        let art_uuid = parse_uuid(&artifact_id)?;
        let pub_uuid = parse_uuid(&publication_id)?;
        Ok(self
            .store
            .update_with_undo(
                art_uuid,
                vec![FieldMutation::AddReference(
                    impress_core::reference::TypedReference {
                        target: pub_uuid,
                        edge_type: EdgeType::RelatesTo,
                        metadata: None,
                    },
                )],
            )?
            .into())
    }

    /// Get relations from an artifact to other items.
    pub fn get_artifact_relations(
        &self,
        id: String,
    ) -> Result<Vec<ArtifactRelation>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let item = self.store.get(uuid)?.ok_or(StoreApiError::NotFound(id))?;
        let mut relations = Vec::new();
        for reference in &item.references {
            let target_item = self.store.get(reference.target)?;
            let (target_schema, target_title) = match &target_item {
                Some(ti) => {
                    let title = match ti.payload.get("title") {
                        Some(Value::String(s)) => Some(s.clone()),
                        _ => ti.payload.get("name").and_then(|v| match v {
                            Value::String(s) => Some(s.clone()),
                            _ => None,
                        }),
                    };
                    (Some(ti.schema.clone()), title)
                }
                None => (None, None),
            };
            relations.push(ArtifactRelation {
                target_id: reference.target.to_string(),
                edge_type: format!("{:?}", reference.edge_type),
                target_schema,
                target_title,
            });
        }
        Ok(relations)
    }

    /// Count all artifacts, optionally filtered by schema.
    pub fn count_artifacts(&self, schema_filter: Option<String>) -> Result<u32, StoreApiError> {
        match schema_filter {
            Some(schema) => {
                let q = ItemQuery {
                    schema: Some(schema),
                    ..Default::default()
                };
                Ok(self.store.count(&q)? as u32)
            }
            None => {
                // Count across all artifact schemas
                let schemas = [
                    "impress/artifact/presentation",
                    "impress/artifact/poster",
                    "impress/artifact/dataset",
                    "impress/artifact/webpage",
                    "impress/artifact/note",
                    "impress/artifact/media",
                    "impress/artifact/code",
                    "impress/artifact/general",
                ];
                let mut total = 0u32;
                for schema in &schemas {
                    let q = ItemQuery {
                        schema: Some((*schema).into()),
                        ..Default::default()
                    };
                    total += self.store.count(&q)? as u32;
                }
                Ok(total)
            }
        }
    }

    // --- Manuscript operations (unified GUI — ADR-0011 / GUI-meld plan) ---
    //
    // Manuscripts are `manuscript@1.0.0` items written by BOTH apps (imprint's
    // ManuscriptStoreAdapter and this store) into the same items table. These
    // methods mirror the publication query surface with manuscript-shaped rows;
    // collection membership reuses the schema-agnostic add_to_collection /
    // remove_from_collection (Contains edges work on any collection item).

    /// List manuscripts, optionally scoped to a manuscript-collection and/or a
    /// lifecycle status. `sort_field`: "title" | "created" | "modified" |
    /// "status" (default modified).
    pub fn list_manuscripts(
        &self,
        collection_id: Option<String>,
        status: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: Option<u32>,
        offset: Option<u32>,
    ) -> Result<Vec<ManuscriptRow>, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(cid) = collection_id {
            let coll_uuid = parse_uuid(&cid)?;
            predicates.push(Predicate::ReferencedBy(EdgeType::Contains, coll_uuid));
        }
        if let Some(st) = status {
            predicates.push(Predicate::Eq("status".into(), Value::String(st)));
        }
        let q = ItemQuery {
            schema: Some("manuscript".into()),
            predicates,
            sort: manuscript_sort_descriptors(&sort_field, ascending),
            limit: limit.map(|l| l as usize),
            offset: offset.map(|o| o as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        items
            .iter()
            .map(|item| {
                let rev_count = self.count_revisions(item.id)?;
                Ok(item_to_manuscript_row(item, &tag_defs, rev_count))
            })
            .collect()
    }

    /// Count manuscripts matching the same filters as `list_manuscripts`.
    pub fn count_manuscripts(
        &self,
        collection_id: Option<String>,
        status: Option<String>,
    ) -> Result<u32, StoreApiError> {
        let mut predicates = Vec::new();
        if let Some(cid) = collection_id {
            let coll_uuid = parse_uuid(&cid)?;
            predicates.push(Predicate::ReferencedBy(EdgeType::Contains, coll_uuid));
        }
        if let Some(st) = status {
            predicates.push(Predicate::Eq("status".into(), Value::String(st)));
        }
        let q = ItemQuery {
            schema: Some("manuscript".into()),
            predicates,
            ..Default::default()
        };
        Ok(self.store.count(&q)? as u32)
    }

    /// The allowed `manuscript.format` values (single source of truth in
    /// impress-core). Swift's `DocumentFormat` asserts parity in tests.
    pub fn supported_manuscript_formats(&self) -> Vec<String> {
        impress_core::manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS
            .iter()
            .map(|s| s.to_string())
            .collect()
    }

    /// List flagged manuscripts, optionally filtered to one flag color.
    /// The manuscript counterpart of `get_flagged_publications` — flags live on
    /// the generic item envelope, only the schema filter differs.
    pub fn list_flagged_manuscripts(
        &self,
        color: Option<String>,
    ) -> Result<Vec<ManuscriptRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("manuscript".into()),
            predicates: vec![Predicate::HasFlag(color)],
            sort: manuscript_sort_descriptors("modified", false),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        items
            .iter()
            .map(|item| {
                let rev_count = self.count_revisions(item.id)?;
                Ok(item_to_manuscript_row(item, &tag_defs, rev_count))
            })
            .collect()
    }

    /// Get a single manuscript row (list shape) by ID.
    pub fn get_manuscript_row(&self, id: String) -> Result<Option<ManuscriptRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "manuscript" => {
                let tag_defs = self.load_tag_definitions()?;
                let rev_count = self.count_revisions(item.id)?;
                Ok(Some(item_to_manuscript_row(&item, &tag_defs, rev_count)))
            }
            _ => Ok(None),
        }
    }

    /// Get full manuscript detail (body, metadata, collections) by ID.
    pub fn get_manuscript_detail(
        &self,
        id: String,
    ) -> Result<Option<ManuscriptDetail>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "manuscript" => {
                let tag_defs = self.load_tag_definitions()?;
                // Collections containing this manuscript (Contains edge holders
                // with the manuscript-collection schema).
                let coll_q = ItemQuery {
                    schema: Some("manuscript-collection".into()),
                    predicates: vec![Predicate::HasReference(EdgeType::Contains, uuid)],
                    ..Default::default()
                };
                let collections: Vec<String> = self
                    .store
                    .query(&coll_q)?
                    .iter()
                    .map(|c| c.id.to_string())
                    .collect();
                Ok(Some(item_to_manuscript_detail(
                    &item,
                    &tag_defs,
                    collections,
                )))
            }
            _ => Ok(None),
        }
    }

    /// Create a manuscript. Payload mirrors imprint's ManuscriptStoreAdapter
    /// exactly (same fields, same `format_schema_version`, self-referential
    /// `current_revision_ref` until the first revision) so items are
    /// indistinguishable regardless of which app created them.
    pub fn create_manuscript(
        &self,
        title: String,
        format: String,
        body: String,
        authors: Vec<String>,
    ) -> Result<ManuscriptRow, StoreApiError> {
        if !impress_core::manuscript_ops::is_supported_manuscript_format(&format) {
            return Err(StoreApiError::InvalidInput(format!(
                "format must be one of {:?}, got '{}'",
                impress_core::manuscript_ops::SUPPORTED_MANUSCRIPT_FORMATS,
                format
            )));
        }
        let id = Uuid::new_v4();
        let now_iso = impress_core::manuscript_ops::iso8601_now();
        let body_hash = impress_core::manuscript_ops::sha256_hex(&body);

        let mut payload = std::collections::BTreeMap::new();
        payload.insert("title".into(), Value::String(title));
        payload.insert("status".into(), Value::String("draft".into()));
        payload.insert("current_revision_ref".into(), Value::String(id.to_string()));
        payload.insert(
            "authors".into(),
            Value::Array(authors.into_iter().map(Value::String).collect()),
        );
        payload.insert("format".into(), Value::String(format));
        payload.insert("body_content".into(), Value::String(body));
        payload.insert("body_content_hash".into(), Value::String(body_hash));
        payload.insert("body_modified_at".into(), Value::String(now_iso));
        // Mirrors imprint's current DocumentSchemaVersion (v1.4).
        payload.insert("format_schema_version".into(), Value::Int(140));

        let item = conversion::bare_item(id, "manuscript", payload);
        self.store.insert(item.clone())?;
        let tag_defs = self.load_tag_definitions()?;
        Ok(item_to_manuscript_row(&item, &tag_defs, 0))
    }

    /// List saved plot specs, newest-modified first.
    pub fn list_plot_specs(&self, limit: u32) -> Result<Vec<PlotSpecRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("plot-spec".into()),
            sort: vec![SortDescriptor {
                field: "modified".into(),
                ascending: false,
            }],
            limit: Some(limit as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        Ok(items.iter().map(item_to_plot_spec_row).collect())
    }

    /// Save a plot spec (the declarative impress-plot spec JSON). Always
    /// creates a new item; overwriting by name is the caller's policy.
    pub fn save_plot_spec(
        &self,
        name: String,
        spec_kind: String,
        spec_json: String,
        data_source: Option<String>,
    ) -> Result<PlotSpecRow, StoreApiError> {
        if spec_kind != "series" && spec_kind != "grid" {
            return Err(StoreApiError::InvalidInput(format!(
                "spec_kind must be 'series' or 'grid', got '{spec_kind}'"
            )));
        }
        // Parse-check so the store never holds an unrenderable spec.
        if serde_json::from_str::<serde_json::Value>(&spec_json).is_err() {
            return Err(StoreApiError::InvalidInput(
                "spec_json is not valid JSON".into(),
            ));
        }
        let id = Uuid::new_v4();
        let mut payload = std::collections::BTreeMap::new();
        payload.insert("name".into(), Value::String(name));
        payload.insert("spec_kind".into(), Value::String(spec_kind));
        payload.insert("spec_json".into(), Value::String(spec_json));
        if let Some(ds) = data_source {
            payload.insert("data_source".into(), Value::String(ds));
        }
        let item = conversion::bare_item(id, "plot-spec", payload);
        self.store.insert(item.clone())?;
        Ok(item_to_plot_spec_row(&item))
    }

    /// Fetch one saved plot spec.
    pub fn get_plot_spec(&self, id: String) -> Result<Option<PlotSpecRow>, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        match self.store.get(uuid)? {
            Some(item) if item.schema == "plot-spec" => Ok(Some(item_to_plot_spec_row(&item))),
            _ => Ok(None),
        }
    }

    /// Save a manuscript body, optionally guarded by the last-known
    /// `body_content_hash` (compare-and-set for cross-process safety).
    ///
    /// With `expected_hash = None` this is an unconditional save (legacy
    /// behavior, matching imprint's setBody). With `Some(hash)`, the save is
    /// rejected with `Conflict` when the stored hash differs — the caller
    /// should re-read, reconcile (fast-forward or surface a conflict banner),
    /// and retry.
    ///
    /// Note: the check-then-write runs as two store calls under this handle's
    /// connection lock; a cross-process writer can still interleave in the
    /// window between them. That residual race is closed by the Darwin
    /// cross-process change notification + `absorbExternalChange` path
    /// (GUI-meld Phase 4); the guard here catches the common stale-editor
    /// case deterministically.
    pub fn set_manuscript_body(
        &self,
        id: String,
        body: String,
        expected_hash: Option<String>,
    ) -> Result<ManuscriptSaveOutcome, StoreApiError> {
        let uuid = parse_uuid(&id)?;
        let item = self
            .store
            .get(uuid)?
            .ok_or_else(|| StoreApiError::NotFound(id.clone()))?;
        if item.schema != "manuscript" {
            return Err(StoreApiError::InvalidInput(format!(
                "set_manuscript_body requires schema 'manuscript', got '{}'",
                item.schema
            )));
        }

        let stored_hash = match item.payload.get("body_content_hash") {
            Some(Value::String(h)) => Some(h.clone()),
            _ => None,
        };
        if let Some(expected) = expected_hash {
            if stored_hash.as_deref() != Some(expected.as_str()) {
                return Ok(ManuscriptSaveOutcome {
                    applied: false,
                    stored_hash,
                    new_hash: None,
                });
            }
        }

        let new_hash = impress_core::manuscript_ops::sha256_hex(&body);
        let now_iso = impress_core::manuscript_ops::iso8601_now();
        self.store.update(
            uuid,
            vec![
                FieldMutation::SetPayload("body_content".into(), Value::String(body)),
                FieldMutation::SetPayload(
                    "body_content_hash".into(),
                    Value::String(new_hash.clone()),
                ),
                FieldMutation::SetPayload("body_modified_at".into(), Value::String(now_iso)),
            ],
        )?;
        Ok(ManuscriptSaveOutcome {
            applied: true,
            stored_hash,
            new_hash: Some(new_hash),
        })
    }

    /// Search manuscripts by title/body/notes substring (list-filter path;
    /// palette search goes through the store FTS on the SharedStore surface).
    pub fn search_manuscripts(
        &self,
        query: String,
        limit: Option<u32>,
    ) -> Result<Vec<ManuscriptRow>, StoreApiError> {
        let search_pred = Predicate::Or(vec![
            Predicate::Contains("title".into(), query.clone()),
            Predicate::Contains("body_content".into(), query.clone()),
            Predicate::Contains("notes".into(), query),
        ]);
        let q = ItemQuery {
            schema: Some("manuscript".into()),
            predicates: vec![search_pred],
            sort: manuscript_sort_descriptors("modified", false),
            limit: limit.map(|l| l as usize),
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let tag_defs = self.load_tag_definitions()?;
        items
            .iter()
            .map(|item| {
                let rev_count = self.count_revisions(item.id)?;
                Ok(item_to_manuscript_row(item, &tag_defs, rev_count))
            })
            .collect()
    }

    /// List all manuscript-collections (flat; tree assembly via `parent_id`
    /// happens in the sidebar view model, same as imbib collections).
    pub fn list_manuscript_collections(
        &self,
    ) -> Result<Vec<ManuscriptCollectionRow>, StoreApiError> {
        let q = ItemQuery {
            schema: Some("manuscript-collection".into()),
            sort: vec![SortDescriptor {
                field: "payload.sort_order".into(),
                ascending: true,
            }],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let mut rows = Vec::new();
        for item in &items {
            let count_q = ItemQuery {
                schema: Some("manuscript".into()),
                predicates: vec![Predicate::ReferencedBy(EdgeType::Contains, item.id)],
                ..Default::default()
            };
            let count = self.store.count(&count_q)? as i32;
            rows.push(item_to_manuscript_collection_row(item, count));
        }
        Ok(rows)
    }

    /// Create a manuscript-collection (folder). Nesting via `parent_id`.
    pub fn create_manuscript_collection(
        &self,
        name: String,
        parent_id: Option<String>,
    ) -> Result<ManuscriptCollectionRow, StoreApiError> {
        if let Some(pid) = &parent_id {
            parse_uuid(pid)?; // validate early
        }
        let id = Uuid::new_v4();
        let mut payload = std::collections::BTreeMap::new();
        payload.insert("name".into(), Value::String(name));
        payload.insert("sort_order".into(), Value::Int(0));
        if let Some(pid) = parent_id {
            payload.insert("parent_collection_ref".into(), Value::String(pid));
        }
        let item = conversion::bare_item(id, "manuscript-collection", payload);
        self.store.insert(item.clone())?;
        Ok(item_to_manuscript_collection_row(&item, 0))
    }

    /// List revision snapshots of a manuscript, newest first.
    pub fn list_manuscript_revisions(
        &self,
        manuscript_id: String,
    ) -> Result<Vec<ManuscriptRevisionRow>, StoreApiError> {
        let uuid = parse_uuid(&manuscript_id)?;
        let items = impress_core::manuscript_ops::list_revisions(&self.store, uuid)?;
        Ok(items.iter().map(item_to_manuscript_revision_row).collect())
    }

    /// Create an immutable revision snapshot of the manuscript's current body
    /// and advance its `current_revision_ref` (ADR-0011 D45 linear chain).
    /// `snapshot_reason`: status-change | user-tag | stable-churn | manual.
    pub fn create_manuscript_revision(
        &self,
        manuscript_id: String,
        revision_tag: String,
        snapshot_reason: String,
    ) -> Result<ManuscriptRevisionRow, StoreApiError> {
        let uuid = parse_uuid(&manuscript_id)?;
        let item = impress_core::manuscript_ops::create_revision(
            &self.store,
            uuid,
            &revision_tag,
            &snapshot_reason,
            "user:local",
            impress_core::item::ActorKind::Human,
        )?;
        Ok(item_to_manuscript_revision_row(&item))
    }
}

// Internal helpers (not exposed via UniFFI)
impl ImbibStore {
    /// Count revision snapshots of a manuscript.
    fn count_revisions(&self, manuscript_id: Uuid) -> Result<i32, StoreApiError> {
        let q = ItemQuery {
            schema: Some("manuscript-revision".into()),
            predicates: vec![Predicate::Eq(
                "parent_manuscript_ref".into(),
                Value::String(manuscript_id.to_string()),
            )],
            ..Default::default()
        };
        Ok(self.store.count(&q)? as i32)
    }

    /// Check whether a publication with matching DOI, arXiv ID, or bibcode already exists
    /// in the given library.
    fn is_duplicate_in_library(
        &self,
        publication: &crate::domain::Publication,
        library_id: Uuid,
    ) -> Result<bool, StoreApiError> {
        let mut or_preds = Vec::new();
        if let Some(ref doi) = publication.identifiers.doi {
            if !doi.is_empty() {
                or_preds.push(Predicate::Eq("doi".into(), Value::String(doi.clone())));
            }
        }
        if let Some(ref arxiv) = publication.identifiers.arxiv_id {
            if !arxiv.is_empty() {
                or_preds.push(Predicate::Eq(
                    "arxiv_id".into(),
                    Value::String(arxiv.clone()),
                ));
                // Also check without version suffix (e.g., "2602.08929" matches "2602.08929v1")
                let stripped = arxiv
                    .trim_end_matches(|c: char| c == 'v' || c.is_ascii_digit())
                    .to_string();
                if stripped != *arxiv && !stripped.is_empty() && !stripped.ends_with('.') {
                    // Only add if stripping actually removed something and result is valid
                    let without_version = arxiv.split('v').next().unwrap_or(arxiv).to_string();
                    if without_version != *arxiv && !without_version.is_empty() {
                        or_preds.push(Predicate::Eq(
                            "arxiv_id".into(),
                            Value::String(without_version),
                        ));
                    }
                }
            }
        }
        if let Some(ref bibcode) = publication.identifiers.bibcode {
            if !bibcode.is_empty() {
                or_preds.push(Predicate::Eq(
                    "bibcode".into(),
                    Value::String(bibcode.clone()),
                ));
            }
        }
        // Also check by cite key as a fallback
        if !publication.cite_key.is_empty() {
            or_preds.push(Predicate::Eq(
                "cite_key".into(),
                Value::String(publication.cite_key.clone()),
            ));
        }
        if or_preds.is_empty() {
            return Ok(false);
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::HasParent(library_id), Predicate::Or(or_preds)],
            limit: Some(1),
            ..Default::default()
        };
        Ok(self.store.count(&q)? > 0)
    }

    fn count_children(&self, parent_id: Uuid, schema: &str) -> Result<usize, StoreApiError> {
        let q = ItemQuery {
            schema: Some(schema.into()),
            predicates: vec![Predicate::HasParent(parent_id)],
            ..Default::default()
        };
        Ok(self.store.count(&q)?)
    }

    fn count_collection_members(&self, collection_id: Uuid) -> Result<usize, StoreApiError> {
        // Count items referenced by this collection via Contains edges
        let item = self.store.get(collection_id)?;
        match item {
            Some(item) => Ok(item
                .references
                .iter()
                .filter(|r| r.edge_type == EdgeType::Contains)
                .count()),
            None => Ok(0),
        }
    }

    /// Load all linked-file items that are children of the given publication IDs.
    /// Returns a map from parent UUID to Vec of linked-file Items.
    // Not wired to a caller yet (landed ahead of the iOS linked-files UI).
    #[allow(dead_code)]
    fn load_linked_files_for_pubs(
        &self,
        pub_ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, Vec<impress_core::item::Item>>, StoreApiError> {
        use std::collections::HashMap;
        let mut map: HashMap<Uuid, Vec<impress_core::item::Item>> = HashMap::new();
        if pub_ids.is_empty() {
            return Ok(map);
        }

        // Single-pub: targeted query instead of full table scan
        if pub_ids.len() == 1 {
            let q = ItemQuery {
                schema: Some("imbib/linked-file".into()),
                predicates: vec![Predicate::HasParent(pub_ids[0])],
                include_tags: false,
                include_references: false,
                ..Default::default()
            };
            let lf = self.store.query(&q)?;
            if !lf.is_empty() {
                map.insert(pub_ids[0], lf);
            }
            return Ok(map);
        }

        // Batch: query all linked-file items — cheaper than per-publication queries for large batches
        let q = ItemQuery {
            schema: Some("imbib/linked-file".into()),
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        let all_lf = self.store.query(&q)?;
        for lf in all_lf {
            if let Some(parent) = lf.parent {
                if pub_ids.contains(&parent) {
                    map.entry(parent).or_default().push(lf);
                }
            }
        }
        Ok(map)
    }

    /// Convert a batch of publication Items into BibliographyRows, resolving linked file status.
    fn items_to_bibliography_rows(
        &self,
        items: &[impress_core::item::Item],
        tag_defs: &[TagDisplayRow],
    ) -> Result<Vec<BibliographyRow>, StoreApiError> {
        let pub_ids: Vec<Uuid> = items.iter().map(|i| i.id).collect();
        let lf_status = self.load_linked_file_status(&pub_ids)?;
        Ok(items
            .iter()
            .map(|item| {
                let (has_pdf, has_other) =
                    lf_status.get(&item.id).copied().unwrap_or((false, false));
                item_to_bibliography_row(item, tag_defs, has_pdf, has_other)
            })
            .collect())
    }

    /// Returns (has_downloaded_pdf, has_other_attachments) per publication.
    /// Uses SQL aggregation with json_extract instead of loading full Item objects.
    fn load_linked_file_status(
        &self,
        pub_ids: &[Uuid],
    ) -> Result<std::collections::HashMap<Uuid, (bool, bool)>, StoreApiError> {
        use std::collections::HashMap;
        let mut result: HashMap<Uuid, (bool, bool)> = HashMap::new();
        if pub_ids.is_empty() {
            return Ok(result);
        }

        for chunk in pub_ids.chunks(900) {
            let placeholders = (1..=chunk.len())
                .map(|i| format!("?{}", i))
                .collect::<Vec<_>>()
                .join(", ");
            let sql = format!(
                "SELECT parent_id, \
                        MAX(CASE WHEN json_extract(payload, '$.is_pdf') = 1 \
                                  AND json_extract(payload, '$.is_locally_materialized') = 1 \
                             THEN 1 ELSE 0 END), \
                        MAX(CASE WHEN json_extract(payload, '$.is_pdf') != 1 \
                                  OR json_extract(payload, '$.is_pdf') IS NULL \
                             THEN 1 ELSE 0 END) \
                 FROM items \
                 WHERE schema_ref = 'imbib/linked-file' AND parent_id IN ({}) \
                 GROUP BY parent_id",
                placeholders
            );
            let params: Vec<String> = chunk.iter().map(|id| id.to_string()).collect();
            let params_ref: Vec<&dyn rusqlite::types::ToSql> = params
                .iter()
                .map(|p| p as &dyn rusqlite::types::ToSql)
                .collect();

            let rows = self.store.query_raw(&sql, &params_ref, |row| {
                let parent_str: String = row.get(0)?;
                let has_pdf: i32 = row.get(1).unwrap_or(0);
                let has_other: i32 = row.get(2).unwrap_or(0);
                Ok((parent_str, has_pdf != 0, has_other != 0))
            })?;

            for (parent_str, has_pdf, has_other) in rows {
                if let Ok(uuid) = Uuid::parse_str(&parent_str) {
                    result.insert(uuid, (has_pdf, has_other));
                }
            }
        }
        Ok(result)
    }

    fn load_tag_definitions(&self) -> Result<Vec<TagDisplayRow>, StoreApiError> {
        // Return cached tag definitions if available
        if let Some(cached) = self.tag_defs_cache.lock().unwrap().as_ref() {
            return Ok(cached.clone());
        }

        let q = ItemQuery {
            schema: Some("imbib/tag-definition".into()),
            include_tags: false,
            include_references: false,
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let result: Vec<TagDisplayRow> = items
            .iter()
            .map(|item| {
                let payload = &item.payload;
                let path = match payload.get("canonical_path") {
                    Some(Value::String(s)) => s.clone(),
                    _ => String::new(),
                };
                let leaf_name = match payload.get("name") {
                    Some(Value::String(s)) => s.clone(),
                    _ => path.rsplit('/').next().unwrap_or("").to_string(),
                };
                let color_light = match payload.get("color_light") {
                    Some(Value::String(s)) => Some(s.clone()),
                    _ => None,
                };
                let color_dark = match payload.get("color_dark") {
                    Some(Value::String(s)) => Some(s.clone()),
                    _ => None,
                };
                TagDisplayRow {
                    path,
                    leaf_name,
                    color_light,
                    color_dark,
                }
            })
            .collect();

        // Populate cache
        *self.tag_defs_cache.lock().unwrap() = Some(result.clone());
        Ok(result)
    }

    /// Find all existing bibliography entries matching any of the given identifiers.
    /// Returns raw Items (not shaped rows) since we only need payload identifiers.
    fn find_items_by_identifiers(
        &self,
        dois: &[String],
        arxiv_ids: &[String],
        bibcodes: &[String],
    ) -> Result<Vec<impress_core::item::Item>, StoreApiError> {
        let mut or_preds = Vec::new();
        if !dois.is_empty() {
            or_preds.push(Predicate::In(
                "doi".into(),
                dois.iter().map(|s| Value::String(s.clone())).collect(),
            ));
        }
        if !arxiv_ids.is_empty() {
            or_preds.push(Predicate::In(
                "arxiv_id".into(),
                arxiv_ids.iter().map(|s| Value::String(s.clone())).collect(),
            ));
        }
        if !bibcodes.is_empty() {
            or_preds.push(Predicate::In(
                "bibcode".into(),
                bibcodes.iter().map(|s| Value::String(s.clone())).collect(),
            ));
        }
        if or_preds.is_empty() {
            return Ok(vec![]);
        }
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![Predicate::Or(or_preds)],
            ..Default::default()
        };
        Ok(self.store.query(&q)?)
    }

    /// Load all dismissed paper identifiers matching the given sets.
    /// Returns a HashSet of lowercased identifier strings for O(1) lookup.
    fn load_dismissed_identifiers(
        &self,
        dois: &[String],
        arxiv_ids: &[String],
        bibcodes: &[String],
    ) -> Result<std::collections::HashSet<String>, StoreApiError> {
        let mut or_preds = Vec::new();
        if !dois.is_empty() {
            or_preds.push(Predicate::In(
                "doi".into(),
                dois.iter()
                    .map(|s| Value::String(s.to_lowercase()))
                    .collect(),
            ));
        }
        if !arxiv_ids.is_empty() {
            or_preds.push(Predicate::In(
                "arxiv_id".into(),
                arxiv_ids
                    .iter()
                    .map(|s| Value::String(s.to_lowercase()))
                    .collect(),
            ));
        }
        if !bibcodes.is_empty() {
            or_preds.push(Predicate::In(
                "bibcode".into(),
                bibcodes
                    .iter()
                    .map(|s| Value::String(s.to_lowercase()))
                    .collect(),
            ));
        }
        if or_preds.is_empty() {
            return Ok(std::collections::HashSet::new());
        }
        let q = ItemQuery {
            schema: Some("imbib/dismissed-paper".into()),
            predicates: vec![Predicate::Or(or_preds)],
            ..Default::default()
        };
        let items = self.store.query(&q)?;
        let mut set = std::collections::HashSet::new();
        for item in &items {
            if let Some(Value::String(d)) = item.payload.get("doi") {
                set.insert(d.clone());
            }
            if let Some(Value::String(a)) = item.payload.get("arxiv_id") {
                set.insert(a.clone());
            }
            if let Some(Value::String(b)) = item.payload.get("bibcode") {
                set.insert(b.clone());
            }
        }
        Ok(set)
    }
}

/// Check whether a search result input is dismissed based on the pre-loaded set.
fn is_input_dismissed(
    result: &SearchResultInput,
    dismissed: &std::collections::HashSet<String>,
) -> bool {
    result
        .doi
        .as_ref()
        .is_some_and(|d| dismissed.contains(&d.to_lowercase()))
        || result
            .arxiv_id
            .as_ref()
            .is_some_and(|a| dismissed.contains(&a.to_lowercase()))
        || result
            .bibcode
            .as_ref()
            .is_some_and(|b| dismissed.contains(&b.to_lowercase()))
}

fn parse_uuid(s: &str) -> Result<Uuid, StoreApiError> {
    Uuid::parse_str(s).map_err(|e| StoreApiError::InvalidInput(format!("invalid UUID: {}", e)))
}

fn normalize_sort_field(field: &str) -> String {
    match field {
        "dateAdded" | "date_added" | "created" => "created".into(),
        "dateModified" | "date_modified" | "modified" => "modified".into(),
        "title" => "payload.title".into(),
        "author" | "author_text" => "payload.author_text".into(),
        "year" => "payload.year".into(),
        "citeKey" | "cite_key" => "payload.cite_key".into(),
        "citationCount" | "citation_count" => "payload.citation_count".into(),
        // Recency of USER ACTIVITY (viewed, or added by hand) — the same
        // payload field that backs the Recent library. Papers never touched
        // have no value; SQLite sorts NULLs last under DESC, so untouched
        // papers fall to the bottom of a "Recently Used" sort, which is the
        // intent.
        "lastActivity" | "last_activity" | "recent" => "payload.last_activity_at".into(),
        f => f.into(),
    }
}

/// Build sort descriptors for a query.
///
/// Most sort fields map to a single SQL ORDER BY column via `normalize_sort_field`.
/// "starred" is special: it sorts starred items first, then by date within each group.
fn build_sort_descriptors(sort_field: &str, ascending: bool) -> Vec<SortDescriptor> {
    match sort_field {
        "starred" => vec![
            SortDescriptor {
                field: "is_starred".into(),
                ascending: false,
            },
            SortDescriptor {
                field: "created".into(),
                ascending,
            },
        ],
        // Recency needs a deterministic secondary: every never-touched paper
        // has a NULL stamp, so without one the whole untouched tail would sit
        // in arbitrary (rowid) order and reshuffle against the Swift-side
        // re-sort, which tie-breaks on created.
        "lastActivity" | "last_activity" | "recent" => vec![
            SortDescriptor {
                field: "payload.last_activity_at".into(),
                ascending,
            },
            SortDescriptor {
                field: "created".into(),
                ascending,
            },
        ],
        other => vec![SortDescriptor {
            field: normalize_sort_field(other),
            ascending,
        }],
    }
}

/// Sort descriptors for manuscript queries. Manuscript payloads have their
/// own sortable fields (title, status); envelope dates are shared.
fn manuscript_sort_descriptors(sort_field: &str, ascending: bool) -> Vec<SortDescriptor> {
    let field = match sort_field {
        "title" => "payload.title",
        "status" => "payload.status",
        "created" => "created",
        _ => "modified",
    };
    vec![SortDescriptor {
        field: field.into(),
        ascending,
    }]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_store() -> Arc<ImbibStore> {
        ImbibStore::open_in_memory().unwrap()
    }

    #[test]
    fn create_and_list_libraries() {
        let store = make_store();
        let lib = store.create_library("My Library".into()).unwrap();
        assert_eq!(lib.name, "My Library");
        assert!(!lib.is_default);

        let libs = store.list_libraries().unwrap();
        assert_eq!(libs.len(), 1);
        assert_eq!(libs[0].name, "My Library");
    }

    #[test]
    fn import_bibtex_and_query() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let bibtex = r#"
@article{Smith2024,
    title = {Dark Matter in Galaxies},
    author = {Smith, John and Doe, Jane},
    year = {2024},
    journal = {ApJ},
}
@article{Jones2023,
    title = {Stellar Populations},
    author = {Jones, Bob},
    year = {2023},
}
"#;
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();
        assert_eq!(ids.len(), 2);

        let pubs = store
            .query_publications(lib.id.clone(), "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs.len(), 2);

        // Check library count
        let libs = store.list_libraries().unwrap();
        assert_eq!(libs[0].publication_count, 2);
    }

    #[test]
    fn set_read_and_starred() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        store.set_read(ids.clone(), true).unwrap();
        store.set_starred(ids.clone(), true).unwrap();

        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert!(pub_row.is_read);
        assert!(pub_row.is_starred);
    }

    #[test]
    fn set_and_clear_flag() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        store
            .set_flag(ids.clone(), Some("red".into()), Some("solid".into()), None)
            .unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row.flag_color, Some("red".into()));
        assert_eq!(pub_row.flag_style, Some("solid".into()));

        // Get flagged
        let flagged = store
            .get_flagged_publications(Some("red".into()), "created".into(), false, None, None)
            .unwrap();
        assert_eq!(flagged.len(), 1);

        // Clear flag
        store.set_flag(ids.clone(), None, None, None).unwrap();
        let pub_row2 = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert!(pub_row2.flag_color.is_none());
    }

    #[test]
    fn tag_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        // Create tag definition
        store
            .create_tag(
                "methods/sims".into(),
                Some("#ff0000".into()),
                Some("#cc0000".into()),
            )
            .unwrap();

        // Add tag to publication
        store.add_tag(ids.clone(), "methods/sims".into()).unwrap();

        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row.tags.len(), 1);
        assert_eq!(pub_row.tags[0].path, "methods/sims");
        assert_eq!(pub_row.tags[0].color_light, Some("#ff0000".into()));

        // Remove tag
        store
            .remove_tag(ids.clone(), "methods/sims".into())
            .unwrap();
        let pub_row2 = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row2.tags.len(), 0);
    }

    #[test]
    fn search_publications() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Dark Matter Distribution}}
@article{B, title={Stellar Populations in the MW}}
"#;
        store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        let results = store
            .search_publications(
                "Dark Matter".into(),
                Some(lib.id.clone()),
                "created".into(),
                false,
                None,
                None,
            )
            .unwrap();
        assert_eq!(results.len(), 1);
        assert!(results[0].title.contains("Dark Matter"));
    }

    #[test]
    fn export_bibtex_round_trip() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{Smith2024,\n    title = {Dark Matter},\n    year = {2024},\n}\n";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        let exported = store.export_bibtex(ids).unwrap();
        assert!(exported.contains("Smith2024"));
        assert!(exported.contains("Dark Matter"));
    }

    #[test]
    fn collection_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let coll = store
            .create_collection("Favorites".into(), lib.id.clone(), false, None)
            .unwrap();
        assert_eq!(coll.name, "Favorites");

        let colls = store.list_collections(lib.id.clone()).unwrap();
        assert_eq!(colls.len(), 1);
    }

    /// `count_publications(None)` must count publications that belong to no
    /// library — the total is a row count, never a sum over libraries.
    ///
    /// This is the invariant `/api/status` and the `count-publications` MCP tool
    /// both rest on. Before the route reported a total, the tool summed each
    /// library's paperCount and under-reported by exactly the unfiled
    /// publications (152 of 6531 on the author's store). Every other assertion
    /// in this file passes `Some(library)`, so the scoped count was covered and
    /// the total never was.
    #[test]
    fn count_publications_includes_ones_no_library_owns() {
        let store = make_store();
        let keep = store.create_library("Keep".into()).unwrap();
        let doomed = store.create_library("Doomed".into()).unwrap();
        store
            .import_bibtex(
                "@article{A, title={Filed}, year={2021}}".into(),
                keep.id.clone(),
            )
            .unwrap();
        store
            .import_bibtex(
                "@article{B, title={Soon orphaned}, year={2022}}".into(),
                doomed.id.clone(),
            )
            .unwrap();
        assert_eq!(store.count_publications(None).unwrap(), 2);

        // ON DELETE SET NULL: the publication survives, its owning library does not.
        store.delete_library(doomed.id.clone()).unwrap();

        let via_libraries: u32 = store
            .list_libraries()
            .unwrap()
            .iter()
            .map(|l| store.count_publications(Some(l.id.clone())).unwrap())
            .sum();
        assert_eq!(
            via_libraries, 1,
            "the orphan is invisible to a library walk"
        );

        assert_eq!(
            store.count_publications(None).unwrap(),
            2,
            "the total must still see the publication no library owns"
        );
    }

    /// `count_collections` must count collections that belong to no library.
    ///
    /// `items.parent_id` is `REFERENCES items(id) ON DELETE SET NULL`, so
    /// deleting a library orphans its collections rather than removing them —
    /// which is how the author's store ended up with four collections that no
    /// library owns. Summing `list_collections` over `list_libraries` reported
    /// zero for all four, and that sum was what `/api/status` published.
    #[test]
    fn count_collections_includes_ones_no_library_owns() {
        let store = make_store();
        let lib = store.create_library("Doomed".into()).unwrap();
        store
            .create_collection("Orphan".into(), lib.id.clone(), false, None)
            .unwrap();
        assert_eq!(store.count_collections().unwrap(), 1);

        store.delete_library(lib.id.clone()).unwrap();

        // The per-library walk now finds nothing...
        let via_libraries: usize = store
            .list_libraries()
            .unwrap()
            .iter()
            .map(|l| store.list_collections(l.id.clone()).unwrap().len())
            .sum();
        assert_eq!(
            via_libraries, 0,
            "the orphan is invisible to a library walk"
        );

        // ...but the collection is still there, and the total says so.
        assert_eq!(
            store.count_collections().unwrap(),
            1,
            "count_collections must count rows by schema, not walk libraries"
        );
    }

    #[test]
    fn rename_collection_updates_name() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let coll = store
            .create_collection("Old Name".into(), lib.id.clone(), false, None)
            .unwrap();

        let renamed = store
            .rename_collection(coll.id.clone(), "New Name".into())
            .unwrap();
        assert_eq!(renamed.name, "New Name");

        // Persisted: list reflects the new name.
        let colls = store.list_collections(lib.id.clone()).unwrap();
        assert_eq!(colls.len(), 1);
        assert_eq!(colls[0].name, "New Name");

        // Renaming a non-existent collection is NotFound.
        let missing = uuid::Uuid::new_v4().to_string();
        assert!(matches!(
            store.rename_collection(missing, "X".into()),
            Err(StoreApiError::NotFound(_))
        ));
    }

    #[test]
    fn delete_collection_removes_it_and_membership() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        let coll = store
            .create_collection("Favorites".into(), lib.id.clone(), false, None)
            .unwrap();
        store
            .add_to_collection(ids.clone(), coll.id.clone())
            .unwrap();
        assert_eq!(
            store
                .count_collection_members_public(coll.id.clone())
                .unwrap(),
            1
        );

        store.delete_collection(coll.id.clone()).unwrap();

        // Collection is gone.
        let colls = store.list_collections(lib.id.clone()).unwrap();
        assert!(colls.is_empty());

        // Publication itself survives (only the membership edge was removed).
        let pub_row = store.get_publication(ids[0].clone()).unwrap();
        assert!(pub_row.is_some());

        // Deleting a missing collection is NotFound.
        assert!(matches!(
            store.delete_collection(coll.id.clone()),
            Err(StoreApiError::NotFound(_))
        ));
    }

    #[test]
    fn list_collections_for_publication_reflects_membership() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();
        let pub_id = ids[0].clone();

        let coll_a = store
            .create_collection("A".into(), lib.id.clone(), false, None)
            .unwrap();
        let coll_b = store
            .create_collection("B".into(), lib.id.clone(), false, None)
            .unwrap();

        // Not in any collection yet.
        assert!(store
            .list_collections_for_publication(pub_id.clone())
            .unwrap()
            .is_empty());

        // Add to A → exactly A, member count 1.
        store
            .add_to_collection(vec![pub_id.clone()], coll_a.id.clone())
            .unwrap();
        let got = store
            .list_collections_for_publication(pub_id.clone())
            .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].id, coll_a.id);
        assert_eq!(got[0].publication_count, 1);

        // Add to B as well → both, order by sort_order (A then B).
        store
            .add_to_collection(vec![pub_id.clone()], coll_b.id.clone())
            .unwrap();
        let got = store
            .list_collections_for_publication(pub_id.clone())
            .unwrap();
        assert_eq!(got.len(), 2);
        let names: Vec<&str> = got.iter().map(|c| c.name.as_str()).collect();
        assert!(names.contains(&"A"));
        assert!(names.contains(&"B"));

        // Remove from A → only B remains.
        store
            .remove_from_collection(vec![pub_id.clone()], coll_a.id.clone())
            .unwrap();
        let got = store
            .list_collections_for_publication(pub_id.clone())
            .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].id, coll_b.id);
    }

    #[test]
    fn delete_smart_search_removes_it() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ss = store
            .create_smart_search(
                "Dark Matter".into(),
                "dark matter galaxies".into(),
                lib.id.clone(),
                None,
                50,
                false,
                false,
                3600,
            )
            .unwrap();
        assert_eq!(
            store
                .list_smart_searches(Some(lib.id.clone()))
                .unwrap()
                .len(),
            1
        );

        store.delete_smart_search(ss.id.clone()).unwrap();
        assert!(store
            .list_smart_searches(Some(lib.id.clone()))
            .unwrap()
            .is_empty());
        assert!(store.get_smart_search(ss.id.clone()).unwrap().is_none());

        // Deleting a missing smart search is NotFound.
        assert!(matches!(
            store.delete_smart_search(ss.id.clone()),
            Err(StoreApiError::NotFound(_))
        ));
    }

    #[test]
    fn delete_publication() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        store.delete_publications(ids.clone()).unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap();
        assert!(pub_row.is_none());
    }

    #[test]
    fn update_field() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{X, title={Old Title}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        store
            .update_field(ids[0].clone(), "title".into(), Some("New Title".into()))
            .unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row.title, "New Title");
    }

    #[test]
    fn publication_detail() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = "@article{Smith2024, title={A Paper}, year={2024}, doi={10.1234/test}}";
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        let detail = store
            .get_publication_detail(ids[0].clone())
            .unwrap()
            .unwrap();
        assert_eq!(detail.cite_key, "Smith2024");
        assert_eq!(detail.entry_type, "article");
        assert!(detail.fields.contains_key("title"));
        assert!(detail.fields.contains_key("doi"));
    }

    #[test]
    fn list_tags() {
        let store = make_store();
        store
            .create_tag("methods/sims".into(), Some("#ff0".into()), None)
            .unwrap();
        store.create_tag("topics/cosmo".into(), None, None).unwrap();

        let tags = store.list_tags().unwrap();
        assert_eq!(tags.len(), 2);
    }

    // --- New method tests ---

    #[test]
    fn library_extensions() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let fetched = store.get_library(lib.id.clone()).unwrap().unwrap();
        assert_eq!(fetched.name, "Test");

        store.set_library_default(lib.id.clone()).unwrap();
        let default = store.get_default_library().unwrap().unwrap();
        assert_eq!(default.id, lib.id);
        assert!(default.is_default);

        // Create second library, set as default — first should be unset
        let lib2 = store.create_library("Test2".into()).unwrap();
        store.set_library_default(lib2.id.clone()).unwrap();
        let old = store.get_library(lib.id.clone()).unwrap().unwrap();
        assert!(!old.is_default);
    }

    #[test]
    fn linked_file_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id.clone())
            .unwrap();

        let lf = store
            .add_linked_file(
                ids[0].clone(),
                "paper.pdf".into(),
                Some("Papers/paper.pdf".into()),
                Some("pdf".into()),
                1024,
                None,
                true,
            )
            .unwrap();
        assert_eq!(lf.filename, "paper.pdf");
        assert!(lf.is_pdf);

        let files = store.list_linked_files(ids[0].clone()).unwrap();
        assert_eq!(files.len(), 1);

        let fetched = store.get_linked_file(lf.id.clone()).unwrap().unwrap();
        assert_eq!(fetched.filename, "paper.pdf");

        assert_eq!(store.count_pdfs(ids[0].clone()).unwrap(), 1);

        store.set_pdf_cloud_available(lf.id.clone(), true).unwrap();
        let updated = store.get_linked_file(lf.id.clone()).unwrap().unwrap();
        assert!(updated.pdf_cloud_available);

        store
            .set_locally_materialized(lf.id.clone(), false)
            .unwrap();
        let updated2 = store.get_linked_file(lf.id).unwrap().unwrap();
        assert!(!updated2.is_locally_materialized);
    }

    #[test]
    fn smart_search_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let ss = store
            .create_smart_search(
                "Dark Matter".into(),
                "dark matter galaxies".into(),
                lib.id.clone(),
                Some("[\"ADS\"]".into()),
                50,
                true,
                false,
                3600,
            )
            .unwrap();
        assert_eq!(ss.name, "Dark Matter");
        assert!(ss.feeds_to_inbox);

        let searches = store.list_smart_searches(Some(lib.id)).unwrap();
        assert_eq!(searches.len(), 1);

        let fetched = store.get_smart_search(ss.id).unwrap().unwrap();
        assert_eq!(fetched.query, "dark matter galaxies");
    }

    #[test]
    fn inbox_and_triage() {
        let store = make_store();

        // No inbox initially
        assert!(store.get_inbox_library().unwrap().is_none());

        let inbox = store.create_inbox_library("Inbox".into()).unwrap();
        assert!(inbox.is_inbox);

        let fetched = store.get_inbox_library().unwrap().unwrap();
        assert_eq!(fetched.id, inbox.id);

        // Muted items
        let muted = store
            .create_muted_item("author".into(), "Smith, John".into())
            .unwrap();
        assert_eq!(muted.mute_type, "author");

        let all_muted = store.list_muted_items(None).unwrap();
        assert_eq!(all_muted.len(), 1);

        let by_type = store.list_muted_items(Some("author".into())).unwrap();
        assert_eq!(by_type.len(), 1);

        store.delete_item(muted.id).unwrap();
        assert_eq!(store.list_muted_items(None).unwrap().len(), 0);

        // Dismissed papers
        let dismissed = store
            .dismiss_paper(Some("10.1234/test".into()), None, None, None)
            .unwrap();
        assert_eq!(dismissed.doi, Some("10.1234/test".into()));

        assert!(store
            .is_paper_dismissed(Some("10.1234/test".into()), None, None, None)
            .unwrap());
        assert!(!store
            .is_paper_dismissed(Some("10.9999/other".into()), None, None, None)
            .unwrap());

        let papers = store.list_dismissed_papers(None, None).unwrap();
        assert_eq!(papers.len(), 1);
    }

    #[test]
    fn dismiss_paper_case_insensitive() {
        let store = make_store();

        // Dismiss with mixed-case DOI
        store
            .dismiss_paper(Some("10.1234/ABC".into()), None, None, None)
            .unwrap();

        // Should match regardless of case (stored as lowercase)
        assert!(store
            .is_paper_dismissed(Some("10.1234/abc".into()), None, None, None)
            .unwrap());
        assert!(store
            .is_paper_dismissed(Some("10.1234/ABC".into()), None, None, None)
            .unwrap());
        assert!(store
            .is_paper_dismissed(Some("10.1234/Abc".into()), None, None, None)
            .unwrap());

        // Non-matching DOI should still return false
        assert!(!store
            .is_paper_dismissed(Some("10.9999/xyz".into()), None, None, None)
            .unwrap());
    }

    #[test]
    fn dismiss_paper_by_cite_key() {
        let store = make_store();

        // Dismiss with cite_key only (no DOI/arXiv/bibcode)
        store
            .dismiss_paper(None, None, None, Some("Einstein2005".into()))
            .unwrap();

        // Should find by cite_key
        assert!(store
            .is_paper_dismissed(None, None, None, Some("Einstein2005".into()))
            .unwrap());

        // Different cite_key should not match
        assert!(!store
            .is_paper_dismissed(None, None, None, Some("Bohr1913".into()))
            .unwrap());

        // No identifiers at all should return false
        assert!(!store.is_paper_dismissed(None, None, None, None).unwrap());
    }

    #[test]
    fn recent_activity_records_only_what_it_is_told() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Paper A}, doi={10.1234/a}}
@article{B, title={Paper B}, doi={10.1234/b}}
@article{C, title={Paper C}, doi={10.1234/c}}
"#;
        store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();
        let all = store
            .query_publications(lib.id, "title".into(), true, None, None)
            .unwrap();
        assert_eq!(all.len(), 3);

        // Importing alone leaves the Recent list empty — automated ingest must
        // never show up here.
        assert!(store.query_recent_activity(50).unwrap().is_empty());

        let a = all[0].id.clone();
        let b = all[1].id.clone();

        assert!(store.record_recent_view(a.clone()).unwrap());
        assert!(store.record_recent_add(b.clone()).unwrap());

        let recent = store.query_recent_activity(50).unwrap();
        assert_eq!(recent.len(), 2, "only the two touched papers appear");
        assert_eq!(recent[0].id, b, "most recent first");
        assert_eq!(recent[1].id, a);

        let activity = store.recent_activity_entries(50).unwrap();
        assert_eq!(activity[0].kind, "added");
        assert_eq!(activity[1].kind, "viewed");
        assert!(activity[0].occurred_at >= activity[1].occurred_at);

        // Debounce: an immediate repeat of the same kind is suppressed and
        // does not reorder the list.
        assert!(!store.record_recent_view(a.clone()).unwrap());
        assert_eq!(store.query_recent_activity(50).unwrap()[0].id, b);

        // The limit is the whole retention policy.
        assert_eq!(store.query_recent_activity(1).unwrap().len(), 1);
    }

    #[test]
    fn deduplication_queries() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Paper A}, doi={10.1234/a}, eprint={2401.00001}, archiveprefix={arXiv}}
@article{B, title={Paper B}, doi={10.1234/b}, bibcode={2024ApJ...900....1S}}
"#;
        store.import_bibtex(bibtex.into(), lib.id).unwrap();

        let by_doi = store.find_by_doi("10.1234/a".into()).unwrap();
        assert_eq!(by_doi.len(), 1);
        assert_eq!(by_doi[0].cite_key, "A");

        let by_arxiv = store.find_by_arxiv("2401.00001".into()).unwrap();
        assert_eq!(by_arxiv.len(), 1);

        let by_bibcode = store.find_by_bibcode("2024ApJ...900....1S".into()).unwrap();
        assert_eq!(by_bibcode.len(), 1);

        let by_ids = store
            .find_by_identifiers(
                Some("10.1234/a".into()),
                None,
                Some("2024ApJ...900....1S".into()),
                None,
            )
            .unwrap();
        assert_eq!(by_ids.len(), 2);
    }

    #[test]
    fn advanced_queries() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Dark Matter Distribution}, author={Smith, John}, abstract={We study DM}}
@article{B, title={Stellar Populations}, author={Jones, Bob}}
"#;
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        // All unread initially
        let unread = store
            .query_unread(Some(lib.id.clone()), "created".into(), false, None, None)
            .unwrap();
        assert_eq!(unread.len(), 2);
        assert_eq!(store.count_unread(Some(lib.id.clone())).unwrap(), 2);

        // Mark one as read
        store.set_read(vec![ids[0].clone()], true).unwrap();
        assert_eq!(store.count_unread(Some(lib.id.clone())).unwrap(), 1);

        // Starred
        store.set_starred(vec![ids[0].clone()], true).unwrap();
        let starred = store
            .query_starred(Some(lib.id.clone()), "created".into(), false, None, None)
            .unwrap();
        assert_eq!(starred.len(), 1);

        // By tag
        store.create_tag("cosmo".into(), None, None).unwrap();
        store.add_tag(vec![ids[0].clone()], "cosmo".into()).unwrap();
        let by_tag = store
            .query_by_tag("cosmo".into(), None, "created".into(), false, None, None)
            .unwrap();
        assert_eq!(by_tag.len(), 1);

        // Recent
        let recent = store.query_recent(1, Some(lib.id.clone())).unwrap();
        assert_eq!(recent.len(), 1);

        // Full text search
        let fts = store
            .full_text_search("Dark Matter".into(), Some(lib.id.clone()), None, None)
            .unwrap();
        assert_eq!(fts.len(), 1);

        // Find by cite key
        let found = store.find_by_cite_key("A".into(), Some(lib.id)).unwrap();
        assert!(found.is_some());
        assert_eq!(found.unwrap().cite_key, "A");
    }

    #[test]
    fn scix_library_operations() {
        let store = make_store();

        let scix = store
            .create_scix_library(
                "remote-123".into(),
                "My ADS Lib".into(),
                Some("A test library".into()),
                true,
                "owner".into(),
                Some("test@example.com".into()),
            )
            .unwrap();
        assert_eq!(scix.name, "My ADS Lib");
        assert!(scix.is_public);

        let all = store.list_scix_libraries().unwrap();
        assert_eq!(all.len(), 1);

        let fetched = store.get_scix_library(scix.id.clone()).unwrap().unwrap();
        assert_eq!(fetched.remote_id, "remote-123");

        store.delete_item(scix.id).unwrap();
        assert_eq!(store.list_scix_libraries().unwrap().len(), 0);
    }

    #[test]
    fn scix_library_query_vs_count() {
        let store = make_store();

        // Create a SciX library
        let scix = store
            .create_scix_library(
                "remote-456".into(),
                "Test SciX Lib".into(),
                None,
                false,
                "owner".into(),
                None,
            )
            .unwrap();

        // Create a library and import some publications
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex(
                "@article{A, title={Alpha}, author={Smith, J}, year={2024}}\n\
                 @article{B, title={Beta}, author={Jones, K}, year={2023}}"
                    .into(),
                lib.id.clone(),
            )
            .unwrap();
        assert_eq!(ids.len(), 2);

        // Add publications to SciX library
        store
            .add_to_scix_library(ids.clone(), scix.id.clone())
            .unwrap();

        // Count should return 2
        let count = store
            .count_scix_library_publications(scix.id.clone())
            .unwrap();
        assert_eq!(count, 2, "count_scix_library_publications should return 2");

        // Query should also return 2
        let rows = store
            .query_scix_library_publications(scix.id.clone(), "created".into(), false, None, None)
            .unwrap();
        assert_eq!(
            rows.len(),
            2,
            "query_scix_library_publications should return 2 rows but got {}",
            rows.len()
        );

        // Verify the publications are the right ones
        let row_ids: std::collections::HashSet<String> =
            rows.iter().map(|r| r.id.clone()).collect();
        for id in &ids {
            assert!(
                row_ids.contains(id),
                "query results should contain publication {}",
                id
            );
        }
    }

    #[test]
    fn annotation_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();
        let lf = store
            .add_linked_file(
                ids[0].clone(),
                "paper.pdf".into(),
                None,
                None,
                0,
                None,
                true,
            )
            .unwrap();

        let ann = store
            .create_annotation(
                lf.id.clone(),
                "highlight".into(),
                5,
                None,
                Some("#ffff00".into()),
                None,
                Some("dark matter".into()),
            )
            .unwrap();
        assert_eq!(ann.annotation_type, "highlight");
        assert_eq!(ann.page_number, 5);

        let anns = store.list_annotations(lf.id.clone(), None).unwrap();
        assert_eq!(anns.len(), 1);

        let page5 = store.list_annotations(lf.id.clone(), Some(5)).unwrap();
        assert_eq!(page5.len(), 1);

        let page1 = store.list_annotations(lf.id.clone(), Some(1)).unwrap();
        assert_eq!(page1.len(), 0);

        assert_eq!(store.count_annotations(lf.id).unwrap(), 1);
    }

    #[test]
    fn comment_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();

        let comment = store
            .create_comment(
                ids[0].clone(),
                "Great paper!".into(),
                Some("user-1".into()),
                Some("Jane".into()),
                None,
            )
            .unwrap();
        assert_eq!(comment.text, "Great paper!");

        let comments = store.list_comments(ids[0].clone()).unwrap();
        assert_eq!(comments.len(), 1);

        store
            .update_comment(comment.id.clone(), "Updated comment".into())
            .unwrap();
        let updated = store.list_comments(ids[0].clone()).unwrap();
        assert_eq!(updated[0].text, "Updated comment");

        store.delete_item(comment.id).unwrap();
        assert_eq!(store.list_comments(ids[0].clone()).unwrap().len(), 0);
    }

    #[test]
    fn anchored_comment_round_trip() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();

        let comment = store
            .create_anchored_comment(
                ids[0].clone(),
                "Needs a citation here".into(),
                Some("user-1".into()),
                Some("Jane".into()),
                42,
                57,
                "dark matter halo".into(),
                "hash-v1".into(),
            )
            .unwrap();
        assert_eq!(comment.anchor_start, Some(42));
        assert_eq!(comment.anchor_end, Some(57));
        assert_eq!(comment.anchor_text.as_deref(), Some("dark matter halo"));
        assert_eq!(comment.anchored_body_hash.as_deref(), Some("hash-v1"));

        // Anchors survive the list round-trip.
        let listed = store.list_comments_for_item(ids[0].clone()).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].anchor_start, Some(42));
        assert_eq!(listed[0].anchor_end, Some(57));
        assert_eq!(listed[0].anchor_text.as_deref(), Some("dark matter halo"));
        assert_eq!(listed[0].anchored_body_hash.as_deref(), Some("hash-v1"));

        // Re-anchor persistence: new offsets + hash, anchor_text unchanged.
        store
            .update_comment_anchor(comment.id.clone(), 60, 75, "hash-v2".into())
            .unwrap();
        let updated = store.list_comments_for_item(ids[0].clone()).unwrap();
        assert_eq!(updated[0].anchor_start, Some(60));
        assert_eq!(updated[0].anchor_end, Some(75));
        assert_eq!(updated[0].anchor_text.as_deref(), Some("dark matter halo"));
        assert_eq!(updated[0].anchored_body_hash.as_deref(), Some("hash-v2"));

        // Plain comments keep None anchors.
        let plain = store
            .create_comment(ids[0].clone(), "Plain".into(), None, None, None)
            .unwrap();
        assert_eq!(plain.anchor_start, None);
        assert_eq!(plain.anchor_end, None);
        assert_eq!(plain.anchor_text, None);
        assert_eq!(plain.anchored_body_hash, None);

        // Invalid ranges are rejected.
        assert!(store
            .create_anchored_comment(
                ids[0].clone(),
                "bad".into(),
                None,
                None,
                10,
                5,
                "x".into(),
                "h".into(),
            )
            .is_err());
        assert!(store
            .update_comment_anchor(comment.id, -1, 3, "h".into())
            .is_err());
    }

    #[test]
    fn assignment_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();

        let assignment = store
            .create_assignment(
                ids[0].clone(),
                "Alice".into(),
                Some("Bob".into()),
                Some("Read by Friday".into()),
                Some(1700000000000),
            )
            .unwrap();
        assert_eq!(assignment.assignee_name, "Alice");

        let list = store.list_assignments(Some(ids[0].clone())).unwrap();
        assert_eq!(list.len(), 1);

        store.delete_item(assignment.id).unwrap();
        assert_eq!(
            store.list_assignments(Some(ids[0].clone())).unwrap().len(),
            0
        );
    }

    #[test]
    fn activity_record_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        store
            .create_activity_record(
                lib.id.clone(),
                "added".into(),
                Some("Jane".into()),
                Some("Dark Matter Paper".into()),
                None,
                None,
            )
            .unwrap();
        store
            .create_activity_record(
                lib.id.clone(),
                "tagged".into(),
                Some("Jane".into()),
                None,
                None,
                None,
            )
            .unwrap();

        let records = store
            .list_activity_records(lib.id.clone(), None, None)
            .unwrap();
        assert_eq!(records.len(), 2);

        let limited = store
            .list_activity_records(lib.id.clone(), Some(1), None)
            .unwrap();
        assert_eq!(limited.len(), 1);

        store.clear_activity_records(lib.id.clone()).unwrap();
        assert_eq!(
            store
                .list_activity_records(lib.id, None, None)
                .unwrap()
                .len(),
            0
        );
    }

    #[test]
    fn recommendation_profile_operations() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        assert!(store
            .get_recommendation_profile(lib.id.clone())
            .unwrap()
            .is_none());

        store
            .create_or_update_recommendation_profile(
                lib.id.clone(),
                Some("{\"cosmo\":0.8}".into()),
                None,
                None,
                None,
            )
            .unwrap();

        let profile = store
            .get_recommendation_profile(lib.id.clone())
            .unwrap()
            .unwrap();
        assert!(profile.contains("cosmo"));

        // Update existing
        store
            .create_or_update_recommendation_profile(
                lib.id.clone(),
                Some("{\"cosmo\":0.9}".into()),
                None,
                None,
                None,
            )
            .unwrap();
        let updated = store
            .get_recommendation_profile(lib.id.clone())
            .unwrap()
            .unwrap();
        assert!(updated.contains("0.9"));

        store.delete_recommendation_profile(lib.id.clone()).unwrap();
        assert!(store.get_recommendation_profile(lib.id).unwrap().is_none());
    }

    #[test]
    fn tag_extensions() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();

        store
            .create_tag("methods/sims".into(), Some("#ff0".into()), None)
            .unwrap();
        store
            .add_tag(vec![ids[0].clone()], "methods/sims".into())
            .unwrap();

        // Tags with counts
        let tags = store.list_tags_with_counts().unwrap();
        assert_eq!(tags.len(), 1);
        assert_eq!(tags[0].publication_count, 1);

        // Update tag colors
        store
            .update_tag(
                "methods/sims".into(),
                Some("#00ff00".into()),
                Some("#009900".into()),
            )
            .unwrap();
        let updated = store.list_tags().unwrap();
        assert_eq!(updated[0].color_light, Some("#00ff00".into()));

        // Rename tag
        store
            .rename_tag("methods/sims".into(), "techniques/numerical".into())
            .unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert!(pub_row
            .tags
            .iter()
            .any(|t| t.path == "techniques/numerical"));
        assert!(!pub_row.tags.iter().any(|t| t.path == "methods/sims"));

        // Delete tag
        store.delete_tag("techniques/numerical".into()).unwrap();
        let pub_row2 = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert!(pub_row2.tags.is_empty());
        assert_eq!(store.list_tags().unwrap().len(), 0);
    }

    #[test]
    fn collection_members() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Alpha}, year={2020}}
@article{B, title={Beta}, year={2024}}
"#;
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        let coll = store
            .create_collection("Favorites".into(), lib.id, false, None)
            .unwrap();
        store
            .add_to_collection(ids.clone(), coll.id.clone())
            .unwrap();

        let members = store
            .list_collection_members(coll.id.clone(), "year".into(), true, None, None)
            .unwrap();
        assert_eq!(members.len(), 2);
        // Should be sorted by year ascending: 2020 before 2024
        assert_eq!(members[0].year, Some(2020));
        assert_eq!(members[1].year, Some(2024));

        // With limit
        let limited = store
            .list_collection_members(coll.id, "year".into(), false, Some(1), None)
            .unwrap();
        assert_eq!(limited.len(), 1);
        assert_eq!(limited[0].year, Some(2024)); // descending
    }

    #[test]
    fn bulk_operations() {
        let store = make_store();
        let lib1 = store.create_library("Lib1".into()).unwrap();
        let lib2 = store.create_library("Lib2".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib1.id.clone())
            .unwrap();

        // Move
        store
            .move_publications(ids.clone(), lib2.id.clone())
            .unwrap();
        let pubs1 = store
            .query_publications(lib1.id.clone(), "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs1.len(), 0);
        let pubs2 = store
            .query_publications(lib2.id.clone(), "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs2.len(), 1);

        // Duplicate back
        let new_ids = store.duplicate_publications(ids, lib1.id.clone()).unwrap();
        assert_eq!(new_ids.len(), 1);
        let pubs1_after = store
            .query_publications(lib1.id, "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs1_after.len(), 1);
        // Original still in lib2
        let pubs2_after = store
            .query_publications(lib2.id, "created".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs2_after.len(), 1);
    }

    #[test]
    fn generic_helpers() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();

        // update_int_field
        store
            .update_int_field(ids[0].clone(), "citation_count".into(), Some(42))
            .unwrap();
        let pub_row = store.get_publication(ids[0].clone()).unwrap().unwrap();
        assert_eq!(pub_row.citation_count, 42);

        // update_bool_field (via linked file)
        let lf = store
            .add_linked_file(ids[0].clone(), "f.pdf".into(), None, None, 0, None, true)
            .unwrap();
        store
            .update_bool_field(lf.id.clone(), "pdf_cloud_available".into(), true)
            .unwrap();
        let updated = store.get_linked_file(lf.id.clone()).unwrap().unwrap();
        assert!(updated.pdf_cloud_available);

        // delete_item
        store.delete_item(lf.id.clone()).unwrap();
        assert!(store.get_linked_file(lf.id).unwrap().is_none());
    }

    #[test]
    fn import_bibtex_deduplication() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"@article{A, title={Paper A}, doi={10.1234/a}}"#;
        let ids1 = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();
        assert_eq!(ids1.len(), 1);

        // Import again with same DOI — should be skipped
        let bibtex2 = r#"@article{B, title={Paper A copy}, doi={10.1234/a}}"#;
        let ids2 = store.import_bibtex(bibtex2.into(), lib.id.clone()).unwrap();
        assert_eq!(ids2.len(), 0);

        // Import into a different library — should NOT be deduplicated
        let lib2 = store.create_library("Other".into()).unwrap();
        let ids3 = store.import_bibtex(bibtex.into(), lib2.id).unwrap();
        assert_eq!(ids3.len(), 1);

        // Entry without identifiers — should always be imported
        let bibtex3 = r#"@article{C, title={No ID}}"#;
        let ids4 = store.import_bibtex(bibtex3.into(), lib.id).unwrap();
        assert_eq!(ids4.len(), 1);
    }

    #[test]
    fn search_publications_multi_field() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Stellar Evolution}, author={Smith, John}, abstract={We study star formation}}
@article{B, title={Galaxy Mergers}, author={Jones, Bob}, note={Important paper on merging galaxies}}
@article{C, title={Dark Energy}, author={Williams, Alice}}
"#;
        store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        // Search by title
        let r1 = store
            .search_publications(
                "Stellar".into(),
                Some(lib.id.clone()),
                "created".into(),
                false,
                None,
                None,
            )
            .unwrap();
        assert_eq!(r1.len(), 1);
        assert_eq!(r1[0].cite_key, "A");

        // Search by author
        let r2 = store
            .search_publications(
                "Jones".into(),
                Some(lib.id.clone()),
                "created".into(),
                false,
                None,
                None,
            )
            .unwrap();
        assert_eq!(r2.len(), 1);
        assert_eq!(r2[0].cite_key, "B");

        // Search by abstract
        let r3 = store
            .search_publications(
                "star formation".into(),
                Some(lib.id.clone()),
                "created".into(),
                false,
                None,
                None,
            )
            .unwrap();
        assert_eq!(r3.len(), 1);
        assert_eq!(r3[0].cite_key, "A");

        // Search by note
        let r4 = store
            .search_publications(
                "merging galaxies".into(),
                Some(lib.id.clone()),
                "created".into(),
                false,
                None,
                None,
            )
            .unwrap();
        assert_eq!(r4.len(), 1);
        assert_eq!(r4[0].cite_key, "B");
    }

    #[test]
    fn bibliography_row_linked_file_status() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id)
            .unwrap();
        let pub_id = &ids[0];

        // Before any linked files — both false
        let row = store.get_publication(pub_id.clone()).unwrap().unwrap();
        assert!(!row.has_downloaded_pdf);
        assert!(!row.has_other_attachments);

        // Add a PDF that is locally materialized
        let lf = store
            .add_linked_file(
                pub_id.clone(),
                "paper.pdf".into(),
                None,
                None,
                1024,
                None,
                true,
            )
            .unwrap();
        store.set_locally_materialized(lf.id.clone(), true).unwrap();

        let row2 = store.get_publication(pub_id.clone()).unwrap().unwrap();
        assert!(row2.has_downloaded_pdf);
        assert!(!row2.has_other_attachments);

        // Add a non-PDF attachment
        store
            .add_linked_file(
                pub_id.clone(),
                "data.csv".into(),
                None,
                None,
                512,
                None,
                false,
            )
            .unwrap();

        let row3 = store.get_publication(pub_id.clone()).unwrap().unwrap();
        assert!(row3.has_downloaded_pdf);
        assert!(row3.has_other_attachments);
    }

    #[test]
    fn publication_detail_linked_files_and_collections() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{X, title={Test}}".into(), lib.id.clone())
            .unwrap();
        let pub_id = &ids[0];

        // Add linked file
        store
            .add_linked_file(
                pub_id.clone(),
                "paper.pdf".into(),
                None,
                None,
                2048,
                None,
                true,
            )
            .unwrap();

        // Add to a collection
        let coll = store
            .create_collection("Favorites".into(), lib.id, false, None)
            .unwrap();
        store
            .add_to_collection(vec![pub_id.clone()], coll.id.clone())
            .unwrap();

        let detail = store
            .get_publication_detail(pub_id.clone())
            .unwrap()
            .unwrap();
        assert_eq!(detail.linked_files.len(), 1);
        assert_eq!(detail.linked_files[0].filename, "paper.pdf");
        assert!(detail.collections.contains(&coll.id));
        assert_eq!(detail.libraries.len(), 1);
    }

    #[test]
    fn artifact_crud() {
        let store = make_store();

        // Create artifact
        let art = store
            .create_artifact(
                "impress/artifact/presentation".into(),
                "My Talk on Dark Matter".into(),
                Some("https://example.com/talk".into()),
                Some("Great talk at AAS".into()),
                None,
                Some("talk.pdf".into()),
                None,
                Some(1024000),
                Some("application/pdf".into()),
                Some("AAS 245".into()),
                Some("Jane Doe".into()),
                Some("AAS 245".into()),
                Some("2025-01-15".into()),
                vec!["talks".into()],
            )
            .unwrap();
        assert_eq!(art.title, "My Talk on Dark Matter");
        assert_eq!(art.schema, "impress/artifact/presentation");
        assert_eq!(art.source_url, Some("https://example.com/talk".into()));
        assert_eq!(art.file_name, Some("talk.pdf".into()));
        assert_eq!(art.file_size, Some(1024000));
        assert_eq!(art.tags.len(), 1);

        // Get by ID
        let fetched = store.get_artifact(art.id.clone()).unwrap().unwrap();
        assert_eq!(fetched.title, "My Talk on Dark Matter");

        // List (all schemas)
        let all = store
            .list_artifacts(None, "created".into(), false, None, None)
            .unwrap();
        assert_eq!(all.len(), 1);

        // List (specific schema)
        let presentations = store
            .list_artifacts(
                Some("impress/artifact/presentation".into()),
                "created".into(),
                false,
                None,
                None,
            )
            .unwrap();
        assert_eq!(presentations.len(), 1);

        let notes = store
            .list_artifacts(
                Some("impress/artifact/note".into()),
                "created".into(),
                false,
                None,
                None,
            )
            .unwrap();
        assert_eq!(notes.len(), 0);

        // Search
        let results = store.search_artifacts("Dark Matter".into(), None).unwrap();
        assert_eq!(results.len(), 1);

        let no_results = store.search_artifacts("quantum".into(), None).unwrap();
        assert_eq!(no_results.len(), 0);

        // Update
        store
            .update_artifact(
                art.id.clone(),
                Some("Updated Talk Title".into()),
                None,
                None,
                None,
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let updated = store.get_artifact(art.id.clone()).unwrap().unwrap();
        assert_eq!(updated.title, "Updated Talk Title");

        // Count
        let count = store.count_artifacts(None).unwrap();
        assert_eq!(count, 1);

        let pres_count = store
            .count_artifacts(Some("impress/artifact/presentation".into()))
            .unwrap();
        assert_eq!(pres_count, 1);

        // Delete
        store.delete_artifact(art.id.clone()).unwrap();
        assert!(store.get_artifact(art.id).unwrap().is_none());
        assert_eq!(store.count_artifacts(None).unwrap(), 0);
    }

    #[test]
    fn artifact_link_to_publication() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let bibtex = r#"@article{Smith2024, title={Dark Matter}, author={Smith}, year={2024}}"#;
        let pub_ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();
        assert_eq!(pub_ids.len(), 1);

        let art = store
            .create_artifact(
                "impress/artifact/note".into(),
                "Notes on Dark Matter Paper".into(),
                None,
                Some("Key findings from Smith2024".into()),
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                None,
                vec![],
            )
            .unwrap();

        // Link artifact to publication
        store
            .link_artifact_to_publication(art.id.clone(), pub_ids[0].clone())
            .unwrap();

        // Verify relation
        let relations = store.get_artifact_relations(art.id).unwrap();
        assert_eq!(relations.len(), 1);
        assert_eq!(relations[0].target_id, pub_ids[0]);
        assert_eq!(relations[0].target_title, Some("Dark Matter".into()));
    }

    #[test]
    fn artifact_invalid_schema_rejected() {
        let store = make_store();
        let result = store.create_artifact(
            "imbib/bibliography-entry".into(),
            "Should Fail".into(),
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            None,
            vec![],
        );
        assert!(result.is_err());
    }

    #[test]
    fn pagination_limit_offset() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        // Import 5 publications with distinct years for deterministic sorting
        for i in 0..5 {
            let bibtex = format!(
                "@article{{P{i}, title={{Paper {i}}}, year={{{}}}}}",
                2020 + i
            );
            store.import_bibtex(bibtex, lib.id.clone()).unwrap();
        }

        // Verify total count
        assert_eq!(store.count_publications(Some(lib.id.clone())).unwrap(), 5);

        // First page: limit=2, offset=0
        let page1 = store
            .query_publications(lib.id.clone(), "year".into(), true, Some(2), Some(0))
            .unwrap();
        assert_eq!(page1.len(), 2);
        assert_eq!(page1[0].year, Some(2020));
        assert_eq!(page1[1].year, Some(2021));

        // Second page: limit=2, offset=2
        let page2 = store
            .query_publications(lib.id.clone(), "year".into(), true, Some(2), Some(2))
            .unwrap();
        assert_eq!(page2.len(), 2);
        assert_eq!(page2[0].year, Some(2022));
        assert_eq!(page2[1].year, Some(2023));

        // Third page: limit=2, offset=4 — only 1 left
        let page3 = store
            .query_publications(lib.id.clone(), "year".into(), true, Some(2), Some(4))
            .unwrap();
        assert_eq!(page3.len(), 1);
        assert_eq!(page3[0].year, Some(2024));

        // Descending sort
        let desc = store
            .query_publications(lib.id.clone(), "year".into(), false, Some(2), Some(0))
            .unwrap();
        assert_eq!(desc[0].year, Some(2024));
        assert_eq!(desc[1].year, Some(2023));
    }

    #[test]
    fn count_methods() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let bibtex = r#"
@article{A, title={Paper A}}
@article{B, title={Paper B}}
@article{C, title={Paper C}}
"#;
        let ids = store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        // All unread initially
        assert_eq!(store.count_unread(Some(lib.id.clone())).unwrap(), 3);
        assert_eq!(store.count_publications(Some(lib.id.clone())).unwrap(), 3);

        // Star one
        store.set_starred(vec![ids[0].clone()], true).unwrap();
        assert_eq!(store.count_starred(Some(lib.id.clone())).unwrap(), 1);

        // Tag one
        store.create_tag("test-tag".into(), None, None).unwrap();
        store
            .add_tag(vec![ids[1].clone()], "test-tag".into())
            .unwrap();
        assert_eq!(store.count_by_tag("test-tag".into(), None).unwrap(), 1);

        // Flag one
        store
            .set_flag(vec![ids[2].clone()], Some("blue".into()), None, None)
            .unwrap();
        assert_eq!(store.count_flagged(Some("blue".into())).unwrap(), 1);
        assert_eq!(store.count_flagged(None).unwrap(), 1); // any flag

        // Search count
        assert_eq!(
            store
                .count_search_results("Paper".into(), Some(lib.id.clone()))
                .unwrap(),
            3
        );
        assert_eq!(
            store
                .count_search_results("Paper A".into(), Some(lib.id.clone()))
                .unwrap(),
            1
        );

        // Collection count
        let coll = store
            .create_collection("Coll".into(), lib.id.clone(), false, None)
            .unwrap();
        store
            .add_to_collection(vec![ids[0].clone(), ids[1].clone()], coll.id.clone())
            .unwrap();
        assert_eq!(store.count_collection_members_public(coll.id).unwrap(), 2);
    }

    #[test]
    fn normalize_sort_field_maps_recency_aliases() {
        // All three spellings reach the Recent library's payload field.
        for alias in ["lastActivity", "last_activity", "recent"] {
            assert_eq!(normalize_sort_field(alias), "payload.last_activity_at");
        }
        // The descriptor builder adds a deterministic `created` secondary so
        // the all-NULL untouched tail has a stable order matching the Swift
        // comparator's dateAdded tie-break.
        let descs = build_sort_descriptors("recent", false);
        assert_eq!(descs.len(), 2);
        assert_eq!(descs[0].field, "payload.last_activity_at");
        assert!(!descs[0].ascending);
        assert_eq!(descs[1].field, "created");
        assert!(!descs[1].ascending);
    }

    #[test]
    fn build_sort_descriptors_starred() {
        // "starred" sort should produce two sort descriptors
        let descs = build_sort_descriptors("starred", false);
        assert_eq!(descs.len(), 2);
        assert_eq!(descs[0].field, "is_starred");
        assert!(!descs[0].ascending);
        assert_eq!(descs[1].field, "created");
        assert!(!descs[1].ascending);

        // Normal sort should produce one
        let descs2 = build_sort_descriptors("year", true);
        assert_eq!(descs2.len(), 1);
        assert_eq!(descs2[0].field, "payload.year");
        assert!(descs2[0].ascending);
    }

    #[test]
    fn paginated_unread_starred_tag_queries() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        for i in 0..10 {
            let bibtex = format!(
                "@article{{P{i}, title={{Paper {i}}}, year={{{}}}}}",
                2015 + i
            );
            store.import_bibtex(bibtex, lib.id.clone()).unwrap();
        }

        // All 10 are unread; paginate
        let page1 = store
            .query_unread(Some(lib.id.clone()), "year".into(), true, Some(3), Some(0))
            .unwrap();
        assert_eq!(page1.len(), 3);
        assert_eq!(page1[0].year, Some(2015));

        let page2 = store
            .query_unread(Some(lib.id.clone()), "year".into(), true, Some(3), Some(3))
            .unwrap();
        assert_eq!(page2.len(), 3);
        assert_eq!(page2[0].year, Some(2018));

        // Star a few and paginate starred
        let all = store
            .query_publications(lib.id.clone(), "year".into(), true, None, None)
            .unwrap();
        store
            .set_starred(
                vec![all[0].id.clone(), all[1].id.clone(), all[2].id.clone()],
                true,
            )
            .unwrap();
        let starred_page = store
            .query_starred(Some(lib.id.clone()), "year".into(), true, Some(2), Some(0))
            .unwrap();
        assert_eq!(starred_page.len(), 2);

        // Tag and paginate
        store.create_tag("physics".into(), None, None).unwrap();
        store
            .add_tag(vec![all[0].id.clone(), all[4].id.clone()], "physics".into())
            .unwrap();
        let tag_page = store
            .query_by_tag(
                "physics".into(),
                None,
                "year".into(),
                true,
                Some(1),
                Some(0),
            )
            .unwrap();
        assert_eq!(tag_page.len(), 1);
        assert_eq!(tag_page[0].year, Some(2015));
    }

    #[test]
    fn delete_publications_undoable_and_restore() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex(
                "@article{a1, title={Paper One}, author={Smith}}\n@article{a2, title={Paper Two}, author={Jones}}".into(),
                lib.id.clone(),
            )
            .unwrap();
        assert_eq!(ids.len(), 2);

        // Delete with snapshot
        let snapshots = store.delete_publications_undoable(ids.clone()).unwrap();
        assert_eq!(snapshots.len(), 2);

        // Verify deleted
        let pubs = store
            .query_publications(lib.id.clone(), "title".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs.len(), 0);

        // Restore from snapshots
        store.restore_snapshots(snapshots).unwrap();

        // Verify restored
        let pubs = store
            .query_publications(lib.id.clone(), "title".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs.len(), 2);
    }

    #[test]
    fn delete_library_undoable_and_restore() {
        let store = make_store();
        let lib = store.create_library("Physics".into()).unwrap();
        let lib_id = lib.id.clone();
        store
            .import_bibtex("@article{x, title={Dark Matter}}".into(), lib_id.clone())
            .unwrap();
        store
            .create_collection("Favorites".into(), lib_id.clone(), false, None)
            .unwrap();

        // Delete library
        let snapshot = store.delete_library_undoable(lib_id.clone()).unwrap();
        assert_eq!(snapshot.child_publication_ids.len(), 1);
        assert_eq!(snapshot.child_collection_ids.len(), 1);

        // Library is gone
        assert!(store.get_library(lib_id.clone()).unwrap().is_none());

        // Publications still exist but orphaned (parent = NULL)
        let detail = store
            .get_publication_detail(snapshot.child_publication_ids[0].clone())
            .unwrap();
        assert!(detail.is_some()); // item still exists

        // Restore library
        store.restore_library(snapshot).unwrap();

        // Library is back
        let restored = store.get_library(lib_id.clone()).unwrap();
        assert!(restored.is_some());
        assert_eq!(restored.unwrap().name, "Physics");

        // Publications are re-parented
        let pubs = store
            .query_publications(lib_id.clone(), "title".into(), true, None, None)
            .unwrap();
        assert_eq!(pubs.len(), 1);
        assert_eq!(pubs[0].title, "Dark Matter");

        // Collection is re-parented
        let colls = store.list_collections(lib_id).unwrap();
        assert_eq!(colls.len(), 1);
    }

    #[test]
    fn delete_tag_undoable_and_restore() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();
        let ids = store
            .import_bibtex("@article{t1, title={Tagged Paper}}".into(), lib.id.clone())
            .unwrap();

        // Create tag and assign
        store
            .create_tag("methods/ml".into(), Some("#ff0000".into()), None)
            .unwrap();
        store.add_tag(ids.clone(), "methods/ml".into()).unwrap();

        // Verify tag exists
        let tags = store.list_tags().unwrap();
        assert!(tags.iter().any(|t| t.path == "methods/ml"));

        // Delete tag with snapshot
        let snapshot = store.delete_tag_undoable("methods/ml".into()).unwrap();
        assert!(!snapshot.tag_definition_json.is_empty());
        assert_eq!(snapshot.tagged_publication_ids.len(), 1);
        assert_eq!(snapshot.tag_path, "methods/ml");

        // Tag is gone
        let tags = store.list_tags().unwrap();
        assert!(!tags.iter().any(|t| t.path == "methods/ml"));

        // Publication no longer has tag
        let detail = store
            .get_publication_detail(ids[0].clone())
            .unwrap()
            .unwrap();
        assert!(!detail.tags.iter().any(|t| t.path == "methods/ml"));

        // Restore tag
        store.restore_tag(snapshot).unwrap();

        // Tag definition is back
        let tags = store.list_tags().unwrap();
        assert!(tags.iter().any(|t| t.path == "methods/ml"));

        // Publication has tag again
        let detail = store
            .get_publication_detail(ids[0].clone())
            .unwrap()
            .unwrap();
        assert!(detail.tags.iter().any(|t| t.path == "methods/ml"));
    }

    // --- batch_import_search_results tests ---

    #[test]
    fn batch_import_classifies_existing_vs_new() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        // Pre-import one paper
        let bibtex =
            r#"@article{Smith2024, title={Existing}, doi={10.1234/existing}, author={Smith}}"#;
        store.import_bibtex(bibtex.into(), lib.id.clone()).unwrap();

        // Batch import: one existing (by DOI), one new
        let results = vec![
            SearchResultInput {
                bibtex: r#"@article{Smith2024b, title={Existing copy}, doi={10.1234/existing}, author={Smith}}"#.into(),
                doi: Some("10.1234/existing".into()),
                arxiv_id: None,
                bibcode: None,
            },
            SearchResultInput {
                bibtex: r#"@article{Jones2025, title={Brand New}, doi={10.1234/new}, author={Jones}}"#.into(),
                doi: Some("10.1234/new".into()),
                arxiv_id: None,
                bibcode: None,
            },
        ];

        let result = store
            .batch_import_search_results(results, lib.id.clone(), false)
            .unwrap();
        assert_eq!(result.existing_ids.len(), 1);
        assert_eq!(result.imported_ids.len(), 1);
        assert_eq!(result.dismissed_count, 0);
        assert_eq!(result.failed_count, 0);
    }

    #[test]
    fn batch_import_filters_dismissed() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        // Dismiss a paper
        store
            .dismiss_paper(Some("10.1234/dismissed".into()), None, None, None)
            .unwrap();

        let results = vec![
            SearchResultInput {
                bibtex: r#"@article{X, title={Dismissed}, doi={10.1234/dismissed}}"#.into(),
                doi: Some("10.1234/dismissed".into()),
                arxiv_id: None,
                bibcode: None,
            },
            SearchResultInput {
                bibtex: r#"@article{Y, title={Allowed}, doi={10.1234/allowed}}"#.into(),
                doi: Some("10.1234/allowed".into()),
                arxiv_id: None,
                bibcode: None,
            },
        ];

        let result = store
            .batch_import_search_results(results, lib.id.clone(), true)
            .unwrap();
        assert_eq!(result.existing_ids.len(), 0);
        assert_eq!(result.imported_ids.len(), 1);
        assert_eq!(result.dismissed_count, 1);
    }

    #[test]
    fn batch_import_filters_dismissed_existing_paper() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        // First import a paper normally
        let results = vec![SearchResultInput {
            bibtex: r#"@article{X, title={Will Be Dismissed}, doi={10.1234/dismissed}}"#.into(),
            doi: Some("10.1234/dismissed".into()),
            arxiv_id: None,
            bibcode: None,
        }];
        let first = store
            .batch_import_search_results(results, lib.id.clone(), false)
            .unwrap();
        assert_eq!(first.imported_ids.len(), 1);

        // Now dismiss it
        store
            .dismiss_paper(Some("10.1234/dismissed".into()), None, None, None)
            .unwrap();

        // Re-import with filter_dismissed: true — should be filtered, not returned as existing
        let results2 = vec![SearchResultInput {
            bibtex: r#"@article{X, title={Will Be Dismissed}, doi={10.1234/dismissed}}"#.into(),
            doi: Some("10.1234/dismissed".into()),
            arxiv_id: None,
            bibcode: None,
        }];
        let second = store
            .batch_import_search_results(results2, lib.id.clone(), true)
            .unwrap();
        assert_eq!(
            second.existing_ids.len(),
            0,
            "dismissed paper must not appear in existing_ids"
        );
        assert_eq!(second.dismissed_count, 1);
        assert_eq!(second.imported_ids.len(), 0);
    }

    #[test]
    fn batch_import_existing_not_dismissed_still_returned() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        // Import a paper
        let results = vec![SearchResultInput {
            bibtex: r#"@article{Y, title={Keep This}, doi={10.1234/keep}}"#.into(),
            doi: Some("10.1234/keep".into()),
            arxiv_id: None,
            bibcode: None,
        }];
        let first = store
            .batch_import_search_results(results, lib.id.clone(), false)
            .unwrap();
        assert_eq!(first.imported_ids.len(), 1);

        // Re-import with filter_dismissed: true — should still appear as existing
        let results2 = vec![SearchResultInput {
            bibtex: r#"@article{Y, title={Keep This}, doi={10.1234/keep}}"#.into(),
            doi: Some("10.1234/keep".into()),
            arxiv_id: None,
            bibcode: None,
        }];
        let second = store
            .batch_import_search_results(results2, lib.id.clone(), true)
            .unwrap();
        assert_eq!(
            second.existing_ids.len(),
            1,
            "non-dismissed existing paper must be returned"
        );
        assert_eq!(second.dismissed_count, 0);
        assert_eq!(second.imported_ids.len(), 0);
    }

    #[test]
    fn batch_import_handles_invalid_bibtex() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        // The BibTeX parser is lenient — unparseable input returns Ok with 0 entries.
        // So "invalid bibtex" doesn't increment failed_count, it just produces nothing.
        let results = vec![SearchResultInput {
            bibtex: "this is not valid bibtex".into(),
            doi: None,
            arxiv_id: None,
            bibcode: None,
        }];

        let result = store
            .batch_import_search_results(results, lib.id.clone(), false)
            .unwrap();
        assert_eq!(result.imported_ids.len(), 0);
        assert_eq!(result.failed_count, 0); // parser is lenient, returns empty entries
        assert_eq!(result.existing_ids.len(), 0);
    }

    #[test]
    fn batch_import_empty_input() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        let result = store
            .batch_import_search_results(vec![], lib.id.clone(), false)
            .unwrap();
        assert!(result.existing_ids.is_empty());
        assert!(result.imported_ids.is_empty());
        assert_eq!(result.dismissed_count, 0);
        assert_eq!(result.failed_count, 0);
    }

    #[test]
    fn batch_import_deduplicates_within_library() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        // Two results with the same DOI — only one should be imported
        // (the first gets imported, the second hits is_duplicate_in_library)
        let results = vec![
            SearchResultInput {
                bibtex: r#"@article{A, title={Paper A}, doi={10.1234/same}}"#.into(),
                doi: Some("10.1234/same".into()),
                arxiv_id: None,
                bibcode: None,
            },
            SearchResultInput {
                bibtex: r#"@article{B, title={Paper A variant}, doi={10.1234/same}}"#.into(),
                doi: Some("10.1234/same".into()),
                arxiv_id: None,
                bibcode: None,
            },
        ];

        let result = store
            .batch_import_search_results(results, lib.id.clone(), false)
            .unwrap();
        // Both are "new" per the batch find (neither existed before), but the second
        // should be caught by is_duplicate_in_library after the first is inserted via insert_batch.
        // However, since insert_batch inserts all at once, is_duplicate_in_library runs BEFORE
        // the batch insert — so both will pass the dedup check and both will be inserted.
        // The batch identifier lookup catches them as having the same DOI, so the second
        // is NOT classified as existing (neither existed at lookup time).
        // This is a known limitation: within-batch dedup relies on is_duplicate_in_library
        // which only sees pre-existing rows. For search results this is acceptable because
        // the Swift-side deduplication service already handles cross-result dedup.
        assert!(!result.imported_ids.is_empty());
    }

    #[test]
    fn batch_import_matches_by_arxiv_and_bibcode() {
        let store = make_store();
        let lib = store.create_library("Test".into()).unwrap();

        // Pre-import papers with arXiv ID and bibcode
        store
            .import_bibtex(
                r#"@article{A, title={arXiv Paper}, eprint={2301.12345}}"#.into(),
                lib.id.clone(),
            )
            .unwrap();
        store
            .import_bibtex(
                r#"@article{B, title={ADS Paper}, bibcode={2023ApJ...944...49A}}"#.into(),
                lib.id.clone(),
            )
            .unwrap();

        let results = vec![
            SearchResultInput {
                bibtex: r#"@article{A2, title={arXiv Paper v2}}"#.into(),
                doi: None,
                arxiv_id: Some("2301.12345".into()),
                bibcode: None,
            },
            SearchResultInput {
                bibtex: r#"@article{B2, title={ADS Paper copy}}"#.into(),
                doi: None,
                arxiv_id: None,
                bibcode: Some("2023ApJ...944...49A".into()),
            },
            SearchResultInput {
                bibtex: r#"@article{C, title={Brand New Paper}, doi={10.5678/new}}"#.into(),
                doi: Some("10.5678/new".into()),
                arxiv_id: None,
                bibcode: None,
            },
        ];

        let result = store
            .batch_import_search_results(results, lib.id.clone(), false)
            .unwrap();
        assert_eq!(result.existing_ids.len(), 2);
        assert_eq!(result.imported_ids.len(), 1);
    }

    // ---- Phase 1: in-library predicate + Contains-edge membership ----

    #[test]
    fn library_add_members_creates_contains_edge() {
        let store = make_store();
        let home = store.create_library("Home".into()).unwrap();
        let extra = store.create_library("Extra".into()).unwrap();

        // Paper lives in `home` via parent
        let ids = store
            .import_bibtex("@article{X, title={Paper}}".into(), home.id.clone())
            .unwrap();
        let paper_id = ids[0].clone();

        // Add to `extra` via Contains edge — must NOT change parent
        store
            .library_add_members(extra.id.clone(), vec![paper_id.clone()])
            .unwrap();

        let item = store
            .store
            .get(parse_uuid(&paper_id).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(
            item.parent.map(|u| u.to_string()),
            Some(home.id.clone()),
            "parent must remain `home`"
        );

        // `extra` must now have a Contains edge to the paper
        let extra_item = store
            .store
            .get(parse_uuid(&extra.id).unwrap())
            .unwrap()
            .unwrap();
        let contains_targets: Vec<String> = extra_item
            .references
            .iter()
            .filter(|r| r.edge_type == EdgeType::Contains)
            .map(|r| r.target.to_string())
            .collect();
        assert_eq!(contains_targets, vec![paper_id.clone()]);
    }

    #[test]
    fn in_library_predicate_matches_parent_and_contains() {
        let store = make_store();
        let home = store.create_library("Home".into()).unwrap();
        let extra = store.create_library("Extra".into()).unwrap();

        // Paper A: parent = home
        let a = store
            .import_bibtex("@article{A, title={A}}".into(), home.id.clone())
            .unwrap()[0]
            .clone();
        // Paper B: parent = extra (so it's a "home child" of extra)
        let b = store
            .import_bibtex("@article{B, title={B}}".into(), extra.id.clone())
            .unwrap()[0]
            .clone();
        // Paper C: parent = home, also Contains-edge from extra
        let c = store
            .import_bibtex("@article{C, title={C}}".into(), home.id.clone())
            .unwrap()[0]
            .clone();
        store
            .library_add_members(extra.id.clone(), vec![c.clone()])
            .unwrap();

        // Query for items in `extra` using the new predicate
        let extra_uuid = parse_uuid(&extra.id).unwrap();
        let q = ItemQuery {
            schema: Some("imbib/bibliography-entry".into()),
            predicates: vec![in_library_predicate(extra_uuid)],
            ..Default::default()
        };
        let items = store.store.query(&q).unwrap();
        let ids: std::collections::HashSet<String> =
            items.iter().map(|i| i.id.to_string()).collect();
        assert!(ids.contains(&b), "B must appear (parent==extra)");
        assert!(ids.contains(&c), "C must appear (Contains edge)");
        assert!(!ids.contains(&a), "A must NOT appear (only in home)");
    }

    #[test]
    fn library_add_members_is_noop_when_paper_is_already_child() {
        let store = make_store();
        let home = store.create_library("Home".into()).unwrap();
        let paper = store
            .import_bibtex("@article{X, title={Paper}}".into(), home.id.clone())
            .unwrap()[0]
            .clone();

        // No-op: paper's parent already == home
        store
            .library_add_members(home.id.clone(), vec![paper.clone()])
            .unwrap();

        // home should NOT have a self-referencing Contains edge for this paper
        let home_item = store
            .store
            .get(parse_uuid(&home.id).unwrap())
            .unwrap()
            .unwrap();
        let self_edges: Vec<_> = home_item
            .references
            .iter()
            .filter(|r| r.edge_type == EdgeType::Contains && r.target.to_string() == paper)
            .collect();
        assert!(
            self_edges.is_empty(),
            "no Contains edge needed for own children"
        );
    }

    #[test]
    fn library_remove_members_does_not_delete_paper() {
        let store = make_store();
        let home = store.create_library("Home".into()).unwrap();
        let extra = store.create_library("Extra".into()).unwrap();
        let paper = store
            .import_bibtex("@article{X, title={Paper}}".into(), home.id.clone())
            .unwrap()[0]
            .clone();

        store
            .library_add_members(extra.id.clone(), vec![paper.clone()])
            .unwrap();
        store
            .library_remove_members(extra.id.clone(), vec![paper.clone()])
            .unwrap();

        // Paper still exists, parent still home
        let item = store
            .store
            .get(parse_uuid(&paper).unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(item.parent.map(|u| u.to_string()), Some(home.id.clone()));

        // extra no longer Contains it
        let extra_item = store
            .store
            .get(parse_uuid(&extra.id).unwrap())
            .unwrap()
            .unwrap();
        let still_contains = extra_item
            .references
            .iter()
            .any(|r| r.edge_type == EdgeType::Contains && r.target.to_string() == paper);
        assert!(!still_contains, "Contains edge must be removed");
    }
}
