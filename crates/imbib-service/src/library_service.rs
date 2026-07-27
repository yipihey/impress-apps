//! `ImbibLibraryService` — library / collection / paper CRUD + queries,
//! paper-level mutations, linked files, and BibTeX I/O.
//!
//! Tag-specific operations live in `tags_service`. Identifier lookups and
//! smart searches live in `search_service`. Undo lives in `undo_service`.

use std::sync::Arc;

use imbib_core::unified::store_api::ImbibStore;
use impress_service_core::async_trait;
use impress_service_macros::{impress_service, impress_service_impl};
use serde::{Deserialize, Deserializer, Serialize};

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
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct MutationResult {
    pub affected_count: u32,
    pub ok: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, schemars::JsonSchema)]
pub struct LibraryRecord {
    pub id: String,
    pub name: String,
    // imbib's existing HTTP API returns camelCase (`isDefault`, `isInbox`,
    // `paperCount`); the SQLite-backed default impl emits snake_case. Accept
    // both on the decode side so the HTTP backend "just works" against the
    // live app without requiring the Swift router to change response shape.
    #[serde(alias = "isDefault", default)]
    pub is_default: bool,
    // create-library response omits isInbox — default to false.
    #[serde(alias = "isInbox", default)]
    pub is_inbox: bool,
    #[serde(alias = "paperCount", default)]
    pub publication_count: i32,
}

