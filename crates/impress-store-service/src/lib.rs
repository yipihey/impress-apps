//! Store-generic `#[impress_service]` traits (ADR-0022 WP G1).
//!
//! Three services live here, and they have one thing in common that decides
//! where they belong: **they know nothing about any app**. They open the
//! shared `impress.sqlite` directly, so they answer with every app closed, and
//! they are therefore never withheld by `impress-mcp`'s reachability gate the
//! way `imbib-app-service` or `implore-service` are.
//!
//! * [`CollectionService`] — the agent-facing twin of the collection kernel
//!   (`impress_core::collection_ops`), mirroring
//!   `impress_store_ffi::SharedStore::collection_*` verb for verb so Swift,
//!   the CLI and an agent share one vocabulary.
//! * [`TriageService`] — star / flag / tag / status over any item, over
//!   `impress_core::triage_ops`.
//! * [`StoreQueryService`] — the mixed-kind reads: grouped global search
//!   (D6, `impress_core::search_ops`), cross-kind relations (D8,
//!   `impress_core::related_ops`), and the generic get/browse pair (G6) that
//!   lets an agent open and page through records of any kind.
//! * [`DocsImportService`] — a directory of markdown files becomes a named
//!   manuscript collection, idempotently (deterministic UUIDv5 ids from the
//!   source path), plus the companion verb that clears out the empty
//!   placeholder shells such an import is meant to replace.
//!
//! [`browse`] is the odd one out: plain functions, not a service. It assembles
//! the store overviews that `impress-mcp` serves as MCP *resources*
//! (`impress://store/schemas`, `impress://store/collections`) — reads over the
//! same store the tools use, in a shape a client fetches rather than calls.
//!
//! ADR-0022 D5's rule is that every GUI verb gets a Rust service twin and
//! *only* service-backed ops are exposed. These are the collection and triage
//! halves of that; `docs/chassis-capability-matrix.md` § "MCP surface" records
//! which matrix cells they automate.

pub mod browse;
pub mod collection_service;
pub mod docs_import_service;
pub mod figure_detection;
pub mod query_service;
pub mod source_assets;
pub mod source_service;
pub mod store;
pub mod triage_service;

/// ADR-0023's watched-folder kernel, at the address W0 gave it.
///
/// The module itself moved to [`impress_core::watched_folder_ops`] in W2, when
/// `impress-store-ffi` became its second consumer and the choice was between
/// one kernel in `impress-core` (the shape `collection_ops` already has) and an
/// FFI shim that depends on the MCP/CLI service crate. Every path W0 wrote
/// still resolves; see the kernel's module docs for the full reasoning.
pub use impress_core::watched_folder_ops as watched_folder;

#[cfg(test)]
mod test_support;

pub use browse::{
    collection_overview, schema_overview, BindingTree, CollectionNode, CollectionsOverview,
    SchemaOverview, SchemaRow,
};
pub use collection_service::{
    binding_for, BindingMigrationDto, CollectionListResult, CollectionMutationResult,
    CollectionResult, CollectionRowDto, CollectionService, DefaultCollectionService,
    KindScopeCountDto, LegacyCountDto, MemberCountsResult, MigrationReportResult,
    MigrationStatusResult, RollbackCountDto, RollbackReportResult, BINDING_NAMES,
};
pub use docs_import_service::{
    document_id, document_key, glob_match, title_from_markdown, DefaultDocsImportService,
    DiscoveredImportResult, DocsImportResult, DocsImportService, EmptyManuscriptDto,
    ImportedDocDto, ProducedRowsResult, PruneResult, SkippedDocDto, WatchedFileListResult,
    WatchedFolderListResult, WatchedFolderRemovalResult, WatchedFolderResult, WatchedScanResult,
    DOCS_IMPORT_NAMESPACE, MARKDOWN_EXTENSIONS, MARKDOWN_FORMAT,
};
pub use query_service::{
    DefaultStoreQueryService, ItemEnvelopeDto, ItemListResult, ItemResult, RelatedItemDto,
    RelatedResult, SearchHitDto, SearchResult, StoreQueryService, DEFAULT_LIST_LIMIT,
    MAX_LIST_LIMIT, MAX_PAYLOAD_BYTES,
};
pub use source_assets::{
    default_source_asset_root, install_source_pdf, set_source_asset_root, set_source_cache_root,
    source_asset_root, source_cache_root, source_pdf_path,
};
pub use source_service::{
    ContentChunkInput, ContentChunkSearchHit, ContentChunkSearchResult, DefaultSourceService,
    EvidenceAvailability, ExtractedTextRegionInput, ExtractionRunInput, FigureEvidenceSummary,
    FigureImageMetadata, FigureImageResult, FigureRegionInput, FigureRegionProvenanceInput,
    FigureRegionStatusInput, NormalizedRectInput, PageImageMetadata, PageImageResult, PixelRect,
    SourceCitationInput, SourceLocatorInput, SourceRecordResult, SourceService,
};
pub use store::{default_store_path, install_store, set_store_path, store_instance, store_path};
pub use triage_service::{DefaultTriageService, TriageResult, TriageService};
pub use watched_folder::{
    watched_file_id, watched_file_key, watched_folder_id, watched_folder_key, DiscoveredFileInput,
    DiscoveredFileOutcome, SkippedFile, WatchedFileDto, WatchedFolderDto, DEFAULT_FILE_LIST_LIMIT,
    MAX_DISCOVERED_FILES_PER_CALL, MAX_DISCOVERY_BATCH, MAX_FILE_LIST_LIMIT,
    WATCHED_FILE_NAMESPACE, WATCHED_FOLDER_NAMESPACE,
};

