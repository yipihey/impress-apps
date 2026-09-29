//! `ImbibAppService` — capabilities that live in the running imbib app rather
//! than in the store.
//!
//! Every other `imbib-service` trait models the SQLite store, so its default
//! backend can answer with imbib closed. These cannot:
//!
//! * **Source search** needs the network and the user's API credentials
//!   (ADS, arXiv, Crossref), which live in the app's keychain.
//! * **PDF download** needs the proxy settings and the attachment layout.
//! * **Sync** is a CloudKit engine owned by the app process; a second writer
//!   nudging it from outside would fight its lease.
//! * **Logs and status** describe a running process. There is nothing to
//!   report when it is not running.
//! * **Recent activity** is the user's own viewing trail, recorded by the UI.
//!   Automated ingest deliberately never writes it, which is exactly what makes
//!   it "what was I just reading?" rather than "what arrived?".
//!
//! So the default backend refuses each of these and says to open imbib, the
//! same shape `backup_service`'s restore uses. The native callbacks installed
//! by `imbib-verbs-ffi` do the real work. Refusing loudly beats returning an
//! empty list that reads like "you have no papers".
//!
//! # The mutation tail
//!
//! This service also carries a handful of writes — notes, the deletes the
//! domain services never grew, artifact tagging, cross-library moves — for one
//! reason: the running app has to observe them. A direct store write leaves
//! imbib's in-memory caches describing rows that changed underneath it, the
//! same hazard that keeps backup's restore out of the store path. They would
//! sit more naturally on the library/annotations/search/artifacts services;
//! moving them there means giving each a store-backed default that ALSO
//! notifies the app, which is a larger change than this migration needs.

use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

/// One hit from an external academic source, before it is imported.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ExternalPaper {
    pub title: String,
    /// Importable identifier selected by the same source-priority rule as the
    /// HTTP candidate (`doi`, arXiv ID, bibcode, then title fallback).
    #[serde(default, alias = "bestIdentifier", alias = "best_identifier")]
    pub identifier: Option<String>,
    #[serde(default)]
    pub authors: Vec<String>,
    #[serde(default)]
    pub year: Option<i64>,
    #[serde(default)]
    pub venue: Option<String>,
    #[serde(default)]
    pub doi: Option<String>,
    #[serde(default, alias = "arxivID", alias = "arxiv_id")]
    pub arxiv_id: Option<String>,
    #[serde(default)]
    pub bibcode: Option<String>,
    #[serde(default)]
    pub abstract_text: Option<String>,
    /// Which source returned it (`ads`, `arxiv`, `crossref`, …).
    #[serde(default, alias = "sourceID", alias = "source_id")]
    pub source: Option<String>,
}

/// Structured bibliographic fields accepted by `/api/papers/resolve`.
/// `raw_bibtex`, `free_text`, and `preferred_database` serialize using the
/// legacy endpoint's camel-case member names inside this nested object.
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CitationInput {
    /// A list of authors, or the comma/semicolon/newline separated string the
    /// HTTP handler also accepts.
    #[serde(default, deserialize_with = "deserialize_citation_authors")]
    #[schemars(with = "CitationAuthorsInput")]
    pub authors: Vec<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub year: Option<i64>,
    #[serde(default)]
    pub journal: Option<String>,
    #[serde(default)]
    pub volume: Option<String>,
    #[serde(default)]
    pub pages: Option<String>,
    #[serde(default)]
    pub doi: Option<String>,
    #[serde(default)]
    pub arxiv: Option<String>,
    #[serde(default)]
    pub bibcode: Option<String>,
    #[serde(default, alias = "raw_bibtex", alias = "bibtex")]
    pub raw_bibtex: Option<String>,
    #[serde(default, alias = "free_text")]
    pub free_text: Option<String>,
    #[serde(default, alias = "preferred_database")]
    pub preferred_database: Option<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
#[serde(untagged)]
enum CitationAuthorsInput {
    List(Vec<String>),
    Text(String),
    Empty(()),
}

fn deserialize_citation_authors<'de, D>(deserializer: D) -> Result<Vec<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    match CitationAuthorsInput::deserialize(deserializer)? {
        CitationAuthorsInput::List(values) => Ok(values),
        CitationAuthorsInput::Text(value) => Ok(value
            .split([',', ';', '&', '\n'])
            .map(str::trim)
            .filter(|author| !author.is_empty())
            .map(str::to_owned)
            .collect()),
        CitationAuthorsInput::Empty(()) => Ok(Vec::new()),
    }
}

