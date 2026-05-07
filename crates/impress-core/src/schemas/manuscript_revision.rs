use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for the `manuscript-revision@1.0.0` item type.
///
/// A manuscript-revision is an immutable snapshot of a manuscript at a point
/// in time. It carries a content-addressed source archive and compiled PDF.
/// Revisions are linear: each points to its predecessor via `Supersedes`.
/// Editing a revision is not permitted — a new revision is created instead.
///
/// Immutability is enforced at the store boundary: payload-mutating
/// operations (`SetPayload`, `RemovePayload`, `PatchPayload`) on items with
/// `schema = "manuscript-revision"` are rejected by `apply_operation()`
/// in `crates/impress-core/src/sqlite_store.rs`. Envelope-level operations
/// (tag, flag, read-status) remain permitted.
///
/// See `docs/ADR-0011-impress-journal.md` D2 for full semantics.
pub fn manuscript_revision_schema() -> Schema {
    Schema {
        id: "manuscript-revision".into(),
        name: "Manuscript Revision".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "parent_manuscript_ref".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "ItemId of the manuscript this revision belongs to.".into(),
                ),
            },
            FieldDef {
                name: "revision_tag".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "User-meaningful tag, e.g. \"v1\", \"submitted\", \"referee-response-1\"."
                        .into(),
                ),
            },
            FieldDef {
                name: "content_hash".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "SHA-256 hex digest of the source archive bytes; the addressing key."
                        .into(),
                ),
            },
            FieldDef {
                name: "pdf_artifact_ref".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "ItemId of the artifact item carrying the compiled PDF (per the artifact \
                     schemas in schemas/artifact.rs)."
                        .into(),
                ),
            },
            FieldDef {
                name: "source_archive_ref".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "ItemId of the artifact item carrying the .tar.zst source snapshot. \
                     For Phase-7-era single-file submissions the value is a `blob:sha256:...` \
                     ref to the inline source text; from Phase 8 onwards it is the artifact \
                     ItemId of the directory bundle (and `bundle_manifest_json` is set)."
                        .into(),
                ),
            },
            FieldDef {
                name: "bundle_manifest_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Optional JSON-encoded `manuscript-bundle-manifest@1.0.0` mirroring \
                     the manifest from the bundle root, so the UI/exporters can list a \
                     manuscript's files without unpacking the archive. Populated when the \
                     manuscript is stored as a directory bundle. \
                     See `crates/impress-core/src/schemas/manuscript_bundle_manifest.rs`."
                        .into(),
                ),
            },
            FieldDef {
                name: "predecessor_revision_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ItemId of the prior revision; null for the first revision of a manuscript."
                        .into(),
                ),
            },
            FieldDef {
                name: "compile_log_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ItemId of the artifact item carrying the compile log, if any.".into(),
                ),
            },
            FieldDef {
                name: "snapshot_reason".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Why this revision was created: status-change | user-tag | stable-churn | \
                     manual."
                        .into(),
                ),
            },
            FieldDef {
                name: "abstract".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Extracted abstract text for FTS and preview displays.".into(),
                ),
            },
            FieldDef {
                name: "word_count".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some("Approximate word count of the revision source.".into()),
            },
        ],
        expected_edges: vec![
            EdgeType::IsPartOf,
            EdgeType::Supersedes,
            EdgeType::Attaches,
            EdgeType::Cites,
            EdgeType::Visualizes,
            EdgeType::DerivedFrom,
        ],
        inherits: None,
    }
}

/// Register the `manuscript-revision@1.0.0` schema.
pub fn register_manuscript_revision_schema(registry: &mut SchemaRegistry) {
    registry
        .register(manuscript_revision_schema())
        .expect("manuscript-revision schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manuscript_revision_schema_registers() {
        let mut reg = SchemaRegistry::new();
        register_manuscript_revision_schema(&mut reg);
        assert!(reg.get("manuscript-revision").is_some());
    }

    #[test]
    fn manuscript_revision_required_fields() {
        let s = manuscript_revision_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        for f in &[
            "parent_manuscript_ref",
            "revision_tag",
            "content_hash",
            "pdf_artifact_ref",
            "source_archive_ref",
        ] {
            assert!(required.contains(f), "missing required field: {f}");
        }
    }

    #[test]
    fn manuscript_revision_expected_edges() {
        let s = manuscript_revision_schema();
        assert!(s.expected_edges.contains(&EdgeType::IsPartOf));
        assert!(s.expected_edges.contains(&EdgeType::Supersedes));
        assert!(s.expected_edges.contains(&EdgeType::Attaches));
    }

    #[test]
    fn manuscript_revision_has_optional_bundle_manifest_field() {
        let s = manuscript_revision_schema();
        let f = s
            .fields
            .iter()
            .find(|f| f.name == "bundle_manifest_json")
            .expect("bundle_manifest_json field missing");
        assert!(!f.required, "bundle_manifest_json must be optional");
        assert!(matches!(f.field_type, FieldType::String));
    }
}
