use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for the `manuscript-submission@1.0.0` item type.
///
/// A manuscript-submission is a structured submission payload that an agent
/// or human posts to the journal pipeline. It is a `task` subtype: Scout
/// receives the submission as a pending task, validates it, computes
/// deduplication, and proposes an outcome (new manuscript / new revision /
/// fragment under existing).
///
/// This schema replaces the PDR's transcript-directory-watcher concept. Per
/// ADR-0011 D6 the journal accepts only structured submissions in
/// steady-state; a one-off CLI backfill tool covers the import of
/// pre-existing transcript content.
///
/// See `docs/ADR-0011-impress-journal.md` D6 for the three submission entry
/// points (HTTP / MCP / CLI) and the persona contract for Scout.
pub fn manuscript_submission_schema() -> Schema {
    Schema {
        id: "manuscript-submission".into(),
        name: "Manuscript Submission".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "submission_kind".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "One of: new-manuscript | new-revision | fragment.".into(),
                ),
            },
            FieldDef {
                name: "title".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Submitter-provided title for the manuscript or revision.".into(),
                ),
            },
            FieldDef {
                name: "source_format".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Source format: tex | typst | markdown | html. \
                     The format determines compile dispatch (typst → typst engine, \
                     tex → tectonic, markdown/html → store-only)."
                        .into(),
                ),
            },
            FieldDef {
                name: "source_payload".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Either inline source text, or a reference like \"blob:sha256:...\" \
                     pointing to a pre-stored blob in the BlobStore. When the submission \
                     is a directory bundle, this field is the bundle artifact's blob ref \
                     of the form \"blob:sha256:...:tar.zst\" and `bundle_manifest_json` \
                     is populated."
                        .into(),
                ),
            },
            FieldDef {
                name: "bundle_manifest_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Optional JSON-encoded `manuscript-bundle-manifest@1.0.0` describing \
                     the bundle's main source, source format, per-file roles, and compile \
                     spec. Required when `source_payload` is a `.tar.zst` bundle ref. \
                     See `crates/impress-core/src/schemas/manuscript_bundle_manifest.rs`."
                        .into(),
                ),
            },
            FieldDef {
                name: "parent_manuscript_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "If submission_kind != new-manuscript: ItemId of the manuscript this \
                     submission targets."
                        .into(),
                ),
            },
            FieldDef {
                name: "parent_revision_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "If submission_kind == new-revision: ItemId of the predecessor revision."
                        .into(),
                ),
            },
            FieldDef {
                name: "submitter_persona_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Persona ID of the agent that authored this submission (per ADR-0013).".into(),
                ),
            },
            FieldDef {
                name: "origin_conversation_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ItemId of a conversation item, or an opaque path string for a transcript \
                     anchor (until conversation@1.0.0 is defined; per ADR-0011 OQ-1)."
                        .into(),
                ),
            },
            FieldDef {
                name: "metadata_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Free-form JSON sidecar with submitter-provided structure (e.g. expected \
                     authors, intended journal, reviewer hints)."
                        .into(),
                ),
            },
            FieldDef {
                name: "bibliography_payload".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Optional .bib content if the submitter has a bibliography to attach.".into(),
                ),
            },
            FieldDef {
                name: "similarity_hint".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Submitter's belief about which manuscript this resembles (advisory only; \
                     Scout cross-checks)."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![EdgeType::DependsOn, EdgeType::OperatesOn],
        // manuscript-submission inherits from task@1.0.0 (state machine, assigned_to, etc.)
        inherits: Some("task".into()),
    }
}

/// Register the `manuscript-submission@1.0.0` schema.
///
/// Must be called AFTER `register_task_schemas()` because of the inheritance
/// link to `task`.
pub fn register_manuscript_submission_schema(registry: &mut SchemaRegistry) {
    registry
        .register(manuscript_submission_schema())
        .expect("manuscript-submission schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schemas::task::register_task_schemas;

    #[test]
    fn manuscript_submission_registers_after_task() {
        let mut reg = SchemaRegistry::new();
        register_task_schemas(&mut reg);
        register_manuscript_submission_schema(&mut reg);
        assert!(reg.get("manuscript-submission").is_some());
    }

    #[test]
    fn manuscript_submission_inherits_task() {
        let s = manuscript_submission_schema();
        assert_eq!(s.inherits, Some("task".into()));
    }

    #[test]
    fn manuscript_submission_required_fields() {
        let s = manuscript_submission_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        for f in &["submission_kind", "title", "source_format", "source_payload"] {
            assert!(required.contains(f), "missing required field: {f}");
        }
    }

    #[test]
    fn manuscript_submission_has_optional_bundle_manifest_field() {
        let s = manuscript_submission_schema();
        let f = s
            .fields
            .iter()
            .find(|f| f.name == "bundle_manifest_json")
            .expect("bundle_manifest_json field missing");
        assert!(!f.required, "bundle_manifest_json must be optional");
        assert!(matches!(f.field_type, FieldType::String));
    }
}
