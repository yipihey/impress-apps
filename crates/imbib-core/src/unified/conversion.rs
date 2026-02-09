use std::collections::BTreeMap;

use chrono::Utc;
use impress_core::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};

use crate::domain::Publication;
use uuid::Uuid;

/// Convert a Publication to an Item with schema "bibliography-entry".
pub fn publication_to_item(pub_data: &Publication, library_id: Option<ItemId>) -> Item {
    let mut payload = BTreeMap::new();

    insert_string(&mut payload, "cite_key", &pub_data.cite_key);
    insert_string(&mut payload, "entry_type", &pub_data.entry_type);
    insert_opt_string(&mut payload, "title", &Some(pub_data.title.clone()));
    insert_opt_string(
        &mut payload,
        "author_text",
        &Some(format_author_text(&pub_data.authors)),
    );
    insert_opt_int(&mut payload, "year", &pub_data.year);
    insert_opt_string(&mut payload, "month", &pub_data.month);
    insert_opt_string(&mut payload, "journal", &pub_data.journal);
    insert_opt_string(&mut payload, "booktitle", &pub_data.booktitle);
    insert_opt_string(&mut payload, "publisher", &pub_data.publisher);
    insert_opt_string(&mut payload, "volume", &pub_data.volume);
    insert_opt_string(&mut payload, "number", &pub_data.number);
    insert_opt_string(&mut payload, "pages", &pub_data.pages);
    insert_opt_string(&mut payload, "edition", &pub_data.edition);
    insert_opt_string(&mut payload, "series", &pub_data.series);
    insert_opt_string(&mut payload, "address", &pub_data.address);
    insert_opt_string(&mut payload, "chapter", &pub_data.chapter);
    insert_opt_string(&mut payload, "howpublished", &pub_data.howpublished);
    insert_opt_string(&mut payload, "institution", &pub_data.institution);
    insert_opt_string(&mut payload, "organization", &pub_data.organization);
    insert_opt_string(&mut payload, "school", &pub_data.school);
    insert_opt_string(&mut payload, "note", &pub_data.note);
    insert_opt_string(&mut payload, "abstract_text", &pub_data.abstract_text);
    insert_opt_string(&mut payload, "url", &pub_data.url);
    insert_opt_string(&mut payload, "eprint", &pub_data.eprint);
    insert_opt_string(&mut payload, "primary_class", &pub_data.primary_class);
    insert_opt_string(&mut payload, "archive_prefix", &pub_data.archive_prefix);

    // Identifiers
    insert_opt_string(&mut payload, "doi", &pub_data.identifiers.doi);
    insert_opt_string(&mut payload, "arxiv_id", &pub_data.identifiers.arxiv_id);
    insert_opt_string(&mut payload, "pmid", &pub_data.identifiers.pmid);
    insert_opt_string(&mut payload, "pmcid", &pub_data.identifiers.pmcid);
    insert_opt_string(&mut payload, "bibcode", &pub_data.identifiers.bibcode);
    insert_opt_string(&mut payload, "isbn", &pub_data.identifiers.isbn);
    insert_opt_string(&mut payload, "issn", &pub_data.identifiers.issn);

    // Compute venue from journal/booktitle
    let venue = pub_data
        .journal
        .clone()
        .or_else(|| pub_data.booktitle.clone());
    insert_opt_string(&mut payload, "venue", &venue);

    insert_opt_int(&mut payload, "citation_count", &pub_data.citation_count);
    insert_opt_int(&mut payload, "reference_count", &pub_data.reference_count);
    insert_opt_string(&mut payload, "source_id", &pub_data.source_id);
    insert_opt_string(&mut payload, "enrichment_source", &pub_data.enrichment_source);
    insert_opt_string(&mut payload, "enrichment_date", &pub_data.enrichment_date);
    insert_opt_string(&mut payload, "raw_bibtex", &pub_data.raw_bibtex);
    insert_opt_string(&mut payload, "raw_ris", &pub_data.raw_ris);

    // Keywords
    if !pub_data.keywords.is_empty() {
        payload.insert(
            "keywords".into(),
            Value::Array(
                pub_data
                    .keywords
                    .iter()
                    .map(|k| Value::String(k.clone()))
                    .collect(),
            ),
        );
    }

    // Extra fields as JSON object
    if !pub_data.extra_fields.is_empty() {
        let mut obj = BTreeMap::new();
        for (k, v) in &pub_data.extra_fields {
            obj.insert(k.clone(), Value::String(v.clone()));
        }
        payload.insert("extra_fields".into(), Value::Object(obj));
    }

    let id = Uuid::parse_str(&pub_data.id).unwrap_or_else(|_| Uuid::new_v4());

    let created = pub_data
        .created_at
        .as_ref()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|dt| dt.with_timezone(&Utc))
        .unwrap_or_else(Utc::now);

    Item {
        id,
        schema: "imbib/bibliography-entry".into(),
        payload,
        created,
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: pub_data.tags.clone(),
        flag: None, // Flag state managed separately by Swift
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: library_id,
    }
}

