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

mod ai;

pub use ai::{
    AiAttachment, AiBlobAvailability, AiConversationDraft, AiModelHostStatus, AiModelRow,
    AiQueuedTurn, AiWorkerStatus, SharedAiStore,
};

use impress_core::{
    collection_ops::{self, CollectionSchemaBinding},
    item::{ActorKind, FlagState, Item, ItemId, Priority, Value, Visibility},
    operation::{OperationIntent, OperationSpec, OperationType, RetentionTier},
    query::{ItemQuery, Predicate, SortDescriptor},
    reference::{EdgeType, TypedReference},
    schemas::watched_folder::VOLUME_STATE_UNAVAILABLE,
    sqlite_store::SqliteItemStore,
    store::{FieldMutation, ItemStore, StoreError},
    watched_folder_ops,
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

// ─── Collection kernel DTOs (ADR-0022 D1/D2) ─────────────────────────────────

/// Which collection schema the kernel operates on.
///
/// ADR-0022 D2 unifies the API before the data: `Publication`, `Manuscript`
/// and `Figure` front the schemas that already exist, `Generic` is the new
/// `collection@1.0.0` that can hold any record kind.
#[cfg_attr(feature = "native", derive(uniffi::Enum))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SharedCollectionBinding {
    /// imbib publication collections (`imbib/collection`).
    Publication,
    /// imprint manuscript folders (`manuscript-collection`).
    Manuscript,
    /// implore figure folders (`figure-collection`).
    Figure,
    /// The generic `collection@1.0.0` kernel schema.
    Generic,
}

/// One flat collection row. Build the tree from `parent_id` (`nil` = root);
/// `parent_id` is the schema's payload tree ref (or, for figure folders, the
/// envelope parent) — never the owning library.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedCollectionRow {
    /// Lowercase UUID string.
    pub id: String,
    pub name: String,
    /// Lowercase UUID string of the parent collection, `nil` for a root.
    pub parent_id: Option<String>,
    pub sort_order: i64,
    /// Record-kind scope ("publication", "manuscript", "any", …) for schemas
    /// that carry one; `nil` for the per-kind legacy schemas.
    pub kind_scope: Option<String>,
    /// Lowercase UUID string of the OWNING CONTAINER — imbib's library — for
    /// bindings that have a container axis (ADR-0022 C2); `nil` for manuscript
    /// folders, figure folders and the generic binding, whose collections are
    /// global. NEVER the tree parent: that is `parent_id`.
    pub container_id: Option<String>,
    /// Is this a SMART (query-defined) collection? The per-row read-only
    /// predicate imbib's sidebar gates Rename / New Subcollection on, leaving
    /// Delete. `false` for bindings whose schema has no such field.
    pub is_smart: bool,
    /// Member count — for a Contains-edge binding, the outgoing `Contains`-edge
    /// count (exactly imbib-core `list_collections`' `publication_count`, so a
    /// tree read is a drop-in for it); for an envelope-membership binding, the
    /// filed-children count.
    pub member_count: i64,
}

/// The value the mutated field held BEFORE a single-field structural verb ran
/// — everything an undo stack needs to invert it.
///
/// An enum rather than three optional fields because `reparent`'s prior value
/// is legitimately "was a root", which `nil` could not distinguish from "no
/// prior value recorded".
#[cfg_attr(feature = "native", derive(uniffi::Enum))]
#[derive(Debug, Clone, PartialEq)]
pub enum SharedCollectionPrior {
    /// Prior `name`, from `collection_rename`. Undo: rename back to it.
    Name { name: String },
    /// Prior `sort_order`, from `collection_reorder`. Undo: reorder back.
    SortOrder { sort_order: i64 },
    /// Prior tree parent, from `collection_reparent`; `nil` = it was a root.
    /// Undo: reparent back to it.
    ///
    /// Means "the owning container did NOT move", so its inverse must leave the
    /// container alone — a same-library reparent writes one field, and undoing
    /// it must not start writing an envelope the forward move never touched.
    Parent { parent_id: Option<String> },
    /// Prior tree parent AND prior owning container, from a
    /// `collection_reparent_in` that CROSSED containers (ADR-0022 C2 — imbib's
    /// cross-library collection move, which was two hand-written Swift writes).
    /// Undo: `collection_reparent_in(id, parent_id, container_id)`.
    ParentInContainer {
        parent_id: Option<String>,
        container_id: Option<String>,
    },
}

/// The result of `collection_rename` / `collection_reorder` /
/// `collection_reparent`: the row as it now stands, plus the prior value.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedCollectionMutation {
    /// The collection AFTER the change.
    pub row: SharedCollectionRow,
    /// The value the changed field held BEFORE.
    pub prior: SharedCollectionPrior,
}

/// Everything needed to put a deleted collection back exactly as it was.
/// Returned by `collection_delete`, consumed by `collection_restore`.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedDeletedCollection {
    /// The collection as it was, including its original id.
    pub row: SharedCollectionRow,
    /// The envelope `parent` the row carried — the OWNING LIBRARY for
    /// payload-tree bindings, the same as `row.parent_id` for figure folders.
    pub envelope_parent_id: Option<String>,
    /// Members whose membership the delete dropped (`Contains` edges gone by
    /// FK CASCADE, envelope-filed items unfiled by FK SET NULL). Never
    /// sub-collections — those are tree nodes.
    pub member_ids: Vec<String>,
    /// Direct child collections whose parent pointer the delete invalidated.
    /// `collection_restore` re-attaches all of them.
    pub child_collection_ids: Vec<String>,
}

// ─── Watched-folder DTOs (ADR-0023 W2) ───────────────────────────────────────
//
// FFI mirrors of `impress_core::watched_folder_ops`' DTOs, in the same
// relationship the `SharedCollection*` records above have to
// `impress_core::collection_ops`: the kernel owns the semantics, these carry
// them across UniFFI, and the conversion is one `From` impl per type.
//
// Why mirrors and not the kernel types directly: `#[derive(uniffi::Record)]`
// cannot be applied to a foreign type, and the kernel's DTOs also carry
// `schemars` derives this side has no use for. The field names are kept
// byte-identical so a reader can diff the two files.

/// One file the watcher discovered, on its way in.
///
/// `content_hash` / `mtime` / `size_bytes` are optional because Swift usually
/// has them already (the metadata query supplies them) and the kernel reads
/// them off disk when it does not. Passing a hash is trusted — the kernel does
/// not re-read the file to check.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedDiscoveredFile {
    /// Absolute POSIX path.
    pub path: String,
    pub content_hash: Option<String>,
    /// ISO-8601.
    pub mtime: Option<String>,
    pub size_bytes: Option<i64>,
    /// Base64 of a per-file security-scoped bookmark, for reference-in-place
    /// records that must reopen the file after a relaunch (ADR-0023 D4).
    pub bookmark_base64: Option<String>,
}

/// A watched folder as the store holds it.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedWatchedFolder {
    pub id: String,
    pub path: String,
    /// The record kind whose `FileDiscoveryCapability` decides what counts —
    /// `publication`, `manuscript`, `figure`, `message`.
    pub kind_scope: String,
    pub display_name: String,
    pub enabled: bool,
    pub recursive: bool,
    /// `indexed` | `unindexed` | `scan-on-demand` | `unavailable`, or nil when
    /// the platform has not declared one yet (ADR-0023 D6).
    pub volume_state: Option<String>,
    pub bookmark_base64: Option<String>,
    pub last_scan_at: Option<String>,
    pub last_scan_file_count: i64,
    pub last_scan_new_count: i64,
    pub last_scan_changed_count: i64,
    pub last_scan_missing_count: i64,
    pub last_scan_duration_ms: i64,
}

/// A discovered file as the store holds it — the provenance row.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedWatchedFile {
    pub id: String,
    pub watched_folder_id: String,
    pub path: String,
    pub content_hash: String,
    /// `present` | `missing`. A missing file keeps its row and its
    /// attributions — ADR-0023 D4 never deletes one.
    pub state: String,
    pub kind_scope: String,
    pub mtime: Option<String>,
    pub size_bytes: i64,
    pub first_seen_at: Option<String>,
    pub last_seen_at: Option<String>,
    pub missing_since: Option<String>,
    /// Store rows this file produced. Empty AND `produced_at == nil` means the
    /// fan-out has not run; empty WITH a `produced_at` means it ran and
    /// produced nothing.
    pub produced_ids: Vec<String>,
    pub produced_at: Option<String>,
    /// True when the content moved on after the last fan-out — the queue the
    /// app's importer drains.
    pub needs_reimport: bool,
}

/// What one file's pass through discovery did.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedDiscoveredFileOutcome {
    pub id: String,
    pub path: String,
    /// `created` | `changed` | `unchanged` | `restored`.
    ///
    /// The first, second and fourth are the ones whose file the app's importer
    /// must run on again; `unchanged` wrote nothing at all.
    pub action: String,
    pub content_hash: String,
}

/// A file discovery declined to record, and why. Never silently dropped.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedSkippedFile {
    pub path: String,
    pub reason: String,
}

/// What one discovery batch did (ADR-0023 D4).
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedDiscoveryReport {
    pub watched_folder_id: String,
    pub kind_scope: String,
    pub created: u32,
    pub changed: u32,
    /// Files whose hash is identical — **these wrote nothing at all**.
    pub unchanged: u32,
    pub restored: u32,
    /// Write-gate batches used (`ceil(files / 500)`), for the D7 burst budget.
    pub batches: u32,
    pub files: Vec<SharedDiscoveredFileOutcome>,
    pub skipped: Vec<SharedSkippedFile>,
}

