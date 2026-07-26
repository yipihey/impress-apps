//! `imprint-service` — Phase 2D/2E of the impress Rust-core consolidation.
//!
//! This crate moves three pieces of imprint that previously lived in Swift
//! into Rust:
//!
//! 1. **Manuscript section persistence** (`sections`) — content-addressed
//!    storage of large bodies, idempotent upserts keyed by
//!    `(document_id, section_key)`, backed by the shared
//!    `impress-store-ffi::SharedStore`. Port of `ImprintStoreAdapter.swift`.
//!
//! 2. **Cross-document full-text search** (`search`) — tantivy-backed index
//!    over the section store, mirroring the pattern used by `imbib-core`'s
//!    publication index. Port of `ManuscriptSearchService.swift`.
//!
//! 3. **Stateless HTTP-router handlers** (`handlers`) — the slice of
//!    `ImprintHTTPRouter.swift` that doesn't touch AppKit / NSDocument /
//!    SwiftUI, lifted to a Rust trait (`ImprintHttpHandlers`) and a default
//!    implementation (`DefaultImprintHttpHandlers`). These are reachable
//!    from MCP, the upcoming CLI, and Python (via PyO3) without going
//!    through HTTP.
//!
//! UniFFI bindings ship in Phase 3 — this crate is intentionally pure Rust.

pub mod app_service;
pub mod backend;
pub mod blob_store;
pub mod error;
pub mod handlers;
pub mod manuscript_service;
pub mod search;
pub mod sections;
pub mod text_service;
pub mod throughline;
pub mod throughline_service;

pub use backend::{has_custom_backend, register_backend, ImprintBackend};
pub use manuscript_service::{
    DefaultImprintManuscriptService, ImprintManuscriptService, SearchHitDto,
};

pub use blob_store::{BlobStore, LARGE_BODY_THRESHOLD};
pub use error::ServiceError;
pub use handlers::{
    compile_typst_dispatch, extract_citation_usages, extract_outline, search_text_plain,
    CitationUsage, CompileOptions, CompileResult, DefaultImprintHttpHandlers, DocumentSummary,
    ExportFormat, ImprintHttpHandlers, Outline, OutlineEntry, PageSize, ReplaceResult, TextMatch,
};
pub use search::{ManuscriptSearchIndex, SearchHit};
pub use sections::{SectionMetadata, SectionRecord, SectionStore, SECTION_SCHEMA_REF};
pub use text_service::{DefaultImprintTextService, ImprintTextService};
pub use throughline::{
    derive_anchor_states, derive_coverage, extract_paragraphs, AnchorAssessment, AnchorEntry,
    AnchorMap, ThroughlineParagraph, ThroughlineRecord, ThroughlineStore,
    THROUGHLINE_ANCHORS_FILENAME, THROUGHLINE_SCHEMA_REF, THROUGHLINE_SOURCE_FILENAME,
};
pub use throughline_service::{
    AnchorStateDto, CoverageDto, DefaultImprintThroughlineService, ImprintThroughlineService,
    ThroughlineInfoDto,
};

/// Convenience constructor: open a `SectionStore` + an in-memory tantivy
/// `ManuscriptSearchIndex` rooted at `workspace_root` and rebuild the index
/// from the existing sections.
///
/// Returns a `DefaultImprintHttpHandlers` ready to dispatch HTTP/MCP/CLI
/// requests.
pub fn open(workspace_root: &std::path::Path) -> Result<ManuscriptService, ServiceError> {
    let sections = std::sync::Arc::new(SectionStore::open(workspace_root)?);
    let search_index = std::sync::Arc::new(ManuscriptSearchIndex::in_memory()?);
    let _ = search_index.rebuild_from(&sections)?;
    let handlers = DefaultImprintHttpHandlers::new(sections.clone(), search_index.clone());
    Ok(ManuscriptService {
        sections,
        search_index,
        handlers,
    })
}

/// Top-level service façade. Holds the (Arc) section store, the
/// (Arc) search index, and the default handler implementation. Cheap to clone.
#[derive(Clone)]
pub struct ManuscriptService {
    pub sections: std::sync::Arc<SectionStore>,
    pub search_index: std::sync::Arc<ManuscriptSearchIndex>,
    pub handlers: DefaultImprintHttpHandlers,
}
