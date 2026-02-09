use std::collections::HashMap;

use crate::item::{Item, Value};
use crate::schema::{FieldType, Schema, SchemaRef};

/// Error from the schema registry.
#[derive(Debug, thiserror::Error)]
pub enum RegistryError {
    #[error("Schema already registered: {0}")]
    AlreadyRegistered(SchemaRef),

    #[error("Schema not found: {0}")]
    NotFound(SchemaRef),

    #[error("Duplicate field name '{field}' in schema '{schema}'")]
    DuplicateField { schema: SchemaRef, field: String },
}

/// Validation error for an item against its schema.
#[derive(Debug, Clone, PartialEq)]
pub struct ValidationError {
    pub field: String,
    pub message: String,
}

impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "field '{}': {}", self.field, self.message)
    }
}

/// Registry of schemas. Used to validate items against their declared schema.
pub struct SchemaRegistry {
    schemas: HashMap<SchemaRef, Schema>,
}

impl SchemaRegistry {
    pub fn new() -> Self {
        Self {
            schemas: HashMap::new(),
        }
    }

    /// Register a new schema. Returns error if a schema with the same ID already exists.
    pub fn register(&mut self, schema: Schema) -> Result<(), RegistryError> {
        if self.schemas.contains_key(&schema.id) {
            return Err(RegistryError::AlreadyRegistered(schema.id.clone()));
        }
        // Check for duplicate field names within the schema
        let mut seen = std::collections::HashSet::new();
        for field in &schema.fields {
            if !seen.insert(&field.name) {
                return Err(RegistryError::DuplicateField {
                    schema: schema.id.clone(),
                    field: field.name.clone(),
                });
            }
        }
        self.schemas.insert(schema.id.clone(), schema);
        Ok(())
    }

    /// Get a schema by ID.
    pub fn get(&self, id: &str) -> Option<&Schema> {
        self.schemas.get(id)
    }

    /// Validate an item against its declared schema.
    /// Returns Ok(()) if valid, or a list of validation errors.
    pub fn validate(&self, item: &Item) -> Result<(), Vec<ValidationError>> {
        let schema = match self.schemas.get(&item.schema) {
            Some(s) => s,
            None => {
                return Err(vec![ValidationError {
                    field: "schema".into(),
                    message: format!("unknown schema: '{}'", item.schema),
                }]);
            }
        };

        // Collect all fields including inherited ones
        let all_fields = self.collect_fields(schema);
        let mut errors = Vec::new();

        for field_def in &all_fields {
            match item.payload.get(&field_def.name) {
                None => {
                    if field_def.required {
                        errors.push(ValidationError {
                            field: field_def.name.clone(),
                            message: "required field missing".into(),
                        });
                    }
                }
                Some(value) => {
                    if !matches!(value, Value::Null) && !type_matches(&field_def.field_type, value) {
                        errors.push(ValidationError {
                            field: field_def.name.clone(),
                            message: format!(
                                "expected {:?}, got {}",
                                field_def.field_type,
                                value_type_name(value)
                            ),
                        });
                    }
                }
            }
        }

        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors)
        }
    }

    /// List all registered schemas.
    pub fn list(&self) -> Vec<&Schema> {
        self.schemas.values().collect()
    }

    /// Collect all field definitions for a schema, including inherited fields.
    fn collect_fields(&self, schema: &Schema) -> Vec<crate::schema::FieldDef> {
        let mut fields = Vec::new();

        // Add inherited fields first
        if let Some(ref parent_id) = schema.inherits {
            if let Some(parent) = self.schemas.get(parent_id) {
                fields.extend(self.collect_fields(parent));
            }
        }

        // Add own fields (overriding inherited ones with same name)
        for field in &schema.fields {
            if let Some(pos) = fields.iter().position(|f| f.name == field.name) {
                fields[pos] = field.clone();
            } else {
                fields.push(field.clone());
            }
        }

        fields
    }
}

