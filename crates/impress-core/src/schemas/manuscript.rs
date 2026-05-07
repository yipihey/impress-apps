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
}
