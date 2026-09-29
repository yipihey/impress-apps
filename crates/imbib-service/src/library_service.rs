//! `ImbibLibraryService` — library / collection / paper CRUD + queries,
//! paper-level mutations, linked files, and BibTeX I/O.
//!
//! Tag-specific operations live in `tags_service`. Identifier lookups and
//! smart searches live in `search_service`. Undo lives in `undo_service`.

use std::sync::Arc;

pub use imbib_core::unified::shaped_queries::BibtexImportOutcome;
use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_core::pipeline::context::report_refusal;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Deserializer, Serialize};

pub use crate::app_service::IdentifierImportResult;

/// Accept `authors` as either a `String` (`/api/papers/recent` shape) or a
/// `Vec<String>` (`/api/search` shape) and produce a "; "-joined display
/// string. Returns an empty string for null / missing.
fn deserialize_authors_string_or_vec<'de, D>(d: D) -> Result<String, D::Error>
where
    D: Deserializer<'de>,
{
    use serde::de::Error;
    let v = serde_json::Value::deserialize(d)?;
    match v {
        serde_json::Value::String(s) => Ok(s),
        serde_json::Value::Array(arr) => {
            let parts: Vec<String> = arr
                .into_iter()
                .map(|x| match x {
                    serde_json::Value::String(s) => s,
                    other => other.to_string(),
                })
                .collect();
            Ok(parts.join("; "))
        }
        serde_json::Value::Null => Ok(String::new()),
        other => Err(D::Error::custom(format!(
            "expected string or array for authors, got {}",
            other
        ))),
    }
}

#[allow(unused_imports)]
use impress_service_macros::impress_method;

// ===========================================================================
// DTOs
// ===========================================================================

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct PublicationSummary {
    pub id: String,
    #[serde(alias = "citeKey", default)]
    pub cite_key: String,
    #[serde(default)]
    pub title: String,
    // Real imbib returns `authors` as a `Vec<String>` from /api/search but a
    // single joined `String` from /api/papers/recent. The custom deserializer
    // below accepts either shape and produces a "; "-joined display string.
    #[serde(
        alias = "authorString",
        alias = "author",
        default,
        deserialize_with = "deserialize_authors_string_or_vec"
    )]
    pub authors: String,
    #[serde(default)]
    pub year: Option<i32>,
    #[serde(default)]
    pub venue: Option<String>,
    #[serde(default)]
    pub doi: Option<String>,
    #[serde(alias = "arxivID", alias = "arxivId", default)]
    pub arxiv_id: Option<String>,
    #[serde(alias = "isRead", default)]
    pub is_read: bool,
    #[serde(alias = "isStarred", default)]
    pub is_starred: bool,
    #[serde(alias = "flagColor", default)]
    pub flag_color: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    // Real imbib uses `hasDownloadedPDF`; our internal Default impl emits
    // `has_pdf`. Accept either.
    #[serde(alias = "hasDownloadedPDF", alias = "hasPDF", default)]
    pub has_pdf: bool,
    /// State on the configured e-ink tablet, when a device in individual
    /// mode is configured; see `BibliographyRow::eink_state`.
    #[serde(alias = "einkState", default)]
    pub eink_state: Option<String>,
    /// When the USER last viewed or hand-added this paper, ms since the epoch,
    /// or null if never. This is the field `sort_field = "last_activity"`
    /// orders by ("Recently Used" in imbib's sort menu), so a caller that asks
    /// for that order can see what produced it — automated ingest never writes
    /// it, which is what makes it the user's own trail.
    #[serde(alias = "lastActivityAt", default)]
    pub last_activity_at: Option<i64>,
}

impl From<&imbib_core::unified::shaped_queries::BibliographyRow> for PublicationSummary {
    fn from(r: &imbib_core::unified::shaped_queries::BibliographyRow) -> Self {
        Self {
            id: r.id.clone(),
            cite_key: r.cite_key.clone(),
            title: r.title.clone(),
            authors: r.author_string.clone(),
            year: r.year,
            venue: r.venue.clone(),
            doi: r.doi.clone(),
            arxiv_id: r.arxiv_id.clone(),
            is_read: r.is_read,
            is_starred: r.is_starred,
            flag_color: r.flag_color.clone(),
            tags: r.tags.iter().map(|t| t.path.clone()).collect(),
            has_pdf: r.has_downloaded_pdf,
            eink_state: r.eink_state.clone(),
            last_activity_at: r.last_activity_at,
        }
    }
}

/// Optional filters for the local publication search. Library and collection
/// are UUID strings because those are the identifiers accepted by imbib's
/// HTTP search route.
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct PublicationSearchFilters {
    pub read: Option<bool>,
    pub collection: Option<String>,
    pub library: Option<String>,
    pub tags: Option<Vec<String>>,
    pub flag: Option<String>,
    pub added_after: Option<String>,
    pub added_before: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct MutationResult {
    pub affected_count: u32,
    pub ok: bool,
}

/// Per-identifier outcome for a collection membership update.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollectionMembershipResult {
    pub assigned: Vec<String>,
    pub not_found: Vec<String>,
}

/// Per-identifier outcome for filing existing papers into a library.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LibraryMembershipResult {
    pub assigned: Vec<String>,
    pub not_found: Vec<String>,
}