#[cfg(test)]
mod inventory_tests {
    use impress_service_core::McpToolDescriptor;

    /// Every method of every trait here must reach the MCP inventory — that is
    /// the entire point of the crate, and a missing `#[impress_method]` is
    /// otherwise invisible until an agent cannot find the tool.
    #[test]
    fn both_services_register_every_tool() {
        let names: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        for expected in [
            "collection-service_tree",
            "collection-service_create",
            "collection-service_rename",
            "collection-service_reparent",
            "collection-service_reorder",
            "collection-service_delete",
            "collection-service_add-members",
            "collection-service_remove-members",
            "collection-service_member-counts",
            // ADR-0022 WP G7: the deliberate, human-invoked convergence trio.
            "collection-service_migration-status",
            "collection-service_migrate",
            "collection-service_rollback",
            "triage-service_set-starred",
            "triage-service_set-flag",
            "triage-service_add-tag",
            "triage-service_remove-tag",
            "triage-service_set-status",
            "store-query-service_search-all",
            "store-query-service_related-items",
            "store-query-service_get-item",
            "store-query-service_list-items",
            "source-service_put-citation",
            "source-service_get-citation",
            "source-service_put-extraction-run",
            "source-service_put-content-chunk",
            "source-service_put-figure-region",
            "source-service_get-content-chunk",
            "source-service_search-content-chunks",
            "source-service_get-page-image",
            "source-service_get-figure-image",
            // Markdown-directory → manuscript-collection import (repeatable).
            "docs-import-service_import-directory",
            "docs-import-service_prune-empty-manuscripts",
            // ADR-0023 watched folders. D5 puts these on MCP deliberately:
            // "an agent can say 'watch this directory' too".
            "docs-import-service_add-watched-folder",
            "docs-import-service_list-watched-folders",
            "docs-import-service_update-watched-folder",
            "docs-import-service_remove-watched-folder",
            "docs-import-service_import-discovered",
            "docs-import-service_finish-watched-scan",
            "docs-import-service_record-produced-rows",
            "docs-import-service_list-watched-files",
        ] {
            assert!(
                names.contains(&expected),
                "{expected} missing from the inventory; have: {names:?}"
            );
        }
    }

    /// Tools that legitimately take NO arguments, so their generated schema is
    /// a bare `{"type": "object"}` with no `properties` key. Kept as an
    /// explicit list rather than a relaxed assertion: a tool losing its
    /// arguments to a refactor should still fail this test loudly.
    const NO_ARGUMENT_TOOLS: [&str; 2] = [
        "collection-service_migration-status",
        "collection-service_rollback",
    ];

    /// Descriptions come from the trait's doc comments. A tool that ships
    /// "Invoke Service.method" is a tool the model will misuse.
    #[test]
    fn descriptions_are_real() {
        for d in McpToolDescriptor::iter() {
            assert!(
                !d.description.starts_with("Invoke "),
                "{} has a placeholder description",
                d.name
            );
            let schema = (d.input_schema)();
            assert_eq!(
                schema.get("type").and_then(|t| t.as_str()),
                Some("object"),
                "{} has no object input schema",
                d.name
            );
            assert!(
                schema.get("properties").is_some() || NO_ARGUMENT_TOOLS.contains(&d.name),
                "{} has no input schema properties",
                d.name
            );
        }
    }
}