/// Shape returned by `/api/papers/resolve`. Paper and candidate dictionaries
/// remain open JSON because the HTTP route returns different paper/candidate
/// shapes for local, imported, and external branches.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CitationResolution {
    pub via: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub paper: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidates: Option<Vec<serde_json::Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

impl CitationResolution {
    pub fn unavailable(reason: impl Into<String>) -> Self {
        Self {
            via: "unavailable".into(),
            paper: None,
            candidates: None,
            reason: Some(reason.into()),
        }
    }
}

/// A paper the user themselves touched, with what they did and when.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ActivityEntry {
    pub id: String,
    #[serde(default, alias = "citeKey")]
    pub cite_key: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    /// `viewed` or `added`.
    #[serde(default, alias = "activityKind")]
    pub activity_kind: Option<String>,
    /// Epoch milliseconds.
    #[serde(default, alias = "activityAt")]
    pub activity_at: Option<i64>,
}

/// One line from the app's in-memory log store.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LogEntry {
    #[serde(default)]
    pub timestamp: Option<String>,
    #[serde(default)]
    pub level: Option<String>,
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub message: String,
}

/// Whether the sync engine accepted an immediate push+pull.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SyncNudgeResult {
    pub accepted: bool,
    /// Why not, when `accepted` is false. A refusal is a normal answer.
    #[serde(default)]
    pub reason: Option<String>,
}

/// Free-form app state. Deliberately a JSON string: `/api/status` and
/// `/api/sync/status` grow fields over time, and re-declaring their shape here
/// would be one more thing to keep in step.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct AppStatus {
    /// `true` when the app answered at all.
    pub running: bool,
    /// The endpoint's JSON body, verbatim, or an explanation when not running.
    pub detail: String,
}

/// What opening the manuscript-papers window did.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct PapersWindowResult {
    pub opened: bool,
    /// The imbib collection the window is showing.
    pub collection_id: Option<String>,
    pub collection_name: Option<String>,
    /// Cite keys the manuscript uses that imbib has no paper for.
    #[serde(default)]
    pub missing_cite_keys: Vec<String>,
    pub message: String,
}

/// Lossless result of the app-owned identifier import path. `added` retains
/// the legacy `/api/papers/add` paper dictionaries; no store-only projection
/// can reproduce the app's full PaperResult without losing fields.
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct IdentifierImportResult {
    pub added: Vec<serde_json::Value>,
    pub duplicates: Vec<String>,
    pub failed: std::collections::BTreeMap<String, String>,
}