/// What `retention_cleanup` removed, per source (plan W3 / D-R10). Each
/// count is papers or searches actually removed; a `0` for a source that
/// found nothing to remove is not distinguishable from a source that was
/// skipped (`0` thresholds skip a source outright — see the method's doc).
#[derive(Debug, Clone, Default, Serialize, Deserialize, schemars::JsonSchema)]
pub struct RetentionCleanupReport {
    /// Inbox papers removed: past `imbib.retention.inbox_days`, or read
    /// when `imbib.retention.auto_remove_read` is on. Starred papers are
    /// never counted, whatever their age.
    pub inbox_removed: u32,
    /// Papers removed from smart-search feed collections that carry their
    /// own per-collection `retention_days`. Starred papers are never
    /// counted.
    pub feed_removed: u32,
    /// Exploration smart searches removed: executed, and past
    /// `imbib.retention.exploration_days`. Only runs when the caller passes
    /// `exploration_library_id` — see the method's doc for why.
    pub exploration_removed: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LibraryRecord {
    pub id: String,
    pub name: String,
    // The older HTTP records used camelCase (`isDefault`, `isInbox`,
    // `paperCount`); the SQLite-backed implementation emits snake_case.
    // Accept both for existing serialized records and fixtures.
    #[serde(alias = "isDefault", default)]
    pub is_default: bool,
    // create-library response omits isInbox — default to false.
    #[serde(alias = "isInbox", default)]
    pub is_inbox: bool,
    #[serde(alias = "paperCount", default)]
    pub publication_count: i32,
    #[serde(alias = "collectionCount", default)]
    pub collection_count: u64,
    /// Local imbib libraries are editable. Read-only SciX libraries use a
    /// separate schema and are not returned by this local-library service.
    #[serde(alias = "canEdit", default = "default_can_edit")]
    pub can_edit: bool,
}

fn default_can_edit() -> bool {
    true
}

impl LibraryRecord {
    fn from_row(
        r: &imbib_core::unified::shaped_queries::LibraryRow,
        collection_count: usize,
    ) -> Self {
        Self {
            id: r.id.clone(),
            name: r.name.clone(),
            is_default: r.is_default,
            is_inbox: r.is_inbox,
            publication_count: r.publication_count,
            collection_count: collection_count as u64,
            can_edit: true,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct PaperImport {
    pub bibtex: String,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub bibcode: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct ImportSummary {
    pub imported_ids: Vec<String>,
    pub existing_ids: Vec<String>,
    pub dismissed_count: u32,
    pub failed_count: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct CollectionRecord {
    pub id: String,
    pub name: String,
    #[serde(alias = "libraryID", alias = "libraryId")]
    pub library_id: Option<String>,
    #[serde(alias = "isSmartCollection")]
    pub is_smart: bool,
    #[serde(alias = "paperCount")]
    pub publication_count: i32,
}

impl From<&imbib_core::unified::shaped_queries::CollectionRow> for CollectionRecord {
    fn from(r: &imbib_core::unified::shaped_queries::CollectionRow) -> Self {
        Self {
            id: r.id.clone(),
            name: r.name.clone(),
            library_id: r.parent_id.clone(),
            is_smart: r.is_smart,
            publication_count: r.publication_count,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct AuthorRecord {
    #[serde(alias = "givenName", default)]
    pub given_name: Option<String>,
    #[serde(alias = "familyName", default)]
    pub family_name: String,
    #[serde(default)]
    pub orcid: Option<String>,
}

impl From<&imbib_core::unified::shaped_queries::AuthorRow> for AuthorRecord {
    fn from(a: &imbib_core::unified::shaped_queries::AuthorRow) -> Self {
        Self {
            given_name: a.given_name.clone(),
            family_name: a.family_name.clone(),
            orcid: a.orcid.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LinkedFileRecord {
    pub id: String,
    #[serde(default)]
    pub filename: String,
    #[serde(alias = "relativePath", default)]
    pub relative_path: Option<String>,
    #[serde(alias = "fileSize", default)]
    pub file_size: i64,
    #[serde(alias = "isPDF", alias = "isPdf", default)]
    pub is_pdf: bool,
    #[serde(alias = "isLocallyMaterialized", default)]
    pub is_locally_materialized: bool,
    #[serde(alias = "dateAdded", default)]
    pub date_added: i64,
    #[serde(alias = "fileType", default)]
    pub file_type: Option<String>,
    #[serde(default)]
    pub sha256: Option<String>,
    #[serde(alias = "displayName", default)]
    pub display_name: Option<String>,
    /// `primary` (absent in older rows), `eink-annotated` or `eink-rmdoc`.
    #[serde(default)]
    pub role: Option<String>,
    #[serde(alias = "sourceRemoteId", default)]
    pub source_remote_id: Option<String>,
}

impl From<&imbib_core::unified::shaped_queries::LinkedFileRow> for LinkedFileRecord {
    fn from(r: &imbib_core::unified::shaped_queries::LinkedFileRow) -> Self {
        Self {
            id: r.id.clone(),
            filename: r.filename.clone(),
            relative_path: r.relative_path.clone(),
            file_size: r.file_size,
            is_pdf: r.is_pdf,
            is_locally_materialized: r.is_locally_materialized,
            date_added: r.date_added,
            file_type: r.file_type.clone(),
            sha256: r.sha256.clone(),
            display_name: r.display_name.clone(),
            role: r.role.clone(),
            source_remote_id: r.source_remote_id.clone(),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct PublicationDetailRecord {
    pub id: String,
    #[serde(alias = "citeKey", default)]
    pub cite_key: String,
    #[serde(alias = "entryType", default)]
    pub entry_type: String,
    #[serde(default)]
    pub fields: std::collections::HashMap<String, String>,
    #[serde(alias = "isRead", default)]
    pub is_read: bool,
    #[serde(alias = "isStarred", default)]
    pub is_starred: bool,
    #[serde(alias = "flagColor", default)]
    pub flag_color: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub authors: Vec<AuthorRecord>,
    #[serde(alias = "linkedFiles", default)]
    pub linked_files: Vec<LinkedFileRecord>,
    #[serde(alias = "collectionIDs", alias = "collectionIds", default)]
    pub collection_ids: Vec<String>,
    #[serde(alias = "libraryIDs", alias = "libraryIds", default)]
    pub library_ids: Vec<String>,
    #[serde(alias = "dateAdded", default)]
    pub date_added: i64,
    #[serde(alias = "dateModified", default)]
    pub date_modified: i64,
    #[serde(alias = "citationCount", default)]
    pub citation_count: i32,
}

impl From<&imbib_core::unified::shaped_queries::PublicationDetail> for PublicationDetailRecord {
    fn from(d: &imbib_core::unified::shaped_queries::PublicationDetail) -> Self {
        Self {
            id: d.id.clone(),
            cite_key: d.cite_key.clone(),
            entry_type: d.entry_type.clone(),
            fields: d.fields.clone(),
            is_read: d.is_read,
            is_starred: d.is_starred,
            flag_color: d.flag_color.clone(),
            tags: d.tags.iter().map(|t| t.path.clone()).collect(),
            authors: d.authors.iter().map(AuthorRecord::from).collect(),
            linked_files: d.linked_files.iter().map(LinkedFileRecord::from).collect(),
            collection_ids: d.collections.clone(),
            library_ids: d.libraries.clone(),
            date_added: d.date_added,
            date_modified: d.date_modified,
            citation_count: d.citation_count,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct DismissedPaperRecord {
    pub id: String,
    #[serde(default)]
    pub doi: Option<String>,
    #[serde(alias = "arxivID", alias = "arxivId", default)]
    pub arxiv_id: Option<String>,
    #[serde(default)]
    pub bibcode: Option<String>,
    #[serde(alias = "citeKey", default)]
    pub cite_key: Option<String>,
    #[serde(alias = "dateDismissed", default)]
    pub date_dismissed: i64,
}

impl From<&imbib_core::unified::shaped_queries::DismissedPaperRow> for DismissedPaperRecord {
    fn from(r: &imbib_core::unified::shaped_queries::DismissedPaperRow) -> Self {
        Self {
            id: r.id.clone(),
            doi: r.doi.clone(),
            arxiv_id: r.arxiv_id.clone(),
            bibcode: r.bibcode.clone(),
            cite_key: r.cite_key.clone(),
            date_dismissed: r.date_dismissed,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct MutedItemRecord {
    pub id: String,
    #[serde(alias = "muteType", default)]
    pub mute_type: String,
    #[serde(default)]
    pub value: String,
    #[serde(alias = "dateAdded", default)]
    pub date_added: i64,
}

impl From<&imbib_core::unified::shaped_queries::MutedItemRow> for MutedItemRecord {
    fn from(r: &imbib_core::unified::shaped_queries::MutedItemRow) -> Self {
        Self {
            id: r.id.clone(),
            mute_type: r.mute_type.clone(),
            value: r.value.clone(),
            date_added: r.date_added,
        }
    }
}

// ===========================================================================
// Trait
// ===========================================================================

/// One library as the sidebar presents it (sidebar plan P3).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct SidebarViewCollection {
    pub id: String,
    pub name: String,
    pub publication_count: i32,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct SidebarViewFeed {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct SidebarViewLibrary {
    pub id: String,
    pub name: String,
    pub unread: u32,
    pub starred: u32,
    pub collections: Vec<SidebarViewCollection>,
    pub feeds: Vec<SidebarViewFeed>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct SidebarViewArtifacts {
    /// `None` = the all-artifacts total.
    pub schema_ref: Option<String>,
    pub count: u32,
}

/// What imbib's sidebar shows, as data (sidebar plan P3): the same snapshot
/// the app's own sidebar renders from, one call. "State is legible: agents
/// can read what the human sees."
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct SidebarView {
    pub libraries: Vec<SidebarViewLibrary>,
    pub artifact_counts: Vec<SidebarViewArtifacts>,
    /// Flag color → count, for the Flagged section's badges.
    pub flag_counts: Vec<SidebarViewArtifactsFlag>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, schemars::JsonSchema)]
pub struct SidebarViewArtifactsFlag {
    pub color: String,
    pub count: u32,
}

#[impress_service]
pub trait ImbibLibraryService: Send + Sync + 'static {
    // ---- Library lifecycle ----
    /// List all libraries in imbib. Libraries are top-level containers for
    /// papers.
    #[impress_method(effects(reads = ["imbib/library", "imbib/bibliography-entry", "imbib/collection"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(name = "reading-library-list", args = r#"{}"#)]
    async fn list_libraries(&self) -> Vec<LibraryRecord>;
    /// What the sidebar shows, as one structured value: every library with
    /// its unread/starred badges, collections and feeds, plus artifact and
    /// flag counts — the same snapshot the app's sidebar renders from.
    #[impress_method(effects(reads = ["imbib/library", "imbib/bibliography-entry", "imbib/smart-search", "imbib/collection", prefix("impress/artifact/")]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(name = "reading-sidebar", args = r#"{}"#)]
    async fn sidebar_view(&self) -> SidebarView;
    /// Create a new library in imbib. Libraries are top-level containers
    /// for papers, separate from collections. Use this when asked to create
    /// a new library for a topic or project.
    #[impress_method(safety = mutating, effects(reads = ["imbib/library", "imbib/collection"], writes = ["imbib/library"]))]
    #[impress_example(
        name = "new-project-library",
        args = r#"{"name":"G3 reading project"}"#,
        expect = r#"{"name":"G3 reading project","is_default":false}"#
    )]
    async fn create_library(&self, name: String) -> Option<LibraryRecord>;
    /// Delete a library with its collections and memberships. `delete_files`
    /// also removes its shared and legacy file containers, which requires the
    /// running imbib app. Store undo does not restore removed file bytes.
    #[impress_method(safety = destructive, effects(reads = ["imbib/library", "imbib/bibliography-entry", "imbib/collection", "imbib/linked-file"], writes = ["imbib/library", "imbib/bibliography-entry", "imbib/collection", "imbib/linked-file"], reach = [app("imbib"), fs]))]
    #[impress_example(
        name = "remove-empty-library",
        args = r#"{"id":"5c000000-0000-4000-8000-00000000000a","delete_files":false}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn delete_library_undoable(&self, id: String, delete_files: bool) -> MutationResult;
    /// Delete a batch of existing libraries after validating every UUID and
    /// library before any filesystem or store mutation. Removed file bytes are
    /// not restored by store undo.
    #[impress_method(safety = destructive, effects(reads = ["imbib/library", "imbib/bibliography-entry", "imbib/collection", "imbib/linked-file"], writes = ["imbib/library", "imbib/bibliography-entry", "imbib/collection", "imbib/linked-file"], reach = [app("imbib"), fs]))]
    #[impress_example(
        name = "delete-library-batch",
        args = r#"{"ids":["5c000000-0000-4000-8000-00000000000d","5c000000-0000-4000-8000-00000000000e"],"delete_files":false}"#,
        expect = r#"2"#
    )]
    async fn delete_libraries(&self, ids: Vec<String>, delete_files: bool) -> u32;
    /// Get the library new papers are filed into by default, if one is set.
    #[impress_method(effects(reads = ["imbib/library", "imbib/bibliography-entry", "imbib/collection"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(
        name = "project-default",
        args = r#"{}"#,
        expect = r#"{"id":"5c000000-0000-4000-8000-00000000000b","name":"G3 default library","is_default":true}"#
    )]
    async fn get_default_library(&self) -> Option<LibraryRecord>;
    /// Make a library the default target for new papers.
    #[impress_method(safety = mutating, effects(reads = ["imbib/library"], writes = ["imbib/library"]))]
    #[impress_example(
        name = "make-reading-default",
        args = r#"{"id":"5c000000-0000-4000-8000-000000000081"}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn set_library_default(&self, id: String) -> MutationResult;
    /// Get the Inbox library, where incoming papers land before filing.
    #[impress_method(effects(reads = ["imbib/library", "imbib/bibliography-entry", "imbib/collection"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(
        name = "inbox-library",
        args = r#"{}"#,
        expect = r#"{"id":"5c000000-0000-4000-8000-00000000000c","name":"G3 Inbox","is_inbox":true}"#
    )]
    async fn get_inbox_library(&self) -> Option<LibraryRecord>;

    // ---- Collection lifecycle ----
    /// List all collections in the imbib library. Collections organize
    /// papers into groups.
    #[impress_method(effects(reads = ["imbib/collection", "imbib/library"]))]
    #[impress_example(
        name = "library-collections",
        args = r#"{"library_id":"5c000000-0000-4000-8000-000000000061"}"#
    )]
    async fn list_collections(&self, library_id: String) -> Vec<CollectionRecord>;
    /// Create a new collection to organize papers. Collections can be
    /// regular (manual) or smart (auto-populated by predicate).
    #[impress_method(safety = mutating, effects(reads = ["imbib/library"], writes = ["imbib/collection"]))]
    #[impress_example(
        name = "manual-collection",
        args = r#"{"name":"G3 methods","library_id":"5c000000-0000-4000-8000-000000000010","is_smart":false,"query":null}"#,
        expect = r#"{"name":"G3 methods","is_smart":false}"#
    )]
    async fn create_collection(
        &self,
        name: String,
        library_id: String,
        is_smart: bool,
        query: Option<String>,
    ) -> Option<CollectionRecord>;
    /// Add papers to an existing collection.
    #[impress_method(safety = mutating, effects(reads = ["imbib/collection", "imbib/bibliography-entry"], writes = ["imbib/collection"]))]
    #[impress_example(
        name = "file-paper",
        args = r#"{"publication_ids":["5c000000-0000-4000-8000-000000000012"],"collection_id":"5c000000-0000-4000-8000-000000000011"}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn add_to_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> MutationResult;
    /// Remove papers from a collection (does not delete them).
    #[impress_method(safety = mutating, effects(reads = ["imbib/collection"], writes = ["imbib/collection"]))]
    #[impress_example(
        name = "unfile-paper",
        args = r#"{"publication_ids":["5c000000-0000-4000-8000-00000000007c"],"collection_id":"5c000000-0000-4000-8000-00000000007b"}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn remove_from_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> MutationResult;
    /// Add or remove existing papers by the same local identifiers accepted
    /// by the retained collection HTTP routes. Results preserve input order.
    #[impress_method(safety = mutating, effects(reads = ["imbib/collection", "imbib/library", "imbib/bibliography-entry", "imbib/tag-definition"], writes = ["imbib/collection"]))]
    #[impress_example(
        name = "file-existing-paper",
        args = r#"{"collection_id":"5c000000-0000-4000-8000-0000000000c1","identifiers":["G3Membership2026","missing-G3"],"action":"add"}"#,
        expect = r#"{"assigned":["G3Membership2026"],"not_found":["missing-G3"]}"#
    )]
    async fn update_collection_members(
        &self,
        collection_id: String,
        identifiers: Vec<String>,
        action: String,
    ) -> CollectionMembershipResult;
    /// List all papers in a specific collection.
    #[impress_method(effects(reads = ["imbib/collection", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror"]))]
    #[impress_example(
        name = "collection-paper",
        args = r#"{"collection_id":"5c000000-0000-4000-8000-000000000064","sort_field":"title","ascending":true,"limit":10,"offset":0}"#
    )]
    async fn list_collection_members(
        &self,
        collection_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<PublicationSummary>;
    /// Remove from a collection every paper that has been dismissed; the
    /// result counts the memberships removed.
    #[impress_method(safety = mutating, effects(reads = ["imbib/collection", "imbib/bibliography-entry", "imbib/dismissed-paper"], writes = ["imbib/collection"]))]
    #[impress_example(
        name = "unfile-dismissed-paper",
        args = r#"{"collection_id":"5c000000-0000-4000-8000-00000000006f"}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn purge_dismissed_from_collection(&self, collection_id: String) -> MutationResult;

    // ---- Paper queries ----
    /// List papers across every library, paged by `limit` and `offset`
    /// (a limit of 0 means 50).
    #[impress_method]
    #[impress_example(name = "default", args = r#"{"limit": 5, "offset": 0}"#)]
    #[impress_example(name = "list-scratch-paper", args = r#"{"limit":200,"offset":0}"#)]
    async fn list_publications(&self, limit: u32, offset: u32) -> Vec<PublicationSummary>;
    /// List the papers in one library, sorted by `sort_field` in the given
    /// direction and paged (a limit of 0 means 50).
    #[impress_method]
    #[impress_example(
        name = "project-papers",
        args = r#"{"library_id":"5c000000-0000-4000-8000-000000000072","sort_field":"title","ascending":true,"limit":10,"offset":0}"#
    )]
    async fn query_publications(
        &self,
        library_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<PublicationSummary>;
    /// List unread papers, optionally within one library or collection
    /// (`parent_id`), sorted.
    #[impress_method]
    #[impress_example(
        name = "default",
        args = r#"{"parent_id": null, "sort_field": "title", "ascending": true, "limit": 5}"#
    )]
    #[impress_example(
        name = "unread-project-paper",
        args = r#"{"parent_id":"5c000000-0000-4000-8000-000000000078","sort_field":"title","ascending":true,"limit":10}"#
    )]
    async fn query_unread(
        &self,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: u32,
    ) -> Vec<PublicationSummary>;
    /// List starred papers, optionally within one library or collection
    /// (`parent_id`), sorted.
    #[impress_method]
    #[impress_example(
        name = "default",
        args = r#"{"parent_id": null, "sort_field": "title", "ascending": true, "limit": 5}"#
    )]
    #[impress_example(
        name = "starred-project-paper",
        args = r#"{"parent_id":"5c000000-0000-4000-8000-000000000076","sort_field":"title","ascending":true,"limit":10}"#
    )]
    async fn query_starred(
        &self,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: u32,
    ) -> Vec<PublicationSummary>;
    /// List the most recently added papers, optionally within one library or
    /// collection (`parent_id`).
    #[impress_method]
    #[impress_example(name = "default", args = r#"{"limit": 5}"#)]
    #[impress_example(
        name = "recent-project-paper",
        args = r#"{"limit":10,"parent_id":"5c000000-0000-4000-8000-000000000074"}"#
    )]
    async fn query_recent(&self, limit: u32, parent_id: Option<String>) -> Vec<PublicationSummary>;
    /// Search paper metadata by free text, newest-added first, applying
    /// optional state, membership, tag, flag, and date filters before paging.
    /// An empty query lists the selected library or collection; with no
    /// membership filter it lists the default library. A zero limit means 50.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/library", "imbib/collection"]))]
    #[impress_example(
        name = "find-unique-spectrum",
        args = r#"{"query":"G3 Unique Spectrum","limit":10}"#
    )]
    #[impress_example(
        name = "filtered-project-spectrum",
        args = r#"{"query":"G3 Unique Spectrum","limit":10,"filters":{"read":false,"library":"5c000000-0000-4000-8000-000000000088"}}"#
    )]
    #[impress_example(
        name = "filtered-collection-spectrum",
        args = r#"{"query":"G3 Unique Spectrum","limit":10,"filters":{"read":false,"collection":"5c000000-0000-4000-8000-000000000089"}}"#
    )]
    async fn search_publications(
        &self,
        query: String,
        limit: u32,
        offset: Option<u32>,
        filters: Option<PublicationSearchFilters>,
    ) -> Vec<PublicationSummary>;
    /// Get one paper's summary by id; null when there is no such paper.
    #[impress_method]
    #[impress_example(
        name = "paper-summary",
        args = r#"{"id":"5c000000-0000-4000-8000-000000000020"}"#,
        expect = r#"{"id":"5c000000-0000-4000-8000-000000000020","title":"G3 stellar spectra","cite_key":"G3Spectra2026"}"#
    )]
    async fn get_publication(&self, id: String) -> Option<PublicationSummary>;
    /// Get detailed metadata, collection membership, and linked files for a
    /// paper by its UUID.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror", "imbib/collection"]))]
    #[impress_example(
        name = "paper-metadata",
        args = r#"{"id":"5c000000-0000-4000-8000-000000000021"}"#,
        expect = r#"{"id":"5c000000-0000-4000-8000-000000000021","cite_key":"G3Detail2026","entry_type":"article"}"#
    )]
    async fn get_publication_detail(&self, id: String) -> Option<PublicationDetailRecord>;
    /// Get a single count — unread, starred, flagged, or by-tag — without
    /// fetching any paper rows. Use whenever the user asks 'how many …'; it
    /// is far cheaper than listing and lengthing the result, and unlike
    /// `imbib-tags-service_list-tags` it does not walk the whole tag vocabulary.
    #[impress_method(effects(reads = ["imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(name = "count-scratch-paper", args = r#"{}"#)]
    async fn count_publications(&self) -> u32;
    /// Count unread papers, optionally within one library or collection.
    #[impress_method(effects(reads = ["imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(
        name = "count-unread-in-library",
        args = r#"{"parent_id":"5c000000-0000-4000-8000-000000000050"}"#,
        expect = r#"1"#
    )]
    async fn count_unread(&self, parent_id: Option<String>) -> u32;
    /// Count starred papers, optionally within one library or collection.
    #[impress_method(effects(reads = ["imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(
        name = "count-starred-in-library",
        args = r#"{"parent_id":"5c000000-0000-4000-8000-000000000051"}"#,
        expect = r#"1"#
    )]
    async fn count_starred(&self, parent_id: Option<String>) -> u32;
    /// Count flagged papers, optionally only those carrying one flag color.
    #[impress_method(effects(reads = ["imbib/bibliography-entry"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(
        name = "count-blue-flags",
        args = r#"{"color":"g3-blue"}"#,
        expect = r#"1"#
    )]
    async fn count_flagged(&self, color: Option<String>) -> u32;

    // ---- Paper mutations ----
    /// Mark papers as read or unread. Useful for tracking reading progress.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry"], writes = ["imbib/bibliography-entry"]))]
    #[impress_example(
        name = "finish-reading",
        args = r#"{"ids":["5c000000-0000-4000-8000-000000000082"],"read":true}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn set_read(&self, ids: Vec<String>, read: bool) -> MutationResult;
    /// Toggle the starred status of papers.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry"], writes = ["imbib/bibliography-entry"]))]
    #[impress_example(
        name = "star-project-paper",
        args = r#"{"ids":["5c000000-0000-4000-8000-000000000083"],"starred":true}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn set_starred(&self, ids: Vec<String>, starred: bool) -> MutationResult;
    /// Set or clear a colored flag on papers. Flags are visual markers for
    /// workflow status. Set color to null to clear the flag.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry"], writes = ["imbib/bibliography-entry"]))]
    #[impress_example(
        name = "flag-for-review",
        args = r#"{"ids":["5c000000-0000-4000-8000-000000000080"],"color":"orange"}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn set_flag(&self, ids: Vec<String>, color: Option<String>) -> MutationResult;
    /// Delete papers from the imbib library. DESTRUCTIVE AND NOT UNDOABLE:
    /// this route removes the rows outright and writes nothing to the
    /// operation log, so `imbib-undo-service_undo-batch` cannot bring them back (verified live
    /// 2026-07-25). The only safety net is an `imbib-backup-service_create-backup` taken
    /// beforehand — do that whenever the instruction is spoken, bulk, or at
    /// all ambiguous about which papers are meant, and confirm the list
    /// with the user first. To take papers out of the user's way without
    /// destroying them, prefer `imbib-library-service_remove-from-collection`, or move them
    /// to the Dismissed library (imbib's trash) with imbib_add_to_library.
    #[impress_method(safety = destructive, effects(reads = ["imbib/bibliography-entry", any("undo snapshots query all children of each publication, regardless of kind")], writes = ["imbib/bibliography-entry"]))]
    #[impress_example(
        name = "delete-scratch-paper",
        args = r#"{"ids":["5c000000-0000-4000-8000-000000000022"]}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn delete_publications_undoable(&self, ids: Vec<String>) -> MutationResult;
    /// Move papers into another library.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry", "imbib/library"], writes = ["imbib/bibliography-entry"]))]
    #[impress_example(
        name = "move-to-project",
        args = r#"{"publication_ids":["5c000000-0000-4000-8000-00000000006e"],"to_library_id":"5c000000-0000-4000-8000-00000000006d"}"#,
        expect = r#"{"ok":true,"affected_count":1}"#
    )]
    async fn move_publications(
        &self,
        publication_ids: Vec<String>,
        to_library_id: String,
    ) -> MutationResult;
    /// File existing papers into a library by the same local identifiers the
    /// collection membership verb accepts. Results preserve input order.
    /// Identifiers that do not resolve are reported and left untouched.
    #[impress_method(safety = mutating, effects(reads = ["imbib/library", "imbib/bibliography-entry", "imbib/tag-definition", "imbib/eink-device"], writes = ["imbib/bibliography-entry"]))]
    #[impress_example(
        name = "file-existing-paper-into-library",
        args = r#"{"library_id":"5c000000-0000-4000-8000-0000000000d3","identifiers":["G3LibraryMove2026","missing-G3-lib"]}"#,
        expect = r#"{"assigned":["G3LibraryMove2026"],"not_found":["missing-G3-lib"]}"#
    )]
    async fn add_existing_papers_to_library(
        &self,
        library_id: String,
        identifiers: Vec<String>,
    ) -> LibraryMembershipResult;
    /// Copy papers into another library; returns the ids of the new copies.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry", "imbib/linked-file"], writes = ["imbib/bibliography-entry", "imbib/linked-file"], reach = [fs]))]
    #[impress_example(
        name = "copy-paper-to-project",
        tier = "b",
        args = r#"{"ids":["5c000000-0000-4000-8000-000000000023"],"to_library_id":"5c000000-0000-4000-8000-000000000024"}"#
    )]
    async fn duplicate_publications(&self, ids: Vec<String>, to_library_id: String) -> Vec<String>;
    /// Merge duplicate papers within a library and hard-delete the duplicate
    /// rows (not undoable); returns how many were removed.
    #[impress_method(safety = destructive, effects(reads = ["imbib/bibliography-entry", "imbib/library"], writes = ["imbib/bibliography-entry"]))]
    #[impress_example(
        name = "merge-same-doi",
        args = r#"{"library_id":"5c000000-0000-4000-8000-000000000025"}"#,
        expect = r#"1"#
    )]
    async fn deduplicate_library(&self, library_id: String) -> u32;

    // ---- Dismissed/muted ----
    /// Record a paper as dismissed by any of its identifiers so imports and
    /// feeds skip it. Writes a tombstone only: nothing is moved or deleted,
    /// and there is no un-dismiss verb.
    #[impress_method(safety = mutating, effects(reads = ["imbib/dismissed-paper"], writes = ["imbib/dismissed-paper"]))]
    #[impress_example(
        name = "dismiss-known-doi",
        args = r#"{"doi":"10.5555/g3-dismiss","arxiv_id":null,"bibcode":null,"cite_key":null}"#,
        expect = r#"{"doi":"10.5555/g3-dismiss"}"#
    )]
    async fn dismiss_paper(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> Option<DismissedPaperRecord>;
    /// Whether a paper with any of the given identifiers has been dismissed.
    #[impress_method(effects(reads = ["imbib/dismissed-paper"]))]
    #[impress_example(name = "default", args = r#"{"doi": "10.1000/effects-example"}"#)]
    #[impress_example(
        name = "known-dismissed-doi",
        args = r#"{"doi":"10.5555/g3-known-dismissed"}"#,
        expect = r#"true"#
    )]
    async fn is_paper_dismissed(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> bool;
    /// List the dismissed-paper tombstones, paged (a limit of 0 means 100).
    #[impress_method(effects(reads = ["imbib/dismissed-paper"]))]
    #[impress_example(name = "dismissed-list", args = r#"{"limit":100,"offset":0}"#)]
    async fn list_dismissed_papers(&self, limit: u32, offset: u32) -> Vec<DismissedPaperRecord>;
    /// List the mute rules (an author, keyword or source value per rule) that
    /// feeds and imports suppress.
    #[impress_method(effects(reads = ["imbib/muted-item"]))]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(name = "active-mute-rules", args = r#"{}"#)]
    async fn list_muted_items(&self) -> Vec<MutedItemRecord>;
    /// Add a mute rule: `mute_type` names what is matched (for example
    /// `author`), `value` is the text to match.
    #[impress_method(safety = mutating, effects(reads = ["imbib/muted-item"], writes = ["imbib/muted-item"]))]
    #[impress_example(
        name = "mute-keyword",
        args = r#"{"mute_type":"keyword","value":"G3 irrelevant topic"}"#,
        expect = r#"{"mute_type":"keyword","value":"G3 irrelevant topic"}"#
    )]
    async fn create_muted_item(&self, mute_type: String, value: String) -> Option<MutedItemRecord>;

    // ---- BibTeX import/export ----
    /// Import already-fetched paper records into a library from their BibTeX
    /// and DOI, arXiv ID, or bibcode identifiers. This method parses the
    /// supplied BibTeX locally; the caller fetches metadata beforehand.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry", "imbib/library", "imbib/dismissed-paper"], writes = ["imbib/bibliography-entry"]))]
    #[impress_example(
        name = "import-fetched-record",
        args = r#"{"papers":[{"bibtex":"@article{G3SearchRecord2026, title={G3 search record}, author={Doe, Jane}, year={2026}}","doi":"10.5555/g3-search-record","arxiv_id":null,"bibcode":null}],"library_id":"5c000000-0000-4000-8000-000000000085"}"#
    )]
    async fn import_papers(&self, papers: Vec<PaperImport>, library_id: String) -> ImportSummary;
    /// Resolve each identifier in the running app, importing fetched records
    /// and preserving per-identifier duplicate/failure outcomes.
    #[impress_method(safety = external, effects(reads = ["imbib/bibliography-entry", "imbib/library", "imbib/collection", "imbib/dismissed-paper", "imbib/linked-file"], writes = ["imbib/bibliography-entry", "imbib/collection", "imbib/linked-file"], reach = [app("imbib"), network, fs]))]
    #[impress_example(
        name = "import-identifiers-native",
        tier = "b",
        args = r#"{"identifiers":["Existing2026"],"library_id":null,"collection_id":null,"download_pdfs":false}"#
    )]
    async fn import_identifiers(
        &self,
        identifiers: Vec<String>,
        library_id: Option<String>,
        collection_id: Option<String>,
        download_pdfs: bool,
    ) -> IdentifierImportResult;
    /// Parse BibTeX and add each entry to a library as a paper; returns the
    /// ids of the papers created.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry", "imbib/library"], writes = ["imbib/bibliography-entry"]))]
    #[impress_example(
        name = "import-one-entry",
        args = r#"{"bibtex":"@article{G3Imported2026, title={G3 imported result}, author={Doe, Jane}, year={2026}}","library_id":"5c000000-0000-4000-8000-000000000030"}"#
    )]
    async fn import_bibtex(&self, bibtex: String, library_id: String) -> Vec<String>;
    /// Import BibTeX and file every resulting paper into a collection. Papers
    /// that already exist — including ones filed in a different library — are
    /// added to the collection rather than skipped, so dropping a .bib on a
    /// collection reliably means "these papers belong here". Returns the papers
    /// created and the pre-existing ones linked, kept separate so undo can
    /// remove only what the import created.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry", "imbib/library", "imbib/collection"], writes = ["imbib/bibliography-entry", "imbib/collection"]))]
    #[impress_example(
        name = "scratch-paper-into-collection",
        args = r#"{"bibtex":"@article{P5bEffects2026, title={P5b Effects Paper}, author={Doe, Jane}, year={2026}}","library_id":"56000000-0000-4000-8000-000000000041","collection_id":"56000000-0000-4000-8000-000000000042"}"#
    )]
    async fn import_bibtex_into_collection(
        &self,
        bibtex: String,
        library_id: String,
        collection_id: String,
    ) -> BibtexImportOutcome;
    /// Export BibTeX entries for one or more papers. Useful for creating
    /// bibliography files or inserting citations.
    #[impress_method(effects(reads = ["imbib/eink-device", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition"]))]
    #[impress_example(name = "export-cite-key", args = r#"{"ids":["G3Export2026"]}"#)]
    async fn export_bibtex(&self, ids: Vec<String>) -> String;
    /// Export selected papers as RIS, accepting UUIDs or cite keys in input
    /// order and omitting identifiers that do not resolve.
    #[impress_method(effects(reads = ["imbib/eink-device", "imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition"]))]
    #[impress_example(
        name = "representative-ris-export",
        args = r#"{"ids":["G3RIS2026"]}"#,
        expect = r#""TY  - JOUR\nAU  - Doe, Jane\nTI  - RIS parity paper\nPY  - 2026\nJF  - Research Journal\nT2  - Research Journal\nVL  - 12\nIS  - 3\nSP  - 100\nEP  - 110\nDO  - 10.5555/g3-ris\nAB  - Representative abstract\nKW  - alpha\nKW  - beta\nUR  - https://example.org/g3-ris\nPB  - Example Press\nCY  - Boston\nSN  - 1234-5678\nN1  - G3 export note\nT3  - Research Series\nET  - 2\nLA  - en\nID  - G3RIS2026\nER  - ""#
    )]
    async fn export_ris(&self, ids: Vec<String>) -> String;
    /// Export every paper in a library as one BibTeX string.
    #[impress_method(effects(reads = ["imbib/bibliography-entry", "imbib/linked-file", "imbib/library"]))]
    #[impress_example(
        name = "export-project-library",
        args = r#"{"library_id":"5c000000-0000-4000-8000-000000000031"}"#
    )]
    async fn export_all_bibtex(&self, library_id: String) -> String;

    // ---- Linked files / PDFs ----
    /// List the files (PDFs and others) linked to a paper.
    #[impress_method(effects(reads = ["imbib/linked-file"]))]
    #[impress_example(
        name = "paper-attachments",
        args = r#"{"publication_id":"5c000000-0000-4000-8000-000000000068"}"#
    )]
    async fn list_linked_files(&self, publication_id: String) -> Vec<LinkedFileRecord>;
    /// Count the PDFs linked to a paper.
    #[impress_method(effects(reads = ["imbib/linked-file"]))]
    #[impress_example(
        name = "one-pdf",
        args = r#"{"publication_id":"5c000000-0000-4000-8000-000000000040"}"#,
        expect = r#"1"#
    )]
    async fn count_pdfs(&self, publication_id: String) -> u32;
    /// Record a file already on disk as linked to a paper; nothing is copied
    /// or fetched.
    #[impress_method(safety = mutating, effects(reads = ["imbib/bibliography-entry"], writes = ["imbib/linked-file"]))]
    #[impress_example(
        name = "link-local-pdf",
        args = r#"{"publication_id":"5c000000-0000-4000-8000-000000000041","filename":"paper.pdf","relative_path":"library/paper.pdf","file_type":"application/pdf","file_size":15,"sha256":null,"is_pdf":true}"#,
        expect = r#"{"filename":"paper.pdf","relative_path":"library/paper.pdf","file_size":15,"is_pdf":true}"#
    )]
    async fn add_linked_file(
        &self,
        publication_id: String,
        filename: String,
        relative_path: Option<String>,
        file_type: Option<String>,
        file_size: i64,
        sha256: Option<String>,
        is_pdf: bool,
    ) -> Option<LinkedFileRecord>;

    // ---- Retention ----
    /// Remove papers past their retention window (imbib CLAUDE.md
    /// "Background Services Must Defer Startup Work"; plan W3, D-R10 —
    /// replaces the Swift `RetentionCleanupService` and its ungated macOS
    /// duplicate). DESTRUCTIVE: it deletes store rows, by design — that is
    /// what the feature does. It never touches the undo stack (undo is a
    /// user action; this runs as scheduled or on-demand background work),
    /// and a starred paper is never removed regardless of age.
    ///
    /// Three sources, each independent and each reading its own threshold
    /// from the settings registry (R1) rather than an argument:
    /// - **Inbox**: `imbib.retention.inbox_days` (0 = keep forever) and
    ///   `imbib.retention.auto_remove_read`. Every removed inbox paper is
    ///   first recorded with `dismiss_paper` (by DOI/arXiv/bibcode/cite key)
    ///   so a later import or feed refresh does not bring it back — "a
    ///   dismissed paper must never re-enter the inbox" (imbib CLAUDE.md).
    /// - **Feed collections**: every `imbib/smart-search` row carrying its
    ///   own per-collection `retention_days` and `auto_remove_read`.
    /// - **Exploration**: `imbib.retention.exploration_days`, applied to
    ///   executed smart searches under the library pointer migrated from
    ///   imbib's legacy `explorationLibraryID` setting. A valid explicit
    ///   `exploration_library_id` takes precedence over that stored pointer.
    #[impress_method(
        safety = destructive,
        effects(
            reads = ["imbib/bibliography-entry", "imbib/smart-search", "imbib/library", "imbib/dismissed-paper", "imbib/tag-definition"],
            writes = ["imbib/bibliography-entry", "imbib/smart-search", "imbib/dismissed-paper"],
        )
    )]
    #[impress_example(name = "default", args = r#"{}"#)]
    #[impress_example(
        name = "expire-old-search",
        args = r#"{"exploration_library_id":"5c000000-0000-4000-8000-000000000086"}"#,
        expect = r#"{"exploration_removed":1}"#
    )]
    async fn retention_cleanup(
        &self,
        exploration_library_id: Option<String>,
    ) -> RetentionCleanupReport;
}

