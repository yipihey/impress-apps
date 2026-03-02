use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for imprint manuscript sections.
///
/// A manuscript section represents a named, ordered block of Typst content
/// within a document (e.g. Introduction, Methods, Results).  Each section is
/// stored as a `manuscript-section@1.0.0` item in the shared impress-core
/// SQLite store so that agents and sibling apps can query and cross-reference
/// document content without parsing `.imprint` packages directly.
///
/// Large bodies (> 64 KiB) should be stored content-addressed at
/// `~/.local/share/impress/content/{sha256}/` with the hash in
/// `content_hash` and an empty `body`.
pub fn manuscript_section_schema() -> Schema {
    Schema {
        id: "manuscript-section".into(),
        name: "Manuscript Section".into(),
        version: "1.0.0".into(),
        fields: vec![
            // --- required ---
            FieldDef {
                name: "title".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Section heading text".into()),
            },
            // --- optional ---
            FieldDef {
                name: "body".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Full Typst source body of the section. \
                     Empty when content is stored content-addressed (see content_hash)."
                        .into(),
                ),
            },
            FieldDef {
                name: "section_type".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Semantic type of the section: abstract, introduction, methods, \
                     results, discussion, conclusion, references, appendix, custom."
                        .into(),
                ),
            },
            FieldDef {
                name: "order_index".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some(
                    "Zero-based position of this section within its document.".into(),
                ),
            },
            FieldDef {
                name: "word_count".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some(
                    "Approximate word count of the section body (agent-readable summary)."
                        .into(),
                ),
            },
            FieldDef {
                name: "document_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "UUID string of the parent ImprintDocument that owns this section.".into(),
                ),
            },
            FieldDef {
                name: "content_hash".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "SHA-256 hex digest of the section body when stored content-addressed. \
                     Populated only for bodies larger than 64 KiB."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![
            // The section is part of a document item (Contains is the inverse)
            EdgeType::Custom("is-part-of".into()),
            // A document Contains its sections
            EdgeType::Contains,
        ],
        inherits: None,
    }
}

/// Register the imprint manuscript-section schema into a registry.
pub fn register_imprint_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(manuscript_section_schema())
        .expect("manuscript-section schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_manuscript_section_schema() {
        let mut reg = SchemaRegistry::new();
        register_imprint_schemas(&mut reg);
        let schema = reg.get("manuscript-section");
        assert!(schema.is_some(), "manuscript-section schema should be registered");
        let schema = schema.unwrap();
        assert_eq!(schema.version, "1.0.0");
    }

    #[test]
    fn manuscript_section_has_required_title() {
        let schema = manuscript_section_schema();
        let title_field = schema.fields.iter().find(|f| f.name == "title");
        assert!(title_field.is_some(), "title field should exist");
        assert!(title_field.unwrap().required, "title should be required");
    }

    #[test]
    fn manuscript_section_optional_fields() {
        let schema = manuscript_section_schema();
        let optional_fields = ["body", "section_type", "order_index", "word_count", "document_id", "content_hash"];
        for name in &optional_fields {
            let field = schema.fields.iter().find(|f| f.name == *name);
            assert!(field.is_some(), "field '{}' should exist", name);
            assert!(!field.unwrap().required, "field '{}' should be optional", name);
        }
    }

    #[test]
    fn manuscript_section_has_expected_edges() {
        let schema = manuscript_section_schema();
        assert!(
            schema.expected_edges.contains(&EdgeType::Contains),
            "should expect Contains edges"
        );
        assert!(
            schema.expected_edges.contains(&EdgeType::Custom("is-part-of".into())),
            "should expect Custom(is-part-of) edges"
        );
    }

    #[test]
    fn manuscript_section_schema_serde_round_trip() {
        let schema = manuscript_section_schema();
        let json = serde_json::to_string_pretty(&schema).unwrap();
        let back: crate::schema::Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(schema, back);
    }
}