impl Default for SchemaRegistry {
    fn default() -> Self {
        Self::new()
    }
}

/// Check if a Value matches the expected FieldType.
fn type_matches(expected: &FieldType, value: &Value) -> bool {
    match (expected, value) {
        (FieldType::String, Value::String(_)) => true,
        (FieldType::Int, Value::Int(_)) => true,
        (FieldType::Float, Value::Float(_)) => true,
        (FieldType::Float, Value::Int(_)) => true, // Allow int where float expected
        (FieldType::Bool, Value::Bool(_)) => true,
        (FieldType::DateTime, Value::String(_)) => true, // DateTime stored as ISO string
        (FieldType::DateTime, Value::Int(_)) => true,    // or as unix timestamp
        (FieldType::StringArray, Value::Array(_)) => true,
        (FieldType::Object, Value::Object(_)) => true,
        _ => false,
    }
}

/// Human-readable name for a Value variant.
fn value_type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Int(_) => "int",
        Value::Float(_) => "float",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::item::{ActorKind, Item, Value};
    use crate::reference::EdgeType;
    use crate::schema::{FieldDef, FieldType, Schema};
    use chrono::Utc;
    use std::collections::BTreeMap;
    use uuid::Uuid;

    fn bib_schema() -> Schema {
        Schema {
            id: "bibliography-entry".into(),
            name: "Bibliography Entry".into(),
            version: "1.0.0".into(),
            fields: vec![
                FieldDef {
                    name: "cite_key".into(),
                    field_type: FieldType::String,
                    required: true,
                    description: None,
                },
                FieldDef {
                    name: "entry_type".into(),
                    field_type: FieldType::String,
                    required: true,
                    description: None,
                },
                FieldDef {
                    name: "title".into(),
                    field_type: FieldType::String,
                    required: false,
                    description: None,
                },
                FieldDef {
                    name: "year".into(),
                    field_type: FieldType::Int,
                    required: false,
                    description: None,
                },
                FieldDef {
                    name: "citation_count".into(),
                    field_type: FieldType::Int,
                    required: false,
                    description: None,
                },
            ],
            expected_edges: vec![EdgeType::Cites],
            inherits: None,
        }
    }

    fn make_valid_item() -> Item {
        let mut payload = BTreeMap::new();
        payload.insert("cite_key".into(), Value::String("smith2024".into()));
        payload.insert("entry_type".into(), Value::String("article".into()));
        payload.insert("title".into(), Value::String("A Paper".into()));
        payload.insert("year".into(), Value::Int(2024));
        Item {
            id: Uuid::new_v4(),
            schema: "bibliography-entry".into(),
            payload,
            created: Utc::now(),
            author: "user".into(),
            author_kind: ActorKind::Human,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: crate::item::Priority::Normal,
            visibility: crate::item::Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        }
    }

    #[test]
    fn register_and_get() {
        let mut reg = SchemaRegistry::new();
        reg.register(bib_schema()).unwrap();
        assert!(reg.get("bibliography-entry").is_some());
        assert!(reg.get("nonexistent").is_none());
    }

    #[test]
    fn register_duplicate_fails() {
        let mut reg = SchemaRegistry::new();
        reg.register(bib_schema()).unwrap();
        let err = reg.register(bib_schema()).unwrap_err();
        assert!(matches!(err, RegistryError::AlreadyRegistered(_)));
    }

    #[test]
    fn validate_conforming_item() {
        let mut reg = SchemaRegistry::new();
        reg.register(bib_schema()).unwrap();
        let item = make_valid_item();
        assert!(reg.validate(&item).is_ok());
    }

    #[test]
    fn validate_missing_required_field() {
        let mut reg = SchemaRegistry::new();
        reg.register(bib_schema()).unwrap();
        let mut item = make_valid_item();
        item.payload.remove("cite_key");
        let errs = reg.validate(&item).unwrap_err();
        assert_eq!(errs.len(), 1);
        assert_eq!(errs[0].field, "cite_key");
        assert!(errs[0].message.contains("required"));
    }

    #[test]
    fn validate_wrong_field_type() {
        let mut reg = SchemaRegistry::new();
        reg.register(bib_schema()).unwrap();
        let mut item = make_valid_item();
        // year should be Int, not String
        item.payload
            .insert("year".into(), Value::String("not a number".into()));
        let errs = reg.validate(&item).unwrap_err();
        assert_eq!(errs.len(), 1);
        assert_eq!(errs[0].field, "year");
        assert!(errs[0].message.contains("expected"));
    }

    #[test]
    fn validate_unknown_schema() {
        let reg = SchemaRegistry::new(); // empty registry
        let item = make_valid_item();
        let errs = reg.validate(&item).unwrap_err();
        assert_eq!(errs.len(), 1);
        assert_eq!(errs[0].field, "schema");
        assert!(errs[0].message.contains("unknown"));
    }

    #[test]
    fn validate_optional_fields_can_be_missing() {
        let mut reg = SchemaRegistry::new();
        reg.register(bib_schema()).unwrap();
        let mut item = make_valid_item();
        item.payload.remove("title");
        item.payload.remove("year");
        item.payload.remove("citation_count");
        assert!(reg.validate(&item).is_ok());
    }

    #[test]
    fn validate_null_value_for_optional() {
        let mut reg = SchemaRegistry::new();
        reg.register(bib_schema()).unwrap();
        let mut item = make_valid_item();
        item.payload.insert("year".into(), Value::Null);
        assert!(reg.validate(&item).is_ok());
    }

    #[test]
    fn validate_with_inheritance() {
        let mut reg = SchemaRegistry::new();

        let base = Schema {
            id: "research-item".into(),
            name: "Research Item".into(),
            version: "1.0.0".into(),
            fields: vec![FieldDef {
                name: "abstract_text".into(),
                field_type: FieldType::String,
                required: true,
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
            expected_edges: vec![],
            inherits: Some("research-item".into()),
        };

        reg.register(base).unwrap();
        reg.register(child).unwrap();

        // Item missing both abstract_text and arxiv_id
        let mut item = Item {
            id: Uuid::new_v4(),
            schema: "preprint".into(),
            payload: BTreeMap::new(),
            created: Utc::now(),
            author: "user".into(),
            author_kind: ActorKind::Human,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: crate::item::Priority::Normal,
            visibility: crate::item::Visibility::Private,
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        };
        let errs = reg.validate(&item).unwrap_err();
        assert_eq!(errs.len(), 2); // missing abstract_text + arxiv_id

        // Add both
        item.payload
            .insert("abstract_text".into(), Value::String("An abstract".into()));
        item.payload
            .insert("arxiv_id".into(), Value::String("2401.00001".into()));
        assert!(reg.validate(&item).is_ok());
    }

    #[test]
    fn list_schemas() {
        let mut reg = SchemaRegistry::new();
        assert_eq!(reg.list().len(), 0);
        reg.register(bib_schema()).unwrap();
        assert_eq!(reg.list().len(), 1);
    }

    #[test]
    fn duplicate_field_in_schema() {
        let mut reg = SchemaRegistry::new();
        let schema = Schema {
            id: "bad".into(),
            name: "Bad".into(),
            version: "1.0.0".into(),
            fields: vec![
                FieldDef {
                    name: "title".into(),
                    field_type: FieldType::String,
                    required: true,
                    description: None,
                },
                FieldDef {
                    name: "title".into(),
                    field_type: FieldType::Int,
                    required: false,
                    description: None,
                },
            ],
            expected_edges: vec![],
            inherits: None,
        };
        let err = reg.register(schema).unwrap_err();
        assert!(matches!(err, RegistryError::DuplicateField { .. }));
    }
}
