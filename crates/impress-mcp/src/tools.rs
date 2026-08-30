//! MCP tool implementations for semantic search over local PDFs.

use std::cell::OnceCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use impress_embeddings::{
    ChunkIndex, ChunkSimilarityResult, EmbeddingStore, SemanticSearch, StoredVector,
};
use rusqlite::Connection;
use serde_json::{json, Value};

use crate::store::{list_publications_by_ids, PublicationMeta};

/// The embedding stack behind the three hand-written semantic-search tools.
///
/// Building it means opening the embedding store, rebuilding an HNSW index
/// over every chunk vector, and loading the fastembed model — seconds on a
/// large library, and a model load that may reach the network.
pub struct SemanticContext {
    pub embedding_store: EmbeddingStore,
    pub chunk_index: ChunkIndex,
    pub semantic: SemanticSearch,
}

/// Shared context for tool execution.
///
/// The embedding stack is built **on first use**, not at startup. None of the
/// `#[impress_service]` inventory tools need it, and a client that only calls
/// those (impel, which spawns this binary at app launch) must not pay an HNSW
/// rebuild and a model load before the first `tools/list` is answered.
///
/// `OnceCell` rather than `OnceLock`: the JSON-RPC loop is single-threaded, and
/// `rusqlite::Connection` is not `Sync`.
pub struct ToolContext {
    embeddings_path: PathBuf,
    semantic: OnceCell<Option<SemanticContext>>,
    /// Opened on first use, never at startup. Opening it eagerly meant a slow
    /// or locked store delayed `initialize` — the client then saw no response
    /// at all, rather than a server that simply could not enrich metadata.
    /// Only the two hand-written semantic tools consult it.
    main_store_path: PathBuf,
    main_store: OnceCell<Option<Connection>>,
}

impl ToolContext {
    /// Build a context that defers BOTH the embedding stack and the main store
    /// until something actually needs them.
    pub fn deferred(embeddings_path: PathBuf, main_store_path: PathBuf) -> Self {
        Self {
            embeddings_path,
            semantic: OnceCell::new(),
            main_store_path,
            main_store: OnceCell::new(),
        }
    }

    /// The shared store, opened on first use. `None` when it is missing or
    /// cannot be opened — metadata enrichment then degrades, which is what the
    /// callers already handle.
    pub fn main_store(&self) -> Option<&Connection> {
        self.main_store
            .get_or_init(
                || match crate::store::open_main_store(&self.main_store_path) {
                    Ok(conn) => Some(conn),
                    Err(e) => {
                        eprintln!("impress-mcp: main store unavailable: {e}");
                        None
                    }
                },
            )
            .as_ref()
    }

    /// The embedding stack, built on first call. `None` when it could not be
    /// built — a missing embeddings database or a model that failed to load.
    /// Callers surface that as a tool error rather than failing the process.
    pub fn semantic(&self) -> Option<&SemanticContext> {
        self.semantic
            .get_or_init(|| match build_semantic(&self.embeddings_path) {
                Ok(ctx) => Some(ctx),
                Err(e) => {
                    eprintln!("impress-mcp: semantic search unavailable: {e}");
                    None
                }
            })
            .as_ref()
    }
}

