//! `ImbibSourcesService` — imbib's two verbs over the online databases,
//! `imbib-sources-service_{search-sources, resolve-citation}` (source
//! convention S6). They used to be `imbib-app-service` methods that forwarded
//! to the running Swift app; that namespace is app-gated in koine's
//! reachability table (`APP_GATED`: its default implementations refuse), so
//! verbs that now run in Rust with the app closed need a namespace of their
//! own. The implementations are [`crate::sources`]; nothing here reaches the
//! app except `download_pdfs`, which asks it for a PDF after an import and
//! does nothing when it is closed.

use impress_service_core::async_trait;
#[allow(unused_imports)]
use impress_service_macros::impress_method;
use impress_service_macros::{impress_service, impress_service_impl};

pub use crate::app_service::{CitationInput, CitationResolution, ExternalPaper};

/// One registered source and the state of what it needs (source convention
/// S-D1: the explain record's `secrets` and etiquette, against the
/// installed secret source).
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct SourceStatus {
    /// The source id (`ads`, `arxiv`, …).
    pub id: String,
    /// Its display name.
    pub name: String,
    /// `api-key` (the record names a secret the source cannot work
    /// without), `api-key-optional` (a key that only raises its limits:
    /// Crossref Plus, NCBI), `email-optional` (a polite pool wants a
    /// contact) or `none`.
    pub requirement: String,
    /// `valid` | `missing` (every required secret present, or not);
    /// `optional-valid` | `optional-missing` (an optional key or the
    /// contact); `not-required`.
    pub status: String,
    /// The koine secret names the source declares.
    #[serde(default)]
    pub secrets: Vec<String>,
    /// Those of them the installed secret source holds.
    #[serde(default)]
    pub secrets_present: Vec<String>,
    /// Which layer answers for the first present secret: `app` (pushed from
    /// the keychain at launch), `env` (`KOINE_SECRET_*`) or `keychain`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub secret_source: Option<String>,
    /// Whether the source's etiquette asks for a contact (polite pool).
    pub wants_contact: bool,
    /// Whether a contact is set for the process.
    pub contact_set: bool,
    /// Where to register for a key.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub registration_url: Option<String>,
    /// The operations the record declares (`search`, `fetch`, `related`, …).
    #[serde(default)]
    pub operations: Vec<String>,
}

#[impress_service]
pub trait ImbibSourcesService: Send + Sync + 'static {
    /// Search external academic sources — ADS, arXiv, Crossref, OpenAlex,
    /// PubMed, Web of Science, SciX — for papers NOT yet in the library, with
    /// the app open or closed (the adapters are koine's `source-service`).
    /// This is how you find new work; to search papers already saved use the
    /// library search tools instead. Results are candidates, each with its
    /// `ids` and `provenance`: import them (`imbib-library-service_import-work`
    /// or `import-identifiers`) before citing or tagging. `query` is words,
    /// an identifier, or an ADS-native string (`author:"Abel" year:2002`);
    /// `sources` is a comma-separated subset (e.g. "arxiv,ads"); empty means
    /// every source that covers the query. Rows from different sources that
    /// share an identifier are one row. `sort` is `year`, `cited_by` or
    /// `relevance` (an arXiv `cat:` feed defaults to `year`: newest first);
    /// omit it to keep the first source's order. Make ONE broad call rather
    /// than several narrow ones.
    #[impress_method(safety = external, effects(reach = [network]))]
    #[impress_example(
        name = "isolated-search-sources",
        args = r##"{"query":"spectral line formation","sources":"arxiv","limit":5}"##,
        tier = "b"
    )]
    async fn search_sources(
        &self,
        query: String,
        sources: Option<String>,
        limit: u32,
        sort: Option<String>,
    ) -> Vec<ExternalPaper>;

    /// Every registered online source with the state of what it needs:
    /// which secrets its explain record names and which are present (and
    /// from where: the app's keychain push, `KOINE_SECRET_*`, or the
    /// keychain itself), whether its polite pool wants a contact and
    /// whether one is set, and where to register for a key. No network: it
    /// reads the records and the installed secret source. This is what
    /// imbib's Settings > Sources shows and what the search form lists.
    #[impress_method(safety = read_only, effects(reach = []))]
    #[impress_example(name = "inventory", args = r#"{}"#)]
    async fn source_status(&self) -> Vec<SourceStatus>;

    /// Resolve free text, BibTeX, or structured citation fields through the
    /// scored cascade (identifier → the library → the online sources), with
    /// the app open or closed. An accepted match not yet in the library is
    /// imported with its provenance and returned as `paper` (`via`:
    /// `local-identifier`, `local-text`, `imported-identifier`, `duplicate`,
    /// `search-high-confidence`); below threshold the scored `candidates` come
    /// back, each with `confidence` and the scorer's `evidence`
    /// (`search-candidates`), or `not-found` with a `reason`. `download_pdfs`
    /// asks the running app for the PDF after an import and does nothing when
    /// it is closed. `preview` (the smart-search paste) returns an accepted
    /// remote hit as the single candidate (`external-identifier-preview`,
    /// `search-high-confidence-preview`) and writes nothing.
    #[impress_method(safety = external, effects(reads = ["imbib/bibliography-entry", "imbib/library", "imbib/dismissed-paper"], writes = ["imbib/bibliography-entry"], reach = [network, app("imbib")]))]
    #[impress_example(
        name = "host-resolve-local-citation",
        tier = "b",
        args = r#"{"query":"{{state.cite_key}}","download_pdfs":false}"#
    )]
    async fn resolve_citation(
        &self,
        query: Option<String>,
        bibtex: Option<String>,
        citation: Option<CitationInput>,
        library_id: Option<String>,
        download_pdfs: bool,
        preview: Option<bool>,
    ) -> CitationResolution;
}

