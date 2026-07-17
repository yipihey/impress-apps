//! Manuscript section persistence on top of the shared impress-core item store.
//!
//! This is the Rust port of `apps/imprint/Packages/ImprintCore/Sources/ImprintCore/
//! ImprintStoreAdapter.swift`. The semantics it preserves are:
//!
//! - One item per section, schema `manuscript-section@1.0.0` (we write
//!   `manuscript-section`, matching the Swift adapter).
//! - The stable external id is `<doc_id>::<section_key>` mapped through a
//!   deterministic UUID v5, so repeated `put_section` calls are idempotent.
//! - Bodies > 64 KiB are written content-addressed to a sibling blob directory
//!   and only the SHA-256 hex digest lives in the row.
//! - Read paths transparently rehydrate offloaded bodies from the blob store.
//!
//! Open question deferred to Phase 3: the Swift adapter additionally posts
//! mutation signals on `ImprintImpressStore` so SwiftUI views re-render. That
//! is a Swift concern — the Rust layer just persists data and reports back.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::blob_store::BlobStore;
use crate::error::ServiceError;
use impress_store_ffi::{SharedItemRow, SharedStore};

/// Schema reference stored on each section item. Matches the Swift adapter.
pub const SECTION_SCHEMA_REF: &str = "manuscript-section";

/// Namespace for the deterministic UUID-v5 we derive from
/// `(document_id, section_key)`. Picked once and frozen so the ids are stable
/// across runs and across the Rust/Swift implementations.
const SECTION_ID_NAMESPACE: Uuid = Uuid::from_bytes([
    0x6f, 0x9b, 0x4b, 0x16, 0xdb, 0xb1, 0x4a, 0xea, 0x9d, 0x52, 0x16, 0x4f, 0xa2, 0x71, 0xfb, 0xb6,
]);

/// Metadata about a section. Optional fields mirror the Swift schema; any of
/// them may be `None` if the caller hasn't computed them yet.
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq, Eq, schemars::JsonSchema)]
pub struct SectionMetadata {
    /// Human-readable section heading (e.g. "Introduction").
    pub title: Option<String>,
    /// Semantic section type, e.g. "introduction" or "methods".
    pub section_type: Option<String>,
    /// Zero-based position within the document.
    pub order_index: Option<i64>,
}

/// A section as persisted in the shared store.
///
/// `body` is always the rehydrated Typst source. When the row holds a
/// `content_hash` and the body was offloaded to the CAS, `get_section` reads
/// the blob back so callers never have to chase the indirection themselves.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SectionRecord {
    /// Stable id used as the item id in the shared store.
    pub item_id: Uuid,
    /// Owning document UUID.
    pub document_id: Uuid,
    /// Caller-supplied key identifying this section within the document.
    pub section_key: String,
    /// Section heading; empty string if none was supplied.
    pub title: String,
    /// Typst source body. Rehydrated from CAS if it was offloaded.
    pub body: String,
    /// Semantic type, e.g. "introduction".
    pub section_type: Option<String>,
    /// Zero-based position within the document.
    pub order_index: Option<i64>,
    /// Approximate word count (whitespace-split, matches Swift heuristic).
    pub word_count: i64,
    /// `Some(hex)` if the body was offloaded to the CAS blob store.
    pub content_hash: Option<String>,
    /// Item creation timestamp in ms since Unix epoch (from the store row).
    pub created_ms: i64,
}

/// JSON payload as we persist it on the item. Internal type — callers should
/// not depend on this shape (the public API works in `SectionRecord`).
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct SectionPayload {
    #[serde(default)]
    title: String,
    #[serde(default)]
    body: String,
    #[serde(default)]
    section_type: Option<String>,
    #[serde(default)]
    order_index: Option<i64>,
    #[serde(default)]
    word_count: i64,
    #[serde(default)]
    document_id: Option<String>,
    #[serde(default)]
    section_key: Option<String>,
    #[serde(default)]
    content_hash: Option<String>,
}

/// Persistence layer for manuscript sections.
///
/// Owns an `Arc<SharedStore>` (the shared SQLite item store) plus a
/// content-addressed blob directory on disk.
#[derive(Clone)]
pub struct SectionStore {
    store: Arc<SharedStore>,
    blobs: BlobStore,
}

impl SectionStore {
    /// Build a `SectionStore` that uses the provided shared store and writes
    /// content-addressed blobs under `blob_root`.
    pub fn new(store: Arc<SharedStore>, blob_root: PathBuf) -> Self {
        Self {
            store,
            blobs: BlobStore::new(blob_root),
        }
    }

