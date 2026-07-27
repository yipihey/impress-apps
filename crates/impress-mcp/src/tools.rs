//! MCP tool implementations for semantic search over local PDFs.

use std::cell::OnceCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

use imbib_core::search::{ChunkIndex, ChunkSimilarityResult, EmbeddingStore, SemanticSearch};
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
    pub main_store: Option<Connection>,
}

impl ToolContext {
    /// Build a context that defers the embedding stack until it is asked for.
    pub fn deferred(embeddings_path: PathBuf, main_store: Option<Connection>) -> Self {
        Self {
            embeddings_path,
            semantic: OnceCell::new(),
            main_store,
        }
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

/// Open the embedding store, rebuild the chunk index, load the model.
fn build_semantic(embeddings_path: &Path) -> Result<SemanticContext, String> {
    let embedding_store = EmbeddingStore::open(embeddings_path.to_str().unwrap_or_default())
        .map_err(|e| format!("failed to open embedding store: {e}"))?;

    let chunk_index = ChunkIndex::new();
    rebuild_chunk_index(&embedding_store, &chunk_index)?;

    eprintln!("impress-mcp: initializing embedding model...");
    let semantic =
        SemanticSearch::new().map_err(|e| format!("failed to initialize SemanticSearch: {e}"))?;

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
fn rebuild_chunk_index(store: &EmbeddingStore, index: &ChunkIndex) -> Result<(), String> {
    let chunk_vectors = store.load_vectors_by_type("chunk")?;
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
    let metadata = if let Some(conn) = &ctx.main_store {
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
    let metadata: HashMap<String, PublicationMeta> = if let Some(conn) = &ctx.main_store {
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