/// What the terminal sweep of a scan found.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedWatchedScanReport {
    pub watched_folder_id: String,
    pub examined: u32,
    pub present: u32,
    /// Rows flipped to `missing` by this call. **Nothing was deleted.**
    pub marked_missing: u32,
    pub missing: Vec<SharedWatchedFile>,
    /// The folder row after its stats were written.
    pub folder: Option<SharedWatchedFolder>,
}

/// What attributing rows to a file changed.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedProducedRowsReport {
    pub file: SharedWatchedFile,
    pub added: u32,
    /// Ids that were attributed to this file before and are not now — the rows
    /// a re-import ORPHANED, which is how a deletion inside a `.bib` becomes
    /// visible. **What to do about them is the app's decision** (imbib tags
    /// them for review; nothing here deletes anything).
    pub removed_ids: Vec<String>,
}

/// One page of discovered files.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedWatchedFilePage {
    pub files: Vec<SharedWatchedFile>,
    /// Unpaged match count, so "200 of 4000" is distinguishable from
    /// "200 of 200".
    pub total: u32,
}

/// The kernel reports failures as prose (`Result<_, String>`), because its
/// other consumer puts them straight into an agent transcript. Swift wants a
/// thrown error, and `Storage` is the variant every non-classified store
/// failure already uses here.
fn watched_err(message: String) -> SharedStoreError {
    SharedStoreError::Storage { message }
}

impl From<watched_folder_ops::WatchedFolderDto> for SharedWatchedFolder {
    fn from(d: watched_folder_ops::WatchedFolderDto) -> Self {
        Self {
            id: d.id,
            path: d.path,
            kind_scope: d.kind_scope,
            display_name: d.display_name,
            enabled: d.enabled,
            recursive: d.recursive,
            volume_state: d.volume_state,
            bookmark_base64: d.bookmark_base64,
            last_scan_at: d.last_scan_at,
            last_scan_file_count: d.last_scan_file_count,
            last_scan_new_count: d.last_scan_new_count,
            last_scan_changed_count: d.last_scan_changed_count,
            last_scan_missing_count: d.last_scan_missing_count,
            last_scan_duration_ms: d.last_scan_duration_ms,
        }
    }
}

impl From<watched_folder_ops::WatchedFileDto> for SharedWatchedFile {
    fn from(d: watched_folder_ops::WatchedFileDto) -> Self {
        Self {
            id: d.id,
            watched_folder_id: d.watched_folder_id,
            path: d.path,
            content_hash: d.content_hash,
            state: d.state,
            kind_scope: d.kind_scope,
            mtime: d.mtime,
            size_bytes: d.size_bytes,
            first_seen_at: d.first_seen_at,
            last_seen_at: d.last_seen_at,
            missing_since: d.missing_since,
            produced_ids: d.produced_ids,
            produced_at: d.produced_at,
            needs_reimport: d.needs_reimport,
        }
    }
}

impl From<SharedDiscoveredFile> for watched_folder_ops::DiscoveredFileInput {
    fn from(f: SharedDiscoveredFile) -> Self {
        Self {
            path: f.path,
            content_hash: f.content_hash,
            mtime: f.mtime,
            size_bytes: f.size_bytes,
            bookmark_base64: f.bookmark_base64,
        }
    }
}

/// A watched folder plus whether THIS call created it. `created == false` is a
/// re-add, which is a no-op returning the existing row.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedWatchedFolderOutcome {
    pub folder: SharedWatchedFolder,
    pub created: bool,
}

