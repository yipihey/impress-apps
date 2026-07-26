//! HTTP-backed implementations of the seven imbib service traits.
//!
//! Each `Http*Service` is a thin adapter that forwards method calls to
//! `impress_app_client::ImbibClient` over HTTP. Install at process startup
//! via [`maybe_install_http_backend`] — if the imbib app is reachable on
//! its automation port, this registers the HTTP backend with imbib-service.
//! Otherwise imbib-service falls back to its default SQLite path.

use std::sync::Arc;

use impress_app_client::ImbibClient;

use imbib_service::annotations_service::{
    AnnotationRecord, CommentRecord, ImbibAnnotationsService,
};
use imbib_service::app_service::{
    ActivityEntry, AppStatus, ExternalPaper, ImbibAppService, LogEntry, SyncNudgeResult,
};
use imbib_service::artifacts_service::{
    ArtifactRecord, ArtifactRelationRecord, ImbibArtifactsService,
};
use imbib_service::library_service::{
    CollectionRecord, DismissedPaperRecord, ImbibLibraryService, ImportSummary, LibraryRecord,
    LinkedFileRecord, MutationResult, MutedItemRecord, PaperImport, PublicationDetailRecord,
    PublicationSummary,
};
use imbib_service::manuscripts_service::{
    CompileResult, ImbibManuscriptsService, ManuscriptRecord, TemplateRecord, WriteResult,
};
use imbib_service::scix_service::{ImbibScixService, SciXLibraryRecord};
use imbib_service::search_service::{ImbibSearchService, SmartSearchRecord};
use imbib_service::tags_service::{ImbibTagsService, TagRecord, TagWithCount};
use imbib_service::undo_service::{ImbibUndoService, UndoGroupRecord};
use imbib_service::ImbibBackend;

// Map the HTTP client's Result into the trait's plain return shape. The
// trait methods are typed as `T` (not `Result<T,E>`) so on HTTP failure we
// return an empty/default value and log to stderr — matching the existing
// SQLite-backed impls' behavior.
fn empty_mut() -> MutationResult {
    MutationResult {
        affected_count: 0,
        ok: false,
    }
}
fn log_err(method: &str, e: impl std::fmt::Display) {
    eprintln!("[imbib-service-http] {method}: {e}");
}