    /// Open a new `SectionStore` rooted at the given workspace directory.
    ///
    /// - `<workspace>/impress.sqlite` is opened (creating it if needed).
    /// - `<workspace>/content/` is used as the blob directory.
    pub fn open<P: AsRef<Path>>(workspace_root: P) -> Result<Self, ServiceError> {
        let root = workspace_root.as_ref();
        let db_path = root.join("impress.sqlite");
        let blob_root = root.join("content");
        std::fs::create_dir_all(root).map_err(|source| ServiceError::BlobIo {
            path: root.to_path_buf(),
            source,
        })?;
        let store = SharedStore::open(db_path.to_string_lossy().into_owned())?;
        Ok(Self::new(store, blob_root))
    }

    /// Open an in-memory store (intended for tests). The blob directory still
    /// has to live on disk; pass a `tempfile::TempDir` path.
    pub fn open_in_memory(blob_root: PathBuf) -> Result<Self, ServiceError> {
        let store = SharedStore::open_in_memory()?;
        Ok(Self::new(store, blob_root))
    }

    /// Borrow the underlying shared store. Useful for higher-level services
    /// that want to issue cross-schema queries.
    pub fn shared_store(&self) -> &SharedStore {
        &self.store
    }

    /// Borrow the blob store directly (e.g. for diagnostics).
    pub fn blob_store(&self) -> &BlobStore {
        &self.blobs
    }

    /// Derive the deterministic item UUID for a (document, section) pair.
    pub fn item_id(document_id: Uuid, section_key: &str) -> Uuid {
        let name = format!("{}::{}", document_id, section_key);
        Uuid::new_v5(&SECTION_ID_NAMESPACE, name.as_bytes())
    }

    /// Approximate word count (whitespace-split). Matches the Swift heuristic
    /// in `ImprintStoreAdapter.countWords`.
    fn count_words(body: &str) -> i64 {
        body.split_whitespace().filter(|s| !s.is_empty()).count() as i64
    }

    /// Persist a section. Idempotent on `(document_id, section_key)`.
    pub fn put_section(
        &self,
        document_id: Uuid,
        section_key: &str,
        body: &str,
        metadata: SectionMetadata,
    ) -> Result<SectionRecord, ServiceError> {
        if section_key.is_empty() {
            return Err(ServiceError::InvalidArgument(
                "section_key must not be empty".into(),
            ));
        }

        let item_id = Self::item_id(document_id, section_key);
        let title = metadata.title.clone().unwrap_or_default();
        let word_count = Self::count_words(body);

        // Inline-vs-CAS decision mirrors `ImprintStoreAdapter.storeSection`.
        let (inline_body, content_hash) = if BlobStore::should_offload(body) {
            let digest = self.blobs.put(body)?;
            (String::new(), Some(digest))
        } else {
            (body.to_string(), None)
        };

        let payload = SectionPayload {
            title: title.clone(),
            body: inline_body,
            section_type: metadata.section_type.clone(),
            order_index: metadata.order_index,
            word_count,
            document_id: Some(document_id.to_string()),
            section_key: Some(section_key.to_string()),
            content_hash: content_hash.clone(),
        };
        let payload_json = serde_json::to_string(&payload)?;

        self.store.upsert_item(
            item_id.to_string(),
            SECTION_SCHEMA_REF.to_string(),
            payload_json,
        )?;

        // Re-read to learn the canonical created_ms timestamp.
        let row = self.store.get_item(item_id.to_string())?.ok_or_else(|| {
            ServiceError::Internal(format!(
                "section {} disappeared immediately after upsert",
                item_id
            ))
        })?;

        Ok(SectionRecord {
            item_id,
            document_id,
            section_key: section_key.to_string(),
            title,
            body: body.to_string(),
            section_type: metadata.section_type,
            order_index: metadata.order_index,
            word_count,
            content_hash,
            created_ms: row.created_ms,
        })
    }

    /// Fetch a section by (document_id, section_key). Returns `Ok(None)` if
    /// no such section exists.
    pub fn get_section(
        &self,
        document_id: Uuid,
        section_key: &str,
    ) -> Result<Option<SectionRecord>, ServiceError> {
        let item_id = Self::item_id(document_id, section_key);
        let row = match self.store.get_item(item_id.to_string())? {
            Some(r) => r,
            None => return Ok(None),
        };
        self.row_to_section(row).map(Some)
    }

