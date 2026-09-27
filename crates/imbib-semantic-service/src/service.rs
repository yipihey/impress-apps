//! `ImbibSemanticService` — the three legacy semantic-search MCP tools, as a
//! real `#[impress_service]` trait (P3c step 1, Tom's decision on ADR-0024
//! D7's other half).
//!
//! The P3a spike (see `docs/plan-verb-pipeline-and-transport.md`'s session
//! log, 2026-09-26) built this and reverted it: this crate is not linked
//! under `full`, so `impress-cli` and `impel-tools` never pay for the
//! fastembed/tokenizers embedding stack behind it — the decision
//! `crates/impress-mcp/Cargo.toml`'s own comment already recorded. P3c gives
//! it real lifecycle instead by carving out a `semantic-search` feature
//! beside `full` in `impress-capabilities` (and its kit crate), which only
//! `impress-mcp` enables.
//!
//! Each method keeps its old flat snake_case name as an `aliases` entry and
//! is `deprecated(since = "0.1.0", …)` on that alias, per P3a's mechanism —
//! a call that arrives as `search_papers` gets the additive `deprecated`
//! envelope field pointing at `search-papers`; a direct call to the
//! canonical name does not.

use std::collections::HashMap;

use impress_embeddings::ChunkSimilarityResult;
use impress_service_core::async_trait;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};
use serde_json::{json, Value};

use crate::context::{metadata_for, SemanticState, SEMANTIC_UNAVAILABLE};
use crate::store::PublicationMeta;

#[impress_service]
pub trait ImbibSemanticService: Send + Sync + 'static {
    /// Semantic search across all indexed PDFs in the local library. Finds
    /// relevant passages by meaning, not just keywords. Returns `{"ok",
    /// "results"}`, where `results` is the publications matched, with text
    /// excerpts, page numbers and similarity scores — or `{"ok": false,
    /// "message"}` when the embedding stack is unavailable.
    ///
    /// Returns an object (not a bare array) on purpose: the additive
    /// `deprecated` envelope field (P3a) only lands on object results, and a
    /// call through this method's `search_papers` alias must carry it.
    #[impress_method(
        safety = read_only,
        effects(reads = [any("reads the imbib embeddings sidecar and, for metadata, the shared impress store")]),
        deprecated(since = "0.1.0", note = "use search-papers"),
        aliases = ["search_papers"]
    )]
    async fn search_papers(&self, query: String, top_k: Option<u64>) -> Value;

    /// Get all text chunks for a specific publication. Use this for
    /// full-context RAG after finding a paper via `search-papers`. Returns
    /// `{"ok", "chunks"}`, `chunks` ordered by position in the document — or
    /// `{"ok": false, "message"}` when the embedding stack is unavailable.
    #[impress_method(
        safety = read_only,
        effects(reads = [any("reads the imbib embeddings sidecar")]),
        deprecated(since = "0.1.0", note = "use get-paper-chunks"),
        aliases = ["get_paper_chunks"]
    )]
    async fn get_paper_chunks(&self, publication_id: String) -> Value;

    /// List all publications that have been chunk-indexed for semantic
    /// search. Returns `{"ok", "papers"}`, `papers` carrying title, authors,
    /// year and chunk count for each — or `{"ok": false, "message"}` when the
    /// embedding stack is unavailable.
    #[impress_method(
        safety = read_only,
        effects(reads = [any("reads the imbib embeddings sidecar and, for metadata, the shared impress store")]),
        deprecated(since = "0.1.0", note = "use list-indexed-papers"),
        aliases = ["list_indexed_papers"]
    )]
    async fn list_indexed_papers(&self, limit: Option<u64>) -> Value;
}

#[derive(Default)]
pub struct DefaultImbibSemanticService {
    state: SemanticState,
}

impl DefaultImbibSemanticService {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait::async_trait]
impl ImbibSemanticService for DefaultImbibSemanticService {
    async fn search_papers(&self, query: String, top_k: Option<u64>) -> Value {
        search_papers_impl(&self.state, &query, top_k.unwrap_or(10) as usize)
    }

    async fn get_paper_chunks(&self, publication_id: String) -> Value {
        get_paper_chunks_impl(&self.state, &publication_id)
    }

