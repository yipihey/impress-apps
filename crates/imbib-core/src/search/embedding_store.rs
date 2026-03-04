//! SQLite-backed persistence for embeddings and text chunks.
//!
//! Stores computed embedding vectors and document chunks so they survive
//! across app launches. The HNSW graph is rebuilt from stored vectors on
//! startup (O(n) insert) instead of recomputing embeddings (~2-5ms each).
//!
//! Schema:
//! - `vectors`: embedding vectors with source linkage and model info
//! - `chunks`: text chunks extracted from PDFs with page/offset metadata

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Mutex, RwLock};

// ---------------------------------------------------------------------------
// Data types (shared across native + UniFFI)
// ---------------------------------------------------------------------------

/// A stored embedding vector with metadata.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Clone, Debug, Serialize, Deserialize)]
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

/// A text chunk extracted from a publication's PDF.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Clone, Debug, Serialize, Deserialize)]
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

/// Statistics about stored vectors per model.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ModelStats {
    pub model: String,
    pub vector_count: u32,
    pub dimension: u32,
}

/// Status of embeddings for a specific publication.
#[cfg_attr(feature = "native", derive(uniffi::Record))]
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PublicationEmbeddingStatus {
    pub publication_id: String,
    pub has_publication_vector: bool,
    pub chunk_count: u32,
    pub model: String,
}

// ---------------------------------------------------------------------------
// SQLite-backed EmbeddingStore (native only)
// ---------------------------------------------------------------------------

#[cfg(not(target_arch = "wasm32"))]
mod store_impl {
    use super::*;
    use std::path::PathBuf;

    pub struct EmbeddingStore {
        db_path: PathBuf,
    }

    impl EmbeddingStore {
        /// Open or create an embedding store at the given path.
        pub fn open(path: &str) -> Result<Self, String> {
            let db_path = PathBuf::from(path);

            // Ensure parent directory exists
            if let Some(parent) = db_path.parent() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| format!("Failed to create directory: {}", e))?;
            }

            let conn = rusqlite::Connection::open(&db_path)
                .map_err(|e| format!("Failed to open database: {}", e))?;

            // Enable WAL mode for better concurrent read performance
            conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
                .map_err(|e| format!("Failed to set pragmas: {}", e))?;

            // Create tables
            conn.execute_batch(
                "CREATE TABLE IF NOT EXISTS vectors (
                    id TEXT PRIMARY KEY,
                    source_id TEXT NOT NULL,
                    source_type TEXT NOT NULL,
                    vector BLOB NOT NULL,
                    model TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_vectors_source ON vectors(source_id, source_type);
                CREATE INDEX IF NOT EXISTS idx_vectors_model ON vectors(model);

                CREATE TABLE IF NOT EXISTS chunks (
                    id TEXT PRIMARY KEY,
                    publication_id TEXT NOT NULL,
                    text TEXT NOT NULL,
                    page_number INTEGER,
                    char_offset INTEGER NOT NULL,
                    char_length INTEGER NOT NULL,
                    chunk_index INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_chunks_pub ON chunks(publication_id);
                ",
            )
            .map_err(|e| format!("Failed to create tables: {}", e))?;

            Ok(Self { db_path })
        }

        fn conn(&self) -> Result<rusqlite::Connection, String> {
            rusqlite::Connection::open(&self.db_path)
                .map_err(|e| format!("Failed to open connection: {}", e))
        }

        // -- Vectors -----------------------------------------------------------