// =====================================================================
// HttpImbibLibraryService
// =====================================================================
pub struct HttpImbibLibraryService {
    client: Arc<ImbibClient>,
}
impl HttpImbibLibraryService {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImbibLibraryService for HttpImbibLibraryService {
    async fn list_libraries(&self) -> Vec<LibraryRecord> {
        self.client.list_libraries().await.unwrap_or_else(|e| {
            log_err("list_libraries", e);
            vec![]
        })
    }
    async fn create_library(&self, name: String) -> Option<LibraryRecord> {
        self.client
            .create_library(name)
            .await
            .map_err(|e| log_err("create_library", e))
            .ok()
    }
    async fn delete_library_undoable(&self, id: String) -> MutationResult {
        self.client
            .delete_library_undoable(id)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_library_undoable", e);
                empty_mut()
            })
    }
    async fn get_default_library(&self) -> Option<LibraryRecord> {
        self.client.get_default_library().await.unwrap_or_else(|e| {
            log_err("get_default_library", e);
            None
        })
    }
    async fn set_library_default(&self, id: String) -> MutationResult {
        self.client
            .set_library_default(id)
            .await
            .unwrap_or_else(|e| {
                log_err("set_library_default", e);
                empty_mut()
            })
    }
    async fn get_inbox_library(&self) -> Option<LibraryRecord> {
        self.client.get_inbox_library().await.unwrap_or_else(|e| {
            log_err("get_inbox_library", e);
            None
        })
    }
    async fn list_collections(&self, library_id: String) -> Vec<CollectionRecord> {
        self.client
            .list_collections(library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("list_collections", e);
                vec![]
            })
    }
    async fn create_collection(
        &self,
        name: String,
        library_id: String,
        is_smart: bool,
        query: Option<String>,
    ) -> Option<CollectionRecord> {
        self.client
            .create_collection(name, library_id, is_smart, query)
            .await
            .map_err(|e| log_err("create_collection", e))
            .ok()
    }
    async fn add_to_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> MutationResult {
        self.client
            .add_to_collection(publication_ids, collection_id)
            .await
            .unwrap_or_else(|e| {
                log_err("add_to_collection", e);
                empty_mut()
            })
    }
    async fn remove_from_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> MutationResult {
        self.client
            .remove_from_collection(publication_ids, collection_id)
            .await
            .unwrap_or_else(|e| {
                log_err("remove_from_collection", e);
                empty_mut()
            })
    }
    async fn list_collection_members(
        &self,
        collection_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<PublicationSummary> {
        self.client
            .list_collection_members(collection_id, sort_field, ascending, limit, offset)
            .await
            .unwrap_or_else(|e| {
                log_err("list_collection_members", e);
                vec![]
            })
    }
    async fn purge_dismissed_from_collection(&self, collection_id: String) -> MutationResult {
        self.client
            .purge_dismissed_from_collection(collection_id)
            .await
            .unwrap_or_else(|e| {
                log_err("purge_dismissed_from_collection", e);
                empty_mut()
            })
    }
    async fn list_publications(&self, limit: u32, offset: u32) -> Vec<PublicationSummary> {
        self.client
            .list_publications(limit, offset)
            .await
            .unwrap_or_else(|e| {
                log_err("list_publications", e);
                vec![]
            })
    }
    async fn query_publications(
        &self,
        library_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<PublicationSummary> {
        self.client
            .query_publications(library_id, sort_field, ascending, limit, offset)
            .await
            .unwrap_or_else(|e| {
                log_err("query_publications", e);
                vec![]
            })
    }
    async fn query_unread(
        &self,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: u32,
    ) -> Vec<PublicationSummary> {
        self.client
            .query_unread(parent_id, sort_field, ascending, limit)
            .await
            .unwrap_or_else(|e| {
                log_err("query_unread", e);
                vec![]
            })
    }
    async fn query_starred(
        &self,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: u32,
    ) -> Vec<PublicationSummary> {
        self.client
            .query_starred(parent_id, sort_field, ascending, limit)
            .await
            .unwrap_or_else(|e| {
                log_err("query_starred", e);
                vec![]
            })
    }
    async fn query_recent(&self, limit: u32, parent_id: Option<String>) -> Vec<PublicationSummary> {
        self.client
            .query_recent(limit, parent_id)
            .await
            .unwrap_or_else(|e| {
                log_err("query_recent", e);
                vec![]
            })
    }
    async fn search_publications(&self, query: String, limit: u32) -> Vec<PublicationSummary> {
        self.client
            .search_publications(query, limit)
            .await
            .unwrap_or_else(|e| {
                log_err("search_publications", e);
                vec![]
            })
    }
    async fn get_publication(&self, id: String) -> Option<PublicationSummary> {
        self.client.get_publication(id).await.unwrap_or_else(|e| {
            log_err("get_publication", e);
            None
        })
    }
    async fn get_publication_detail(&self, id: String) -> Option<PublicationDetailRecord> {
        self.client
            .get_publication_detail(id)
            .await
            .unwrap_or_else(|e| {
                log_err("get_publication_detail", e);
                None
            })
    }
    async fn count_publications(&self) -> u32 {
        self.client.count_publications().await.unwrap_or_else(|e| {
            log_err("count_publications", e);
            0
        })
    }
    async fn count_unread(&self, parent_id: Option<String>) -> u32 {
        self.client
            .count_unread(parent_id)
            .await
            .unwrap_or_else(|e| {
                log_err("count_unread", e);
                0
            })
    }
    async fn count_starred(&self, parent_id: Option<String>) -> u32 {
        self.client
            .count_starred(parent_id)
            .await
            .unwrap_or_else(|e| {
                log_err("count_starred", e);
                0
            })
    }
    async fn count_flagged(&self, color: Option<String>) -> u32 {
        self.client.count_flagged(color).await.unwrap_or_else(|e| {
            log_err("count_flagged", e);
            0
        })
    }
    async fn set_read(&self, ids: Vec<String>, read: bool) -> MutationResult {
        self.client.set_read(ids, read).await.unwrap_or_else(|e| {
            log_err("set_read", e);
            empty_mut()
        })
    }
    async fn set_starred(&self, ids: Vec<String>, starred: bool) -> MutationResult {
        self.client
            .set_starred(ids, starred)
            .await
            .unwrap_or_else(|e| {
                log_err("set_starred", e);
                empty_mut()
            })
    }
    async fn set_flag(&self, ids: Vec<String>, color: Option<String>) -> MutationResult {
        self.client.set_flag(ids, color).await.unwrap_or_else(|e| {
            log_err("set_flag", e);
            empty_mut()
        })
    }
    async fn delete_publications_undoable(&self, ids: Vec<String>) -> MutationResult {
        self.client
            .delete_publications_undoable(ids)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_publications_undoable", e);
                empty_mut()
            })
    }
    async fn move_publications(
        &self,
        publication_ids: Vec<String>,
        to_library_id: String,
    ) -> MutationResult {
        self.client
            .move_publications(publication_ids, to_library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("move_publications", e);
                empty_mut()
            })
    }
    async fn duplicate_publications(&self, ids: Vec<String>, to_library_id: String) -> Vec<String> {
        self.client
            .duplicate_publications(ids, to_library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("duplicate_publications", e);
                vec![]
            })
    }
    async fn deduplicate_library(&self, library_id: String) -> u32 {
        self.client
            .deduplicate_library(library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("deduplicate_library", e);
                0
            })
    }
    async fn dismiss_paper(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> Option<DismissedPaperRecord> {
        self.client
            .dismiss_paper(doi, arxiv_id, bibcode, cite_key)
            .await
            .unwrap_or_else(|e| {
                log_err("dismiss_paper", e);
                None
            })
    }
    async fn is_paper_dismissed(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> bool {
        self.client
            .is_paper_dismissed(doi, arxiv_id, bibcode, cite_key)
            .await
            .unwrap_or_else(|e| {
                log_err("is_paper_dismissed", e);
                false
            })
    }
    async fn list_dismissed_papers(&self, limit: u32, offset: u32) -> Vec<DismissedPaperRecord> {
        self.client
            .list_dismissed_papers(limit, offset)
            .await
            .unwrap_or_else(|e| {
                log_err("list_dismissed_papers", e);
                vec![]
            })
    }
    async fn list_muted_items(&self) -> Vec<MutedItemRecord> {
        self.client.list_muted_items().await.unwrap_or_else(|e| {
            log_err("list_muted_items", e);
            vec![]
        })
    }
    async fn create_muted_item(&self, mute_type: String, value: String) -> Option<MutedItemRecord> {
        self.client
            .create_muted_item(mute_type, value)
            .await
            .unwrap_or_else(|e| {
                log_err("create_muted_item", e);
                None
            })
    }
    async fn import_papers(&self, papers: Vec<PaperImport>, library_id: String) -> ImportSummary {
        self.client
            .import_papers(papers, library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("import_papers", e);
                ImportSummary {
                    imported_ids: vec![],
                    existing_ids: vec![],
                    dismissed_count: 0,
                    failed_count: 0,
                }
            })
    }
    async fn import_bibtex(&self, bibtex: String, library_id: String) -> Vec<String> {
        self.client
            .import_bibtex(bibtex, library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("import_bibtex", e);
                vec![]
            })
    }
    async fn export_bibtex(&self, ids: Vec<String>) -> String {
        self.client.export_bibtex(ids).await.unwrap_or_else(|e| {
            log_err("export_bibtex", e);
            String::new()
        })
    }
    async fn export_all_bibtex(&self, library_id: String) -> String {
        self.client
            .export_all_bibtex(library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("export_all_bibtex", e);
                String::new()
            })
    }
    async fn list_linked_files(&self, publication_id: String) -> Vec<LinkedFileRecord> {
        self.client
            .list_linked_files(publication_id)
            .await
            .unwrap_or_else(|e| {
                log_err("list_linked_files", e);
                vec![]
            })
    }
    async fn count_pdfs(&self, publication_id: String) -> u32 {
        self.client
            .count_pdfs(publication_id)
            .await
            .unwrap_or_else(|e| {
                log_err("count_pdfs", e);
                0
            })
    }
    async fn add_linked_file(
        &self,
        publication_id: String,
        filename: String,
        relative_path: Option<String>,
        file_type: Option<String>,
        file_size: i64,
        sha256: Option<String>,
        is_pdf: bool,
    ) -> Option<LinkedFileRecord> {
        self.client
            .add_linked_file(
                publication_id,
                filename,
                relative_path,
                file_type,
                file_size,
                sha256,
                is_pdf,
            )
            .await
            .unwrap_or_else(|e| {
                log_err("add_linked_file", e);
                None
            })
    }
}

