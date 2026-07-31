//! Watched-folder bookkeeping — the Rust half of ADR-0023 (WP W0).
//!
//! # Why this is a kernel in `impress-core` and not a module of the service
//!
//! W0 wrote it as `impress_store_service::watched_folder`, because at that
//! point the agent-facing verbs were its only consumer. W2 added the second:
//! Swift reaches these same verbs through `SharedStore` (`impress-store-ffi`),
//! and an FFI shim that depended on the *service* crate would drag the whole
//! MCP/CLI machinery — `inventory` registrations, `tokio`, `async-trait` — into
//! every app binary on both platforms, to call functions that are synchronous
//! and know nothing about any of it.
//!
//! So it moved here, into the shape the suite already uses for exactly this:
//! [`crate::collection_ops`] is the kernel, `CollectionService` is its
//! agent-facing twin, and `SharedStore::collection_*` is its Swift twin — the
//! triangle `impress-store-service`'s own crate docs describe. Nothing about
//! the module changed in the move except its address:
//! `impress_store_service::watched_folder` is still a valid path (a re-export),
//! and the eight service verbs are untouched.
//!
//! ADR-0023 D5 draws the line: **discovery is Swift, everything below it is
//! Rust.** `NSMetadataQuery` and security-scoped bookmarks are platform policy;
//! parsing, id derivation, provenance and the re-scan diff are logic, and logic
//! lives here so the CLI, MCP and a headless test can drive it with every app
//! closed.
//!
//! This module owns the *file-level* bookkeeping for both ingest units (D3):
//! which files a watched folder has seen, what their content hashes were, and
//! which store rows each file produced. It does **not** parse anything and it
//! does not know what a BibTeX entry is. The fan-out from a discovered `.bib`
//! to publication rows runs through imbib's real importer, and it reports back
//! through [`record_produced`] — that is the W2 seam, and it is deliberately a
//! seam rather than a call, because the alternative is this crate growing a
//! dependency on every app's importer.
//!
//! # The D4 semantics, in one table
//!
//! | Situation | What happens |
//! |---|---|
//! | Path not seen before | Insert a `watched-file@1.0.0` row: provenance, hash, mtime, `state: present` |
//! | Path seen, hash changed | Update hash/mtime/size in place, same id. `produced_ids` is left alone — it is now STALE, and `produced_for_hash != content_hash` (surfaced as `needs_reimport`) is how a caller knows |
//! | Path seen, hash identical | **Nothing is written.** Not the row, not a timestamp, not a scan stamp |
//! | Path gone from disk | [`sweep_missing`] flips `state` to `missing` and stamps `missing_since`. The row is **never deleted** |
//! | Path back after being missing | `state` returns to `present`, `missing_since` cleared, same id |
//!
//! # Why missing-detection stats the filesystem instead of stamping rows
//!
//! The obvious design gives each scan a generation token, stamps every file it
//! touches, and sweeps the rows that did not get stamped. It is also the design
//! that makes an unchanged re-scan cost one write per file — which would defeat
//! the "re-run writes nothing" property that the whole idempotency claim rests
//! on, and would fire `.storeDidMutate` for a scan that found no news (the
//! startup render-loop failure mode, root CLAUDE.md).
//!
//! So [`sweep_missing`] asks the filesystem instead: for every row this folder
//! still calls `present`, does the path exist? That needs no per-row stamp, no
//! caller state, and no call ever carrying the whole tree — so it works
//! identically for a live `NSMetadataQuery` update and a full manual walk.
//!
//! It has one hazard, and it is guarded: if the *volume* went away, every path
//! stops existing at once and a naive sweep would mark a whole library missing.
//! [`sweep_missing`] therefore refuses to run when the folder's own root is not
//! reachable, and says so (ADR-0023 D6 — the folder row must never render an
//! unavailable volume as an honest-looking zero).
//!
//! # The first watch of a large tree — the burst analysis (ADR-0023 D7)
//!
//! ADR-0023's stated risk is "ingest bursts on first watch of a huge tree". The
//! shape to fear is the one `task_schema_migration` writes down for the
//! scheduler: an unbounded set of rows entering some consumer's reach all at
//! once, each write fanning out into operation-journal rows and
//! `.storeDidMutate` notifications, during the window the UI is least able to
//! absorb them.
//!
//! What actually bounds it, in decreasing order of how load-bearing each is:
//!
//! 1. **The steady state is not a scan.** `NSMetadataQuery` is *live*
//!    (ADR-0023 D7), so after the first pass a watched folder produces one
//!    discovery call per file the user touches. The burst is a one-time
//!    startup cost per folder, not a recurring poll — which is why the
//!    zero-write property below is the thing that matters most in the long run
//!    and the batch size matters most on day one.
//! 2. **An unchanged file writes nothing.** Not a row, not a timestamp, not a
//!    scan stamp (this is why missing-detection stats the filesystem instead of
//!    stamping — see above). So the SECOND watch of a 10 000-file tree, and
//!    every watch after it, costs zero writes and fires zero store mutations.
//!    Measured by `an_unchanged_rescan_writes_nothing_at_all`, which compares
//!    `Item::modified` and `logical_clock` rather than trusting the counts.
//! 3. **The write gate.** [`MAX_DISCOVERY_BATCH`] is 500, the shipped
//!    store-mirror bound (`ImpressStoreKit.StoreMirrorWriteGate`). Input is
//!    sorted by path and chunked into batches of that size, so the first pass
//!    is ordered and resumable rather than one unbounded transaction.
//!    Measured by `discovery_chunks_at_the_write_gate_bound`.
//! 4. **The per-call ceiling.** [`MAX_DISCOVERED_FILES_PER_CALL`] is ten
//!    batches. A caller sending more is REJECTED with the bound named, not
//!    truncated — silently ingesting a prefix is how a watcher comes to believe
//!    it has scanned a tree it has not. Paging is always available because a
//!    batch never has to be a complete set. Measured by
//!    `a_call_over_the_per_call_bound_is_rejected_with_instructions`.
//! 5. **The fan-out is a separate verb.** Discovery writes ONE index row per
//!    file and never parses anything, so the expensive half — imbib's importer
//!    with its whole-library identifier dedup — is driven per file by the
//!    caller, at whatever rate the caller chooses, and is trivially resumable
//!    from `needs_reimport`. A tree of 10 000 `.bib` files costs 10 000 small
//!    inserts here, not 10 000 parses and a dedup pass against a growing
//!    library.
//!
//! So the first-watch cost is `ceil(N / 500)` bounded write batches of one
//! small row each, plus one `stat()` per file at sweep time, and every
//! subsequent watch of the same unchanged tree is free. The 90-second
//! background-service embargo (root CLAUDE.md) is W1's to honour — it owns
//! when discovery starts; nothing here schedules itself.
//!
//! The two costs this does NOT bound, recorded rather than hidden:
//! [`sweep_missing`] loads every `present` row of one folder into memory before
//! chunking its writes (bounded by the folder's file count, not by a constant),
//! and [`list_folders`] is unpaged. Both are fine at the sizes a watched folder
//! reaches and both become paging work the day a folder holds a hundred
//! thousand files.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use crate::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use crate::manuscript_ops::{iso8601_now, sha256_bytes_hex};
use crate::query::{ItemQuery, Predicate};
use crate::reference::{EdgeType, TypedReference};
use crate::schemas::watched_folder::{
    FILE_STATE_MISSING, FILE_STATE_PRESENT, VOLUME_STATES, VOLUME_STATE_UNAVAILABLE,
    WATCHED_FILE_SCHEMA, WATCHED_FOLDER_SCHEMA,
};
use crate::sqlite_store::SqliteItemStore;
use crate::store::{FieldMutation, ItemStore, StoreError};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Deterministic identity
// ---------------------------------------------------------------------------