/// Convert an Item with schema "bibliography-entry" back to a Publication.
pub fn item_to_publication(item: &Item) -> Publication {
    let id = item.id.to_string();

    let cite_key = get_string(&item.payload, "cite_key").unwrap_or_default();
    let entry_type = get_string(&item.payload, "entry_type").unwrap_or_default();
    let title = get_string(&item.payload, "title").unwrap_or_default();

    let identifiers = crate::domain::Identifiers {
        doi: get_string(&item.payload, "doi"),
        arxiv_id: get_string(&item.payload, "arxiv_id"),
        pmid: get_string(&item.payload, "pmid"),
        pmcid: get_string(&item.payload, "pmcid"),
        bibcode: get_string(&item.payload, "bibcode"),
        isbn: get_string(&item.payload, "isbn"),
        issn: get_string(&item.payload, "issn"),
        orcid: None,
    };

    let keywords = match item.payload.get("keywords") {
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(|v| match v {
                Value::String(s) => Some(s.clone()),
                _ => None,
            })
            .collect(),
        _ => vec![],
    };

    let extra_fields = match item.payload.get("extra_fields") {
        Some(Value::Object(obj)) => obj
            .iter()
            .filter_map(|(k, v)| match v {
                Value::String(s) => Some((k.clone(), s.clone())),
                _ => None,
            })
            .collect(),
        _ => std::collections::HashMap::new(),
    };

    Publication {
        id,
        cite_key,
        entry_type,
        title,
        year: get_int(&item.payload, "year").map(|v| v as i32),
        month: get_string(&item.payload, "month"),
        authors: vec![], // TODO: parse author_text or authors_json
        editors: vec![],
        journal: get_string(&item.payload, "journal"),
        booktitle: get_string(&item.payload, "booktitle"),
        publisher: get_string(&item.payload, "publisher"),
        volume: get_string(&item.payload, "volume"),
        number: get_string(&item.payload, "number"),
        pages: get_string(&item.payload, "pages"),
        edition: get_string(&item.payload, "edition"),
        series: get_string(&item.payload, "series"),
        address: get_string(&item.payload, "address"),
        chapter: get_string(&item.payload, "chapter"),
        howpublished: get_string(&item.payload, "howpublished"),
        institution: get_string(&item.payload, "institution"),
        organization: get_string(&item.payload, "organization"),
        school: get_string(&item.payload, "school"),
        note: get_string(&item.payload, "note"),
        abstract_text: get_string(&item.payload, "abstract_text"),
        keywords,
        url: get_string(&item.payload, "url"),
        eprint: get_string(&item.payload, "eprint"),
        primary_class: get_string(&item.payload, "primary_class"),
        archive_prefix: get_string(&item.payload, "archive_prefix"),
        identifiers,
        extra_fields,
        linked_files: vec![], // Managed as separate items with Attaches edges
        tags: item.tags.clone(),
        collections: vec![],
        library_id: item.parent.map(|p| p.to_string()),
        created_at: Some(item.created.to_rfc3339()),
        modified_at: None,
        source_id: get_string(&item.payload, "source_id"),
        citation_count: get_int(&item.payload, "citation_count").map(|v| v as i32),
        reference_count: get_int(&item.payload, "reference_count").map(|v| v as i32),
        enrichment_source: get_string(&item.payload, "enrichment_source"),
        enrichment_date: get_string(&item.payload, "enrichment_date"),
        raw_bibtex: get_string(&item.payload, "raw_bibtex"),
        raw_ris: get_string(&item.payload, "raw_ris"),
    }
}