// ===========================================================================
// Impl
// ===========================================================================

#[derive(Clone)]
pub struct DefaultImbibLibraryService {
    store: Arc<ImbibStore>,
}

impl DefaultImbibLibraryService {
    pub fn new(store: Arc<ImbibStore>) -> Self {
        Self { store }
    }

    fn library_record(
        &self,
        row: &imbib_core::unified::shaped_queries::LibraryRow,
    ) -> Result<LibraryRecord, imbib_core::unified::store_api::StoreApiError> {
        let collection_count = self.store.list_collections(row.id.clone())?.len();
        Ok(LibraryRecord::from_row(row, collection_count))
    }

    fn collection_exists(
        &self,
        collection_id: &str,
    ) -> Result<bool, imbib_core::unified::store_api::StoreApiError> {
        for library in self.store.list_libraries()? {
            if self
                .store
                .list_collections(library.id)?
                .iter()
                .any(|collection| collection.id == collection_id)
            {
                return Ok(true);
            }
        }
        Ok(false)
    }

    fn publication_id_for_local_identifier(
        &self,
        identifier: &LocalPaperIdentifier,
    ) -> Result<Option<String>, imbib_core::unified::store_api::StoreApiError> {
        use LocalPaperIdentifier as Id;
        let publication = match identifier {
            Id::Uuid(value, _) => self.store.get_publication(value.to_string())?,
            Id::Doi(value, _) => self.store.find_by_doi(value.clone())?.into_iter().next(),
            Id::Arxiv(value, _) => self.store.find_by_arxiv(value.clone())?.into_iter().next(),
            Id::Bibcode(value, _) => self
                .store
                .find_by_bibcode(value.clone())?
                .into_iter()
                .next(),
            Id::Pmid(value, _) => self
                .store
                .find_by_identifiers(None, None, None, Some(value.clone()))?
                .into_iter()
                .next(),
            Id::CiteKey(value, _) => self.store.find_by_cite_key(value.clone(), None)?,
            Id::Unsupported(_) => None,
        };
        Ok(publication.map(|row| row.id))
    }
}