/// Fixed namespace for every watched-folder row.
///
/// Derived ONCE as `UUIDv5(NAMESPACE_DNS, "store.impress.watched-folder")` and
/// hardcoded, exactly as `impress_store_service::DOCS_IMPORT_NAMESPACE`
/// and `DeterministicID.impartNamespace` are. **Never change it** — a new
/// namespace forks every watched folder in every store into a duplicate, and
/// takes the provenance of every file with it.
pub const WATCHED_FOLDER_NAMESPACE: &str = "f54fd9f7-3dd3-5c74-b3c9-519e1c0c5843";

/// Fixed namespace for every discovered-file row.
/// `UUIDv5(NAMESPACE_DNS, "store.impress.watched-file")`. Same rule.
pub const WATCHED_FILE_NAMESPACE: &str = "d01f64e8-aa2a-5067-a702-26618b75eff9";

/// The write-gate batch size (ADR-0023 D7), matching the shipped store-mirror
/// bound. Discovery input is sorted and chunked into batches of this size.
pub const MAX_DISCOVERY_BATCH: usize = 500;

/// Ten batches. A call carrying more is rejected with instructions rather than
/// truncated: silently ingesting a prefix of what the caller sent is how a
/// watcher comes to believe it has scanned a tree it has not.
pub const MAX_DISCOVERED_FILES_PER_CALL: usize = MAX_DISCOVERY_BATCH * 10;

/// How many rows a single query result carries by default.
pub const DEFAULT_FILE_LIST_LIMIT: i64 = 200;

/// Hard ceiling on one `list_files` page.
pub const MAX_FILE_LIST_LIMIT: i64 = 2_000;

/// The stable key a folder's id is derived from: `"<kind_scope>/<path>"`,
/// lowercased and with trailing slashes stripped.
///
/// The kind scope is IN the key on purpose: watching one directory for `.bib`
/// files and watching it again for manuscripts are two folders, with two file
/// sets and two provenances, and collapsing them onto one id would make the
/// second `add` silently reconfigure the first.
pub fn watched_folder_key(path: &str, kind_scope: &str) -> String {
    format!(
        "{}/{}",
        kind_scope.trim(),
        normalize_dir_path(path).trim_start_matches('/')
    )
    .to_lowercase()
}

/// The deterministic id of a watched folder.
pub fn watched_folder_id(path: &str, kind_scope: &str) -> Uuid {
    let namespace =
        Uuid::parse_str(WATCHED_FOLDER_NAMESPACE).expect("folder namespace constant is a UUID");
    Uuid::new_v5(&namespace, watched_folder_key(path, kind_scope).as_bytes())
}

/// The stable key a discovered file's id is derived from:
/// `"<watched folder id>/<absolute path>"`, lowercased.
///
/// Scoped by the FOLDER rather than keyed on the path alone, so the same file
/// discovered by two watched folders gets two rows with two provenances —
/// which is correct, because deleting one of those folders must not orphan the
/// other's record of it.
///
/// The consequence to know: the key holds the ABSOLUTE path, so moving a
/// watched tree re-derives every id. The old rows go `missing` (never deleted)
/// and the new ones import fresh; imbib's identifier dedup then collapses the
/// duplicate entries. That is the same trade `document_key` makes by scoping on
/// the collection name, and relative-to-root keying is the recorded follow-up.
pub fn watched_file_key(watched_folder_id: &str, path: &str) -> String {
    format!(
        "{}/{}",
        watched_folder_id.trim().to_lowercase(),
        path.trim()
    )
    .to_lowercase()
}

/// The deterministic id of a discovered file.
pub fn watched_file_id(watched_folder_id: &str, path: &str) -> Uuid {
    let namespace =
        Uuid::parse_str(WATCHED_FILE_NAMESPACE).expect("file namespace constant is a UUID");
    Uuid::new_v5(
        &namespace,
        watched_file_key(watched_folder_id, path).as_bytes(),
    )
}

/// Strip trailing separators so `/docs` and `/docs/` are one folder.
fn normalize_dir_path(path: &str) -> String {
    let trimmed = path.trim();
    let stripped = trimmed.trim_end_matches('/');
    if stripped.is_empty() {
        trimmed.to_string()
    } else {
        stripped.to_string()
    }
}

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// One file the caller discovered. `content_hash`, `mtime` and `size_bytes` are
/// optional: Swift already has them from the metadata query and passes them, and
/// a CLI/MCP caller who does not is served by this module reading them off the
/// filesystem itself. A caller who passes a hash is trusted — this is not the
/// place to re-read every file to check.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct DiscoveredFileInput {
    /// Absolute POSIX path of the file.
    pub path: String,
    /// SHA-256 hex of the file's bytes. Null means "read and hash it for me".
    #[serde(default)]
    pub content_hash: Option<String>,
    /// ISO-8601 modification time. Null means "read it for me".
    #[serde(default)]
    pub mtime: Option<String>,
    /// Size in bytes. Null means "read it for me".
    #[serde(default)]
    pub size_bytes: Option<i64>,
    /// Base64 of a per-file security-scoped bookmark, for reference-in-place
    /// records that must reopen the file after a relaunch (D4).
    #[serde(default)]
    pub bookmark_base64: Option<String>,
}