impl From<&imbib_core::unified::shaped_queries::LibraryRow> for LibraryRecord {
    fn from(r: &imbib_core::unified::shaped_queries::LibraryRow) -> Self {
        Self {
            id: r.id.clone(),
            name: r.name.clone(),
            is_default: r.is_default,
            is_inbox: r.is_inbox,
            publication_count: r.publication_count,
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

#[impress_service]
pub trait ImbibLibraryService: Send + Sync + 'static {
    // ---- Library lifecycle ----
    /// List all libraries in imbib. Libraries are top-level containers for
    /// papers.
    #[impress_method]
    async fn list_libraries(&self) -> Vec<LibraryRecord>;
    /// Create a new library in imbib. Libraries are top-level containers
    /// for papers, separate from collections. Use this when asked to create
    /// a new library for a topic or project.
    #[impress_method]
    async fn create_library(&self, name: String) -> Option<LibraryRecord>;
    #[impress_method]
    async fn delete_library_undoable(&self, id: String) -> MutationResult;
    #[impress_method]
    async fn get_default_library(&self) -> Option<LibraryRecord>;
    #[impress_method]
    async fn set_library_default(&self, id: String) -> MutationResult;
    #[impress_method]
    async fn get_inbox_library(&self) -> Option<LibraryRecord>;

    // ---- Collection lifecycle ----
    /// List all collections in the imbib library. Collections organize
    /// papers into groups.
    #[impress_method]
    async fn list_collections(&self, library_id: String) -> Vec<CollectionRecord>;
    /// Create a new collection to organize papers. Collections can be
    /// regular (manual) or smart (auto-populated by predicate).
    #[impress_method]
    async fn create_collection(
        &self,
        name: String,
        library_id: String,
        is_smart: bool,
        query: Option<String>,
    ) -> Option<CollectionRecord>;
    /// Add papers to an existing collection.
    #[impress_method]
    async fn add_to_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> MutationResult;
    /// Remove papers from a collection (does not delete them).
    #[impress_method]
    async fn remove_from_collection(
        &self,
        publication_ids: Vec<String>,
        collection_id: String,
    ) -> MutationResult;
    /// List all papers in a specific collection.
    #[impress_method]
    async fn list_collection_members(
        &self,
        collection_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn purge_dismissed_from_collection(&self, collection_id: String) -> MutationResult;

    // ---- Paper queries ----
    #[impress_method]
    async fn list_publications(&self, limit: u32, offset: u32) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn query_publications(
        &self,
        library_id: String,
        sort_field: String,
        ascending: bool,
        limit: u32,
        offset: u32,
    ) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn query_unread(
        &self,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: u32,
    ) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn query_starred(
        &self,
        parent_id: Option<String>,
        sort_field: String,
        ascending: bool,
        limit: u32,
    ) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn query_recent(&self, limit: u32, parent_id: Option<String>) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn search_publications(&self, query: String, limit: u32) -> Vec<PublicationSummary>;
    #[impress_method]
    async fn get_publication(&self, id: String) -> Option<PublicationSummary>;
    /// Get detailed information about a specific paper by its cite key.
    /// Returns full metadata and BibTeX entry.
    #[impress_method]
    async fn get_publication_detail(&self, id: String) -> Option<PublicationDetailRecord>;
    /// Get a single count — unread, starred, flagged, or by-tag — without
    /// fetching any paper rows. Use whenever the user asks 'how many …'; it
    /// is far cheaper than listing and lengthing the result, and unlike
    /// `imbib-tags-service_list-tags` it does not walk the whole tag vocabulary.
    #[impress_method]
    async fn count_publications(&self) -> u32;
    #[impress_method]
    async fn count_unread(&self, parent_id: Option<String>) -> u32;
    #[impress_method]
    async fn count_starred(&self, parent_id: Option<String>) -> u32;
    #[impress_method]
    async fn count_flagged(&self, color: Option<String>) -> u32;

    // ---- Paper mutations ----
    /// Mark papers as read or unread. Useful for tracking reading progress.
    #[impress_method]
    async fn set_read(&self, ids: Vec<String>, read: bool) -> MutationResult;
    /// Toggle the starred status of papers.
    #[impress_method]
    async fn set_starred(&self, ids: Vec<String>, starred: bool) -> MutationResult;
    /// Set or clear a colored flag on papers. Flags are visual markers for
    /// workflow status. Set color to null to clear the flag.
    #[impress_method]
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
    #[impress_method]
    async fn delete_publications_undoable(&self, ids: Vec<String>) -> MutationResult;
    #[impress_method]
    async fn move_publications(
        &self,
        publication_ids: Vec<String>,
        to_library_id: String,
    ) -> MutationResult;
    #[impress_method]
    async fn duplicate_publications(&self, ids: Vec<String>, to_library_id: String) -> Vec<String>;
    #[impress_method]
    async fn deduplicate_library(&self, library_id: String) -> u32;

    // ---- Dismissed/muted ----
    #[impress_method]
    async fn dismiss_paper(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> Option<DismissedPaperRecord>;
    #[impress_method]
    async fn is_paper_dismissed(
        &self,
        doi: Option<String>,
        arxiv_id: Option<String>,
        bibcode: Option<String>,
        cite_key: Option<String>,
    ) -> bool;
    #[impress_method]
    async fn list_dismissed_papers(&self, limit: u32, offset: u32) -> Vec<DismissedPaperRecord>;
    #[impress_method]
    async fn list_muted_items(&self) -> Vec<MutedItemRecord>;
    #[impress_method]
    async fn create_muted_item(&self, mute_type: String, value: String) -> Option<MutedItemRecord>;

    // ---- BibTeX import/export ----
    /// Add papers to the imbib library by identifier. Supports DOI, arXiv
    /// ID, bibcode, or other identifiers. Automatically fetches metadata
    /// from external sources. If papers already exist, they are still added
    /// to the target library/collection.
    #[impress_method]
    async fn import_papers(&self, papers: Vec<PaperImport>, library_id: String) -> ImportSummary;
    #[impress_method]
    async fn import_bibtex(&self, bibtex: String, library_id: String) -> Vec<String>;
    /// Export BibTeX entries for one or more papers. Useful for creating
    /// bibliography files or inserting citations.
    #[impress_method]
    async fn export_bibtex(&self, ids: Vec<String>) -> String;
    #[impress_method]
    async fn export_all_bibtex(&self, library_id: String) -> String;

    // ---- Linked files / PDFs ----
    #[impress_method]
    async fn list_linked_files(&self, publication_id: String) -> Vec<LinkedFileRecord>;
    #[impress_method]
    async fn count_pdfs(&self, publication_id: String) -> u32;
    #[impress_method]
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
    async fn list_libraries(&self) -> Vec<LibraryRecord> {
        self.store
            .list_libraries()
            .map(|rs| rs.iter().map(LibraryRecord::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("list_libraries", e);
                vec![]
            })
    }
    async fn create_library(&self, name: String) -> Option<LibraryRecord> {
        self.store
            .create_library(name)
            .map(|r| LibraryRecord::from(&r))
            .map_err(|e| log("create_library", e))
            .ok()
    }
    async fn delete_library_undoable(&self, id: String) -> MutationResult {
        match self.store.delete_library_undoable(id) {
            Ok(_) => ok_n(1),
            Err(e) => {
                log("delete_library_undoable", e);
                fail()
            }
        }
    }
    async fn get_default_library(&self) -> Option<LibraryRecord> {
        self.store
            .get_default_library()
            .ok()
            .flatten()
            .as_ref()
            .map(LibraryRecord::from)
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
            .as_ref()
            .map(LibraryRecord::from)
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
    async fn search_publications(&self, query: String, limit: u32) -> Vec<PublicationSummary> {
        let lim = if limit == 0 { Some(50) } else { Some(limit) };
        self.store
            .search_publications(query, None, "date_added".into(), false, lim, None)
            .map(|rs| rs.iter().map(PublicationSummary::from).collect::<Vec<_>>())
            .unwrap_or_else(|e| {
                log("search_publications", e);
                vec![]
            })
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
    async fn import_bibtex(&self, bibtex: String, library_id: String) -> Vec<String> {
        self.store
            .import_bibtex(bibtex, library_id)
            .unwrap_or_else(|e| {
                log("import_bibtex", e);
                vec![]
            })
    }
    async fn export_bibtex(&self, ids: Vec<String>) -> String {
        self.store.export_bibtex(ids).unwrap_or_else(|e| {
            log("export_bibtex", e);
            String::new()
        })
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
}

// ===========================================================================
// Macro registration
// ===========================================================================

impress_service_impl! {
    service = ImbibLibraryService,
    impl = DefaultImbibLibraryService,
    instance = || crate::backend::library_service_instance(),
    methods = [
        // Library lifecycle
        list_libraries() -> Vec<LibraryRecord>,
        create_library(name: String) -> Option<LibraryRecord>,
        delete_library_undoable(id: String) -> MutationResult,
        get_default_library() -> Option<LibraryRecord>,
        set_library_default(id: String) -> MutationResult,
        get_inbox_library() -> Option<LibraryRecord>,
        // Collection lifecycle
        list_collections(library_id: String) -> Vec<CollectionRecord>,
        create_collection(name: String, library_id: String, is_smart: bool, query: Option<String>) -> Option<CollectionRecord>,
        add_to_collection(publication_ids: Vec<String>, collection_id: String) -> MutationResult,
        remove_from_collection(publication_ids: Vec<String>, collection_id: String) -> MutationResult,
        list_collection_members(collection_id: String, sort_field: String, ascending: bool, limit: u32, offset: u32) -> Vec<PublicationSummary>,
        purge_dismissed_from_collection(collection_id: String) -> MutationResult,
        // Paper queries
        list_publications(limit: u32, offset: u32) -> Vec<PublicationSummary>,
        query_publications(library_id: String, sort_field: String, ascending: bool, limit: u32, offset: u32) -> Vec<PublicationSummary>,
        query_unread(parent_id: Option<String>, sort_field: String, ascending: bool, limit: u32) -> Vec<PublicationSummary>,
        query_starred(parent_id: Option<String>, sort_field: String, ascending: bool, limit: u32) -> Vec<PublicationSummary>,
        query_recent(limit: u32, parent_id: Option<String>) -> Vec<PublicationSummary>,
        search_publications(query: String, limit: u32) -> Vec<PublicationSummary>,
        get_publication(id: String) -> Option<PublicationSummary>,
        get_publication_detail(id: String) -> Option<PublicationDetailRecord>,
        count_publications() -> u32,
        count_unread(parent_id: Option<String>) -> u32,
        count_starred(parent_id: Option<String>) -> u32,
        count_flagged(color: Option<String>) -> u32,
        // Paper mutations
        set_read(ids: Vec<String>, read: bool) -> MutationResult,
        set_starred(ids: Vec<String>, starred: bool) -> MutationResult,
        set_flag(ids: Vec<String>, color: Option<String>) -> MutationResult,
        delete_publications_undoable(ids: Vec<String>) -> MutationResult,
        move_publications(publication_ids: Vec<String>, to_library_id: String) -> MutationResult,
        duplicate_publications(ids: Vec<String>, to_library_id: String) -> Vec<String>,
        deduplicate_library(library_id: String) -> u32,
        // Dismissed/muted
        dismiss_paper(doi: Option<String>, arxiv_id: Option<String>, bibcode: Option<String>, cite_key: Option<String>) -> Option<DismissedPaperRecord>,
        is_paper_dismissed(doi: Option<String>, arxiv_id: Option<String>, bibcode: Option<String>, cite_key: Option<String>) -> bool,
        list_dismissed_papers(limit: u32, offset: u32) -> Vec<DismissedPaperRecord>,
        list_muted_items() -> Vec<MutedItemRecord>,
        create_muted_item(mute_type: String, value: String) -> Option<MutedItemRecord>,
        // BibTeX I/O
        import_papers(papers: Vec<PaperImport>, library_id: String) -> ImportSummary,
        import_bibtex(bibtex: String, library_id: String) -> Vec<String>,
        export_bibtex(ids: Vec<String>) -> String,
        export_all_bibtex(library_id: String) -> String,
        // Linked files
        list_linked_files(publication_id: String) -> Vec<LinkedFileRecord>,
        count_pdfs(publication_id: String) -> u32,
        add_linked_file(publication_id: String, filename: String, relative_path: Option<String>, file_type: Option<String>, file_size: i64, sha256: Option<String>, is_pdf: bool) -> Option<LinkedFileRecord>,
    ],
}

// Legacy compatibility — bin crates that used the old singleton-init can keep working.
pub fn init_imbib_library_service(store_path: std::path::PathBuf) -> Result<(), String> {
    crate::store_singleton::init_imbib_store(store_path)
}

#[cfg(test)]
mod tests {
    use impress_service_core::McpToolDescriptor;

    #[test]
    fn library_service_methods_registered() {
        let names: Vec<&str> = McpToolDescriptor::iter()
            .filter(|d| d.name.starts_with("imbib-library-service_"))
            .map(|d| d.name)
            .collect();
        // 43 methods registered (see methods = [...] above)
        assert!(
            names.len() >= 40,
            "expected >=40 library-service methods, got {}: {names:?}",
            names.len()
        );
    }
}
