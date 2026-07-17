//! `ImbibSearchService` — identifier lookups, full-text search, smart-search CRUD.

use std::sync::Arc;

use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

use crate::library_service::PublicationSummary;
use crate::store_singleton::store_instance;

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

#[impress_service]
pub trait ImbibSearchService: Send + Sync + 'static {
    // ---- Identifier lookups ----
    #[impress_method]
    async fn find_by_cite_key(&self, cite_key: String, library_id: Option<String>) -> Option<PublicationSummary>;
    #[impress_method]
    async fn find_by_doi(&self, doi: String) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn find_by_arxiv(&self, arxiv_id: String) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn find_by_bibcode(&self, bibcode: String) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn find_by_identifiers_batch(&self, dois: Vec<String>, arxiv_ids: Vec<String>, bibcodes: Vec<String>) -> Vec<PublicationSummary>;

    // ---- Full-text search ----
    #[impress_method]
    async fn full_text_search(&self, query: String, parent_id: Option<String>, limit: u32) -> Vec<PublicationSummary>;

    // ---- Smart search CRUD ----
    #[impress_method]
    async fn list_smart_searches(&self, library_id: Option<String>) -> Vec<SmartSearchRecord>;
    #[impress_method]
    async fn get_smart_search(&self, id: String) -> Option<SmartSearchRecord>;
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
pub struct DefaultImbibSearchService { store: Arc<ImbibStore> }
impl DefaultImbibSearchService { pub fn new(store: Arc<ImbibStore>) -> Self { Self { store } } }

fn log(m: &str, e: impl std::fmt::Display) { eprintln!("[imbib-search-service] {m}: {e}"); }

#[async_trait::async_trait]
impl ImbibSearchService for DefaultImbibSearchService {
    async fn find_by_cite_key(&self, cite_key: String, library_id: Option<String>) -> Option<PublicationSummary> {
        self.store.find_by_cite_key(cite_key, library_id).ok().flatten().as_ref().map(PublicationSummary::from)
    }
    async fn find_by_doi(&self, doi: String) -> Vec<PublicationSummary> {
        self.store.find_by_doi(doi).map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>()).unwrap_or_else(|e| { log("find_by_doi", e); vec![] })
    }
    async fn find_by_arxiv(&self, arxiv_id: String) -> Vec<PublicationSummary> {
        self.store.find_by_arxiv(arxiv_id).map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>()).unwrap_or_else(|e| { log("find_by_arxiv", e); vec![] })
    }
    async fn find_by_bibcode(&self, bibcode: String) -> Vec<PublicationSummary> {
        self.store.find_by_bibcode(bibcode).map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>()).unwrap_or_else(|e| { log("find_by_bibcode", e); vec![] })
    }
    async fn find_by_identifiers_batch(&self, dois: Vec<String>, arxiv_ids: Vec<String>, bibcodes: Vec<String>) -> Vec<PublicationSummary> {
        self.store.find_by_identifiers_batch(dois, arxiv_ids, bibcodes).map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>()).unwrap_or_else(|e| { log("find_by_identifiers_batch", e); vec![] })
    }
    async fn full_text_search(&self, query: String, parent_id: Option<String>, limit: u32) -> Vec<PublicationSummary> {
        let lim = if limit == 0 { Some(50) } else { Some(limit) };
        self.store.full_text_search(query, parent_id, lim, None)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("full_text_search", e); vec![] })
    }
    async fn list_smart_searches(&self, library_id: Option<String>) -> Vec<SmartSearchRecord> {
        self.store.list_smart_searches(library_id)
            .map(|rs| rs.iter().map(SmartSearchRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("list_smart_searches", e); vec![] })
    }
    async fn get_smart_search(&self, id: String) -> Option<SmartSearchRecord> {
        self.store.get_smart_search(id).ok().flatten().as_ref().map(SmartSearchRecord::from)
    }
    async fn create_smart_search(&self, name: String, query: String, library_id: String, source_ids_json: Option<String>, max_results: i64, feeds_to_inbox: bool, auto_refresh_enabled: bool, refresh_interval_seconds: i64) -> Option<SmartSearchRecord> {
        self.store.create_smart_search(name, query, library_id, source_ids_json, max_results, feeds_to_inbox, auto_refresh_enabled, refresh_interval_seconds)
            .map(|r| SmartSearchRecord::from(&r))
            .map_err(|e| log("create_smart_search", e))
            .ok()
    }
}

impress_service_impl! {
    service = ImbibSearchService,
    impl = DefaultImbibSearchService,
    instance = || crate::backend::search_service_instance(),
    methods = [
        find_by_cite_key(cite_key: String, library_id: Option<String>) -> Option<PublicationSummary>,
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