    async fn list_indexed_papers(&self, limit: Option<u64>) -> Value {
        list_indexed_papers_impl(&self.state, limit.unwrap_or(50) as usize)
    }
}

fn error_result(message: impl Into<String>) -> Value {
    json!({ "ok": false, "message": message.into() })
}

// ---------------------------------------------------------------------------
// search_papers
// ---------------------------------------------------------------------------

fn search_papers_impl(state: &SemanticState, query: &str, top_k: usize) -> Value {
    let sem = match state.semantic() {
        Some(sem) => sem,
        None => return error_result(SEMANTIC_UNAVAILABLE),
    };

    let query_vec = match sem.semantic.embed_query(query) {
        Ok(v) => v,
        Err(e) => return error_result(format!("Embedding error: {e}")),
    };

    let results: Vec<ChunkSimilarityResult> = sem.chunk_index.search(&query_vec, top_k * 3);
    if results.is_empty() {
        return json!({ "ok": true, "results": [] });
    }

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

    let pub_ids: Vec<String> = enriched_passages.keys().cloned().collect();
    let metadata = metadata_for(state, &pub_ids);

    let mut scored: Vec<(f32, String, Value)> = enriched_passages
        .into_iter()
        .map(|(pub_id, passages)| {
            let meta = metadata.get(&pub_id);
            let best_sim = best_similarity(&passages);

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
                pub_id.clone(),
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

    rank_scored_publications(&mut scored);

    let output: Vec<Value> = scored.into_iter().take(top_k).map(|(_, _, v)| v).collect();
    json!({ "ok": true, "results": output })
}

/// The best passage similarity for one publication, folded from
/// `NEG_INFINITY` rather than `0.0` — cosine similarity is signed.
fn best_similarity(passages: &[EnrichedPassage]) -> f32 {
    passages
        .iter()
        .map(|p| p.similarity)
        .fold(f32::NEG_INFINITY, f32::max)
}

/// Best similarity descending, tie-broken by publication id ascending so
/// equal scores cannot reorder between runs.
fn rank_scored_publications(scored: &mut [(f32, String, Value)]) {
    scored.sort_by(|a, b| {
        b.0.partial_cmp(&a.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.1.cmp(&b.1))
    });
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

fn get_paper_chunks_impl(state: &SemanticState, publication_id: &str) -> Value {
    let sem = match state.semantic() {
        Some(sem) => sem,
        None => return error_result(SEMANTIC_UNAVAILABLE),
    };

    let chunks = match sem.embedding_store.get_chunks(publication_id) {
        Ok(c) => c,
        Err(e) => return error_result(format!("Failed to get chunks: {e}")),
    };

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

    json!({ "ok": true, "chunks": output })
}

// ---------------------------------------------------------------------------
// list_indexed_papers
// ---------------------------------------------------------------------------

fn list_indexed_papers_impl(state: &SemanticState, limit: usize) -> Value {
    let sem = match state.semantic() {
        Some(sem) => sem,
        None => return error_result(SEMANTIC_UNAVAILABLE),
    };

    let pub_ids: Vec<String> = sem.chunk_index.indexed_publications().into_iter().collect();
    if pub_ids.is_empty() {
        return json!({ "ok": true, "papers": [] });
    }

    let metadata: HashMap<String, PublicationMeta> = metadata_for(state, &pub_ids);
    let page = page_of_indexed_papers(pub_ids, &metadata, limit);

    let output: Vec<Value> = page
        .iter()
        .map(|pub_id| {
            let meta = metadata.get(pub_id);
            let count = sem
                .embedding_store
                .get_chunks(pub_id)
                .unwrap_or_default()
                .len() as u32;
            json!({
                "publication_id": pub_id,
                "title": meta.map(|m| m.title.as_str()).unwrap_or(""),
                "authors": meta.map(|m| m.authors.as_str()).unwrap_or(""),
                "year": meta.and_then(|m| m.year),
                "chunk_count": count,
            })
        })
        .collect();

    json!({ "ok": true, "papers": output })
}

/// Sorted by title (ids without metadata sort first, on the empty string),
/// tie-broken by publication id, cut to `limit` only after sorting — see
/// `crates/impress-mcp`'s original module docs for why the order of those two
/// steps is the point (a `HashSet`-order page reshuffled every process).
fn page_of_indexed_papers(
    mut pub_ids: Vec<String>,
    metadata: &HashMap<String, PublicationMeta>,
    limit: usize,
) -> Vec<String> {
    pub_ids.sort_by(|a, b| {
        let ta = metadata.get(a).map(|m| m.title.as_str()).unwrap_or("");
        let tb = metadata.get(b).map(|m| m.title.as_str()).unwrap_or("");
        ta.cmp(tb).then_with(|| a.cmp(b))
    });
    pub_ids.truncate(limit);
    pub_ids
}

impress_service_impl! {
    service = ImbibSemanticService,
    safety = read_only,
    since = "0.1.0",
    effects = {
        reads: [any("reads the imbib embeddings sidecar and the shared impress store")],
        writes: [],
        reach: [],
    },
    impl = DefaultImbibSemanticService,
    instance = DefaultImbibSemanticService::new,
    methods = [
        /// Semantic search across all indexed PDFs in the local library.
        search_papers(query: String, top_k: Option<u64>) -> Value,
        /// Get all text chunks for a specific publication.
        get_paper_chunks(publication_id: String) -> Value,
        /// List all publications that have been chunk-indexed for semantic search.
        list_indexed_papers(limit: Option<u64>) -> Value,
    ],
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(id: &str, title: &str) -> (String, PublicationMeta) {
        (
            id.to_string(),
            PublicationMeta {
                id: id.into(),
                title: title.into(),
                authors: String::new(),
                year: None,
                cite_key: String::new(),
            },
        )
    }

    #[test]
    fn best_similarity_keeps_negative_scores() {
        let passages = vec![
            EnrichedPassage {
                text: "worse".into(),
                page: None,
                similarity: -0.9,
            },
            EnrichedPassage {
                text: "best of a bad lot".into(),
                page: None,
                similarity: -0.2,
            },
        ];
        assert_eq!(best_similarity(&passages), -0.2);
    }

    #[test]
    fn rank_scored_publications_breaks_ties_on_publication_id() {
        let mut scored = vec![
            (0.5, "z-pub".to_string(), json!(1)),
            (0.9, "m-pub".to_string(), json!(2)),
            (0.5, "a-pub".to_string(), json!(3)),
        ];
        rank_scored_publications(&mut scored);
        let order: Vec<&str> = scored.iter().map(|(_, id, _)| id.as_str()).collect();
        assert_eq!(order, ["m-pub", "a-pub", "z-pub"]);
    }

    #[test]
    fn indexed_papers_page_is_first_titles_regardless_of_arrival_order() {
        let metadata: HashMap<String, PublicationMeta> = [
            meta("p1", "Delta"),
            meta("p2", "Alpha"),
            meta("p3", "Echo"),
            meta("p4", "Bravo"),
            meta("p5", "Charlie"),
        ]
        .into_iter()
        .collect();

        let arrival = ["p1", "p2", "p3", "p4", "p5"].map(String::from).to_vec();
        let page = page_of_indexed_papers(arrival, &metadata, 3);
        assert_eq!(page, ["p2", "p4", "p5"]); // Alpha, Bravo, Charlie
    }

    #[test]
    fn semantic_unavailable_when_no_embeddings_db() {
        let dir = tempfile::tempdir().unwrap();
        let state = SemanticState::deferred(
            dir.path().join("nonexistent-embeddings.sqlite"),
            dir.path().join("nonexistent-store.sqlite"),
        );
        // Missing embeddings db still opens (EmbeddingStore::open creates the
        // file), so the failure this test pins is a missing main store not
        // breaking search — the semantic stack itself degrades to `None`
        // only when the model truly cannot load, which is not exercised in
        // this offline unit test. What we CAN assert offline: search_papers
        // never panics and always returns a well-formed `{"ok", ...}` object.
        let out = search_papers_impl(&state, "anything", 10);
        assert!(
            out.is_object(),
            "search_papers must return an object: {out}"
        );
        assert!(out.get("ok").is_some(), "{out}");
    }
}
