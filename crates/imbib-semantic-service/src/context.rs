//! The embedding stack behind the three semantic-search verbs, and the
//! lazily-built state that holds it.
//!
//! Copied (with the transport-specific naming stripped) from
//! `crates/impress-mcp/src/tools.rs` when the three hand-written tools moved
//! here (P3c step 1): opening the embedding store, rebuilding an HNSW index
//! over every chunk vector, and loading the fastembed model are unchanged.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

use impress_embeddings::{ChunkIndex, EmbeddingStore, SemanticSearch, StoredVector};
use rusqlite::Connection;

use crate::store::{open_main_store, PublicationMeta};

/// Message returned by the three verbs when the stack could not be built.
pub const SEMANTIC_UNAVAILABLE: &str =
    "Semantic search is unavailable: no embeddings database, or the model failed to load. \
     Index PDFs in imbib first.";

/// The built embedding stack.
pub struct SemanticContext {
    pub embedding_store: EmbeddingStore,
    pub chunk_index: ChunkIndex,
    pub semantic: SemanticSearch,
}

/// Lazily-built state shared by the three verbs.
///
/// Both the embedding stack and the main store are built **on first use**,
/// not at construction: a client that spawns this process (impel, at app
/// launch) must not pay an HNSW rebuild and a model load, or a slow/locked
/// store open, before it has asked for anything that needs them.
///
/// `#[impress_service]` requires `Send + Sync` on the impl (unlike
/// `impress-mcp`'s original single-threaded `ToolContext`, which could use a
/// plain `OnceCell`): `OnceLock` for the embedding stack, and a `Mutex`
/// around the `rusqlite::Connection` (which is `Send` but not `Sync`) for the
/// main store.
pub struct SemanticState {
    embeddings_path: PathBuf,
    semantic: OnceLock<Option<SemanticContext>>,
    main_store_path: PathBuf,
    main_store: OnceLock<Mutex<Option<Connection>>>,
}

impl SemanticState {
    pub fn deferred(embeddings_path: PathBuf, main_store_path: PathBuf) -> Self {
        Self {
            embeddings_path,
            semantic: OnceLock::new(),
            main_store_path,
            main_store: OnceLock::new(),
        }
    }

    /// The default embeddings path — `dirs::data_dir()/imbib/embeddings.sqlite`,
    /// the same default `impress-mcp`'s `main.rs` computed before P3c.
    pub fn default_embeddings_path() -> PathBuf {
        if let Some(path) = std::env::var_os("IMPRESS_EMBEDDINGS_PATH") {
            return path.into();
        }
        dirs::data_dir()
            .expect("Could not determine data directory")
            .join("imbib/embeddings.sqlite")
    }

    /// The default main store path — the same default `impress-mcp`'s
    /// `main.rs` computed before P3c.
    pub fn default_main_store_path() -> PathBuf {
        if let Some(path) = std::env::var_os("IMPRESS_STORE_PATH") {
            return path.into();
        }
        dirs::home_dir()
            .expect("Could not determine home directory")
            .join("Library/Group Containers/QG3MEYVHMS.com.impress.suite/workspace/impress.sqlite")
    }

    /// Run `f` against the shared store, opened on first use. `f` sees
    /// `None` when the store is missing or cannot be opened — metadata
    /// enrichment then degrades, which callers already handle. A closure
    /// rather than a returned reference: the connection lives behind a
    /// `Mutex`, so a borrow cannot outlive the lock guard.
    pub fn with_main_store<R>(&self, f: impl FnOnce(Option<&Connection>) -> R) -> R {
        let lock = self.main_store.get_or_init(|| {
            Mutex::new(match open_main_store(&self.main_store_path) {
                Ok(conn) => Some(conn),
                Err(e) => {
                    eprintln!("imbib-semantic-service: main store unavailable: {e}");
                    None
                }
            })
        });
        let guard = lock.lock().unwrap_or_else(|e| e.into_inner());
        f(guard.as_ref())
    }

    /// The embedding stack, built on first call. `None` when it could not be
    /// built — a missing embeddings database or a model that failed to load.
    pub fn semantic(&self) -> Option<&SemanticContext> {
        self.semantic
            .get_or_init(|| match build_semantic(&self.embeddings_path) {
                Ok(ctx) => Some(ctx),
                Err(e) => {
                    eprintln!("imbib-semantic-service: semantic search unavailable: {e}");
                    None
                }
            })
            .as_ref()
    }
}

impl Default for SemanticState {
    fn default() -> Self {
        Self::deferred(
            Self::default_embeddings_path(),
            Self::default_main_store_path(),
        )
    }
}

/// Open the embedding store, load the model, rebuild the chunk index.
///
/// The model loads *before* the index rebuild because the rebuild needs
/// `semantic.model_id()` to decide which vectors belong in the index — see
/// `rebuild_chunk_index`.
fn build_semantic(embeddings_path: &Path) -> Result<SemanticContext, String> {
    let embedding_store = EmbeddingStore::open(embeddings_path.to_str().unwrap_or_default())
        .map_err(|e| format!("failed to open embedding store: {e}"))?;

    eprintln!("imbib-semantic-service: initializing embedding model...");
    let semantic =
        SemanticSearch::new().map_err(|e| format!("failed to initialize SemanticSearch: {e}"))?;

    let chunk_index = ChunkIndex::new();
    rebuild_chunk_index(&embedding_store, &chunk_index, semantic.model_id())?;

    eprintln!(
        "imbib-semantic-service: semantic search ready — {} chunks across {} publications",
        chunk_index.len(),
        chunk_index.indexed_publications().len()
    );

    Ok(SemanticContext {
        embedding_store,
        chunk_index,
        semantic,
    })
}

