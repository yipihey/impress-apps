use std::collections::BTreeMap;

use impress_core::item::{Item, Value};

// --- Batch Import Types ---

/// Input for a single search result in a batch import operation.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct SearchResultInput {
    /// The BibTeX string for this result (used for import if new).
    pub bibtex: String,
    /// DOI, if known (used for dedup lookup).
    pub doi: Option<String>,
    /// arXiv ID, if known (used for dedup lookup).
    pub arxiv_id: Option<String>,
    /// Bibcode, if known (used for dedup lookup).
    pub bibcode: Option<String>,
}

/// Result of a batch import operation.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct BatchImportResult {
    /// IDs of publications that already existed in the store.
    pub existing_ids: Vec<String>,
    /// IDs of publications that were newly imported.
    pub imported_ids: Vec<String>,
    /// Number of results skipped because they were dismissed.
    pub dismissed_count: u32,
    /// Number of results that failed to parse/import.
    pub failed_count: u32,
}

// --- Bibliography Display Types ---

/// Pre-shaped bibliography row for list display — matches what PublicationRowData needs.
/// All fields are display-ready strings/primitives to avoid computation on the Swift side.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct BibliographyRow {
    pub id: String,
    pub cite_key: String,
    pub title: String,
    pub author_string: String,
    pub year: Option<i32>,
    pub abstract_text: Option<String>,
    pub is_read: bool,
    pub is_starred: bool,
    pub flag_color: Option<String>,
    pub flag_style: Option<String>,
    pub flag_length: Option<String>,
    pub has_downloaded_pdf: bool,
    pub has_other_attachments: bool,
    pub citation_count: i32,
    pub reference_count: i32,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub bibcode: Option<String>,
    pub venue: Option<String>,
    pub note: Option<String>,
    pub date_added: i64,
    pub date_modified: i64,
    pub primary_category: Option<String>,
    pub categories: Vec<String>,
    pub tags: Vec<TagDisplayRow>,
    pub library_name: Option<String>,
    pub enrichment_date: Option<String>,
}

/// Tag display data for list rows.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct TagDisplayRow {
    pub path: String,
    pub leaf_name: String,
    pub color_light: Option<String>,
    pub color_dark: Option<String>,
}

/// Library summary for sidebar display.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct LibraryRow {
    pub id: String,
    pub name: String,
    pub is_default: bool,
    pub is_inbox: bool,
    pub publication_count: i32,
}

/// Collection summary for sidebar display.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct CollectionRow {
    pub id: String,
    pub name: String,
    pub parent_id: Option<String>,
    pub is_smart: bool,
    pub publication_count: i32,
    pub sort_order: i32,
}

/// Full publication detail for InfoTab / edit views.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct PublicationDetail {
    pub id: String,
    pub cite_key: String,
    pub entry_type: String,
    pub fields: std::collections::HashMap<String, String>,
    pub is_read: bool,
    pub is_starred: bool,
    pub flag_color: Option<String>,
    pub flag_style: Option<String>,
    pub flag_length: Option<String>,
    pub tags: Vec<TagDisplayRow>,
    pub authors: Vec<AuthorRow>,
    pub date_added: i64,
    pub date_modified: i64,
    pub linked_files: Vec<LinkedFileRow>,
    pub citation_count: i32,
    pub reference_count: i32,
    pub raw_bibtex: Option<String>,
    pub collections: Vec<String>,
    pub libraries: Vec<String>,
}

/// Linked file info for detail view.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct LinkedFileRow {
    pub id: String,
    pub filename: String,
    pub relative_path: Option<String>,
    pub file_size: i64,
    pub is_pdf: bool,
    pub is_locally_materialized: bool,
    pub pdf_cloud_available: bool,
    pub date_added: i64,
}

/// Author structured data for detail views.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct AuthorRow {
    pub given_name: Option<String>,
    pub family_name: String,
    pub suffix: Option<String>,
    pub orcid: Option<String>,
    pub affiliation: Option<String>,
}

/// Smart search / saved query summary for sidebar.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct SmartSearchRow {
    pub id: String,
    pub name: String,
    pub query: String,
    pub source_ids: Vec<String>,
    pub max_results: i32,
    pub feeds_to_inbox: bool,
    pub auto_refresh_enabled: bool,
    pub refresh_interval_seconds: i32,
    pub last_fetch_count: i32,
    pub last_executed: Option<i64>,
    pub library_id: Option<String>,
    pub sort_order: i32,
    /// Target library/collection ID for triage save action (None = use global default).
    pub save_target_id: Option<String>,
    /// Whether to show dismissed papers in this collection's results.
    pub show_dismissed: bool,
    /// Per-collection retention in days (0 = use global setting, None = no retention).
    pub retention_days: Option<i32>,
    /// Whether to auto-remove read papers during retention cleanup.
    pub auto_remove_read: bool,
}

/// Muted item (author/venue/category hidden from inbox).
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct MutedItemRow {
    pub id: String,
    pub mute_type: String,
    pub value: String,
    pub date_added: i64,
}

/// Dismissed paper record.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct DismissedPaperRow {
    pub id: String,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub bibcode: Option<String>,
    pub cite_key: Option<String>,
    pub date_dismissed: i64,
}

