//! Search module
//!
//! Provides:
//! - Query building and parsing utilities for various search APIs (ADS, arXiv)
//! - Full-text search with Tantivy (unified search across metadata, PDFs, notes)
//! - Snippet extraction and term highlighting
//! - Semantic search with embeddings (optional, requires "embeddings" feature)
//!
//! Query building/parsing works on all platforms including WASM.
//! Full-text search requires native platforms (uses Tantivy).

mod query_builder;
mod query_parser;
pub mod snippets;

// Tantivy-based full-text search (native only - requires filesystem)
#[cfg(not(target_arch = "wasm32"))]
pub mod index;
#[cfg(not(target_arch = "wasm32"))]
pub mod schema;

#[cfg(feature = "embeddings")]
pub mod semantic;

// Approximate Nearest Neighbor search (native only)
#[cfg(feature = "native")]
pub mod ann_index;

#[cfg(feature = "native")]
pub use query_builder::{
    build_arxiv_author_category_query, build_classic_query, build_paper_query,
    is_classic_form_empty, is_paper_form_empty, ADSDatabase, QueryLogic,
};

#[cfg(feature = "native")]
pub use query_parser::{
    parse_arxiv_query, parse_classic_query, parse_paper_query, ParsedArXivForm, ParsedArXivTerm,
    ParsedClassicForm, ParsedPaperForm,
};

#[cfg(not(target_arch = "wasm32"))]
pub use index::*;
#[cfg(not(target_arch = "wasm32"))]
pub use schema::*;
#[cfg(feature = "native")]
pub use snippets::*;

#[cfg(feature = "native")]
pub use ann_index::*;

#[cfg(feature = "embeddings")]
pub use semantic::*;