// =====================================================================
// HttpImbibTagsService
// =====================================================================
pub struct HttpImbibTagsService {
    client: Arc<ImbibClient>,
}
impl HttpImbibTagsService {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImbibTagsService for HttpImbibTagsService {
    async fn list_tags(&self) -> Vec<TagRecord> {
        self.client.list_tags().await.unwrap_or_else(|e| {
            log_err("list_tags", e);
            vec![]
        })
    }
    async fn list_tags_with_counts(&self) -> Vec<TagWithCount> {
        self.client
            .list_tags_with_counts()
            .await
            .unwrap_or_else(|e| {
                log_err("list_tags_with_counts", e);
                vec![]
            })
    }
    async fn create_tag(
        &self,
        path: String,
        color_light: Option<String>,
        color_dark: Option<String>,
    ) -> MutationResult {
        self.client
            .create_tag(path, color_light, color_dark)
            .await
            .unwrap_or_else(|e| {
                log_err("create_tag", e);
                empty_mut()
            })
    }
    async fn delete_tag_undoable(&self, path: String) -> MutationResult {
        self.client
            .delete_tag_undoable(path)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_tag_undoable", e);
                empty_mut()
            })
    }
    async fn update_tag(
        &self,
        path: String,
        color_light: Option<String>,
        color_dark: Option<String>,
    ) -> MutationResult {
        self.client
            .update_tag(path, color_light, color_dark)
            .await
            .unwrap_or_else(|e| {
                log_err("update_tag", e);
                empty_mut()
            })
    }
    async fn rename_tag(&self, old_path: String, new_path: String) -> MutationResult {
        self.client
            .rename_tag(old_path, new_path)
            .await
            .unwrap_or_else(|e| {
                log_err("rename_tag", e);
                empty_mut()
            })
    }
    async fn add_tag(&self, ids: Vec<String>, tag_path: String) -> MutationResult {
        self.client
            .add_tag(ids, tag_path)
            .await
            .unwrap_or_else(|e| {
                log_err("add_tag", e);
                empty_mut()
            })
    }
    async fn remove_tag(&self, ids: Vec<String>, tag_path: String) -> MutationResult {
        self.client
            .remove_tag(ids, tag_path)
            .await
            .unwrap_or_else(|e| {
                log_err("remove_tag", e);
                empty_mut()
            })
    }
    async fn query_by_tag(
        &self,
        tag_path: String,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: u32,
    ) -> Vec<PublicationSummary> {
        self.client
            .query_by_tag(tag_path, parent_id, sort_field, ascending, limit)
            .await
            .unwrap_or_else(|e| {
                log_err("query_by_tag", e);
                vec![]
            })
    }
    async fn count_by_tag(&self, tag_path: String, parent_id: Option<String>) -> u32 {
        self.client
            .count_by_tag(tag_path, parent_id)
            .await
            .unwrap_or_else(|e| {
                log_err("count_by_tag", e);
                0
            })
    }
}