/// SciX (ADS) remote library summary.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct SciXLibraryRow {
    pub id: String,
    pub remote_id: String,
    pub name: String,
    pub description: Option<String>,
    pub is_public: bool,
    pub last_sync_date: Option<i64>,
    pub sync_state: String,
    pub permission_level: String,
    pub owner_email: Option<String>,
    pub document_count: i32,
    pub publication_count: i32,
    pub sort_order: i32,
}

/// PDF annotation record.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct AnnotationRow {
    pub id: String,
    pub annotation_type: String,
    pub page_number: i32,
    pub bounds_json: Option<String>,
    pub color: Option<String>,
    pub contents: Option<String>,
    pub selected_text: Option<String>,
    pub author_name: Option<String>,
    pub date_created: i64,
    pub date_modified: i64,
    pub linked_file_id: String,
}

/// Threaded comment on a publication.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct CommentRow {
    pub id: String,
    pub text: String,
    pub author_identifier: Option<String>,
    pub author_display_name: Option<String>,
    pub date_created: i64,
    pub date_modified: i64,
    pub parent_comment_id: Option<String>,
    pub parent_item_id: String,
    pub parent_schema: Option<String>,
    /// Byte offset where the anchored range starts (range-anchored comments only).
    pub anchor_start: Option<i64>,
    /// Byte offset where the anchored range ends (exclusive).
    pub anchor_end: Option<i64>,
    /// Snippet the range covered when anchored, used for re-anchoring after edits.
    pub anchor_text: Option<String>,
    /// The `body_content_hash` the range was valid against.
    pub anchored_body_hash: Option<String>,
}

/// Paper assignment.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct AssignmentRow {
    pub id: String,
    pub assignee_name: String,
    pub assigned_by_name: Option<String>,
    pub note: Option<String>,
    pub date_created: i64,
    pub due_date: Option<i64>,
    pub publication_id: String,
    pub library_id: Option<String>,
}

/// Library activity log entry.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ActivityRecordRow {
    pub id: String,
    pub activity_type: String,
    pub actor_display_name: Option<String>,
    pub target_title: Option<String>,
    pub target_id: Option<String>,
    pub date: i64,
    pub detail: Option<String>,
    pub library_id: String,
}

/// Research artifact row for list display.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ArtifactRow {
    pub id: String,
    pub schema: String,
    pub title: String,
    pub source_url: Option<String>,
    pub notes: Option<String>,
    pub artifact_subtype: Option<String>,
    pub file_name: Option<String>,
    pub file_hash: Option<String>,
    pub file_size: Option<i64>,
    pub file_mime_type: Option<String>,
    pub capture_context: Option<String>,
    pub original_author: Option<String>,
    pub event_name: Option<String>,
    pub event_date: Option<String>,
    pub tags: Vec<TagDisplayRow>,
    pub flag_color: Option<String>,
    pub is_read: bool,
    pub is_starred: bool,
    pub created_at: i64,
    pub author: String,
}

/// Relation from an artifact to another item.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ArtifactRelation {
    pub target_id: String,
    pub edge_type: String,
    pub target_schema: Option<String>,
    pub target_title: Option<String>,
}

/// Operation record for provenance display.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct OperationRow {
    pub id: String,
    pub target_id: String,
    pub op_type: String,
    pub intent: String,
    pub reason: Option<String>,
    pub author: String,
    pub date: i64,
    pub logical_clock: u64,
    pub batch_id: Option<String>,
}

// --- Manuscript Display Types (unified GUI — ADR-0011 / GUI-meld plan) ---

/// Pre-shaped manuscript row for list display. Mirrors `BibliographyRow`'s
/// role for `manuscript@1.0.0` items: display-ready fields, no Swift-side
/// payload parsing. Deliberately NOT merged into `BibliographyRow` —
/// manuscripts are not publication-shaped (see plan: option (a), additive).
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ManuscriptRow {
    pub id: String,
    pub title: String,
    /// Author display strings joined with "; " (from the `authors` array).
    pub author_string: String,
    /// Lifecycle state: draft | internal-review | submitted | in-revision |
    /// published | archived.
    pub status: String,
    /// Source format: "typst" | "latex" (empty for metadata-only items).
    pub format: String,
    pub journal_target: Option<String>,
    /// SHA-256 hex of the current body (CAS token for guarded saves).
    pub body_content_hash: Option<String>,
    /// ISO 8601 timestamp of the most recent body edit.
    pub body_modified_at: Option<String>,
    /// Byte length of the inline body ("0" when body is a blob ref or absent).
    pub body_size: i64,
    /// True when `body_content` is a `blob:sha256:...` ref (>1 MB escape hatch).
    pub body_is_blob_ref: bool,
    /// Number of manuscript-revision snapshots (pre-computed by the store layer).
    pub revision_count: i32,
    pub is_read: bool,
    pub is_starred: bool,
    pub flag_color: Option<String>,
    pub flag_style: Option<String>,
    pub flag_length: Option<String>,
    pub tags: Vec<TagDisplayRow>,
    pub date_added: i64,
    pub date_modified: i64,
}