/// Convert Library-equivalent fields to an Item.
pub fn library_to_item(
    name: &str,
    bib_file_path: Option<&str>,
    papers_directory_path: Option<&str>,
    is_default: bool,
    is_inbox: bool,
    is_system: bool,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "name", name);
    insert_opt_string(&mut payload, "bib_file_path", &bib_file_path.map(String::from));
    insert_opt_string(
        &mut payload,
        "papers_directory_path",
        &papers_directory_path.map(String::from),
    );
    payload.insert("is_default".into(), Value::Bool(is_default));
    payload.insert("is_inbox".into(), Value::Bool(is_inbox));
    payload.insert("is_system".into(), Value::Bool(is_system));

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/library".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    }
}

/// Convert Collection-equivalent fields to an Item.
pub fn collection_to_item(
    name: &str,
    parent_id: Option<ItemId>,
    is_smart: bool,
    smart_query: Option<&str>,
    sort_order: Option<i64>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "name", name);
    payload.insert("is_smart".into(), Value::Bool(is_smart));
    insert_opt_string(&mut payload, "smart_query", &smart_query.map(String::from));
    if let Some(order) = sort_order {
        payload.insert("sort_order".into(), Value::Int(order));
    }

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/collection".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: parent_id,
    }
}

/// Convert tag definition fields to an Item.
pub fn tag_definition_to_item(
    name: &str,
    canonical_path: &str,
    color_light: Option<&str>,
    color_dark: Option<&str>,
    sort_order: Option<i64>,
    parent_id: Option<ItemId>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "name", name);
    insert_string(&mut payload, "canonical_path", canonical_path);
    insert_opt_string(&mut payload, "color_light", &color_light.map(String::from));
    insert_opt_string(&mut payload, "color_dark", &color_dark.map(String::from));
    if let Some(order) = sort_order {
        payload.insert("sort_order".into(), Value::Int(order));
    }

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/tag-definition".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: parent_id,
    }
}

/// Convert linked file fields to an Item.
/// Parent: the bibliography-entry item this file is attached to.
pub fn linked_file_to_item(
    publication_id: ItemId,
    filename: &str,
    relative_path: Option<&str>,
    file_type: Option<&str>,
    file_size: i64,
    sha256: Option<&str>,
    is_pdf: bool,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "filename", filename);
    insert_opt_string(&mut payload, "relative_path", &relative_path.map(String::from));
    insert_opt_string(&mut payload, "file_type", &file_type.map(String::from));
    payload.insert("file_size".into(), Value::Int(file_size));
    insert_opt_string(&mut payload, "sha256", &sha256.map(String::from));
    payload.insert("is_pdf".into(), Value::Bool(is_pdf));
    payload.insert("is_locally_materialized".into(), Value::Bool(true));
    payload.insert("pdf_cloud_available".into(), Value::Bool(false));

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/linked-file".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: Some(publication_id),
    }
}

