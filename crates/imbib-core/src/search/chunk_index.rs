//! Chunk-level HNSW index for RAG retrieval.
//!
//! Wraps the existing `AnnIndex` to provide chunk-specific operations:
//! - Maps chunk IDs to publication IDs for scope filtering
//! - Supports scoped search (all, specific publications, etc.)
//! - Designed for ~10-100 chunks per publication × thousands of publications

#[cfg(feature = "native")]
use super::ann_index::{AnnIndex, AnnIndexConfig};

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::sync::RwLock;

/// A chunk similarity result with publication linkage.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ChunkSimilarityResult {
    /// Chunk ID
    pub chunk_id: String,
    /// Parent publication ID
    pub publication_id: String,
    /// Cosine similarity score
    pub similarity: f32,
}

/// Chunk-level index with publication-aware filtering.
#[cfg(feature = "native")]
pub struct ChunkIndex {
    /// The underlying HNSW index
    ann: AnnIndex,
    /// chunk_id → publication_id mapping
    chunk_to_pub: RwLock<HashMap<String, String>>,
}

#[cfg(feature = "native")]
impl ChunkIndex {
    /// Create a new chunk index with default configuration.
    pub fn new() -> Self {
        Self::with_config(AnnIndexConfig {
            max_connections: 16,
            capacity: 50000, // Larger default: 1000 papers × 50 chunks
            max_layer: 16,
            ef_construction: 200,
        })
    }

    /// Create with custom configuration.
    pub fn with_config(config: AnnIndexConfig) -> Self {
        Self {
            ann: AnnIndex::with_config(config),
            chunk_to_pub: RwLock::new(HashMap::new()),
        }
    }

    /// Add a chunk embedding to the index.
    pub fn add(&self, chunk_id: &str, publication_id: &str, embedding: &[f32]) {
        self.ann.add(chunk_id, embedding);
        self.chunk_to_pub
            .write()
            .unwrap()
            .insert(chunk_id.to_string(), publication_id.to_string());
    }

    /// Add multiple chunk embeddings at once.
    pub fn add_batch(&self, items: Vec<(String, String, Vec<f32>)>) {
        if items.is_empty() {
            return;
        }

        let ann_items: Vec<(String, Vec<f32>)> = items
            .iter()
            .map(|(chunk_id, _, embedding)| (chunk_id.clone(), embedding.clone()))
            .collect();

        self.ann.add_batch(ann_items);

        let mut map = self.chunk_to_pub.write().unwrap();
        for (chunk_id, pub_id, _) in items {
            map.insert(chunk_id, pub_id);
        }
    }

    /// Search for similar chunks across the entire index.
    pub fn search(&self, query: &[f32], top_k: usize) -> Vec<ChunkSimilarityResult> {
        let ann_results = self.ann.search(query, top_k);
        let map = self.chunk_to_pub.read().unwrap();

        ann_results
            .into_iter()
            .map(|r| ChunkSimilarityResult {
                chunk_id: r.publication_id.clone(), // AnnIndex stores chunk_id as "publication_id"
                publication_id: map
                    .get(&r.publication_id)
                    .cloned()
                    .unwrap_or_default(),
                similarity: r.similarity,
            })
            .collect()
    }

    /// Search for similar chunks, filtered to specific publications.
    ///
    /// Retrieves more results from the ANN index than needed, then filters
    /// by publication scope. This is efficient because HNSW search is O(log n)
    /// and post-filtering is O(k).
    pub fn search_scoped(
        &self,
        query: &[f32],
        top_k: usize,
        publication_ids: &HashSet<String>,
    ) -> Vec<ChunkSimilarityResult> {
        // Over-fetch to account for filtered results
        let fetch_k = top_k * 5;
        let all_results = self.search(query, fetch_k);

        all_results
            .into_iter()
            .filter(|r| publication_ids.contains(&r.publication_id))
            .take(top_k)
            .collect()
    }

    /// Number of chunks in the index.
    pub fn len(&self) -> usize {
        self.ann.len()
    }

    /// Whether the index is empty.
    pub fn is_empty(&self) -> bool {
        self.ann.is_empty()
    }