/// Full manuscript detail for the detail pane (Info/Source tabs).
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ManuscriptDetail {
    pub id: String,
    pub title: String,
    pub status: String,
    pub authors: Vec<String>,
    pub format: String,
    /// Inline UTF-8 source, or the raw `blob:sha256:...` ref when the body
    /// exceeded the inline threshold. Blob resolution happens caller-side
    /// via the content-addressed store (`ImpressContentStore`); check
    /// `body_is_blob_ref` before treating this as markup.
    pub body_content: String,
    pub body_is_blob_ref: bool,
    pub body_content_hash: Option<String>,
    pub body_modified_at: Option<String>,
    pub format_schema_version: Option<i32>,
    pub current_revision_ref: Option<String>,
    pub journal_target: Option<String>,
    pub submission_id: Option<String>,
    pub topic_tags: Vec<String>,
    pub notes: Option<String>,
    pub import_source: Option<String>,
    pub linked_imbib_manuscript_id: Option<String>,
    pub linked_imbib_library_id: Option<String>,
    pub orcid: Option<String>,
    pub affiliation: Option<String>,
    pub funder: Option<String>,
    pub license: Option<String>,
    pub embargo_until: Option<String>,
    pub is_read: bool,
    pub is_starred: bool,
    pub flag_color: Option<String>,
    pub flag_style: Option<String>,
    pub flag_length: Option<String>,
    pub tags: Vec<TagDisplayRow>,
    pub date_added: i64,
    pub date_modified: i64,
    /// IDs of manuscript-collections containing this manuscript.
    pub collections: Vec<String>,
}

/// Manuscript folder (manuscript-collection item) for sidebar display.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ManuscriptCollectionRow {
    pub id: String,
    pub name: String,
    /// UUID string of the parent collection (payload `parent_collection_ref`);
    /// None for top-level folders/workspaces.
    pub parent_id: Option<String>,
    pub sort_order: i32,
    pub is_smart: bool,
    pub is_workspace: bool,
    pub manuscript_count: i32,
}

/// Immutable manuscript-revision snapshot for the Versions section.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct ManuscriptRevisionRow {
    pub id: String,
    pub parent_manuscript_ref: String,
    pub revision_tag: String,
    pub content_hash: String,
    pub pdf_artifact_ref: Option<String>,
    pub source_archive_ref: Option<String>,
    pub predecessor_revision_ref: Option<String>,
    pub snapshot_reason: Option<String>,
    pub word_count: Option<i32>,
    pub author: String,
    pub date_created: i64,
}

/// Tag definition with publication count for settings/management.
#[derive(Debug, Clone)]
#[cfg_attr(feature = "native", derive(uniffi::Record))]
pub struct TagWithCountRow {
    pub path: String,
    pub leaf_name: String,
    pub color_light: Option<String>,
    pub color_dark: Option<String>,
    pub publication_count: i32,
}

/// Convert an Item into a BibliographyRow for list display.
/// `has_downloaded_pdf` and `has_other_attachments` are pre-computed from linked file status.
pub fn item_to_bibliography_row(
    item: &Item,
    tag_defs: &[TagDisplayRow],
    has_downloaded_pdf: bool,
    has_other_attachments: bool,
) -> BibliographyRow {
    let payload = &item.payload;

    // Match tags to their definitions
    let tags: Vec<TagDisplayRow> = item
        .tags
        .iter()
        .map(|tag_path| {
            tag_defs
                .iter()
                .find(|td| td.path == *tag_path)
                .cloned()
                .unwrap_or_else(|| {
                    let leaf = tag_path.rsplit('/').next().unwrap_or(tag_path).to_string();
                    TagDisplayRow {
                        path: tag_path.clone(),
                        leaf_name: leaf,
                        color_light: None,
                        color_dark: None,
                    }
                })
        })
        .collect();

    // Parse primary_class for categories
    let primary_class = get_str(payload, "primary_class");
    let categories: Vec<String> = primary_class
        .as_ref()
        .map(|pc| vec![pc.clone()])
        .unwrap_or_default();

    BibliographyRow {
        id: item.id.to_string(),
        cite_key: get_str(payload, "cite_key").unwrap_or_default(),
        title: get_str(payload, "title").unwrap_or_default(),
        author_string: get_str(payload, "author_text").unwrap_or_default(),
        year: get_i64(payload, "year").map(|v| v as i32),
        abstract_text: get_str(payload, "abstract_text"),
        is_read: item.is_read,
        is_starred: item.is_starred,
        flag_color: item.flag.as_ref().map(|f| f.color.clone()),
        flag_style: item.flag.as_ref().and_then(|f| f.style.clone()),
        flag_length: item.flag.as_ref().and_then(|f| f.length.clone()),
        has_downloaded_pdf,
        has_other_attachments,
        citation_count: get_i64(payload, "citation_count").unwrap_or(0) as i32,
        reference_count: get_i64(payload, "reference_count").unwrap_or(0) as i32,
        doi: get_str(payload, "doi"),
        arxiv_id: get_str(payload, "arxiv_id"),
        bibcode: get_str(payload, "bibcode"),
        venue: get_str(payload, "venue"),
        note: get_str(payload, "note"),
        date_added: item.created.timestamp_millis(),
        date_modified: item.modified.timestamp_millis(),
        primary_category: primary_class,
        categories,
        tags,
        library_name: None, // Filled in by the store API layer
        enrichment_date: get_str(payload, "enrichment_date"),
    }
}

/// Convert an Item into a LibraryRow.
pub fn item_to_library_row(item: &Item, publication_count: i32) -> LibraryRow {
    let payload = &item.payload;
    LibraryRow {
        id: item.id.to_string(),
        name: get_str(payload, "name").unwrap_or_default(),
        is_default: get_bool(payload, "is_default"),
        is_inbox: get_bool(payload, "is_inbox"),
        publication_count,
    }
}