/// What removing a watched folder took with it.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedWatchedFolderRemoval {
    /// False when there was no such folder.
    pub removed: bool,
    /// `watched-file` index entries deleted. Zero unless asked.
    pub file_rows_deleted: u32,
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

    // ─── Collection kernel (ADR-0022 D1/D2) ────────────────────────────────
    //
    // Thin delegation to `impress_core::collection_ops`, which owns the whole
    // verb set — including the reparent cycle check that used to live in the
    // Swift sidebar view model. All ids in and out are lowercase UUID strings.
    //
    // UNDO CONTRACT (ADR-0022 G2). Every mutating verb hands back what an undo
    // stack needs to invert it, so the caller never has to re-read the store
    // (which races) to build the inverse:
    //
    //   create        → row               undo: collection_delete(row.id)
    //   rename        → mutation          undo: collection_rename(id, prior .name)
    //   reorder       → mutation          undo: collection_reorder(id, prior .sortOrder)
    //   reparent      → mutation          undo: collection_reparent(id, prior .parent)
    //   delete        → snapshot          undo: collection_restore(snapshot)
    //   restore       → row               undo: collection_delete(row.id)
    //   add_members   → changed ids       undo: collection_remove_members(id, changed)
    //   remove_members→ changed ids       undo: collection_add_members(id, changed)
    //
    // The membership verbs return only the ids they ACTUALLY changed, so an
    // inverse cannot unfile an item that was already a member.

    /// All collections of the bound schema, flat and ordered by `sort_order`.
    /// The caller assembles the tree from `parent_id`.
    pub fn collection_tree(
        &self,
        binding: SharedCollectionBinding,
    ) -> Result<Vec<SharedCollectionRow>, SharedStoreError> {
        let rows = collection_ops::list_tree(&self.inner, &binding.binding())?;
        Ok(rows.into_iter().map(collection_row_to_ffi).collect())
    }

    /// The collections of ONE owning container (ADR-0022 C2), flat and ordered
    /// by `sort_order`. `container_id: nil`, or a binding with no container
    /// axis, answers exactly as `collection_tree` does.
    ///
    /// This is the migration-safe read imbib's sidebar needs: imbib-core's
    /// `list_collections(library_id)` hard-codes `schema_ref =
    /// "imbib/collection"` and returns nothing once WP G7 has run, while this
    /// resolves the binding against the `collections.unified` marker and filters
    /// on the envelope, which the migration never touches.
    pub fn collection_tree_in(
        &self,
        binding: SharedCollectionBinding,
        container_id: Option<String>,
    ) -> Result<Vec<SharedCollectionRow>, SharedStoreError> {
        let rows =
            collection_ops::list_tree_in(&self.inner, &binding.binding(), container_id.as_deref())?;
        Ok(rows.into_iter().map(collection_row_to_ffi).collect())
    }

    /// Create a collection under `parent_id` (`nil` = root). `kind_scope` is
    /// honoured only by the `Generic` binding, which defaults it to `"any"`.
    ///
    /// `sort_order` positions the row among its siblings: `nil` writes `0`
    /// (the historical behaviour), `Some(n)` writes `n` — pass the current
    /// sibling count to append to the end, which is what implore's figure
    /// folders want and used to emulate with a second `collection_reorder`.
    ///
    /// **Undo:** `collection_delete(row.id)`.
    pub fn collection_create(
        &self,
        binding: SharedCollectionBinding,
        name: String,
        parent_id: Option<String>,
        kind_scope: Option<String>,
        sort_order: Option<i64>,
    ) -> Result<SharedCollectionRow, SharedStoreError> {
        let row = collection_ops::create(
            &self.inner,
            &binding.binding(),
            &name,
            parent_id.as_deref(),
            kind_scope.as_deref(),
            sort_order,
        )?;
        Ok(collection_row_to_ffi(row))
    }

    /// Create a collection in an explicit OWNING CONTAINER (ADR-0022 C2).
    ///
    /// `container_id` is what makes per-library creation expressible: imbib's
    /// "New Collection" on a library row creates a ROOT collection whose owning
    /// library is that row, and there is no parent collection to inherit the
    /// library from. `nil` keeps the historical inherit-from-parent rule, so
    /// `collection_create` is this call with `nil`.
    ///
    /// **Undo:** `collection_delete(row.id)`.
    pub fn collection_create_in(
        &self,
        binding: SharedCollectionBinding,
        name: String,
        parent_id: Option<String>,
        kind_scope: Option<String>,
        sort_order: Option<i64>,
        container_id: Option<String>,
    ) -> Result<SharedCollectionRow, SharedStoreError> {
        let row = collection_ops::create_in(
            &self.inner,
            &binding.binding(),
            &name,
            parent_id.as_deref(),
            kind_scope.as_deref(),
            sort_order,
            container_id.as_deref(),
        )?;
        Ok(collection_row_to_ffi(row))
    }

    /// Rename a collection.
    ///
    /// **Undo:** `collection_rename(id, prior)` with the `.name` the returned
    /// mutation carries.
    pub fn collection_rename(
        &self,
        binding: SharedCollectionBinding,
        id: String,
        name: String,
    ) -> Result<SharedCollectionMutation, SharedStoreError> {
        let mutation = collection_ops::rename(&self.inner, &binding.binding(), &id, &name)?;
        Ok(collection_mutation_to_ffi(mutation))
    }

    /// Move a collection under `new_parent_id` (`nil` = make it a root).
    /// Returns `InvalidArgument` for self-parenting or a move under one of
    /// the collection's own descendants.
    ///
    /// **Undo:** `collection_reparent(id, prior)` with the `.parent` the
    /// returned mutation carries (whose `parent_id` is `nil` when the
    /// collection was a root).
    pub fn collection_reparent(
        &self,
        binding: SharedCollectionBinding,
        id: String,
        new_parent_id: Option<String>,
    ) -> Result<SharedCollectionMutation, SharedStoreError> {
        let mutation = collection_ops::reparent(
            &self.inner,
            &binding.binding(),
            &id,
            new_parent_id.as_deref(),
        )?;
        Ok(collection_mutation_to_ffi(mutation))
    }

    /// Move a collection under `new_parent_id` AND into `new_container_id`
    /// (ADR-0022 C2) — imbib's cross-library collection move, atomically.
    ///
    /// `new_container_id: nil` means "leave the owning container alone", which
    /// is what `collection_reparent` passes and what a same-library move wants:
    /// the Swift path it replaces skipped its `reparentItem` write entirely when
    /// the library did not change, and so does this.
    ///
    /// **Undo:** `collection_reparent_in(id, prior.parentId, prior.containerId)`
    /// — the returned prior is `ParentInContainer` exactly when the container
    /// moved, and a plain `Parent` otherwise.
    pub fn collection_reparent_in(
        &self,
        binding: SharedCollectionBinding,
        id: String,
        new_parent_id: Option<String>,
        new_container_id: Option<String>,
    ) -> Result<SharedCollectionMutation, SharedStoreError> {
        let mutation = collection_ops::reparent_in(
            &self.inner,
            &binding.binding(),
            &id,
            new_parent_id.as_deref(),
            new_container_id.as_deref(),
        )?;
        Ok(collection_mutation_to_ffi(mutation))
    }

    /// Set a collection's position among its siblings.
    ///
    /// **Undo:** `collection_reorder(id, prior)` with the `.sortOrder` the
    /// returned mutation carries.
    pub fn collection_reorder(
        &self,
        binding: SharedCollectionBinding,
        id: String,
        sort_order: i64,
    ) -> Result<SharedCollectionMutation, SharedStoreError> {
        let mutation = collection_ops::reorder(&self.inner, &binding.binding(), &id, sort_order)?;
        Ok(collection_mutation_to_ffi(mutation))
    }

    /// Delete a collection. Members are never deleted — only the membership.
    ///
    /// Returns the snapshot needed to put it back. **Undo:**
    /// `collection_restore(snapshot)`.
    pub fn collection_delete(
        &self,
        binding: SharedCollectionBinding,
        id: String,
    ) -> Result<SharedDeletedCollection, SharedStoreError> {
        let snapshot = collection_ops::delete(&self.inner, &binding.binding(), &id)?;
        Ok(SharedDeletedCollection {
            row: collection_row_to_ffi(snapshot.row),
            envelope_parent_id: snapshot.envelope_parent_id,
            member_ids: snapshot.member_ids,
            child_collection_ids: snapshot.child_collection_ids,
        })
    }

    /// Put a deleted collection back under its ORIGINAL id, with its members
    /// re-filed and its child collections re-attached — the inverse of
    /// `collection_delete`.
    ///
    /// Members and children that have since been deleted are skipped rather
    /// than failing the restore; restoring over a live id is `InvalidArgument`.
    ///
    /// **Undo:** `collection_delete(row.id)`.
    pub fn collection_restore(
        &self,
        binding: SharedCollectionBinding,
        snapshot: SharedDeletedCollection,
    ) -> Result<SharedCollectionRow, SharedStoreError> {
        let snapshot = collection_ops::DeletedCollection {
            row: collection_row_from_ffi(snapshot.row),
            envelope_parent_id: snapshot.envelope_parent_id,
            member_ids: snapshot.member_ids,
            child_collection_ids: snapshot.child_collection_ids,
        };
        let row = collection_ops::restore(&self.inner, &binding.binding(), &snapshot)?;
        Ok(collection_row_to_ffi(row))
    }

    /// Add items to a collection. Idempotent per item.
    ///
    /// Returns the ids that ACTUALLY became members — an id that was already
    /// filed reports nothing. **Undo:**
    /// `collection_remove_members(collection_id, changed)`.
    pub fn collection_add_members(
        &self,
        binding: SharedCollectionBinding,
        collection_id: String,
        item_ids: Vec<String>,
    ) -> Result<Vec<String>, SharedStoreError> {
        Ok(collection_ops::add_members(
            &self.inner,
            &binding.binding(),
            &collection_id,
            &item_ids,
        )?)
    }

    /// Remove items from a collection without touching the items.
    ///
    /// Returns the ids that were ACTUALLY removed — non-members and items
    /// filed in a different collection report nothing. **Undo:**
    /// `collection_add_members(collection_id, changed)`.
    pub fn collection_remove_members(
        &self,
        binding: SharedCollectionBinding,
        collection_id: String,
        item_ids: Vec<String>,
    ) -> Result<Vec<String>, SharedStoreError> {
        Ok(collection_ops::remove_members(
            &self.inner,
            &binding.binding(),
            &collection_id,
            &item_ids,
        )?)
    }

    /// Member counts, aligned index-for-index with `collection_ids`.
    pub fn collection_member_counts(
        &self,
        binding: SharedCollectionBinding,
        collection_ids: Vec<String>,
    ) -> Result<Vec<u32>, SharedStoreError> {
        Ok(collection_ops::member_counts(
            &self.inner,
            &binding.binding(),
            &collection_ids,
        )?)
    }

    // ─── Watched folders (ADR-0023 W2) ─────────────────────────────────────
    //
    // Eight verbs, the same eight `DocsImportService` exposes to MCP/CLI, over
    // the same kernel (`impress_core::watched_folder_ops`) — the
    // collection-kernel arrangement exactly: agent surface and Swift surface
    // are twins of one implementation, never two implementations of one idea.
    //
    // What differs from the service twin, deliberately: no `message` strings
    // (those are prose for an agent transcript) and errors are `Result` rather
    // than an `ok: false` field, because Swift has `throws` and the service's
    // callers do not. The DATA is identical field for field.
    //
    // The order a caller uses them:
    //
    //   watched_folder_add            once, when the user picks a directory
    //   watched_folder_list           at launch, to rebuild the sidebar
    //   watched_import_discovered  ─┐ per discovery batch
    //   watched_record_produced    ─┘ per file, after the app's importer ran
    //   watched_finish_scan           once per sweep — the missing-file pass
    //   watched_files_list            provenance, both directions
    //   watched_folder_update         pause / rename / re-bookmark / declare
    //   watched_folder_remove         stop watching (touches no file on disk)

    /// Start watching a directory for files of one record kind.
    ///
    /// `kind_scope` is the record kind whose `FileDiscoveryCapability` decides
    /// which files count (`publication`, `manuscript`, `figure`, `message`).
    /// The file types are deliberately NOT an argument: they are declared once,
    /// on the record kind, and restating them here would be a second authority
    /// that can disagree with the first.
    ///
    /// **Idempotent.** The id is derived from `(path, kind_scope)`, so adding
    /// the same folder twice returns the existing row (`created == false`).
    /// Re-adding with a fresh `bookmark_base64` swaps the bookmark in — that is
    /// how a Swift caller hands over a re-granted access scope — and changes
    /// nothing else. Watching one directory for two kinds is two folders.
    ///
    /// Nothing is scanned by this call; discovery is `watched_import_discovered`.
    pub fn watched_folder_add(
        &self,
        path: String,
        kind_scope: String,
        display_name: Option<String>,
        bookmark_base64: Option<String>,
        recursive: bool,
    ) -> Result<SharedWatchedFolderOutcome, SharedStoreError> {
        let (folder, created) = watched_folder_ops::create_folder(
            &self.inner,
            &path,
            &kind_scope,
            display_name.as_deref(),
            bookmark_base64.as_deref(),
            recursive,
        )
        .map_err(watched_err)?;
        Ok(SharedWatchedFolderOutcome {
            folder: folder.into(),
            created,
        })
    }

    /// Every watched folder, optionally narrowed to one `kind_scope`, in path
    /// order — with its last-scan stats and its declared volume state.
    pub fn watched_folder_list(
        &self,
        kind_scope: Option<String>,
    ) -> Result<Vec<SharedWatchedFolder>, SharedStoreError> {
        let folders = watched_folder_ops::list_folders(&self.inner, kind_scope.as_deref())
            .map_err(watched_err)?;
        Ok(folders.into_iter().map(Into::into).collect())
    }

    /// Change a watched folder's mutable facets. Every argument is optional and
    /// `nil` leaves that field alone, so pausing a folder cannot blank its
    /// bookmark by omission.
    ///
    /// `volume_state` is the ADR-0023 D6 declaration — `indexed`, `unindexed`,
    /// `scan-on-demand`, `unavailable`. Writing it is how a folder on a
    /// Spotlight-less volume says so instead of rendering an honest-looking
    /// zero, and it is the store-side twin of `WatchedFolderState`.
    pub fn watched_folder_update(
        &self,
        id: String,
        enabled: Option<bool>,
        recursive: Option<bool>,
        display_name: Option<String>,
        bookmark_base64: Option<String>,
        volume_state: Option<String>,
    ) -> Result<SharedWatchedFolder, SharedStoreError> {
        let folder = watched_folder_ops::update_folder(
            &self.inner,
            &id,
            enabled,
            recursive,
            display_name.as_deref(),
            bookmark_base64.as_deref(),
            volume_state.as_deref(),
        )
        .map_err(watched_err)?;
        Ok(folder.into())
    }

    /// Stop watching a folder.
    ///
    /// **Never touches a byte on disk** — ADR-0023 D4's reference-in-place rule
    /// is one-way. The rows the folder's files PRODUCED are left alone too: a
    /// publication imported from a watched `.bib` is a publication, and
    /// un-watching its folder is not a retraction of it.
    ///
    /// `delete_file_rows` additionally removes the folder's `watched-file`
    /// index entries. Leave it false to keep the provenance readable.
    pub fn watched_folder_remove(
        &self,
        id: String,
        delete_file_rows: bool,
    ) -> Result<SharedWatchedFolderRemoval, SharedStoreError> {
        let (removed, file_rows_deleted) =
            watched_folder_ops::remove_folder(&self.inner, &id, delete_file_rows)
                .map_err(watched_err)?;
        Ok(SharedWatchedFolderRemoval {
            removed,
            file_rows_deleted,
        })
    }

    /// Record a batch of discovered files against a watched folder — the
    /// ADR-0023 D4 diff.
    ///
    /// * A path not seen before becomes a `watched-file` row with its
    ///   provenance, content hash and mtime (`created`).
    /// * A path whose hash moved is updated in place, same id (`changed`).
    /// * A path whose hash is identical writes **nothing at all** — not the
    ///   row, not a timestamp. Re-running discovery over a settled tree is free
    ///   and fires no store mutation, which is what keeps a watcher out of the
    ///   startup render loop.
    /// * A path that was `missing` and is back is restored, same id, with its
    ///   attribution intact (`restored`).
    ///
    /// Missing files are NOT found here: a batch never has to be a complete set
    /// (live discovery reports one file at a time), so absence from a batch
    /// means nothing. `watched_finish_scan` is what looks for them.
    ///
    /// There is deliberately no `kind_scope` argument — the folder declared its
    /// scope when it was added, and a second copy on every call could only ever
    /// be redundant or wrong.
    ///
    /// Bounded per ADR-0023 D7: paths are sorted and written in batches of 500,
    /// and at most 5000 files may be sent in one call. A bigger tree is paged;
    /// an over-large call is REJECTED with the bound named, never truncated.
    pub fn watched_import_discovered(
        &self,
        watched_folder_id: String,
        files: Vec<SharedDiscoveredFile>,
        dry_run: bool,
    ) -> Result<SharedDiscoveryReport, SharedStoreError> {
        let folder = watched_folder_ops::load_folder(&self.inner, &watched_folder_id)
            .map_err(watched_err)?
            .ok_or_else(|| {
                watched_err(format!(
                    "no watched folder {watched_folder_id} — call watched_folder_add first"
                ))
            })?;
        let kind_scope = watched_folder_ops::folder_to_dto(&folder).kind_scope;
        let inputs: Vec<watched_folder_ops::DiscoveredFileInput> =
            files.into_iter().map(Into::into).collect();
        let outcome = watched_folder_ops::upsert_discovered(&self.inner, &folder, &inputs, dry_run)
            .map_err(watched_err)?;
        Ok(SharedDiscoveryReport {
            watched_folder_id: folder.id.to_string(),
            kind_scope,
            created: outcome.created,
            changed: outcome.changed,
            unchanged: outcome.unchanged,
            restored: outcome.restored,
            batches: outcome.batches,
            files: outcome
                .files
                .into_iter()
                .map(|f| SharedDiscoveredFileOutcome {
                    id: f.id,
                    path: f.path,
                    action: f.action,
                    content_hash: f.content_hash,
                })
                .collect(),
            skipped: outcome
                .skipped
                .into_iter()
                .map(|s| SharedSkippedFile {
                    path: s.path,
                    reason: s.reason,
                })
                .collect(),
        })
    }

    /// Close a scan: find the files that vanished, and write the folder's
    /// last-scan stats.
    ///
    /// A file whose path is gone is marked `missing` — **never deleted**
    /// (ADR-0023 D4). A moved file is not a retracted one, and the rows it
    /// produced are still real.
    ///
    /// **Refuses to run when the folder's own root is unreachable.** If a
    /// volume unmounted or a bookmark lapsed, every path under it stops
    /// existing at once and a credulous sweep would mark a whole library
    /// missing in one pass; the folder's `volume_state` is set to `unavailable`
    /// and the call throws instead (D6 with teeth).
    ///
    /// The three counts are the caller's running totals across however many
    /// `watched_import_discovered` calls the scan took — no single one of them
    /// knows the total. File and missing counts are computed here.
    pub fn watched_finish_scan(
        &self,
        watched_folder_id: String,
        new_count: Option<i64>,
        changed_count: Option<i64>,
        duration_ms: Option<i64>,
        dry_run: bool,
    ) -> Result<SharedWatchedScanReport, SharedStoreError> {
        let folder = watched_folder_ops::load_folder(&self.inner, &watched_folder_id)
            .map_err(watched_err)?
            .ok_or_else(|| watched_err(format!("no watched folder {watched_folder_id}")))?;

        let outcome = match watched_folder_ops::sweep_missing(&self.inner, &folder, dry_run) {
            Ok(outcome) => outcome,
            Err(e) => {
                // The root is unreachable. DECLARE it before throwing, so the
                // row the user sees says "Folder unavailable" rather than
                // silently keeping a stale healthy state.
                let _ = watched_folder_ops::update_folder(
                    &self.inner,
                    &watched_folder_id,
                    None,
                    None,
                    None,
                    None,
                    Some(VOLUME_STATE_UNAVAILABLE),
                );
                return Err(watched_err(e));
            }
        };

        let folder_dto = if dry_run {
            Some(watched_folder_ops::folder_to_dto(&folder))
        } else {
            Some(
                watched_folder_ops::record_scan_stats(
                    &self.inner,
                    &folder,
                    outcome.present as i64,
                    new_count.unwrap_or(0).max(0),
                    changed_count.unwrap_or(0).max(0),
                    outcome.marked_missing as i64,
                    duration_ms.unwrap_or(0).max(0),
                )
                .map_err(watched_err)?,
            )
        };

        Ok(SharedWatchedScanReport {
            watched_folder_id: folder.id.to_string(),
            examined: outcome.examined,
            present: outcome.present,
            marked_missing: outcome.marked_missing,
            missing: outcome.missing.into_iter().map(Into::into).collect(),
            folder: folder_dto.map(Into::into),
        })
    }

    /// Attribute store rows to the discovered file that produced them.
    ///
    /// The seam between file-level bookkeeping (the kernel) and each app's real
    /// importer (Swift). The kernel does not know how to parse a `.bib` and
    /// must not learn:
    ///
    /// 1. `watched_import_discovered` reports a file `created` / `changed` /
    ///    `restored`.
    /// 2. The app's own importer runs on that one file — for imbib, the same
    ///    BibTeX/RIS import a manual drag performs, with its whole-library
    ///    identifier dedup.
    /// 3. It calls this with the ids that file now accounts for.
    ///
    /// `replace` is what makes deletions detectable: re-importing an edited
    /// `.bib` that lost an entry returns that entry's id in `removed_ids`, so
    /// the caller can decide what "the source no longer contains this" means.
    /// Pass `replace: false` to union instead, which is what an incremental
    /// append wants.
    ///
    /// Pass ALL the ids the file accounts for, not just the newly created ones
    /// — an id the importer deduped onto an existing publication is still an id
    /// this file produces, and omitting it would orphan a row on every re-scan.
    pub fn watched_record_produced(
        &self,
        file_id: String,
        produced_ids: Vec<String>,
        replace: bool,
    ) -> Result<SharedProducedRowsReport, SharedStoreError> {
        let outcome =
            watched_folder_ops::record_produced(&self.inner, &file_id, &produced_ids, replace)
                .map_err(watched_err)?;
        Ok(SharedProducedRowsReport {
            file: outcome.file.into(),
            added: outcome.added,
            removed_ids: outcome.removed_ids,
        })
    }

    /// The provenance query, both directions.
    ///
    /// * `watched_folder_id` — "which files does this folder know about?",
    ///   optionally narrowed to `state: "present"` or `"missing"`, paged.
    /// * `file_id` — one file's row, whose `produced_ids` answers "which store
    ///   rows did this file produce?" and whose `needs_reimport` says whether
    ///   its content has moved on since.
    ///
    /// One of the two is required.
    pub fn watched_files_list(
        &self,
        watched_folder_id: Option<String>,
        file_id: Option<String>,
        state: Option<String>,
        limit: i64,
        offset: i64,
    ) -> Result<SharedWatchedFilePage, SharedStoreError> {
        let limit = if limit <= 0 {
            watched_folder_ops::DEFAULT_FILE_LIST_LIMIT
        } else {
            limit
        };
        let (files, total) = watched_folder_ops::list_files(
            &self.inner,
            watched_folder_id.as_deref(),
            file_id.as_deref(),
            state.as_deref(),
            limit,
            offset,
        )
        .map_err(watched_err)?;
        Ok(SharedWatchedFilePage {
            files: files.into_iter().map(Into::into).collect(),
            total,
        })
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

impl SharedCollectionBinding {
    /// The kernel descriptor for this binding.
    fn binding(self) -> CollectionSchemaBinding {
        match self {
            SharedCollectionBinding::Publication => collection_ops::IMBIB_COLLECTION,
            SharedCollectionBinding::Manuscript => collection_ops::MANUSCRIPT_COLLECTION,
            SharedCollectionBinding::Figure => collection_ops::FIGURE_COLLECTION,
            SharedCollectionBinding::Generic => collection_ops::GENERIC_COLLECTION,
        }
    }
}

fn collection_row_to_ffi(row: collection_ops::CollectionRow) -> SharedCollectionRow {
    SharedCollectionRow {
        id: row.id,
        name: row.name,
        parent_id: row.parent_id,
        sort_order: row.sort_order,
        kind_scope: row.kind_scope,
        container_id: row.container_id,
        is_smart: row.is_smart,
        member_count: row.member_count,
    }
}

/// The inverse, for the one call that takes a row back in: `collection_restore`.
fn collection_row_from_ffi(row: SharedCollectionRow) -> collection_ops::CollectionRow {
    collection_ops::CollectionRow {
        id: row.id,
        name: row.name,
        parent_id: row.parent_id,
        sort_order: row.sort_order,
        kind_scope: row.kind_scope,
        container_id: row.container_id,
        is_smart: row.is_smart,
        member_count: row.member_count,
    }
}

fn collection_mutation_to_ffi(
    mutation: collection_ops::CollectionMutation,
) -> SharedCollectionMutation {
    SharedCollectionMutation {
        row: collection_row_to_ffi(mutation.row),
        prior: match mutation.prior {
            collection_ops::CollectionPrior::Name(name) => SharedCollectionPrior::Name { name },
            collection_ops::CollectionPrior::SortOrder(sort_order) => {
                SharedCollectionPrior::SortOrder { sort_order }
            }
            collection_ops::CollectionPrior::Parent(parent_id) => {
                SharedCollectionPrior::Parent { parent_id }
            }
            collection_ops::CollectionPrior::ParentInContainer { parent, container } => {
                SharedCollectionPrior::ParentInContainer {
                    parent_id: parent,
                    container_id: container,
                }
            }
        },
    }
}

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

// ─── Hybrid search ranking (Stage 7 item 7) ──────────────────────────────────

/// One publication returned by at least one of imbib's three retrieval engines.
///
/// A `nil` score means that engine did not return this publication. That is
/// load-bearing rather than a default: it decides the match type and whether
/// the field boosts apply, so callers must pass `nil` (not `0`) for a miss.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedHybridCandidate {
    /// Lowercase UUID string. Also the tie-break key — spell it consistently.
    pub id: String,
    pub cite_key: String,
    pub title: String,
    /// Rendered author list, as displayed.
    pub authors: String,
    /// Tantivy BM25 score, if the full-text index returned this publication.
    pub fts_score: Option<f32>,
    /// Embedding cosine similarity (0–1).
    pub semantic_similarity: Option<f32>,
    /// Best chunk-passage cosine similarity (0–1).
    pub chunk_similarity: Option<f32>,
}

