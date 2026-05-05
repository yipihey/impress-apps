use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for citation-usage records linking imprint manuscript sections
/// to the bibliography entries they cite.
///
/// Each record represents "this manuscript section cites this paper" and
/// is upserted by `CitationUsageTracker` in the imprint app whenever a
/// manuscript section is written. Imbib consumes these records to surface
/// a "papers cited in your writing" smart library without needing to know
/// anything about imprint's internals.
///
/// ## Keying
///
/// The canonical id of a citation-usage record is a deterministic hash of
/// `(section_id, cite_key)` so repeated writes of the same section are
/// idempotent. When a citation is removed from the source, the tracker
/// deletes the corresponding record; imbib's sidebar then sees the
/// paper disappear from the cited set on its next snapshot refresh.
///
/// ## Ownership
///
/// - `section_id` — the manuscript section that does the citing
/// - `document_id` — the parent document (duplicated for cheap filters)
/// - `paper_id` — imbib's publication UUID (if known); may be empty when
///   the cite key hasn't been resolved to a publication yet
/// - `cite_key` — the literal cite key as it appears in the source
pub fn citation_usage_schema() -> Schema {
    Schema {
        id: "citation-usage".into(),
        name: "Citation Usage".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "cite_key".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "The literal cite key as it appears in the source \
                     (e.g. `desjacques18`, `abel-banerjee-2024`).".into(),
                ),
            },
            FieldDef {
                name: "section_id".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "UUID of the manuscript-section item that cites this key.".into(),
                ),
            },
            FieldDef {
                name: "document_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "UUID of the parent ImprintDocument. Duplicated from \
                     section for cheap per-document queries.".into(),
                ),
            },
            FieldDef {
                name: "paper_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "UUID of the imbib bibliography-entry item this key \
                     resolves to, when known. Empty when unresolved.".into(),
                ),
            },
            FieldDef {
                name: "first_cited".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ISO8601 timestamp of when this citation was first recorded.".into(),
                ),
            },
            FieldDef {
                name: "last_seen".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ISO8601 timestamp of the most recent tracker refresh \
                     that still observed this citation in the source.".into(),
                ),
            },
        ],
        expected_edges: vec![
            EdgeType::Custom("cites".into()),
            EdgeType::Custom("is-part-of".into()),
        ],
        inherits: None,
    }
}

/// Register the citation-usage schema into a registry.
pub fn register_citation_usage_schema(registry: &mut SchemaRegistry) {
    registry
        .register(citation_usage_schema())
        .expect("citation-usage schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_citation_usage_schema_ok() {
        let mut reg = SchemaRegistry::new();
        register_citation_usage_schema(&mut reg);
        let schema = reg.get("citation-usage");
        assert!(schema.is_some(), "citation-usage schema should be registered");
        assert_eq!(schema.unwrap().version, "1.0.0");
    }

    #[test]
    fn citation_usage_has_required_fields() {
        let schema = citation_usage_schema();
        for name in &["cite_key", "section_id"] {
            let field = schema.fields.iter().find(|f| f.name == *name);
            assert!(field.is_some(), "field '{}' should exist", name);
            assert!(field.unwrap().required, "field '{}' should be required", name);
        }
    }
}
