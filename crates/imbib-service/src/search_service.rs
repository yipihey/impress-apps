//! `ImbibSearchService` — identifier lookups, full-text search, smart-search CRUD.

use std::sync::Arc;

use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

use crate::library_service::PublicationSummary;

#[allow(unused_imports)]
use impress_service_macros::impress_method;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SmartSearchRecord {
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub query: String,
    #[serde(alias = "sourceIds", alias = "sourceIDs", default)]
    pub source_ids: Vec<String>,
    #[serde(alias = "maxResults", default)]
    pub max_results: i32,
    #[serde(alias = "feedsToInbox", default)]
    pub feeds_to_inbox: bool,
    #[serde(alias = "autoRefreshEnabled", default)]
    pub auto_refresh_enabled: bool,
    #[serde(alias = "refreshIntervalSeconds", default)]
    pub refresh_interval_seconds: i32,
    #[serde(alias = "libraryId", alias = "libraryID", default)]
    pub library_id: Option<String>,
}

impl From<&imbib_core::unified::shaped_queries::SmartSearchRow> for SmartSearchRecord {
    fn from(r: &imbib_core::unified::shaped_queries::SmartSearchRow) -> Self {
        Self {
            id: r.id.clone(),
            name: r.name.clone(),
            query: r.query.clone(),
            source_ids: r.source_ids.clone(),
            max_results: r.max_results,
            feeds_to_inbox: r.feeds_to_inbox,
            auto_refresh_enabled: r.auto_refresh_enabled,
            refresh_interval_seconds: r.refresh_interval_seconds,
            library_id: r.library_id.clone(),
        }
    }
}

/// The answer to "what paper does this manuscript cite key refer to?" —
/// including, when there is no answer, WHICH kind of no.
///
/// `find_by_cite_key` returns `null` for both "your library has no paper with
/// that key" and "this device has no papers at all", and a caller that renders
/// the two the same way lies to the user: on iOS the store is routinely empty
/// (imbib-iOS + CloudKit sync is off by default), so "not in your library" is
/// the wrong sentence far more often than it is the right one. `status`
/// separates them, and `library_size` shows the work.
#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CiteKeyResolution {
    /// The key that was looked up, after trimming and dropping a leading `@`.
    pub cite_key: String,
    /// `resolved` — `publication` is the paper.
    /// `unknown-key` — the library has papers, none with this key.
    /// `empty-library` — the library has NO papers at all, so the key was
    ///   never really tested; the right thing to tell a user is "nothing is
    ///   here yet", not "no such paper".
    /// `error` — the store could not be read; see `message`.
    pub status: String,
    /// The paper, when `status` is `resolved`.
    pub publication: Option<PublicationSummary>,
    /// How many publications the store holds — in `library_id` when one was
    /// given, otherwise across every library. `Some(0)` is what makes
    /// `empty-library` checkable rather than a claim; `null` means the size
    /// could not be established (the HTTP-proxied implementation cannot ask a
    /// running app for it), in which case `empty-library` is never reported,
    /// because it could not be ruled in.
    pub library_size: Option<u32>,
    /// The library the lookup was scoped to, echoed back; null means "any".
    pub library_id: Option<String>,
    pub message: String,
}