/// A scored candidate. The vector this comes back in **is** the rank order.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedRankedCandidate {
    pub id: String,
    pub score: f32,
    /// `both` | `fulltext` | `full` | `semantic`.
    pub match_type: String,
}

/// Rank imbib's hybrid (full-text + semantic + chunk) candidate set.
///
/// The single implementation of the hybrid relevance formula: full-text hits
/// outrank semantic-only ones, field matches on author/title/cite-key boost
/// full-text hits, and chunk-passage similarity is scaled to sit between the
/// two. Ordering is score descending, ties broken by ascending id — the
/// tie-break is pinned so the palette does not reshuffle equal-scored rows.
///
/// Pure function: no store access, so any surface can call it.
#[cfg_attr(feature = "native", uniffi::export)]
pub fn rank_hybrid_search_results(
    query: String,
    candidates: Vec<SharedHybridCandidate>,
) -> Vec<SharedRankedCandidate> {
    let inputs: Vec<impress_core::search_ops::HybridCandidate> = candidates
        .into_iter()
        .map(|c| impress_core::search_ops::HybridCandidate {
            id: c.id,
            cite_key: c.cite_key,
            title: c.title,
            authors: c.authors,
            fts_score: c.fts_score,
            semantic_similarity: c.semantic_similarity,
            chunk_similarity: c.chunk_similarity,
        })
        .collect();

    impress_core::search_ops::rank_hybrid_candidates(&query, &inputs)
        .into_iter()
        .map(|r| SharedRankedCandidate {
            id: r.id,
            score: r.score,
            match_type: r.match_type.to_string(),
        })
        .collect()
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
                "task@1.0.0".into(),
                r#"{"title": "t"}"#.into(),
            )
            .expect("upsert task");

        assert_eq!(
            store
                .count_by_schema("review-request@1.0.0".into())
                .expect("count"),
            3
        );
        assert_eq!(
            store.count_by_schema("task@1.0.0".into()).expect("count"),
            1
        );
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
                "task@1.0.0".into(),
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
            .query_by_schema("task@1.0.0".into(), 10, 0)
            .expect("query tasks");
        assert_eq!(tasks.len(), 1);
        assert_eq!(tasks[0].id, task_id);

        let emails = store
            .query_by_schema("email-message".into(), 10, 0)
            .expect("query emails");
        assert_eq!(emails.len(), 1);
        assert_eq!(emails[0].id, email_id);
    }

    // ─── Collection kernel (ADR-0022 D1/D2) ────────────────────────────────

    /// Insert a plain record of `schema` and return its id.
    fn make_record(store: &SharedStore, schema: &str, title: &str) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                id.clone(),
                schema.into(),
                format!(r#"{{"title": "{title}"}}"#),
            )
            .expect("upsert record");
        id
    }

    #[test]
    fn collection_kernel_round_trip() {
        let store = SharedStore::open_in_memory().expect("open");
        let root = store
            .collection_create(
                SharedCollectionBinding::Generic,
                "Grant renewal".into(),
                None,
                Some("any".into()),
                None,
            )
            .expect("create root");
        let child = store
            .collection_create(
                SharedCollectionBinding::Generic,
                "Figures".into(),
                Some(root.id.clone()),
                None,
                Some(1),
            )
            .expect("create child");

        assert_eq!(root.kind_scope.as_deref(), Some("any"));
        assert_eq!(root.sort_order, 0, "nil sort_order keeps writing 0");
        assert_eq!(
            child.kind_scope.as_deref(),
            Some("any"),
            "kind_scope defaults to any"
        );
        assert_eq!(child.sort_order, 1, "an explicit sort_order is honoured");
        assert_eq!(child.parent_id.as_deref(), Some(root.id.as_str()));

        let renamed = store
            .collection_rename(
                SharedCollectionBinding::Generic,
                child.id.clone(),
                "Panels".into(),
            )
            .expect("rename");
        assert_eq!(renamed.row.name, "Panels");
        assert_eq!(
            renamed.prior,
            SharedCollectionPrior::Name {
                name: "Figures".into()
            },
            "undo renames back to this"
        );

        let reordered = store
            .collection_reorder(SharedCollectionBinding::Generic, child.id.clone(), 4)
            .expect("reorder");
        assert_eq!(reordered.row.sort_order, 4);
        assert_eq!(
            reordered.prior,
            SharedCollectionPrior::SortOrder { sort_order: 1 }
        );

        let unparented = store
            .collection_reparent(SharedCollectionBinding::Generic, child.id.clone(), None)
            .expect("reparent to root");
        assert!(unparented.row.parent_id.is_none());
        assert_eq!(
            unparented.prior,
            SharedCollectionPrior::Parent {
                parent_id: Some(root.id.clone())
            }
        );
        let reparented = store
            .collection_reparent(
                SharedCollectionBinding::Generic,
                child.id.clone(),
                Some(root.id.clone()),
            )
            .expect("reparent back");
        assert_eq!(
            reparented.prior,
            SharedCollectionPrior::Parent { parent_id: None },
            "'was a root' is not the same as 'no prior value'"
        );
        store
            .collection_reparent(SharedCollectionBinding::Generic, child.id.clone(), None)
            .expect("reparent to root again");

        let tree = store
            .collection_tree(SharedCollectionBinding::Generic)
            .expect("tree");
        assert_eq!(tree.len(), 2);
        assert_eq!(
            tree.iter().map(|r| r.name.as_str()).collect::<Vec<_>>(),
            vec!["Grant renewal", "Panels"],
            "tree is flat and sorted by sort_order"
        );

        let snapshot = store
            .collection_delete(SharedCollectionBinding::Generic, child.id.clone())
            .expect("delete");
        assert_eq!(snapshot.row.id, child.id);
        assert_eq!(snapshot.row.sort_order, 4, "the snapshot is undo-complete");
        assert_eq!(
            store
                .collection_tree(SharedCollectionBinding::Generic)
                .expect("tree")
                .len(),
            1
        );
        assert!(matches!(
            store.collection_delete(SharedCollectionBinding::Generic, child.id),
            Err(SharedStoreError::NotFound { .. })
        ));
    }

    #[test]
    fn collection_reparent_rejects_cycles() {
        let store = SharedStore::open_in_memory().expect("open");
        let a = store
            .collection_create(
                SharedCollectionBinding::Generic,
                "A".into(),
                None,
                None,
                None,
            )
            .expect("A");
        let b = store
            .collection_create(
                SharedCollectionBinding::Generic,
                "B".into(),
                Some(a.id.clone()),
                None,
                None,
            )
            .expect("B");
        let c = store
            .collection_create(
                SharedCollectionBinding::Generic,
                "C".into(),
                Some(b.id.clone()),
                None,
                None,
            )
            .expect("C");

        assert!(
            matches!(
                store.collection_reparent(
                    SharedCollectionBinding::Generic,
                    a.id.clone(),
                    Some(a.id.clone())
                ),
                Err(SharedStoreError::InvalidArgument { .. })
            ),
            "self-parenting must be rejected"
        );
        assert!(
            matches!(
                store.collection_reparent(
                    SharedCollectionBinding::Generic,
                    a.id.clone(),
                    Some(c.id.clone())
                ),
                Err(SharedStoreError::InvalidArgument { .. })
            ),
            "a move under a descendant must be rejected"
        );

        // The rejected moves left the tree intact.
        let tree = store
            .collection_tree(SharedCollectionBinding::Generic)
            .expect("tree");
        let a_row = tree.iter().find(|r| r.id == a.id).expect("A listed");
        assert!(a_row.parent_id.is_none());
    }

    #[test]
    fn collection_members_are_mixed_kind() {
        let store = SharedStore::open_in_memory().expect("open");
        let mixed = store
            .collection_create(
                SharedCollectionBinding::Generic,
                "Everything".into(),
                None,
                Some("any".into()),
                None,
            )
            .expect("create");
        let empty = store
            .collection_create(
                SharedCollectionBinding::Generic,
                "Empty".into(),
                None,
                None,
                None,
            )
            .expect("create");

        let manuscript = make_record(&store, "manuscript", "Draft II");
        let figure = make_record(&store, "figure", "Rotation curve");

        assert_eq!(
            store
                .collection_add_members(
                    SharedCollectionBinding::Generic,
                    mixed.id.clone(),
                    vec![manuscript.clone(), figure.clone()],
                )
                .expect("add members"),
            vec![manuscript.clone(), figure.clone()],
            "the ids that actually changed, for an exact inverse"
        );
        assert!(
            store
                .collection_add_members(
                    SharedCollectionBinding::Generic,
                    mixed.id.clone(),
                    vec![figure.clone()],
                )
                .expect("re-add")
                .is_empty(),
            "re-adding an existing member changes nothing"
        );
        assert_eq!(
            store
                .collection_member_counts(
                    SharedCollectionBinding::Generic,
                    vec![mixed.id.clone(), empty.id.clone()],
                )
                .expect("counts"),
            vec![2, 0],
            "counts align with the requested ids"
        );

        let refs = store
            .get_item_references(mixed.id.clone())
            .expect("references");
        assert_eq!(refs.len(), 2);
        assert!(refs.iter().all(|r| r.edge_type == "Contains"));

        assert_eq!(
            store
                .collection_remove_members(
                    SharedCollectionBinding::Generic,
                    mixed.id.clone(),
                    vec![figure.clone()],
                )
                .expect("remove"),
            vec![figure.clone()]
        );
        assert_eq!(
            store
                .collection_member_counts(SharedCollectionBinding::Generic, vec![mixed.id])
                .expect("counts"),
            vec![1]
        );
        assert!(
            store.get_item(figure).expect("get").is_some(),
            "removing membership must not delete the item"
        );
    }

    #[test]
    fn collection_bindings_are_isolated() {
        let store = SharedStore::open_in_memory().expect("open");
        store
            .collection_create(
                SharedCollectionBinding::Generic,
                "Mixed".into(),
                None,
                None,
                None,
            )
            .expect("generic");
        let workspace = store
            .collection_create(
                SharedCollectionBinding::Manuscript,
                "Workspace".into(),
                None,
                None,
                None,
            )
            .expect("manuscript");
        let folder = store
            .collection_create(
                SharedCollectionBinding::Manuscript,
                "Drafts".into(),
                Some(workspace.id.clone()),
                None,
                None,
            )
            .expect("manuscript child");

        assert_eq!(
            store
                .collection_tree(SharedCollectionBinding::Manuscript)
                .expect("tree")
                .len(),
            2,
            "each binding sees only its own schema"
        );
        assert!(store
            .collection_tree(SharedCollectionBinding::Publication)
            .expect("tree")
            .is_empty());

        // The manuscript binding writes the payload ref imprint already uses,
        // and leaves the envelope parent (the owning library) alone.
        let row = store
            .get_item(folder.id.clone())
            .expect("get")
            .expect("row");
        let payload: serde_json::Value = serde_json::from_str(&row.payload_json).unwrap();
        assert_eq!(payload["parent_collection_ref"], workspace.id);
        assert!(row.parent_id.is_none());
        assert!(folder.kind_scope.is_none());
    }

    #[test]
    fn collection_figure_binding_files_via_envelope_parent() {
        let store = SharedStore::open_in_memory().expect("open");
        let folder = store
            .collection_create(
                SharedCollectionBinding::Figure,
                "Paper figures".into(),
                None,
                None,
                None,
            )
            .expect("folder");
        let nested = store
            .collection_create(
                SharedCollectionBinding::Figure,
                "Supplement".into(),
                Some(folder.id.clone()),
                None,
                None,
            )
            .expect("nested folder");
        assert_eq!(nested.parent_id.as_deref(), Some(folder.id.as_str()));

        let figure = make_record(&store, "figure", "Panel A");
        store
            .collection_add_members(
                SharedCollectionBinding::Figure,
                folder.id.clone(),
                vec![figure.clone()],
            )
            .expect("file figure");

        let row = store.get_item(figure).expect("get").expect("row");
        assert_eq!(
            row.parent_id.as_deref(),
            Some(folder.id.as_str()),
            "figures are filed through the envelope parent"
        );
        assert_eq!(
            store
                .collection_member_counts(SharedCollectionBinding::Figure, vec![folder.id])
                .expect("counts"),
            vec![1],
            "the nested folder is a tree node, not a member"
        );
    }

    #[test]
    fn collection_delete_snapshot_restores_the_whole_folder() {
        let store = SharedStore::open_in_memory().expect("open");
        let folder = store
            .collection_create(
                SharedCollectionBinding::Figure,
                "Paper figures".into(),
                None,
                None,
                Some(2),
            )
            .expect("folder");
        let nested = store
            .collection_create(
                SharedCollectionBinding::Figure,
                "Supplement".into(),
                Some(folder.id.clone()),
                None,
                None,
            )
            .expect("nested");
        let panel = make_record(&store, "figure", "Panel A");
        store
            .collection_add_members(
                SharedCollectionBinding::Figure,
                folder.id.clone(),
                vec![panel.clone()],
            )
            .expect("file figure");

        let snapshot = store
            .collection_delete(SharedCollectionBinding::Figure, folder.id.clone())
            .expect("delete");
        assert_eq!(snapshot.row.sort_order, 2);
        assert_eq!(snapshot.member_ids, vec![panel.clone()]);
        assert_eq!(snapshot.child_collection_ids, vec![nested.id.clone()]);

        let restored = store
            .collection_restore(SharedCollectionBinding::Figure, snapshot.clone())
            .expect("restore");
        assert_eq!(restored.id, folder.id, "restored under its ORIGINAL id");
        assert_eq!(restored.sort_order, 2);

        let tree = store
            .collection_tree(SharedCollectionBinding::Figure)
            .expect("tree");
        assert_eq!(tree.len(), 2);
        assert_eq!(
            tree.iter()
                .find(|r| r.id == nested.id)
                .expect("nested listed")
                .parent_id
                .as_deref(),
            Some(folder.id.as_str()),
            "the child folder is re-attached"
        );
        assert_eq!(
            store
                .collection_member_counts(SharedCollectionBinding::Figure, vec![folder.id.clone()])
                .expect("counts"),
            vec![1],
            "the figure is re-filed"
        );

        // A second restore is a double-undo, not a repair.
        assert!(matches!(
            store.collection_restore(SharedCollectionBinding::Figure, snapshot),
            Err(SharedStoreError::InvalidArgument { .. })
        ));
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Search & Related (ADR-0022 D6/D8)
// ═══════════════════════════════════════════════════════════════════════════
//
// Two mixed-kind reads over the shared store: grouped global search and the
// generic Related section. Both return `schema_ref` on every row, because
// their whole point is that the caller does NOT know in advance which record
// kinds are in the answer — Swift picks a row renderer per entry.
//
// Appended as a separate exported `impl SharedStore` block rather than folded
// into the main one: these are a distinct capability with a distinct ADR
// section, and UniFFI is happy to scaffold several impl blocks for one object.

/// One grouped-search hit. `schema_ref` is the bucket key — group by it to
/// render one section per record kind.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedSearchHit {
    /// Lowercase UUID string.
    pub id: String,
    /// The item's schema ("manuscript", "figure", "email-message", …).
    pub schema_ref: String,
    /// Display title (title / subject / name, in that order).
    pub title: String,
    /// Snippet of the best-matching indexed column, unmarked; falls back to
    /// the title when the match has nothing quotable.
    pub snippet: String,
    /// BM25 relevance. **Lower is better** — hits arrive already sorted.
    pub rank: f64,
}

