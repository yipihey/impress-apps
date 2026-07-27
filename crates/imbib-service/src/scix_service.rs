//! `ImbibScixService` — NASA ADS / SciX remote-library integration. Tier 4.

use std::sync::Arc;

use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

use crate::library_service::{MutationResult, PublicationSummary};

#[allow(unused_imports)]
use impress_service_macros::impress_method;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct SciXLibraryRecord {
    pub id: String,
    #[serde(alias = "remoteId", alias = "remoteID", default)]
    pub remote_id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(alias = "isPublic", default)]
    pub is_public: bool,
    #[serde(alias = "permissionLevel", default)]
    pub permission_level: String,
    #[serde(alias = "ownerEmail", default)]
    pub owner_email: Option<String>,
    #[serde(alias = "documentCount", default)]
    pub document_count: i32,
    #[serde(alias = "publicationCount", alias = "paperCount", default)]
    pub publication_count: i32,
}

impl From<&imbib_core::unified::shaped_queries::SciXLibraryRow> for SciXLibraryRecord {
    fn from(r: &imbib_core::unified::shaped_queries::SciXLibraryRow) -> Self {
        Self {
            id: r.id.clone(),
            remote_id: r.remote_id.clone(),
            name: r.name.clone(),
            description: r.description.clone(),
            is_public: r.is_public,
            permission_level: r.permission_level.clone(),
            owner_email: r.owner_email.clone(),
            document_count: r.document_count,
            publication_count: r.publication_count,
        }
    }
}

#[impress_service]
pub trait ImbibScixService: Send + Sync + 'static {
    #[impress_method]
    async fn list_scix_libraries(&self) -> Vec<SciXLibraryRecord>;
    #[impress_method]
    async fn get_scix_library(&self, id: String) -> Option<SciXLibraryRecord>;
    #[impress_method]
    async fn create_scix_library(
        &self,
        remote_id: String,
        name: String,
        description: Option<String>,
        is_public: bool,
        permission_level: String,
        owner_email: Option<String>,
    ) -> Option<SciXLibraryRecord>;
    #[impress_method]
    async fn add_to_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> MutationResult;
    #[impress_method]
    async fn remove_from_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> MutationResult;
    #[impress_method]
    async fn query_scix_library_publications(
        &self,
        scix_library_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn count_scix_library_publications(&self, scix_library_id: String) -> u32;
}

#[derive(Clone)]
pub struct DefaultImbibScixService {
    store: Arc<ImbibStore>,
}
impl DefaultImbibScixService {
    pub fn new(store: Arc<ImbibStore>) -> Self {
        Self { store }
    }
}

fn ok_n(n: u32) -> MutationResult {
    MutationResult {
        affected_count: n,
        ok: true,
    }
}
fn fail() -> MutationResult {
    MutationResult {
        affected_count: 0,
        ok: false,
    }
}
fn log(m: &str, e: impl std::fmt::Display) {
    eprintln!("[imbib-scix-service] {m}: {e}");
}

#[async_trait::async_trait]
impl ImbibScixService for DefaultImbibScixService {
    async fn list_scix_libraries(&self) -> Vec<SciXLibraryRecord> {
        self.store
            .list_scix_libraries()
            .map(|rs| rs.iter().map(SciXLibraryRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("list_scix_libraries", e);
                vec![]
            })
    }
    async fn get_scix_library(&self, id: String) -> Option<SciXLibraryRecord> {
        self.store
            .get_scix_library(id)
            .ok()
            .flatten()
            .as_ref()
            .map(SciXLibraryRecord::from)
    }
    async fn create_scix_library(
        &self,
        remote_id: String,
        name: String,
        description: Option<String>,
        is_public: bool,
        permission_level: String,
        owner_email: Option<String>,
    ) -> Option<SciXLibraryRecord> {
        self.store
            .create_scix_library(
                remote_id,
                name,
                description,
                is_public,
                permission_level,
                owner_email,
            )
            .map(|r| SciXLibraryRecord::from(&r))
            .map_err(|e| log("create_scix_library", e))
            .ok()
    }
    async fn add_to_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> MutationResult {
        let n = publication_ids.len() as u32;
        match self
            .store
            .add_to_scix_library(publication_ids, scix_library_id)
        {
            Ok(_) => ok_n(n),
            Err(e) => {
                log("add_to_scix_library", e);
                fail()
            }
        }
    }
    async fn remove_from_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> MutationResult {
        let n = publication_ids.len() as u32;
        match self
            .store
            .remove_from_scix_library(publication_ids, scix_library_id)
        {
            Ok(_) => ok_n(n),
            Err(e) => {
                log("remove_from_scix_library", e);
                fail()
            }
        }
    }
    async fn query_scix_library_publications(
        &self,
        scix_library_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<PublicationSummary> {
        let lim = if limit == 0 { Some(50) } else { Some(limit) };
        let off = if offset == 0 { None } else { Some(offset) };
        let sort = if sort_field.is_empty() {
            "date_added".to_string()
        } else {
            sort_field
        };
        self.store
            .query_scix_library_publications(scix_library_id, sort, ascending, lim, off)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("query_scix_library_publications", e);
                vec![]
            })
    }
    async fn count_scix_library_publications(&self, scix_library_id: String) -> u32 {
        self.store
            .count_scix_library_publications(scix_library_id)
            .unwrap_or(0)
    }
}

impress_service_impl! {
    service = ImbibScixService,
    impl = DefaultImbibScixService,
    instance = || crate::backend::scix_service_instance(),
    methods = [
        list_scix_libraries() -> Vec<SciXLibraryRecord>,
        get_scix_library(id: String) -> Option<SciXLibraryRecord>,
        create_scix_library(remote_id: String, name: String, description: Option<String>, is_public: bool, permission_level: String, owner_email: Option<String>) -> Option<SciXLibraryRecord>,
        add_to_scix_library(publication_ids: Vec<String>, scix_library_id: String) -> MutationResult,
        remove_from_scix_library(publication_ids: Vec<String>, scix_library_id: String) -> MutationResult,
        query_scix_library_publications(scix_library_id: String, sort_field: String, ascending: bool, limit: u32, offset: u32) -> Vec<PublicationSummary>,
        count_scix_library_publications(scix_library_id: String) -> u32,
    ],
}