/// The retained `PaperIdentifier.fromString` behavior, limited to local lookup
/// forms. Semantic Scholar and OpenAlex identifiers are recognized by that
/// parser but intentionally have no local lookup path.
enum LocalPaperIdentifier {
    Uuid(uuid::Uuid, String),
    Doi(String, String),
    Arxiv(String, String),
    Bibcode(String, String),
    Pmid(String, String),
    CiteKey(String, String),
    Unsupported(String),
}

impl LocalPaperIdentifier {
    fn parse(input: &str) -> Self {
        use LocalPaperIdentifier as Id;
        let trimmed = input.trim();
        if let Ok(uuid) = uuid::Uuid::parse_str(trimmed) {
            return Id::Uuid(uuid, uuid.hyphenated().to_string().to_ascii_uppercase());
        }
        if trimmed.starts_with("10.") || trimmed.to_ascii_lowercase().starts_with("doi:") {
            // Match `PaperIdentifier.fromString`'s case-sensitive prefix
            // removal: unusual `DOI:` input is classified as a DOI but keeps
            // the prefix in its value and therefore remains a local miss.
            let value = if trimmed.starts_with("doi:") {
                trimmed.get(4..).unwrap_or_default().trim()
            } else {
                trimmed
            };
            return Id::Doi(value.to_string(), value.to_string());
        }
        let arxiv = if trimmed.starts_with("arXiv:") {
            trimmed.get(6..).unwrap_or_default()
        } else {
            trimmed
        };
        if is_modern_arxiv_id(arxiv) || is_legacy_arxiv_id(trimmed) {
            return Id::Arxiv(arxiv.to_string(), arxiv.to_string());
        }
        if trimmed.chars().count() == 19 {
            let year = trimmed.get(..4).and_then(|value| value.parse::<u16>().ok());
            if year.is_some_and(|year| (1800..=2100).contains(&year)) {
                return Id::Bibcode(trimmed.to_string(), trimmed.to_string());
            }
        }
        let character_count = trimmed.chars().count();
        if (5..=10).contains(&character_count) && trimmed.chars().all(char::is_numeric) {
            return Id::Pmid(trimmed.to_string(), trimmed.to_string());
        }
        if (trimmed.len() == 40 && trimmed.bytes().all(|byte| byte.is_ascii_hexdigit()))
            || trimmed
                .strip_prefix('W')
                .is_some_and(|rest| rest.bytes().all(|byte| byte.is_ascii_digit()))
        {
            return Id::Unsupported(trimmed.to_string());
        }
        Id::CiteKey(trimmed.to_string(), trimmed.to_string())
    }

    fn value(&self) -> &str {
        match self {
            Self::Uuid(_, value)
            | Self::Doi(_, value)
            | Self::Arxiv(_, value)
            | Self::Bibcode(_, value)
            | Self::Pmid(_, value)
            | Self::CiteKey(_, value)
            | Self::Unsupported(value) => value,
        }
    }
}

fn is_modern_arxiv_id(value: &str) -> bool {
    let base = match value.rsplit_once('v') {
        Some((base, suffix))
            if !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit()) =>
        {
            base
        }
        _ => value,
    };
    let Some((year_month, paper)) = base.split_once('.') else {
        return false;
    };
    year_month.len() == 4
        && year_month.bytes().all(|byte| byte.is_ascii_digit())
        && (4..=5).contains(&paper.len())
        && paper.bytes().all(|byte| byte.is_ascii_digit())
}

fn is_legacy_arxiv_id(value: &str) -> bool {
    let Some((archive, number)) = value.split_once('/') else {
        return false;
    };
    let base = match number.rsplit_once('v') {
        Some((base, suffix))
            if !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit()) =>
        {
            base
        }
        _ => number,
    };
    !archive.is_empty()
        && archive
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte == b'-')
        && base.len() == 7
        && base.bytes().all(|byte| byte.is_ascii_digit())
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
fn log(method: &str, e: impl std::fmt::Display) {
    eprintln!("[imbib-library-service] {method}: {e}");
}

#[async_trait::async_trait]
impl ImbibLibraryService for DefaultImbibLibraryService {
    async fn sidebar_view(&self) -> SidebarView {
        match self.store.sidebar_snapshot() {
            Ok(snapshot) => {
                let unread: std::collections::HashMap<&str, u32> = snapshot
                    .counts
                    .unread_by_container
                    .iter()
                    .map(|entry| (entry.id.as_str(), entry.count))
                    .collect();
                let names: std::collections::HashMap<&str, &str> = snapshot
                    .libraries
                    .iter()
                    .map(|lib| (lib.id.as_str(), lib.name.as_str()))
                    .collect();
                SidebarView {
                    libraries: snapshot
                        .per_library
                        .iter()
                        .map(|per| SidebarViewLibrary {
                            id: per.library_id.clone(),
                            name: names
                                .get(per.library_id.as_str())
                                .map(|n| n.to_string())
                                .unwrap_or_default(),
                            unread: unread.get(per.library_id.as_str()).copied().unwrap_or(0),
                            starred: per.starred,
                            collections: per
                                .collections
                                .iter()
                                .map(|c| SidebarViewCollection {
                                    id: c.id.clone(),
                                    name: c.name.clone(),
                                    publication_count: c.publication_count,
                                })
                                .collect(),
                            feeds: per
                                .feeds
                                .iter()
                                .map(|f| SidebarViewFeed {
                                    id: f.id.clone(),
                                    name: f.name.clone(),
                                })
                                .collect(),
                        })
                        .collect(),
                    artifact_counts: snapshot
                        .artifact_counts
                        .iter()
                        .map(|a| SidebarViewArtifacts {
                            schema_ref: a.schema_ref.clone(),
                            count: a.count,
                        })
                        .collect(),
                    flag_counts: snapshot
                        .counts
                        .flag_counts
                        .iter()
                        .map(|f| SidebarViewArtifactsFlag {
                            color: f.id.clone(),
                            count: f.count,
                        })
                        .collect(),
                }
            }
            Err(e) => {
                log("sidebar_view", e);
                SidebarView {
                    libraries: vec![],
                    artifact_counts: vec![],
                    flag_counts: vec![],
                }
            }
        }
    }

    async fn list_libraries(&self) -> Vec<LibraryRecord> {
        self.store
            .list_libraries()
            .and_then(|rows| rows.iter().map(|row| self.library_record(row)).collect())
            .unwrap_or_else(|e| {
                log("list_libraries", e);
                vec![]
            })
    }
    async fn create_library(&self, name: String) -> Option<LibraryRecord> {
        self.store
            .create_library(name)
            .and_then(|r| self.library_record(&r))
            .map_err(|e| log("create_library", e))
            .ok()
    }
    async fn delete_library_undoable(&self, id: String, delete_files: bool) -> MutationResult {
        let library_id = match uuid::Uuid::parse_str(&id) {
            Ok(id) => id.to_string(),
            Err(error) => {
                impress_service_core::pipeline::context::report_refusal(
                    impress_service_core::refusal::codes::INVALID_ARGUMENT,
                    format!("Invalid library UUID: {error}"),
                );
                return fail();
            }
        };
        match self.store.get_library(library_id.clone()) {
            Ok(Some(_)) => {}
            Ok(None) => {
                impress_service_core::pipeline::context::report_refusal(
                    impress_service_core::refusal::codes::NOT_FOUND,
                    format!("Library {library_id} was not found"),
                );
                return fail();
            }
            Err(error) => {
                log("delete_library_undoable/preflight", &error);
                impress_service_core::pipeline::context::report_refusal(
                    impress_service_core::refusal::codes::STORE_ERROR,
                    error.to_string(),
                );
                return fail();
            }
        }
        if crate::backend::has_app_service_backend() {
            return if crate::backend::app_service_instance()
                .delete_library(library_id, delete_files)
                .await
            {
                ok_n(1)
            } else {
                fail()
            };
        }
        if delete_files {
            // The headless backend cannot safely locate or remove native file containers.
            let _ = crate::backend::app_service_instance()
                .delete_library(library_id, true)
                .await;
            return fail();
        }
        match self.store.delete_library_undoable(library_id) {
            Ok(_) => ok_n(1),
            Err(e) => {
                log("delete_library_undoable", e);
                impress_service_core::pipeline::context::report_refusal(
                    impress_service_core::refusal::codes::STORE_ERROR,
                    "Library deletion failed after preflight",
                );
                fail()
            }
        }
    }
    async fn delete_libraries(&self, ids: Vec<String>, delete_files: bool) -> u32 {
        let mut parsed = match ids
            .iter()
            .map(|id| uuid::Uuid::parse_str(id).map(|uuid| uuid.to_string()))
            .collect::<Result<Vec<_>, _>>()
        {
            Ok(ids) => ids,
            Err(error) => {
                impress_service_core::pipeline::context::report_refusal(
                    impress_service_core::refusal::codes::INVALID_ARGUMENT,
                    format!("One or more library IDs are invalid UUIDs: {error}"),
                );
                return 0;
            }
        };
        // A library is deleted and counted once even when an ID is repeated.
        let mut seen = std::collections::HashSet::new();
        parsed.retain(|id| seen.insert(id.clone()));
        if parsed.is_empty() {
            return 0;
        }

        // Preflight every row before cleanup or deletion so an unknown later
        // ID cannot leave an earlier library half-deleted.
        for id in &parsed {
            match self.store.get_library(id.clone()) {
                Ok(Some(_)) => {}
                Ok(None) => {
                    impress_service_core::pipeline::context::report_refusal(
                        impress_service_core::refusal::codes::NOT_FOUND,
                        format!("Library {id} was not found; batch was not changed"),
                    );
                    return 0;
                }
                Err(error) => {
                    log("delete_libraries/preflight", &error);
                    impress_service_core::pipeline::context::report_refusal(
                        impress_service_core::refusal::codes::STORE_ERROR,
                        error.to_string(),
                    );
                    return 0;
                }
            }
        }
        if crate::backend::has_app_service_backend() {
            return crate::backend::app_service_instance()
                .delete_libraries(parsed, delete_files)
                .await;
        }
        if delete_files {
            // Refuse before mutation when running without the app-owned file service.
            let _ = crate::backend::app_service_instance()
                .delete_libraries(parsed, true)
                .await;
            return 0;
        }

        let mut deleted = 0;
        for id in parsed {
            match self.store.delete_library_undoable(id) {
                Ok(_) => deleted += 1,
                Err(error) => {
                    log("delete_libraries", &error);
                    impress_service_core::pipeline::context::report_refusal(
                        impress_service_core::refusal::codes::STORE_ERROR,
                        format!("Batch deleted {deleted} libraries before a store error: {error}"),
                    );
                    break;
                }
            }
        }
        deleted
    }
    async fn get_default_library(&self) -> Option<LibraryRecord> {
        self.store
            .get_default_library()
            .ok()
            .flatten()
            .and_then(|row| {
                self.library_record(&row)
                    .map_err(|e| log("get_default_library", e))
                    .ok()
            })
    }
    async fn set_library_default(&self, id: String) -> MutationResult {
        match self.store.set_library_default(id) {
            Ok(_) => ok_n(1),
            Err(e) => {
                log("set_library_default", e);
                fail()
            }
        }
    }
    async fn get_inbox_library(&self) -> Option<LibraryRecord> {
        self.store
            .get_inbox_library()
            .ok()
            .flatten()
            .and_then(|row| {
                self.library_record(&row)
                    .map_err(|e| log("get_inbox_library", e))
                    .ok()
            })
    }

    async fn list_collections(&self, library_id: String) -> Vec<CollectionRecord> {
        self.store
            .list_collections(library_id)
            .map(|rs| rs.iter().map(CollectionRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("list_collections", e);
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
        self.store
            .create_collection(name, library_id, is_smart, query)
            .map(|r| CollectionRecord::from(&r))
            .map_err(|e| log("create_collection", e))
            .ok()
    }
    async fn add_to_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> MutationResult {
        let n = publication_ids.len() as u32;
        match self.store.add_to_collection(publication_ids, collection_id) {
            Ok(_) => ok_n(n),
            Err(e) => {
                log("add_to_collection", e);
                fail()
            }
        }
    }
    async fn remove_from_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> MutationResult {
        let n = publication_ids.len() as u32;
        match self
            .store
            .remove_from_collection(publication_ids, collection_id)
        {
            Ok(_) => ok_n(n),
            Err(e) => {
                log("remove_from_collection", e);
                fail()
            }
        }
    }
    async fn update_collection_members(
        &self,
        collection_id: String,
        identifiers: Vec<String>,
        action: String,
    ) -> CollectionMembershipResult {
        if !matches!(action.as_str(), "add" | "remove") {
            report_refusal(
                impress_service_core::refusal::codes::INVALID_ARGUMENT,
                "action must be 'add' or 'remove'",
            );
            return CollectionMembershipResult::default();
        }
        let Ok(collection_uuid) = uuid::Uuid::parse_str(&collection_id) else {
            report_refusal(
                impress_service_core::refusal::codes::INVALID_ARGUMENT,
                "collection_id must be a UUID",
            );
            return CollectionMembershipResult::default();
        };
        if identifiers.is_empty() {
            report_refusal(
                impress_service_core::refusal::codes::INVALID_ARGUMENT,
                "identifiers must contain at least one value",
            );
            return CollectionMembershipResult::default();
        }
        match self.collection_exists(&collection_uuid.to_string()) {
            Ok(true) => {}
            Ok(false) => {
                report_refusal(
                    impress_service_core::refusal::codes::NOT_FOUND,
                    format!("Collection not found: {collection_uuid}"),
                );
                return CollectionMembershipResult::default();
            }
            Err(error) => {
                log("update_collection_members.validate_collection", &error);
                report_refusal(
                    impress_service_core::refusal::codes::INTERNAL,
                    "Unable to validate collection",
                );
                return CollectionMembershipResult::default();
            }
        }

        let parsed: Vec<LocalPaperIdentifier> = identifiers
            .iter()
            .map(|value| LocalPaperIdentifier::parse(value))
            .collect();
        let mut resolved = Vec::new();
        let mut result = CollectionMembershipResult::default();
        for identifier in parsed {
            match self.publication_id_for_local_identifier(&identifier) {
                Ok(Some(publication_id)) => {
                    resolved.push(publication_id);
                    result.assigned.push(identifier.value().to_string());
                }
                Ok(None) => result.not_found.push(identifier.value().to_string()),
                Err(error) => {
                    log("update_collection_members.resolve_identifier", &error);
                    report_refusal(
                        impress_service_core::refusal::codes::INTERNAL,
                        "Unable to resolve local publication identifier",
                    );
                    return CollectionMembershipResult::default();
                }
            }
        }
        if resolved.is_empty() {
            return result;
        }
        let mutation = match action.as_str() {
            "add" => self
                .store
                .add_to_collection(resolved, collection_uuid.to_string()),
            "remove" => self
                .store
                .remove_from_collection(resolved, collection_uuid.to_string()),
            _ => unreachable!("action was validated above"),
        };
        if let Err(error) = mutation {
            log("update_collection_members.mutate", &error);
            report_refusal(
                impress_service_core::refusal::codes::VERB_FAILED,
                "Collection membership update failed",
            );
            return CollectionMembershipResult::default();
        }
        result
    }
    async fn list_collection_members(
        &self,
        collection_id: String,
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
            .list_collection_members(collection_id, sort, ascending, lim, off)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("list_collection_members", e);
                vec![]
            })
    }
    async fn purge_dismissed_from_collection(&self, collection_id: String) -> MutationResult {
        match self.store.purge_dismissed_from_collection(collection_id) {
            Ok(n) => ok_n(n),
            Err(e) => {
                log("purge_dismissed_from_collection", e);
                fail()
            }
        }
    }