// =====================================================================
// HttpImbibSearchService
// =====================================================================
pub struct HttpImbibSearchService {
    client: Arc<ImbibClient>,
}
impl HttpImbibSearchService {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImbibSearchService for HttpImbibSearchService {
    async fn find_by_cite_key(
        &self,
        cite_key: String,
        library_id: Option<String>,
    ) -> Option<PublicationSummary> {
        self.client
            .find_by_cite_key(cite_key, library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("find_by_cite_key", e);
                None
            })
    }
    async fn find_by_doi(&self, doi: String) -> Vec<PublicationSummary> {
        self.client.find_by_doi(doi).await.unwrap_or_else(|e| {
            log_err("find_by_doi", e);
            vec![]
        })
    }
    async fn find_by_arxiv(&self, arxiv_id: String) -> Vec<PublicationSummary> {
        self.client
            .find_by_arxiv(arxiv_id)
            .await
            .unwrap_or_else(|e| {
                log_err("find_by_arxiv", e);
                vec![]
            })
    }
    async fn find_by_bibcode(&self, bibcode: String) -> Vec<PublicationSummary> {
        self.client
            .find_by_bibcode(bibcode)
            .await
            .unwrap_or_else(|e| {
                log_err("find_by_bibcode", e);
                vec![]
            })
    }
    async fn find_by_identifiers_batch(
        &self,
        dois: Vec<String>,
        arxiv_ids: Vec<String>,
        bibcodes: Vec<String>,
    ) -> Vec<PublicationSummary> {
        self.client
            .find_by_identifiers_batch(dois, arxiv_ids, bibcodes)
            .await
            .unwrap_or_else(|e| {
                log_err("find_by_identifiers_batch", e);
                vec![]
            })
    }
    async fn full_text_search(
        &self,
        query: String,
        parent_id: Option<String>,
        limit: u32,
    ) -> Vec<PublicationSummary> {
        self.client
            .full_text_search(query, parent_id, limit)
            .await
            .unwrap_or_else(|e| {
                log_err("full_text_search", e);
                vec![]
            })
    }
    async fn list_smart_searches(&self, library_id: Option<String>) -> Vec<SmartSearchRecord> {
        self.client
            .list_smart_searches(library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("list_smart_searches", e);
                vec![]
            })
    }
    async fn get_smart_search(&self, id: String) -> Option<SmartSearchRecord> {
        self.client.get_smart_search(id).await.unwrap_or_else(|e| {
            log_err("get_smart_search", e);
            None
        })
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
        self.client
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
            .await
            .unwrap_or_else(|e| {
                log_err("create_smart_search", e);
                None
            })
    }
}