/// Convert smart search fields to an Item.
/// Parent: the library item this search belongs to.
#[allow(clippy::too_many_arguments)]
pub fn smart_search_to_item(
    name: &str,
    query: &str,
    library_id: ItemId,
    source_ids_json: Option<&str>,
    max_results: i64,
    feeds_to_inbox: bool,
    auto_refresh_enabled: bool,
    refresh_interval_seconds: i64,
    sort_order: Option<i64>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "name", name);
    insert_string(&mut payload, "query", query);
    insert_opt_string(&mut payload, "source_ids_json", &source_ids_json.map(String::from));
    payload.insert("max_results".into(), Value::Int(max_results));
    payload.insert("feeds_to_inbox".into(), Value::Bool(feeds_to_inbox));
    payload.insert("auto_refresh_enabled".into(), Value::Bool(auto_refresh_enabled));
    payload.insert("refresh_interval_seconds".into(), Value::Int(refresh_interval_seconds));
    payload.insert("last_fetch_count".into(), Value::Int(0));
    if let Some(order) = sort_order {
        payload.insert("sort_order".into(), Value::Int(order));
    }

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/smart-search".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: Some(library_id),
    }
}

/// Convert muted item fields to an Item.
pub fn muted_item_to_item(mute_type: &str, value: &str) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "mute_type", mute_type);
    insert_string(&mut payload, "value", value);

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/muted-item".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    }
}

/// Convert dismissed paper fields to an Item.
pub fn dismissed_paper_to_item(
    doi: Option<&str>,
    arxiv_id: Option<&str>,
    bibcode: Option<&str>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_opt_string(&mut payload, "doi", &doi.map(String::from));
    insert_opt_string(&mut payload, "arxiv_id", &arxiv_id.map(String::from));
    insert_opt_string(&mut payload, "bibcode", &bibcode.map(String::from));

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/dismissed-paper".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    }
}

/// Convert SciX library fields to an Item.
pub fn scix_library_to_item(
    remote_id: &str,
    name: &str,
    description: Option<&str>,
    is_public: bool,
    permission_level: &str,
    owner_email: Option<&str>,
    sort_order: Option<i64>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "remote_id", remote_id);
    insert_string(&mut payload, "name", name);
    insert_opt_string(&mut payload, "description", &description.map(String::from));
    payload.insert("is_public".into(), Value::Bool(is_public));
    insert_string(&mut payload, "permission_level", permission_level);
    insert_opt_string(&mut payload, "owner_email", &owner_email.map(String::from));
    payload.insert("document_count".into(), Value::Int(0));
    insert_opt_string(&mut payload, "sync_state", &Some("pending".into()));
    if let Some(order) = sort_order {
        payload.insert("sort_order".into(), Value::Int(order));
    }

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/scix-library".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: None,
    }
}

/// Convert annotation fields to an Item.
/// Parent: the linked-file item this annotation is on.
pub fn annotation_to_item(
    linked_file_id: ItemId,
    annotation_type: &str,
    page_number: i64,
    bounds_json: Option<&str>,
    color: Option<&str>,
    contents: Option<&str>,
    selected_text: Option<&str>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "annotation_type", annotation_type);
    payload.insert("page_number".into(), Value::Int(page_number));
    insert_opt_string(&mut payload, "bounds_json", &bounds_json.map(String::from));
    insert_opt_string(&mut payload, "color", &color.map(String::from));
    insert_opt_string(&mut payload, "contents", &contents.map(String::from));
    insert_opt_string(&mut payload, "selected_text", &selected_text.map(String::from));

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/annotation".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: Some(linked_file_id),
    }
}

/// Convert comment fields to an Item.
/// Parent: the bibliography-entry item this comment is on.
pub fn comment_to_item(
    publication_id: ItemId,
    text: &str,
    author_identifier: Option<&str>,
    author_display_name: Option<&str>,
    parent_comment_id: Option<&str>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "text", text);
    insert_opt_string(&mut payload, "author_identifier", &author_identifier.map(String::from));
    insert_opt_string(&mut payload, "author_display_name", &author_display_name.map(String::from));
    insert_opt_string(&mut payload, "parent_comment_id", &parent_comment_id.map(String::from));

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/comment".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: Some(publication_id),
    }
}