    async fn list_publications(&self, limit: u32, offset: u32) -> Vec<PublicationSummary> {
        let lim = if limit == 0 { 50 } else { limit };
        self.store
            .query_all_publications(Some(lim), Some(offset))
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("list_publications", e);
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
        let lim = if limit == 0 { Some(50) } else { Some(limit) };
        let off = if offset == 0 { None } else { Some(offset) };
        let sort = if sort_field.is_empty() {
            "date_added".to_string()
        } else {
            sort_field
        };
        self.store
            .query_publications(library_id, sort, ascending, lim, off)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("query_publications", e);
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
        let lim = if limit == 0 { Some(50) } else { Some(limit) };
        let sort = if sort_field.is_empty() {
            "date_added".to_string()
        } else {
            sort_field
        };
        self.store
            .query_unread(parent_id, sort, ascending, lim, None)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("query_unread", e);
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
        let lim = if limit == 0 { Some(50) } else { Some(limit) };
        let sort = if sort_field.is_empty() {
            "date_added".to_string()
        } else {
            sort_field
        };
        self.store
            .query_starred(parent_id, sort, ascending, lim, None)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("query_starred", e);
                vec![]
            })
    }
    async fn query_recent(&self, limit: u32, parent_id: Option<String>) -> Vec<PublicationSummary> {
        let lim = if limit == 0 { 50 } else { limit };
        self.store
            .query_recent(lim, parent_id)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("query_recent", e);
                vec![]
            })
    }
    async fn search_publications(
        &self,
        query: String,
        limit: u32,
        offset: Option<u32>,
        filters: Option<PublicationSearchFilters>,
    ) -> Vec<PublicationSummary> {
        use std::collections::HashSet;

        let filters = filters.unwrap_or_default();
        // The HTTP route treats an invalid UUID filter as absent. Keep that
        // behavior at the generated boundary rather than returning a partial
        // result or changing the endpoint's accepted inputs.
        let library_id = filters
            .library
            .as_deref()
            .and_then(|id| uuid::Uuid::parse_str(id).ok())
            .map(|id| id.to_string());
        let collection_id = filters
            .collection
            .as_deref()
            .and_then(|id| uuid::Uuid::parse_str(id).ok())
            .map(|id| id.to_string());
        let collection_rows = match collection_id.as_ref() {
            Some(id) => match self.store.list_collection_members(
                id.clone(),
                "date_added".into(),
                false,
                Some(u32::MAX),
                Some(0),
            ) {
                Ok(rows) => Some(rows),
                Err(error) => {
                    log("search_publications", error);
                    return Vec::new();
                }
            },
            None => None,
        };

        let rows = if query.is_empty() {
            if let Some(library_id) = library_id.as_ref() {
                self.store.query_publications(
                    library_id.clone(),
                    "date_added".into(),
                    false,
                    None,
                    None,
                )
            } else if let Some(collection_rows) = collection_rows.as_ref() {
                Ok(collection_rows.clone())
            } else {
                match self.store.get_default_library() {
                    Ok(Some(default_library)) => self.store.query_publications(
                        default_library.id,
                        "date_added".into(),
                        false,
                        None,
                        None,
                    ),
                    Ok(None) => Ok(Vec::new()),
                    Err(error) => Err(error),
                }
            }
        } else {
            self.store.search_publications(
                query,
                library_id.clone(),
                "date_added".into(),
                false,
                None,
                None,
            )
        };

        let mut rows = match rows {
            Ok(rows) => rows,
            Err(error) => {
                log("search_publications", error);
                return Vec::new();
            }
        };

        // Library membership is pushed into the core query (which includes
        // both home-library and Contains membership). Collection membership
        // is checked against exact IDs, never names or a limited result page.
        let collection_members: Option<HashSet<String>> =
            collection_rows.map(|members| members.into_iter().map(|row| row.id).collect());
        let added_after = filters
            .added_after
            .as_deref()
            .and_then(|raw| chrono::DateTime::parse_from_rfc3339(raw).ok())
            .map(|date| date.timestamp_millis());
        let added_before = filters
            .added_before
            .as_deref()
            .and_then(|raw| chrono::DateTime::parse_from_rfc3339(raw).ok())
            .map(|date| date.timestamp_millis());

        rows.retain(|row| {
            if filters.read.is_some_and(|read| row.is_read != read) {
                return false;
            }
            if !filters.tags.as_ref().is_none_or(|tags| {
                tags.is_empty()
                    || tags.iter().any(|tag| {
                        let tag = tag.trim();
                        row.tags.iter().any(|item| item.path == tag)
                    })
            }) {
                return false;
            }
            if filters
                .flag
                .as_ref()
                .is_some_and(|flag| row.flag_color.as_ref() != Some(flag))
            {
                return false;
            }
            if added_after.is_some_and(|after| row.date_added <= after)
                || added_before.is_some_and(|before| row.date_added >= before)
            {
                return false;
            }
            if collection_members
                .as_ref()
                .is_some_and(|members| !members.contains(&row.id))
            {
                return false;
            }
            true
        });

        let start = offset.unwrap_or(0) as usize;
        let page_limit = if limit == 0 { 50 } else { limit } as usize;
        let end = start.saturating_add(page_limit).min(rows.len());
        rows.into_iter()
            .skip(start.min(end))
            .take(end.saturating_sub(start))
            .map(|row| PublicationSummary::from(&row))
            .collect()
    }
    async fn get_publication(&self, id: String) -> Option<PublicationSummary> {
        self.store
            .get_publication(id)
            .ok()
            .flatten()
            .as_ref()
            .map(PublicationSummary::from)
    }
    async fn get_publication_detail(&self, id: String) -> Option<PublicationDetailRecord> {
        self.store
            .get_publication_detail(id)
            .ok()
            .flatten()
            .as_ref()
            .map(PublicationDetailRecord::from)
    }
    async fn count_publications(&self) -> u32 {
        self.store.count_publications(None).unwrap_or(0)
    }
    async fn count_unread(&self, parent_id: Option<String>) -> u32 {
        self.store.count_unread(parent_id).unwrap_or(0)
    }
    async fn count_starred(&self, parent_id: Option<String>) -> u32 {
        self.store.count_starred(parent_id).unwrap_or(0)
    }
    async fn count_flagged(&self, color: Option<String>) -> u32 {
        self.store.count_flagged(color).unwrap_or(0)
    }

    async fn set_read(&self, ids: Vec<String>, read: bool) -> MutationResult {
        let n = ids.len() as u32;
        match self.store.set_read(ids, read) {
            Ok(_) => ok_n(n),
            Err(e) => {
                log("set_read", e);
                fail()
            }
        }
    }
    async fn set_starred(&self, ids: Vec<String>, starred: bool) -> MutationResult {
        let n = ids.len() as u32;
        match self.store.set_starred(ids, starred) {
            Ok(_) => ok_n(n),
            Err(e) => {
                log("set_starred", e);
                fail()
            }
        }
    }
    async fn set_flag(&self, ids: Vec<String>, color: Option<String>) -> MutationResult {
        let n = ids.len() as u32;
        match self.store.set_flag(ids, color, None, None) {
            Ok(_) => ok_n(n),
            Err(e) => {
                log("set_flag", e);
                fail()
            }
        }
    }
    async fn delete_publications_undoable(&self, ids: Vec<String>) -> MutationResult {
        match self.store.delete_publications_undoable(ids) {
            Ok(snapshots) => ok_n(snapshots.len() as u32),
            Err(e) => {
                log("delete_publications_undoable", e);
                fail()
            }
        }
    }
    async fn move_publications(
        &self,
        publication_ids: Vec<String>,
        to_library_id: String,
    ) -> MutationResult {
        let n = publication_ids.len() as u32;
        match self.store.move_publications(publication_ids, to_library_id) {
            Ok(_) => ok_n(n),
            Err(e) => {
                log("move_publications", e);
                fail()
            }
        }
    }
    async fn add_existing_papers_to_library(
        &self,
        library_id: String,
        identifiers: Vec<String>,
    ) -> LibraryMembershipResult {
        let Ok(library_uuid) = uuid::Uuid::parse_str(&library_id) else {
            report_refusal(
                impress_service_core::refusal::codes::INVALID_ARGUMENT,
                "library_id must be a UUID",
            );
            return LibraryMembershipResult::default();
        };
        if identifiers.is_empty() {
            report_refusal(
                impress_service_core::refusal::codes::INVALID_ARGUMENT,
                "identifiers must contain at least one value",
            );
            return LibraryMembershipResult::default();
        }
        match self.store.get_library(library_uuid.to_string()) {
            Ok(Some(_)) => {}
            Ok(None) => {
                report_refusal(
                    impress_service_core::refusal::codes::NOT_FOUND,
                    format!("Library not found: {library_uuid}"),
                );
                return LibraryMembershipResult::default();
            }
            Err(error) => {
                log("add_existing_papers_to_library.validate_library", &error);
                report_refusal(
                    impress_service_core::refusal::codes::INTERNAL,
                    "Unable to validate library",
                );
                return LibraryMembershipResult::default();
            }
        }

        let parsed: Vec<LocalPaperIdentifier> = identifiers
            .iter()
            .map(|value| LocalPaperIdentifier::parse(value))
            .collect();
        let mut resolved = Vec::new();
        let mut seen = std::collections::HashSet::new();
        let mut result = LibraryMembershipResult::default();
        for identifier in parsed {
            match self.publication_id_for_local_identifier(&identifier) {
                Ok(Some(publication_id)) => {
                    if seen.insert(publication_id.clone()) {
                        resolved.push(publication_id);
                    }
                    result.assigned.push(identifier.value().to_string());
                }
                Ok(None) => result.not_found.push(identifier.value().to_string()),
                Err(error) => {
                    log("add_existing_papers_to_library.resolve_identifier", &error);
                    report_refusal(
                        impress_service_core::refusal::codes::INTERNAL,
                        "Unable to resolve local publication identifier",
                    );
                    return LibraryMembershipResult::default();
                }
            }
        }
        if resolved.is_empty() {
            return result;
        }
        if let Err(error) = self
            .store
            .move_publications(resolved, library_uuid.to_string())
        {
            log("add_existing_papers_to_library.move", &error);
            report_refusal(
                impress_service_core::refusal::codes::VERB_FAILED,
                "Library membership update failed",
            );
            return LibraryMembershipResult::default();
        }
        result
    }
    async fn duplicate_publications(&self, ids: Vec<String>, to_library_id: String) -> Vec<String> {
        self.store
            .duplicate_publications(ids, to_library_id)
            .unwrap_or_else(|e| {
                log("duplicate_publications", e);
                vec![]
            })
    }
    async fn deduplicate_library(&self, library_id: String) -> u32 {
        self.store.deduplicate_library(library_id).unwrap_or(0)
    }

    async fn dismiss_paper(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> Option<DismissedPaperRecord> {
        self.store
            .dismiss_paper(doi, arxiv_id, bibcode, cite_key)
            .map(|r| DismissedPaperRecord::from(&r))
            .map_err(|e| log("dismiss_paper", e))
            .ok()
    }
    async fn is_paper_dismissed(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> bool {
        self.store
            .is_paper_dismissed(doi, arxiv_id, bibcode, cite_key)
            .unwrap_or(false)
    }
    async fn list_dismissed_papers(&self, limit: u32, offset: u32) -> Vec<DismissedPaperRecord> {
        let lim = if limit == 0 { Some(100) } else { Some(limit) };
        let off = if offset == 0 { None } else { Some(offset) };
        self.store
            .list_dismissed_papers(lim, off)
            .map(|rs| {
                rs.iter()
                    .map(DismissedPaperRecord::from)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_else(|e| {
                log("list_dismissed_papers", e);
                vec![]
            })
    }
    async fn list_muted_items(&self) -> Vec<MutedItemRecord> {
        self.store
            .list_muted_items(None)
            .map(|rs| rs.iter().map(MutedItemRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("list_muted_items", e);
                vec![]
            })
    }
    async fn create_muted_item(&self, mute_type: String, value: String) -> Option<MutedItemRecord> {
        self.store
            .create_muted_item(mute_type, value)
            .map(|r| MutedItemRecord::from(&r))
            .map_err(|e| log("create_muted_item", e))
            .ok()
    }

    async fn import_papers(&self, papers: Vec<PaperImport>, library_id: String) -> ImportSummary {
        let inputs: Vec<imbib_core::unified::shaped_queries::SearchResultInput> = papers
            .into_iter()
            .map(|p| imbib_core::unified::shaped_queries::SearchResultInput {
                bibtex: p.bibtex,
                doi: p.doi,
                arxiv_id: p.arxiv_id,
                bibcode: p.bibcode,
            })
            .collect();
        match self
            .store
            .batch_import_search_results(inputs, library_id, true)
        {
            Ok(r) => ImportSummary {
                imported_ids: r.imported_ids,
                existing_ids: r.existing_ids,
                dismissed_count: r.dismissed_count,
                failed_count: r.failed_count,
            },
            Err(e) => {
                log("import_papers", e);
                ImportSummary {
                    imported_ids: vec![],
                    existing_ids: vec![],
                    dismissed_count: 0,
                    failed_count: 0,
                }
            }
        }
    }

    async fn import_identifiers(
        &self,
        identifiers: Vec<String>,
        library_id: Option<String>,
        collection_id: Option<String>,
        download_pdfs: bool,
    ) -> IdentifierImportResult {
        crate::backend::app_service_instance()
            .import_identifiers(identifiers, library_id, collection_id, download_pdfs)
            .await
    }
    async fn import_bibtex(&self, bibtex: String, library_id: String) -> Vec<String> {
        self.store
            .import_bibtex(bibtex, library_id)
            .unwrap_or_else(|e| {
                log("import_bibtex", e);
                vec![]
            })
    }
    async fn import_bibtex_into_collection(
        &self,
        bibtex: String,
        library_id: String,
        collection_id: String,
    ) -> BibtexImportOutcome {
        self.store
            .import_bibtex_into(bibtex, library_id, Some(collection_id))
            .unwrap_or_else(|e| {
                log("import_bibtex_into_collection", e);
                BibtexImportOutcome::default()
            })
    }
    async fn export_bibtex(&self, ids: Vec<String>) -> String {
        // The former HTTP path accepted cite keys in its `keys=` query,
        // while store callers also pass UUIDs. Resolve both to the exact
        // publication ids the exporter expects, preserving input order.
        let mut resolved = Vec::with_capacity(ids.len());
        for identifier in ids {
            if uuid::Uuid::parse_str(&identifier).is_ok() {
                resolved.push(identifier);
                continue;
            }
            match self.store.find_by_cite_key(identifier, None) {
                Ok(Some(paper)) => resolved.push(paper.id),
                Ok(None) => {} // HTTP export likewise omitted unknown keys.
                Err(error) => {
                    log("export_bibtex/find_by_cite_key", &error);
                    impress_service_core::pipeline::context::report_refusal(
                        impress_service_core::refusal::codes::STORE_ERROR,
                        error.to_string(),
                    );
                    return String::new();
                }
            }
        }
        self.store.export_bibtex(resolved).unwrap_or_else(|error| {
            log("export_bibtex", &error);
            impress_service_core::pipeline::context::report_refusal(
                impress_service_core::refusal::codes::STORE_ERROR,
                error.to_string(),
            );
            String::new()
        })
    }
    async fn export_ris(&self, ids: Vec<String>) -> String {
        // Share the exact UUID/cite-key resolution and input-order behavior
        // with BibTeX export, then use the existing Rust parser, legacy
        // compatibility converter, and shared RIS formatter.
        let bibtex = self.export_bibtex(ids).await;
        let parsed = match imbib_core::bibtex::parse(bibtex) {
            Ok(parsed) if parsed.errors.is_empty() => parsed,
            Ok(parsed) => {
                let message = format!(
                    "RIS export could not parse canonical BibTeX: {:?}",
                    parsed.errors
                );
                log("export_ris/parse", &message);
                impress_service_core::pipeline::context::report_refusal(
                    impress_service_core::refusal::codes::STORE_ERROR,
                    message,
                );
                return String::new();
            }
            Err(error) => {
                log("export_ris/parse", &error);
                impress_service_core::pipeline::context::report_refusal(
                    impress_service_core::refusal::codes::STORE_ERROR,
                    error.to_string(),
                );
                return String::new();
            }
        };

        parsed
            .entries
            .into_iter()
            .map(imbib_core::ris::from_bibtex_legacy_export)
            .map(imbib_core::ris_format_entry)
            .collect::<Vec<_>>()
            .join("\n\n")
    }
    async fn export_all_bibtex(&self, library_id: String) -> String {
        self.store
            .export_all_bibtex(library_id)
            .unwrap_or_else(|e| {
                log("export_all_bibtex", e);
                String::new()
            })
    }

    async fn list_linked_files(&self, publication_id: String) -> Vec<LinkedFileRecord> {
        self.store
            .list_linked_files(publication_id)
            .map(|rs| rs.iter().map(LinkedFileRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("list_linked_files", e);
                vec![]
            })
    }
    async fn count_pdfs(&self, publication_id: String) -> u32 {
        self.store.count_pdfs(publication_id).unwrap_or(0)
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
        self.store
            .add_linked_file(
                publication_id,
                filename,
                relative_path,
                file_type,
                file_size,
                sha256,
                is_pdf,
            )
            .map(|r| LinkedFileRecord::from(&r))
            .map_err(|e| log("add_linked_file", e))
            .ok()
    }

    async fn retention_cleanup(
        &self,
        exploration_library_id: Option<String>,
    ) -> RetentionCleanupReport {
        retention::run(&self.store, exploration_library_id.as_deref())
    }
}

/// `retention_cleanup`'s implementation — its own module so the date-cutoff
/// arithmetic and the three source loops (ported from the deleted Swift
/// `RetentionCleanupService`) read as one unit, separate from the trait glue
/// above. See the trait method's doc for the invariants this must keep.
mod retention {
    use std::sync::OnceLock;

    use imbib_core::unified::store_api::ImbibStore;
    use impress_settings::SettingsStore;

    use super::RetentionCleanupReport;

    const EXPLORATION_LIBRARY_ID_KEY: &str = "imbib.internal.exploration_library_id";

    static SETTINGS: OnceLock<SettingsStore> = OnceLock::new();

    fn settings() -> &'static SettingsStore {
        SETTINGS
            .get_or_init(|| SettingsStore::open(crate::store_singleton::default_workspace_dir()))
    }

    fn setting_i64(key: &str, default: i64) -> i64 {
        settings()
            .get(key)
            .ok()
            .and_then(|r| r.value.as_i64())
            .unwrap_or(default)
    }

    fn setting_bool(key: &str, default: bool) -> bool {
        settings()
            .get(key)
            .ok()
            .and_then(|r| r.value.as_bool())
            .unwrap_or(default)
    }

    fn normalized_library_id(raw: &str) -> Option<String> {
        uuid::Uuid::parse_str(raw)
            .ok()
            .map(|id| id.hyphenated().to_string())
    }

    /// An explicit override wins (invalid values disable this cleanup). When
    /// omitted, read the pointer that
    /// LibraryManager copied from its legacy UserDefaults key into the shared
    /// settings file. Invalid values never broaden retention to a library.
    fn resolve_exploration_library_id(
        explicit: Option<&str>,
        settings: &SettingsStore,
    ) -> Option<String> {
        match explicit {
            Some(raw) => normalized_library_id(raw),
            None => settings
                .get(EXPLORATION_LIBRARY_ID_KEY)
                .ok()?
                .value
                .as_str()
                .and_then(normalized_library_id),
        }
    }

    /// Milliseconds-since-epoch cutoff `days` in the past; `None` when
    /// `days <= 0` (the registry's "0 = keep forever").
    fn cutoff_ms(days: i64) -> Option<i64> {
        if days <= 0 {
            return None;
        }
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        Some(now - days * 24 * 60 * 60 * 1000)
    }

    /// Record a removed paper as dismissed (by whichever identifiers it has)
    /// before deleting its row, so it never re-enters the inbox on the next
    /// import or feed refresh — the same order the Swift service used
    /// (`InboxManager.trackDismissal` before `store.deleteItem`).
    fn dismiss_and_delete(
        store: &ImbibStore,
        row: &imbib_core::unified::shaped_queries::BibliographyRow,
    ) -> bool {
        if let Err(error) = store.dismiss_paper(
            row.doi.clone(),
            row.arxiv_id.clone(),
            row.bibcode.clone(),
            Some(row.cite_key.clone()),
        ) {
            tracing::warn!(target: "workflow", paper_id = %row.id, %error, "retention dismissal failed; paper kept");
            return false;
        }
        match store.delete_item(row.id.clone()) {
            Ok(()) => true,
            Err(error) => {
                tracing::warn!(target: "workflow", paper_id = %row.id, %error, "retention delete failed");
                false
            }
        }
    }

    fn cleanup_inbox(store: &ImbibStore) -> u32 {
        let days = setting_i64("imbib.retention.inbox_days", 30);
        let Some(cutoff) = cutoff_ms(days) else {
            return 0; // 0 = keep forever, including when auto-remove-read is on
        };
        let auto_remove_read = setting_bool("imbib.retention.auto_remove_read", false);
        let Ok(Some(inbox)) = store.get_inbox_library() else {
            return 0;
        };
        let Ok(publications) =
            store.query_publications(inbox.id, "created".into(), true, None, None)
        else {
            return 0;
        };
        let mut removed = 0u32;
        for pub_row in &publications {
            if pub_row.is_starred {
                continue;
            }
            let is_old = pub_row.date_added < cutoff;
            let should_remove_as_read = auto_remove_read && pub_row.is_read;
            if is_old || should_remove_as_read {
                removed += u32::from(dismiss_and_delete(store, pub_row));
            }
        }
        removed
    }

    fn cleanup_feed_collections(store: &ImbibStore) -> u32 {
        let Ok(searches) = store.list_smart_searches(None) else {
            return 0;
        };
        let mut removed = 0u32;
        for search in &searches {
            let Some(days) = search.retention_days else {
                continue;
            };
            let Some(cutoff) = cutoff_ms(days as i64) else {
                continue;
            };
            // A smart search lives under a library, but its papers are linked
            // by Contains edges from the search itself. Querying library_id
            // here sweeps every paper in that library for one feed's policy.
            let Ok(publications) = store.list_collection_members(
                search.id.clone(),
                "created".into(),
                true,
                None,
                None,
            ) else {
                continue;
            };
            for pub_row in &publications {
                if pub_row.is_starred {
                    continue;
                }
                let is_old = pub_row.date_added < cutoff;
                let should_remove_as_read = search.auto_remove_read && pub_row.is_read;
                if is_old || should_remove_as_read {
                    removed += u32::from(dismiss_and_delete(store, pub_row));
                }
            }
        }
        removed
    }

    fn cleanup_exploration(store: &ImbibStore, exploration_library_id: Option<&str>) -> u32 {
        let Some(lib_id) = exploration_library_id else {
            return 0;
        };
        let days = setting_i64("imbib.retention.exploration_days", 30);
        let Some(cutoff) = cutoff_ms(days) else {
            return 0;
        };
        let Ok(searches) = store.list_smart_searches(Some(lib_id.to_string())) else {
            return 0;
        };
        let mut removed = 0u32;
        for search in &searches {
            let Some(executed) = search.last_executed else {
                continue; // never refreshed: age unknown, never swept
            };
            if executed < cutoff {
                match store.delete_smart_search(search.id.clone()) {
                    Ok(()) => removed += 1,
                    Err(error) => {
                        tracing::warn!(target: "workflow", search_id = %search.id, %error, "retention exploration delete failed")
                    }
                }
            }
        }
        removed
    }

    pub(super) fn run(
        store: &ImbibStore,
        exploration_library_id: Option<&str>,
    ) -> RetentionCleanupReport {
        let exploration_library_id =
            resolve_exploration_library_id(exploration_library_id, settings());
        tracing::info!(target: "workflow", exploration_library_id, "retention cleanup requested");
        // Match the retired Swift cleanup order. Removing an expired
        // exploration search first prevents its own feed policy from deleting
        // the papers linked to a search that no longer exists.
        let inbox_removed = cleanup_inbox(store);
        let exploration_removed = cleanup_exploration(store, exploration_library_id.as_deref());
        let feed_removed = cleanup_feed_collections(store);
        tracing::info!(target: "workflow", inbox_removed, exploration_removed, feed_removed, "retention cleanup saved");
        RetentionCleanupReport {
            inbox_removed,
            feed_removed,
            exploration_removed,
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use serde_json::Value;

        #[test]
        fn legacy_exploration_library_id_is_read_from_the_scratch_settings_store() {
            let dir = tempfile::tempdir().unwrap();
            let settings = SettingsStore::open(dir.path());
            let legacy_id = "5c000000-0000-4000-8000-000000000086";
            assert!(settings
                .import_legacy(EXPLORATION_LIBRARY_ID_KEY, &Value::String(legacy_id.into()))
                .unwrap());

            assert_eq!(
                resolve_exploration_library_id(None, &settings).as_deref(),
                Some(legacy_id)
            );
        }

        #[test]
        fn explicit_exploration_library_id_overrides_the_stored_pointer() {
            let dir = tempfile::tempdir().unwrap();
            let settings = SettingsStore::open(dir.path());
            let stored_id = "5c000000-0000-4000-8000-000000000086";
            let explicit_id = "5c000000-0000-4000-8000-000000000087";
            settings
                .set(EXPLORATION_LIBRARY_ID_KEY, &Value::String(stored_id.into()))
                .unwrap();

            assert_eq!(
                resolve_exploration_library_id(Some(explicit_id), &settings).as_deref(),
                Some(explicit_id)
            );
            assert_eq!(
                resolve_exploration_library_id(Some("not-a-uuid"), &settings),
                None
            );
        }

        #[test]
        fn invalid_internal_exploration_id_is_ignored() {
            let dir = tempfile::tempdir().unwrap();
            let settings = SettingsStore::open(dir.path());
            settings
                .set(
                    EXPLORATION_LIBRARY_ID_KEY,
                    &Value::String("not-a-uuid".into()),
                )
                .unwrap();

            assert_eq!(resolve_exploration_library_id(None, &settings), None);
        }
    }
}

// ===========================================================================
// Macro registration
// ===========================================================================

impress_service_impl! {
    service = ImbibLibraryService,
    safety = read_only,
    since = "0.1.0",
    effects = {
        reads: ["imbib/bibliography-entry", "imbib/linked-file", "imbib/tag-definition", "imbib/eink-mirror"],
        writes: [],
        reach: [],
    },
    impl = DefaultImbibLibraryService,
    instance = || crate::backend::library_service_instance(),
    methods = [
        // Library lifecycle
        list_libraries() -> Vec<LibraryRecord>,
        sidebar_view() -> SidebarView,
        create_library(
            /// Visible name of the new top-level library.
            name: String
        ) -> Option<LibraryRecord>,
        delete_library_undoable(
            /// UUID of the library to delete with its collections.
            id: String,
            /// Whether to remove its shared and legacy library-file containers.
            delete_files: bool
        ) -> MutationResult,
        delete_libraries(
            /// UUIDs of libraries to delete; every UUID and row is preflighted.
            ids: Vec<String>,
            /// Whether to remove their shared and legacy library-file containers.
            delete_files: bool
        ) -> u32,
        get_default_library() -> Option<LibraryRecord>,
        set_library_default(
            /// UUID of the library that should receive new papers by default.
            id: String
        ) -> MutationResult,
        get_inbox_library() -> Option<LibraryRecord>,
        // Collection lifecycle
        list_collections(
            /// UUID of the library whose collections are listed.
            library_id: String
        ) -> Vec<CollectionRecord>,
        create_collection(
            /// Visible collection name.
            name: String,
            /// UUID of the owning library.
            library_id: String,
            /// Whether the collection is populated by a saved query.
            is_smart: bool,
            /// Smart collection predicate, or null for a manual collection.
            query: Option<String>
        ) -> Option<CollectionRecord>,
        add_to_collection(
            /// UUIDs of existing publications to file.
            publication_ids: Vec<String>,
            /// UUID of the collection receiving the papers.
            collection_id: String
        ) -> MutationResult,
        remove_from_collection(
            /// UUIDs of publications to unfile without deleting them.
            publication_ids: Vec<String>,
            /// UUID of the collection to remove them from.
            collection_id: String
        ) -> MutationResult,
        update_collection_members(
            /// UUID of the collection to update.
            collection_id: String,
            /// Existing local cite keys, identifiers, or publication UUIDs.
            identifiers: Vec<String>,
            /// Add memberships or remove them (`add` or `remove`).
            action: String
        ) -> CollectionMembershipResult,
        list_collection_members(
            /// UUID of the collection to inspect.
            collection_id: String,
            /// Publication sort field, such as `title` or `date_added`.
            sort_field: String,
            /// Whether to sort in ascending order.
            ascending: bool,
            /// Maximum number of papers, with zero selecting the default of 50.
            limit: u32,
            /// Number of matching papers to skip.
            offset: u32
        ) -> Vec<PublicationSummary>,
        purge_dismissed_from_collection(
            /// UUID of the collection to remove dismissed members from.
            collection_id: String
        ) -> MutationResult,
        // Paper queries
        list_publications(
            /// Maximum number of papers, with zero selecting the default of 50.
            limit: u32,
            /// Number of matching papers to skip.
            offset: u32
        ) -> Vec<PublicationSummary>,
        query_publications(
            /// UUID of the library to search.
            library_id: String,
            /// Publication sort field, such as `title` or `date_added`.
            sort_field: String,
            /// Whether to sort in ascending order.
            ascending: bool,
            /// Maximum number of papers, with zero selecting the default of 50.
            limit: u32,
            /// Number of matching papers to skip.
            offset: u32
        ) -> Vec<PublicationSummary>,
        query_unread(
            /// Library UUID to scope the query, or null for all libraries.
            parent_id: Option<String>,
            /// Publication sort field, such as `title` or `date_added`.
            sort_field: String,
            /// Whether to sort in ascending order.
            ascending: bool,
            /// Maximum number of papers, with zero selecting the default of 50.
            limit: u32
        ) -> Vec<PublicationSummary>,
        query_starred(
            /// Library UUID to scope the query, or null for all libraries.
            parent_id: Option<String>,
            /// Publication sort field, such as `title` or `date_added`.
            sort_field: String,
            /// Whether to sort in ascending order.
            ascending: bool,
            /// Maximum number of papers, with zero selecting the default of 50.
            limit: u32
        ) -> Vec<PublicationSummary>,
        query_recent(
            /// Maximum number of papers, with zero selecting the default of 50.
            limit: u32,
            /// Library UUID to scope the query, or null for all libraries.
            parent_id: Option<String>
        ) -> Vec<PublicationSummary>,
        search_publications(
            /// Text to find in paper titles, authors, abstracts, or notes.
            query: String,
            /// Maximum number of papers, with zero selecting the default of 50.
            limit: u32,
            /// Number of matching papers to skip after filtering.
            offset: Option<u32>,
            /// Optional local-state, membership, tag, flag, and added-date filters.
            filters: Option<PublicationSearchFilters>
        ) -> Vec<PublicationSummary>,
        get_publication(
            /// UUID of the publication to summarize.
            id: String
        ) -> Option<PublicationSummary>,
        get_publication_detail(
            /// UUID of the publication whose full metadata is needed.
            id: String
        ) -> Option<PublicationDetailRecord>,
        count_publications() -> u32,
        count_unread(
            /// Library or collection UUID to scope the count, or null for all papers.
            parent_id: Option<String>
        ) -> u32,
        count_starred(
            /// Library or collection UUID to scope the count, or null for all papers.
            parent_id: Option<String>
        ) -> u32,
        count_flagged(
            /// Flag color to count, or null for every flagged paper.
            color: Option<String>
        ) -> u32,
        // Paper mutations
        set_read(
            /// UUIDs of publications whose read state changes.
            ids: Vec<String>,
            /// True to mark read; false to mark unread.
            read: bool
        ) -> MutationResult,
        set_starred(
            /// UUIDs of publications whose starred state changes.
            ids: Vec<String>,
            /// True to star; false to remove the star.
            starred: bool
        ) -> MutationResult,
        set_flag(
            /// UUIDs of publications whose flag changes.
            ids: Vec<String>,
            /// Flag color to set, or null to clear the flag.
            color: Option<String>
        ) -> MutationResult,
        delete_publications_undoable(
            /// UUIDs of the publications to permanently remove.
            ids: Vec<String>
        ) -> MutationResult,
        move_publications(
            /// UUIDs of publications to move.
            publication_ids: Vec<String>,
            /// UUID of the destination library.
            to_library_id: String
        ) -> MutationResult,
        add_existing_papers_to_library(
            /// UUID of the library that should own the papers.
            library_id: String,
            /// Existing local cite keys, identifiers, or publication UUIDs.
            identifiers: Vec<String>
        ) -> LibraryMembershipResult,
        duplicate_publications(
            /// UUIDs of publications to copy.
            ids: Vec<String>,
            /// UUID of the library that receives the copies.
            to_library_id: String
        ) -> Vec<String>,
        deduplicate_library(
            /// UUID of the library whose duplicate papers should be merged.
            library_id: String
        ) -> u32,
        // Dismissed/muted
        dismiss_paper(
            /// DOI to suppress on future imports, if known.
            doi: Option<String>,
            /// arXiv identifier to suppress, if known.
            arxiv_id: Option<String>,
            /// ADS bibcode to suppress, if known.
            bibcode: Option<String>,
            /// Citation key to suppress, if known.
            cite_key: Option<String>
        ) -> Option<DismissedPaperRecord>,
        is_paper_dismissed(
            /// DOI to check, if known.
            doi: Option<String>,
            /// arXiv identifier to check, if known.
            arxiv_id: Option<String>,
            /// ADS bibcode to check, if known.
            bibcode: Option<String>,
            /// Citation key to check, if known.
            cite_key: Option<String>
        ) -> bool,
        list_dismissed_papers(
            /// Maximum number of tombstones, with zero selecting the default of 100.
            limit: u32,
            /// Number of tombstones to skip.
            offset: u32
        ) -> Vec<DismissedPaperRecord>,
        list_muted_items() -> Vec<MutedItemRecord>,
        create_muted_item(
            /// Rule category, such as `author` or `keyword`.
            mute_type: String,
            /// Text to match within that category.
            value: String
        ) -> Option<MutedItemRecord>,
        // BibTeX I/O
        import_papers(
            /// Already-fetched papers, each with BibTeX and any known identifiers.
            papers: Vec<PaperImport>,
            /// UUID of the library receiving new papers.
            library_id: String
        ) -> ImportSummary,
        import_identifiers(
            /// Paper identifiers accepted by imbib, in caller order.
            identifiers: Vec<String>,
            /// UUID of the target library; omit to use imbib's default.
            library_id: Option<String>,
            /// UUID of a collection to receive added and duplicate papers.
            collection_id: Option<String>,
            /// Whether to start background PDF acquisition for newly fetched papers.
            download_pdfs: bool
        ) -> IdentifierImportResult,
        import_bibtex(
            /// BibTeX source containing one or more entries.
            bibtex: String,
            /// UUID of the target library.
            library_id: String
        ) -> Vec<String>,
        import_bibtex_into_collection(
            /// BibTeX source containing one or more entries.
            bibtex: String,
            /// UUID of the target library.
            library_id: String,
            /// UUID of the collection receiving the imported papers.
            collection_id: String
        ) -> BibtexImportOutcome,
        export_bibtex(
            /// Publication UUIDs or cite keys to export, in requested order.
            ids: Vec<String>
        ) -> String,
        export_ris(
            /// Publication UUIDs or cite keys to export, in requested order.
            ids: Vec<String>
        ) -> String,
        export_all_bibtex(
            /// UUID of the library whose papers should be exported.
            library_id: String
        ) -> String,
        // Linked files
        list_linked_files(
            /// UUID of the publication whose attachments are listed.
            publication_id: String
        ) -> Vec<LinkedFileRecord>,
        count_pdfs(
            /// UUID of the publication whose linked PDFs are counted.
            publication_id: String
        ) -> u32,
        add_linked_file(
            /// UUID of the publication receiving the file link.
            publication_id: String,
            /// File name shown in the paper's attachments.
            filename: String,
            /// Optional path relative to the library's file root.
            relative_path: Option<String>,
            /// Optional MIME type or file extension description.
            file_type: Option<String>,
            /// File size in bytes.
            file_size: i64,
            /// Optional SHA-256 content hash.
            sha256: Option<String>,
            /// Whether this linked file is a PDF.
            is_pdf: bool
        ) -> Option<LinkedFileRecord>,
        // Retention
        retention_cleanup(
            /// Exploration library UUID to sweep, or null to leave exploration untouched.
            exploration_library_id: Option<String>
        ) -> RetentionCleanupReport,
    ],
}

#[cfg(test)]
mod identifier_import_schema_tests {
    #[test]
    fn identifier_import_is_a_single_library_verb_with_the_approved_arguments() {
        let verb =
            impress_service_core::VerbDescriptor::find("imbib-library-service_import-identifiers")
                .expect("identifier import verb is registered");
        let schema = (verb.input_schema)();
        let properties = schema["properties"].as_object().unwrap();
        assert!(properties.contains_key("identifiers"));
        assert!(properties.contains_key("library_id"));
        assert!(properties.contains_key("collection_id"));
        assert!(properties.contains_key("download_pdfs"));
        assert_eq!(verb.service, "imbib-library-service");
    }
}

// Legacy compatibility — bin crates that used the old singleton-init can keep working.
pub fn init_imbib_library_service(store_path: std::path::PathBuf) -> Result<(), String> {
    crate::store_singleton::init_imbib_store(store_path)
}

#[cfg(test)]
mod tests {
    use super::{
        CollectionMembershipResult, ImbibLibraryService, LibraryMembershipResult,
        LocalPaperIdentifier,
    };
    use impress_service_core::McpToolDescriptor;

    #[tokio::test]
    async fn collection_membership_resolves_route_identifiers_in_order_and_mutates_exact_rows() {
        let store = imbib_core::unified::store_api::ImbibStore::open_in_memory().unwrap();
        let library = store.create_library("Membership contract".into()).unwrap();
        let library_id = library.id.clone();
        let collection = store
            .create_collection("Membership target".into(), library_id.clone(), false, None)
            .unwrap();
        let ids = store
            .import_bibtex(
                "@article{Member2026, title={Collection member}, doi={10.1234/member}}".into(),
                library_id,
            )
            .unwrap();
        let publication_id = ids[0].clone();
        let service = super::DefaultImbibLibraryService::new(store.clone());

        let added = service
            .update_collection_members(
                collection.id.clone(),
                vec![
                    " Member2026 ".into(),
                    format!("doi:{}", "10.1234/member"),
                    publication_id.to_ascii_uppercase(),
                    "missing-key".into(),
                    "Member2026".into(),
                ],
                "add".into(),
            )
            .await;
        assert_eq!(
            added,
            CollectionMembershipResult {
                assigned: vec![
                    "Member2026".into(),
                    "10.1234/member".into(),
                    publication_id.to_ascii_uppercase(),
                    "Member2026".into(),
                ],
                not_found: vec!["missing-key".into()],
            }
        );
        let members = store
            .list_collection_members(collection.id.clone(), "title".into(), true, None, None)
            .unwrap();
        assert_eq!(members.len(), 1);
        assert_eq!(members[0].id, publication_id);

        let removed = service
            .update_collection_members(
                collection.id.clone(),
                vec!["Member2026".into(), "not-present".into()],
                "remove".into(),
            )
            .await;
        assert_eq!(removed.assigned, vec![String::from("Member2026")]);
        assert_eq!(removed.not_found, vec![String::from("not-present")]);
        assert!(store
            .list_collection_members(collection.id, "title".into(), true, None, None)
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn library_membership_resolves_identifiers_and_moves_only_found_papers() {
        let store = imbib_core::unified::store_api::ImbibStore::open_in_memory().unwrap();
        let source = store.create_library("Source library".into()).unwrap();
        let destination = store.create_library("Destination library".into()).unwrap();
        let publication_id = store
            .import_bibtex(
                "@article{LibraryMove2026, title={Library move}, doi={10.1234/library-move}}"
                    .into(),
                source.id.clone(),
            )
            .unwrap()
            .remove(0);
        let service = super::DefaultImbibLibraryService::new(store.clone());

        let moved = service
            .add_existing_papers_to_library(
                destination.id.clone(),
                vec![
                    " LibraryMove2026 ".into(),
                    "doi:10.1234/library-move".into(),
                    "missing-key".into(),
                ],
            )
            .await;
        assert_eq!(
            moved,
            LibraryMembershipResult {
                assigned: vec!["LibraryMove2026".into(), "10.1234/library-move".into()],
                not_found: vec!["missing-key".into()],
            }
        );
        let in_destination = store
            .query_publications(destination.id.clone(), "title".into(), true, None, None)
            .unwrap();
        assert_eq!(in_destination.len(), 1);
        assert_eq!(in_destination[0].id, publication_id);
        assert!(store
            .query_publications(source.id, "title".into(), true, None, None)
            .unwrap()
            .is_empty());

        let missing_library = service
            .add_existing_papers_to_library(
                uuid::Uuid::new_v4().to_string(),
                vec!["LibraryMove2026".into()],
            )
            .await;
        assert!(missing_library.assigned.is_empty());
        assert_eq!(
            store
                .query_publications(destination.id, "title".into(), true, None, None)
                .unwrap()
                .len(),
            1
        );
    }

    #[tokio::test]
    async fn collection_membership_refuses_invalid_action_and_missing_collection_without_writes() {
        let store = imbib_core::unified::store_api::ImbibStore::open_in_memory().unwrap();
        let library = store.create_library("Membership errors".into()).unwrap();
        let collection = store
            .create_collection("Existing target".into(), library.id.clone(), false, None)
            .unwrap();
        let publication_id = store
            .import_bibtex(
                "@article{StillUnfiled2026, title={Must stay unfiled}}".into(),
                library.id,
            )
            .unwrap()
            .remove(0);
        let service = super::DefaultImbibLibraryService::new(store.clone());

        let invalid_action = service
            .update_collection_members(
                collection.id.clone(),
                vec!["StillUnfiled2026".into()],
                "replace".into(),
            )
            .await;
        assert!(invalid_action.assigned.is_empty());
        assert!(invalid_action.not_found.is_empty());

        let missing_collection = service
            .update_collection_members(
                uuid::Uuid::new_v4().to_string(),
                vec!["StillUnfiled2026".into()],
                "add".into(),
            )
            .await;
        assert!(missing_collection.assigned.is_empty());
        assert!(missing_collection.not_found.is_empty());
        assert!(store
            .list_collection_members(collection.id, "title".into(), true, None, None)
            .unwrap()
            .is_empty());
        assert!(store.get_publication(publication_id).unwrap().is_some());
    }

    #[test]
    fn paper_identifier_parser_matches_route_local_forms() {
        assert!(matches!(
            LocalPaperIdentifier::parse(" doi:10.1234/example "),
            LocalPaperIdentifier::Doi(value, normalized)
                if value == "10.1234/example" && normalized == value
        ));
        assert!(matches!(
            LocalPaperIdentifier::parse("DOI:10.1234/example"),
            LocalPaperIdentifier::Doi(value, normalized)
                if value == "DOI:10.1234/example" && normalized == value
        ));
        assert!(matches!(
            LocalPaperIdentifier::parse("arXiv:2401.12345v2"),
            LocalPaperIdentifier::Arxiv(value, _) if value == "2401.12345v2"
        ));
        assert!(matches!(
            LocalPaperIdentifier::parse("hep-th/9901001v2"),
            LocalPaperIdentifier::Arxiv(value, _) if value == "hep-th/9901001v2"
        ));
        assert!(matches!(
            LocalPaperIdentifier::parse("2401.12345"),
            LocalPaperIdentifier::Arxiv(_, _)
        ));
        assert!(matches!(
            LocalPaperIdentifier::parse("2023ApJ...950L..22A"),
            LocalPaperIdentifier::Bibcode(_, _)
        ));
        assert!(matches!(
            LocalPaperIdentifier::parse("123456"),
            LocalPaperIdentifier::Pmid(_, _)
        ));
        assert!(matches!(
            LocalPaperIdentifier::parse("W123"),
            LocalPaperIdentifier::Unsupported(_)
        ));
    }

    #[tokio::test]
    async fn bibtex_export_accepts_http_cite_keys_and_store_ids() {
        let store = imbib_core::unified::store_api::ImbibStore::open_in_memory().unwrap();
        let library = store.create_library("Research".into()).unwrap();
        let id = store
            .import_bibtex(
                "@article{Key2026, title={Native transport parity}}".into(),
                library.id,
            )
            .unwrap()
            .remove(0);
        let service = super::DefaultImbibLibraryService::new(store);
        let by_key = service.export_bibtex(vec!["Key2026".into()]).await;
        let by_id = service.export_bibtex(vec![id]).await;
        assert!(by_key.contains("Key2026"), "{by_key}");
        assert_eq!(by_key, by_id);
    }

    #[tokio::test]
    async fn publication_search_filters_membership_before_pagination() {
        let store = imbib_core::unified::store_api::ImbibStore::open_in_memory().unwrap();
        let first_library = store.create_library("Same name".into()).unwrap();
        let second_library = store.create_library("Same name".into()).unwrap();
        let first = store
            .import_bibtex(
                "@article{First2026, title={P5c9 Shared term alpha}}".into(),
                first_library.id.clone(),
            )
            .unwrap()
            .remove(0);
        let second = store
            .import_bibtex(
                "@article{Second2026, title={P5c9 Shared term beta}}".into(),
                second_library.id.clone(),
            )
            .unwrap()
            .remove(0);
        let third = store
            .import_bibtex(
                "@article{Third2026, title={P5c9 Shared term gamma}}".into(),
                second_library.id.clone(),
            )
            .unwrap()
            .remove(0);
        let collection = store
            .create_collection("P5c9 subset".into(), first_library.id.clone(), false, None)
            .unwrap();
        store
            .add_to_collection(
                vec![first.clone(), second.clone(), third.clone()],
                collection.id.clone(),
            )
            .unwrap();
        store
            .create_tag("methods/query".into(), None, None)
            .unwrap();
        store
            .add_tag(vec![second.clone()], "methods/query".into())
            .unwrap();
        store.set_read(vec![second.clone()], true).unwrap();
        store
            .set_flag(vec![second.clone()], Some("red".into()), None, None)
            .unwrap();

        let service = super::DefaultImbibLibraryService::new(store);
        let filters = |library: Option<String>, collection: Option<String>| {
            Some(super::PublicationSearchFilters {
                library,
                collection,
                ..Default::default()
            })
        };
        let same_named_library = service
            .search_publications(
                "P5c9 Shared term".into(),
                50,
                None,
                filters(Some(second_library.id.clone()), None),
            )
            .await;
        let second_and_third: std::collections::HashSet<_> = same_named_library
            .iter()
            .map(|row| row.id.as_str())
            .collect();
        assert_eq!(same_named_library.len(), 2);
        assert!(second_and_third.contains(second.as_str()));
        assert!(second_and_third.contains(third.as_str()));

        let collection_only = service
            .search_publications(
                "".into(),
                50,
                None,
                filters(None, Some(collection.id.clone())),
            )
            .await;
        assert_eq!(collection_only.len(), 3);
        let collection_in_library = service
            .search_publications(
                "".into(),
                50,
                None,
                filters(Some(second_library.id.clone()), Some(collection.id)),
            )
            .await;
        assert_eq!(collection_in_library.len(), 2);
        assert!(collection_in_library.iter().all(|row| row.id != first));

        let filtered_page = service
            .search_publications(
                "P5c9 Shared term".into(),
                1,
                Some(1),
                Some(super::PublicationSearchFilters {
                    library: Some(second_library.id.clone()),
                    ..Default::default()
                }),
            )
            .await;
        assert_eq!(filtered_page.len(), 1);
        assert_ne!(filtered_page[0].id, first);

        let state_filtered = service
            .search_publications(
                "P5c9 Shared term".into(),
                50,
                None,
                Some(super::PublicationSearchFilters {
                    read: Some(true),
                    tags: Some(vec!["methods/query".into()]),
                    flag: Some("red".into()),
                    ..Default::default()
                }),
            )
            .await;
        assert_eq!(state_filtered.len(), 1);
        assert_eq!(state_filtered[0].id, second);

        let second_added_at = service
            .get_publication_detail(second.clone())
            .await
            .unwrap()
            .date_added;
        let exact_boundary = chrono::DateTime::from_timestamp_millis(second_added_at)
            .unwrap()
            .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        let after_exact_boundary = service
            .search_publications(
                "P5c9 Shared term".into(),
                50,
                None,
                Some(super::PublicationSearchFilters {
                    added_after: Some(exact_boundary.clone()),
                    ..Default::default()
                }),
            )
            .await;
        assert!(after_exact_boundary.iter().all(|row| row.id != second));
        let before_exact_boundary = service
            .search_publications(
                "P5c9 Shared term".into(),
                50,
                None,
                Some(super::PublicationSearchFilters {
                    added_before: Some(exact_boundary),
                    ..Default::default()
                }),
            )
            .await;
        assert!(before_exact_boundary.iter().all(|row| row.id != second));

        let after_future = service
            .search_publications(
                "P5c9 Shared term".into(),
                50,
                None,
                Some(super::PublicationSearchFilters {
                    added_after: Some("2999-01-01T00:00:00Z".into()),
                    ..Default::default()
                }),
            )
            .await;
        assert!(after_future.is_empty());
    }

    #[tokio::test]
    async fn ris_export_preserves_identifier_order_and_omits_unknown_keys() {
        let store = imbib_core::unified::store_api::ImbibStore::open_in_memory().unwrap();
        let library = store.create_library("RIS export scratch".into()).unwrap();
        let first_id = store
            .import_bibtex(
                "@article{FirstRIS2026, title={First RIS paper}, author={Doe, Jane}}".into(),
                library.id.clone(),
            )
            .unwrap()
            .remove(0);
        store
            .import_bibtex(
                "@article{SecondRIS2026, title={Second RIS paper}, author={Roe, John}}".into(),
                library.id,
            )
            .unwrap();
        let service = super::DefaultImbibLibraryService::new(store);

        let ris = service
            .export_ris(vec![
                "SecondRIS2026".into(),
                "NoSuchRISKey".into(),
                first_id.clone(),
            ])
            .await;
        let second = ris.find("TI  - Second RIS paper").unwrap();
        let first = ris.find("TI  - First RIS paper").unwrap();
        assert!(
            second < first,
            "RIS entries did not preserve request order: {ris}"
        );
        assert!(!ris.contains("NoSuchRISKey"));

        let by_key = service.export_ris(vec!["FirstRIS2026".into()]).await;
        let by_id = service.export_ris(vec![first_id]).await;
        assert_eq!(by_key, by_id);
    }

    #[test]
    fn library_service_methods_registered() {
        let names: Vec<&str> = McpToolDescriptor::iter()
            .filter(|d| d.name.starts_with("imbib-library-service_"))
            .map(|d| d.name)
            .collect();
        // 45 methods registered (see methods = [...] above)
        assert!(
            names.len() >= 40,
            "expected >=40 library-service methods, got {}: {names:?}",
            names.len()
        );
    }

    /// Tier A: `retention_cleanup` against a scratch store, pointed at a
    /// scratch settings workspace so the test never reads (or depends on)
    /// this machine's real `imbib.retention.*` values. Covers the invariant
    /// this verb exists to keep: a starred paper is never removed, whatever
    /// its read state or the auto-remove-read setting.
    #[tokio::test]
    async fn retention_cleanup_only_removes_eligible_papers_in_each_source() {
        // Isolate the settings workspace this test's `retention_cleanup`
        // call resolves (`store_singleton::default_workspace_dir`) from
        // whatever this machine's real imbib app has written.
        let settings_dir = tempfile::tempdir().unwrap();
        std::env::set_var(
            "IMBIB_STORE_PATH",
            settings_dir.path().join("impress.sqlite"),
        );
        let settings = impress_settings::SettingsStore::open(settings_dir.path());
        settings
            .set(
                "imbib.retention.auto_remove_read",
                &serde_json::Value::Bool(true),
            )
            .expect("set auto_remove_read");

        let store = imbib_core::unified::store_api::ImbibStore::open_in_memory().unwrap();
        let inbox = store.create_inbox_library("Inbox".into()).unwrap();

        let read_id = store
            .import_bibtex("@article{Read2024, title={Read}}".into(), inbox.id.clone())
            .unwrap()
            .remove(0);
        store.set_read(vec![read_id.clone()], true).unwrap();

        let starred_read_id = store
            .import_bibtex(
                "@article{StarredRead2024, title={Starred and read}}".into(),
                inbox.id.clone(),
            )
            .unwrap()
            .remove(0);
        store.set_read(vec![starred_read_id.clone()], true).unwrap();
        store
            .set_starred(vec![starred_read_id.clone()], true)
            .unwrap();

        let unread_id = store
            .import_bibtex(
                "@article{Unread2024, title={Unread}}".into(),
                inbox.id.clone(),
            )
            .unwrap()
            .remove(0);

        // The feed's parent library contains unrelated read papers too. Its
        // retention policy may touch only Contains-linked members of this
        // smart search, including when both papers are equally eligible.
        let feed_library = store.create_library("Feeds".into()).unwrap();
        let feed = store
            .create_smart_search(
                "Feed".into(),
                "topic".into(),
                feed_library.id.clone(),
                None,
                100,
                false,
                false,
                3600,
            )
            .unwrap();
        store
            .update_int_field(feed.id.clone(), "retention_days".into(), Some(1))
            .unwrap();
        store
            .update_bool_field(feed.id.clone(), "auto_remove_read".into(), true)
            .unwrap();
        let member_id = store
            .import_bibtex(
                "@article{FeedMember2024, title={Feed member}}".into(),
                feed_library.id.clone(),
            )
            .unwrap()
            .remove(0);
        let unrelated_id = store
            .import_bibtex(
                "@article{Unrelated2024, title={Unrelated}}".into(),
                feed_library.id.clone(),
            )
            .unwrap()
            .remove(0);
        let starred_member_id = store
            .import_bibtex(
                "@article{StarredFeed2024, title={Starred feed member}}".into(),
                feed_library.id.clone(),
            )
            .unwrap()
            .remove(0);
        store
            .add_to_collection(vec![member_id.clone(), starred_member_id.clone()], feed.id)
            .unwrap();
        store
            .set_read(
                vec![
                    member_id.clone(),
                    unrelated_id.clone(),
                    starred_member_id.clone(),
                ],
                true,
            )
            .unwrap();
        store
            .set_starred(vec![starred_member_id.clone()], true)
            .unwrap();

        let service = super::DefaultImbibLibraryService::new(store.clone());
        let report = super::ImbibLibraryService::retention_cleanup(&service, None).await;

        assert_eq!(report.inbox_removed, 1, "only the read, unstarred paper");
        assert_eq!(report.feed_removed, 1, "only the unstarred feed member");
        assert_eq!(report.exploration_removed, 0);

        assert!(store.get_publication(read_id).unwrap().is_none());
        assert!(store.get_publication(starred_read_id).unwrap().is_some());
        assert!(store.get_publication(unread_id).unwrap().is_some());
        assert!(store.get_publication(member_id).unwrap().is_none());
        assert!(store.get_publication(unrelated_id).unwrap().is_some());
        assert!(store.get_publication(starred_member_id).unwrap().is_some());

        // The removed inbox paper is recorded dismissed so it never
        // re-enters the inbox (imbib CLAUDE.md's dismissed-papers
        // invariant), and it never touched an undo stack — `delete_item`
        // is a plain store delete, not `update_with_undo`.
        assert!(store
            .is_paper_dismissed(None, None, None, Some("Read2024".into()))
            .unwrap());
        assert!(store
            .is_paper_dismissed(None, None, None, Some("FeedMember2024".into()))
            .unwrap());
        assert!(!store
            .is_paper_dismissed(None, None, None, Some("Unrelated2024".into()))
            .unwrap());

        // The legacy service treats zero inbox days as an unconditional keep
        // forever setting, even when auto-remove-read is enabled.
        settings
            .set("imbib.retention.inbox_days", &serde_json::json!(0))
            .unwrap();
        let read_forever_id = store
            .import_bibtex(
                "@article{ReadForever2024, title={Read forever}}".into(),
                inbox.id,
            )
            .unwrap()
            .remove(0);
        store.set_read(vec![read_forever_id.clone()], true).unwrap();
        let report = super::ImbibLibraryService::retention_cleanup(&service, None).await;
        assert_eq!(report.inbox_removed, 0);
        assert!(store.get_publication(read_forever_id).unwrap().is_some());

        // Swift removed expired exploration searches before sweeping feeds.
        // If a search has both policies, its linked paper belongs to the
        // surviving library and must not be deleted with the stale search.
        settings
            .set("imbib.retention.exploration_days", &serde_json::json!(1))
            .unwrap();
        let exploration = store.create_library("Exploration".into()).unwrap();
        let expired_search = store
            .create_smart_search(
                "Expired exploration".into(),
                "topic".into(),
                exploration.id.clone(),
                None,
                100,
                false,
                false,
                3600,
            )
            .unwrap();
        store
            .update_int_field(expired_search.id.clone(), "retention_days".into(), Some(1))
            .unwrap();
        store
            .update_bool_field(expired_search.id.clone(), "auto_remove_read".into(), true)
            .unwrap();
        let two_days_ago = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as i64
            - 2 * 24 * 60 * 60 * 1000;
        store
            .update_int_field(
                expired_search.id.clone(),
                "last_executed".into(),
                Some(two_days_ago),
            )
            .unwrap();
        let exploration_paper_id = store
            .import_bibtex(
                "@article{ExplorationPaper2024, title={Exploration paper}}".into(),
                exploration.id.clone(),
            )
            .unwrap()
            .remove(0);
        store
            .add_to_collection(
                vec![exploration_paper_id.clone()],
                expired_search.id.clone(),
            )
            .unwrap();
        store
            .set_read(vec![exploration_paper_id.clone()], true)
            .unwrap();

        let report =
            super::ImbibLibraryService::retention_cleanup(&service, Some(exploration.id)).await;
        assert_eq!(report.exploration_removed, 1);
        assert_eq!(report.feed_removed, 0);
        assert!(store.get_smart_search(expired_search.id).unwrap().is_none());
        assert!(store
            .get_publication(exploration_paper_id)
            .unwrap()
            .is_some());
        assert!(!store
            .is_paper_dismissed(None, None, None, Some("ExplorationPaper2024".into()))
            .unwrap());
    }

    #[tokio::test]
    async fn delete_libraries_preflights_every_existing_row_before_mutating() {
        let store = imbib_core::unified::store_api::ImbibStore::open_in_memory().unwrap();
        let first = store
            .create_library("First scratch library".into())
            .unwrap();
        let missing = "50000000-0000-4000-8000-000000000001".to_string();
        let service = super::DefaultImbibLibraryService::new(store.clone());

        let deleted = service
            .delete_libraries(vec![first.id.clone(), missing.clone()], false)
            .await;

        assert_eq!(deleted, 0);
        assert!(store.get_library(first.id).unwrap().is_some());
        assert!(store.get_library(missing).unwrap().is_none());
    }

    #[tokio::test]
    async fn repeated_library_ids_are_deleted_and_counted_once() {
        let store = imbib_core::unified::store_api::ImbibStore::open_in_memory().unwrap();
        let library = store
            .create_library("Duplicate deletion fixture".into())
            .unwrap();
        let service = super::DefaultImbibLibraryService::new(store.clone());
        assert_eq!(
            service
                .delete_libraries(vec![library.id.clone(), library.id.clone()], false)
                .await,
            1
        );
        assert!(store.get_library(library.id).unwrap().is_none());
    }

    #[test]
    fn delete_verbs_publish_the_filesystem_choice_and_batch_signature() {
        let single = impress_service_core::VerbDescriptor::find(
            "imbib-library-service_delete-library-undoable",
        )
        .unwrap();
        let single_schema = (single.input_schema)();
        assert!(single_schema["properties"].get("delete_files").is_some());

        let batch =
            impress_service_core::VerbDescriptor::find("imbib-library-service_delete-libraries")
                .unwrap();
        let batch_schema = (batch.input_schema)();
        assert!(batch_schema["properties"].get("ids").is_some());
        assert!(batch_schema["properties"].get("delete_files").is_some());
        assert_eq!(batch.service, "imbib-library-service");
    }
}
