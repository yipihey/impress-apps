//! UniFFI surface for the embedding stack.
//!
//! The engines — the HNSW index, the chunk index, the SQLite sidecar and the
//! text embedder — live in the suite-level `impress-embeddings` crate. What
//! stays here is everything Swift actually binds against: the handle
//! registries, the `#[uniffi::export]` shims, and **mirror `uniffi::Record`
//! types** re-declared with byte-identical fields (and doc comments — uniffi
//! emits those into the generated Swift) so the generated bindings do not
//! move when the maths does.
//!
//! Two rules keep this file honest:
//!
//! 1. A mirror record must stay field-for-field and doc-for-doc identical to
//!    its `impress_embeddings` twin. The `From` impls below are the only
//!    conversion; adding a field on one side without the other is a compile
//!    error there, which is the point.
//! 2. New capability belongs in `impress-embeddings`, not here. This file is
//!    an adapter, and it should stay one.

use impress_embeddings::{AnnIndex, AnnIndexConfig, ChunkIndex, EmbeddingStore};
use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, RwLock};

// ---------------------------------------------------------------------------
// Mirror records — the Swift-facing shape of the engine types
// ---------------------------------------------------------------------------

/// A stored embedding vector with metadata.
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct StoredVector {
    /// Unique vector ID (UUID string)
    pub id: String,
    /// Source entity ID (publication_id or chunk_id)
    pub source_id: String,
    /// Source type: "publication" or "chunk"
    pub source_type: String,
    /// The embedding vector
    pub vector: Vec<f32>,
    /// Model identifier, e.g. "apple-nl-384", "fastembed-384"
    pub model: String,
    /// ISO 8601 creation timestamp
    pub created_at: String,
}

impl From<impress_embeddings::StoredVector> for StoredVector {
    fn from(v: impress_embeddings::StoredVector) -> Self {
        Self {
            id: v.id,
            source_id: v.source_id,
            source_type: v.source_type,
            vector: v.vector,
            model: v.model,
            created_at: v.created_at,
        }
    }
}

impl From<StoredVector> for impress_embeddings::StoredVector {
    fn from(v: StoredVector) -> Self {
        Self {
            id: v.id,
            source_id: v.source_id,
            source_type: v.source_type,
            vector: v.vector,
            model: v.model,
            created_at: v.created_at,
        }
    }
}

/// A text chunk extracted from a publication's PDF.
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct StoredChunk {
    /// Unique chunk ID (UUID string)
    pub id: String,
    /// Parent publication ID
    pub publication_id: String,
    /// The chunk text
    pub text: String,
    /// Page number in the PDF (0-indexed), if known
    pub page_number: Option<u32>,
    /// Character offset within the full document text
    pub char_offset: u32,
    /// Character length of the chunk
    pub char_length: u32,
    /// Sequential chunk index within the publication (0, 1, 2, ...)
    pub chunk_index: u32,
}

impl From<impress_embeddings::StoredChunk> for StoredChunk {
    fn from(c: impress_embeddings::StoredChunk) -> Self {
        Self {
            id: c.id,
            publication_id: c.publication_id,
            text: c.text,
            page_number: c.page_number,
            char_offset: c.char_offset,
            char_length: c.char_length,
            chunk_index: c.chunk_index,
        }
    }
}

impl From<StoredChunk> for impress_embeddings::StoredChunk {
    fn from(c: StoredChunk) -> Self {
        Self {
            id: c.id,
            publication_id: c.publication_id,
            text: c.text,
            page_number: c.page_number,
            char_offset: c.char_offset,
            char_length: c.char_length,
            chunk_index: c.chunk_index,
        }
    }
}

/// Statistics about stored vectors per model.
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct ModelStats {
    pub model: String,
    pub vector_count: u32,
    pub dimension: u32,
}

impl From<impress_embeddings::ModelStats> for ModelStats {
    fn from(s: impress_embeddings::ModelStats) -> Self {
        Self {
            model: s.model,
            vector_count: s.vector_count,
            dimension: s.dimension,
        }
    }
}

impl From<ModelStats> for impress_embeddings::ModelStats {
    fn from(s: ModelStats) -> Self {
        Self {
            model: s.model,
            vector_count: s.vector_count,
            dimension: s.dimension,
        }
    }
}

