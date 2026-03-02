use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for annotations — highlights or anchored notes on readable items.
pub fn annotation_schema() -> Schema {
    Schema {
        id: "annotation".into(),
        name: "Annotation".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("text"),
            field("selection_start", FieldType::Int, true),
            field("selection_end", FieldType::Int, true),
            field("page", FieldType::Int, false),
            optional_string("quote"),
            optional_string("color"),
        ],
        expected_edges: vec![EdgeType::Annotates],
        inherits: None,
    }
}

/// Register all document-related schemas into the registry.
///
/// Note: figure/dataset schemas are in `implore.rs`; manuscript-section is in `manuscript_section.rs`.
pub fn register_document_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(annotation_schema())
        .expect("annotation schema registration");
}

fn required_string(name: &str) -> FieldDef {
    FieldDef { name: name.into(), field_type: FieldType::String, required: true, description: None }
}

fn optional_string(name: &str) -> FieldDef {
    FieldDef { name: name.into(), field_type: FieldType::String, required: false, description: None }
}

fn field(name: &str, field_type: FieldType, required: bool) -> FieldDef {
    FieldDef { name: name.into(), field_type, required, description: None }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn document_schemas_register() {
        let mut reg = SchemaRegistry::new();
        register_document_schemas(&mut reg);
        assert!(reg.get("annotation").is_some());
    }

    #[test]
    fn annotation_schema_required_fields() {
        let schema = annotation_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"text"), "missing required text");
        assert!(required.contains(&"selection_start"), "missing required selection_start");
        assert!(required.contains(&"selection_end"), "missing required selection_end");
    }

    #[test]
    fn annotation_schema_has_annotates_edge() {
        let schema = annotation_schema();
        assert!(schema.expected_edges.contains(&EdgeType::Annotates));
    }

}