// =====================================================================
// HttpImbibUndoService
// =====================================================================
pub struct HttpImbibUndoService {
    client: Arc<ImbibClient>,
}
impl HttpImbibUndoService {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImbibUndoService for HttpImbibUndoService {
    async fn recent_undo_groups(&self, max_entries: u32) -> Vec<UndoGroupRecord> {
        self.client
            .recent_undo_groups(max_entries)
            .await
            .unwrap_or_else(|e| {
                log_err("recent_undo_groups", e);
                vec![]
            })
    }
    async fn undo_operation(&self, operation_id: String) -> MutationResult {
        self.client
            .undo_operation(operation_id)
            .await
            .unwrap_or_else(|e| {
                log_err("undo_operation", e);
                empty_mut()
            })
    }
    async fn undo_batch(&self, batch_id: String) -> MutationResult {
        self.client.undo_batch(batch_id).await.unwrap_or_else(|e| {
            log_err("undo_batch", e);
            empty_mut()
        })
    }
}

// =====================================================================
// HttpImbibAnnotationsService
// =====================================================================
pub struct HttpImbibAnnotationsService {
    client: Arc<ImbibClient>,
}
impl HttpImbibAnnotationsService {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImbibAnnotationsService for HttpImbibAnnotationsService {
    async fn list_annotations(
        &self,
        linked_file_id: String,
        page_number: Option<i32>,
    ) -> Vec<AnnotationRecord> {
        self.client
            .list_annotations(linked_file_id, page_number)
            .await
            .unwrap_or_else(|e| {
                log_err("list_annotations", e);
                vec![]
            })
    }
    async fn count_annotations(&self, linked_file_id: String) -> u32 {
        self.client
            .count_annotations(linked_file_id)
            .await
            .unwrap_or_else(|e| {
                log_err("count_annotations", e);
                0
            })
    }
    async fn create_annotation(
        &self,
        linked_file_id: String,
        annotation_type: String,
        page_number: i64,
        bounds_json: Option<String>,
        color: Option<String>,
        contents: Option<String>,
        selected_text: Option<String>,
    ) -> Option<AnnotationRecord> {
        self.client
            .create_annotation(
                linked_file_id,
                annotation_type,
                page_number,
                bounds_json,
                color,
                contents,
                selected_text,
            )
            .await
            .unwrap_or_else(|e| {
                log_err("create_annotation", e);
                None
            })
    }
    async fn list_comments_for_item(&self, item_id: String) -> Vec<CommentRecord> {
        self.client
            .list_comments_for_item(item_id)
            .await
            .unwrap_or_else(|e| {
                log_err("list_comments_for_item", e);
                vec![]
            })
    }
    async fn list_comments(&self, publication_id: String) -> Vec<CommentRecord> {
        self.client
            .list_comments(publication_id)
            .await
            .unwrap_or_else(|e| {
                log_err("list_comments", e);
                vec![]
            })
    }
    async fn list_comments_since(&self, item_id: String, since_clock: u64) -> Vec<CommentRecord> {
        self.client
            .list_comments_since(item_id, since_clock)
            .await
            .unwrap_or_else(|e| {
                log_err("list_comments_since", e);
                vec![]
            })
    }
    async fn create_comment(
        &self,
        publication_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Option<CommentRecord> {
        self.client
            .create_comment(
                publication_id,
                text,
                author_identifier,
                author_display_name,
                parent_comment_id,
            )
            .await
            .unwrap_or_else(|e| {
                log_err("create_comment", e);
                None
            })
    }
    async fn create_comment_on_item(
        &self,
        item_id: String,
        text: String,
        author_identifier: Option<String>,
        author_display_name: Option<String>,
        parent_comment_id: Option<String>,
    ) -> Option<CommentRecord> {
        self.client
            .create_comment_on_item(
                item_id,
                text,
                author_identifier,
                author_display_name,
                parent_comment_id,
            )
            .await
            .unwrap_or_else(|e| {
                log_err("create_comment_on_item", e);
                None
            })
    }
    async fn update_comment(&self, id: String, text: String) -> MutationResult {
        self.client
            .update_comment(id, text)
            .await
            .unwrap_or_else(|e| {
                log_err("update_comment", e);
                empty_mut()
            })
    }
}

// =====================================================================
// HttpImbibArtifactsService
// =====================================================================
pub struct HttpImbibArtifactsService {
    client: Arc<ImbibClient>,
}
impl HttpImbibArtifactsService {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImbibArtifactsService for HttpImbibArtifactsService {
    async fn list_artifacts(
        &self,
        schema_filter: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<ArtifactRecord> {
        self.client
            .list_artifacts(schema_filter, sort_field, ascending, limit, offset)
            .await
            .unwrap_or_else(|e| {
                log_err("list_artifacts", e);
                vec![]
            })
    }
    async fn search_artifacts(
        &self,
        query: String,
        schema_filter: Option<String>,
    ) -> Vec<ArtifactRecord> {
        self.client
            .search_artifacts(query, schema_filter)
            .await
            .unwrap_or_else(|e| {
                log_err("search_artifacts", e);
                vec![]
            })
    }
    async fn get_artifact(&self, id: String) -> Option<ArtifactRecord> {
        self.client.get_artifact(id).await.unwrap_or_else(|e| {
            log_err("get_artifact", e);
            None
        })
    }
    async fn count_artifacts(&self, schema_filter: Option<String>) -> u32 {
        self.client
            .count_artifacts(schema_filter)
            .await
            .unwrap_or_else(|e| {
                log_err("count_artifacts", e);
                0
            })
    }
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
    ) -> Option<ArtifactRecord> {
        self.client
            .create_artifact(
                schema,
                title,
                source_url,
                notes,
                artifact_subtype,
                file_name,
                file_hash,
                file_size,
                file_mime_type,
                capture_context,
                original_author,
                event_name,
                event_date,
                tags,
            )
            .await
            .unwrap_or_else(|e| {
                log_err("create_artifact", e);
                None
            })
    }
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
    ) -> MutationResult {
        self.client
            .update_artifact(
                id,
                title,
                source_url,
                notes,
                artifact_subtype,
                capture_context,
                original_author,
                event_name,
                event_date,
            )
            .await
            .unwrap_or_else(|e| {
                log_err("update_artifact", e);
                empty_mut()
            })
    }
    async fn delete_artifact(&self, id: String) -> MutationResult {
        self.client.delete_artifact(id).await.unwrap_or_else(|e| {
            log_err("delete_artifact", e);
            empty_mut()
        })
    }
    async fn link_artifact_to_publication(
        &self,
        artifact_id: String,
        publication_id: String,
    ) -> MutationResult {
        self.client
            .link_artifact_to_publication(artifact_id, publication_id)
            .await
            .unwrap_or_else(|e| {
                log_err("link_artifact_to_publication", e);
                empty_mut()
            })
    }
    async fn get_artifact_relations(&self, id: String) -> Vec<ArtifactRelationRecord> {
        self.client
            .get_artifact_relations(id)
            .await
            .unwrap_or_else(|e| {
                log_err("get_artifact_relations", e);
                vec![]
            })
    }
}

// =====================================================================
// HttpImbibScixService
// =====================================================================
pub struct HttpImbibScixService {
    client: Arc<ImbibClient>,
}
impl HttpImbibScixService {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImbibScixService for HttpImbibScixService {
    async fn list_scix_libraries(&self) -> Vec<SciXLibraryRecord> {
        self.client.list_scix_libraries().await.unwrap_or_else(|e| {
            log_err("list_scix_libraries", e);
            vec![]
        })
    }
    async fn get_scix_library(&self, id: String) -> Option<SciXLibraryRecord> {
        self.client.get_scix_library(id).await.unwrap_or_else(|e| {
            log_err("get_scix_library", e);
            None
        })
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
        self.client
            .create_scix_library(
                remote_id,
                name,
                description,
                is_public,
                permission_level,
                owner_email,
            )
            .await
            .unwrap_or_else(|e| {
                log_err("create_scix_library", e);
                None
            })
    }
    async fn add_to_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> MutationResult {
        self.client
            .add_to_scix_library(publication_ids, scix_library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("add_to_scix_library", e);
                empty_mut()
            })
    }
    async fn remove_from_scix_library(
        &self,
        publication_ids: Vec<String>,
        scix_library_id: String,
    ) -> MutationResult {
        self.client
            .remove_from_scix_library(publication_ids, scix_library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("remove_from_scix_library", e);
                empty_mut()
            })
    }
    async fn query_scix_library_publications(
        &self,
        scix_library_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<PublicationSummary> {
        self.client
            .query_scix_library_publications(scix_library_id, sort_field, ascending, limit, offset)
            .await
            .unwrap_or_else(|e| {
                log_err("query_scix_library_publications", e);
                vec![]
            })
    }
    async fn count_scix_library_publications(&self, scix_library_id: String) -> u32 {
        self.client
            .count_scix_library_publications(scix_library_id)
            .await
            .unwrap_or_else(|e| {
                log_err("count_scix_library_publications", e);
                0
            })
    }
}

// =====================================================================
// Backend bundle + installer
// =====================================================================

// ---------------------------------------------------------------------------
// ImbibAppService — capabilities that only exist while imbib is running
// ---------------------------------------------------------------------------

pub struct HttpImbibAppService {
    client: Arc<ImbibClient>,
}

impl HttpImbibAppService {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImbibAppService for HttpImbibAppService {
    async fn search_sources(
        &self,
        query: String,
        sources: Option<String>,
        limit: u32,
    ) -> Vec<ExternalPaper> {
        self.client
            .search_sources(query, sources, limit)
            .await
            .unwrap_or_else(|e| {
                log_err("search_sources", e);
                vec![]
            })
    }