/// Open the embedding store, load the model, rebuild the chunk index.
///
/// The model loads *before* the index rebuild (unlike before ADR-0028)
/// because the rebuild needs `semantic.model_id()` to decide which vectors
/// belong in the index — see `rebuild_chunk_index`.
fn build_semantic(embeddings_path: &Path) -> Result<SemanticContext, String> {
    let embedding_store = EmbeddingStore::open(embeddings_path.to_str().unwrap_or_default())
        .map_err(|e| format!("failed to open embedding store: {e}"))?;

    eprintln!("impress-mcp: initializing embedding model...");
    let semantic =
        SemanticSearch::new().map_err(|e| format!("failed to initialize SemanticSearch: {e}"))?;

    let chunk_index = ChunkIndex::new();
    rebuild_chunk_index(&embedding_store, &chunk_index, semantic.model_id())?;

    eprintln!(
        "impress-mcp: semantic search ready — {} chunks across {} publications",
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
///
/// Chunk vectors have `source_id = chunk_id`. Each chunk is looked up to get
/// its publication_id so the index carries the right mapping.
///
/// `model` is `semantic.model_id()` — the model this process embeds queries
/// with. The vector *selection* is gated (see `select_chunk_vectors`); once
/// selected, the loop below is unchanged from before ADR-0028.
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

/// The model-gated chunk-vector selection (ADR-0028 D4), pulled out of
/// `rebuild_chunk_index` so the decision itself — which rows load — is
/// unit-testable without building an HNSW index.
///
/// Once the sidecar holds at least one vector for `model`, only same-model
/// chunk vectors load: mixing `apple-nl` and `fastembed` vectors in one HNSW
/// graph makes cosine distance between them meaningless. Until then, every
/// chunk vector loads regardless of model — exactly the pre-ADR-0028
/// behavior — so a device that has only ever run imbib.app keeps searching
/// correctly instead of coming up empty the moment this filter ships ahead
/// of the backfill executor that will populate fastembed vectors.
fn select_chunk_vectors(store: &EmbeddingStore, model: &str) -> Result<Vec<StoredVector>, String> {
    if store.has_vectors_for_model(model)? {
        store.load_vectors_by_type_and_model("chunk", model)
    } else {
        eprintln!(
            "impress-mcp: sidecar holds no '{model}' vectors yet — loading all chunk vectors \
             regardless of model. Semantic search runs cross-model until the impress backfill \
             executor (ADR-0028 D7) populates fastembed vectors."
        );
        store.load_vectors_by_type("chunk")
    }
}

/// Message returned by the semantic tools when the stack could not be built.
pub const SEMANTIC_UNAVAILABLE: &str =
    "Semantic search is unavailable: no embeddings database, or the model failed to load. \
     Index PDFs in imbib first.";

// ---------------------------------------------------------------------------
// search_papers
// ---------------------------------------------------------------------------

pub fn tool_search_papers(ctx: &ToolContext, args: &Value) -> Result<String, String> {
    let query = args
        .get("query")
        .and_then(|v| v.as_str())
        .ok_or("Missing required argument: query")?;
    let top_k = args.get("top_k").and_then(|v| v.as_u64()).unwrap_or(10) as usize;

    // Builds the embedding stack on first call (see `ToolContext::semantic`).
    let sem = ctx.semantic().ok_or(SEMANTIC_UNAVAILABLE)?;

    // 1. Embed the query
    let query_vec = sem
        .semantic
        .embed_query(query)
        .map_err(|e| format!("Embedding error: {}", e))?;

    // 2. HNSW search over chunk vectors
    let results: Vec<ChunkSimilarityResult> = sem.chunk_index.search(&query_vec, top_k * 3);

    if results.is_empty() {
        return Ok("[]".to_string());
    }

    // 3. Group by publication, keep top passages per publication
    let mut pub_passages: HashMap<String, Vec<PassageHit>> = HashMap::new();
    for r in &results {
        pub_passages
            .entry(r.publication_id.clone())
            .or_default()
            .push(PassageHit {
                chunk_id: r.chunk_id.clone(),
                similarity: r.similarity,
            });
    }

    // 4. Enrich with chunk text
    let mut enriched_passages: HashMap<String, Vec<EnrichedPassage>> = HashMap::new();
    for (pub_id, hits) in &pub_passages {
        let mut passages = Vec::new();
        for hit in hits {
            if let Ok(Some(chunk)) = sem.embedding_store.get_chunk(&hit.chunk_id) {
                passages.push(EnrichedPassage {
                    text: chunk.text,
                    page: chunk.page_number,
                    similarity: hit.similarity,
                });
            }
        }
        if !passages.is_empty() {
            enriched_passages.insert(pub_id.clone(), passages);
        }
    }

    // 5. Enrich with metadata from main store
    let pub_ids: Vec<String> = enriched_passages.keys().cloned().collect();
    let metadata = if let Some(conn) = ctx.main_store() {
        list_publications_by_ids(conn, &pub_ids).unwrap_or_default()
    } else {
        HashMap::new()
    };

    // 6. Build response sorted by best passage similarity
    let mut scored: Vec<(f32, Value)> = enriched_passages
        .into_iter()
        .map(|(pub_id, passages)| {
            let meta = metadata.get(&pub_id);
            let best_sim = passages.iter().map(|p| p.similarity).fold(0.0f32, f32::max);

            let passage_values: Vec<Value> = passages
                .iter()
                .map(|p| {
                    json!({
                        "text": p.text,
                        "page": p.page,
                        "similarity": format!("{:.4}", p.similarity),
                    })
                })
                .collect();

            (
                best_sim,
                json!({
                    "publication_id": pub_id,
                    "title": meta.map(|m| m.title.as_str()).unwrap_or(""),
                    "authors": meta.map(|m| m.authors.as_str()).unwrap_or(""),
                    "year": meta.and_then(|m| m.year),
                    "cite_key": meta.map(|m| m.cite_key.as_str()).unwrap_or(""),
                    "passages": passage_values,
                }),
            )
        })
        .collect();

    scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));

    let output: Vec<Value> = scored.into_iter().take(top_k).map(|(_, v)| v).collect();

    serde_json::to_string_pretty(&output).map_err(|e| e.to_string())
}