/// Convert an Item into a CollectionRow.
pub fn item_to_collection_row(item: &Item, publication_count: i32) -> CollectionRow {
    let payload = &item.payload;
    CollectionRow {
        id: item.id.to_string(),
        name: get_str(payload, "name").unwrap_or_default(),
        // The parent (library) lives on the unified `item.parent` field, not
        // on the payload. Reading from payload silently returned None.
        parent_id: item.parent.map(|u| u.to_string()),
        is_smart: get_bool(payload, "is_smart"),
        publication_count,
        sort_order: get_i64(payload, "sort_order").unwrap_or(0) as i32,
    }
}

/// Convert an Item into a PublicationDetail for the detail view.
/// `child_linked_files` are pre-fetched children with schema "linked-file".
pub fn item_to_publication_detail(
    item: &Item,
    tag_defs: &[TagDisplayRow],
    collection_ids: Vec<String>,
    library_ids: Vec<String>,
    child_linked_files: &[Item],
) -> PublicationDetail {
    let payload = &item.payload;

    // Extract all string fields into a flat HashMap
    let mut fields = std::collections::HashMap::new();
    for (key, value) in payload {
        if let Value::String(s) = value {
            fields.insert(key.clone(), s.clone());
        } else if let Value::Int(i) = value {
            fields.insert(key.clone(), i.to_string());
        }
    }

    let tags: Vec<TagDisplayRow> = item
        .tags
        .iter()
        .map(|tag_path| {
            tag_defs
                .iter()
                .find(|td| td.path == *tag_path)
                .cloned()
                .unwrap_or_else(|| {
                    let leaf = tag_path.rsplit('/').next().unwrap_or(tag_path).to_string();
                    TagDisplayRow {
                        path: tag_path.clone(),
                        leaf_name: leaf,
                        color_light: None,
                        color_dark: None,
                    }
                })
        })
        .collect();

    // Parse authors from authors_json payload field
    let authors = parse_authors_json(payload);

    // Convert child linked file items to LinkedFileRows
    let linked_files: Vec<LinkedFileRow> = child_linked_files
        .iter()
        .map(item_to_linked_file_row)
        .collect();

    PublicationDetail {
        id: item.id.to_string(),
        cite_key: get_str(payload, "cite_key").unwrap_or_default(),
        entry_type: get_str(payload, "entry_type").unwrap_or_default(),
        fields,
        is_read: item.is_read,
        is_starred: item.is_starred,
        flag_color: item.flag.as_ref().map(|f| f.color.clone()),
        flag_style: item.flag.as_ref().and_then(|f| f.style.clone()),
        flag_length: item.flag.as_ref().and_then(|f| f.length.clone()),
        tags,
        authors,
        date_added: item.created.timestamp_millis(),
        date_modified: item.modified.timestamp_millis(),
        linked_files,
        citation_count: get_i64(payload, "citation_count").unwrap_or(0) as i32,
        reference_count: get_i64(payload, "reference_count").unwrap_or(0) as i32,
        raw_bibtex: get_str(payload, "raw_bibtex"),
        collections: collection_ids,
        libraries: library_ids,
    }
}

/// Parse authors from the `authors_json` payload field.
/// Falls back to parsing `author_text` (semicolon-separated "Family, Given" format)
/// for papers that were imported before `authors_json` was populated.
fn parse_authors_json(payload: &BTreeMap<String, Value>) -> Vec<AuthorRow> {
    // Try structured JSON first
    if let Some(Value::String(json_str)) = payload.get("authors_json") {
        let parsed: Result<Vec<serde_json::Value>, _> = serde_json::from_str(json_str);
        if let Ok(arr) = parsed {
            let rows: Vec<AuthorRow> = arr
                .iter()
                .filter_map(|v| {
                    let obj = v.as_object()?;
                    let family_name = obj.get("family_name")?.as_str()?.to_string();
                    Some(AuthorRow {
                        given_name: obj
                            .get("given_name")
                            .and_then(|v| v.as_str())
                            .map(String::from),
                        family_name,
                        suffix: obj.get("suffix").and_then(|v| v.as_str()).map(String::from),
                        orcid: obj.get("orcid").and_then(|v| v.as_str()).map(String::from),
                        affiliation: obj
                            .get("affiliation")
                            .and_then(|v| v.as_str())
                            .map(String::from),
                    })
                })
                .collect();
            if !rows.is_empty() {
                return rows;
            }
        }
    }

    // Fallback: parse author_text ("Family, Given; Family, Given; ...")
    if let Some(Value::String(text)) = payload.get("author_text") {
        if !text.is_empty() {
            return text
                .split("; ")
                .filter(|s| !s.is_empty())
                .map(|entry| {
                    let parts: Vec<&str> = entry.splitn(2, ", ").collect();
                    AuthorRow {
                        family_name: parts[0].to_string(),
                        given_name: parts.get(1).map(|s| s.to_string()),
                        suffix: None,
                        orcid: None,
                        affiliation: None,
                    }
                })
                .collect();
        }
    }

    vec![]
}

