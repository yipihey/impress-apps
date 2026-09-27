//! `imbib-semantic-service` — the three legacy semantic-search MCP tools
//! (`search_papers`, `get_paper_chunks`, `list_indexed_papers`) as a real
//! `#[impress_service]` trait, P3c step 1.
//!
//! See `service::ImbibSemanticService`'s module docs for why this crate
//! exists as its own thing rather than folding into `impress-mcp` or
//! `imbib-service`: the fastembed/tokenizers embedding stack it needs stays
//! out of the shared `full` inventory that `impress-cli` and `impel-tools`
//! link, so this crate is force-linked only behind the `semantic-search`
//! feature in `impress-capabilities`, which only `impress-mcp` enables.

#![forbid(unsafe_code)]

mod context;
mod store;

pub mod service;

pub use context::{SemanticContext, SemanticState, SEMANTIC_UNAVAILABLE};
pub use service::{DefaultImbibSemanticService, ImbibSemanticService};
pub use store::PublicationMeta;
