//! Schemas for domain-neutral citations and extraction products.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

pub const SOURCE_CITATION_SCHEMA: &str = "source-citation@1.0.0";
pub const EXTRACTION_RUN_SCHEMA: &str = "extraction-run@1.0.0";
pub const CONTENT_CHUNK_SCHEMA: &str = "content-chunk@1.0.0";

fn field(name: &str, field_type: FieldType, required: bool, description: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type,
        required,
        description: Some(description.into()),
    }
}

pub fn source_citation_schema() -> Schema {
    Schema {
        id: SOURCE_CITATION_SCHEMA.into(),
        name: "Source Citation".into(),
        version: "1.0.0".into(),
        fields: vec![
            field(
                "source_item_id",
                FieldType::String,
                true,
                "Cited source item UUID.",
            ),
            field(
                "source_content_hash",
                FieldType::String,
                true,
                "SHA-256 of cited source bytes.",
            ),
            field(
                "extraction_run_id",
                FieldType::String,
                false,
                "Extraction run used to locate derived text.",
            ),
            field(
                "locator",
                FieldType::Object,
                true,
                "Structured page, region, range, section, figure, or table locator.",
            ),
            field(
                "quote",
                FieldType::String,
                false,
                "Bounded supporting excerpt.",
            ),
            field(
                "quote_hash",
                FieldType::String,
                false,
                "SHA-256 of the normalized excerpt.",
            ),
            field(
                "title",
                FieldType::String,
                false,
                "Display title for the source.",
            ),
        ],
        expected_edges: vec![EdgeType::References, EdgeType::DerivedFrom],
        inherits: None,
    }
}

pub fn extraction_run_schema() -> Schema {
    Schema {
        id: EXTRACTION_RUN_SCHEMA.into(),
        name: "Extraction Run".into(),
        version: "1.0.0".into(),
        fields: vec![
            field(
                "source_item_id",
                FieldType::String,
                true,
                "Input source item UUID.",
            ),
            field(
                "source_content_hash",
                FieldType::String,
                true,
                "SHA-256 of input bytes.",
            ),
            field(
                "extractor",
                FieldType::String,
                true,
                "Extractor or OCR engine identifier.",
            ),
            field(
                "extractor_version",
                FieldType::String,
                true,
                "Extractor version.",
            ),
            field(
                "profile",
                FieldType::String,
                true,
                "Extraction profile and relevant settings identity.",
            ),
            field(
                "started_at",
                FieldType::String,
                true,
                "RFC3339 start timestamp.",
            ),
            field(
                "completed_at",
                FieldType::String,
                false,
                "RFC3339 completion timestamp.",
            ),
            field(
                "output_content_hash",
                FieldType::String,
                false,
                "SHA-256 of canonical extraction output.",
            ),
            field(
                "warnings",
                FieldType::StringArray,
                false,
                "Non-fatal extraction warnings.",
            ),
            field(
                "produced_item_ids",
                FieldType::StringArray,
                false,
                "Items derived by this run.",
            ),
        ],
        expected_edges: vec![EdgeType::DerivedFrom, EdgeType::ProducedBy],
        inherits: None,
    }
}

pub fn content_chunk_schema() -> Schema {
    Schema {
        id: CONTENT_CHUNK_SCHEMA.into(),
        name: "Content Chunk".into(),
        version: "1.0.0".into(),
        fields: vec![
            field(
                "source_item_id",
                FieldType::String,
                true,
                "Source item UUID.",
            ),
            field(
                "extraction_run_id",
                FieldType::String,
                true,
                "Producing extraction run UUID.",
            ),
            field(
                "citation_id",
                FieldType::String,
                false,
                "Page- or region-level citation for this extracted text.",
            ),
            field(
                "ordinal",
                FieldType::Int,
                true,
                "Stable order within the extraction.",
            ),
            field("text", FieldType::String, true, "Derived text."),
            field(
                "content_hash",
                FieldType::String,
                true,
                "SHA-256 of canonical chunk text.",
            ),
            field(
                "locator",
                FieldType::Object,
                true,
                "Location within the immutable source.",
            ),
            field(
                "regions",
                FieldType::Object,
                false,
                "Optional OCR/layout observations with normalized geometry and confidence.",
            ),
        ],
        expected_edges: vec![EdgeType::DerivedFrom, EdgeType::IsPartOf, EdgeType::Cites],
        inherits: None,
    }
}

pub fn register_source_schemas(registry: &mut SchemaRegistry) {
    for schema in [
        source_citation_schema(),
        extraction_run_schema(),
        content_chunk_schema(),
    ] {
        registry
            .register(schema)
            .expect("source schema registration");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_schemas_register_with_canonical_refs() {
        let mut registry = SchemaRegistry::new();
        register_source_schemas(&mut registry);
        for id in [
            SOURCE_CITATION_SCHEMA,
            EXTRACTION_RUN_SCHEMA,
            CONTENT_CHUNK_SCHEMA,
        ] {
            assert!(registry.get(id).is_some(), "missing {id}");
        }
    }

    #[test]
    fn citations_require_structured_locators() {
        let schema = source_citation_schema();
        let locator = schema
            .fields
            .iter()
            .find(|field| field.name == "locator")
            .unwrap();
        assert!(locator.required);
        assert_eq!(locator.field_type, FieldType::Object);
    }
}
