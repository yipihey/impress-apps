use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for the `manuscript-collection@1.0.0` item type.
///
/// A manuscript collection is a user-curated grouping of manuscripts in the
/// imprint library — analogous to imbib's `collection` items. Collections
/// nest via `parent_collection_ref` to form a tree; smart collections carry
/// a serialised filter (`smart_filter_json`) that the library evaluates at
/// read time.
///
/// Collections emit `Contains` edges to both manuscripts and child
/// collections. A workspace is just a top-level collection with no parent.
pub fn manuscript_collection_schema() -> Schema {
    Schema {
        id: "manuscript-collection".into(),
        name: "Manuscript Collection".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "name".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Display name shown in the sidebar.".into()),
            },
            FieldDef {
                name: "parent_collection_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ItemId (UUID string) of the parent collection. Null/absent for \
                     top-level collections (workspaces)."
                        .into(),
                ),
            },
            FieldDef {
                name: "sort_order".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some(
                    "Position among siblings sharing the same parent. Lower sorts first."
                        .into(),
                ),
            },
            FieldDef {
                name: "is_smart".into(),
                field_type: FieldType::Bool,
                required: false,
                description: Some(
                    "True for saved-search collections whose membership is computed \
                     from `smart_filter_json` rather than explicit `Contains` edges."
                        .into(),
                ),
            },
            FieldDef {
                name: "smart_filter_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "JSON-encoded query for smart collections. Schema is owned by the \
                     library UI; engine-agnostic. Ignored when `is_smart` is false/absent."
                        .into(),
                ),
            },
            FieldDef {
                name: "is_workspace".into(),
                field_type: FieldType::Bool,
                required: false,
                description: Some(
                    "Marks a top-level collection that organises everything under it. \
                     Workspaces always have `parent_collection_ref` null."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![EdgeType::Contains],
        inherits: None,
    }
}

/// Register the `manuscript-collection@1.0.0` schema.
pub fn register_manuscript_collection_schema(registry: &mut SchemaRegistry) {
    registry
        .register(manuscript_collection_schema())
        .expect("manuscript-collection schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manuscript_collection_schema_registers() {
        let mut reg = SchemaRegistry::new();
        register_manuscript_collection_schema(&mut reg);
        assert!(reg.get("manuscript-collection").is_some());
    }

    #[test]
    fn manuscript_collection_required_fields() {
        let s = manuscript_collection_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(required, vec!["name"]);
    }

    #[test]
    fn manuscript_collection_optional_fields() {
        let s = manuscript_collection_schema();
        let optional = [
            "parent_collection_ref",
            "sort_order",
            "is_smart",
            "smart_filter_json",
            "is_workspace",
        ];
        for name in &optional {
            let field = s.fields.iter().find(|f| f.name == *name);
            assert!(field.is_some(), "field '{}' should exist", name);
            assert!(!field.unwrap().required, "field '{}' should be optional", name);
        }
    }

    #[test]
    fn manuscript_collection_expects_contains_edges() {
        let s = manuscript_collection_schema();
        assert!(s.expected_edges.contains(&EdgeType::Contains));
    }

    #[test]
    fn manuscript_collection_serde_round_trip() {
        let s = manuscript_collection_schema();
        let json = serde_json::to_string_pretty(&s).unwrap();
        let back: Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }
}