    async fn recent_activity(&self, limit: u32, parent_id: Option<String>) -> Vec<ActivityEntry> {
        self.client
            .recent_activity(limit, parent_id)
            .await
            .unwrap_or_else(|e| {
                log_err("recent_activity", e);
                vec![]
            })
    }

    async fn download_pdfs(&self, publication_ids: Vec<String>) -> u32 {
        self.client
            .download_pdfs(publication_ids)
            .await
            .unwrap_or_else(|e| {
                log_err("download_pdfs", e);
                0
            })
    }

    async fn sync_nudge(&self) -> SyncNudgeResult {
        self.client.sync_nudge().await.unwrap_or_else(|e| {
            // A transport failure is not the same as the engine declining, so
            // say which one happened rather than reporting a bare `false`.
            let reason = format!("could not reach imbib's sync endpoint: {e}");
            log_err("sync_nudge", e);
            SyncNudgeResult {
                accepted: false,
                reason: Some(reason),
            }
        })
    }

    async fn sync_status(&self) -> AppStatus {
        self.client.sync_status_raw().await.unwrap_or_else(|e| {
            let detail = format!("could not read sync status: {e}");
            log_err("sync_status", e);
            AppStatus {
                running: false,
                detail,
            }
        })
    }

    async fn status(&self) -> AppStatus {
        self.client.app_status_raw().await.unwrap_or_else(|e| {
            let detail = format!("imbib did not answer: {e}");
            log_err("status", e);
            AppStatus {
                running: false,
                detail,
            }
        })
    }