/// Status of embeddings for a specific publication.
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct PublicationEmbeddingStatus {
    pub publication_id: String,
    pub has_publication_vector: bool,
    pub chunk_count: u32,
    pub model: String,
}

impl From<impress_embeddings::PublicationEmbeddingStatus> for PublicationEmbeddingStatus {
    fn from(s: impress_embeddings::PublicationEmbeddingStatus) -> Self {
        Self {
            publication_id: s.publication_id,
            has_publication_vector: s.has_publication_vector,
            chunk_count: s.chunk_count,
            model: s.model,
        }
    }
}

impl From<PublicationEmbeddingStatus> for impress_embeddings::PublicationEmbeddingStatus {
    fn from(s: PublicationEmbeddingStatus) -> Self {
        Self {
            publication_id: s.publication_id,
            has_publication_vector: s.has_publication_vector,
            chunk_count: s.chunk_count,
            model: s.model,
        }
    }
}

/// Result of a similarity search
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct AnnSimilarityResult {
    pub publication_id: String,
    pub similarity: f32,
}

impl From<impress_embeddings::AnnSimilarityResult> for AnnSimilarityResult {
    fn from(r: impress_embeddings::AnnSimilarityResult) -> Self {
        Self {
            publication_id: r.publication_id,
            similarity: r.similarity,
        }
    }
}

impl From<AnnSimilarityResult> for impress_embeddings::AnnSimilarityResult {
    fn from(r: AnnSimilarityResult) -> Self {
        Self {
            publication_id: r.publication_id,
            similarity: r.similarity,
        }
    }
}

/// A chunk similarity result with publication linkage.
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct ChunkSimilarityResult {
    /// Chunk ID
    pub chunk_id: String,
    /// Parent publication ID
    pub publication_id: String,
    /// Cosine similarity score
    pub similarity: f32,
}

impl From<impress_embeddings::ChunkSimilarityResult> for ChunkSimilarityResult {
    fn from(r: impress_embeddings::ChunkSimilarityResult) -> Self {
        Self {
            chunk_id: r.chunk_id,
            publication_id: r.publication_id,
            similarity: r.similarity,
        }
    }
}

impl From<ChunkSimilarityResult> for impress_embeddings::ChunkSimilarityResult {
    fn from(r: ChunkSimilarityResult) -> Self {
        Self {
            chunk_id: r.chunk_id,
            publication_id: r.publication_id,
            similarity: r.similarity,
        }
    }
}

// ---------------------------------------------------------------------------
// ANN index — handle-based UniFFI API
// ---------------------------------------------------------------------------

lazy_static! {
    static ref ANN_INDEX_REGISTRY: RwLock<HashMap<u64, AnnIndex>> = RwLock::new(HashMap::new());
    static ref ANN_INDEX_COUNTER: Mutex<u64> = Mutex::new(0);
}

/// Create a new ANN index, returns a handle
#[uniffi::export]
pub fn ann_index_create() -> u64 {
    let mut counter = ANN_INDEX_COUNTER.lock().unwrap();
    *counter += 1;
    let handle_id = *counter;
    drop(counter);

    let index = AnnIndex::new();
    let mut registry = ANN_INDEX_REGISTRY.write().unwrap();
    registry.insert(handle_id, index);

    handle_id
}

/// Create a new ANN index with custom configuration
#[uniffi::export]
pub fn ann_index_create_with_config(
    max_connections: u32,
    capacity: u32,
    max_layer: u32,
    ef_construction: u32,
) -> u64 {
    let mut counter = ANN_INDEX_COUNTER.lock().unwrap();
    *counter += 1;
    let handle_id = *counter;
    drop(counter);

    let config = AnnIndexConfig {
        max_connections: max_connections as usize,
        capacity: capacity as usize,
        max_layer: max_layer as usize,
        ef_construction: ef_construction as usize,
    };
    let index = AnnIndex::with_config(config);
    let mut registry = ANN_INDEX_REGISTRY.write().unwrap();
    registry.insert(handle_id, index);

    handle_id
}

/// Add an embedding to the index
#[uniffi::export]
pub fn ann_index_add(handle_id: u64, publication_id: String, embedding: Vec<f32>) -> bool {
    let registry = ANN_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle_id) {
        index.add(&publication_id, &embedding);
        true
    } else {
        false
    }
}

