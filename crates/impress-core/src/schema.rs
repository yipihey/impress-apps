use serde::{Deserialize, Serialize};

use crate::reference::EdgeType;

/// Reference to a registered schema (e.g., "bibliography-entry", "chat-message").
pub type SchemaRef = String;

/// A field definition within a schema.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FieldDef {
    pub name: String,
    pub field_type: FieldType,
    pub required: bool,
    pub description: Option<String>,
}

/// Supported field types for schema definitions.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum FieldType {
    String,
    Int,
    Float,
    Bool,
    DateTime,
    StringArray,
    Object,
}

/// Schema definition — describes what fields an item type has.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Schema {
    pub id: SchemaRef,
    pub name: String,
    pub version: String,
    pub fields: Vec<FieldDef>,
    pub expected_edges: Vec<EdgeType>,
    pub inherits: Option<SchemaRef>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_serde_round_trip() {
        let schema = Schema {
            id: "bibliography-entry".into(),
            name: "Bibliography Entry".into(),
            version: "1.0.0".into(),
            fields: vec![
                FieldDef {
                    name: "title".into(),
                    field_type: FieldType::String,
                    required: true,
                    description: Some("The title of the publication".into()),
                },
                FieldDef {
                    name: "citation_count".into(),
                    field_type: FieldType::Int,
                    required: false,
                    description: None,
                },
                FieldDef {
                    name: "authors".into(),
                    field_type: FieldType::StringArray,
                    required: true,
                    description: None,
                },
            ],
            expected_edges: vec![EdgeType::Cites, EdgeType::Attaches],
            inherits: None,
        };
        let json = serde_json::to_string_pretty(&schema).unwrap();
        let back: Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(schema, back);
    }

    #[test]
    fn schema_with_inheritance() {
        let base = Schema {
            id: "research-item".into(),
            name: "Research Item".into(),
            version: "1.0.0".into(),
            fields: vec![FieldDef {
                name: "abstract".into(),
                field_type: FieldType::String,
                required: false,
                description: None,
            }],
            expected_edges: vec![],
            inherits: None,
        };
        let child = Schema {
            id: "preprint".into(),
            name: "Preprint".into(),
            version: "1.0.0".into(),
            fields: vec![FieldDef {
                name: "arxiv_id".into(),
                field_type: FieldType::String,
                required: true,
                description: None,
            }],
            expected_edges: vec![EdgeType::Supersedes],
            inherits: Some(base.id.clone()),
        };
        let json = serde_json::to_string(&child).unwrap();
        let back: Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(child, back);
        assert_eq!(back.inherits, Some("research-item".into()));
    }
}