/// Rebuild the HNSW chunk index from the embedding store.
fn rebuild_chunk_index(
    store: &EmbeddingStore,
    index: &ChunkIndex,
    model: &str,
) -> Result<(), String> {
    let chunk_vectors = select_chunk_vectors(store, model)?;
    if chunk_vectors.is_empty() {
        return Ok(());
    }

    let mut batch: Vec<(String, String, Vec<f32>)> = Vec::with_capacity(chunk_vectors.len());
    for v in chunk_vectors {
        if let Ok(Some(chunk)) = store.get_chunk(&v.source_id) {
            batch.push((v.source_id, chunk.publication_id, v.vector));
        }
    }

    if !batch.is_empty() {
        index.add_batch(batch);
    }
    Ok(())
}

/// The model-gated chunk-vector selection (ADR-0028 D4). Once the sidecar
/// holds at least one **chunk** vector for `model`, only same-model chunk
/// vectors load; until then every chunk vector loads regardless of model —
/// the pre-ADR-0028 behavior — so a device that has only ever run imbib.app
/// keeps searching correctly instead of coming up empty. Scoped to
/// `source_type = "chunk"`, not the whole store, so a `memory-item` vector in
/// the query model's space (written by the ADR-0028 embed executor into the
/// same sidecar) never flips the gate on with zero chunk rows to show for it.
fn select_chunk_vectors(store: &EmbeddingStore, model: &str) -> Result<Vec<StoredVector>, String> {
    if store.has_vectors_for_source_and_model("chunk", model)? {
        store.load_vectors_by_type_and_model("chunk", model)
    } else {
        eprintln!(
            "imbib-semantic-service: sidecar holds no '{model}' chunk vectors yet — loading all \
             chunk vectors regardless of model. Semantic search runs cross-model until the \
             impress backfill executor (ADR-0028 D7) populates fastembed vectors."
        );
        store.load_vectors_by_type("chunk")
    }
}

/// Metadata for a set of publication ids, or an empty map if the main store
/// is unavailable — the degrade-gracefully rule every caller here follows.
pub fn metadata_for(state: &SemanticState, ids: &[String]) -> HashMap<String, PublicationMeta> {
    state.with_main_store(|conn| match conn {
        Some(conn) => crate::store::list_publications_by_ids(conn, ids).unwrap_or_default(),
        None => HashMap::new(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_embeddings::StoredChunk;

    fn temp_store() -> (EmbeddingStore, tempfile::TempDir) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("embeddings.sqlite");
        let store = EmbeddingStore::open(path.to_str().unwrap()).unwrap();
        (store, dir)
    }

    fn vector(id: &str, source_id: &str, model: &str) -> StoredVector {
        typed_vector(id, source_id, "chunk", model)
    }

    fn typed_vector(id: &str, source_id: &str, source_type: &str, model: &str) -> StoredVector {
        StoredVector {
            id: id.into(),
            source_id: source_id.into(),
            source_type: source_type.into(),
            vector: vec![1.0, 0.0],
            model: model.into(),
            created_at: "2026-01-01T00:00:00Z".into(),
        }
    }

    #[test]
    fn select_chunk_vectors_prefers_same_model_once_present() {
        let (store, _dir) = temp_store();
        store
            .save_chunks(&[StoredChunk {
                id: "c1".into(),
                publication_id: "pub1".into(),
                text: "chunk one".into(),
                page_number: None,
                char_offset: 0,
                char_length: 9,
                chunk_index: 0,
            }])
            .unwrap();
        store
            .save_vectors(&[
                vector("v-apple", "c1", "apple-nl"),
                vector("v-fastembed", "c1", "fastembed/AllMiniLML6V2"),
            ])
            .unwrap();

        let selected = select_chunk_vectors(&store, "fastembed/AllMiniLML6V2").unwrap();
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].id, "v-fastembed");
    }

    #[test]
    fn select_chunk_vectors_falls_back_to_all_when_model_absent() {
        let (store, _dir) = temp_store();
        store
            .save_vectors(&[vector("v-apple", "c1", "apple-nl")])
            .unwrap();
        let selected = select_chunk_vectors(&store, "fastembed/AllMiniLML6V2").unwrap();
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].id, "v-apple");
    }

    #[test]
    fn select_chunk_vectors_empty_store_returns_empty() {
        let (store, _dir) = temp_store();
        let selected = select_chunk_vectors(&store, "fastembed/AllMiniLML6V2").unwrap();
        assert!(selected.is_empty());
    }

    #[test]
    fn select_chunk_vectors_ignores_memory_item_vectors_when_gating() {
        let (store, _dir) = temp_store();
        store
            .save_vectors(&[
                typed_vector("v-memory", "m1", "memory-item", "fastembed/AllMiniLML6V2"),
                vector("v-apple", "c1", "apple-nl"),
            ])
            .unwrap();
        let selected = select_chunk_vectors(&store, "fastembed/AllMiniLML6V2").unwrap();
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].id, "v-apple");

        store
            .save_vectors(&[vector("v-fastembed", "c2", "fastembed/AllMiniLML6V2")])
            .unwrap();
        let selected = select_chunk_vectors(&store, "fastembed/AllMiniLML6V2").unwrap();
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].id, "v-fastembed");
    }
}