/// Convert assignment fields to an Item.
/// Parent: the bibliography-entry item this assignment is for.
pub fn assignment_to_item(
    publication_id: ItemId,
    assignee_name: &str,
    assigned_by_name: Option<&str>,
    note: Option<&str>,
    due_date: Option<i64>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "assignee_name", assignee_name);
    insert_opt_string(&mut payload, "assigned_by_name", &assigned_by_name.map(String::from));
    insert_opt_string(&mut payload, "note", &note.map(String::from));
    if let Some(dd) = due_date {
        payload.insert("due_date".into(), Value::Int(dd));
    }

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/assignment".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: Some(publication_id),
    }
}

/// Convert activity record fields to an Item.
/// Parent: the library item this activity belongs to.
pub fn activity_record_to_item(
    library_id: ItemId,
    activity_type: &str,
    actor_display_name: Option<&str>,
    target_title: Option<&str>,
    target_id: Option<&str>,
    detail: Option<&str>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_string(&mut payload, "activity_type", activity_type);
    insert_opt_string(&mut payload, "actor_display_name", &actor_display_name.map(String::from));
    insert_opt_string(&mut payload, "target_title", &target_title.map(String::from));
    insert_opt_string(&mut payload, "target_id", &target_id.map(String::from));
    insert_opt_string(&mut payload, "detail", &detail.map(String::from));

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/activity-record".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: Some(library_id),
    }
}

/// Convert recommendation profile fields to an Item.
/// Parent: the library item this profile belongs to.
pub fn recommendation_profile_to_item(
    library_id: ItemId,
    topic_affinities_json: Option<&str>,
    author_affinities_json: Option<&str>,
    venue_affinities_json: Option<&str>,
    training_events_json: Option<&str>,
) -> Item {
    let mut payload = BTreeMap::new();
    insert_opt_string(&mut payload, "topic_affinities_json", &topic_affinities_json.map(String::from));
    insert_opt_string(&mut payload, "author_affinities_json", &author_affinities_json.map(String::from));
    insert_opt_string(&mut payload, "venue_affinities_json", &venue_affinities_json.map(String::from));
    insert_opt_string(&mut payload, "training_events_json", &training_events_json.map(String::from));

    Item {
        id: Uuid::new_v4(),
        schema: "imbib/recommendation-profile".into(),
        payload,
        created: Utc::now(),
        author: "system".into(),
        author_kind: ActorKind::System,
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::Normal,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        batch_id: None,
        references: vec![],
        parent: Some(library_id),
    }
}

// --- Helpers ---

fn format_author_text(authors: &[crate::domain::Author]) -> String {
    authors
        .iter()
        .map(|a| match &a.given_name {
            Some(given) if !given.is_empty() => format!("{}, {}", a.family_name, given),
            _ => a.family_name.clone(),
        })
        .collect::<Vec<_>>()
        .join("; ")
}

fn insert_string(payload: &mut BTreeMap<String, Value>, key: &str, val: &str) {
    if !val.is_empty() {
        payload.insert(key.into(), Value::String(val.into()));
    }
}

fn insert_opt_string(payload: &mut BTreeMap<String, Value>, key: &str, val: &Option<String>) {
    if let Some(v) = val {
        if !v.is_empty() {
            payload.insert(key.into(), Value::String(v.clone()));
        }
    }
}

fn insert_opt_int(payload: &mut BTreeMap<String, Value>, key: &str, val: &Option<i32>) {
    if let Some(v) = val {
        payload.insert(key.into(), Value::Int(*v as i64));
    }
}

fn get_string(payload: &BTreeMap<String, Value>, key: &str) -> Option<String> {
    match payload.get(key) {
        Some(Value::String(s)) => Some(s.clone()),
        _ => None,
    }
}