        /// Save embedding vectors (upserts by id).
        pub fn save_vectors(&self, vectors: &[StoredVector]) -> Result<usize, String> {
            let conn = self.conn()?;
            let mut count = 0usize;

            let tx = conn
                .unchecked_transaction()
                .map_err(|e| format!("Transaction error: {}", e))?;

            {
                let mut stmt = tx
                    .prepare_cached(
                        "INSERT OR REPLACE INTO vectors (id, source_id, source_type, vector, model, created_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    )
                    .map_err(|e| format!("Prepare error: {}", e))?;

                for v in vectors {
                    let blob = floats_to_bytes(&v.vector);
                    stmt.execute(rusqlite::params![
                        v.id,
                        v.source_id,
                        v.source_type,
                        blob,
                        v.model,
                        v.created_at,
                    ])
                    .map_err(|e| format!("Insert error: {}", e))?;
                    count += 1;
                }
            }

            tx.commit()
                .map_err(|e| format!("Commit error: {}", e))?;

            Ok(count)
        }

        /// Get all vectors for a given source entity.
        pub fn get_vectors(&self, source_id: &str) -> Result<Vec<StoredVector>, String> {
            let conn = self.conn()?;
            let mut stmt = conn
                .prepare(
                    "SELECT id, source_id, source_type, vector, model, created_at
                     FROM vectors WHERE source_id = ?1",
                )
                .map_err(|e| format!("Prepare error: {}", e))?;

            let rows = stmt
                .query_map([source_id], |row| {
                    let blob: Vec<u8> = row.get(3)?;
                    Ok(StoredVector {
                        id: row.get(0)?,
                        source_id: row.get(1)?,
                        source_type: row.get(2)?,
                        vector: bytes_to_floats(&blob),
                        model: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                })
                .map_err(|e| format!("Query error: {}", e))?;

            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| format!("Row error: {}", e))
        }

        /// Load all vectors (for rebuilding HNSW index at startup).
        pub fn load_all_vectors(&self) -> Result<Vec<StoredVector>, String> {
            let conn = self.conn()?;
            let mut stmt = conn
                .prepare(
                    "SELECT id, source_id, source_type, vector, model, created_at FROM vectors",
                )
                .map_err(|e| format!("Prepare error: {}", e))?;

            let rows = stmt
                .query_map([], |row| {
                    let blob: Vec<u8> = row.get(3)?;
                    Ok(StoredVector {
                        id: row.get(0)?,
                        source_id: row.get(1)?,
                        source_type: row.get(2)?,
                        vector: bytes_to_floats(&blob),
                        model: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                })
                .map_err(|e| format!("Query error: {}", e))?;

            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| format!("Row error: {}", e))
        }

        /// Load vectors filtered by source_type (e.g., "publication" or "chunk").
        pub fn load_vectors_by_type(&self, source_type: &str) -> Result<Vec<StoredVector>, String> {
            let conn = self.conn()?;
            let mut stmt = conn
                .prepare(
                    "SELECT id, source_id, source_type, vector, model, created_at
                     FROM vectors WHERE source_type = ?1",
                )
                .map_err(|e| format!("Prepare error: {}", e))?;

            let rows = stmt
                .query_map([source_type], |row| {
                    let blob: Vec<u8> = row.get(3)?;
                    Ok(StoredVector {
                        id: row.get(0)?,
                        source_id: row.get(1)?,
                        source_type: row.get(2)?,
                        vector: bytes_to_floats(&blob),
                        model: row.get(4)?,
                        created_at: row.get(5)?,
                    })
                })
                .map_err(|e| format!("Query error: {}", e))?;

            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| format!("Row error: {}", e))
        }

        /// Delete all vectors for a source entity.
        pub fn delete_by_source(&self, source_id: &str) -> Result<u32, String> {
            let conn = self.conn()?;
            let count = conn
                .execute("DELETE FROM vectors WHERE source_id = ?1", [source_id])
                .map_err(|e| format!("Delete error: {}", e))?;
            Ok(count as u32)
        }

        /// Delete all vectors for a given model (used when switching providers).
        pub fn delete_by_model(&self, model: &str) -> Result<u32, String> {
            let conn = self.conn()?;
            let count = conn
                .execute("DELETE FROM vectors WHERE model = ?1", [model])
                .map_err(|e| format!("Delete error: {}", e))?;
            Ok(count as u32)
        }

        /// Total vector count.
        pub fn vector_count(&self) -> Result<u32, String> {
            let conn = self.conn()?;
            let count: u32 = conn
                .query_row("SELECT COUNT(*) FROM vectors", [], |row| row.get(0))
                .map_err(|e| format!("Count error: {}", e))?;
            Ok(count)
        }

        /// Get per-model statistics.
        pub fn model_stats(&self) -> Result<Vec<ModelStats>, String> {
            let conn = self.conn()?;
            let mut stmt = conn
                .prepare(
                    "SELECT model, COUNT(*), LENGTH(vector) / 4
                     FROM vectors GROUP BY model",
                )
                .map_err(|e| format!("Prepare error: {}", e))?;

            let rows = stmt
                .query_map([], |row| {
                    Ok(ModelStats {
                        model: row.get(0)?,
                        vector_count: row.get(1)?,
                        dimension: row.get(2)?,
                    })
                })
                .map_err(|e| format!("Query error: {}", e))?;

            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| format!("Row error: {}", e))
        }

        // -- Chunks ------------------------------------------------------------

        /// Save text chunks (upserts by id).
        pub fn save_chunks(&self, chunks: &[StoredChunk]) -> Result<usize, String> {
            let conn = self.conn()?;
            let mut count = 0usize;

            let tx = conn
                .unchecked_transaction()
                .map_err(|e| format!("Transaction error: {}", e))?;

            {
                let mut stmt = tx
                    .prepare_cached(
                        "INSERT OR REPLACE INTO chunks
                         (id, publication_id, text, page_number, char_offset, char_length, chunk_index)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                    )
                    .map_err(|e| format!("Prepare error: {}", e))?;

                for c in chunks {
                    stmt.execute(rusqlite::params![
                        c.id,
                        c.publication_id,
                        c.text,
                        c.page_number,
                        c.char_offset,
                        c.char_length,
                        c.chunk_index,
                    ])
                    .map_err(|e| format!("Insert error: {}", e))?;
                    count += 1;
                }
            }

            tx.commit()
                .map_err(|e| format!("Commit error: {}", e))?;

            Ok(count)
        }

        /// Get all chunks for a publication.
        pub fn get_chunks(&self, publication_id: &str) -> Result<Vec<StoredChunk>, String> {
            let conn = self.conn()?;
            let mut stmt = conn
                .prepare(
                    "SELECT id, publication_id, text, page_number, char_offset, char_length, chunk_index
                     FROM chunks WHERE publication_id = ?1 ORDER BY chunk_index",
                )
                .map_err(|e| format!("Prepare error: {}", e))?;

            let rows = stmt
                .query_map([publication_id], |row| {
                    Ok(StoredChunk {
                        id: row.get(0)?,
                        publication_id: row.get(1)?,
                        text: row.get(2)?,
                        page_number: row.get(3)?,
                        char_offset: row.get(4)?,
                        char_length: row.get(5)?,
                        chunk_index: row.get(6)?,
                    })
                })
                .map_err(|e| format!("Query error: {}", e))?;

            rows.collect::<Result<Vec<_>, _>>()
                .map_err(|e| format!("Row error: {}", e))
        }

        /// Get a single chunk by ID.
        pub fn get_chunk(&self, chunk_id: &str) -> Result<Option<StoredChunk>, String> {
            let conn = self.conn()?;
            let mut stmt = conn
                .prepare(
                    "SELECT id, publication_id, text, page_number, char_offset, char_length, chunk_index
                     FROM chunks WHERE id = ?1",
                )
                .map_err(|e| format!("Prepare error: {}", e))?;

            let mut rows = stmt
                .query_map([chunk_id], |row| {
                    Ok(StoredChunk {
                        id: row.get(0)?,
                        publication_id: row.get(1)?,
                        text: row.get(2)?,
                        page_number: row.get(3)?,
                        char_offset: row.get(4)?,
                        char_length: row.get(5)?,
                        chunk_index: row.get(6)?,
                    })
                })
                .map_err(|e| format!("Query error: {}", e))?;

            match rows.next() {
                Some(Ok(chunk)) => Ok(Some(chunk)),
                Some(Err(e)) => Err(format!("Row error: {}", e)),
                None => Ok(None),
            }
        }

        /// Delete all chunks for a publication.
        pub fn delete_chunks(&self, publication_id: &str) -> Result<u32, String> {
            let conn = self.conn()?;
            let count = conn
                .execute(
                    "DELETE FROM chunks WHERE publication_id = ?1",
                    [publication_id],
                )
                .map_err(|e| format!("Delete error: {}", e))?;
            Ok(count as u32)
        }

        /// Total chunk count.
        pub fn chunk_count(&self) -> Result<u32, String> {
            let conn = self.conn()?;
            let count: u32 = conn
                .query_row("SELECT COUNT(*) FROM chunks", [], |row| row.get(0))
                .map_err(|e| format!("Count error: {}", e))?;
            Ok(count)
        }

        /// Number of publications with chunks.
        pub fn chunked_publication_count(&self) -> Result<u32, String> {
            let conn = self.conn()?;
            let count: u32 = conn
                .query_row(
                    "SELECT COUNT(DISTINCT publication_id) FROM chunks",
                    [],
                    |row| row.get(0),
                )
                .map_err(|e| format!("Count error: {}", e))?;
            Ok(count)
        }

        /// Delete everything (used when switching providers entirely).
        pub fn clear_all(&self) -> Result<(), String> {
            let conn = self.conn()?;
            conn.execute_batch("DELETE FROM vectors; DELETE FROM chunks;")
                .map_err(|e| format!("Clear error: {}", e))?;
            Ok(())
        }
    }

