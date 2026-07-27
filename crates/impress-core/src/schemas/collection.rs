use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema id of the generic collection. Items are stored with this bare
/// `schema_ref` (the registry is keyed by id; the version lives on the
/// `Schema` — same convention as `manuscript-collection`).
pub const COLLECTION_SCHEMA: &str = "collection";

/// `kind_scope` value for a collection that accepts every record kind.
pub const KIND_SCOPE_ANY: &str = "any";

/// Schema for the `collection@1.0.0` item type (ADR-0022 D1).
///
/// The one generic collection: a user-curated grouping of *any* record kind.
/// `kind_scope` names the record kind a collection organises
/// (`"publication"`, `"manuscript"`, `"figure"`, `"message"`, `"task"`, …) or
/// `"any"` for the mixed-kind collections the impress app is built around.
///
/// Collections nest through payload `parent_id` — never through the envelope
/// `item.parent`, which is the owning library/account (the c902a22f
/// postmortem invariant; see `apps/imbib/CLAUDE.md`). Membership is uniformly
/// a `Contains` edge from the collection to the member.
///
/// `is_smart` is schema'd but inert: the predicate language for saved-search
/// collections is deferred to a future ADR.
pub fn collection_schema() -> Schema {
    Schema {
        id: COLLECTION_SCHEMA.into(),
        name: "Collection".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "name".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Display name shown in the sidebar.".into()),
            },
            FieldDef {
                name: "kind_scope".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Record-kind identifier this collection organises \
                     (\"publication\", \"manuscript\", \"figure\", \"message\", \
                     \"task\", …), or \"any\" for a mixed-kind collection. \
                     Absent is read as \"any\"."
                        .into(),
                ),
            },
            FieldDef {
                name: "parent_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ItemId (lowercase UUID string) of the parent collection. \
                     Null/absent for a root collection. This — NOT the envelope \
                     `item.parent`, which is the owning library — is the tree edge."
                        .into(),
                ),
            },
            FieldDef {
                name: "sort_order".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some(
                    "Position among siblings sharing the same parent. Lower sorts first.".into(),
                ),
            },
            FieldDef {
                name: "is_smart".into(),
                field_type: FieldType::Bool,
                required: false,
                description: Some(
                    "Reserved for saved-search collections. Inert: no predicate \
                     language exists yet, so membership is always the explicit \
                     `Contains` edge set."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![EdgeType::Contains],
        inherits: None,
    }
}

/// Register the `collection@1.0.0` schema.
pub fn register_collection_schema(registry: &mut SchemaRegistry) {
    registry
        .register(collection_schema())
        .expect("collection schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collection_schema_registers() {
        let mut reg = SchemaRegistry::new();
        register_collection_schema(&mut reg);
        assert!(reg.get("collection").is_some());
    }

    #[test]
    fn collection_required_fields() {
        let s = collection_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(required, vec!["name"]);
    }

    #[test]
    fn collection_optional_fields() {
        let s = collection_schema();
        for name in ["kind_scope", "parent_id", "sort_order", "is_smart"] {
            let field = s.fields.iter().find(|f| f.name == name);
            assert!(field.is_some(), "field '{}' should exist", name);
            assert!(
                !field.unwrap().required,
                "field '{}' should be optional",
                name
            );
        }
    }

    #[test]
    fn collection_tree_field_is_payload_parent_id() {
        let s = collection_schema();
        let parent = s
            .fields
            .iter()
            .find(|f| f.name == "parent_id")
            .expect("parent_id field");
        assert_eq!(parent.field_type, FieldType::String);
        assert!(
            !s.fields.iter().any(|f| f.name == "parent"),
            "the tree edge is payload parent_id, never the envelope parent"
        );
    }

    #[test]
    fn collection_expects_contains_edges() {
        let s = collection_schema();
        assert!(s.expected_edges.contains(&EdgeType::Contains));
    }

    #[test]
    fn collection_serde_round_trip() {
        let s = collection_schema();
        let json = serde_json::to_string_pretty(&s).unwrap();
        let back: Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }
}