fn get_int(payload: &BTreeMap<String, Value>, key: &str) -> Option<i64> {
    match payload.get(key) {
        Some(Value::Int(i)) => Some(*i),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::{Author, Identifiers, Publication};
    use std::collections::HashMap;

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
            authors: vec![
                make_author("John", "Smith"),
                make_author("Jane", "Doe"),
            ],
            editors: vec![],
            journal: Some("ApJ".into()),
            booktitle: None,
            publisher: None,
            volume: Some("900".into()),
            number: None,
            pages: Some("1-15".into()),
            edition: None,
            series: None,
            address: None,
            chapter: None,
            howpublished: None,
            institution: None,
            organization: None,
            school: None,
            note: Some("Important paper".into()),
            abstract_text: Some("We study dark matter".into()),
            keywords: vec!["dark matter".into(), "galaxies".into()],
            url: None,
            eprint: Some("2401.00001".into()),
            primary_class: Some("astro-ph.GA".into()),
            archive_prefix: Some("arXiv".into()),
            identifiers: Identifiers {
                doi: Some("10.3847/1538-4357/abc123".into()),
                arxiv_id: Some("2401.00001".into()),
                bibcode: Some("2024ApJ...900....1S".into()),
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
    fn publication_to_item_round_trip() {
        let pub_data = make_publication();
        let item = publication_to_item(&pub_data, None);

        assert_eq!(item.schema, "imbib/bibliography-entry");
        assert_eq!(
            get_string(&item.payload, "cite_key"),
            Some("smith2024".into())
        );
        assert_eq!(
            get_string(&item.payload, "title"),
            Some("Dark Matter in Galaxies".into())
        );
        assert_eq!(get_int(&item.payload, "year"), Some(2024));
        assert_eq!(
            get_string(&item.payload, "doi"),
            Some("10.3847/1538-4357/abc123".into())
        );
        assert_eq!(get_int(&item.payload, "citation_count"), Some(42));
        assert!(item.tags.contains(&"methods/sims".to_string()));

        // Round-trip back
        let pub_back = item_to_publication(&item);
        assert_eq!(pub_back.cite_key, pub_data.cite_key);
        assert_eq!(pub_back.title, pub_data.title);
        assert_eq!(pub_back.year, pub_data.year);
        assert_eq!(pub_back.identifiers.doi, pub_data.identifiers.doi);
        assert_eq!(pub_back.identifiers.arxiv_id, pub_data.identifiers.arxiv_id);
        assert_eq!(pub_back.citation_count, pub_data.citation_count);
        assert_eq!(pub_back.note, pub_data.note);
        assert_eq!(pub_back.tags, pub_data.tags);
        assert_eq!(pub_back.journal, pub_data.journal);
    }

    #[test]
    fn library_to_item_fields() {
        let item = library_to_item("My Library", Some("/path/to/lib.bib"), None, true, false, false);
        assert_eq!(item.schema, "imbib/library");
        assert_eq!(get_string(&item.payload, "name"), Some("My Library".into()));
        assert_eq!(
            item.payload.get("is_default"),
            Some(&Value::Bool(true))
        );
    }

    #[test]
    fn collection_to_item_fields() {
        let parent = Uuid::new_v4();
        let item = collection_to_item("Favorites", Some(parent), false, None, Some(5));
        assert_eq!(item.schema, "imbib/collection");
        assert_eq!(item.parent, Some(parent));
        assert_eq!(
            get_string(&item.payload, "name"),
            Some("Favorites".into())
        );
        assert_eq!(get_int(&item.payload, "sort_order"), Some(5));
    }

    #[test]
    fn tag_definition_to_item_fields() {
        let item = tag_definition_to_item(
            "sims",
            "methods/sims",
            Some("#ff0000"),
            Some("#cc0000"),
            None,
            None,
        );
        assert_eq!(item.schema, "imbib/tag-definition");
        assert_eq!(
            get_string(&item.payload, "canonical_path"),
            Some("methods/sims".into())
        );
        assert_eq!(
            get_string(&item.payload, "color_light"),
            Some("#ff0000".into())
        );
    }

    #[test]
    fn schema_validation_passes_for_converted_items() {
        let mut reg = impress_core::SchemaRegistry::new();
        super::super::schemas::register_all(&mut reg);

        let pub_data = make_publication();
        let item = publication_to_item(&pub_data, None);
        assert!(reg.validate(&item).is_ok());

        let lib_item = library_to_item("Test", None, None, false, false, false);
        assert!(reg.validate(&lib_item).is_ok());

        let coll_item = collection_to_item("Test", None, false, None, None);
        assert!(reg.validate(&coll_item).is_ok());
    }

    #[test]
    fn linked_file_to_item_fields() {
        let pub_id = Uuid::new_v4();
        let item = linked_file_to_item(pub_id, "paper.pdf", Some("Papers/paper.pdf"), Some("pdf"), 1024, Some("abc123"), true);
        assert_eq!(item.schema, "imbib/linked-file");
        assert_eq!(item.parent, Some(pub_id));
        assert_eq!(get_string(&item.payload, "filename"), Some("paper.pdf".into()));
        assert_eq!(item.payload.get("is_pdf"), Some(&Value::Bool(true)));
        assert_eq!(item.payload.get("file_size"), Some(&Value::Int(1024)));
    }

    #[test]
    fn smart_search_to_item_fields() {
        let lib_id = Uuid::new_v4();
        let item = smart_search_to_item("My Search", "dark matter", lib_id, Some("[\"ADS\",\"arXiv\"]"), 50, true, false, 3600, Some(1));
        assert_eq!(item.schema, "imbib/smart-search");
        assert_eq!(item.parent, Some(lib_id));
        assert_eq!(get_string(&item.payload, "name"), Some("My Search".into()));
        assert_eq!(get_string(&item.payload, "query"), Some("dark matter".into()));
        assert_eq!(item.payload.get("feeds_to_inbox"), Some(&Value::Bool(true)));
        assert_eq!(item.payload.get("max_results"), Some(&Value::Int(50)));
    }

    #[test]
    fn muted_item_to_item_fields() {
        let item = muted_item_to_item("author", "Smith, John");
        assert_eq!(item.schema, "imbib/muted-item");
        assert_eq!(get_string(&item.payload, "mute_type"), Some("author".into()));
        assert_eq!(get_string(&item.payload, "value"), Some("Smith, John".into()));
        assert!(item.parent.is_none());
    }

    #[test]
    fn dismissed_paper_to_item_fields() {
        let item = dismissed_paper_to_item(Some("10.1234/test"), Some("2401.00001"), None);
        assert_eq!(item.schema, "imbib/dismissed-paper");
        assert_eq!(get_string(&item.payload, "doi"), Some("10.1234/test".into()));
        assert_eq!(get_string(&item.payload, "arxiv_id"), Some("2401.00001".into()));
        assert!(get_string(&item.payload, "bibcode").is_none());
    }

    #[test]
    fn scix_library_to_item_fields() {
        let item = scix_library_to_item("remote-123", "My ADS Lib", Some("A test library"), true, "owner", Some("test@example.com"), None);
        assert_eq!(item.schema, "imbib/scix-library");
        assert_eq!(get_string(&item.payload, "remote_id"), Some("remote-123".into()));
        assert_eq!(get_string(&item.payload, "name"), Some("My ADS Lib".into()));
        assert_eq!(item.payload.get("is_public"), Some(&Value::Bool(true)));
    }

    #[test]
    fn annotation_to_item_fields() {
        let file_id = Uuid::new_v4();
        let item = annotation_to_item(file_id, "highlight", 5, Some("{\"x\":10}"), Some("#ffff00"), None, Some("dark matter"));
        assert_eq!(item.schema, "imbib/annotation");
        assert_eq!(item.parent, Some(file_id));
        assert_eq!(get_string(&item.payload, "annotation_type"), Some("highlight".into()));
        assert_eq!(item.payload.get("page_number"), Some(&Value::Int(5)));
        assert_eq!(get_string(&item.payload, "selected_text"), Some("dark matter".into()));
    }

    #[test]
    fn comment_to_item_fields() {
        let pub_id = Uuid::new_v4();
        let item = comment_to_item(pub_id, "Great paper!", Some("user-123"), Some("Jane Doe"), None);
        assert_eq!(item.schema, "imbib/comment");
        assert_eq!(item.parent, Some(pub_id));
        assert_eq!(get_string(&item.payload, "text"), Some("Great paper!".into()));
        assert_eq!(get_string(&item.payload, "author_display_name"), Some("Jane Doe".into()));
    }

    #[test]
    fn assignment_to_item_fields() {
        let pub_id = Uuid::new_v4();
        let item = assignment_to_item(pub_id, "Alice", Some("Bob"), Some("Read by Friday"), Some(1700000000000));
        assert_eq!(item.schema, "imbib/assignment");
        assert_eq!(item.parent, Some(pub_id));
        assert_eq!(get_string(&item.payload, "assignee_name"), Some("Alice".into()));
        assert_eq!(item.payload.get("due_date"), Some(&Value::Int(1700000000000)));
    }

    #[test]
    fn activity_record_to_item_fields() {
        let lib_id = Uuid::new_v4();
        let item = activity_record_to_item(lib_id, "added", Some("Jane"), Some("Dark Matter Paper"), None, None);
        assert_eq!(item.schema, "imbib/activity-record");
        assert_eq!(item.parent, Some(lib_id));
        assert_eq!(get_string(&item.payload, "activity_type"), Some("added".into()));
    }

    #[test]
    fn recommendation_profile_to_item_fields() {
        let lib_id = Uuid::new_v4();
        let item = recommendation_profile_to_item(lib_id, Some("{\"cosmo\":0.8}"), None, None, None);
        assert_eq!(item.schema, "imbib/recommendation-profile");
        assert_eq!(item.parent, Some(lib_id));
        assert_eq!(get_string(&item.payload, "topic_affinities_json"), Some("{\"cosmo\":0.8}".into()));
    }

    #[test]
    fn all_new_schemas_validate() {
        let mut reg = impress_core::SchemaRegistry::new();
        super::super::schemas::register_all(&mut reg);

        let pub_id = Uuid::new_v4();
        let lib_id = Uuid::new_v4();
        let file_id = Uuid::new_v4();

        assert!(reg.validate(&linked_file_to_item(pub_id, "test.pdf", None, None, 0, None, true)).is_ok());
        assert!(reg.validate(&smart_search_to_item("q", "test", lib_id, None, 100, false, false, 3600, None)).is_ok());
        assert!(reg.validate(&muted_item_to_item("author", "Smith")).is_ok());
        assert!(reg.validate(&dismissed_paper_to_item(Some("10.1/x"), None, None)).is_ok());
        assert!(reg.validate(&scix_library_to_item("r1", "lib", None, false, "read", None, None)).is_ok());
        assert!(reg.validate(&annotation_to_item(file_id, "highlight", 1, None, None, None, None)).is_ok());
        assert!(reg.validate(&comment_to_item(pub_id, "hi", None, None, None)).is_ok());
        assert!(reg.validate(&assignment_to_item(pub_id, "Alice", None, None, None)).is_ok());
        assert!(reg.validate(&activity_record_to_item(lib_id, "added", None, None, None, None)).is_ok());
        assert!(reg.validate(&recommendation_profile_to_item(lib_id, None, None, None, None)).is_ok());
    }
}
