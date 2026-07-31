use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for the `manuscript@1.0.0` item type.
///
/// A manuscript is a long-lived envelope item representing a paper, draft, or
/// other authored document tracked by the impress journal pipeline. Its
/// `current_revision_ref` advances forward as new revisions are snapshotted;
/// reviews and revision notes accumulate as `Annotates` edges from
/// knowledge-object items (per ADR-0012). The actual `.tex` / `.typ` source
/// lives in imprint and is bridged via a `Contains` edge with
/// `metadata.kind = "imprint-source"` (per ADR-0011 D3).
///
/// See `docs/ADR-0011-impress-journal.md` D1 for full field semantics.
pub fn manuscript_schema() -> Schema {
    Schema {
        id: "manuscript".into(),
        name: "Manuscript".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "title".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Working title; updated via SetPayload operations.".into()),
            },
            FieldDef {
                name: "status".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Lifecycle state: draft | internal-review | submitted | in-revision | \
                     published | archived."
                        .into(),
                ),
            },
            FieldDef {
                name: "current_revision_ref".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "ItemId (UUID string) of the most recent manuscript-revision item.".into(),
                ),
            },
            FieldDef {
                name: "authors".into(),
                field_type: FieldType::StringArray,
                required: false,
                description: Some(
                    "Author display strings at the time of last revision; updated by snapshot."
                        .into(),
                ),
            },
            FieldDef {
                name: "journal_target".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Target journal name (free text; not validated).".into()),
            },
            FieldDef {
                name: "submission_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "External submission identifier (e.g. \"PRD-123456\") if submitted.".into(),
                ),
            },
            FieldDef {
                name: "topic_tags".into(),
                field_type: FieldType::StringArray,
                required: false,
                description: Some(
                    "Topic classifications used by smart collections in imbib.".into(),
                ),
            },
            FieldDef {
                name: "notes".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Free-form notes on the manuscript as a whole.".into()),
            },
            // -----------------------------------------------------------------
            // Body-in-store fields (added by the impress-wide unified-store
            // pivot — see plan-one-store-the-store).
            //
            // The manuscript body now lives inside the manuscript item's
            // payload rather than on the filesystem next to it. Toolchains
            // (LaTeX compile, Veusz render) request a render-time
            // materialization to `<working dir>/.tmp/main.{typ|tex}` and
            // clean it up after the invocation returns.
            //
            // All seven fields are optional so v1.0 items (no body, only
            // metadata) continue to validate.
            // -----------------------------------------------------------------
            FieldDef {
                name: "format".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Source format: \"typst\" | \"latex\". Drives extension of the \
                     materialized body file (main.typ vs main.tex) and the rendered \
                     plot format default (SVG for Typst, PDF for LaTeX)."
                        .into(),
                ),
            },
            FieldDef {
                name: "body_content".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "UTF-8 source text (LaTeX or Typst markup). Editor reads/writes \
                     via the manuscript store adapter with a 200ms idle debounce. \
                     For bodies > 1 MB, store as a `blob:sha256:...` ref via a sibling \
                     artifact item (matching the manuscript-revision.source_archive_ref \
                     precedent)."
                        .into(),
                ),
            },
            FieldDef {
                name: "crdt_state".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Base64-encoded Automerge state bytes for Typst manuscripts. Null \
                     for LaTeX. Same >1 MB blob-ref escape hatch as `body_content`."
                        .into(),
                ),
            },
            FieldDef {
                name: "body_content_hash".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "SHA-256 hex of `body_content`. Used to detect external drift and \
                     to dedup imports against existing manuscripts."
                        .into(),
                ),
            },
            FieldDef {
                name: "body_modified_at".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ISO 8601 timestamp of the most recent body edit (separate from the \
                     envelope's `modified` so metadata-only updates don't bump it)."
                        .into(),
                ),
            },
            FieldDef {
                name: "format_schema_version".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some(
                    "Per-item payload schema version. Drives ManuscriptPayloadMigrator \
                     (formerly imprint's DocumentMigrator) so new payload fields can be \
                     added without breaking older items."
                        .into(),
                ),
            },
            // -----------------------------------------------------------------
            // Reference-in-place (ADR-0023 D4, W3).
            //
            // `import_source` and `external_source` are OPPOSITES and must not
            // be confused: `import_source` says "a copy was taken and the
            // original is DETACHED"; `external_source` says "the file on disk
            // is still authoritative and this row is an INDEX ENTRY".
            // -----------------------------------------------------------------
            FieldDef {
                name: "external_source".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "JSON-encoded `{ path: String, bookmark_base64: String?, \
                     content_hash: String, size_bytes: Int?, \
                     watched_file_id: String?, watched_folder_id: String?, \
                     folder_name: String?, read_at: String?, state: \
                     \"present\"|\"missing\" }`. Present ⇒ this manuscript is \
                     REFERENCE-IN-PLACE (ADR-0023 D4): the file named by `path` \
                     is authoritative for the body, `body_content` holds only \
                     the snapshot read at `read_at`, and `content_hash` is the \
                     hash of the FILE (not of `body_content`) as of that read. \
                     Nothing in the suite writes the file back; a row carrying \
                     this field takes no editor session, so no debounced \
                     compare-and-set save can resurrect a stale body over an \
                     externally-edited file. `state: \"missing\"` mirrors the \
                     `watched-file` row's own state — the row is kept and \
                     flagged, never deleted."
                        .into(),
                ),
            },
            FieldDef {
                name: "import_source".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "JSON-encoded `{ kind: \"tex\" | \"imprint\", original_path: String?, \
                     original_path_bookmark_base64: String? }`. Informational only; \
                     powers the \"Imported from \\<path\\>. Original is detached.\" \
                     banner and the \"Reveal in Finder\" affordance."
                        .into(),
                ),
            },
            // -----------------------------------------------------------------
            // imbib bridge + FAIR attribution fields (added in Phase F1 of the
            // unified-store plan). Migrated 1:1 from the legacy
            // `ImprintDocument` so the macOS callsite refactor (ROCrateBuilder,
            // ManuscriptLibraryCoordinator) can pull these off the
            // `manuscript` payload instead of going through the legacy type.
            // All optional — pre-existing items continue to validate.
            // -----------------------------------------------------------------
            FieldDef {
                name: "linked_imbib_manuscript_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "UUID string of the linked imbib manuscript-record, if any. \
                     Maintained by ManuscriptLibraryCoordinator when the user \
                     associates a draft with an imbib library entry."
                        .into(),
                ),
            },
            FieldDef {
                name: "linked_imbib_library_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "UUID string of the imbib library that holds papers cited \
                     by this manuscript. Created on first save by \
                     ManuscriptLibraryCoordinator."
                        .into(),
                ),
            },
            FieldDef {
                name: "orcid".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Author ORCID (FAIR attribution, ADR-0014 D54).".into()),
            },
            FieldDef {
                name: "affiliation".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Author affiliation (FAIR attribution).".into()),
            },
            FieldDef {
                name: "funder".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Funding source (FAIR attribution).".into()),
            },
            FieldDef {
                name: "license".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Manuscript license identifier (FAIR attribution).".into()),
            },
            FieldDef {
                name: "embargo_until".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ISO 8601 embargo expiration (informational only — no enforcement code)."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![
            EdgeType::HasVersion,
            EdgeType::Contains,
            EdgeType::Cites,
            EdgeType::Visualizes,
            EdgeType::Annotates,
            EdgeType::DerivedFrom,
        ],
        inherits: None,
    }
}