    // -- Helpers ---------------------------------------------------------------

    /// Encode f32 slice as little-endian bytes for SQLite BLOB storage.
    fn floats_to_bytes(floats: &[f32]) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(floats.len() * 4);
        for f in floats {
            bytes.extend_from_slice(&f.to_le_bytes());
        }
        bytes
    }

    /// Decode little-endian bytes back to f32 vec.
    fn bytes_to_floats(bytes: &[u8]) -> Vec<f32> {
        bytes
            .chunks_exact(4)
            .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
            .collect()
    }
}

// Re-export the store implementation on native platforms
#[cfg(not(target_arch = "wasm32"))]
pub use store_impl::EmbeddingStore;

// ---------------------------------------------------------------------------
// UniFFI handle-based API (matches ann_index.rs pattern)
// ---------------------------------------------------------------------------

#[cfg(feature = "native")]
use lazy_static::lazy_static;

#[cfg(feature = "native")]
lazy_static! {
    static ref EMBEDDING_STORE_REGISTRY: RwLock<HashMap<u64, store_impl::EmbeddingStore>> =
        RwLock::new(HashMap::new());
    static ref EMBEDDING_STORE_COUNTER: Mutex<u64> = Mutex::new(0);
}

/// Open or create an embedding store, returns a handle.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_open(path: String) -> u64 {
    match store_impl::EmbeddingStore::open(&path) {
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
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_save_vectors(handle: u64, vectors: Vec<StoredVector>) -> u32 {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.save_vectors(&vectors).unwrap_or(0) as u32
    } else {
        0
    }
}