/// A watched folder as the store holds it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct WatchedFolderDto {
    pub id: String,
    pub path: String,
    pub kind_scope: String,
    pub display_name: String,
    pub enabled: bool,
    pub recursive: bool,
    /// One of `crate::schemas::watched_folder::VOLUME_STATES`, or null
    /// when the platform has not declared one yet.
    pub volume_state: Option<String>,
    /// Base64 security-scoped bookmark, when one was stored. Present so the
    /// Swift side can resolve access without a second read.
    pub bookmark_base64: Option<String>,
    pub last_scan_at: Option<String>,
    pub last_scan_file_count: i64,
    pub last_scan_new_count: i64,
    pub last_scan_changed_count: i64,
    pub last_scan_missing_count: i64,
    pub last_scan_duration_ms: i64,
}

/// A discovered file as the store holds it.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct WatchedFileDto {
    pub id: String,
    pub watched_folder_id: String,
    pub path: String,
    pub content_hash: String,
    /// `"present"` | `"missing"`.
    pub state: String,
    pub kind_scope: String,
    pub mtime: Option<String>,
    pub size_bytes: i64,
    pub first_seen_at: Option<String>,
    pub last_seen_at: Option<String>,
    pub missing_since: Option<String>,
    /// Store rows this file produced. Empty AND `produced_at == null` means the
    /// fan-out has not run; empty with a `produced_at` means it ran and produced
    /// nothing.
    pub produced_ids: Vec<String>,
    pub produced_at: Option<String>,
    /// True when the content changed after the last fan-out — the queue W2's
    /// importer drains.
    pub needs_reimport: bool,
}

/// What one file's pass through discovery did.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct DiscoveredFileOutcome {
    pub id: String,
    pub path: String,
    /// `"created"` | `"changed"` | `"unchanged"` | `"restored"`.
    ///
    /// `"changed"` and `"restored"` are the two that need the app's importer
    /// run again; `"unchanged"` wrote nothing at all.
    pub action: String,
    pub content_hash: String,
}

/// A file discovery declined to record, and why.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
pub struct SkippedFile {
    pub path: String,
    pub reason: String,
}

// ---------------------------------------------------------------------------
// Item <-> DTO
// ---------------------------------------------------------------------------

