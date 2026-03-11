//! impress-mcp — MCP server for local impress suite search.
//!
//! Exposes semantic search over locally indexed PDFs via the
//! Model Context Protocol (JSON-RPC 2.0 over stdio).

mod server;
mod store;
mod tools;

use imbib_core::search::{ChunkIndex, EmbeddingStore, SemanticSearch};
use std::path::PathBuf;
use tools::ToolContext;

fn default_embeddings_path() -> PathBuf {
    dirs::data_dir()
        .expect("Could not determine data directory")
        .join("imbib/embeddings.sqlite")
}

fn default_main_store_path() -> PathBuf {
    dirs::home_dir()
        .expect("Could not determine home directory")
        .join("Library/Group Containers/group.com.impress.suite/workspace/impress.sqlite")
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();

    let mut embeddings_path = default_embeddings_path();
    let mut store_path = default_main_store_path();

    // Parse CLI overrides
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--embeddings-path" => {
                i += 1;
                embeddings_path =
                    PathBuf::from(args.get(i).expect("Missing value for --embeddings-path"));
            }
            "--store-path" => {
                i += 1;
                store_path = PathBuf::from(args.get(i).expect("Missing value for --store-path"));
            }
            _ => {
                eprintln!("Unknown argument: {}", args[i]);
                std::process::exit(1);
            }
        }
        i += 1;
    }

    // 1. Open embedding store
    let embedding_store = EmbeddingStore::open(embeddings_path.to_str().unwrap_or_default())
        .map_err(|e| format!("Failed to open embedding store: {}", e))?;

    // 2. Build HNSW index from chunk vectors with correct publication mapping
    let chunk_index = ChunkIndex::new();
    rebuild_chunk_index(&embedding_store, &chunk_index)?;

    // 4. Initialize fastembed model
    eprintln!("impress-mcp: initializing embedding model...");
    let semantic =
        SemanticSearch::new().map_err(|e| format!("Failed to initialize SemanticSearch: {}", e))?;

    // 5. Open main store (optional — metadata enrichment degrades gracefully)
    let main_store = if store_path.exists() {
        match store::open_main_store(&store_path) {
            Ok(conn) => {
                eprintln!("impress-mcp: main store opened at {}", store_path.display());
                Some(conn)
            }
            Err(e) => {
                eprintln!("impress-mcp: warning: could not open main store: {}", e);
                None
            }
        }
    } else {
        eprintln!(
            "impress-mcp: main store not found at {}, metadata enrichment disabled",
            store_path.display()
        );
        None
    };

    let index_size = chunk_index.len();
    let pub_count = chunk_index.indexed_publications().len();
    eprintln!(
        "impress-mcp: ready — {} chunks indexed across {} publications",
        index_size, pub_count
    );

    let ctx = ToolContext {
        embedding_store,
        chunk_index,
        semantic,
        main_store,
    };

    server::run_server(ctx)
}

/// Rebuild the HNSW chunk index from the embedding store.
///
/// Chunk vectors have source_id = chunk_id. We look up each chunk to get
/// the publication_id and build the index with proper mapping.
fn rebuild_chunk_index(store: &EmbeddingStore, index: &ChunkIndex) -> Result<(), String> {
    let chunk_vectors = store.load_vectors_by_type("chunk")?;
    if chunk_vectors.is_empty() {
        return Ok(());
    }

    let mut batch: Vec<(String, String, Vec<f32>)> = Vec::with_capacity(chunk_vectors.len());
    for v in chunk_vectors {
        // Look up the chunk to get its publication_id
        if let Ok(Some(chunk)) = store.get_chunk(&v.source_id) {
            batch.push((v.source_id, chunk.publication_id, v.vector));
        }
    }

    if !batch.is_empty() {
        index.add_batch(batch);
    }
    Ok(())
}
