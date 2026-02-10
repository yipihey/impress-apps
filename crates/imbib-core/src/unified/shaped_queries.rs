use std::collections::BTreeMap;

use impress_core::item::{Item, Value};

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
    pub publication_id: String,
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
/// `child_linked_files` are pre-fetched children with schema "linked-file".
pub fn item_to_bibliography_row(
    item: &Item,
    tag_defs: &[TagDisplayRow],
    child_linked_files: &[Item],
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
                    let leaf = tag_path
                        .rsplit('/')
                        .next()
                        .unwrap_or(tag_path)
                        .to_string();
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
        has_downloaded_pdf: child_linked_files
            .iter()
            .any(|lf| get_bool(&lf.payload, "is_pdf") && get_bool(&lf.payload, "is_locally_materialized")),
        has_other_attachments: child_linked_files
            .iter()
            .any(|lf| !get_bool(&lf.payload, "is_pdf")),
        citation_count: get_i64(payload, "citation_count").unwrap_or(0) as i32,
        reference_count: get_i64(payload, "reference_count").unwrap_or(0) as i32,
        doi: get_str(payload, "doi"),
        arxiv_id: get_str(payload, "arxiv_id"),
        bibcode: get_str(payload, "bibcode"),
        venue: get_str(payload, "venue"),
        note: get_str(payload, "note"),
        date_added: item.created.timestamp_millis(),
        date_modified: item.created.timestamp_millis(),
        primary_category: primary_class,
        categories,
        tags,
        library_name: None, // Filled in by the store API layer
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
        parent_id: get_str(payload, "parent_id"),
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
                    let leaf = tag_path
                        .rsplit('/')
                        .next()
                        .unwrap_or(tag_path)
                        .to_string();
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
        date_modified: item.created.timestamp_millis(),
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
                        suffix: obj
                            .get("suffix")
                            .and_then(|v| v.as_str())
                            .map(String::from),
                        orcid: obj
                            .get("orcid")
                            .and_then(|v| v.as_str())
                            .map(String::from),
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
        refresh_interval_seconds: get_i64(payload, "refresh_interval_seconds").unwrap_or(3600) as i32,
        last_fetch_count: get_i64(payload, "last_fetch_count").unwrap_or(0) as i32,
        last_executed: get_i64(payload, "last_executed"),
        library_id: item.parent.map(|p| p.to_string()),
        sort_order: get_i64(payload, "sort_order").unwrap_or(0) as i32,
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
        date_modified: item.created.timestamp_millis(),
        linked_file_id: item.parent.map(|p| p.to_string()).unwrap_or_default(),
    }
}

/// Convert an Item into a CommentRow.
pub fn item_to_comment_row(item: &Item) -> CommentRow {
    let payload = &item.payload;
    CommentRow {
        id: item.id.to_string(),
        text: get_str(payload, "text").unwrap_or_default(),
        author_identifier: get_str(payload, "author_identifier"),
        author_display_name: get_str(payload, "author_display_name"),
        date_created: item.created.timestamp_millis(),
        date_modified: item.created.timestamp_millis(),
        parent_comment_id: get_str(payload, "parent_comment_id"),
        publication_id: item.parent.map(|p| p.to_string()).unwrap_or_default(),
    }
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
                    let leaf = tag_path
                        .rsplit('/')
                        .next()
                        .unwrap_or(tag_path)
                        .to_string();
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
    use crate::unified::conversion::publication_to_item;
    use crate::domain::{Author, Identifiers, Publication};
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
        let row = item_to_bibliography_row(&item, &[], &[]);

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

        let row = item_to_bibliography_row(&item, &tag_defs, &[]);
        assert_eq!(row.tags[0].color_light, Some("#ff0000".into()));
    }

    #[test]
    fn library_row_from_item() {
        let item = super::super::conversion::library_to_item(
            "My Library",
            None,
            None,
            true,
            false,
            false,
        );
        let row = item_to_library_row(&item, 42);
        assert_eq!(row.name, "My Library");
        assert!(row.is_default);
        assert_eq!(row.publication_count, 42);
    }

    #[test]
    fn collection_row_from_item() {
        let item = super::super::conversion::collection_to_item(
            "Favorites",
            None,
            false,
            None,
            Some(3),
        );
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
