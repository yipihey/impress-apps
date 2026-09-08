use impress_core::reference::EdgeType;
use impress_core::schema::{FieldDef, FieldType, Schema};

/// Schema for bibliography entries (maps to CDPublication / Publication).
pub fn bibliography_entry_schema() -> Schema {
    Schema {
        id: "imbib/bibliography-entry".into(),
        name: "Bibliography Entry".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("cite_key"),
            required_string("entry_type"),
            optional_string("title"),
            optional_string("author_text"),
            optional_int("year"),
            optional_string("month"),
            optional_string("journal"),
            optional_string("booktitle"),
            optional_string("publisher"),
            optional_string("volume"),
            optional_string("number"),
            optional_string("pages"),
            optional_string("edition"),
            optional_string("series"),
            optional_string("address"),
            optional_string("chapter"),
            optional_string("howpublished"),
            optional_string("institution"),
            optional_string("organization"),
            optional_string("school"),
            optional_string("note"),
            optional_string("abstract_text"),
            optional_string("url"),
            optional_string("eprint"),
            optional_string("primary_class"),
            optional_string("archive_prefix"),
            // Identifiers
            optional_string("doi"),
            optional_string("arxiv_id"),
            optional_string("pmid"),
            optional_string("pmcid"),
            optional_string("bibcode"),
            optional_string("isbn"),
            optional_string("issn"),
            // Metadata
            optional_string("venue"),
            optional_int("citation_count"),
            optional_int("reference_count"),
            optional_string("source_id"),
            optional_string("enrichment_source"),
            optional_string("enrichment_date"),
            optional_string("raw_bibtex"),
            optional_string("raw_ris"),
            // Structured data as JSON objects
            field("keywords", FieldType::StringArray, false),
            optional_string("authors_json"),
            field("editors_json", FieldType::Object, false),
            field("extra_fields", FieldType::Object, false),
            field("linked_files_json", FieldType::Object, false),
        ],
        expected_edges: vec![EdgeType::Cites, EdgeType::Attaches, EdgeType::Contains],
        inherits: None,
    }
}

/// Schema for libraries (maps to CDLibrary).
pub fn library_schema() -> Schema {
    Schema {
        id: "imbib/library".into(),
        name: "Library".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("name"),
            optional_string("bib_file_path"),
            optional_string("papers_directory_path"),
            field("is_default", FieldType::Bool, false),
            field("is_inbox", FieldType::Bool, false),
            field("is_system", FieldType::Bool, false),
        ],
        expected_edges: vec![EdgeType::Contains],
        inherits: None,
    }
}

/// Schema for collections (maps to CDCollection).
pub fn collection_schema() -> Schema {
    Schema {
        id: "imbib/collection".into(),
        name: "Collection".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("name"),
            field("is_smart", FieldType::Bool, false),
            optional_string("smart_query"),
            optional_int("sort_order"),
        ],
        expected_edges: vec![EdgeType::Contains],
        inherits: None,
    }
}

