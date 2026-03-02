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

/// Schema for manuscript sections — sections of a Typst document being authored in imprint.
pub fn manuscript_section_schema() -> Schema {
    Schema {
        id: "manuscript-section".into(),
        name: "Manuscript Section".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("title"),
            required_string("body"),
            required_string("section_type"),
            field("word_count", FieldType::Int, false),
            optional_string("version"),
        ],
        expected_edges: vec![
            EdgeType::Contains,
            EdgeType::Cites,
            EdgeType::Visualizes,
            EdgeType::Custom("is-part-of".into()),
        ],
        inherits: None,
    }
}

/// Schema for figures — visualizations or images produced by implore or referenced in manuscripts.
pub fn figure_schema() -> Schema {
    Schema {
        id: "figure".into(),
        name: "Figure".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("title"),
            required_string("format"),
            optional_string("caption"),
            optional_string("data_hash"),
            optional_string("script_hash"),
            field("width", FieldType::Int, false),
            field("height", FieldType::Int, false),
        ],
        expected_edges: vec![EdgeType::Visualizes, EdgeType::Attaches, EdgeType::DerivedFrom],
        inherits: None,
    }
}

/// Schema for datasets — metadata for tabular or structured data used in analysis.
pub fn dataset_schema() -> Schema {
    Schema {
        id: "dataset".into(),
        name: "Dataset".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("name"),
            required_string("format"),
            field("row_count", FieldType::Int, false),
            field("column_count", FieldType::Int, false),
            optional_string("data_hash"),
            optional_string("description"),
            optional_string("schema_json"),
        ],
        expected_edges: vec![EdgeType::Attaches],
        inherits: None,
    }
}

/// Register all document-related schemas into the registry.
pub fn register_document_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(annotation_schema())
        .expect("annotation schema registration");
    registry
        .register(manuscript_section_schema())
        .expect("manuscript-section schema registration");
    registry
        .register(figure_schema())
        .expect("figure schema registration");
    registry
        .register(dataset_schema())
        .expect("dataset schema registration");
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
        assert!(reg.get("manuscript-section").is_some());
        assert!(reg.get("figure").is_some());
        assert!(reg.get("dataset").is_some());
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

    #[test]
    fn manuscript_section_required_fields() {
        let schema = manuscript_section_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"title"), "missing required title");
        assert!(required.contains(&"body"), "missing required body");
        assert!(required.contains(&"section_type"), "missing required section_type");
    }

    #[test]
    fn figure_schema_required_fields() {
        let schema = figure_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"title"), "missing required title");
        assert!(required.contains(&"format"), "missing required format");
    }

    #[test]
    fn dataset_schema_required_fields() {
        let schema = dataset_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"name"), "missing required name");
        assert!(required.contains(&"format"), "missing required format");
    }
}