#[impress_service]
pub trait ImbibSearchService: Send + Sync + 'static {
    // ---- Identifier lookups ----
    #[impress_method]
    async fn find_by_cite_key(
        &self,
        cite_key: String,
        library_id: Option<String>,
    ) -> Option<PublicationSummary>;

    /// Resolve a manuscript cite key (`@smith2024`, `\cite{smith2024}`) to the
    /// paper it refers to — the lookup behind imprint's citation-inspection
    /// affordance (hover on macOS, long-press on iOS).
    ///
    /// Use this instead of `find_by_cite_key` whenever a human will read the
    /// outcome. It runs the same store lookup, but a miss comes back saying
    /// WHY: `unknown-key` (the library has papers, just not this one) or
    /// `empty-library` (the library is empty, so the key was never really
    /// tested — the common case on a fresh iOS device, where sync is off by
    /// default). A leading `@` is accepted and stripped, so a key lifted
    /// straight out of Typst source works.
    #[impress_method]
    async fn resolve_cite_key(
        &self,
        cite_key: String,
        library_id: Option<String>,
    ) -> CiteKeyResolution;
    #[impress_method]
    async fn find_by_doi(&self, doi: String) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn find_by_arxiv(&self, arxiv_id: String) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn find_by_bibcode(&self, bibcode: String) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn find_by_identifiers_batch(
        &self,
        dois: Vec<String>,
        arxiv_ids: Vec<String>,
        bibcodes: Vec<String>,
    ) -> Vec<PublicationSummary>;

    // ---- Full-text search ----
    /// Search the imbib library for papers by title, author, abstract, or
    /// keywords. Returns matching papers with metadata and BibTeX.
    #[impress_method]
    async fn full_text_search(
        &self,
        query: String,
        parent_id: Option<String>,
        limit: u32,
    ) -> Vec<PublicationSummary>;

    // ---- Smart search CRUD ----
    /// List saved smart searches. Pass the Exploration library's ID to
    /// enumerate the rows of imbib's Exploration sidebar section.
    #[impress_method]
    async fn list_smart_searches(&self, library_id: Option<String>) -> Vec<SmartSearchRecord>;
    /// Fetch one smart search by UUID: its query string, owning library,
    /// result cap, and its feeds-to-inbox / auto-refresh settings. Use to
    /// inspect or confirm a search before changing or deleting it; find the
    /// UUID with `imbib-search-service_list-smart-searches`.
    #[impress_method]
    async fn get_smart_search(&self, id: String) -> Option<SmartSearchRecord>;
    /// Save a query as a smart search (an Exploration sidebar row) in a
    /// library — the 'keep an eye on this topic' tool. To run a search ONCE
    /// without saving anything, use `imbib-search-service_full-text-search` (the local
    /// library) or `imbib-app-service_search-sources` (external databases) instead.
    /// feedsToInbox routes new hits into the user's Inbox and
    /// autoRefreshEnabled makes imbib re-run the query on a timer; both
    /// default OFF, so turn them on only when the user explicitly asks for
    /// an ongoing feed rather than a saved query. List with
    /// `imbib-search-service_list-smart-searches`, remove with imbib_delete_smart_searches.
    #[impress_method]
    async fn create_smart_search(
        &self,
        name: String,
        query: String,
        library_id: String,
        source_ids_json: Option<String>,
        max_results: i64,
        feeds_to_inbox: bool,
        auto_refresh_enabled: bool,
        refresh_interval_seconds: i64,
    ) -> Option<SmartSearchRecord>;
}

#[derive(Clone)]
pub struct DefaultImbibSearchService {
    store: Arc<ImbibStore>,
}
impl DefaultImbibSearchService {
    pub fn new(store: Arc<ImbibStore>) -> Self {
        Self { store }
    }
}

fn log(m: &str, e: impl std::fmt::Display) {
    eprintln!("[imbib-search-service] {m}: {e}");
}

#[async_trait::async_trait]
impl ImbibSearchService for DefaultImbibSearchService {
    async fn find_by_cite_key(
        &self,
        cite_key: String,
        library_id: Option<String>,
    ) -> Option<PublicationSummary> {
        self.store
            .find_by_cite_key(cite_key, library_id)
            .ok()
            .flatten()
            .as_ref()
            .map(PublicationSummary::from)
    }
    async fn resolve_cite_key(
        &self,
        cite_key: String,
        library_id: Option<String>,
    ) -> CiteKeyResolution {
        // Accept a key exactly as it appears in Typst source.
        let key = cite_key.trim().trim_start_matches('@').to_string();

        let answer = |status: &str, publication, library_size, message: String| CiteKeyResolution {
            cite_key: key.clone(),
            status: status.to_string(),
            publication,
            library_size,
            library_id: library_id.clone(),
            message,
        };

        if key.is_empty() {
            return answer("unknown-key", None, None, "No cite key was given.".into());
        }

        match self.store.find_by_cite_key(key.clone(), library_id.clone()) {
            Err(e) => {
                log("resolve_cite_key", &e);
                return answer("error", None, None, e.to_string());
            }
            Ok(Some(row)) => {
                let summary = PublicationSummary::from(&row);
                let title = if summary.title.is_empty() {
                    "(untitled)".to_string()
                } else {
                    summary.title.clone()
                };
                // The size is still worth reporting on a hit: it is the same
                // number the miss branches justify themselves with, so a caller
                // never has to make a second call to interpret one.
                let size = self.store.count_publications(library_id.clone()).ok();
                return answer("resolved", Some(summary), size, format!("{key} → {title}"));
            }
            Ok(None) => {}
        }

        match self.store.count_publications(library_id.clone()) {
            Err(e) => {
                log("resolve_cite_key/count", &e);
                answer("error", None, None, e.to_string())
            }
            Ok(0) => answer(
                "empty-library",
                None,
                Some(0),
                format!(
                    "No publications are in this library at all, so '{key}' could not be looked \
                     up. Add papers in imbib (or turn on sync) — this is not the same as the key \
                     being wrong."
                ),
            ),
            Ok(size) => answer(
                "unknown-key",
                None,
                Some(size),
                format!("No publication in this library ({size} paper(s)) has cite key '{key}'."),
            ),
        }
    }

