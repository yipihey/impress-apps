//! `ImbibArtifactsService` — research artifacts (datasets, posters, notes,
//! presentations) — the non-publication schemas in the unified store. Tier 4.

use std::sync::Arc;

use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

use crate::library_service::MutationResult;
use crate::store_singleton::store_instance;

#[allow(unused_imports)]
use impress_service_macros::impress_method;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ArtifactRecord {
    pub id: String,
    #[serde(default)]
    pub schema: String,
    #[serde(default)]
    pub title: String,
    #[serde(alias = "sourceUrl", alias = "sourceURL", default)]
    pub source_url: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(alias = "artifactSubtype", alias = "subtype", default)]
    pub artifact_subtype: Option<String>,
    #[serde(alias = "fileName", default)]
    pub file_name: Option<String>,
    #[serde(alias = "fileHash", default)]
    pub file_hash: Option<String>,
    #[serde(alias = "fileSize", default)]
    pub file_size: Option<i64>,
    #[serde(alias = "fileMimeType", default)]
    pub file_mime_type: Option<String>,
    #[serde(alias = "captureContext", default)]
    pub capture_context: Option<String>,
    #[serde(alias = "originalAuthor", default)]
    pub original_author: Option<String>,
    #[serde(alias = "eventName", default)]
    pub event_name: Option<String>,
    #[serde(alias = "eventDate", default)]
    pub event_date: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
}

