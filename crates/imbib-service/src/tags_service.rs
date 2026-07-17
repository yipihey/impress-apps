//! `ImbibTagsService` — tag CRUD + tag-scoped paper queries + counts.

use std::sync::Arc;

use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Serialize};

use crate::library_service::{MutationResult, PublicationSummary};
use crate::store_singleton::store_instance;

#[allow(unused_imports)]
use impress_service_macros::impress_method;

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TagRecord {
    #[serde(default)]
    pub path: String,
    #[serde(alias = "leafName", default)]
    pub leaf_name: String,
    #[serde(alias = "colorLight", default)]
    pub color_light: Option<String>,
    #[serde(alias = "colorDark", default)]
    pub color_dark: Option<String>,
}

impl From<&imbib_core::unified::shaped_queries::TagDisplayRow> for TagRecord {
    fn from(r: &imbib_core::unified::shaped_queries::TagDisplayRow) -> Self {
        Self {
            path: r.path.clone(),
            leaf_name: r.leaf_name.clone(),
            color_light: r.color_light.clone(),
            color_dark: r.color_dark.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct TagWithCount {
    #[serde(default)]
    pub path: String,
    #[serde(alias = "leafName", default)]
    pub leaf_name: String,
    #[serde(alias = "colorLight", default)]
    pub color_light: Option<String>,
    #[serde(alias = "colorDark", default)]
    pub color_dark: Option<String>,
    #[serde(alias = "paperCount", alias = "useCount", default)]
    pub publication_count: i32,
}

impl From<&imbib_core::unified::shaped_queries::TagWithCountRow> for TagWithCount {
    fn from(r: &imbib_core::unified::shaped_queries::TagWithCountRow) -> Self {
        Self {
            path: r.path.clone(),
            leaf_name: r.leaf_name.clone(),
            color_light: r.color_light.clone(),
            color_dark: r.color_dark.clone(),
            publication_count: r.publication_count,
        }
    }
}

#[impress_service]
pub trait ImbibTagsService: Send + Sync + 'static {
    #[impress_method]
    async fn list_tags(&self) -> Vec<TagRecord>;
    #[impress_method]
    async fn list_tags_with_counts(&self) -> Vec<TagWithCount>;
    #[impress_method]
    async fn create_tag(&self, path: String, color_light: Option<String>, color_dark: Option<String>) -> MutationResult;
    #[impress_method]
    async fn delete_tag_undoable(&self, path: String) -> MutationResult;
    #[impress_method]
    async fn update_tag(&self, path: String, color_light: Option<String>, color_dark: Option<String>) -> MutationResult;
    #[impress_method]
    async fn rename_tag(&self, old_path: String, new_path: String) -> MutationResult;
    #[impress_method]
    async fn add_tag(&self, ids: Vec<String>, tag_path: String) -> MutationResult;
    #[impress_method]
    async fn remove_tag(&self, ids: Vec<String>, tag_path: String) -> MutationResult;
    #[impress_method]
    async fn query_by_tag(&self, tag_path: String, parent_id: Option<String>, sort_field: String, ascending: bool, limit: u32) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn count_by_tag(&self, tag_path: String, parent_id: Option<String>) -> u32;
}

#[derive(Clone)]
pub struct DefaultImbibTagsService { store: Arc<ImbibStore> }
impl DefaultImbibTagsService { pub fn new(store: Arc<ImbibStore>) -> Self { Self { store } } }

fn ok_n(n: u32) -> MutationResult { MutationResult { affected_count: n, ok: true } }
fn fail() -> MutationResult { MutationResult { affected_count: 0, ok: false } }
fn log(m: &str, e: impl std::fmt::Display) { eprintln!("[imbib-tags-service] {m}: {e}"); }

#[async_trait::async_trait]
impl ImbibTagsService for DefaultImbibTagsService {
    async fn list_tags(&self) -> Vec<TagRecord> {
        self.store.list_tags().map(|rs| rs.iter().map(TagRecord::from).collect::<Vec<_>>()).unwrap_or_else(|e| { log("list_tags", e); vec![] })
    }
    async fn list_tags_with_counts(&self) -> Vec<TagWithCount> {
        self.store.list_tags_with_counts().map(|rs| rs.iter().map(TagWithCount::from).collect::<Vec<_>>()).unwrap_or_else(|e| { log("list_tags_with_counts", e); vec![] })
    }
    async fn create_tag(&self, path: String, color_light: Option<String>, color_dark: Option<String>) -> MutationResult {
        match self.store.create_tag(path, color_light, color_dark) { Ok(_) => ok_n(1), Err(e) => { log("create_tag", e); fail() } }
    }
    async fn delete_tag_undoable(&self, path: String) -> MutationResult {
        match self.store.delete_tag_undoable(path) { Ok(_) => ok_n(1), Err(e) => { log("delete_tag_undoable", e); fail() } }
    }
    async fn update_tag(&self, path: String, color_light: Option<String>, color_dark: Option<String>) -> MutationResult {
        match self.store.update_tag(path, color_light, color_dark) { Ok(_) => ok_n(1), Err(e) => { log("update_tag", e); fail() } }
    }
    async fn rename_tag(&self, old_path: String, new_path: String) -> MutationResult {
        match self.store.rename_tag(old_path, new_path) { Ok(_) => ok_n(1), Err(e) => { log("rename_tag", e); fail() } }
    }
    async fn add_tag(&self, ids: Vec<String>, tag_path: String) -> MutationResult {
        let n = ids.len() as u32;
        match self.store.add_tag(ids, tag_path) { Ok(_) => ok_n(n), Err(e) => { log("add_tag", e); fail() } }
    }
    async fn remove_tag(&self, ids: Vec<String>, tag_path: String) -> MutationResult {
        let n = ids.len() as u32;
        match self.store.remove_tag(ids, tag_path) { Ok(_) => ok_n(n), Err(e) => { log("remove_tag", e); fail() } }
    }
    async fn query_by_tag(&self, tag_path: String, parent_id: Option<String>, sort_field: String, ascending: bool, limit: u32) -> Vec<PublicationSummary> {
        let lim = if limit == 0 { Some(50) } else { Some(limit) };
        let sort = if sort_field.is_empty() { "date_added".to_string() } else { sort_field };
        self.store.query_by_tag(tag_path, parent_id, sort, ascending, lim, None)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("query_by_tag", e); vec![] })
    }
    async fn count_by_tag(&self, tag_path: String, parent_id: Option<String>) -> u32 {
        self.store.count_by_tag(tag_path, parent_id).unwrap_or(0)
    }
}

impress_service_impl! {
    service = ImbibTagsService,
    impl = DefaultImbibTagsService,
    instance = || crate::backend::tags_service_instance(),
    methods = [
        list_tags() -> Vec<TagRecord>,
        list_tags_with_counts() -> Vec<TagWithCount>,
        create_tag(path: String, color_light: Option<String>, color_dark: Option<String>) -> MutationResult,
        delete_tag_undoable(path: String) -> MutationResult,
        update_tag(path: String, color_light: Option<String>, color_dark: Option<String>) -> MutationResult,
        rename_tag(old_path: String, new_path: String) -> MutationResult,
        add_tag(ids: Vec<String>, tag_path: String) -> MutationResult,
        remove_tag(ids: Vec<String>, tag_path: String) -> MutationResult,
        query_by_tag(tag_path: String, parent_id: Option<String>, sort_field: String, ascending: bool, limit: u32) -> Vec<PublicationSummary>,
        count_by_tag(tag_path: String, parent_id: Option<String>) -> u32,
    ],
}