/// Convert an Item into a LinkedFileRow.
pub fn item_to_linked_file_row(item: &Item) -> LinkedFileRow {
    let payload = &item.payload;
    LinkedFileRow {
        id: item.id.to_string(),
        filename: get_str(payload, "filename").unwrap_or_default(),
        relative_path: get_str(payload, "relative_path"),
        file_size: get_i64(payload, "file_size").unwrap_or(0),
        is_pdf: get_bool(payload, "is_pdf"),
        is_locally_materialized: get_bool(payload, "is_locally_materialized"),
        pdf_cloud_available: get_bool(payload, "pdf_cloud_available"),
        date_added: item.created.timestamp_millis(),
    }
}

/// Convert an Item into a SmartSearchRow.
pub fn item_to_smart_search_row(item: &Item) -> SmartSearchRow {
    let payload = &item.payload;
    let source_ids: Vec<String> = get_str(payload, "source_ids_json")
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default();
    SmartSearchRow {
        id: item.id.to_string(),
        name: get_str(payload, "name").unwrap_or_default(),
        query: get_str(payload, "query").unwrap_or_default(),
        source_ids,
        max_results: get_i64(payload, "max_results").unwrap_or(100) as i32,
        feeds_to_inbox: get_bool(payload, "feeds_to_inbox"),
        auto_refresh_enabled: get_bool(payload, "auto_refresh_enabled"),
        refresh_interval_seconds: get_i64(payload, "refresh_interval_seconds").unwrap_or(3600)
            as i32,
        last_fetch_count: get_i64(payload, "last_fetch_count").unwrap_or(0) as i32,
        last_executed: get_i64(payload, "last_executed"),
        library_id: item.parent.map(|p| p.to_string()),
        sort_order: get_i64(payload, "sort_order").unwrap_or(0) as i32,
        save_target_id: get_str(payload, "save_target_id"),
        show_dismissed: get_bool(payload, "show_dismissed"),
        retention_days: get_i64(payload, "retention_days").map(|v| v as i32),
        auto_remove_read: get_bool(payload, "auto_remove_read"),
    }
}

/// Convert an Item into a MutedItemRow.
pub fn item_to_muted_item_row(item: &Item) -> MutedItemRow {
    let payload = &item.payload;
    MutedItemRow {
        id: item.id.to_string(),
        mute_type: get_str(payload, "mute_type").unwrap_or_default(),
        value: get_str(payload, "value").unwrap_or_default(),
        date_added: item.created.timestamp_millis(),
    }
}

/// Convert an Item into a DismissedPaperRow.
pub fn item_to_dismissed_paper_row(item: &Item) -> DismissedPaperRow {
    let payload = &item.payload;
    DismissedPaperRow {
        id: item.id.to_string(),
        doi: get_str(payload, "doi"),
        arxiv_id: get_str(payload, "arxiv_id"),
        bibcode: get_str(payload, "bibcode"),
        cite_key: get_str(payload, "cite_key"),
        date_dismissed: item.created.timestamp_millis(),
    }
}

/// Convert an Item into a SciXLibraryRow.
pub fn item_to_scix_library_row(item: &Item, publication_count: i32) -> SciXLibraryRow {
    let payload = &item.payload;
    SciXLibraryRow {
        id: item.id.to_string(),
        remote_id: get_str(payload, "remote_id").unwrap_or_default(),
        name: get_str(payload, "name").unwrap_or_default(),
        description: get_str(payload, "description"),
        is_public: get_bool(payload, "is_public"),
        last_sync_date: get_i64(payload, "last_sync_date"),
        sync_state: get_str(payload, "sync_state").unwrap_or_else(|| "unknown".into()),
        permission_level: get_str(payload, "permission_level").unwrap_or_else(|| "read".into()),
        owner_email: get_str(payload, "owner_email"),
        document_count: get_i64(payload, "document_count").unwrap_or(0) as i32,
        publication_count,
        sort_order: get_i64(payload, "sort_order").unwrap_or(0) as i32,
    }
}

/// Convert an Item into an AnnotationRow.
pub fn item_to_annotation_row(item: &Item) -> AnnotationRow {
    let payload = &item.payload;
    AnnotationRow {
        id: item.id.to_string(),
        annotation_type: get_str(payload, "annotation_type").unwrap_or_default(),
        page_number: get_i64(payload, "page_number").unwrap_or(0) as i32,
        bounds_json: get_str(payload, "bounds_json"),
        color: get_str(payload, "color"),
        contents: get_str(payload, "contents"),
        selected_text: get_str(payload, "selected_text"),
        author_name: get_str(payload, "author_name"),
        date_created: item.created.timestamp_millis(),
        date_modified: item.modified.timestamp_millis(),
        linked_file_id: item.parent.map(|p| p.to_string()).unwrap_or_default(),
    }
}

/// Convert an Item into a CommentRow.
///
/// `parent_schema` is populated from a separate lookup by the caller when
/// needed; defaults to `None` here.
pub fn item_to_comment_row(item: &Item) -> CommentRow {
    let payload = &item.payload;
    CommentRow {
        id: item.id.to_string(),
        text: get_str(payload, "text").unwrap_or_default(),
        author_identifier: get_str(payload, "author_identifier"),
        author_display_name: get_str(payload, "author_display_name"),
        date_created: item.created.timestamp_millis(),
        date_modified: item.modified.timestamp_millis(),
        parent_comment_id: get_str(payload, "parent_comment_id"),
        parent_item_id: item.parent.map(|p| p.to_string()).unwrap_or_default(),
        parent_schema: None,
        anchor_start: get_i64(payload, "anchor_start"),
        anchor_end: get_i64(payload, "anchor_end"),
        anchor_text: get_str(payload, "anchor_text"),
        anchored_body_hash: get_str(payload, "anchored_body_hash"),
    }
}

