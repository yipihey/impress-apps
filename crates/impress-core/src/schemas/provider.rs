//! Local runtime-provider registration (`provider@1.0.0`, ADR-0034 D-P4).
//!
//! This record stores the provider descriptor, its trust decision, and a hash
//! of the host-issued credential. The raw credential is never a payload field;
//! its private, hash-addressed file lives in the host workspace. Provider rows
//! are also excluded from the sync outbox by the store-service installer.

use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

pub const PROVIDER_SCHEMA: crate::SchemaRef = crate::schema::refs::PROVIDER;

fn field(name: &str, field_type: FieldType, description: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type,
        required: true,
        description: Some(description.into()),
    }
}

pub fn provider_schema() -> Schema {
    Schema {
        id: PROVIDER_SCHEMA,
        name: "Runtime Provider".into(),
        version: "1.0.0".into(),
        fields: vec![
            field(
                "id",
                FieldType::String,
                "The provider's stable kebab-case id.",
            ),
            field(
                "language",
                FieldType::String,
                "The provider implementation language.",
            ),
            field(
                "version",
                FieldType::String,
                "The provider's numeric dotted version.",
            ),
            field(
                "endpoint",
                FieldType::String,
                "The validated loopback HTTP(S) endpoint.",
            ),
            field(
                "trusted",
                FieldType::Bool,
                "Only a person may grant this trust decision.",
            ),
            field(
                "token_hash",
                FieldType::String,
                "SHA-256 of the host-issued token; the token itself is never stored here.",
            ),
            field(
                "deregistered",
                FieldType::Bool,
                "A tombstoned provider is unavailable.",
            ),
            field(
                "verbs",
                FieldType::String,
                "JSON text of the validated descriptor list, including dropped verbs. \
                 Stored as text because FieldType has no array-of-objects variant.",
            ),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

pub fn register_provider_schema(registry: &mut SchemaRegistry) {
    registry
        .register(provider_schema())
        .expect("provider schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_record_has_one_canonical_ref_and_no_token_field() {
        let mut registry = SchemaRegistry::new();
        register_provider_schema(&mut registry);
        let schema = registry.get(&PROVIDER_SCHEMA).expect("provider schema");
        assert_eq!(schema.id, PROVIDER_SCHEMA);
        assert!(!schema.fields.iter().any(|field| field.name == "token"));
        assert!(schema.fields.iter().any(|field| field.name == "token_hash"));
    }
}
