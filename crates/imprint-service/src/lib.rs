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
/// A manuscript as a project (ADR-0030 D12): tree, files, targets, graph —
/// store-direct, so the CLI and MCP work with the app closed.
pub mod project_bib;
pub mod project_service;
pub mod search;
pub mod sections;
pub mod text_service;
pub mod throughline;
pub mod throughline_service;

pub use backend::{clear_backend, has_custom_backend, register_backend, ImprintBackend};
pub use manuscript_service::{
    DefaultImprintManuscriptService, ImprintManuscriptService, PresentationMutationDto,
    PresentationOutlineDto, PresentationSlideDto, SearchHitDto,
};

pub use blob_store::{BlobStore, LARGE_BODY_THRESHOLD};
pub use error::ServiceError;
pub use handlers::{
    compile_typst_dispatch, extract_citation_usages, extract_outline, search_text_plain,
    CitationUsage, CompileOptions, CompileResult, DefaultImprintHttpHandlers, DocumentSummary,
    ExportFormat, ImprintHttpHandlers, Outline, OutlineEntry, PageSize, ReplaceResult, TextMatch,
};
pub use project_bib::StoreBibliographyResolver;
pub use project_service::{
    graph_record, tree_from_snapshot, DefaultImprintProjectService, ImprintProjectService,
    ProjectBibliographyRecord, ProjectBuildOutputRecord, ProjectBuildOutputResult,
    ProjectBuildRecord, ProjectBuildResult, ProjectBuildsRecord, ProjectCitationRecord,
    ProjectCitationsRecord, ProjectCompileRecord, ProjectDiagnosticRecord, ProjectEdgeRecord,
    ProjectExportRecord, ProjectFileContentRecord, ProjectFileRecord, ProjectFileResult,
    ProjectGraphRecord, ProjectImportRecord, ProjectMutationResult, ProjectOutlineRecord,
    ProjectSectionRecord, ProjectSnapshotRecord, ProjectStepRecord, ProjectStepReportRecord,
    ProjectTargetRecord, ProjectTreeRecord, ProjectUnresolvedRecord,
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

#[cfg(test)]
mod inventory_tests {
    use impress_service_core::{CliSubcommand, McpToolDescriptor};

    /// Every project verb reaches the MCP inventory — the whole point of
    /// `#[impress_service]` is that one definition IS the tool, the CLI
    /// subcommand and impel's agent tool (root CLAUDE.md).
    #[test]
    fn project_service_methods_registered_in_mcp_inventory() {
        let names: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        for expected in [
            "imprint-project-service_project-tree",
            "imprint-project-service_project-file",
            "imprint-project-service_project-put-file",
            "imprint-project-service_project-delete-file",
            "imprint-project-service_project-move-file",
            "imprint-project-service_project-set-entry",
            "imprint-project-service_project-set-targets",
            "imprint-project-service_project-set-bibliography",
            "imprint-project-service_project-set-figure-build",
            "imprint-project-service_project-graph",
            "imprint-project-service_project-outline",
            "imprint-project-service_project-citations",
            "imprint-project-service_project-compile",
            "imprint-project-service_project-import-directory",
            "imprint-project-service_project-export",
            "imprint-project-service_project-materialize",
            "imprint-project-service_project-snapshot",
            "imprint-project-service_project-build",
            "imprint-project-service_project-builds",
            "imprint-project-service_project-build-output",
        ] {
            assert!(
                names.contains(&expected),
                "missing {expected}; have {names:?}"
            );
        }
    }

    #[test]
    fn project_service_methods_registered_in_cli_inventory() {
        let names: Vec<&str> = CliSubcommand::iter().map(|c| c.name).collect();
        for expected in [
            "project-tree",
            "project-file",
            "project-put-file",
            "project-delete-file",
            "project-move-file",
            "project-set-entry",
            "project-set-targets",
            "project-set-bibliography",
            "project-set-figure-build",
            "project-graph",
            "project-outline",
            "project-citations",
            "project-compile",
            "project-import-directory",
            "project-export",
            "project-materialize",
            "project-snapshot",
            "project-build",
            "project-builds",
            "project-build-output",
        ] {
            assert!(names.contains(&expected), "missing {expected}");
        }
    }
}