#[derive(Default, Clone, Copy)]
pub struct DefaultImbibSourcesService;

#[async_trait::async_trait]
impl ImbibSourcesService for DefaultImbibSourcesService {
    async fn search_sources(
        &self,
        query: String,
        sources: Option<String>,
        limit: u32,
        sort: Option<String>,
    ) -> Vec<ExternalPaper> {
        crate::sources::search_sources(query, sources, limit, sort).await
    }

    async fn source_status(&self) -> Vec<SourceStatus> {
        crate::sources::source_status()
    }

    async fn resolve_citation(
        &self,
        query: Option<String>,
        bibtex: Option<String>,
        citation: Option<CitationInput>,
        library_id: Option<String>,
        download_pdfs: bool,
        preview: Option<bool>,
    ) -> CitationResolution {
        crate::sources::resolve_citation(
            query,
            bibtex,
            citation,
            library_id,
            download_pdfs,
            preview.unwrap_or(false),
        )
        .await
    }
}

impress_service_impl! {
    service = ImbibSourcesService,
    safety = external,
    since = "0.1.0",
    effects = {
        reads: [],
        writes: [],
        reach: [network],
    },
    impl = DefaultImbibSourcesService,
    instance = || DefaultImbibSourcesService,
    methods = [
        search_sources(
            /// Search text sent to the selected academic sources.
            query: String,
            /// Comma-separated source IDs; omit to use configured sources.
            sources: Option<String>,
            /// Maximum number of results to return.
            limit: u32,
            /// `year`, `cited_by` or `relevance`; omit for the source's order (an arXiv `cat:` feed sorts by year).
            sort: Option<String>
        ) -> Vec<ExternalPaper>,
        source_status() -> Vec<SourceStatus>,
        resolve_citation(
            /// Free-text citation query (kept private because it may contain manuscript text).
            #[impress_private] query: Option<String>,
            /// BibTeX fragment, kept private because it may contain unpublished citation data.
            #[impress_private] bibtex: Option<String>,
            /// Structured fields; kept private for the same reason as the raw citation.
            #[impress_private] citation: Option<CitationInput>,
            /// Destination library UUID; omit to use the default library.
            library_id: Option<String>,
            /// Whether to fetch a PDF after automatic import.
            download_pdfs: bool,
            /// Preview only: an accepted remote match comes back as a candidate and nothing is imported.
            preview: Option<bool>
        ) -> CitationResolution,
    ],
}

#[cfg(test)]
mod tests {
    use impress_service_core::McpToolDescriptor;

    #[test]
    fn resolve_citation_marks_citation_material_private_in_generated_schema() {
        let tool = McpToolDescriptor::iter()
            .find(|tool| tool.name == "imbib-sources-service_resolve-citation")
            .expect("resolve-citation is registered");
        let schema = (tool.input_schema)();
        for field in ["query", "bibtex", "citation"] {
            assert_eq!(schema["properties"][field]["x-private"], true, "{field}");
        }
    }

    /// Not app-gated: the point of the move. The app-service namespace
    /// stays gated for the verbs that are app state.
    #[test]
    fn the_sources_namespace_is_not_app_gated() {
        use impress_service_core::pipeline::reachability::gated_app;
        assert_eq!(gated_app("imbib-sources-service_search-sources"), None);
        assert_eq!(gated_app("imbib-app-service_status"), Some("imbib"));
    }
}