/// One item related to a subject item by a typed edge.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Debug, Clone)]
pub struct SharedRelatedItem {
    /// Lowercase UUID of the OTHER item — never the subject.
    pub id: String,
    /// The other item's schema, so a mixed-kind list can pick a row renderer.
    pub schema_ref: String,
    /// Display title (title / subject / name, in that order).
    pub title: String,
    /// Edge type name ("Cites", "Contains", "ProducedBy", …); a custom edge
    /// reports its bare custom name.
    pub edge_type: String,
    /// `"outgoing"` when the subject is the edge source (this manuscript
    /// *contains* that figure), `"incoming"` when it is the target.
    pub direction: String,
}

#[cfg_attr(feature = "native", uniffi::export)]
impl SharedStore {
    /// Full-text search across every record kind at once (ADR-0022 D6).
    ///
    /// Results are ordered by `schema_ref`, then relevance, then id, so the
    /// per-kind buckets are contiguous and stable. `limit_per_schema` caps each
    /// kind separately — one noisy mailbox cannot crowd manuscripts off the
    /// surface. Pass `0` for the default (20); the cap is clamped at 200.
    ///
    /// The query string is treated as words, never as FTS5 syntax: a
    /// half-typed `foo AND (` searches for two literal words instead of
    /// failing. Terms are prefix-matched, so "scal" finds "Scaling".
    ///
    /// Items with `status: "dismissed"` are withheld — they are reachable
    /// through their own section, by design.
    pub fn search_all(
        &self,
        query: String,
        limit_per_schema: u32,
    ) -> Result<Vec<SharedSearchHit>, SharedStoreError> {
        let hits = impress_core::search_ops::search_all(&self.inner, &query, limit_per_schema)?;
        Ok(hits
            .into_iter()
            .map(|h| SharedSearchHit {
                id: h.id,
                schema_ref: h.schema_ref,
                title: h.title,
                snippet: h.snippet,
                rank: h.rank,
            })
            .collect())
    }