/// Add multiple embeddings at once
#[uniffi::export]
pub fn ann_index_add_batch(handle_id: u64, items: Vec<AnnIndexItem>) -> bool {
    let registry = ANN_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle_id) {
        let batch: Vec<(String, Vec<f32>)> = items
            .into_iter()
            .map(|item| (item.publication_id, item.embedding))
            .collect();
        index.add_batch(batch);
        true
    } else {
        false
    }
}

/// Item for batch insertion
#[derive(uniffi::Record)]
pub struct AnnIndexItem {
    pub publication_id: String,
    pub embedding: Vec<f32>,
}

/// Search for similar items
#[uniffi::export]
pub fn ann_index_search(handle_id: u64, query: Vec<f32>, top_k: u32) -> Vec<AnnSimilarityResult> {
    let registry = ANN_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle_id) {
        index
            .search(&query, top_k as usize)
            .into_iter()
            .map(AnnSimilarityResult::from)
            .collect()
    } else {
        vec![]
    }
}

/// Get the number of items in the index
#[uniffi::export]
pub fn ann_index_size(handle_id: u64) -> u32 {
    let registry = ANN_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle_id) {
        index.len() as u32
    } else {
        0
    }
}

/// Close and release an index
#[uniffi::export]
pub fn ann_index_close(handle_id: u64) -> bool {
    let mut registry = ANN_INDEX_REGISTRY.write().unwrap();
    registry.remove(&handle_id).is_some()
}

/// Get the number of active index handles (for debugging)
#[uniffi::export]
pub fn ann_index_handle_count() -> u32 {
    let registry = ANN_INDEX_REGISTRY.read().unwrap();
    registry.len() as u32
}

// ---------------------------------------------------------------------------
// Chunk index — handle-based UniFFI API
// ---------------------------------------------------------------------------

lazy_static! {
    static ref CHUNK_INDEX_REGISTRY: RwLock<HashMap<u64, ChunkIndex>> = RwLock::new(HashMap::new());
    static ref CHUNK_INDEX_COUNTER: Mutex<u64> = Mutex::new(0);
}

/// Item for chunk batch insertion.
#[derive(uniffi::Record)]
pub struct ChunkIndexItem {
    pub chunk_id: String,
    pub publication_id: String,
    pub embedding: Vec<f32>,
}

/// Create a new chunk index, returns a handle.
#[uniffi::export]
pub fn chunk_index_create() -> u64 {
    let mut counter = CHUNK_INDEX_COUNTER.lock().unwrap();
    *counter += 1;
    let handle = *counter;
    drop(counter);

    let index = ChunkIndex::new();
    let mut registry = CHUNK_INDEX_REGISTRY.write().unwrap();
    registry.insert(handle, index);
    handle
}

/// Add a single chunk to the index.
#[uniffi::export]
pub fn chunk_index_add(
    handle: u64,
    chunk_id: String,
    publication_id: String,
    embedding: Vec<f32>,
) -> bool {
    let registry = CHUNK_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle) {
        index.add(&chunk_id, &publication_id, &embedding);
        true
    } else {
        false
    }
}

/// Add multiple chunks at once.
#[uniffi::export]
pub fn chunk_index_add_batch(handle: u64, items: Vec<ChunkIndexItem>) -> bool {
    let registry = CHUNK_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle) {
        let batch: Vec<(String, String, Vec<f32>)> = items
            .into_iter()
            .map(|item| (item.chunk_id, item.publication_id, item.embedding))
            .collect();
        index.add_batch(batch);
        true
    } else {
        false
    }
}

/// Search for similar chunks (unscoped).
#[uniffi::export]
pub fn chunk_index_search(handle: u64, query: Vec<f32>, top_k: u32) -> Vec<ChunkSimilarityResult> {
    let registry = CHUNK_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle) {
        index
            .search(&query, top_k as usize)
            .into_iter()
            .map(ChunkSimilarityResult::from)
            .collect()
    } else {
        vec![]
    }
}

/// Search for similar chunks, filtered to specific publications.
#[uniffi::export]
pub fn chunk_index_search_scoped(
    handle: u64,
    query: Vec<f32>,
    top_k: u32,
    publication_ids: Vec<String>,
) -> Vec<ChunkSimilarityResult> {
    let registry = CHUNK_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle) {
        let scope: HashSet<String> = publication_ids.into_iter().collect();
        index
            .search_scoped(&query, top_k as usize, &scope)
            .into_iter()
            .map(ChunkSimilarityResult::from)
            .collect()
    } else {
        vec![]
    }
}

