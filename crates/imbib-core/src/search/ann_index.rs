//! Approximate Nearest Neighbor index using HNSW
//!
//! Provides O(log n) similarity search for embeddings, significantly faster
//! than brute-force O(n) search for large collections.

#[cfg(feature = "native")]
use hnsw_rs::prelude::*;

use serde::{Deserialize, Serialize};
use std::sync::RwLock;

/// Result of a similarity search
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct AnnSimilarityResult {
    pub publication_id: String,
    pub similarity: f32,
}

/// Configuration for the HNSW index
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AnnIndexConfig {
    /// Maximum number of connections per node (M parameter)
    pub max_connections: usize,
    /// Initial capacity
    pub capacity: usize,
    /// Maximum layer depth
    pub max_layer: usize,
    /// Construction-time search width
    pub ef_construction: usize,
}

impl Default for AnnIndexConfig {
    fn default() -> Self {
        Self {
            max_connections: 16,
            capacity: 10000,
            max_layer: 16,
            ef_construction: 200,
        }
    }
}

/// HNSW index for fast similarity search
#[cfg(feature = "native")]
pub struct AnnIndex {
    hnsw: RwLock<Hnsw<'static, f32, DistCosine>>,
    id_map: RwLock<Vec<String>>,
    config: AnnIndexConfig,
}

#[cfg(feature = "native")]
impl AnnIndex {
    /// Create a new empty index with default configuration
    pub fn new() -> Self {
        Self::with_config(AnnIndexConfig::default())
    }

    /// Create a new empty index with custom configuration
    pub fn with_config(config: AnnIndexConfig) -> Self {
        let hnsw = Hnsw::new(
            config.max_connections,
            config.capacity,
            config.max_layer,
            config.ef_construction,
            DistCosine,
        );
        Self {
            hnsw: RwLock::new(hnsw),
            id_map: RwLock::new(Vec::new()),
            config,
        }
    }

    /// Get the number of items in the index
    pub fn len(&self) -> usize {
        self.id_map.read().unwrap().len()
    }

    /// Check if the index is empty
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    /// Add an embedding to the index
    pub fn add(&self, publication_id: &str, embedding: &[f32]) {
        let mut id_map = self.id_map.write().unwrap();
        let idx = id_map.len();
        id_map.push(publication_id.to_string());
        drop(id_map);

        let hnsw = self.hnsw.read().unwrap();
        hnsw.insert((embedding, idx));
    }

    /// Add multiple embeddings at once (more efficient for batch operations)
    pub fn add_batch(&self, items: Vec<(String, Vec<f32>)>) {
        if items.is_empty() {
            return;
        }

        let mut id_map = self.id_map.write().unwrap();
        let start_idx = id_map.len();

        let data: Vec<(&Vec<f32>, usize)> = items
            .iter()
            .enumerate()
            .map(|(i, (id, emb))| {
                id_map.push(id.clone());
                (emb, start_idx + i)
            })
            .collect();

        drop(id_map);

        let hnsw = self.hnsw.read().unwrap();
        for (emb, idx) in data {
            hnsw.insert((emb, idx));
        }
    }

    /// Find k most similar publications
    pub fn search(&self, query: &[f32], k: usize) -> Vec<AnnSimilarityResult> {
        let ef_search = (k * 2).max(50); // Search beam width
        let hnsw = self.hnsw.read().unwrap();
        let id_map = self.id_map.read().unwrap();

        let results = hnsw.search(query, k, ef_search);

        results
            .into_iter()
            .map(|neighbour| AnnSimilarityResult {
                publication_id: id_map.get(neighbour.d_id).cloned().unwrap_or_default(),
                similarity: 1.0 - neighbour.distance, // Convert distance to similarity
            })
            .collect()
    }

    /// Serialize index to bytes
    pub fn save(&self) -> Result<Vec<u8>, String> {
        let id_map = self.id_map.read().unwrap();
        // Note: hnsw_rs doesn't directly support serialization of the index
        // We save the id_map and would need to rebuild the index on load
        bincode::serialize(&(id_map.clone(), &self.config))
            .map_err(|e| format!("Serialization error: {}", e))
    }

    /// Get the configuration used for this index
    pub fn config(&self) -> AnnIndexConfig {
        self.config.clone()
    }
}

#[cfg(feature = "native")]
impl Default for AnnIndex {
    fn default() -> Self {
        Self::new()
    }
}

// UniFFI exports for ANN functionality
// Using handle-based API like SearchIndex

#[cfg(feature = "native")]
use lazy_static::lazy_static;
#[cfg(feature = "native")]
use std::collections::HashMap;
#[cfg(feature = "native")]
use std::sync::Mutex;

#[cfg(feature = "native")]
lazy_static! {
    static ref ANN_INDEX_REGISTRY: RwLock<HashMap<u64, AnnIndex>> = RwLock::new(HashMap::new());
    static ref ANN_INDEX_COUNTER: Mutex<u64> = Mutex::new(0);
}

/// Create a new ANN index, returns a handle
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
#[derive(uniffi::Record)]
pub struct AnnIndexItem {
    pub publication_id: String,
    pub embedding: Vec<f32>,
}

/// Search for similar items
#[cfg(feature = "native")]
#[uniffi::export]
pub fn ann_index_search(handle_id: u64, query: Vec<f32>, top_k: u32) -> Vec<AnnSimilarityResult> {
    let registry = ANN_INDEX_REGISTRY.read().unwrap();
    if let Some(index) = registry.get(&handle_id) {
        index.search(&query, top_k as usize)
    } else {
        vec![]
    }
}

/// Get the number of items in the index
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
#[uniffi::export]
pub fn ann_index_close(handle_id: u64) -> bool {
    let mut registry = ANN_INDEX_REGISTRY.write().unwrap();
    registry.remove(&handle_id).is_some()
}

/// Get the number of active index handles (for debugging)
#[cfg(feature = "native")]
#[uniffi::export]
pub fn ann_index_handle_count() -> u32 {
    let registry = ANN_INDEX_REGISTRY.read().unwrap();
    registry.len() as u32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    #[cfg(feature = "native")]
    fn test_ann_index_basic() {
        let index = AnnIndex::new();

        // Add some embeddings
        index.add("pub1", &[1.0, 0.0, 0.0]);
        index.add("pub2", &[0.9, 0.1, 0.0]);
        index.add("pub3", &[0.0, 1.0, 0.0]);

        assert_eq!(index.len(), 3);

        // Search
        let results = index.search(&[1.0, 0.0, 0.0], 2);
        assert_eq!(results.len(), 2);
        // pub1 should be most similar to itself
        assert_eq!(results[0].publication_id, "pub1");
        assert!(results[0].similarity > 0.99);
    }

    #[test]
    #[cfg(feature = "native")]
    fn test_ann_index_batch() {
        let index = AnnIndex::new();

        let items = vec![
            ("pub1".to_string(), vec![1.0, 0.0, 0.0]),
            ("pub2".to_string(), vec![0.0, 1.0, 0.0]),
            ("pub3".to_string(), vec![0.0, 0.0, 1.0]),
        ];

        index.add_batch(items);
        assert_eq!(index.len(), 3);

        let results = index.search(&[0.0, 1.0, 0.0], 1);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].publication_id, "pub2");
    }

    #[test]
    #[cfg(feature = "native")]
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
}