    /// Delete a section. Returns `Ok(())` even when the section does not exist
    /// (a `NotFound` from the store is swallowed so callers can issue
    /// idempotent deletes safely).
    pub fn delete_section(&self, document_id: Uuid, section_key: &str) -> Result<(), ServiceError> {
        let item_id = Self::item_id(document_id, section_key);
        match self.store.delete_item(item_id.to_string()) {
            Ok(()) => Ok(()),
            Err(impress_store_ffi::SharedStoreError::NotFound { .. }) => Ok(()),
            Err(e) => Err(e.into()),
        }
    }

    /// List all sections belonging to a document, oldest-first by creation
    /// time. `limit = 0` is treated as "no explicit limit" and falls through
    /// to the shared store's default page size.
    pub fn list_sections(
        &self,
        document_id: Uuid,
        limit: u32,
    ) -> Result<Vec<SectionRecord>, ServiceError> {
        let mut all = Vec::new();
        let page_size = if limit == 0 { 500 } else { limit };
        let mut offset: u32 = 0;
        loop {
            let rows =
                self.store
                    .query_by_schema(SECTION_SCHEMA_REF.to_string(), page_size, offset)?;
            let row_count = rows.len() as u32;
            for row in rows {
                if let Some(rec) = self.try_row_to_section_for_doc(row, document_id)? {
                    all.push(rec);
                    if limit != 0 && all.len() as u32 >= limit {
                        return Ok(all);
                    }
                }
            }
            if row_count < page_size {
                break;
            }
            offset += row_count;
        }
        // Sort by (order_index ascending, created_ms ascending). Sections
        // without an order_index sort after those that have one.
        all.sort_by(|a, b| match (a.order_index, b.order_index) {
            (Some(x), Some(y)) => x.cmp(&y).then(a.created_ms.cmp(&b.created_ms)),
            (Some(_), None) => std::cmp::Ordering::Less,
            (None, Some(_)) => std::cmp::Ordering::Greater,
            (None, None) => a.created_ms.cmp(&b.created_ms),
        });
        Ok(all)
    }

    /// List every section across every document.
    pub fn list_all_sections(&self, limit: u32) -> Result<Vec<SectionRecord>, ServiceError> {
        let mut all = Vec::new();
        let page_size = if limit == 0 { 500 } else { limit };
        let mut offset: u32 = 0;
        loop {
            let rows =
                self.store
                    .query_by_schema(SECTION_SCHEMA_REF.to_string(), page_size, offset)?;
            let row_count = rows.len() as u32;
            for row in rows {
                let rec = self.row_to_section(row)?;
                all.push(rec);
                if limit != 0 && all.len() as u32 >= limit {
                    return Ok(all);
                }
            }
            if row_count < page_size {
                break;
            }
            offset += row_count;
        }
        Ok(all)
    }

    // ── internals ───────────────────────────────────────────────────────────

    fn try_row_to_section_for_doc(
        &self,
        row: SharedItemRow,
        document_id: Uuid,
    ) -> Result<Option<SectionRecord>, ServiceError> {
        let payload: SectionPayload = serde_json::from_str(&row.payload_json)?;
        // Filter rows whose payload doc id doesn't match the requested document.
        if let Some(ref doc_str) = payload.document_id {
            if doc_str != &document_id.to_string() {
                return Ok(None);
            }
        } else {
            return Ok(None);
        }
        let rec = self.assemble_section(row, payload)?;
        Ok(Some(rec))
    }

    fn row_to_section(&self, row: SharedItemRow) -> Result<SectionRecord, ServiceError> {
        let payload: SectionPayload = serde_json::from_str(&row.payload_json)?;
        self.assemble_section(row, payload)
    }