/// Get the number of chunks in the index.
#[uniffi::export]
pub fn chunk_index_size(handle: u64) -> u32 {
    let registry = CHUNK_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle) {
        index.len() as u32
    } else {
        0
    }
}

/// Close and release a chunk index.
#[uniffi::export]
pub fn chunk_index_close(handle: u64) -> bool {
    let mut registry = CHUNK_INDEX_REGISTRY.write().unwrap();
    registry.remove(&handle).is_some()
}

// ---------------------------------------------------------------------------
// Embedding store — handle-based UniFFI API
// ---------------------------------------------------------------------------

lazy_static! {
    static ref EMBEDDING_STORE_REGISTRY: RwLock<HashMap<u64, EmbeddingStore>> =
        RwLock::new(HashMap::new());
    static ref EMBEDDING_STORE_COUNTER: Mutex<u64> = Mutex::new(0);
}

/// Open or create an embedding store, returns a handle.
#[uniffi::export]
pub fn embedding_store_open(path: String) -> u64 {
    match EmbeddingStore::open(&path) {
        Ok(store) => {
            let mut counter = EMBEDDING_STORE_COUNTER.lock().unwrap();
            *counter += 1;
            let handle = *counter;
            drop(counter);

            let mut registry = EMBEDDING_STORE_REGISTRY.write().unwrap();
            registry.insert(handle, store);
            handle
        }
        Err(e) => {
            eprintln!("embedding_store_open failed: {}", e);
            0
        }
    }
}

/// Save embedding vectors. Returns number saved.
#[uniffi::export]
pub fn embedding_store_save_vectors(handle: u64, vectors: Vec<StoredVector>) -> u32 {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        let vectors: Vec<impress_embeddings::StoredVector> = vectors
            .into_iter()
            .map(impress_embeddings::StoredVector::from)
            .collect();
        store.save_vectors(&vectors).unwrap_or(0) as u32
    } else {
        0
    }
}

/// Get vectors for a source entity.
#[uniffi::export]
pub fn embedding_store_get_vectors(handle: u64, source_id: String) -> Vec<StoredVector> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store
            .get_vectors(&source_id)
            .unwrap_or_default()
            .into_iter()
            .map(StoredVector::from)
            .collect()
    } else {
        vec![]
    }
}

/// Load all vectors (for HNSW rebuild at startup).
#[uniffi::export]
pub fn embedding_store_load_all_vectors(handle: u64) -> Vec<StoredVector> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store
            .load_all_vectors()
            .unwrap_or_default()
            .into_iter()
            .map(StoredVector::from)
            .collect()
    } else {
        vec![]
    }
}

/// Load vectors filtered by source type ("publication" or "chunk").
#[uniffi::export]
pub fn embedding_store_load_vectors_by_type(handle: u64, source_type: String) -> Vec<StoredVector> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store
            .load_vectors_by_type(&source_type)
            .unwrap_or_default()
            .into_iter()
            .map(StoredVector::from)
            .collect()
    } else {
        vec![]
    }
}

/// Save text chunks. Returns number saved.
#[uniffi::export]
pub fn embedding_store_save_chunks(handle: u64, chunks: Vec<StoredChunk>) -> u32 {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        let chunks: Vec<impress_embeddings::StoredChunk> = chunks
            .into_iter()
            .map(impress_embeddings::StoredChunk::from)
            .collect();
        store.save_chunks(&chunks).unwrap_or(0) as u32
    } else {
        0
    }
}

/// Get chunks for a publication.
#[uniffi::export]
pub fn embedding_store_get_chunks(handle: u64, publication_id: String) -> Vec<StoredChunk> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store
            .get_chunks(&publication_id)
            .unwrap_or_default()
            .into_iter()
            .map(StoredChunk::from)
            .collect()
    } else {
        vec![]
    }
}

/// Get a single chunk by ID.
#[uniffi::export]
pub fn embedding_store_get_chunk(handle: u64, chunk_id: String) -> Option<StoredChunk> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store
            .get_chunk(&chunk_id)
            .unwrap_or(None)
            .map(StoredChunk::from)
    } else {
        None
    }
}