/// Get vectors for a source entity.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_get_vectors(handle: u64, source_id: String) -> Vec<StoredVector> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.get_vectors(&source_id).unwrap_or_default()
    } else {
        vec![]
    }
}

/// Load all vectors (for HNSW rebuild at startup).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_load_all_vectors(handle: u64) -> Vec<StoredVector> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.load_all_vectors().unwrap_or_default()
    } else {
        vec![]
    }
}

/// Load vectors filtered by source type ("publication" or "chunk").
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_load_vectors_by_type(handle: u64, source_type: String) -> Vec<StoredVector> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.load_vectors_by_type(&source_type).unwrap_or_default()
    } else {
        vec![]
    }
}

/// Save text chunks. Returns number saved.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_save_chunks(handle: u64, chunks: Vec<StoredChunk>) -> u32 {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.save_chunks(&chunks).unwrap_or(0) as u32
    } else {
        0
    }
}

/// Get chunks for a publication.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_get_chunks(handle: u64, publication_id: String) -> Vec<StoredChunk> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.get_chunks(&publication_id).unwrap_or_default()
    } else {
        vec![]
    }
}

/// Get a single chunk by ID.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_get_chunk(handle: u64, chunk_id: String) -> Option<StoredChunk> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.get_chunk(&chunk_id).unwrap_or(None)
    } else {
        None
    }
}

/// Delete all vectors and chunks for a source entity.
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_model_stats(handle: u64) -> Vec<ModelStats> {
    let registry = EMBEDDING_STORE_REGISTRY.read().unwrap();
    if let Some(store) = registry.get(&handle) {
        store.model_stats().unwrap_or_default()
    } else {
        vec![]
    }
}