#[impress_service]
pub trait ImbibAppService: Send + Sync + 'static {
    /// Internal bridge used by the generated library import verb. Kept out of
    /// the app-service inventory because identifier import is one public
    /// library capability, while the running app owns source lookup and PDF
    /// acquisition.
    async fn import_identifiers(
        &self,
        identifiers: Vec<String>,
        library_id: Option<String>,
        collection_id: Option<String>,
        download_pdfs: bool,
    ) -> IdentifierImportResult;

    /// Search external academic sources — ADS, arXiv, Crossref and the rest —
    /// for papers NOT yet in the library. This is how you find new work; to
    /// search papers already saved use the library search tools instead.
    /// Results are candidates: import them before citing or tagging.
    /// `sources` is a comma-separated subset (e.g. "arxiv,ads"); empty means
    /// every configured source. Make ONE broad call rather than several narrow
    /// ones.
    #[impress_method]
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
    ) -> Vec<ExternalPaper>;

    /// Resolve free text, BibTeX, or structured citation fields through the
    /// running app's existing `/api/papers/resolve` cascade. Candidate order,
    /// confidence, `via`, and reason values are preserved. The returned paper
    /// and candidate objects use the same open dictionary shape as HTTP.
    #[impress_method(safety = external, effects(reach = [app("imbib")]))]
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
    ) -> CitationResolution;

    /// What the USER was recently working on: papers they viewed or added by
    /// hand, most recent first, each carrying `activity_kind` and
    /// `activity_at`. This is imbib's "Recent" virtual library and the right
    /// opener for "what was I just reading?" / "pick up where I left off".
    /// Automated ingest is deliberately excluded — inbox feeds, smart-search
    /// refreshes and group feeds never record activity — so this really is the
    /// user's own trail. For newly ARRIVED papers regardless of who put them
    /// there, use the recent-papers query instead.
    #[impress_method]
    #[impress_example(
        name = "isolated-recent-activity",
        args = r##"{"limit":10,"parent_id":null}"##,
        tier = "b"
    )]
    async fn recent_activity(&self, limit: u32, parent_id: Option<String>) -> Vec<ActivityEntry>;

    /// Download PDFs for the given papers, honouring the user's library-proxy
    /// and source-priority settings. Returns how many were fetched. Slow: it
    /// goes out to publishers and preprint servers.
    #[impress_method]
    #[impress_example(
        name = "isolated-download-pdfs",
        args = r##"{"publication_ids":["{{fixture.publication_id}}"]}"##,
        expect = r##"1"##,
        tier = "b"
    )]
    async fn download_pdfs(&self, publication_ids: Vec<String>) -> u32;

    /// Show a manuscript's papers in imbib: a window on the manuscript's own
    /// collection — imbib's list and inspector, no sidebar — with the citation
    /// verbs pointed at that manuscript. imbib folds the papers the manuscript
    /// cites into the collection first, so the window always opens on its
    /// current set, and reports the cite keys it has no paper for.
    ///
    /// This is the surface imprint uses for choosing references; imprint no
    /// longer has a paper panel of its own.
    #[impress_method]
    #[impress_example(
        name = "isolated-open-manuscript-papers",
        args = r##"{"manuscript_id":"{{fixture.manuscript_id}}"}"##,
        expect = r##"{"opened":true}"##,
        tier = "b"
    )]
    async fn open_manuscript_papers(&self, manuscript_id: String) -> PapersWindowResult;

    /// Ask imbib's sync engine for an immediate push+pull instead of waiting
    /// for its schedule. THIS IS WHAT DELIVERS YOUR WORK TO THE USER'S OTHER
    /// DEVICES: every change made through the other tools lands in the local
    /// store first and only reaches their phone on the next pass. Call it
    /// after finishing a batch of edits, and whenever the user asks why they
    /// cannot see something yet. A refusal is a normal answer, not an error —
    /// it reports `accepted: false` with a reason (sync off, not entitled, no
    /// iCloud account, another app holds the lease).
    #[impress_method]
    #[impress_example(name = "isolated-sync-nudge", args = r##"{}"##, tier = "b")]
    async fn sync_nudge(&self) -> SyncNudgeResult;

    /// The CloudKit sync engine's real state: whether it is on, when it last
    /// pushed and pulled, and the last error if any. Use this to diagnose a
    /// refused nudge.
    #[impress_method]
    #[impress_example(
        name = "isolated-sync-status",
        args = r##"{}"##,
        expect = r##"{"running":true}"##,
        tier = "b"
    )]
    async fn sync_status(&self) -> AppStatus;

    /// Whether imbib is running, and its version, port and library counts.
    /// Cheap; a good first call when a tool has just reported the app
    /// unavailable.
    #[impress_method]
    #[impress_example(
        name = "isolated-status",
        args = r##"{}"##,
        expect = r##"{"running":true}"##,
        tier = "b"
    )]
    async fn status(&self) -> AppStatus;

    /// Recent lines from imbib's in-memory log store — the same feed its
    /// Console window shows. The way to find out what a mutation actually did.
    /// `level` is a comma-separated filter (`info,warning,error`), `category`
    /// narrows to one subsystem (e.g. `backup`, `tags`, `sync`).
    #[impress_method]
    #[impress_example(
        name = "isolated-get-logs",
        args = r##"{"limit":20,"level":"info,warning,error","category":null,"search":null}"##,
        tier = "b"
    )]
    async fn get_logs(
        &self,
        limit: u32,
        level: Option<String>,
        category: Option<String>,
        search: Option<String>,
    ) -> Vec<LogEntry>;

    // ---- Mutations the running app must observe ---------------------------

    /// A paper's notes — the user's own prose about it, not the abstract.
    #[impress_method]
    #[impress_example(
        name = "isolated-get-notes",
        args = r##"{"cite_key":"G3Native2026"}"##,
        expect = r##""Owned native note""##,
        tier = "b"
    )]
    async fn get_notes(&self, cite_key: String) -> Option<String>;

    /// Replace a paper's notes. Whole-field write: read them first if you mean
    /// to append rather than overwrite.
    #[impress_method]
    #[impress_example(
        name = "isolated-update-notes",
        args = r##"{"cite_key":"G3Native2026","notes":"Revised owned native note"}"##,
        expect = r##"true"##,
        tier = "b"
    )]
    async fn update_notes(&self, cite_key: String, notes: String) -> bool;

    /// Delete one annotation from a PDF.
    #[impress_method]
    #[impress_example(
        name = "isolated-delete-annotation",
        args = r##"{"annotation_id":"{{fixture.annotation_id}}"}"##,
        expect = r##"true"##,
        tier = "b"
    )]
    async fn delete_annotation(&self, annotation_id: String) -> bool;

    /// Delete one comment.
    #[impress_method]
    #[impress_example(
        name = "isolated-delete-comment",
        args = r##"{"comment_id":"{{fixture.comment_id}}"}"##,
        expect = r##"true"##,
        tier = "b"
    )]
    async fn delete_comment(&self, comment_id: String) -> bool;

    /// Delete a collection. The papers survive — a collection is a grouping,
    /// not a container, so removing it never removes what it held.
    #[impress_method]
    #[impress_example(
        name = "isolated-delete-collection",
        args = r##"{"collection_id":"{{fixture.collection_id}}"}"##,
        expect = r##"true"##,
        tier = "b"
    )]
    async fn delete_collection(&self, collection_id: String) -> bool;

    /// Delete saved searches by id. Returns how many went.
    #[impress_method]
    #[impress_example(
        name = "isolated-delete-smart-searches",
        args = r##"{"ids":["{{fixture.smart_search_id}}"]}"##,
        expect = r##"1"##,
        tier = "b"
    )]
    async fn delete_smart_searches(&self, ids: Vec<String>) -> u32;

    /// Replace an artifact's tags. Whole-set write, like notes.
    #[impress_method]
    #[impress_example(
        name = "isolated-tag-artifact",
        args = r##"{"artifact_id":"{{fixture.artifact_id}}","tags":["g3/native"]}"##,
        expect = r##"true"##,
        tier = "b"
    )]
    async fn tag_artifact(&self, artifact_id: String, tags: Vec<String>) -> bool;

    /// Resolve an identifier — DOI, arXiv id, bibcode — to a paper, fetching
    /// its metadata from the outside world if the library does not have it
    /// yet. Unlike the find-by-* searches, which only look locally, this one
    /// can go and get it.
    #[impress_method]
    #[impress_example(
        name = "isolated-resolve-identifier",
        args = r##"{"identifier":"10.1038/nphys1170","download_pdfs":false}"##,
        tier = "b"
    )]
    async fn resolve_identifier(&self, identifier: String, download_pdfs: bool) -> Option<String>;

    /// Add existing papers to another library. Papers can sit in several
    /// libraries at once; this adds rather than moves.
    #[impress_method]
    #[impress_example(
        name = "isolated-add-to-library",
        args = r##"{"publication_ids":["{{fixture.publication_id}}"],"library_id":"{{fixture.destination_library_id}}"}"##,
        expect = r##"1"##,
        tier = "b"
    )]
    async fn add_to_library(&self, publication_ids: Vec<String>, library_id: String) -> u32;
}