/// Delete all vectors and chunks for a source entity.
#[uniffi::export]
pub fn embedding_store_delete_by_source(handle: u64, source_id: String) -> u32 {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        let vec_count = store.delete_by_source(&source_id).unwrap_or(0);
        let chunk_count = store.delete_chunks(&source_id).unwrap_or(0);
        vec_count + chunk_count
    } else {
        0
    }
}

/// Delete all vectors for a given model.
#[uniffi::export]
pub fn embedding_store_delete_by_model(handle: u64, model: String) -> u32 {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.delete_by_model(&model).unwrap_or(0)
    } else {
        0
    }
}

/// Get total vector count.
#[uniffi::export]
pub fn embedding_store_vector_count(handle: u64) -> u32 {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.vector_count().unwrap_or(0)
    } else {
        0
    }
}

/// Get total chunk count.
#[uniffi::export]
pub fn embedding_store_chunk_count(handle: u64) -> u32 {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.chunk_count().unwrap_or(0)
    } else {
        0
    }
}

/// Get number of publications with chunks.
#[uniffi::export]
pub fn embedding_store_chunked_publication_count(handle: u64) -> u32 {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.chunked_publication_count().unwrap_or(0)
    } else {
        0
    }
}

/// Get per-model statistics.
#[uniffi::export]
pub fn embedding_store_model_stats(handle: u64) -> Vec<ModelStats> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store
            .model_stats()
            .unwrap_or_default()
            .into_iter()
            .map(ModelStats::from)
            .collect()
    } else {
        vec![]
    }
}

/// Clear all data in the store.
#[uniffi::export]
pub fn embedding_store_clear(handle: u64) -> bool {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.clear_all().is_ok()
    } else {
        false
    }
}

/// Close and release a store handle.
#[uniffi::export]
pub fn embedding_store_close(handle: u64) -> bool {
    let mut registry = EMBEDDING_STORE_REGISTRY.write().unwrap();
    registry.remove(&handle).is_some()
}