    /// Every item related to `id` by a typed edge, in BOTH directions and
    /// across ALL edge types (ADR-0022 D8).
    ///
    /// Ordered by edge type, then title — so a Related section can render one
    /// heading per edge type by walking the list once. Edges whose other end
    /// no longer exists are skipped rather than shown as blank rows. Pass `0`
    /// for the default limit (50); the cap is clamped at 500.
    pub fn related_items(
        &self,
        id: String,
        limit: u32,
    ) -> Result<Vec<SharedRelatedItem>, SharedStoreError> {
        let rows = impress_core::related_ops::related_items(&self.inner, &id, limit)?;
        Ok(rows
            .into_iter()
            .map(|r| SharedRelatedItem {
                id: r.id,
                schema_ref: r.schema_ref,
                title: r.title,
                edge_type: r.edge_type,
                direction: r.direction,
            })
            .collect())
    }
}

// ─── Search & Related tests ──────────────────────────────────────────────────

#[cfg(test)]
mod search_related_tests {
    use super::*;

    fn store() -> Arc<SharedStore> {
        SharedStore::open_in_memory().expect("open")
    }

    /// Insert an item with a raw payload JSON object, returning its id.
    fn record(store: &SharedStore, schema: &str, payload_json: &str) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(id.clone(), schema.into(), payload_json.into())
            .expect("upsert");
        id
    }

    fn titled(store: &SharedStore, schema: &str, title: &str) -> String {
        record(
            store,
            schema,
            &format!(r#"{{"title": {}}}"#, json_str(title)),
        )
    }

    fn json_str(s: &str) -> String {
        serde_json::to_string(s).expect("encode")
    }

    #[test]
    fn search_all_spans_kinds_and_caps_each_one() {
        let store = store();
        for n in 0..8 {
            record(
                &store,
                "email-message",
                &format!(r#"{{"subject": "budget thread {n}", "from": "pi@example.edu"}}"#),
            );
        }
        let manuscript = titled(&store, "manuscript", "Budget narrative");
        let figure = titled(&store, "figure", "Budget breakdown");

        let hits = store.search_all("budget".into(), 2).expect("search");
        let mail = hits
            .iter()
            .filter(|h| h.schema_ref == "email-message")
            .count();
        assert_eq!(mail, 2, "the per-kind cap must bind: {hits:?}");
        let ids: Vec<&str> = hits.iter().map(|h| h.id.as_str()).collect();
        assert!(ids.contains(&manuscript.as_str()), "{hits:?}");
        assert!(ids.contains(&figure.as_str()), "{hits:?}");
        assert!(hits.iter().all(|h| !h.snippet.is_empty()));
    }

    /// A search field is typed by a human mid-thought; every one of these is
    /// an FTS5 syntax error if the string reaches MATCH unsanitized.
    #[test]
    fn search_all_survives_hostile_queries() {
        let store = store();
        titled(&store, "manuscript", "Dark matter halos");
        for hostile in ["foo AND (", "\"unbalanced", "NEAR(", "*", ")))", ""] {
            store
                .search_all(hostile.into(), 5)
                .unwrap_or_else(|e| panic!("{hostile:?} must not error: {e}"));
        }
        assert_eq!(
            store.search_all("dark".into(), 5).expect("search").len(),
            1,
            "a real query still works afterwards"
        );
    }

    #[test]
    fn search_all_withholds_dismissed_items() {
        let store = store();
        let live = titled(&store, "task", "Recalibrate the detector");
        let gone = record(
            &store,
            "task",
            r#"{"title": "Recalibrate someday", "status": "dismissed"}"#,
        );
        let hits = store.search_all("recalibrate".into(), 10).expect("search");
        let ids: Vec<&str> = hits.iter().map(|h| h.id.as_str()).collect();
        assert_eq!(ids, vec![live.as_str()], "dismissed leaked: {hits:?}");
        assert!(!ids.contains(&gone.as_str()));
    }

    #[test]
    fn related_items_walks_both_directions() {
        let store = store();
        let manuscript = titled(&store, "manuscript", "Draft II");
        let figure = titled(&store, "figure", "Rotation curve");
        let paper = titled(&store, "imbib/bibliography-entry", "Zwicky 1933");
        let task = titled(&store, "task", "Redo the fit");

        store
            .add_reference(manuscript.clone(), figure.clone(), "Contains".into())
            .expect("contains edge");
        store
            .add_reference(manuscript.clone(), paper.clone(), "Cites".into())
            .expect("cites edge");
        store
            .add_reference(task.clone(), manuscript.clone(), "ProducedBy".into())
            .expect("produced-by edge");

        let rows = store
            .related_items(manuscript.clone(), 10)
            .expect("related");
        assert_eq!(rows.len(), 3, "{rows:?}");

        let contains = rows.iter().find(|r| r.edge_type == "Contains").unwrap();
        assert_eq!(contains.id, figure);
        assert_eq!(contains.schema_ref, "figure");
        assert_eq!(contains.direction, "outgoing");

        let produced = rows.iter().find(|r| r.edge_type == "ProducedBy").unwrap();
        assert_eq!(produced.id, task);
        assert_eq!(produced.direction, "incoming");

        // Seen from the figure, the manuscript is the incoming half.
        let back = store.related_items(figure, 10).expect("related");
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].id, manuscript);
        assert_eq!(back[0].direction, "incoming");
        assert_eq!(back[0].title, "Draft II");
    }

    #[test]
    fn related_items_skips_deleted_ends_and_rejects_bad_ids() {
        let store = store();
        let manuscript = titled(&store, "manuscript", "Draft II");
        let kept = titled(&store, "figure", "Panel A");
        let doomed = titled(&store, "figure", "Panel B");
        store
            .add_reference(manuscript.clone(), kept.clone(), "Contains".into())
            .expect("edge");
        store
            .add_reference(manuscript.clone(), doomed.clone(), "Contains".into())
            .expect("edge");
        assert_eq!(
            store.related_items(manuscript.clone(), 10).unwrap().len(),
            2
        );

        store.delete_item(doomed).expect("delete");
        let rows = store.related_items(manuscript, 10).expect("related");
        assert_eq!(rows.len(), 1, "{rows:?}");
        assert_eq!(rows[0].id, kept);

        assert!(matches!(
            store.related_items("not-a-uuid".into(), 10),
            Err(SharedStoreError::InvalidArgument { .. })
        ));
        assert!(matches!(
            store.related_items(uuid::Uuid::new_v4().to_string(), 10),
            Err(SharedStoreError::NotFound { .. })
        ));
    }
}