/// Schema for tag definitions (maps to CDTag).
pub fn tag_definition_schema() -> Schema {
    Schema {
        id: "imbib/tag-definition".into(),
        name: "Tag Definition".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("name"),
            required_string("canonical_path"),
            optional_string("color_light"),
            optional_string("color_dark"),
            optional_int("sort_order"),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for linked files / attachments (maps to CDLinkedFile).
/// Parent: bibliography-entry item.
pub fn linked_file_schema() -> Schema {
    Schema {
        id: "imbib/linked-file".into(),
        name: "Linked File".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("filename"),
            optional_string("relative_path"),
            optional_string("file_type"),
            optional_string("sha256"),
            optional_string("display_name"),
            optional_int("file_size"),
            optional_string("mime_type"),
            field("is_pdf", FieldType::Bool, false),
            field("is_locally_materialized", FieldType::Bool, false),
            field("pdf_cloud_available", FieldType::Bool, false),
            // Which copy this is: absent or `primary` for the file the user
            // attached, `eink-annotated` for the tablet's rendition with the
            // handwriting burned in, `eink-rmdoc` for the raw archive.
            optional_string("role"),
            optional_string("source_device_id"),
            optional_string("source_remote_id"),
            optional_int("source_remote_modified_ms"),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for smart searches / saved queries (maps to CDSmartSearch).
/// Parent: library item.
pub fn smart_search_schema() -> Schema {
    Schema {
        id: "imbib/smart-search".into(),
        name: "Smart Search".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("name"),
            required_string("query"),
            optional_string("source_ids_json"),
            optional_int("max_results"),
            field("feeds_to_inbox", FieldType::Bool, false),
            field("auto_refresh_enabled", FieldType::Bool, false),
            optional_int("refresh_interval_seconds"),
            optional_int("last_fetch_count"),
            optional_int("last_executed"),
            optional_int("sort_order"),
            // Phase 1: generalized feed settings
            optional_string("save_target_id"),
            field("show_dismissed", FieldType::Bool, false),
            optional_int("retention_days"),
            field("auto_remove_read", FieldType::Bool, false),
        ],
        expected_edges: vec![EdgeType::Contains],
        inherits: None,
    }
}

/// Schema for muted items — authors/venues/categories to hide from inbox (maps to CDMutedItem).
pub fn muted_item_schema() -> Schema {
    Schema {
        id: "imbib/muted-item".into(),
        name: "Muted Item".into(),
        version: "1.0.0".into(),
        fields: vec![required_string("mute_type"), required_string("value")],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for dismissed papers — papers explicitly dismissed from inbox (maps to CDDismissedPaper).
pub fn dismissed_paper_schema() -> Schema {
    Schema {
        id: "imbib/dismissed-paper".into(),
        name: "Dismissed Paper".into(),
        version: "1.0.1".into(),
        fields: vec![
            optional_string("doi"),
            optional_string("arxiv_id"),
            optional_string("bibcode"),
            optional_string("cite_key"),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for SciX (ADS) remote libraries (maps to CDSciXLibrary).
pub fn scix_library_schema() -> Schema {
    Schema {
        id: "imbib/scix-library".into(),
        name: "SciX Library".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("remote_id"),
            required_string("name"),
            optional_string("description"),
            field("is_public", FieldType::Bool, false),
            optional_int("last_sync_date"),
            optional_string("sync_state"),
            optional_string("permission_level"),
            optional_string("owner_email"),
            optional_int("document_count"),
            optional_string("pending_changes_json"),
            optional_int("sort_order"),
        ],
        expected_edges: vec![EdgeType::Contains],
        inherits: None,
    }
}

/// Schema for PDF annotations (maps to CDAnnotation).
/// Parent: linked-file item.
pub fn annotation_schema() -> Schema {
    Schema {
        id: "imbib/annotation".into(),
        name: "Annotation".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("annotation_type"),
            optional_int("page_number"),
            optional_string("bounds_json"),
            optional_string("color"),
            optional_string("contents"),
            optional_string("selected_text"),
            optional_string("author_name"),
            optional_string("sync_state"),
            // Provenance for rows an e-ink import wrote: where they came from
            // (`remarkable`), which tablet document, page and stroke item, so a
            // re-import updates rather than duplicates.
            optional_string("source"),
            optional_string("source_device_id"),
            optional_string("source_remote_id"),
            optional_string("source_page_id"),
            optional_string("source_item_id"),
            // Container-relative path of a rendered PNG of the strokes.
            optional_string("image_path"),
            optional_string("pen"),
            optional_string("strokes_hash"),
            field("ocr_confidence", FieldType::Float, false),
            optional_int("imported_at_ms"),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for an e-ink tablet imbib mirrors papers to (one row per device).
/// No parent. Written only by `ImbibStore::eink_configure_device` and the
/// mirror engine's per-sync stamps (`crates/imbib-core/src/eink/store.rs`).
pub fn eink_device_schema() -> Schema {
    Schema {
        id: "imbib/eink-device".into(),
        name: "E-ink Device".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("name"),
            required_string("transport"),
            optional_string("base_url"),
            required_string("mirror_mode"),
            optional_string("root_folder_name"),
            field("mirror_collections", FieldType::Bool, false),
            field("include_library_level", FieldType::Bool, false),
            field("include_inbox", FieldType::Bool, false),
            optional_string("folder_strategy"),
            field("file_in_nearest_folder", FieldType::Bool, false),
            optional_string("upload_format"),
            field("auto_fetch_source", FieldType::Bool, false),
            field("import_annotated_pdf", FieldType::Bool, false),
            field("import_rmdoc", FieldType::Bool, false),
            field("import_highlights", FieldType::Bool, false),
            field("import_ink", FieldType::Bool, false),
            field("import_typed_text", FieldType::Bool, false),
            field("run_ocr", FieldType::Bool, false),
            field("auto_import_on_connect", FieldType::Bool, false),
            field("enabled", FieldType::Bool, false),
            optional_int("last_sync_at_ms"),
            optional_int("last_seen_at_ms"),
            optional_int("sync_started_at_ms"),
            optional_string("last_error"),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for one publication's presence on one e-ink device.
/// Parent: the bibliography-entry item, so `HasParent` finds a paper's rows
/// and the row goes with the paper into undo snapshots. Written only by the
/// mirror engine (`crates/imbib-core/src/eink/store.rs`).
pub fn eink_mirror_schema() -> Schema {
    Schema {
        id: "imbib/eink-mirror".into(),
        name: "E-ink Mirror".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("device_id"),
            field("marked", FieldType::Bool, false),
            optional_int("marked_at_ms"),
            optional_string("linked_file_id"),
            optional_string("source_kind"),
            optional_string("remote_id"),
            optional_string("remote_parent_id"),
            optional_string("remote_name"),
            optional_string("remote_path"),
            // Set only when the paper is filed above where it belongs,
            // because the tablet lacks that folder.
            optional_string("desired_path"),
            optional_string("uploaded_sha256"),
            optional_int("uploaded_size"),
            optional_int("uploaded_at_ms"),
            optional_string("superseded_remote_id"),
            required_string("state"),
            optional_string("last_error"),
            optional_int("attempts"),
            optional_int("last_attempt_ms"),
            optional_int("remote_modified_ms"),
            optional_int("imported_modified_ms"),
            optional_string("annotated_file_id"),
            field("resend", FieldType::Bool, false),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for threaded comments on publications (maps to CDComment).
/// Parent: bibliography-entry item.
pub fn comment_schema() -> Schema {
    Schema {
        id: "imbib/comment".into(),
        name: "Comment".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("text"),
            optional_string("author_identifier"),
            optional_string("author_display_name"),
            optional_string("parent_comment_id"),
            optional_string("sync_state"),
            // Range anchor (optional — plain comments have none).
            // Byte offsets into the parent item's body text.
            optional_int("anchor_start"),
            optional_int("anchor_end"),
            // Snippet the range covered, used for re-anchoring after edits.
            optional_string("anchor_text"),
            // The body_content_hash the range was valid against.
            optional_string("anchored_body_hash"),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for paper assignments (maps to CDAssignment).
/// Parent: bibliography-entry item.
pub fn assignment_schema() -> Schema {
    Schema {
        id: "imbib/assignment".into(),
        name: "Assignment".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("assignee_name"),
            optional_string("assigned_by_name"),
            optional_string("note"),
            optional_int("due_date"),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for library activity log entries (maps to CDActivityRecord).
/// Parent: library item.
pub fn activity_record_schema() -> Schema {
    Schema {
        id: "imbib/activity-record".into(),
        name: "Activity Record".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("activity_type"),
            optional_string("actor_display_name"),
            optional_string("target_title"),
            optional_string("target_id"),
            optional_string("detail"),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for recommendation profiles (maps to CDRecommendationProfile).
/// Parent: library item.
pub fn recommendation_profile_schema() -> Schema {
    Schema {
        id: "imbib/recommendation-profile".into(),
        name: "Recommendation Profile".into(),
        version: "1.0.0".into(),
        fields: vec![
            optional_string("topic_affinities_json"),
            optional_string("author_affinities_json"),
            optional_string("venue_affinities_json"),
            optional_string("training_events_json"),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

/// Schema for operations — records of mutations applied to items.
pub fn core_operation_schema() -> Schema {
    Schema {
        id: "core/operation".into(),
        name: "Operation".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("target_id"),
            required_string("op_type"),
            required_string("intent"),
            field("op_data", FieldType::Object, false),
            optional_string("reason"),
        ],
        expected_edges: vec![EdgeType::OperatesOn],
        inherits: None,
    }
}

/// Register all imbib schemas (+ shared artifact schemas) in a registry.
pub fn register_all(registry: &mut impress_core::SchemaRegistry) {
    // Register suite-wide artifact schemas from impress-core
    impress_core::schemas::register_artifact_schemas(registry);

    // Journal/manuscript schemas (shared with imprint via impress-core).
    // The unified GUI reads and writes manuscript items through ImbibStore,
    // so its registry must know the same schema vocabulary imprint's
    // ManuscriptStoreAdapter writes.
    impress_core::schemas::register_manuscript_schema(registry);
    impress_core::schemas::register_manuscript_revision_schema(registry);
    impress_core::schemas::register_manuscript_collection_schema(registry);
    impress_core::schemas::register_imprint_schemas(registry); // manuscript-section

    registry
        .register(bibliography_entry_schema())
        .expect("bibliography-entry schema registration");
    registry
        .register(library_schema())
        .expect("library schema registration");
    registry
        .register(collection_schema())
        .expect("collection schema registration");
    registry
        .register(tag_definition_schema())
        .expect("tag-definition schema registration");
    registry
        .register(linked_file_schema())
        .expect("linked-file schema registration");
    registry
        .register(smart_search_schema())
        .expect("smart-search schema registration");
    registry
        .register(muted_item_schema())
        .expect("muted-item schema registration");
    registry
        .register(dismissed_paper_schema())
        .expect("dismissed-paper schema registration");
    registry
        .register(scix_library_schema())
        .expect("scix-library schema registration");
    registry
        .register(annotation_schema())
        .expect("annotation schema registration");
    registry
        .register(comment_schema())
        .expect("comment schema registration");
    registry
        .register(assignment_schema())
        .expect("assignment schema registration");
    registry
        .register(activity_record_schema())
        .expect("activity-record schema registration");
    registry
        .register(recommendation_profile_schema())
        .expect("recommendation-profile schema registration");
    registry
        .register(core_operation_schema())
        .expect("core/operation schema registration");
    registry
        .register(eink_device_schema())
        .expect("eink-device schema registration");
    registry
        .register(eink_mirror_schema())
        .expect("eink-mirror schema registration");
}

fn required_string(name: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type: FieldType::String,
        required: true,
        description: None,
    }
}

fn optional_string(name: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type: FieldType::String,
        required: false,
        description: None,
    }
}

fn optional_int(name: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type: FieldType::Int,
        required: false,
        description: None,
    }
}

fn field(name: &str, field_type: FieldType, required: bool) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type,
        required,
        description: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::SchemaRegistry;

    #[test]
    fn register_all_schemas() {
        let mut reg = SchemaRegistry::new();
        register_all(&mut reg);
        assert!(reg.get("imbib/bibliography-entry").is_some());
        assert!(reg.get("imbib/library").is_some());
        assert!(reg.get("imbib/collection").is_some());
        assert!(reg.get("imbib/tag-definition").is_some());
        assert!(reg.get("imbib/linked-file").is_some());
        assert!(reg.get("imbib/smart-search").is_some());
        assert!(reg.get("imbib/muted-item").is_some());
        assert!(reg.get("imbib/dismissed-paper").is_some());
        assert!(reg.get("imbib/scix-library").is_some());
        assert!(reg.get("imbib/annotation").is_some());
        assert!(reg.get("imbib/comment").is_some());
        assert!(reg.get("imbib/assignment").is_some());
        assert!(reg.get("imbib/activity-record").is_some());
        assert!(reg.get("imbib/recommendation-profile").is_some());
        assert!(reg.get("core/operation").is_some());
        assert!(reg.get("imbib/eink-device").is_some());
        assert!(reg.get("imbib/eink-mirror").is_some());
    }

    #[test]
    fn bib_entry_schema_has_required_fields() {
        let schema = bibliography_entry_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"cite_key"));
        assert!(required.contains(&"entry_type"));
    }

    #[test]
    fn no_duplicate_fields_in_schemas() {
        let mut reg = SchemaRegistry::new();
        // register_all will panic if any schema has duplicate fields
        register_all(&mut reg);
    }
}