/// The store-backed default: refuses everything, because none of it exists
/// outside the running app.
#[derive(Clone, Default)]
pub struct DefaultImbibAppService;

impl DefaultImbibAppService {
    pub fn new() -> Self {
        Self
    }
}

const NOT_RUNNING: &str =
    "imbib is not running. This capability lives in the app — network search \
     credentials, the sync engine, the log store and the user's activity trail \
     are all app state, not store rows. Open imbib and try again.";

fn refuse(method: &str) {
    eprintln!("[imbib-app-service] {method}: imbib not running; refused");
}

#[async_trait::async_trait]
impl ImbibAppService for DefaultImbibAppService {
    async fn import_identifiers(
        &self,
        identifiers: Vec<String>,
        _library_id: Option<String>,
        _collection_id: Option<String>,
        _download_pdfs: bool,
    ) -> IdentifierImportResult {
        refuse("import_identifiers");
        impress_service_core::pipeline::context::report_refusal(
            impress_service_core::refusal::codes::HOST_UNAVAILABLE,
            NOT_RUNNING,
        );
        IdentifierImportResult {
            added: vec![],
            duplicates: vec![],
            failed: identifiers
                .into_iter()
                .map(|id| (id, NOT_RUNNING.into()))
                .collect(),
        }
    }

    async fn search_sources(
        &self,
        _query: String,
        _sources: Option<String>,
        _limit: u32,
    ) -> Vec<ExternalPaper> {
        refuse("search_sources");
        vec![]
    }