    async fn find_by_doi(&self, doi: String) -> Vec<PublicationSummary> {
        self.store
            .find_by_doi(doi)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("find_by_doi", e);
                vec![]
            })
    }
    async fn find_by_arxiv(&self, arxiv_id: String) -> Vec<PublicationSummary> {
        self.store
            .find_by_arxiv(arxiv_id)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("find_by_arxiv", e);
                vec![]
            })
    }
    async fn find_by_bibcode(&self, bibcode: String) -> Vec<PublicationSummary> {
        self.store
            .find_by_bibcode(bibcode)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("find_by_bibcode", e);
                vec![]
            })
    }
    async fn find_by_identifiers_batch(
        &self,
        dois: Vec<String>,
        arxiv_ids: Vec<String>,
        bibcodes: Vec<String>,
    ) -> Vec<PublicationSummary> {
        self.store
            .find_by_identifiers_batch(dois, arxiv_ids, bibcodes)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("find_by_identifiers_batch", e);
                vec![]
            })
    }
    async fn full_text_search(
        &self,
        query: String,
        parent_id: Option<String>,
        limit: u32,
    ) -> Vec<PublicationSummary> {
        let lim = if limit == 0 { Some(50) } else { Some(limit) };
        self.store
            .full_text_search(query, parent_id, lim, None)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("full_text_search", e);
                vec![]
            })
    }
    async fn list_smart_searches(&self, library_id: Option<String>) -> Vec<SmartSearchRecord> {
        self.store
            .list_smart_searches(library_id)
            .map(|rs| rs.iter().map(SmartSearchRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("list_smart_searches", e);
                vec![]
            })
    }
    async fn get_smart_search(&self, id: String) -> Option<SmartSearchRecord> {
        self.store
            .get_smart_search(id)
            .ok()
            .flatten()
            .as_ref()
            .map(SmartSearchRecord::from)
    }
    async fn create_smart_search(
        &self,
        name: String,
        query: String,
        library_id: String,
        source_ids_json: Option<String>,
        max_results: i64,
        feeds_to_inbox: bool,
        auto_refresh_enabled: bool,
        refresh_interval_seconds: i64,
    ) -> Option<SmartSearchRecord> {
        self.store
            .create_smart_search(
                name,
                query,
                library_id,
                source_ids_json,
                max_results,
                feeds_to_inbox,
                auto_refresh_enabled,
                refresh_interval_seconds,
            )
            .map(|r| SmartSearchRecord::from(&r))
            .map_err(|e| log("create_smart_search", e))
            .ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_service_core::McpToolDescriptor;

    const SEED: &str = r#"
    @article{Einstein1905,
      author = {Albert Einstein},
      title = {Zur Elektrodynamik bewegter Koerper},
      journal = {Annalen der Physik},
      year = {1905}
    }
    "#;

    /// A service over a fresh store, optionally seeded.
    ///
    /// A file, not `:memory:` — the store pools connections, and every
    /// `:memory:` connection is its own empty database, so the migrations run
    /// on one connection and the query lands on another with no `items` table.
    fn svc(seeded: bool) -> DefaultImbibSearchService {
        let path = std::env::temp_dir().join(format!(
            "imbib-search-service-test-{}-{:?}.sqlite",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_file(&path);
        let store = ImbibStore::open(path.to_string_lossy().into_owned()).expect("store opens");
        if seeded {
            let library = store
                .create_library("Test Library".to_string())
                .expect("library");
            store
                .import_bibtex(SEED.to_string(), library.id)
                .expect("import");
        }
        DefaultImbibSearchService::new(store)
    }

    #[tokio::test]
    async fn resolve_cite_key_returns_the_paper_and_the_library_size() {
        let out = svc(true)
            .resolve_cite_key("Einstein1905".into(), None)
            .await;
        assert_eq!(out.status, "resolved", "{}", out.message);
        let paper = out.publication.expect("a paper");
        assert_eq!(paper.cite_key, "Einstein1905");
        assert!(paper.title.contains("Elektrodynamik"), "{}", paper.title);
        assert_eq!(out.library_size, Some(1));
        assert!(out.message.contains("Einstein1905"), "{}", out.message);
    }

    #[tokio::test]
    async fn resolve_cite_key_accepts_a_key_lifted_from_typst_source() {
        // `@Einstein1905` is what a manuscript actually contains.
        let out = svc(true)
            .resolve_cite_key("  @Einstein1905 ".into(), None)
            .await;
        assert_eq!(out.status, "resolved", "{}", out.message);
        assert_eq!(
            out.cite_key, "Einstein1905",
            "the sigil is stripped, and echoed back without it"
        );
    }

    #[tokio::test]
    async fn an_unknown_key_in_a_populated_library_is_not_an_empty_library() {
        let out = svc(true).resolve_cite_key("Missing2099".into(), None).await;
        assert_eq!(out.status, "unknown-key", "{}", out.message);
        assert!(out.publication.is_none());
        assert_eq!(
            out.library_size,
            Some(1),
            "the claim ships with its evidence"
        );
        assert!(out.message.contains("Missing2099"), "{}", out.message);
    }

    #[tokio::test]
    async fn an_empty_library_says_so_instead_of_blaming_the_key() {
        // The distinction this method exists for. `find_by_cite_key` answers
        // `null` here and in the test above; a UI that renders both the same
        // way tells a user their citation is wrong when nothing has synced yet.
        let s = svc(false);
        let out = s.resolve_cite_key("Einstein1905".into(), None).await;
        assert_eq!(out.status, "empty-library", "{}", out.message);
        assert_eq!(out.library_size, Some(0));
        assert!(
            out.message.contains("not the same as the key being wrong"),
            "the message has to carry the distinction too: {}",
            out.message
        );

        // And the older method still cannot tell the two apart, which is why
        // this one exists.
        assert!(s
            .find_by_cite_key("Einstein1905".into(), None)
            .await
            .is_none());
    }

    #[tokio::test]
    async fn an_empty_key_is_a_miss_not_a_panic() {
        let out = svc(true).resolve_cite_key("@".into(), None).await;
        assert_eq!(out.status, "unknown-key");
        assert!(out.publication.is_none());
    }

    #[test]
    fn resolve_cite_key_is_registered_as_a_tool_and_a_subcommand() {
        let tools: Vec<&str> = McpToolDescriptor::iter().map(|d| d.name).collect();
        assert!(
            tools.contains(&"imbib-search-service_resolve-cite-key"),
            "the agent-facing surface is the point of putting this in a service trait: {tools:?}"
        );
    }
}

impress_service_impl! {
    service = ImbibSearchService,
    impl = DefaultImbibSearchService,
    instance = || crate::backend::search_service_instance(),
    methods = [
        find_by_cite_key(cite_key: String, library_id: Option<String>) -> Option<PublicationSummary>,
        /// Resolve a manuscript cite key to a paper, saying WHY on a miss.
        resolve_cite_key(cite_key: String, library_id: Option<String>) -> CiteKeyResolution,
        find_by_doi(doi: String) -> Vec<PublicationSummary>,
        find_by_arxiv(arxiv_id: String) -> Vec<PublicationSummary>,
        find_by_bibcode(bibcode: String) -> Vec<PublicationSummary>,
        find_by_identifiers_batch(dois: Vec<String>, arxiv_ids: Vec<String>, bibcodes: Vec<String>) -> Vec<PublicationSummary>,
        full_text_search(query: String, parent_id: Option<String>, limit: u32) -> Vec<PublicationSummary>,
        list_smart_searches(library_id: Option<String>) -> Vec<SmartSearchRecord>,
        get_smart_search(id: String) -> Option<SmartSearchRecord>,
        create_smart_search(name: String, query: String, library_id: String, source_ids_json: Option<String>, max_results: i64, feeds_to_inbox: bool, auto_refresh_enabled: bool, refresh_interval_seconds: i64) -> Option<SmartSearchRecord>,
    ],
}