    /// Get all publication IDs that have chunks in the index.
    pub fn indexed_publications(&self) -> HashSet<String> {
        let map = self.chunk_to_pub.read().unwrap();
        map.values().cloned().collect()
    }
}

#[cfg(feature = "native")]
impl Default for ChunkIndex {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// UniFFI handle-based API
// ---------------------------------------------------------------------------

#[cfg(feature = "native")]
use lazy_static::lazy_static;
#[cfg(feature = "native")]
use std::sync::Mutex;

#[cfg(feature = "native")]
lazy_static! {
    static ref CHUNK_INDEX_REGISTRY: RwLock<HashMap<u64, ChunkIndex>> =
        RwLock::new(HashMap::new());
    static ref CHUNK_INDEX_COUNTER: Mutex<u64> = Mutex::new(0);
}

/// Item for chunk batch insertion.
#[cfg(feature = "native")]
#[derive(uniffi::Record)]
pub struct ChunkIndexItem {
    pub chunk_id: String,
    pub publication_id: String,
    pub embedding: Vec<f32>,
}

/// Create a new chunk index, returns a handle.
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
#[uniffi::export]
pub fn chunk_index_search(handle: u64, query: Vec<f32>, top_k: u32) -> Vec<ChunkSimilarityResult> {
    let registry = CHUNK_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle) {
        index.search(&query, top_k as usize)
    } else {
        vec![]
    }
}

/// Search for similar chunks, filtered to specific publications.
#[cfg(feature = "native")]
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
        index.search_scoped(&query, top_k as usize, &scope)
    } else {
        vec![]
    }
}

/// Get the number of chunks in the index.
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
#[uniffi::export]
pub fn chunk_index_close(handle: u64) -> bool {
    let mut registry = CHUNK_INDEX_REGISTRY.write().unwrap();
    registry.remove(&handle).is_some()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[cfg(feature = "native")]
mod tests {
    use super::*;

    #[test]
    fn test_chunk_index_basic() {
        let index = ChunkIndex::new();

        index.add("c1", "pub1", &[1.0, 0.0, 0.0]);
        index.add("c2", "pub1", &[0.9, 0.1, 0.0]);
        index.add("c3", "pub2", &[0.0, 1.0, 0.0]);

        assert_eq!(index.len(), 3);

        let results = index.search(&[1.0, 0.0, 0.0], 2);
        assert_eq!(results.len(), 2);
        assert_eq!(results[0].chunk_id, "c1");
        assert_eq!(results[0].publication_id, "pub1");
        assert!(results[0].similarity > 0.99);
    }

    #[test]
    fn test_scoped_search() {
        let index = ChunkIndex::new();

        index.add("c1", "pub1", &[1.0, 0.0, 0.0]);
        index.add("c2", "pub1", &[0.9, 0.1, 0.0]);
        index.add("c3", "pub2", &[0.95, 0.05, 0.0]); // Very similar to query but in pub2

        // Unscoped: c1 should be first, c3 or c2 second
        let all_results = index.search(&[1.0, 0.0, 0.0], 3);
        assert_eq!(all_results.len(), 3);

        // Scoped to pub2 only
        let scope: HashSet<String> = vec!["pub2".to_string()].into_iter().collect();
        let scoped = index.search_scoped(&[1.0, 0.0, 0.0], 2, &scope);
        assert_eq!(scoped.len(), 1);
        assert_eq!(scoped[0].publication_id, "pub2");
    }

    #[test]
    fn test_batch_add() {
        let index = ChunkIndex::new();

        let items = vec![
            ("c1".into(), "pub1".into(), vec![1.0, 0.0, 0.0]),
            ("c2".into(), "pub1".into(), vec![0.0, 1.0, 0.0]),
            ("c3".into(), "pub2".into(), vec![0.0, 0.0, 1.0]),
        ];

        index.add_batch(items);
        assert_eq!(index.len(), 3);

        let pubs = index.indexed_publications();
        assert!(pubs.contains("pub1"));
        assert!(pubs.contains("pub2"));
    }
}