struct PassageHit {
    chunk_id: String,
    similarity: f32,
}

struct EnrichedPassage {
    text: String,
    page: Option<u32>,
    similarity: f32,
}

// ---------------------------------------------------------------------------
// get_paper_chunks
// ---------------------------------------------------------------------------

pub fn tool_get_paper_chunks(ctx: &ToolContext, args: &Value) -> Result<String, String> {
    let publication_id = args
        .get("publication_id")
        .and_then(|v| v.as_str())
        .ok_or("Missing required argument: publication_id")?;

    let sem = ctx.semantic().ok_or(SEMANTIC_UNAVAILABLE)?;

    let chunks = sem
        .embedding_store
        .get_chunks(publication_id)
        .map_err(|e| format!("Failed to get chunks: {}", e))?;

    let output: Vec<Value> = chunks
        .iter()
        .map(|c| {
            json!({
                "text": c.text,
                "page_number": c.page_number,
                "chunk_index": c.chunk_index,
            })
        })
        .collect();

    serde_json::to_string_pretty(&output).map_err(|e| e.to_string())
}

// ---------------------------------------------------------------------------
// list_indexed_papers
// ---------------------------------------------------------------------------

pub fn tool_list_indexed_papers(ctx: &ToolContext, args: &Value) -> Result<String, String> {
    let limit = args.get("limit").and_then(|v| v.as_u64()).unwrap_or(50) as usize;

    let sem = ctx.semantic().ok_or(SEMANTIC_UNAVAILABLE)?;

    // Get all publication IDs that have chunks in the index
    let pub_ids: Vec<String> = sem.chunk_index.indexed_publications().into_iter().collect();

    if pub_ids.is_empty() {
        return Ok("[]".to_string());
    }

    // Count chunks per publication
    let mut chunk_counts: HashMap<String, u32> = HashMap::new();
    for pub_id in &pub_ids {
        let chunks = sem.embedding_store.get_chunks(pub_id).unwrap_or_default();
        chunk_counts.insert(pub_id.clone(), chunks.len() as u32);
    }

    // Enrich with metadata
    let metadata: HashMap<String, PublicationMeta> = if let Some(conn) = ctx.main_store() {
        list_publications_by_ids(conn, &pub_ids).unwrap_or_default()
    } else {
        HashMap::new()
    };

    let mut output: Vec<Value> = pub_ids
        .iter()
        .take(limit)
        .map(|pub_id| {
            let meta = metadata.get(pub_id);
            let count = chunk_counts.get(pub_id).copied().unwrap_or(0);
            json!({
                "publication_id": pub_id,
                "title": meta.map(|m| m.title.as_str()).unwrap_or(""),
                "authors": meta.map(|m| m.authors.as_str()).unwrap_or(""),
                "year": meta.and_then(|m| m.year),
                "chunk_count": count,
            })
        })
        .collect();

    // Sort by title for consistent output
    output.sort_by(|a, b| {
        let ta = a["title"].as_str().unwrap_or("");
        let tb = b["title"].as_str().unwrap_or("");
        ta.cmp(tb)
    });

    serde_json::to_string_pretty(&output).map_err(|e| e.to_string())
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
        StoredVector {
            id: id.into(),
            source_id: source_id.into(),
            source_type: "chunk".into(),
            vector: vec![1.0, 0.0],
            model: model.into(),
            created_at: "2026-01-01T00:00:00Z".into(),
        }
    }

    /// Once a same-model vector exists, selection is strict: the foreign
    /// model is excluded even though both are present for the same chunk.
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

    /// Legacy path: no vector for `model` exists anywhere in the sidecar, so
    /// every chunk vector loads regardless of model — the pre-ADR-0028
    /// behavior, preserved until the backfill executor writes something in
    /// the query model's space.
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

    /// A same-model vector for a *different* chunk does not change the
    /// fallback decision for other rows: gating is a store-wide check
    /// (`has_vectors_for_model`), then a per-row filter
    /// (`load_vectors_by_type_and_model`) — once gated on, a chunk with only
    /// a foreign-model vector simply drops out rather than falling back.
    #[test]
    fn select_chunk_vectors_drops_foreign_only_rows_once_gated() {
        let (store, _dir) = temp_store();

        store
            .save_vectors(&[
                vector("v1", "c1", "fastembed/AllMiniLML6V2"),
                vector("v2", "c2", "apple-nl"),
            ])
            .unwrap();

        let selected = select_chunk_vectors(&store, "fastembed/AllMiniLML6V2").unwrap();
        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].source_id, "c1");
    }
}