/// Clear all data in the store.
#[cfg(feature = "native")]
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
#[cfg(feature = "native")]
#[uniffi::export]
pub fn embedding_store_close(handle: u64) -> bool {
    let mut registry = EMBEDDING_STORE_REGISTRY.write().unwrap();
    registry.remove(&handle).is_some()
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
#[cfg(not(target_arch = "wasm32"))]
mod tests {
    use super::*;

    fn temp_store() -> EmbeddingStore {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test_embeddings.sqlite");
        EmbeddingStore::open(path.to_str().unwrap()).unwrap()
    }

    #[test]
    fn test_vector_roundtrip() {
        let store = temp_store();

        let vectors = vec![StoredVector {
            id: "v1".into(),
            source_id: "pub1".into(),
            source_type: "publication".into(),
            vector: vec![1.0, 0.5, -0.3, 0.0],
            model: "test-model-4".into(),
            created_at: "2026-01-01T00:00:00Z".into(),
        }];

        let saved = store.save_vectors(&vectors).unwrap();
        assert_eq!(saved, 1);

        let loaded = store.get_vectors("pub1").unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].id, "v1");
        assert_eq!(loaded[0].vector, vec![1.0, 0.5, -0.3, 0.0]);
        assert_eq!(loaded[0].model, "test-model-4");
    }

    #[test]
    fn test_chunk_roundtrip() {
        let store = temp_store();

        let chunks = vec![
            StoredChunk {
                id: "c1".into(),
                publication_id: "pub1".into(),
                text: "First chunk of text.".into(),
                page_number: Some(0),
                char_offset: 0,
                char_length: 20,
                chunk_index: 0,
            },
            StoredChunk {
                id: "c2".into(),
                publication_id: "pub1".into(),
                text: "Second chunk of text.".into(),
                page_number: Some(1),
                char_offset: 20,
                char_length: 21,
                chunk_index: 1,
            },
        ];

        let saved = store.save_chunks(&chunks).unwrap();
        assert_eq!(saved, 2);

        let loaded = store.get_chunks("pub1").unwrap();
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].chunk_index, 0);
        assert_eq!(loaded[1].chunk_index, 1);
    }

    #[test]
    fn test_load_all_vectors() {
        let store = temp_store();

        let vectors = vec![
            StoredVector {
                id: "v1".into(),
                source_id: "pub1".into(),
                source_type: "publication".into(),
                vector: vec![1.0, 0.0],
                model: "m1".into(),
                created_at: "2026-01-01T00:00:00Z".into(),
            },
            StoredVector {
                id: "v2".into(),
                source_id: "c1".into(),
                source_type: "chunk".into(),
                vector: vec![0.0, 1.0],
                model: "m1".into(),
                created_at: "2026-01-01T00:00:00Z".into(),
            },
        ];

        store.save_vectors(&vectors).unwrap();

        let all = store.load_all_vectors().unwrap();
        assert_eq!(all.len(), 2);

        let pubs = store.load_vectors_by_type("publication").unwrap();
        assert_eq!(pubs.len(), 1);
        assert_eq!(pubs[0].source_id, "pub1");

        let chunks = store.load_vectors_by_type("chunk").unwrap();
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].source_id, "c1");
    }

    #[test]
    fn test_model_stats() {
        let store = temp_store();

        let vectors = vec![
            StoredVector {
                id: "v1".into(),
                source_id: "pub1".into(),
                source_type: "publication".into(),
                vector: vec![1.0, 0.0, 0.0],
                model: "apple-nl-384".into(),
                created_at: "2026-01-01T00:00:00Z".into(),
            },
            StoredVector {
                id: "v2".into(),
                source_id: "pub2".into(),
                source_type: "publication".into(),
                vector: vec![0.0, 1.0, 0.0],
                model: "apple-nl-384".into(),
                created_at: "2026-01-01T00:00:00Z".into(),
            },
        ];

        store.save_vectors(&vectors).unwrap();

        let stats = store.model_stats().unwrap();
        assert_eq!(stats.len(), 1);
        assert_eq!(stats[0].model, "apple-nl-384");
        assert_eq!(stats[0].vector_count, 2);
    }

    #[test]
    fn test_delete_operations() {
        let store = temp_store();

        let vectors = vec![
            StoredVector {
                id: "v1".into(),
                source_id: "pub1".into(),
                source_type: "publication".into(),
                vector: vec![1.0],
                model: "m1".into(),
                created_at: "2026-01-01T00:00:00Z".into(),
            },
            StoredVector {
                id: "v2".into(),
                source_id: "pub2".into(),
                source_type: "publication".into(),
                vector: vec![0.0],
                model: "m1".into(),
                created_at: "2026-01-01T00:00:00Z".into(),
            },
        ];

        store.save_vectors(&vectors).unwrap();
        assert_eq!(store.vector_count().unwrap(), 2);

        store.delete_by_source("pub1").unwrap();
        assert_eq!(store.vector_count().unwrap(), 1);

        store.clear_all().unwrap();
        assert_eq!(store.vector_count().unwrap(), 0);
    }
}