fn string_field(item: &Item, field: &str) -> Option<String> {
    match item.payload.get(field) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn int_field(item: &Item, field: &str) -> i64 {
    match item.payload.get(field) {
        Some(Value::Int(i)) => *i,
        Some(Value::Float(f)) => *f as i64,
        _ => 0,
    }
}

fn bool_field(item: &Item, field: &str, default: bool) -> bool {
    match item.payload.get(field) {
        Some(Value::Bool(b)) => *b,
        _ => default,
    }
}

fn string_array_field(item: &Item, field: &str) -> Option<Vec<String>> {
    match item.payload.get(field) {
        Some(Value::Array(values)) => Some(
            values
                .iter()
                .filter_map(|v| match v {
                    Value::String(s) => Some(s.clone()),
                    _ => None,
                })
                .collect(),
        ),
        _ => None,
    }
}

fn folder_dto(item: &Item) -> WatchedFolderDto {
    let path = string_field(item, "path").unwrap_or_default();
    let fallback_name = Path::new(&path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| path.clone());
    WatchedFolderDto {
        id: item.id.to_string(),
        path,
        kind_scope: string_field(item, "kind_scope").unwrap_or_default(),
        display_name: string_field(item, "display_name").unwrap_or(fallback_name),
        enabled: bool_field(item, "enabled", true),
        recursive: bool_field(item, "recursive", true),
        volume_state: string_field(item, "volume_state"),
        bookmark_base64: string_field(item, "bookmark_base64"),
        last_scan_at: string_field(item, "last_scan_at"),
        last_scan_file_count: int_field(item, "last_scan_file_count"),
        last_scan_new_count: int_field(item, "last_scan_new_count"),
        last_scan_changed_count: int_field(item, "last_scan_changed_count"),
        last_scan_missing_count: int_field(item, "last_scan_missing_count"),
        last_scan_duration_ms: int_field(item, "last_scan_duration_ms"),
    }
}

fn file_dto(item: &Item) -> WatchedFileDto {
    let produced_ids = string_array_field(item, "produced_ids");
    let produced_at = string_field(item, "produced_at");
    let last_seen_at = string_field(item, "last_seen_at");
    let content_hash = string_field(item, "content_hash").unwrap_or_default();
    let state = string_field(item, "state").unwrap_or_else(|| FILE_STATE_PRESENT.to_string());
    // "Does this file still owe the importer a run?" — a CONTENT comparison,
    // not a timestamp one. `iso8601_now` has one-second resolution, so an edit
    // and an import landing in the same second would compare equal and the
    // re-import would silently never be queued.
    let needs_reimport = if state == FILE_STATE_MISSING {
        false
    } else if produced_at.is_none() {
        true
    } else {
        string_field(item, "produced_for_hash").as_deref() != Some(content_hash.as_str())
    };
    WatchedFileDto {
        id: item.id.to_string(),
        watched_folder_id: string_field(item, "watched_folder_id").unwrap_or_default(),
        path: string_field(item, "path").unwrap_or_default(),
        content_hash,
        state,
        kind_scope: string_field(item, "kind_scope").unwrap_or_default(),
        mtime: string_field(item, "mtime"),
        size_bytes: int_field(item, "size_bytes"),
        first_seen_at: string_field(item, "first_seen_at"),
        last_seen_at,
        missing_since: string_field(item, "missing_since"),
        produced_ids: produced_ids.unwrap_or_default(),
        produced_at,
        needs_reimport,
    }
}

/// A bare item with a CALLER-CHOSEN id — the basis of idempotency here, as it
/// is in `docs_import_service::new_manuscript`.
fn new_item(
    id: Uuid,
    schema: &str,
    payload: BTreeMap<String, Value>,
    parent: Option<ItemId>,
) -> Item {
    let now = chrono::Utc::now();
    Item {
        id,
        schema: schema.into(),
        payload,
        created: now,
        modified: now,
        author: "impress-store-service:watched-folder".into(),
        author_kind: ActorKind::System,
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
        parent,
    }
}

// ---------------------------------------------------------------------------
// Folder CRUD
// ---------------------------------------------------------------------------

/// Load a watched-folder item by id string, rejecting an id held by anything
/// else. Returns `Ok(None)` for "no such folder".
pub fn load_folder(store: &SqliteItemStore, id: &str) -> Result<Option<Item>, String> {
    let uuid = Uuid::parse_str(id.trim()).map_err(|_| format!("'{id}' is not a UUID"))?;
    let item = store.get(uuid).map_err(|e| e.to_string())?;
    match item {
        Some(item) if item.schema == WATCHED_FOLDER_SCHEMA => Ok(Some(item)),
        Some(item) => Err(format!(
            "{id} is a '{}' item, not a watched folder",
            item.schema
        )),
        None => Ok(None),
    }
}

/// Create — or return unchanged — the watched folder for `(path, kind_scope)`.
///
/// Idempotent by construction: the id is derived from the pair, so adding the
/// same folder twice is a no-op that returns the existing row rather than a
/// second one. The bool is `created`.
pub fn create_folder(
    store: &SqliteItemStore,
    path: &str,
    kind_scope: &str,
    display_name: Option<&str>,
    bookmark_base64: Option<&str>,
    recursive: bool,
) -> Result<(WatchedFolderDto, bool), String> {
    let path = normalize_dir_path(path);
    if path.is_empty() {
        return Err("path must not be empty".into());
    }
    let kind_scope = kind_scope.trim();
    if kind_scope.is_empty() {
        return Err("kind_scope must not be empty — it is the key into the \
                    record kind's FileDiscoveryCapability"
            .into());
    }
    let id = watched_folder_id(&path, kind_scope);

    if let Some(existing) = store.get(id).map_err(|e| e.to_string())? {
        if existing.schema != WATCHED_FOLDER_SCHEMA {
            return Err(format!(
                "deterministic id {id} is already held by a '{}' item",
                existing.schema
            ));
        }
        // Re-adding a folder is how the Swift side hands over a REFRESHED
        // bookmark (they expire, and a re-grant produces new bytes). Take the
        // new one; leave everything else alone, because this call is not an
        // edit verb.
        if let Some(bookmark) = bookmark_base64.filter(|b| !b.trim().is_empty()) {
            if string_field(&existing, "bookmark_base64").as_deref() != Some(bookmark) {
                store
                    .update(
                        id,
                        vec![FieldMutation::SetPayload(
                            "bookmark_base64".into(),
                            Value::String(bookmark.to_string()),
                        )],
                    )
                    .map_err(|e| e.to_string())?;
                let refreshed = store
                    .get(id)
                    .map_err(|e| e.to_string())?
                    .ok_or("folder vanished mid-update")?;
                return Ok((folder_dto(&refreshed), false));
            }
        }
        return Ok((folder_dto(&existing), false));
    }

    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert("path".into(), Value::String(path.clone()));
    payload.insert("kind_scope".into(), Value::String(kind_scope.to_string()));
    payload.insert("enabled".into(), Value::Bool(true));
    payload.insert("recursive".into(), Value::Bool(recursive));
    if let Some(name) = display_name.map(str::trim).filter(|n| !n.is_empty()) {
        payload.insert("display_name".into(), Value::String(name.to_string()));
    }
    if let Some(bookmark) = bookmark_base64.map(str::trim).filter(|b| !b.is_empty()) {
        payload.insert(
            "bookmark_base64".into(),
            Value::String(bookmark.to_string()),
        );
    }
    store
        .insert(new_item(id, WATCHED_FOLDER_SCHEMA, payload, None))
        .map_err(|e| e.to_string())?;
    let item = store
        .get(id)
        .map_err(|e| e.to_string())?
        .ok_or("folder vanished after insert")?;
    Ok((folder_dto(&item), true))
}

/// Every watched folder, optionally narrowed to one `kind_scope`, in path order.
pub fn list_folders(
    store: &SqliteItemStore,
    kind_scope: Option<&str>,
) -> Result<Vec<WatchedFolderDto>, String> {
    let mut predicates = Vec::new();
    if let Some(scope) = kind_scope.map(str::trim).filter(|s| !s.is_empty()) {
        predicates.push(Predicate::Eq(
            "payload.kind_scope".into(),
            Value::String(scope.to_string()),
        ));
    }
    let q = ItemQuery {
        schema: Some(WATCHED_FOLDER_SCHEMA.into()),
        predicates,
        include_tags: false,
        include_references: false,
        ..Default::default()
    };
    let mut rows: Vec<WatchedFolderDto> = store
        .query(&q)
        .map_err(|e| e.to_string())?
        .iter()
        .map(folder_dto)
        .collect();
    rows.sort_by(|a, b| (&a.path, &a.kind_scope).cmp(&(&b.path, &b.kind_scope)));
    Ok(rows)
}

/// Apply the mutable facets of a folder. Every argument is optional; `None`
/// leaves the field as it was, so a caller flipping `enabled` cannot
/// accidentally blank the bookmark.
#[allow(clippy::too_many_arguments)]
pub fn update_folder(
    store: &SqliteItemStore,
    id: &str,
    enabled: Option<bool>,
    recursive: Option<bool>,
    display_name: Option<&str>,
    bookmark_base64: Option<&str>,
    volume_state: Option<&str>,
) -> Result<WatchedFolderDto, String> {
    let item = load_folder(store, id)?.ok_or_else(|| format!("no watched folder {id}"))?;
    if let Some(state) = volume_state.map(str::trim).filter(|s| !s.is_empty()) {
        if !VOLUME_STATES.contains(&state) {
            return Err(format!(
                "volume_state '{state}' is not one of {VOLUME_STATES:?}"
            ));
        }
    }
    let mut mutations = Vec::new();
    if let Some(enabled) = enabled {
        if bool_field(&item, "enabled", true) != enabled {
            mutations.push(FieldMutation::SetPayload(
                "enabled".into(),
                Value::Bool(enabled),
            ));
        }
    }
    if let Some(recursive) = recursive {
        if bool_field(&item, "recursive", true) != recursive {
            mutations.push(FieldMutation::SetPayload(
                "recursive".into(),
                Value::Bool(recursive),
            ));
        }
    }
    for (field, value) in [
        ("display_name", display_name),
        ("bookmark_base64", bookmark_base64),
        ("volume_state", volume_state),
    ] {
        if let Some(value) = value.map(str::trim).filter(|v| !v.is_empty()) {
            if string_field(&item, field).as_deref() != Some(value) {
                mutations.push(FieldMutation::SetPayload(
                    field.into(),
                    Value::String(value.to_string()),
                ));
            }
        }
    }
    if !mutations.is_empty() {
        store
            .update(item.id, mutations)
            .map_err(|e| e.to_string())?;
    }
    let refreshed = store
        .get(item.id)
        .map_err(|e| e.to_string())?
        .ok_or("folder vanished mid-update")?;
    Ok(folder_dto(&refreshed))
}

/// Forget a watched folder. `delete_file_rows` additionally removes its
/// `watched-file` index entries.
///
/// **Never touches a byte on disk.** ADR-0023 D4's reference-in-place rule is
/// one-way: the store row is an index entry and the file is the user's. Removing
/// the folder removes the index, not the library.
///
/// The rows the files PRODUCED are also left alone — a publication imported from
/// a watched `.bib` is a publication, and un-watching the folder it came from is
/// not a retraction of it.
pub fn remove_folder(
    store: &SqliteItemStore,
    id: &str,
    delete_file_rows: bool,
) -> Result<(bool, u32), String> {
    let Some(item) = load_folder(store, id)? else {
        return Ok((false, 0));
    };
    let mut deleted = 0u32;
    if delete_file_rows {
        for file in query_files(store, &item.id.to_string(), None)? {
            store.delete(file.id).map_err(|e| e.to_string())?;
            deleted += 1;
        }
    }
    store.delete(item.id).map_err(|e| e.to_string())?;
    Ok((true, deleted))
}

// ---------------------------------------------------------------------------
// File queries
// ---------------------------------------------------------------------------

/// Every `watched-file` item of one folder, optionally narrowed by `state`.
/// Sorted by path so a report and a re-run agree.
fn query_files(
    store: &SqliteItemStore,
    watched_folder_id: &str,
    state: Option<&str>,
) -> Result<Vec<Item>, String> {
    let mut predicates = vec![Predicate::Eq(
        "payload.watched_folder_id".into(),
        Value::String(watched_folder_id.trim().to_lowercase()),
    )];
    if let Some(state) = state {
        predicates.push(Predicate::Eq(
            "payload.state".into(),
            Value::String(state.to_string()),
        ));
    }
    let q = ItemQuery {
        schema: Some(WATCHED_FILE_SCHEMA.into()),
        predicates,
        include_tags: false,
        include_references: false,
        ..Default::default()
    };
    let mut items = store.query(&q).map_err(|e| e.to_string())?;
    items.sort_by_key(|a| string_field(a, "path"));
    Ok(items)
}

/// "Which files does watched-folder X know about?" — and, given `file_id`, the
/// one row whose `produced_ids` answers "which rows did file Y produce?".
///
/// Returns `(page, total)`; `total` is the unpaged match count, so a caller can
/// tell "200 of 4000" from "200 of 200".
pub fn list_files(
    store: &SqliteItemStore,
    watched_folder_id: Option<&str>,
    file_id: Option<&str>,
    state: Option<&str>,
    limit: i64,
    offset: i64,
) -> Result<(Vec<WatchedFileDto>, u32), String> {
    if let Some(state) = state {
        if state != FILE_STATE_PRESENT && state != FILE_STATE_MISSING {
            return Err(format!(
                "state '{state}' is neither '{FILE_STATE_PRESENT}' nor '{FILE_STATE_MISSING}'"
            ));
        }
    }
    // A file id is a direct fetch: no scan, and it answers the provenance
    // question ("rows produced by file Y") in one read.
    if let Some(file_id) = file_id.map(str::trim).filter(|f| !f.is_empty()) {
        let uuid = Uuid::parse_str(file_id).map_err(|_| format!("'{file_id}' is not a UUID"))?;
        let Some(item) = store.get(uuid).map_err(|e| e.to_string())? else {
            return Ok((Vec::new(), 0));
        };
        if item.schema != WATCHED_FILE_SCHEMA {
            return Err(format!(
                "{file_id} is a '{}' item, not a discovered file",
                item.schema
            ));
        }
        return Ok((vec![file_dto(&item)], 1));
    }

    let folder_id = watched_folder_id
        .map(str::trim)
        .filter(|f| !f.is_empty())
        .ok_or("one of watched_folder_id or file_id is required")?;
    let items = query_files(store, folder_id, state)?;
    let total = items.len() as u32;
    let limit = limit.clamp(1, MAX_FILE_LIST_LIMIT) as usize;
    let offset = offset.max(0) as usize;
    let page = items
        .iter()
        .skip(offset)
        .take(limit)
        .map(file_dto)
        .collect();
    Ok((page, total))
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

/// What one `import_discovered` pass did.
pub struct DiscoveryOutcome {
    pub created: u32,
    pub changed: u32,
    pub unchanged: u32,
    pub restored: u32,
    pub batches: u32,
    pub files: Vec<DiscoveredFileOutcome>,
    pub skipped: Vec<SkippedFile>,
}

/// Record a batch of discovered files against a watched folder.
///
/// See the module docs for the full D4 table. The property this function exists
/// to hold: **an unchanged file produces no write at all** — no row, no
/// timestamp, no stamp — so re-running discovery over a settled tree costs
/// nothing and fires no store mutation.
///
/// Paths are sorted and processed in [`MAX_DISCOVERY_BATCH`] chunks so a first
/// scan of a large tree is ordered and bounded (ADR-0023 D7).
pub fn upsert_discovered(
    store: &SqliteItemStore,
    folder: &Item,
    files: &[DiscoveredFileInput],
    dry_run: bool,
) -> Result<DiscoveryOutcome, String> {
    if files.len() > MAX_DISCOVERED_FILES_PER_CALL {
        return Err(format!(
            "{} files in one call exceeds the {MAX_DISCOVERED_FILES_PER_CALL} bound \
             (ADR-0023 D7). Send bounded batches — a discovery batch never has to \
             be a complete set, because missing files are found by \
             finish_watched_scan, not by absence from a batch.",
            files.len()
        ));
    }
    let folder_id = folder.id.to_string();
    let kind_scope = string_field(folder, "kind_scope").unwrap_or_default();

    // Sorted and deduped by path: a report and its re-run must agree, and a
    // watcher that reports one path twice in a burst must not write it twice.
    let mut sorted: Vec<&DiscoveredFileInput> = files.iter().collect();
    sorted.sort_by(|a, b| a.path.cmp(&b.path));
    sorted.dedup_by(|a, b| a.path == b.path);

    let mut outcome = DiscoveryOutcome {
        created: 0,
        changed: 0,
        unchanged: 0,
        restored: 0,
        batches: 0,
        files: Vec::new(),
        skipped: Vec::new(),
    };

    for batch in sorted.chunks(MAX_DISCOVERY_BATCH) {
        outcome.batches += 1;
        for input in batch {
            let path = input.path.trim();
            if path.is_empty() {
                outcome.skipped.push(SkippedFile {
                    path: input.path.clone(),
                    reason: "empty path".into(),
                });
                continue;
            }
            let observed = match observe(input) {
                Ok(o) => o,
                Err(reason) => {
                    outcome.skipped.push(SkippedFile {
                        path: path.to_string(),
                        reason,
                    });
                    continue;
                }
            };
            let id = watched_file_id(&folder_id, path);
            let existing = match store.get(id) {
                Ok(item) => item,
                Err(e) => {
                    outcome.skipped.push(SkippedFile {
                        path: path.to_string(),
                        reason: format!("store read failed: {e}"),
                    });
                    continue;
                }
            };
            if let Some(item) = &existing {
                if item.schema != WATCHED_FILE_SCHEMA {
                    outcome.skipped.push(SkippedFile {
                        path: path.to_string(),
                        reason: format!(
                            "deterministic id {id} is already held by a '{}' item",
                            item.schema
                        ),
                    });
                    continue;
                }
            }

            let action = discovery_action(existing.as_ref(), &observed);
            if !dry_run {
                let write = match &existing {
                    None => insert_file(
                        store,
                        id,
                        folder.id,
                        &folder_id,
                        &kind_scope,
                        path,
                        &observed,
                        input.bookmark_base64.as_deref(),
                    ),
                    // The zero-write case, and the whole idempotency claim.
                    Some(_) if action == "unchanged" => Ok(()),
                    Some(item) => update_file(
                        store,
                        item,
                        &observed,
                        input.bookmark_base64.as_deref(),
                        action == "restored",
                    ),
                };
                if let Err(e) = write {
                    outcome.skipped.push(SkippedFile {
                        path: path.to_string(),
                        reason: format!("write failed: {e}"),
                    });
                    continue;
                }
            }
            match action {
                "created" => outcome.created += 1,
                "changed" => outcome.changed += 1,
                "restored" => outcome.restored += 1,
                _ => outcome.unchanged += 1,
            }
            outcome.files.push(DiscoveredFileOutcome {
                id: id.to_string(),
                path: path.to_string(),
                action: action.to_string(),
                content_hash: observed.content_hash.clone(),
            });
        }
    }
    Ok(outcome)
}

/// What the caller told us, completed from the filesystem where it did not.
struct Observed {
    content_hash: String,
    mtime: Option<String>,
    size_bytes: i64,
}

fn observe(input: &DiscoveredFileInput) -> Result<Observed, String> {
    let path = PathBuf::from(input.path.trim());
    let hash = input
        .content_hash
        .as_deref()
        .map(str::trim)
        .filter(|h| !h.is_empty())
        .map(|h| h.to_lowercase());
    let needs_disk = hash.is_none() || input.mtime.is_none() || input.size_bytes.is_none();

    let metadata = if needs_disk {
        Some(fs::metadata(&path).map_err(|e| format!("unreadable: {e}"))?)
    } else {
        None
    };
    if let Some(metadata) = &metadata {
        if !metadata.is_file() {
            return Err("not a regular file".into());
        }
    }

    let content_hash = match hash {
        Some(h) => h,
        None => {
            let bytes = fs::read(&path).map_err(|e| format!("unreadable: {e}"))?;
            // Over the RAW bytes, never a lossy UTF-8 conversion: a `.bib` with
            // a stray Latin-1 byte — or a phase-2 PDF — must hash by what it
            // contains, or two different files collide and an edit reads as
            // "unchanged" forever. See `sha256_bytes_hex`'s doc.
            sha256_bytes_hex(&bytes)
        }
    };
    let size_bytes = input
        .size_bytes
        .or_else(|| metadata.as_ref().map(|m| m.len() as i64))
        .unwrap_or(0);
    let mtime = input.mtime.clone().or_else(|| {
        metadata
            .as_ref()
            .and_then(|m| m.modified().ok())
            .map(|t| chrono::DateTime::<chrono::Utc>::from(t).to_rfc3339())
    });
    Ok(Observed {
        content_hash,
        mtime,
        size_bytes,
    })
}

fn discovery_action(existing: Option<&Item>, observed: &Observed) -> &'static str {
    match existing {
        None => "created",
        Some(item) => {
            let was_missing = string_field(item, "state").as_deref() == Some(FILE_STATE_MISSING);
            let same_hash =
                string_field(item, "content_hash").as_deref() == Some(&observed.content_hash);
            if was_missing {
                // A file that came back is news even when its bytes did not
                // change: its row said `missing`, and something has to say
                // otherwise.
                "restored"
            } else if same_hash {
                "unchanged"
            } else {
                "changed"
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
fn insert_file(
    store: &SqliteItemStore,
    id: Uuid,
    folder_uuid: ItemId,
    folder_id: &str,
    kind_scope: &str,
    path: &str,
    observed: &Observed,
    bookmark_base64: Option<&str>,
) -> Result<(), StoreError> {
    let now = iso8601_now();
    let mut payload: BTreeMap<String, Value> = BTreeMap::new();
    payload.insert(
        "watched_folder_id".into(),
        Value::String(folder_id.to_lowercase()),
    );
    payload.insert("path".into(), Value::String(path.to_string()));
    payload.insert(
        "content_hash".into(),
        Value::String(observed.content_hash.clone()),
    );
    payload.insert("state".into(), Value::String(FILE_STATE_PRESENT.into()));
    payload.insert("kind_scope".into(), Value::String(kind_scope.to_string()));
    payload.insert("size_bytes".into(), Value::Int(observed.size_bytes));
    if let Some(mtime) = &observed.mtime {
        payload.insert("mtime".into(), Value::String(mtime.clone()));
    }
    if let Some(bookmark) = bookmark_base64.map(str::trim).filter(|b| !b.is_empty()) {
        payload.insert(
            "bookmark_base64".into(),
            Value::String(bookmark.to_string()),
        );
    }
    payload.insert("first_seen_at".into(), Value::String(now.clone()));
    payload.insert("last_seen_at".into(), Value::String(now));
    // The envelope parent is the OWNING container (imbib's c902a22f invariant:
    // `item.parent` is the owner, payload holds the tree). For a discovered
    // file the owner IS the watched folder, so both spellings agree by
    // construction and `Predicate::HasParent` works without a payload scan.
    store.insert(new_item(
        id,
        WATCHED_FILE_SCHEMA,
        payload,
        Some(folder_uuid),
    ))?;
    Ok(())
}

/// Update in place. Only fields that actually changed are written, and
/// `produced_ids` is NEVER touched here — that is the W2 seam, and a re-scan
/// that silently cleared it would destroy the only record of what a since-edited
/// file put in the store.
fn update_file(
    store: &SqliteItemStore,
    existing: &Item,
    observed: &Observed,
    bookmark_base64: Option<&str>,
    restored: bool,
) -> Result<(), StoreError> {
    let now = iso8601_now();
    let mut mutations = vec![FieldMutation::SetPayload(
        "last_seen_at".into(),
        Value::String(now),
    )];
    if string_field(existing, "content_hash").as_deref() != Some(&observed.content_hash) {
        mutations.push(FieldMutation::SetPayload(
            "content_hash".into(),
            Value::String(observed.content_hash.clone()),
        ));
    }
    if int_field(existing, "size_bytes") != observed.size_bytes {
        mutations.push(FieldMutation::SetPayload(
            "size_bytes".into(),
            Value::Int(observed.size_bytes),
        ));
    }
    if let Some(mtime) = &observed.mtime {
        if string_field(existing, "mtime").as_deref() != Some(mtime.as_str()) {
            mutations.push(FieldMutation::SetPayload(
                "mtime".into(),
                Value::String(mtime.clone()),
            ));
        }
    }
    if let Some(bookmark) = bookmark_base64.map(str::trim).filter(|b| !b.is_empty()) {
        if string_field(existing, "bookmark_base64").as_deref() != Some(bookmark) {
            mutations.push(FieldMutation::SetPayload(
                "bookmark_base64".into(),
                Value::String(bookmark.to_string()),
            ));
        }
    }
    if restored {
        mutations.push(FieldMutation::SetPayload(
            "state".into(),
            Value::String(FILE_STATE_PRESENT.into()),
        ));
        mutations.push(FieldMutation::RemovePayload("missing_since".into()));
    }
    store.update(existing.id, mutations)
}

// ---------------------------------------------------------------------------
// The missing sweep
// ---------------------------------------------------------------------------

/// What a terminal scan sweep found.
pub struct ScanOutcome {
    pub examined: u32,
    pub present: u32,
    pub marked_missing: u32,
    pub missing: Vec<WatchedFileDto>,
}

/// Mark every file this folder still calls `present` whose path is gone.
///
/// **Refuses to run when the folder's own root is unreachable.** If a volume
/// unmounted or a bookmark lapsed, every path under it stops existing at once,
/// and a sweep that believed the filesystem would mark an entire library
/// missing in one pass. ADR-0023 D6 requires the folder row to *declare* that
/// state instead; this is that rule with teeth.
///
/// Rows are never deleted (D4). A file that comes back is restored by the next
/// discovery pass, with the same id and its `produced_ids` intact.
pub fn sweep_missing(
    store: &SqliteItemStore,
    folder: &Item,
    dry_run: bool,
) -> Result<ScanOutcome, String> {
    let root = string_field(folder, "path").unwrap_or_default();
    if root.is_empty() || !Path::new(&root).is_dir() {
        return Err(format!(
            "watched folder root '{root}' is not reachable — refusing to mark any \
             file missing. An unmounted volume makes every path vanish at once, \
             and D6 requires the folder to declare '{VOLUME_STATE_UNAVAILABLE}' \
             rather than report an empty library."
        ));
    }
    let folder_id = folder.id.to_string();
    let items = query_files(store, &folder_id, Some(FILE_STATE_PRESENT))?;
    let mut outcome = ScanOutcome {
        examined: items.len() as u32,
        present: 0,
        marked_missing: 0,
        missing: Vec::new(),
    };
    let now = iso8601_now();
    // Bounded, ordered writes: the same ≤500 gate discovery uses.
    for batch in items.chunks(MAX_DISCOVERY_BATCH) {
        for item in batch {
            let path = string_field(item, "path").unwrap_or_default();
            if !path.is_empty() && Path::new(&path).exists() {
                outcome.present += 1;
                continue;
            }
            outcome.marked_missing += 1;
            if !dry_run {
                store
                    .update(
                        item.id,
                        vec![
                            FieldMutation::SetPayload(
                                "state".into(),
                                Value::String(FILE_STATE_MISSING.into()),
                            ),
                            FieldMutation::SetPayload(
                                "missing_since".into(),
                                Value::String(now.clone()),
                            ),
                        ],
                    )
                    .map_err(|e| e.to_string())?;
            }
            let mut dto = file_dto(item);
            dto.state = FILE_STATE_MISSING.into();
            dto.missing_since = Some(now.clone());
            outcome.missing.push(dto);
        }
    }
    Ok(outcome)
}

/// Write the folder's last-scan stats. `new_count` / `changed_count` /
/// `duration_ms` come from the caller because the caller ran the scan — it may
/// have taken many `import_discovered` calls to do it, and no single one of
/// them knows the total.
pub fn record_scan_stats(
    store: &SqliteItemStore,
    folder: &Item,
    file_count: i64,
    new_count: i64,
    changed_count: i64,
    missing_count: i64,
    duration_ms: i64,
) -> Result<WatchedFolderDto, String> {
    let mutations = vec![
        FieldMutation::SetPayload("last_scan_at".into(), Value::String(iso8601_now())),
        FieldMutation::SetPayload("last_scan_file_count".into(), Value::Int(file_count)),
        FieldMutation::SetPayload("last_scan_new_count".into(), Value::Int(new_count)),
        FieldMutation::SetPayload("last_scan_changed_count".into(), Value::Int(changed_count)),
        FieldMutation::SetPayload("last_scan_missing_count".into(), Value::Int(missing_count)),
        FieldMutation::SetPayload("last_scan_duration_ms".into(), Value::Int(duration_ms)),
    ];
    store
        .update(folder.id, mutations)
        .map_err(|e| e.to_string())?;
    let refreshed = store
        .get(folder.id)
        .map_err(|e| e.to_string())?
        .ok_or("folder vanished mid-update")?;
    Ok(folder_dto(&refreshed))
}

// ---------------------------------------------------------------------------
// The W2 seam
// ---------------------------------------------------------------------------

/// What `record_produced` changed.
pub struct ProducedOutcome {
    pub file: WatchedFileDto,
    pub added: u32,
    /// Ids that were attributed to this file before and are not now — the
    /// answer to "what did re-importing this file orphan?".
    pub removed_ids: Vec<String>,
}

/// Attribute store rows to the file that produced them — **the W2 seam**.
///
/// Discovery never writes `produced_ids`, because W0 does not know how to parse
/// a `.bib` and must not learn. The wiring is:
///
/// 1. `import_discovered` reports a file as `created` / `changed` / `restored`.
/// 2. The app's REAL importer runs on that one file — imbib's BibTeX/RIS import
///    with its identifier dedup for `entries` ingest, or the reference-in-place
///    row builder for `file` ingest.
/// 3. The importer calls this with the ids it produced.
///
/// `replace` is what makes deletions detectable: re-importing an edited `.bib`
/// that lost an entry returns that entry's id in `removed_ids`, so the caller
/// can decide what "the source no longer contains this" should mean for it —
/// which is a product decision (dismiss? flag? nothing?) and therefore not one
/// this crate gets to make. With `replace: false` the ids are unioned, which is
/// what an incremental append wants.
///
/// The ids are also written as `DerivedFrom` references on the file row, so the
/// graph and the payload agree and `neighbors` reaches the produced rows.
pub fn record_produced(
    store: &SqliteItemStore,
    file_id: &str,
    produced_ids: &[String],
    replace: bool,
) -> Result<ProducedOutcome, String> {
    let uuid = Uuid::parse_str(file_id.trim()).map_err(|_| format!("'{file_id}' is not a UUID"))?;
    let item = store
        .get(uuid)
        .map_err(|e| e.to_string())?
        .ok_or_else(|| format!("no discovered file {file_id}"))?;
    if item.schema != WATCHED_FILE_SCHEMA {
        return Err(format!(
            "{file_id} is a '{}' item, not a discovered file",
            item.schema
        ));
    }

    // Normalise once: the store's canonical id form is lowercase, and a caller
    // handing us Swift's uppercase `UUID().uuidString` must not create a second
    // spelling of the same row (apps/imbib/CLAUDE.md, the FFI-boundary rule).
    let mut incoming: Vec<String> = Vec::new();
    for id in produced_ids {
        let trimmed = id.trim();
        if trimmed.is_empty() {
            continue;
        }
        let parsed = Uuid::parse_str(trimmed)
            .map_err(|_| format!("produced id '{trimmed}' is not a UUID"))?;
        let lowered = parsed.to_string();
        if !incoming.contains(&lowered) {
            incoming.push(lowered);
        }
    }

    // Every produced id must name a row that EXISTS. The `DerivedFrom` edges
    // below are foreign-keyed, so an absent target would fail the write anyway
    // — but it would fail after the payload mutation was queued, mid-list, with
    // a storage error naming a constraint instead of the id. Checking first
    // turns that into one sentence the caller can act on, and it is the right
    // rule regardless: attributing a row that does not exist is not provenance,
    // it is a dangling pointer that only shows up as a broken query later.
    let missing_targets: Vec<&String> = incoming
        .iter()
        .filter(|id| {
            Uuid::parse_str(id)
                .ok()
                .and_then(|u| store.get(u).ok().flatten())
                .is_none()
        })
        .collect();
    if !missing_targets.is_empty() {
        return Err(format!(
            "these produced ids name no row in the store: {}. Record the rows \
             first — attribution is provenance, and provenance for a row that \
             does not exist is a dangling pointer.",
            missing_targets
                .iter()
                .map(|s| s.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ));
    }

    let before: Vec<String> = string_array_field(&item, "produced_ids").unwrap_or_default();
    let before_set: BTreeSet<&String> = before.iter().collect();
    let after: Vec<String> = if replace {
        incoming.clone()
    } else {
        let mut merged = before.clone();
        for id in &incoming {
            if !merged.contains(id) {
                merged.push(id.clone());
            }
        }
        merged
    };
    let after_set: BTreeSet<&String> = after.iter().collect();

    let added = after.iter().filter(|id| !before_set.contains(id)).count() as u32;
    let removed_ids: Vec<String> = before
        .iter()
        .filter(|id| !after_set.contains(id))
        .cloned()
        .collect();

    let mut mutations = vec![
        FieldMutation::SetPayload(
            "produced_ids".into(),
            Value::Array(after.iter().map(|id| Value::String(id.clone())).collect()),
        ),
        FieldMutation::SetPayload("produced_at".into(), Value::String(iso8601_now())),
        // The hash this fan-out was FOR. `needs_reimport` compares it against
        // the live `content_hash`, which is why an edit inside the same second
        // as its import is still detected.
        FieldMutation::SetPayload(
            "produced_for_hash".into(),
            Value::String(string_field(&item, "content_hash").unwrap_or_default()),
        ),
    ];
    for id in &removed_ids {
        if let Ok(uuid) = Uuid::parse_str(id) {
            mutations.push(FieldMutation::RemoveReference(uuid, EdgeType::DerivedFrom));
        }
    }
    for id in &after {
        if before_set.contains(id) {
            continue;
        }
        if let Ok(uuid) = Uuid::parse_str(id) {
            mutations.push(FieldMutation::AddReference(TypedReference {
                target: uuid,
                edge_type: EdgeType::DerivedFrom,
                metadata: None,
            }));
        }
    }
    store
        .update(item.id, mutations)
        .map_err(|e| e.to_string())?;

    let refreshed = store
        .get(item.id)
        .map_err(|e| e.to_string())?
        .ok_or("file vanished mid-update")?;
    Ok(ProducedOutcome {
        file: file_dto(&refreshed),
        added,
        removed_ids,
    })
}

// ---------------------------------------------------------------------------
// Public DTO builders (used by the service layer)
// ---------------------------------------------------------------------------

/// Expose the item→DTO mapping for the service layer, which holds `Item`s it
/// has already loaded.
pub fn folder_to_dto(item: &Item) -> WatchedFolderDto {
    folder_dto(item)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The namespaces are load-bearing: every watched folder and every file row
    /// in every store hangs off them, exactly as `DOCS_IMPORT_NAMESPACE` does
    /// for imported manuscripts. Same verification test.
    #[test]
    fn namespaces_are_the_documented_derivations() {
        assert_eq!(
            Uuid::new_v5(&Uuid::NAMESPACE_DNS, b"store.impress.watched-folder").to_string(),
            WATCHED_FOLDER_NAMESPACE
        );
        assert_eq!(
            Uuid::new_v5(&Uuid::NAMESPACE_DNS, b"store.impress.watched-file").to_string(),
            WATCHED_FILE_NAMESPACE
        );
    }

    #[test]
    fn folder_ids_are_stable_scoped_and_slash_insensitive() {
        let a = watched_folder_id("/Users/x/papers", "publication");
        assert_eq!(a, watched_folder_id("/Users/x/papers/", "publication"));
        assert_eq!(a, watched_folder_id("  /Users/x/papers  ", "publication"));
        assert_ne!(
            a,
            watched_folder_id("/Users/x/papers", "manuscript"),
            "one directory watched for two kinds is two folders"
        );
        assert_ne!(a, watched_folder_id("/Users/x/other", "publication"));
        assert_eq!(a.get_version_num(), 5);
    }

    #[test]
    fn file_ids_are_scoped_to_their_folder() {
        let f1 = watched_folder_id("/a", "publication").to_string();
        let f2 = watched_folder_id("/b", "publication").to_string();
        let a = watched_file_id(&f1, "/a/refs.bib");
        assert_eq!(a, watched_file_id(&f1.to_uppercase(), "/a/refs.bib"));
        assert_ne!(a, watched_file_id(&f2, "/a/refs.bib"));
        assert_ne!(a, watched_file_id(&f1, "/a/other.bib"));
        assert_eq!(a.get_version_num(), 5);
    }

    #[test]
    fn the_batch_bound_is_the_store_mirror_precedent() {
        assert_eq!(MAX_DISCOVERY_BATCH, 500);
        assert_eq!(MAX_DISCOVERED_FILES_PER_CALL, 5_000);
    }
}