    async fn resolve_citation(
        &self,
        _query: Option<String>,
        _bibtex: Option<String>,
        _citation: Option<CitationInput>,
        _library_id: Option<String>,
        _download_pdfs: bool,
    ) -> CitationResolution {
        refuse("resolve_citation");
        CitationResolution::unavailable(NOT_RUNNING)
    }

    async fn recent_activity(&self, _limit: u32, _parent_id: Option<String>) -> Vec<ActivityEntry> {
        refuse("recent_activity");
        vec![]
    }

    async fn download_pdfs(&self, _publication_ids: Vec<String>) -> u32 {
        refuse("download_pdfs");
        0
    }

    async fn open_manuscript_papers(&self, _manuscript_id: String) -> PapersWindowResult {
        refuse("open_manuscript_papers");
        PapersWindowResult {
            opened: false,
            collection_id: None,
            collection_name: None,
            missing_cite_keys: Vec::new(),
            message: NOT_RUNNING.into(),
        }
    }

    async fn sync_nudge(&self) -> SyncNudgeResult {
        refuse("sync_nudge");
        SyncNudgeResult {
            accepted: false,
            reason: Some(NOT_RUNNING.into()),
        }
    }

    async fn sync_status(&self) -> AppStatus {
        refuse("sync_status");
        AppStatus {
            running: false,
            detail: NOT_RUNNING.into(),
        }
    }

    async fn status(&self) -> AppStatus {
        // Not a refusal so much as the honest answer: the question is "is imbib
        // running?" and the answer is no.
        AppStatus {
            running: false,
            detail: "imbib is not running.".into(),
        }
    }

    async fn get_logs(
        &self,
        _limit: u32,
        _level: Option<String>,
        _category: Option<String>,
        _search: Option<String>,
    ) -> Vec<LogEntry> {
        refuse("get_logs");
        vec![]
    }

    async fn get_notes(&self, _cite_key: String) -> Option<String> {
        refuse("get_notes");
        None
    }
    async fn update_notes(&self, _cite_key: String, _notes: String) -> bool {
        refuse("update_notes");
        false
    }
    async fn delete_annotation(&self, _annotation_id: String) -> bool {
        refuse("delete_annotation");
        false
    }
    async fn delete_comment(&self, _comment_id: String) -> bool {
        refuse("delete_comment");
        false
    }
    async fn delete_collection(&self, _collection_id: String) -> bool {
        refuse("delete_collection");
        false
    }
    async fn delete_smart_searches(&self, _ids: Vec<String>) -> u32 {
        refuse("delete_smart_searches");
        0
    }
    async fn tag_artifact(&self, _artifact_id: String, _tags: Vec<String>) -> bool {
        refuse("tag_artifact");
        false
    }
    async fn resolve_identifier(
        &self,
        _identifier: String,
        _download_pdfs: bool,
    ) -> Option<String> {
        refuse("resolve_identifier");
        None
    }
    async fn add_to_library(&self, _publication_ids: Vec<String>, _library_id: String) -> u32 {
        refuse("add_to_library");
        0
    }
}

