use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for research presentations (talks, slides, lecture recordings).
pub fn presentation_schema() -> Schema {
    Schema {
        id: "impress/artifact/presentation".into(),
        name: "Presentation".into(),
        version: "1.1.0".into(),
        fields: artifact_fields(),
        expected_edges: vec![EdgeType::Attaches, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Schema for conference posters.
pub fn poster_schema() -> Schema {
    Schema {
        id: "impress/artifact/poster".into(),
        name: "Poster".into(),
        version: "1.1.0".into(),
        fields: artifact_fields(),
        expected_edges: vec![EdgeType::Attaches, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Schema for dataset documentation (READMEs, codebooks).
pub fn dataset_schema() -> Schema {
    Schema {
        id: "impress/artifact/dataset".into(),
        name: "Dataset".into(),
        version: "1.1.0".into(),
        fields: artifact_fields(),
        expected_edges: vec![EdgeType::Attaches, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Schema for web pages (blog posts, tutorials, documentation).
pub fn webpage_schema() -> Schema {
    Schema {
        id: "impress/artifact/webpage".into(),
        name: "Web Page".into(),
        version: "1.1.0".into(),
        fields: artifact_fields(),
        expected_edges: vec![EdgeType::Attaches, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Schema for quick research notes and ideas.
pub fn note_schema() -> Schema {
    Schema {
        id: "impress/artifact/note".into(),
        name: "Note".into(),
        version: "1.1.0".into(),
        fields: artifact_fields(),
        expected_edges: vec![EdgeType::Attaches, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Schema for media (whiteboard photos, experiment images, videos).
pub fn media_schema() -> Schema {
    Schema {
        id: "impress/artifact/media".into(),
        name: "Media".into(),
        version: "1.1.0".into(),
        fields: artifact_fields(),
        expected_edges: vec![EdgeType::Attaches, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Schema for code snippets, gists, algorithms.
pub fn code_schema() -> Schema {
    Schema {
        id: "impress/artifact/code".into(),
        name: "Code".into(),
        version: "1.1.0".into(),
        fields: artifact_fields(),
        expected_edges: vec![EdgeType::Attaches, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Schema for general research artifacts (catch-all).
pub fn general_schema() -> Schema {
    Schema {
        id: "impress/artifact/general".into(),
        name: "General Artifact".into(),
        version: "1.1.0".into(),
        fields: artifact_fields(),
        expected_edges: vec![EdgeType::Attaches, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Common fields shared by all artifact schemas.
///
/// 1.1.0 (ADR-0014 D54): additive — five FAIR attribution fields.
fn artifact_fields() -> Vec<FieldDef> {
    vec![
        required_string("title"),
        optional_string("source_url"),
        optional_string("notes"),
        optional_string("artifact_subtype"),
        // File attachment metadata
        optional_string("file_name"),
        optional_string("file_hash"),
        field("file_size", FieldType::Int, false),
        optional_string("file_mime_type"),
        // Provenance
        optional_string("capture_context"),
        optional_string("original_author"),
        optional_string("event_name"),
        optional_string("event_date"),
        // FAIR attribution (ADR-0014 D54)
        optional_string("orcid"),
        optional_string("affiliation"),
        optional_string("funder"),
        optional_string("license"),
        field("embargo_until", FieldType::DateTime, false),
    ]
}

/// Every artifact `schema_ref`, in the sidebar's display order — the ONE
/// list a caller enumerates artifact kinds from (the sidebar snapshot verb
/// counts per entry; hardcoding these eight spellings anywhere else is the
/// schema-refs drift class). Each entry is the id its `*_schema()` below
/// registers; the parity test pins that.
pub const ARTIFACT_SCHEMA_REFS: [&str; 8] = [
    "impress/artifact/general",
    "impress/artifact/code",
    "impress/artifact/dataset",
    "impress/artifact/media",
    "impress/artifact/note",
    "impress/artifact/poster",
    "impress/artifact/presentation",
    "impress/artifact/webpage",
];

/// Register all artifact schemas in a registry.
pub fn register_artifact_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(presentation_schema())
        .expect("artifact/presentation schema registration");
    registry
        .register(poster_schema())
        .expect("artifact/poster schema registration");
    registry
        .register(dataset_schema())
        .expect("artifact/dataset schema registration");
    registry
        .register(webpage_schema())
        .expect("artifact/webpage schema registration");
    registry
        .register(note_schema())
        .expect("artifact/note schema registration");
    registry
        .register(media_schema())
        .expect("artifact/media schema registration");
    registry
        .register(code_schema())
        .expect("artifact/code schema registration");
    registry
        .register(general_schema())
        .expect("artifact/general schema registration");
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

    #[test]
    fn artifact_schema_refs_const_matches_the_registry() {
        let mut reg = SchemaRegistry::new();
        register_artifact_schemas(&mut reg);
        for id in ARTIFACT_SCHEMA_REFS {
            assert!(
                reg.get(id).is_some(),
                "ARTIFACT_SCHEMA_REFS names {id:?}, which register_artifact_schemas does not register"
            );
        }
        assert_eq!(
            ARTIFACT_SCHEMA_REFS.len(),
            reg.list()
                .iter()
                .filter(|s| s.id.starts_with("impress/artifact/"))
                .count(),
            "an artifact schema exists that ARTIFACT_SCHEMA_REFS does not name"
        );
    }

    #[test]
    fn register_all_artifact_schemas() {
        let mut reg = SchemaRegistry::new();
        register_artifact_schemas(&mut reg);

        assert!(reg.get("impress/artifact/presentation").is_some());
        assert!(reg.get("impress/artifact/poster").is_some());
        assert!(reg.get("impress/artifact/dataset").is_some());
        assert!(reg.get("impress/artifact/webpage").is_some());
        assert!(reg.get("impress/artifact/note").is_some());
        assert!(reg.get("impress/artifact/media").is_some());
        assert!(reg.get("impress/artifact/code").is_some());
        assert!(reg.get("impress/artifact/general").is_some());
    }

    #[test]
    fn artifact_schemas_have_required_title() {
        let schemas = vec![
            presentation_schema(),
            poster_schema(),
            dataset_schema(),
            webpage_schema(),
            note_schema(),
            media_schema(),
            code_schema(),
            general_schema(),
        ];
        for schema in &schemas {
            let has_required_title = schema
                .fields
                .iter()
                .any(|f| f.name == "title" && f.required);
            assert!(
                has_required_title,
                "Schema {} missing required title field",
                schema.id
            );
        }
    }

    #[test]
    fn artifact_schemas_have_expected_edges() {
        let schema = presentation_schema();
        assert!(schema.expected_edges.contains(&EdgeType::Attaches));
        assert!(schema.expected_edges.contains(&EdgeType::RelatesTo));
    }
}
