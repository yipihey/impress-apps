//! Service-trait facade over `imbib-core` exposed via `#[impress_service]`.
//!
//! Each module defines one trait + impl + `impress_service_impl!`
//! registration; the inventory entries fan out to MCP / CLI / future Python
//! and Swift bindings without per-binding boilerplate.
//!
//! Process-wide `Arc<ImbibStore>` lives in `store_singleton` and is shared
//! across every service.

use impress_service_core::async_trait;
// `impress_method` is referenced as a path-only attribute on trait methods;
// `#[impress_service]` strips the attribute, so the symbol is structurally
// "unused" — keep it imported because Rust still requires the path to
// resolve when the macro expands.
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

// ---- Stateless utilities (the original Phase 3 service) ------------------

#[impress_service]
pub trait ImbibTextService: Send + Sync + 'static {
    /// Decode LaTeX-encoded text into Unicode (e.g. `\'{e}` → `é`).
    #[impress_method]
    async fn decode_latex(&self, input: String) -> String;

    /// Expand a BibTeX journal-name macro to its full form (e.g.
    /// `ApJ` → `Astrophysical Journal`).
    #[impress_method]
    async fn expand_journal_macro(&self, value: String) -> String;

    /// Generate a BibTeX cite key in the `{LastName}{Year}{TitleWord}`
    /// convention.
    #[impress_method]
    async fn generate_cite_key(
        &self,
        author: Option<String>,
        year: Option<String>,
        title: Option<String>,
    ) -> String;

    /// Normalize a single tag segment ("Dark Energy" → "dark-energy").
    #[impress_method]
    async fn normalize_tag_segment(&self, segment: String) -> String;

    /// Normalize a hierarchical tag path.
    #[impress_method]
    async fn normalize_tag_path(&self, path: String) -> String;
}

#[derive(Default, Clone, Copy)]
pub struct DefaultImbibTextService;

#[async_trait::async_trait]
impl ImbibTextService for DefaultImbibTextService {
    async fn decode_latex(&self, input: String) -> String {
        imbib_core::bibtex::decode_latex(input)
    }
    async fn expand_journal_macro(&self, value: String) -> String {
        imbib_core::bibtex::expand_journal_macro(value)
    }
    async fn generate_cite_key(
        &self,
        author: Option<String>,
        year: Option<String>,
        title: Option<String>,
    ) -> String {
        imbib_core::identifiers::generate_cite_key(author, year, title)
    }
    async fn normalize_tag_segment(&self, segment: String) -> String {
        impress_tags::normalize_tag_segment(&segment)
    }
    async fn normalize_tag_path(&self, path: String) -> String {
        impress_tags::normalize_tag_path(&path)
    }
}

impress_service_impl! {
    service = ImbibTextService,
    impl = DefaultImbibTextService,
    instance = || DefaultImbibTextService,
    methods = [
        /// Decode LaTeX-encoded text into Unicode.
        decode_latex(input: String) -> String,
        /// Expand a BibTeX journal-name macro.
        expand_journal_macro(value: String) -> String,
        /// Generate a BibTeX cite key.
        generate_cite_key(
            author: Option<String>,
            year: Option<String>,
            title: Option<String>
        ) -> String,
        /// Normalize a single tag segment.
        normalize_tag_segment(segment: String) -> String,
        /// Normalize a hierarchical tag path.
        normalize_tag_path(path: String) -> String,
    ],
}

// ---- Stateful services (Phase 3.5+) --------------------------------------

pub mod annotations_service;
pub mod app_service;
pub mod artifacts_service;
pub mod backup_service;
pub mod library_service;
pub mod manuscripts_service;
pub mod scix_service;
pub mod search_service;
pub mod store_singleton;
pub mod tags_service;
pub mod undo_service;

// Pluggable backend registry (HTTP / SQLite).
pub mod backend;
pub use backend::{has_custom_backend, register_backend, ImbibBackend};

pub use annotations_service::{
    AnnotationRecord, CommentRecord, DefaultImbibAnnotationsService, ImbibAnnotationsService,
};
pub use artifacts_service::{
    ArtifactRecord, ArtifactRelationRecord, DefaultImbibArtifactsService, ImbibArtifactsService,
};
pub use library_service::{
    init_imbib_library_service, AuthorRecord, CollectionRecord, DefaultImbibLibraryService,
    DismissedPaperRecord, ImbibLibraryService, ImportSummary, LibraryRecord, LinkedFileRecord,
    MutationResult, MutedItemRecord, PaperImport, PublicationDetailRecord, PublicationSummary,
};
pub use scix_service::{DefaultImbibScixService, ImbibScixService, SciXLibraryRecord};
pub use search_service::{DefaultImbibSearchService, ImbibSearchService, SmartSearchRecord};
pub use store_singleton::init_imbib_store;
pub use tags_service::{DefaultImbibTagsService, ImbibTagsService, TagRecord, TagWithCount};
pub use undo_service::{DefaultImbibUndoService, ImbibUndoService, UndoGroupRecord};

#[cfg(test)]
mod tests {
    use impress_service_core::{CliSubcommand, McpToolDescriptor};

    #[test]
    fn text_service_methods_registered_in_mcp_inventory() {
        let names: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        for expected in [
            "imbib-text-service_decode-latex",
            "imbib-text-service_expand-journal-macro",
            "imbib-text-service_generate-cite-key",
            "imbib-text-service_normalize-tag-segment",
            "imbib-text-service_normalize-tag-path",
        ] {
            assert!(names.contains(&expected), "missing {expected}");
        }
    }

    #[test]
    fn text_service_methods_registered_in_cli_inventory() {
        let names: Vec<&str> = CliSubcommand::iter().map(|c| c.name).collect();
        for expected in [
            "decode-latex",
            "expand-journal-macro",
            "generate-cite-key",
            "normalize-tag-segment",
            "normalize-tag-path",
        ] {
            assert!(names.contains(&expected), "missing {expected}");
        }
    }

    #[test]
    fn decode_latex_round_trips_through_inventory() {
        use impress_service_core::runtime;
        use impress_service_core::serde_json::json;

        let tool = McpToolDescriptor::iter()
            .find(|d| d.name == "imbib-text-service_decode-latex")
            .expect("decode-latex tool");
        let result = runtime::block_on((tool.handler)(json!({ "input": "Caf\\'{e}" })))
            .expect("handler succeeded");
        assert_eq!(result.as_str(), Some("Café"));
    }

    #[test]
    fn six_services_all_registered() {
        let names: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        // At least one method per service prefix should be present.
        for prefix in [
            "imbib-text-service_",
            "imbib-library-service_",
            "imbib-tags-service_",
            "imbib-search-service_",
            "imbib-undo-service_",
            "imbib-annotations-service_",
            "imbib-artifacts-service_",
            "imbib-scix-service_",
        ] {
            assert!(
                names.iter().any(|n| n.starts_with(prefix)),
                "no methods registered for {prefix}"
            );
        }
    }
}