impress_service_impl! {
    service = ImbibAppService,
    safety = external,
    since = "0.1.0",
    effects = {
        reads: [],
        writes: [],
        reach: [app("imbib")],
    },
    impl = DefaultImbibAppService,
    instance = crate::backend::app_service_instance,
    methods = [
        search_sources(
            /// Search text sent to the selected academic sources.
            query: String,
            /// Comma-separated source IDs; omit to use configured sources.
            sources: Option<String>,
            /// Maximum number of results to return.
            limit: u32
        ) -> Vec<ExternalPaper>,
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
            download_pdfs: bool
        ) -> CitationResolution,
        recent_activity(
            /// Maximum number of results to return.
            limit: u32,
            /// Library or collection UUID to scope activity; omit for all libraries.
            parent_id: Option<String>
        ) -> Vec<ActivityEntry>,
        download_pdfs(
            /// UUIDs of the saved bibliography entries to operate on.
            publication_ids: Vec<String>
        ) -> u32,
        open_manuscript_papers(
            /// UUID of the manuscript whose reading collection should open.
            manuscript_id: String
        ) -> PapersWindowResult,
        sync_nudge() -> SyncNudgeResult,
        sync_status() -> AppStatus,
        status() -> AppStatus,
        get_logs(
            /// Maximum number of results to return.
            limit: u32,
            /// Comma-separated log levels; omit to include every level.
            level: Option<String>,
            /// Exact log category to filter, or omit for all categories.
            category: Option<String>,
            /// Text to match in log messages, or omit for no text filter.
            search: Option<String>
        ) -> Vec<LogEntry>,
        get_notes(
            /// Unique bibliography citation key of the paper.
            cite_key: String
        ) -> Option<String>,
        update_notes(
            /// Unique bibliography citation key of the paper.
            cite_key: String,
            /// Complete replacement Markdown note text.
            #[impress_private] notes: String
        ) -> bool,
        delete_annotation(
            /// UUID of the annotation to delete.
            annotation_id: String
        ) -> bool,
        delete_comment(
            /// UUID of the comment to delete.
            comment_id: String
        ) -> bool,
        delete_collection(
            /// UUID of the collection to delete; papers remain saved.
            collection_id: String
        ) -> bool,
        delete_smart_searches(
            /// UUIDs of the smart searches to delete.
            ids: Vec<String>
        ) -> u32,
        tag_artifact(
            /// UUID of the artifact to tag.
            artifact_id: String,
            /// Hierarchical tag paths to add.
            tags: Vec<String>
        ) -> bool,
        resolve_identifier(
            /// DOI, arXiv identifier, or another supported source identifier.
            identifier: String,
            /// Whether to fetch the PDF after importing the identified paper.
            download_pdfs: bool
        ) -> Option<String>,
        add_to_library(
            /// UUIDs of the saved bibliography entries to operate on.
            publication_ids: Vec<String>,
            /// UUID of the destination library.
            library_id: String
        ) -> u32,
    ],
}

#[cfg(test)]
mod identifier_import_contract_tests {
    use super::IdentifierImportResult;
    use serde_json::json;

    #[test]
    fn identifier_import_result_keeps_the_legacy_outcome_envelope_and_full_added_rows() {
        let result: IdentifierImportResult = serde_json::from_value(json!({
            "added": [{
                "id": "paper-id",
                "citeKey": "Example2026",
                "title": "Example",
                "authors": ["Doe, Jane"],
                "bibtex": "@article{Example2026}",
                "dateAdded": "2026-09-29T00:00:00Z",
                "collectionIDs": ["collection-id"],
                "libraryIDs": ["library-id"]
            }],
            "duplicates": ["Existing2026"],
            "failed": {"invalid": "unsupported identifier"}
        }))
        .unwrap();

        assert_eq!(result.added[0]["authors"][0], "Doe, Jane");
        assert_eq!(result.added[0]["collectionIDs"][0], "collection-id");
        assert_eq!(result.added[0]["dateAdded"], "2026-09-29T00:00:00Z");
        assert_eq!(result.duplicates, vec!["Existing2026"]);
        assert_eq!(result.failed["invalid"], "unsupported identifier");

        let schema = schemars::schema_for!(IdentifierImportResult);
        let schema = serde_json::to_value(schema).unwrap();
        let fields = schema["properties"].as_object().unwrap();
        assert!(fields.contains_key("added"));
        assert!(fields.contains_key("duplicates"));
        assert!(fields.contains_key("failed"));
    }
}

#[cfg(test)]
mod citation_contract_tests {
    use super::*;
    use impress_service_core::McpToolDescriptor;
    use serde_json::json;

    #[test]
    fn citation_inputs_accept_http_author_forms_and_keep_http_member_names() {
        let input: CitationInput = serde_json::from_value(json!({
            "authors": "Ada; Charles\nGrace",
            "rawBibtex": "@article{x}",
            "freeText": "citation query",
            "preferredDatabase": "physics"
        }))
        .unwrap();
        assert_eq!(input.authors, vec!["Ada", "Charles", "Grace"]);
        let encoded = serde_json::to_value(input).unwrap();
        assert_eq!(encoded["rawBibtex"], "@article{x}");
        assert_eq!(encoded["freeText"], "citation query");
        assert_eq!(encoded["preferredDatabase"], "physics");
    }

    #[test]
    fn resolve_citation_marks_citation_material_private_in_generated_schema() {
        let tool = McpToolDescriptor::iter()
            .find(|tool| tool.name == "imbib-app-service_resolve-citation")
            .expect("resolve-citation is registered");
        let schema = (tool.input_schema)();
        for field in ["query", "bibtex", "citation"] {
            assert_eq!(schema["properties"][field]["x-private"], true, "{field}");
        }
    }
}