/// Convert an Item into a CommentRow with a known parent schema.
pub fn item_to_comment_row_with_schema(item: &Item, parent_schema: Option<String>) -> CommentRow {
    let mut row = item_to_comment_row(item);
    row.parent_schema = parent_schema;
    row
}

/// Convert an Item into an AssignmentRow.
pub fn item_to_assignment_row(item: &Item) -> AssignmentRow {
    let payload = &item.payload;
    AssignmentRow {
        id: item.id.to_string(),
        assignee_name: get_str(payload, "assignee_name").unwrap_or_default(),
        assigned_by_name: get_str(payload, "assigned_by_name"),
        note: get_str(payload, "note"),
        date_created: item.created.timestamp_millis(),
        due_date: get_i64(payload, "due_date"),
        publication_id: item.parent.map(|p| p.to_string()).unwrap_or_default(),
        library_id: None, // Set by store API from context
    }
}

/// Convert an Item into an ActivityRecordRow.
pub fn item_to_activity_record_row(item: &Item) -> ActivityRecordRow {
    let payload = &item.payload;
    ActivityRecordRow {
        id: item.id.to_string(),
        activity_type: get_str(payload, "activity_type").unwrap_or_default(),
        actor_display_name: get_str(payload, "actor_display_name"),
        target_title: get_str(payload, "target_title"),
        target_id: get_str(payload, "target_id"),
        date: item.created.timestamp_millis(),
        detail: get_str(payload, "detail"),
        library_id: item.parent.map(|p| p.to_string()).unwrap_or_default(),
    }
}

/// Convert an artifact Item into an ArtifactRow.
pub fn item_to_artifact_row(item: &Item, tag_defs: &[TagDisplayRow]) -> ArtifactRow {
    let payload = &item.payload;
    let tags: Vec<TagDisplayRow> = item
        .tags
        .iter()
        .map(|tag_path| {
            tag_defs
                .iter()
                .find(|td| td.path == *tag_path)
                .cloned()
                .unwrap_or_else(|| {
                    let leaf = tag_path.rsplit('/').next().unwrap_or(tag_path).to_string();
                    TagDisplayRow {
                        path: tag_path.clone(),
                        leaf_name: leaf,
                        color_light: None,
                        color_dark: None,
                    }
                })
        })
        .collect();

    ArtifactRow {
        id: item.id.to_string(),
        schema: item.schema.clone(),
        title: get_str(payload, "title").unwrap_or_default(),
        source_url: get_str(payload, "source_url"),
        notes: get_str(payload, "notes"),
        artifact_subtype: get_str(payload, "artifact_subtype"),
        file_name: get_str(payload, "file_name"),
        file_hash: get_str(payload, "file_hash"),
        file_size: get_i64(payload, "file_size"),
        file_mime_type: get_str(payload, "file_mime_type"),
        capture_context: get_str(payload, "capture_context"),
        original_author: get_str(payload, "original_author"),
        event_name: get_str(payload, "event_name"),
        event_date: get_str(payload, "event_date"),
        tags,
        flag_color: item.flag.as_ref().map(|f| f.color.clone()),
        is_read: item.is_read,
        is_starred: item.is_starred,
        created_at: item.created.timestamp_millis(),
        author: item.author.clone(),
    }
}

/// Convert a core/operation Item into an OperationRow.
pub fn item_to_operation_row(item: &Item) -> OperationRow {
    let payload = &item.payload;
    OperationRow {
        id: item.id.to_string(),
        target_id: get_str(payload, "target_id").unwrap_or_default(),
        op_type: get_str(payload, "op_type").unwrap_or_default(),
        intent: get_str(payload, "intent").unwrap_or_else(|| "routine".into()),
        reason: get_str(payload, "reason"),
        author: item.author.clone(),
        date: item.created.timestamp_millis(),
        logical_clock: item.logical_clock,
        batch_id: item.batch_id.clone(),
    }
}

/// Prefix marking a payload string field as a content-addressed blob ref
/// rather than inline content (the >1 MB escape hatch documented on
/// `manuscript.body_content`).
pub const BLOB_REF_PREFIX: &str = "blob:sha256:";

/// Match an item's tag paths against tag definitions (shared by the
/// bibliography/artifact/manuscript shapers).
fn match_tags(item: &Item, tag_defs: &[TagDisplayRow]) -> Vec<TagDisplayRow> {
    item.tags
        .iter()
        .map(|tag_path| {
            tag_defs
                .iter()
                .find(|td| td.path == *tag_path)
                .cloned()
                .unwrap_or_else(|| {
                    let leaf = tag_path.rsplit('/').next().unwrap_or(tag_path).to_string();
                    TagDisplayRow {
                        path: tag_path.clone(),
                        leaf_name: leaf,
                        color_light: None,
                        color_dark: None,
                    }
                })
        })
        .collect()
}