// ─── Watched folders (ADR-0023 W2) ───────────────────────────────────────────
//
// The kernel's own semantics are pinned in `impress_core::watched_folder_ops`
// and in `DocsImportService`'s tests. What is proven HERE is the thing only
// this file can get wrong: that the eight Swift-facing methods carry the
// kernel's answers across the boundary intact — including the two that are
// easy to lose in a mirror, `unchanged` writing nothing and `removed_ids`
// coming back at all.
//
// Scratch stores and temp directories only.
#[cfg(test)]
mod watched_folder_tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    struct Scratch {
        dir: PathBuf,
    }

    impl Scratch {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!("watched-ffi-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&dir).expect("temp dir");
            Self { dir }
        }

        fn write(&self, name: &str, contents: &str) -> String {
            let path = self.dir.join(name);
            fs::write(&path, contents).expect("write");
            path.to_string_lossy().to_string()
        }

        fn path(&self) -> String {
            self.dir.to_string_lossy().to_string()
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.dir);
        }
    }

    /// A real publication row. The kernel refuses to attribute provenance to
    /// an id that names nothing — a dangling pointer is not provenance — so
    /// every produced id in these tests is a row that exists.
    fn publication(store: &SharedStore, title: &str) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        store
            .upsert_item(
                id.clone(),
                "bibliography-entry".into(),
                format!(r#"{{"title": "{title}"}}"#),
            )
            .expect("publication");
        id
    }

    fn discovered(path: &str) -> SharedDiscoveredFile {
        SharedDiscoveredFile {
            path: path.to_string(),
            content_hash: None,
            mtime: None,
            size_bytes: None,
            bookmark_base64: None,
        }
    }

    fn watched(store: &SharedStore, scratch: &Scratch) -> String {
        store
            .watched_folder_add(
                scratch.path(),
                "publication".into(),
                Some("Papers".into()),
                None,
                true,
            )
            .expect("add")
            .folder
            .id
    }

    #[test]
    fn adding_the_same_folder_twice_returns_the_same_row() {
        let store = SharedStore::open_in_memory().expect("open");
        let scratch = Scratch::new();

        let first = store
            .watched_folder_add(scratch.path(), "publication".into(), None, None, true)
            .expect("add");
        assert!(first.created, "the first add creates");

        let second = store
            .watched_folder_add(
                // Trailing slash: the kernel normalises it, and a mirror that
                // forwarded the raw string would mint a duplicate folder.
                format!("{}/", scratch.path()),
                "publication".into(),
                None,
                Some("Ym9va21hcms=".into()),
                true,
            )
            .expect("re-add");
        assert!(!second.created, "a re-add is a no-op, not a duplicate");
        assert_eq!(first.folder.id, second.folder.id);
        assert_eq!(
            second.folder.bookmark_base64.as_deref(),
            Some("Ym9va21hcms="),
            "re-adding with a fresh bookmark swaps it in — the re-grant path"
        );

        // Watching one directory for two kinds is two folders, on purpose.
        let other = store
            .watched_folder_add(scratch.path(), "manuscript".into(), None, None, true)
            .expect("add manuscript scope");
        assert!(other.created);
        assert_ne!(first.folder.id, other.folder.id);

        assert_eq!(store.watched_folder_list(None).expect("list").len(), 2);
        assert_eq!(
            store
                .watched_folder_list(Some("publication".into()))
                .expect("list scoped")
                .len(),
            1
        );
    }

    #[test]
    fn discovery_reports_created_then_unchanged_then_changed() {
        let store = SharedStore::open_in_memory().expect("open");
        let scratch = Scratch::new();
        let folder = watched(&store, &scratch);
        let bib = scratch.write("refs.bib", "@article{a2026, title={A}}");

        let first = store
            .watched_import_discovered(folder.clone(), vec![discovered(&bib)], false)
            .expect("first discovery");
        assert_eq!((first.created, first.changed, first.unchanged), (1, 0, 0));
        assert_eq!(first.kind_scope, "publication");
        assert_eq!(first.batches, 1);
        assert_eq!(first.files[0].action, "created");

        let again = store
            .watched_import_discovered(folder.clone(), vec![discovered(&bib)], false)
            .expect("second discovery");
        assert_eq!(
            (again.created, again.changed, again.unchanged),
            (0, 0, 1),
            "a settled tree must re-scan free — this is the property that keeps \
             a watcher out of the startup render loop"
        );
        assert_eq!(again.files[0].id, first.files[0].id, "same row, same id");

        fs::write(
            &bib,
            "@article{a2026, title={A}}\n@article{b2026, title={B}}",
        )
        .expect("edit");
        let edited = store
            .watched_import_discovered(folder, vec![discovered(&bib)], false)
            .expect("third discovery");
        assert_eq!(
            (edited.created, edited.changed, edited.unchanged),
            (0, 1, 0)
        );
        assert_eq!(edited.files[0].id, first.files[0].id, "changed in place");
    }

    #[test]
    fn produced_rows_round_trip_and_surface_what_a_re_import_orphaned() {
        let store = SharedStore::open_in_memory().expect("open");
        let scratch = Scratch::new();
        let folder = watched(&store, &scratch);
        let bib = scratch.write("refs.bib", "@article{a2026,}\n@article{b2026,}");

        let report = store
            .watched_import_discovered(folder.clone(), vec![discovered(&bib)], false)
            .expect("discovery");
        let file_id = report.files[0].id.clone();

        let one = publication(&store, "A");
        let two = publication(&store, "B");
        let attributed = store
            .watched_record_produced(file_id.clone(), vec![one.clone(), two.clone()], true)
            .expect("attribute");
        assert_eq!(attributed.added, 2);
        assert!(attributed.removed_ids.is_empty());
        assert_eq!(attributed.file.produced_ids.len(), 2);

        // The source lost an entry. `replace: true` is what makes that visible;
        // NOTHING is deleted here, and the id comes back for the app to decide
        // about.
        let after = store
            .watched_record_produced(file_id.clone(), vec![one.clone()], true)
            .expect("re-attribute");
        assert_eq!(after.removed_ids, vec![two.clone()]);
        assert_eq!(after.file.produced_ids, vec![one.clone()]);

        // And the union mode an incremental append wants.
        let unioned = store
            .watched_record_produced(file_id.clone(), vec![two.clone()], false)
            .expect("union");
        assert!(unioned.removed_ids.is_empty());
        assert_eq!(unioned.file.produced_ids.len(), 2);

        let page = store
            .watched_files_list(None, Some(file_id), None, 0, 0)
            .expect("by file id");
        assert_eq!(page.total, 1);
        assert_eq!(page.files[0].produced_ids.len(), 2);
        assert!(!page.files[0].needs_reimport);
    }

    #[test]
    fn a_vanished_file_is_marked_missing_and_never_deleted() {
        let store = SharedStore::open_in_memory().expect("open");
        let scratch = Scratch::new();
        let folder = watched(&store, &scratch);
        let kept = scratch.write("kept.bib", "@article{k,}");
        let doomed = scratch.write("doomed.bib", "@article{d,}");

        let report = store
            .watched_import_discovered(
                folder.clone(),
                vec![discovered(&kept), discovered(&doomed)],
                false,
            )
            .expect("discovery");
        assert_eq!(report.created, 2);
        let doomed_row = report
            .files
            .iter()
            .find(|f| f.path == doomed)
            .expect("row")
            .id
            .clone();
        let produced = publication(&store, "D");
        store
            .watched_record_produced(doomed_row.clone(), vec![produced.clone()], true)
            .expect("attribute");

        fs::remove_file(&doomed).expect("delete");

        let scan = store
            .watched_finish_scan(folder.clone(), Some(2), Some(0), Some(12), false)
            .expect("sweep");
        assert_eq!(
            (scan.examined, scan.present, scan.marked_missing),
            (2, 1, 1)
        );
        assert_eq!(scan.missing.len(), 1);
        assert_eq!(scan.missing[0].path, doomed);
        let stats = scan.folder.expect("folder stats");
        assert_eq!(stats.last_scan_file_count, 1);
        assert_eq!(stats.last_scan_missing_count, 1);
        assert_eq!(stats.last_scan_duration_ms, 12);

        // The row and its provenance survive. This is D4's whole point.
        let still_there = store
            .watched_files_list(None, Some(doomed_row), None, 0, 0)
            .expect("read back");
        assert_eq!(still_there.total, 1);
        assert_eq!(still_there.files[0].state, "missing");
        assert_eq!(still_there.files[0].produced_ids, vec![produced]);

        let missing_only = store
            .watched_files_list(Some(folder), None, Some("missing".into()), 0, 0)
            .expect("filtered");
        assert_eq!(missing_only.total, 1);
    }

    #[test]
    fn a_sweep_over_an_unreachable_root_refuses_and_declares_the_volume() {
        let store = SharedStore::open_in_memory().expect("open");
        let scratch = Scratch::new();
        let folder = watched(&store, &scratch);
        let bib = scratch.write("refs.bib", "@article{a,}");
        store
            .watched_import_discovered(folder.clone(), vec![discovered(&bib)], false)
            .expect("discovery");

        fs::remove_dir_all(&scratch.dir).expect("unmount the volume, so to speak");

        let refused = store.watched_finish_scan(folder.clone(), None, None, None, false);
        assert!(
            refused.is_err(),
            "a whole library must not be marked missing because its volume went away"
        );

        let declared = store
            .watched_folder_list(None)
            .expect("list")
            .into_iter()
            .find(|f| f.id == folder)
            .expect("folder");
        assert_eq!(
            declared.volume_state.as_deref(),
            Some("unavailable"),
            "D6: the folder DECLARES the state rather than reporting an honest-looking zero"
        );
    }

    #[test]
    fn removing_a_folder_keeps_the_rows_its_files_produced() {
        let store = SharedStore::open_in_memory().expect("open");
        let scratch = Scratch::new();
        let folder = watched(&store, &scratch);
        let bib = scratch.write("refs.bib", "@article{a,}");
        let report = store
            .watched_import_discovered(folder.clone(), vec![discovered(&bib)], false)
            .expect("discovery");
        let file_id = report.files[0].id.clone();

        let row = publication(&store, "A");
        store
            .watched_record_produced(file_id, vec![row.clone()], true)
            .expect("attribute");

        let removal = store
            .watched_folder_remove(folder.clone(), false)
            .expect("remove");
        assert!(removal.removed);
        assert_eq!(
            removal.file_rows_deleted, 0,
            "provenance is kept unless the caller asks otherwise"
        );
        assert!(
            store.get_item(row).expect("read").is_some(),
            "un-watching a folder is not a retraction of what it imported"
        );

        assert!(
            !store
                .watched_folder_remove(folder, false)
                .expect("second remove")
                .removed
        );
    }

    #[test]
    fn update_leaves_omitted_fields_alone() {
        let store = SharedStore::open_in_memory().expect("open");
        let scratch = Scratch::new();
        let folder = store
            .watched_folder_add(
                scratch.path(),
                "publication".into(),
                Some("Papers".into()),
                Some("Ym9va21hcms=".into()),
                true,
            )
            .expect("add")
            .folder;

        let paused = store
            .watched_folder_update(folder.id.clone(), Some(false), None, None, None, None)
            .expect("pause");
        assert!(!paused.enabled);
        assert_eq!(
            paused.bookmark_base64.as_deref(),
            Some("Ym9va21hcms="),
            "pausing a folder must not blank its bookmark by omission"
        );
        assert_eq!(paused.display_name, "Papers");
        assert!(paused.recursive);

        let declared = store
            .watched_folder_update(folder.id, None, None, None, None, Some("unindexed".into()))
            .expect("declare");
        assert_eq!(declared.volume_state.as_deref(), Some("unindexed"));
        assert!(!declared.enabled, "still paused");
    }

    #[test]
    fn a_dry_run_writes_nothing() {
        let store = SharedStore::open_in_memory().expect("open");
        let scratch = Scratch::new();
        let folder = watched(&store, &scratch);
        let bib = scratch.write("refs.bib", "@article{a,}");

        let planned = store
            .watched_import_discovered(folder.clone(), vec![discovered(&bib)], true)
            .expect("dry run");
        assert_eq!(planned.created, 1, "the counts are the real run's counts");
        assert_eq!(
            store
                .watched_files_list(Some(folder), None, None, 0, 0)
                .expect("list")
                .total,
            0,
            "and nothing was written"
        );
    }
}