    async fn get_logs(
        &self,
        limit: u32,
        level: Option<String>,
        category: Option<String>,
        search: Option<String>,
    ) -> Vec<LogEntry> {
        self.client
            .get_logs(limit, level, category, search)
            .await
            .unwrap_or_else(|e| {
                log_err("get_logs", e);
                vec![]
            })
    }

    async fn get_notes(&self, cite_key: String) -> Option<String> {
        self.client.get_notes(&cite_key).await.unwrap_or_else(|e| {
            log_err("get_notes", e);
            None
        })
    }
    async fn update_notes(&self, cite_key: String, notes: String) -> bool {
        self.client
            .update_notes(&cite_key, notes)
            .await
            .map(|r| r.ok)
            .unwrap_or_else(|e| {
                log_err("update_notes", e);
                false
            })
    }
    async fn delete_annotation(&self, annotation_id: String) -> bool {
        self.client
            .delete_annotation(&annotation_id)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_annotation", e);
                false
            })
    }
    async fn delete_comment(&self, comment_id: String) -> bool {
        self.client
            .delete_comment(&comment_id)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_comment", e);
                false
            })
    }
    async fn delete_collection(&self, collection_id: String) -> bool {
        self.client
            .delete_collection(&collection_id)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_collection", e);
                false
            })
    }
    async fn delete_smart_searches(&self, ids: Vec<String>) -> u32 {
        self.client
            .delete_smart_searches(ids)
            .await
            .unwrap_or_else(|e| {
                log_err("delete_smart_searches", e);
                0
            })
    }
    async fn tag_artifact(&self, artifact_id: String, tags: Vec<String>) -> bool {
        self.client
            .tag_artifact(&artifact_id, tags)
            .await
            .unwrap_or_else(|e| {
                log_err("tag_artifact", e);
                false
            })
    }
    async fn resolve_identifier(&self, identifier: String, download_pdfs: bool) -> Option<String> {
        // The resolved paper's cite key is the useful handle: every other tool
        // takes one, and returning the whole record here would duplicate
        // get-publication-detail.
        self.client
            .resolve_identifier(identifier, download_pdfs)
            .await
            .unwrap_or_else(|e| {
                log_err("resolve_identifier", e);
                None
            })
            .map(|p| p.cite_key)
    }
    async fn add_to_library(&self, publication_ids: Vec<String>, library_id: String) -> u32 {
        self.client
            .add_to_library(publication_ids, library_id)
            .await
            .map(|r| r.affected_count)
            .unwrap_or_else(|e| {
                log_err("add_to_library", e);
                0
            })
    }
}

// ---------------------------------------------------------------------------
// ImbibManuscriptsService
// ---------------------------------------------------------------------------

pub struct HttpImbibManuscriptsService {
    client: Arc<ImbibClient>,
}