// ---------------------------------------------------------------------------
// Tests — the handle API, and the mirror-conversion parity gate
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_handle_api() {
        let handle = ann_index_create();
        assert!(handle > 0);

        assert!(ann_index_add(
            handle,
            "pub1".to_string(),
            vec![1.0, 0.0, 0.0]
        ));
        assert!(ann_index_add(
            handle,
            "pub2".to_string(),
            vec![0.0, 1.0, 0.0]
        ));

        assert_eq!(ann_index_size(handle), 2);

        let results = ann_index_search(handle, vec![1.0, 0.0, 0.0], 1);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].publication_id, "pub1");

        assert!(ann_index_close(handle));
    }

    #[test]
    fn test_chunk_index_handle_api() {
        let handle = chunk_index_create();
        assert!(handle > 0);

        assert!(chunk_index_add_batch(
            handle,
            vec![
                ChunkIndexItem {
                    chunk_id: "c1".into(),
                    publication_id: "pub1".into(),
                    embedding: vec![1.0, 0.0, 0.0],
                },
                ChunkIndexItem {
                    chunk_id: "c2".into(),
                    publication_id: "pub2".into(),
                    embedding: vec![0.0, 1.0, 0.0],
                },
            ]
        ));

        assert_eq!(chunk_index_size(handle), 2);

        let scoped =
            chunk_index_search_scoped(handle, vec![1.0, 0.0, 0.0], 2, vec!["pub1".to_string()]);
        assert_eq!(scoped.len(), 1);
        assert_eq!(scoped[0].chunk_id, "c1");
        assert_eq!(scoped[0].publication_id, "pub1");

        assert!(chunk_index_close(handle));
    }

    /// The mirror records are a second declaration of the same data, so the
    /// only thing that can silently break is a conversion that drops or
    /// crosses a field. Write through the FFI shims, then read the same file
    /// back with `impress_embeddings::EmbeddingStore` directly and demand
    /// field-for-field equality: a swapped `char_offset`/`char_length` or a
    /// dropped `page_number` fails here and nowhere else.
    #[test]
    fn test_mirror_records_round_trip_losslessly() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("mirror_parity.sqlite");
        let path_str = path.to_str().unwrap().to_string();

        let handle = embedding_store_open(path_str.clone());
        assert!(handle > 0, "store must open");

        let vectors = vec![
            StoredVector {
                id: "v1".into(),
                source_id: "pub1".into(),
                source_type: "publication".into(),
                vector: vec![1.0, -0.5, 0.25, 0.0],
                model: "apple-nl-384".into(),
                created_at: "2026-01-01T00:00:00Z".into(),
            },
            StoredVector {
                id: "v2".into(),
                source_id: "c1".into(),
                source_type: "chunk".into(),
                vector: vec![0.0, 1.0],
                model: "fastembed-384".into(),
                created_at: "2026-02-02T12:34:56Z".into(),
            },
        ];
        let chunks = vec![
            StoredChunk {
                id: "c1".into(),
                publication_id: "pub1".into(),
                text: "First chunk of text.".into(),
                page_number: Some(3),
                char_offset: 11,
                char_length: 22,
                chunk_index: 0,
            },
            StoredChunk {
                id: "c2".into(),
                publication_id: "pub1".into(),
                text: "Second chunk — non-ASCII ✓".into(),
                page_number: None,
                char_offset: 33,
                char_length: 44,
                chunk_index: 1,
            },
        ];

        assert_eq!(embedding_store_save_vectors(handle, vectors.clone()), 2);
        assert_eq!(embedding_store_save_chunks(handle, chunks.clone()), 2);
        assert!(embedding_store_close(handle));

        // Read the same file through the engine type, bypassing the mirrors.
        let engine = impress_embeddings::EmbeddingStore::open(&path_str).unwrap();

        let mut engine_vectors = engine.load_all_vectors().unwrap();
        engine_vectors.sort_by(|a, b| a.id.cmp(&b.id));
        assert_eq!(engine_vectors.len(), 2);
        for (mirror, engine_row) in vectors.iter().zip(engine_vectors.iter()) {
            assert_eq!(
                &impress_embeddings::StoredVector::from(mirror.clone()),
                engine_row,
                "StoredVector mirror must round-trip field-for-field"
            );
            // …and back through the other conversion direction.
            let back = StoredVector::from(engine_row.clone());
            assert_eq!(back.id, mirror.id);
            assert_eq!(back.source_id, mirror.source_id);
            assert_eq!(back.source_type, mirror.source_type);
            assert_eq!(back.vector, mirror.vector);
            assert_eq!(back.model, mirror.model);
            assert_eq!(back.created_at, mirror.created_at);
        }

        let engine_chunks = engine.get_chunks("pub1").unwrap();
        assert_eq!(engine_chunks.len(), 2);
        for (mirror, engine_row) in chunks.iter().zip(engine_chunks.iter()) {
            assert_eq!(
                &impress_embeddings::StoredChunk::from(mirror.clone()),
                engine_row,
                "StoredChunk mirror must round-trip field-for-field"
            );
            let back = StoredChunk::from(engine_row.clone());
            assert_eq!(back.id, mirror.id);
            assert_eq!(back.publication_id, mirror.publication_id);
            assert_eq!(back.text, mirror.text);
            assert_eq!(back.page_number, mirror.page_number);
            assert_eq!(back.char_offset, mirror.char_offset);
            assert_eq!(back.char_length, mirror.char_length);
            assert_eq!(back.chunk_index, mirror.chunk_index);
        }

        // ModelStats and PublicationEmbeddingStatus have no shim that produces
        // them from an engine read path other than model_stats(); check both
        // conversions directly so a renamed field cannot slip through.
        let engine_stats = engine.model_stats().unwrap();
        let mirrored: Vec<ModelStats> =
            engine_stats.iter().cloned().map(ModelStats::from).collect();
        for (m, e) in mirrored.iter().zip(engine_stats.iter()) {
            assert_eq!(&impress_embeddings::ModelStats::from(m.clone()), e);
        }

        let status = PublicationEmbeddingStatus {
            publication_id: "pub1".into(),
            has_publication_vector: true,
            chunk_count: 2,
            model: "apple-nl-384".into(),
        };
        let engine_status = impress_embeddings::PublicationEmbeddingStatus::from(status.clone());
        assert_eq!(engine_status.publication_id, status.publication_id);
        assert_eq!(
            engine_status.has_publication_vector,
            status.has_publication_vector
        );
        assert_eq!(engine_status.chunk_count, status.chunk_count);
        assert_eq!(engine_status.model, status.model);
        let back = PublicationEmbeddingStatus::from(engine_status);
        assert_eq!(back.publication_id, status.publication_id);
        assert_eq!(back.has_publication_vector, status.has_publication_vector);
        assert_eq!(back.chunk_count, status.chunk_count);
        assert_eq!(back.model, status.model);
    }
}
