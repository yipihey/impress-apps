use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for bibliography entries (articles, books, preprints, theses, etc.).
pub fn bibliography_entry_schema() -> Schema {
    Schema {
        id: "bibliography-entry".into(),
        name: "Bibliography Entry".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("cite_key"),
            required_string("entry_type"),
            required_string("title"),
            field("authors", FieldType::StringArray, false),
            optional_string("abstract"),
            optional_string("keywords"),
            field("year", FieldType::Int, false),
            optional_string("doi"),
            optional_string("arxiv_id"),
            optional_string("url"),
            optional_string("journal"),
            optional_string("venue"),
            optional_string("bibcode"),
        ],
        expected_edges: vec![EdgeType::Cites, EdgeType::Attaches],
        inherits: None,
    }
}

/// Register all bibliography schemas into the registry.
pub fn register_bibliography_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(bibliography_entry_schema())
        .expect("bibliography-entry schema registration");
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
    fn bibliography_entry_schema_registers() {
        let mut reg = SchemaRegistry::new();
        register_bibliography_schemas(&mut reg);
        assert!(reg.get("bibliography-entry").is_some());
    }

    #[test]
    fn bibliography_entry_has_required_fields() {
        let schema = bibliography_entry_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"cite_key"), "missing required cite_key");
        assert!(required.contains(&"entry_type"), "missing required entry_type");
        assert!(required.contains(&"title"), "missing required title");
    }

    #[test]
    fn bibliography_entry_has_expected_edges() {
        let schema = bibliography_entry_schema();
        assert!(schema.expected_edges.contains(&EdgeType::Cites));
        assert!(schema.expected_edges.contains(&EdgeType::Attaches));
    }
}
