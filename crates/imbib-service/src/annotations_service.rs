//! `ImbibAnnotationsService` — PDF annotations + threaded comments on items.
//! Tier 4.

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
pub struct AnnotationRecord {
    pub id: String,
    #[serde(alias = "annotationType", alias = "type", default)]
    pub annotation_type: String,
    #[serde(alias = "pageNumber", alias = "page", default)]
    pub page_number: i32,
    #[serde(alias = "boundsJson", alias = "bounds", default)]
    pub bounds_json: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub contents: Option<String>,
    #[serde(alias = "selectedText", default)]
    pub selected_text: Option<String>,
    #[serde(alias = "authorName", default)]
    pub author_name: Option<String>,
    #[serde(alias = "dateCreated", default)]
    pub date_created: i64,
    #[serde(alias = "dateModified", default)]
    pub date_modified: i64,
    #[serde(alias = "linkedFileId", alias = "linkedFileID", default)]
    pub linked_file_id: String,
}

impl From<&imbib_core::unified::shaped_queries::AnnotationRow> for AnnotationRecord {
    fn from(r: &imbib_core::unified::shaped_queries::AnnotationRow) -> Self {
        Self {
            id: r.id.clone(),
            annotation_type: r.annotation_type.clone(),
            page_number: r.page_number,
            bounds_json: r.bounds_json.clone(),
            color: r.color.clone(),
            contents: r.contents.clone(),
            selected_text: r.selected_text.clone(),
            author_name: r.author_name.clone(),
            date_created: r.date_created,
            date_modified: r.date_modified,
            linked_file_id: r.linked_file_id.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CommentRecord {
    pub id: String,
    #[serde(default)]
    pub text: String,
    #[serde(alias = "authorIdentifier", alias = "authorAgentId", default)]
    pub author_identifier: Option<String>,
    #[serde(alias = "authorDisplayName", default)]
    pub author_display_name: Option<String>,
    #[serde(alias = "dateCreated", alias = "createdAt", default)]
    pub date_created: i64,
    #[serde(alias = "dateModified", alias = "updatedAt", default)]
    pub date_modified: i64,
    #[serde(alias = "parentCommentId", alias = "parentCommentID", default)]
    pub parent_comment_id: Option<String>,
    #[serde(alias = "parentItemId", alias = "parentItemID", default)]
    pub parent_item_id: String,
}

impl From<&imbib_core::unified::shaped_queries::CommentRow> for CommentRecord {
    fn from(r: &imbib_core::unified::shaped_queries::CommentRow) -> Self {
        Self {
            id: r.id.clone(),
            text: r.text.clone(),
            author_identifier: r.author_identifier.clone(),
            author_display_name: r.author_display_name.clone(),
            date_created: r.date_created,
            date_modified: r.date_modified,
            parent_comment_id: r.parent_comment_id.clone(),
            parent_item_id: r.parent_item_id.clone(),
        }
    }
}

#[impress_service]
pub trait ImbibAnnotationsService: Send + Sync + 'static {
    // ---- Annotations (PDF) ----
    #[impress_method]
    async fn list_annotations(&self, linked_file_id: String, page_number: Option<i32>) -> Vec<AnnotationRecord>;
    #[impress_method]
    async fn count_annotations(&self, linked_file_id: String) -> u32;
    #[impress_method]
    async fn create_annotation(
        &self,
        linked_file_id: String,
        annotation_type: String,
        page_number: i64,
        bounds_json: Option<String>,
        color: Option<String>,
        contents: Option<String>,
        selected_text: Option<String>,
    ) -> Option<AnnotationRecord>;

    // ---- Comments (threaded, on any item) ----
    #[impress_method]
    async fn list_comments_for_item(&self, item_id: String) -> Vec<CommentRecord>;
    #[impress_method]
    async fn list_comments(&self, publication_id: String) -> Vec<CommentRecord>;
    #[impress_method]
    async fn list_comments_since(&self, item_id: String, since_clock: u64) -> Vec<CommentRecord>;
    #[impress_method]
    async fn create_comment(
        &self,
        publication_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Option<CommentRecord>;
    #[impress_method]
    async fn create_comment_on_item(
        &self,
        item_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Option<CommentRecord>;
    #[impress_method]
    async fn update_comment(&self, id: String, text: String) -> MutationResult;
}

#[derive(Clone)]
pub struct DefaultImbibAnnotationsService { store: Arc<ImbibStore> }
impl DefaultImbibAnnotationsService { pub fn new(store: Arc<ImbibStore>) -> Self { Self { store } } }

fn ok_n(n: u32) -> MutationResult { MutationResult { affected_count: n, ok: true } }
fn fail() -> MutationResult { MutationResult { affected_count: 0, ok: false } }
fn log(m: &str, e: impl std::fmt::Display) { eprintln!("[imbib-annotations-service] {m}: {e}"); }

#[async_trait::async_trait]
impl ImbibAnnotationsService for DefaultImbibAnnotationsService {
    async fn list_annotations(&self, linked_file_id: String, page_number: Option<i32>) -> Vec<AnnotationRecord> {
        self.store.list_annotations(linked_file_id, page_number)
            .map(|rs| rs.iter().map(AnnotationRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("list_annotations", e); vec![] })
    }
    async fn count_annotations(&self, linked_file_id: String) -> u32 {
        self.store.count_annotations(linked_file_id).unwrap_or(0)
    }
    async fn create_annotation(&self, linked_file_id: String, annotation_type: String, page_number: i64, bounds_json: Option<String>, color: Option<String>, contents: Option<String>, selected_text: Option<String>) -> Option<AnnotationRecord> {
        self.store.create_annotation(linked_file_id, annotation_type, page_number, bounds_json, color, contents, selected_text)
            .map(|r| AnnotationRecord::from(&r))
            .map_err(|e| log("create_annotation", e))
            .ok()
    }
    async fn list_comments_for_item(&self, item_id: String) -> Vec<CommentRecord> {
        self.store.list_comments_for_item(item_id)
            .map(|rs| rs.iter().map(CommentRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("list_comments_for_item", e); vec![] })
    }
    async fn list_comments(&self, publication_id: String) -> Vec<CommentRecord> {
        self.store.list_comments(publication_id)
            .map(|rs| rs.iter().map(CommentRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("list_comments", e); vec![] })
    }
    async fn list_comments_since(&self, item_id: String, since_clock: u64) -> Vec<CommentRecord> {
        self.store.list_comments_since(item_id, since_clock)
            .map(|rs| rs.iter().map(CommentRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| { log("list_comments_since", e); vec![] })
    }
    async fn create_comment(&self, publication_id: String, text: String, author_identifier: Option<String>, author_display_name: Option<String>, parent_comment_id: Option<String>) -> Option<CommentRecord> {
        self.store.create_comment(publication_id, text, author_identifier, author_display_name, parent_comment_id)
            .map(|r| CommentRecord::from(&r))
            .map_err(|e| log("create_comment", e))
            .ok()
    }
    async fn create_comment_on_item(&self, item_id: String, text: String, author_identifier: Option<String>, author_display_name: Option<String>, parent_comment_id: Option<String>) -> Option<CommentRecord> {
        self.store.create_comment_on_item(item_id, text, author_identifier, author_display_name, parent_comment_id)
            .map(|r| CommentRecord::from(&r))
            .map_err(|e| log("create_comment_on_item", e))
            .ok()
    }
    async fn update_comment(&self, id: String, text: String) -> MutationResult {
        match self.store.update_comment(id, text) { Ok(_) => ok_n(1), Err(e) => { log("update_comment", e); fail() } }
    }
}

impress_service_impl! {
    service = ImbibAnnotationsService,
    impl = DefaultImbibAnnotationsService,
    instance = || crate::backend::annotations_service_instance(),
    methods = [
        list_annotations(linked_file_id: String, page_number: Option<i32>) -> Vec<AnnotationRecord>,
        count_annotations(linked_file_id: String) -> u32,
        create_annotation(linked_file_id: String, annotation_type: String, page_number: i64, bounds_json: Option<String>, color: Option<String>, contents: Option<String>, selected_text: Option<String>) -> Option<AnnotationRecord>,
        list_comments_for_item(item_id: String) -> Vec<CommentRecord>,
        list_comments(publication_id: String) -> Vec<CommentRecord>,
        list_comments_since(item_id: String, since_clock: u64) -> Vec<CommentRecord>,
        create_comment(publication_id: String, text: String, author_identifier: Option<String>, author_display_name: Option<String>, parent_comment_id: Option<String>) -> Option<CommentRecord>,
        create_comment_on_item(item_id: String, text: String, author_identifier: Option<String>, author_display_name: Option<String>, parent_comment_id: Option<String>) -> Option<CommentRecord>,
        update_comment(id: String, text: String) -> MutationResult,
    ],
}