    fn assemble_section(
        &self,
        row: SharedItemRow,
        payload: SectionPayload,
    ) -> Result<SectionRecord, ServiceError> {
        let item_id: Uuid = row.id.parse()?;
        let document_id = payload
            .document_id
            .as_ref()
            .and_then(|s| s.parse::<Uuid>().ok())
            .unwrap_or_else(Uuid::nil);
        let section_key = payload.section_key.unwrap_or_default();

        // Rehydrate body from CAS if needed.
        let body = if let Some(hash) = &payload.content_hash {
            match self.blobs.get(hash)? {
                Some(b) => b,
                // Blob is missing — fall back to the inline copy (which is
                // the empty string in this case). Better to return an empty
                // section than to crash a downstream MCP/CLI request.
                None => payload.body.clone(),
            }
        } else {
            payload.body.clone()
        };

        Ok(SectionRecord {
            item_id,
            document_id,
            section_key,
            title: payload.title,
            body,
            section_type: payload.section_type,
            order_index: payload.order_index,
            word_count: payload.word_count,
            content_hash: payload.content_hash,
            created_ms: row.created_ms,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_store() -> (SectionStore, TempDir) {
        let dir = TempDir::new().unwrap();
        let store = SectionStore::open_in_memory(dir.path().join("content")).unwrap();
        (store, dir)
    }

    #[test]
    fn put_and_get_roundtrip_inline() {
        let (store, _dir) = make_store();
        let doc = Uuid::new_v4();
        let rec = store
            .put_section(
                doc,
                "intro",
                "Once upon a time…",
                SectionMetadata {
                    title: Some("Introduction".into()),
                    section_type: Some("introduction".into()),
                    order_index: Some(0),
                },
            )
            .unwrap();
        assert_eq!(rec.body, "Once upon a time…");
        assert_eq!(rec.title, "Introduction");
        assert!(rec.content_hash.is_none(), "small body should be inline");

        let got = store.get_section(doc, "intro").unwrap().unwrap();
        assert_eq!(got.body, "Once upon a time…");
        assert_eq!(got.item_id, rec.item_id);
    }

    #[test]
    fn put_and_get_roundtrip_cas() {
        let (store, _dir) = make_store();
        let doc = Uuid::new_v4();
        let big = "lorem ipsum ".repeat(10_000); // ~120 KiB
        assert!(BlobStore::should_offload(&big));

        let rec = store
            .put_section(doc, "methods", &big, SectionMetadata::default())
            .unwrap();
        assert!(rec.content_hash.is_some());
        assert_eq!(rec.body, big);

        let got = store.get_section(doc, "methods").unwrap().unwrap();
        assert_eq!(got.body, big, "body should be rehydrated from CAS");
        assert_eq!(got.content_hash, rec.content_hash);
    }

    #[test]
    fn deterministic_item_id() {
        let doc = Uuid::nil();
        let a = SectionStore::item_id(doc, "intro");
        let b = SectionStore::item_id(doc, "intro");
        let c = SectionStore::item_id(doc, "methods");
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn idempotent_put_overwrites_body() {
        let (store, _dir) = make_store();
        let doc = Uuid::new_v4();
        let r1 = store
            .put_section(doc, "k", "v1", SectionMetadata::default())
            .unwrap();
        let r2 = store
            .put_section(doc, "k", "v2", SectionMetadata::default())
            .unwrap();
        assert_eq!(r1.item_id, r2.item_id);
        let got = store.get_section(doc, "k").unwrap().unwrap();
        assert_eq!(got.body, "v2");
    }

    #[test]
    fn list_filters_by_document() {
        let (store, _dir) = make_store();
        let d1 = Uuid::new_v4();
        let d2 = Uuid::new_v4();
        store
            .put_section(
                d1,
                "intro",
                "a",
                SectionMetadata {
                    order_index: Some(0),
                    ..Default::default()
                },
            )
            .unwrap();
        store
            .put_section(
                d1,
                "methods",
                "b",
                SectionMetadata {
                    order_index: Some(1),
                    ..Default::default()
                },
            )
            .unwrap();
        store
            .put_section(
                d2,
                "intro",
                "c",
                SectionMetadata {
                    order_index: Some(0),
                    ..Default::default()
                },
            )
            .unwrap();

        let s1 = store.list_sections(d1, 0).unwrap();
        assert_eq!(s1.len(), 2);
        assert!(s1.iter().all(|s| s.document_id == d1));
        assert_eq!(s1[0].section_key, "intro");
        assert_eq!(s1[1].section_key, "methods");

        let s2 = store.list_sections(d2, 0).unwrap();
        assert_eq!(s2.len(), 1);
    }

    #[test]
    fn delete_is_idempotent() {
        let (store, _dir) = make_store();
        let doc = Uuid::new_v4();
        store
            .put_section(doc, "k", "v", SectionMetadata::default())
            .unwrap();
        store.delete_section(doc, "k").unwrap();
        // Second delete must not error.
        store.delete_section(doc, "k").unwrap();
        assert!(store.get_section(doc, "k").unwrap().is_none());
    }

    #[test]
    fn delete_missing_is_ok() {
        let (store, _dir) = make_store();
        let doc = Uuid::new_v4();
        store.delete_section(doc, "never-existed").unwrap();
    }
}