impl From<&imbib_core::unified::shaped_queries::ArtifactRow> for ArtifactRecord {
    fn from(r: &imbib_core::unified::shaped_queries::ArtifactRow) -> Self {
        Self {
            id: r.id.clone(),
            schema: r.schema.clone(),
            title: r.title.clone(),
            source_url: r.source_url.clone(),
            notes: r.notes.clone(),
            artifact_subtype: r.artifact_subtype.clone(),
            file_name: r.file_name.clone(),
            file_hash: r.file_hash.clone(),
            file_size: r.file_size,
            file_mime_type: r.file_mime_type.clone(),
            capture_context: r.capture_context.clone(),
            original_author: r.original_author.clone(),
            event_name: r.event_name.clone(),
            event_date: r.event_date.clone(),
            tags: r.tags.iter().map(|t| t.path.clone()).collect(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ArtifactRelationRecord {
    #[serde(alias = "targetId", alias = "targetID", default)]
    pub target_id: String,
    #[serde(alias = "edgeType", default)]
    pub edge_type: String,
    #[serde(alias = "targetSchema", default)]
    pub target_schema: Option<String>,
    #[serde(alias = "targetTitle", default)]
    pub target_title: Option<String>,
}

impl From<&imbib_core::unified::shaped_queries::ArtifactRelation> for ArtifactRelationRecord {
    fn from(r: &imbib_core::unified::shaped_queries::ArtifactRelation) -> Self {
        Self {
            target_id: r.target_id.clone(),
            edge_type: r.edge_type.clone(),
            target_schema: r.target_schema.clone(),
            target_title: r.target_title.clone(),
        }
    }
}

#[impress_service]
pub trait ImbibArtifactsService: Send + Sync + 'static {
    #[impress_method]
    async fn list_artifacts(&self, schema_filter: Option<String>, sort_field: String, ascending: bool, limit: u32, offset: u32) -> Vec<ArtifactRecord>;
    #[impress_method]
    async fn search_artifacts(&self, query: String, schema_filter: Option<String>) -> Vec<ArtifactRecord>;
    #[impress_method]
    async fn get_artifact(&self, id: String) -> Option<ArtifactRecord>;
    #[impress_method]
    async fn count_artifacts(&self, schema_filter: Option<String>) -> u32;
    #[impress_method]
    async fn create_artifact(
        &self,
        schema: String,
        title: String,
        source_url: Option<String>,
        notes: Option<String>,
        artifact_subtype: Option<String>,
        file_name: Option<String>,
        file_hash: Option<String>,
        file_size: Option<i64>,
        file_mime_type: Option<String>,
        capture_context: Option<String>,
        original_author: Option<String>,
        event_name: Option<String>,
        event_date: Option<String>,
        tags: Vec<String>,
    ) -> Option<ArtifactRecord>;
    #[impress_method]
    async fn update_artifact(
        &self,
        id: String,
        title: Option<String>,
        source_url: Option<String>,
        notes: Option<String>,
        artifact_subtype: Option<String>,
        capture_context: Option<String>,
        original_author: Option<String>,
        event_name: Option<String>,
        event_date: Option<String>,
    ) -> MutationResult;
    #[impress_method]
    async fn delete_artifact(&self, id: String) -> MutationResult;
    #[impress_method]
    async fn link_artifact_to_publication(&self, artifact_id: String, publication_id: String) -> MutationResult;
    #[impress_method]
    async fn get_artifact_relations(&self, id: String) -> Vec<ArtifactRelationRecord>;
}

#[derive(Clone)]
pub struct DefaultImbibArtifactsService { store: Arc<ImbibStore> }
impl DefaultImbibArtifactsService { pub fn new(store: Arc<ImbibStore>) -> Self { Self { store } } }

fn ok_n(n: u32) -> MutationResult { MutationResult { affected_count: n, ok: true } }
fn fail() -> MutationResult { MutationResult { affected_count: 0, ok: false } }
fn log(m: &str, e: impl std::fmt::Display) { eprintln!("[imbib-artifacts-service] {m}: {e}"); }

#[async_trait::async_trait]
impl ImbibArtifactsService for DefaultImbibArtifactsService {
    async fn list_artifacts(&self, schema_filter: Option<String>, sort_field: String, ascending: bool, limit: u32, offset: u32) -> Vec<ArtifactRecord> {
        let lim = if limit == 0 { Some(50) } else { Some(limit) };
        let off = if offset == 0 { None } else { Some(offset) };
        let sort = if sort_field.is_empty() { "date_added".to_string() } else { sort_field };
        self.store.list_artifacts(schema_filter, sort, ascending, lim, off)
            .map(|rs| rs.iter().map(ArtifactRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("list_artifacts", e); vec![] })
    }
    async fn search_artifacts(&self, query: String, schema_filter: Option<String>) -> Vec<ArtifactRecord> {
        self.store.search_artifacts(query, schema_filter)
            .map(|rs| rs.iter().map(ArtifactRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("search_artifacts", e); vec![] })
    }
    async fn get_artifact(&self, id: String) -> Option<ArtifactRecord> {
        self.store.get_artifact(id).ok().flatten().as_ref().map(ArtifactRecord::from)
    }
    async fn count_artifacts(&self, schema_filter: Option<String>) -> u32 {
        self.store.count_artifacts(schema_filter).unwrap_or(0)
    }
    async fn create_artifact(&self, schema: String, title: String, source_url: Option<String>, notes: Option<String>, artifact_subtype: Option<String>, file_name: Option<String>, file_hash: Option<String>, file_size: Option<i64>, file_mime_type: Option<String>, capture_context: Option<String>, original_author: Option<String>, event_name: Option<String>, event_date: Option<String>, tags: Vec<String>) -> Option<ArtifactRecord> {
        self.store.create_artifact(schema, title, source_url, notes, artifact_subtype, file_name, file_hash, file_size, file_mime_type, capture_context, original_author, event_name, event_date, tags)
            .map(|r| ArtifactRecord::from(&r))
            .map_err(|e| log("create_artifact", e))
            .ok()
    }
    async fn update_artifact(&self, id: String, title: Option<String>, source_url: Option<String>, notes: Option<String>, artifact_subtype: Option<String>, capture_context: Option<String>, original_author: Option<String>, event_name: Option<String>, event_date: Option<String>) -> MutationResult {
        match self.store.update_artifact(id, title, source_url, notes, artifact_subtype, capture_context, original_author, event_name, event_date) {
            Ok(_) => ok_n(1), Err(e) => { log("update_artifact", e); fail() }
        }
    }
    async fn delete_artifact(&self, id: String) -> MutationResult {
        match self.store.delete_artifact(id) { Ok(_) => ok_n(1), Err(e) => { log("delete_artifact", e); fail() } }
    }
    async fn link_artifact_to_publication(&self, artifact_id: String, publication_id: String) -> MutationResult {
        match self.store.link_artifact_to_publication(artifact_id, publication_id) {
            Ok(_) => ok_n(1), Err(e) => { log("link_artifact_to_publication", e); fail() }
        }
    }
    async fn get_artifact_relations(&self, id: String) -> Vec<ArtifactRelationRecord> {
        self.store.get_artifact_relations(id)
            .map(|rs| rs.iter().map(ArtifactRelationRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("get_artifact_relations", e); vec![] })
    }
}

impress_service_impl! {
    service = ImbibArtifactsService,
    impl = DefaultImbibArtifactsService,
    instance = || crate::backend::artifacts_service_instance(),
    methods = [
        list_artifacts(schema_filter: Option<String>, sort_field: String, ascending: bool, limit: u32, offset: u32) -> Vec<ArtifactRecord>,
        search_artifacts(query: String, schema_filter: Option<String>) -> Vec<ArtifactRecord>,
        get_artifact(id: String) -> Option<ArtifactRecord>,
        count_artifacts(schema_filter: Option<String>) -> u32,
        create_artifact(schema: String, title: String, source_url: Option<String>, notes: Option<String>, artifact_subtype: Option<String>, file_name: Option<String>, file_hash: Option<String>, file_size: Option<i64>, file_mime_type: Option<String>, capture_context: Option<String>, original_author: Option<String>, event_name: Option<String>, event_date: Option<String>, tags: Vec<String>) -> Option<ArtifactRecord>,
        update_artifact(id: String, title: Option<String>, source_url: Option<String>, notes: Option<String>, artifact_subtype: Option<String>, capture_context: Option<String>, original_author: Option<String>, event_name: Option<String>, event_date: Option<String>) -> MutationResult,
        delete_artifact(id: String) -> MutationResult,
        link_artifact_to_publication(artifact_id: String, publication_id: String) -> MutationResult,
        get_artifact_relations(id: String) -> Vec<ArtifactRelationRecord>,
    ],
}