impl HttpImbibManuscriptsService {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

#[async_trait::async_trait]
impl ImbibManuscriptsService for HttpImbibManuscriptsService {
    async fn list_manuscripts(&self) -> Vec<ManuscriptRecord> {
        self.client.list_manuscripts().await.unwrap_or_else(|e| {
            log_err("list_manuscripts", e);
            vec![]
        })
    }
    async fn get_manuscript(&self, manuscript_id: String) -> Option<ManuscriptRecord> {
        self.client
            .get_manuscript(&manuscript_id)
            .await
            .unwrap_or_else(|e| {
                log_err("get_manuscript", e);
                None
            })
    }
    async fn create_manuscript(
        &self,
        title: String,
        format: Option<String>,
    ) -> Option<ManuscriptRecord> {
        self.client
            .create_manuscript(title, format)
            .await
            .unwrap_or_else(|e| {
                log_err("create_manuscript", e);
                None
            })
    }
    async fn write_manuscript_body(
        &self,
        manuscript_id: String,
        body: String,
        expected_hash: String,
    ) -> WriteResult {
        self.client
            .write_manuscript_body(&manuscript_id, body, expected_hash)
            .await
            .unwrap_or_else(|e| {
                let message = format!("could not write the manuscript: {e}");
                log_err("write_manuscript_body", e);
                WriteResult {
                    ok: false,
                    content_hash: None,
                    message,
                }
            })
    }
    async fn compile_manuscript(&self, manuscript_id: String) -> CompileResult {
        self.client
            .compile_manuscript(&manuscript_id)
            .await
            .unwrap_or_else(|e| {
                let msg = format!("compile request failed: {e}");
                log_err("compile_manuscript", e);
                CompileResult {
                    ok: false,
                    pdf_path: None,
                    page_count: None,
                    messages: vec![msg],
                }
            })
    }
    async fn list_templates(&self) -> Vec<TemplateRecord> {
        self.client.list_templates().await.unwrap_or_else(|e| {
            log_err("list_templates", e);
            vec![]
        })
    }
    async fn create_manuscript_from_template(
        &self,
        template_id: String,
        title: String,
    ) -> Option<ManuscriptRecord> {
        self.client
            .create_manuscript_from_template(template_id, title)
            .await
            .unwrap_or_else(|e| {
                log_err("create_manuscript_from_template", e);
                None
            })
    }
}

pub struct HttpBackend {
    client: Arc<ImbibClient>,
}

impl HttpBackend {
    pub fn new(client: Arc<ImbibClient>) -> Self {
        Self { client }
    }
}

impl ImbibBackend for HttpBackend {
    fn library(&self) -> Arc<dyn ImbibLibraryService> {
        Arc::new(HttpImbibLibraryService::new(self.client.clone()))
    }
    fn tags(&self) -> Arc<dyn ImbibTagsService> {
        Arc::new(HttpImbibTagsService::new(self.client.clone()))
    }
    fn search(&self) -> Arc<dyn ImbibSearchService> {
        Arc::new(HttpImbibSearchService::new(self.client.clone()))
    }
    fn undo(&self) -> Arc<dyn ImbibUndoService> {
        Arc::new(HttpImbibUndoService::new(self.client.clone()))
    }
    fn annotations(&self) -> Arc<dyn ImbibAnnotationsService> {
        Arc::new(HttpImbibAnnotationsService::new(self.client.clone()))
    }
    fn artifacts(&self) -> Arc<dyn ImbibArtifactsService> {
        Arc::new(HttpImbibArtifactsService::new(self.client.clone()))
    }
    fn manuscripts(&self) -> Arc<dyn ImbibManuscriptsService> {
        Arc::new(HttpImbibManuscriptsService::new(self.client.clone()))
    }
    fn app(&self) -> Arc<dyn ImbibAppService> {
        Arc::new(HttpImbibAppService::new(self.client.clone()))
    }
    fn scix(&self) -> Arc<dyn ImbibScixService> {
        Arc::new(HttpImbibScixService::new(self.client.clone()))
    }
}

/// Probe the imbib HTTP server at the default port. If reachable, install
/// the HTTP backend so all subsequent imbib-service trait calls route via
/// HTTP instead of opening SQLite directly. Returns `true` on install.
///
/// Honors env vars:
/// * `IMBIB_BACKEND` = `http` (force HTTP — error if unreachable),
///   `sqlite` (skip probe), or `auto` (default — probe & install if up).
/// * `IMBIB_HTTP_URL` overrides the default `http://localhost:23120`.
pub fn maybe_install_http_backend() -> bool {
    let mode = std::env::var("IMBIB_BACKEND").unwrap_or_else(|_| "auto".into());
    if mode == "sqlite" {
        eprintln!("[imbib-service-http] IMBIB_BACKEND=sqlite — skipping HTTP probe");
        return false;
    }

    let base_url = std::env::var("IMBIB_HTTP_URL")
        .ok()
        .and_then(|s| url::Url::parse(&s).ok());
    let client = match base_url {
        Some(u) => Arc::new(ImbibClient::with_base_url(u)),
        None => Arc::new(ImbibClient::new()),
    };

    // Run a 1-second probe synchronously on a small runtime so this can be
    // called from a sync `main()`.
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("tokio current_thread runtime");

    let info = rt.block_on(client.probe());
    match info {
        Some(info) => {
            eprintln!(
                "[imbib-service-http] imbib HTTP reachable ({} libs, {} collections, port {:?}); using HTTP backend",
                info.library_count.unwrap_or(0),
                info.collection_count.unwrap_or(0),
                info.server_port,
            );
            imbib_service::register_backend(Box::new(HttpBackend::new(client)));
            true
        }
        None => {
            if mode == "http" {
                eprintln!(
                    "[imbib-service-http] IMBIB_BACKEND=http but imbib HTTP unreachable; service calls will fail."
                );
            } else {
                eprintln!(
                    "[imbib-service-http] imbib HTTP unreachable; falling back to SQLite backend (may fail due to TCC)."
                );
            }
            false
        }
    }
}