fn get_string_array(payload: &BTreeMap<String, Value>, key: &str) -> Vec<String> {
    match payload.get(key) {
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(|v| match v {
                Value::String(s) => Some(s.clone()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// Convert a `manuscript@1.0.0` Item into a ManuscriptRow for list display.
/// `revision_count` is pre-computed by the store API layer.
pub fn item_to_manuscript_row(
    item: &Item,
    tag_defs: &[TagDisplayRow],
    revision_count: i32,
) -> ManuscriptRow {
    let payload = &item.payload;
    let body = get_str(payload, "body_content");
    let body_is_blob_ref = body
        .as_deref()
        .map(|b| b.starts_with(BLOB_REF_PREFIX))
        .unwrap_or(false);
    let body_size = if body_is_blob_ref {
        0
    } else {
        body.as_deref().map(|b| b.len() as i64).unwrap_or(0)
    };

    ManuscriptRow {
        id: item.id.to_string(),
        title: get_str(payload, "title").unwrap_or_default(),
        author_string: get_string_array(payload, "authors").join("; "),
        status: get_str(payload, "status").unwrap_or_else(|| "draft".into()),
        format: get_str(payload, "format").unwrap_or_default(),
        journal_target: get_str(payload, "journal_target"),
        body_content_hash: get_str(payload, "body_content_hash"),
        body_modified_at: get_str(payload, "body_modified_at"),
        body_size,
        body_is_blob_ref,
        revision_count,
        is_read: item.is_read,
        is_starred: item.is_starred,
        flag_color: item.flag.as_ref().map(|f| f.color.clone()),
        flag_style: item.flag.as_ref().and_then(|f| f.style.clone()),
        flag_length: item.flag.as_ref().and_then(|f| f.length.clone()),
        tags: match_tags(item, tag_defs),
        date_added: item.created.timestamp_millis(),
        date_modified: item.modified.timestamp_millis(),
    }
}

/// Convert a `manuscript@1.0.0` Item into a ManuscriptDetail.
/// `collection_ids` are pre-fetched by the store API layer.
pub fn item_to_manuscript_detail(
    item: &Item,
    tag_defs: &[TagDisplayRow],
    collection_ids: Vec<String>,
) -> ManuscriptDetail {
    let payload = &item.payload;
    let body = get_str(payload, "body_content").unwrap_or_default();
    let body_is_blob_ref = body.starts_with(BLOB_REF_PREFIX);

    ManuscriptDetail {
        id: item.id.to_string(),
        title: get_str(payload, "title").unwrap_or_default(),
        status: get_str(payload, "status").unwrap_or_else(|| "draft".into()),
        authors: get_string_array(payload, "authors"),
        format: get_str(payload, "format").unwrap_or_default(),
        body_content: body,
        body_is_blob_ref,
        body_content_hash: get_str(payload, "body_content_hash"),
        body_modified_at: get_str(payload, "body_modified_at"),
        format_schema_version: get_i64(payload, "format_schema_version").map(|v| v as i32),
        current_revision_ref: get_str(payload, "current_revision_ref"),
        journal_target: get_str(payload, "journal_target"),
        submission_id: get_str(payload, "submission_id"),
        topic_tags: get_string_array(payload, "topic_tags"),
        notes: get_str(payload, "notes"),
        import_source: get_str(payload, "import_source"),
        linked_imbib_manuscript_id: get_str(payload, "linked_imbib_manuscript_id"),
        linked_imbib_library_id: get_str(payload, "linked_imbib_library_id"),
        orcid: get_str(payload, "orcid"),
        affiliation: get_str(payload, "affiliation"),
        funder: get_str(payload, "funder"),
        license: get_str(payload, "license"),
        embargo_until: get_str(payload, "embargo_until"),
        is_read: item.is_read,
        is_starred: item.is_starred,
        flag_color: item.flag.as_ref().map(|f| f.color.clone()),
        flag_style: item.flag.as_ref().and_then(|f| f.style.clone()),
        flag_length: item.flag.as_ref().and_then(|f| f.length.clone()),
        tags: match_tags(item, tag_defs),
        date_added: item.created.timestamp_millis(),
        date_modified: item.modified.timestamp_millis(),
        collections: collection_ids,
    }
}

/// Convert a `manuscript-collection@1.0.0` Item into a ManuscriptCollectionRow.
pub fn item_to_manuscript_collection_row(
    item: &Item,
    manuscript_count: i32,
) -> ManuscriptCollectionRow {
    let payload = &item.payload;
    ManuscriptCollectionRow {
        id: item.id.to_string(),
        name: get_str(payload, "name").unwrap_or_default(),
        parent_id: get_str(payload, "parent_collection_ref"),
        sort_order: get_i64(payload, "sort_order").unwrap_or(0) as i32,
        is_smart: get_bool(payload, "is_smart"),
        is_workspace: get_bool(payload, "is_workspace"),
        manuscript_count,
    }
}

/// Convert a `manuscript-revision@1.0.0` Item into a ManuscriptRevisionRow.
/// Empty-string refs (used when a revision has no compiled PDF yet) are
/// normalized to None.
pub fn item_to_manuscript_revision_row(item: &Item) -> ManuscriptRevisionRow {
    let payload = &item.payload;
    let non_empty = |v: Option<String>| v.filter(|s| !s.is_empty());
    ManuscriptRevisionRow {
        id: item.id.to_string(),
        parent_manuscript_ref: get_str(payload, "parent_manuscript_ref").unwrap_or_default(),
        revision_tag: get_str(payload, "revision_tag").unwrap_or_default(),
        content_hash: get_str(payload, "content_hash").unwrap_or_default(),
        pdf_artifact_ref: non_empty(get_str(payload, "pdf_artifact_ref")),
        source_archive_ref: non_empty(get_str(payload, "source_archive_ref")),
        predecessor_revision_ref: non_empty(get_str(payload, "predecessor_revision_ref")),
        snapshot_reason: get_str(payload, "snapshot_reason"),
        word_count: get_i64(payload, "word_count").map(|v| v as i32),
        author: item.author.clone(),
        date_created: item.created.timestamp_millis(),
    }
}

// --- Helpers ---

fn get_str(payload: &BTreeMap<String, Value>, key: &str) -> Option<String> {
    match payload.get(key) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn get_i64(payload: &BTreeMap<String, Value>, key: &str) -> Option<i64> {
    match payload.get(key) {
        Some(Value::Int(i)) => Some(*i),
        _ => None,
    }
}

fn get_bool(payload: &BTreeMap<String, Value>, key: &str) -> bool {
    match payload.get(key) {
        Some(Value::Bool(b)) => *b,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Author, Identifiers, Publication};
    use crate::unified::conversion::publication_to_item;
    use std::collections::HashMap;
    use uuid::Uuid;

    fn make_author(given: &str, family: &str) -> Author {
        Author {
            id: Uuid::new_v4().to_string(),
            given_name: Some(given.into()),
            family_name: family.into(),
            suffix: None,
            orcid: None,
            affiliation: None,
        }
    }

    fn make_publication() -> Publication {
        Publication {
            id: Uuid::new_v4().to_string(),
            cite_key: "smith2024".into(),
            entry_type: "article".into(),
            title: "Dark Matter in Galaxies".into(),
            year: Some(2024),
            month: None,
            authors: vec![make_author("John", "Smith")],
            editors: vec![],
            journal: Some("ApJ".into()),
            booktitle: None,
            publisher: None,
            volume: Some("900".into()),
            number: None,
            pages: None,
            edition: None,
            series: None,
            address: None,
            chapter: None,
            howpublished: None,
            institution: None,
            organization: None,
            school: None,
            note: None,
            abstract_text: Some("We study dark matter".into()),
            keywords: vec![],
            url: None,
            eprint: None,
            primary_class: Some("astro-ph.GA".into()),
            archive_prefix: None,
            identifiers: Identifiers {
                doi: Some("10.3847/test".into()),
                arxiv_id: Some("2401.00001".into()),
                bibcode: None,
                pmid: None,
                pmcid: None,
                isbn: None,
                issn: None,
                orcid: None,
            },
            extra_fields: HashMap::new(),
            linked_files: vec![],
            tags: vec!["methods/sims".into()],
            collections: vec![],
            library_id: None,
            created_at: Some("2024-01-15T10:00:00Z".into()),
            modified_at: Some("2024-06-01T12:00:00Z".into()),
            source_id: None,
            citation_count: Some(42),
            reference_count: Some(50),
            enrichment_source: None,
            enrichment_date: None,
            raw_bibtex: None,
            raw_ris: None,
        }
    }

    #[test]
    fn bibliography_row_from_item() {
        let pub_data = make_publication();
        let item = publication_to_item(&pub_data, None);
        let row = item_to_bibliography_row(&item, &[], false, false);

        assert_eq!(row.cite_key, "smith2024");
        assert_eq!(row.title, "Dark Matter in Galaxies");
        assert_eq!(row.year, Some(2024));
        assert_eq!(row.doi, Some("10.3847/test".into()));
        assert_eq!(row.citation_count, 42);
        assert_eq!(row.venue, Some("ApJ".into()));
        assert_eq!(row.primary_category, Some("astro-ph.GA".into()));
        assert!(!row.is_read);
        assert!(!row.is_starred);
        assert!(row.flag_color.is_none());
        assert_eq!(row.tags.len(), 1);
        assert_eq!(row.tags[0].path, "methods/sims");
    }

    #[test]
    fn bibliography_row_with_tag_definitions() {
        let pub_data = make_publication();
        let item = publication_to_item(&pub_data, None);

        let tag_defs = vec![TagDisplayRow {
            path: "methods/sims".into(),
            leaf_name: "sims".into(),
            color_light: Some("#ff0000".into()),
            color_dark: Some("#cc0000".into()),
        }];

        let row = item_to_bibliography_row(&item, &tag_defs, false, false);
        assert_eq!(row.tags[0].color_light, Some("#ff0000".into()));
    }

    #[test]
    fn library_row_from_item() {
        let item =
            super::super::conversion::library_to_item("My Library", None, None, true, false, false);
        let row = item_to_library_row(&item, 42);
        assert_eq!(row.name, "My Library");
        assert!(row.is_default);
        assert_eq!(row.publication_count, 42);
    }

    #[test]
    fn collection_row_from_item() {
        let item =
            super::super::conversion::collection_to_item("Favorites", None, false, None, Some(3));
        let row = item_to_collection_row(&item, 10);
        assert_eq!(row.name, "Favorites");
        assert!(!row.is_smart);
        assert_eq!(row.sort_order, 3);
        assert_eq!(row.publication_count, 10);
    }

    #[test]
    fn publication_detail_from_item() {
        let pub_data = make_publication();
        let item = publication_to_item(&pub_data, None);
        let detail = item_to_publication_detail(&item, &[], vec![], vec![], &[]);

        assert_eq!(detail.cite_key, "smith2024");
        assert_eq!(detail.entry_type, "article");
        assert!(detail.fields.contains_key("title"));
        assert_eq!(detail.citation_count, 42);
    }
}
