use crate::reference::EdgeType;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for operation items (the audit trail / CRDT log).
pub fn operation_schema() -> Schema {
    Schema {
        id: "impress/operation".into(),
        name: "Operation".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "target_id".into(),
                field_type: FieldType::String,
                required: true,
                description: None,
            },
            FieldDef {
                name: "op_type".into(),
                field_type: FieldType::String,
                required: true,
                description: None,
            },
            FieldDef {
                name: "op_data".into(),
                field_type: FieldType::Object,
                required: false,
                description: None,
            },
            FieldDef {
                name: "intent".into(),
                field_type: FieldType::String,
                required: false,
                description: None,
            },
            FieldDef {
                name: "reason".into(),
                field_type: FieldType::String,
                required: false,
                description: None,
            },
            FieldDef {
                name: "prev".into(),
                field_type: FieldType::Object,
                required: false,
                description: None,
            },
            FieldDef {
                name: "snapshot".into(),
                field_type: FieldType::Object,
                required: false,
                description: None,
            },
            FieldDef {
                name: "undo_info".into(),
                field_type: FieldType::Object,
                required: false,
                description: None,
            },
        ],
        expected_edges: vec![EdgeType::OperatesOn],
        inherits: None,
    }
}

pub fn register_operation_schema(registry: &mut crate::registry::SchemaRegistry) {
    registry
        .register(operation_schema())
        .expect("impress/operation schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::SchemaRegistry;

    #[test]
    fn operation_schema_registers() {
        let mut reg = SchemaRegistry::new();
        register_operation_schema(&mut reg);
        assert!(reg.get("impress/operation").is_some());
    }

    #[test]
    fn operation_schema_has_required_fields() {
        let schema = operation_schema();
        let required: Vec<_> = schema.fields.iter().filter(|f| f.required).collect();
        assert_eq!(required.len(), 2);
        assert!(required.iter().any(|f| f.name == "target_id"));
        assert!(required.iter().any(|f| f.name == "op_type"));
    }

    #[test]
    fn operation_schema_has_operates_on_edge() {
        let schema = operation_schema();
        assert!(schema.expected_edges.contains(&EdgeType::OperatesOn));
    }
}