/// Register the `manuscript@1.0.0` schema.
pub fn register_manuscript_schema(registry: &mut SchemaRegistry) {
    registry
        .register(manuscript_schema())
        .expect("manuscript schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manuscript_schema_registers() {
        let mut reg = SchemaRegistry::new();
        register_manuscript_schema(&mut reg);
        assert!(reg.get("manuscript").is_some());
    }

    #[test]
    fn manuscript_schema_required_fields() {
        let s = manuscript_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"title"));
        assert!(required.contains(&"status"));
        assert!(required.contains(&"current_revision_ref"));
    }

    #[test]
    fn manuscript_schema_expected_edges() {
        let s = manuscript_schema();
        assert!(s.expected_edges.contains(&EdgeType::HasVersion));
        assert!(s.expected_edges.contains(&EdgeType::Contains));
        assert!(s.expected_edges.contains(&EdgeType::Annotates));
    }

    #[test]
    fn manuscript_schema_serde_round_trip() {
        let s = manuscript_schema();
        let json = serde_json::to_string_pretty(&s).unwrap();
        let back: Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }

    #[test]
    fn manuscript_schema_body_fields_present_and_optional() {
        let s = manuscript_schema();
        let body_fields = [
            "format",
            "body_content",
            "crdt_state",
            "body_content_hash",
            "body_modified_at",
            "format_schema_version",
            "import_source",
        ];
        for name in &body_fields {
            let field = s.fields.iter().find(|f| f.name == *name);
            assert!(field.is_some(), "body field '{}' should exist", name);
            assert!(
                !field.unwrap().required,
                "body field '{}' must be optional so pre-pivot items still validate",
                name
            );
        }
    }

    /// ADR-0023 D4/W3. A reference-in-place manuscript declares its file
    /// through `external_source`; the field must exist, be optional (every
    /// manuscript written before W3 has none) and be distinct from
    /// `import_source`, whose meaning is the opposite.
    #[test]
    fn manuscript_schema_declares_optional_external_source() {
        let s = manuscript_schema();
        let external = s
            .fields
            .iter()
            .find(|f| f.name == "external_source")
            .expect("external_source must be declared (ADR-0023 D4)");
        assert!(
            !external.required,
            "external_source must be optional: an ordinary manuscript has none"
        );
        assert_eq!(external.field_type, FieldType::String);
        assert!(
            s.fields.iter().any(|f| f.name == "import_source"),
            "import_source stays: a reference and a detached copy are different claims"
        );
    }

    /// The whole no-write-back argument lives in the field's own description,
    /// because a payload field is where the next reader looks. If the
    /// description stops saying it, the invariant has quietly become folklore.
    #[test]
    fn external_source_description_states_the_no_write_back_rule() {
        let s = manuscript_schema();
        let description = s
            .fields
            .iter()
            .find(|f| f.name == "external_source")
            .and_then(|f| f.description.clone())
            .unwrap_or_default();
        assert!(description.contains("authoritative"));
        assert!(description.contains("no editor session"));
        assert!(description.contains("never deleted"));
    }
}
