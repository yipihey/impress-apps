use impress_core::reference::EdgeType;
use impress_core::registry::SchemaRegistry;
use impress_core::schema::{FieldDef, FieldType, Schema};

pub const VW_CONFIGURATION_SCHEMA: &str = "vw/configuration@1.0.0";
pub const VW_VEHICLE_SCHEMA: &str = "vw/vehicle@1.0.0";
pub const VW_DIAGNOSTIC_SESSION_SCHEMA: &str = "vw/diagnostic-session@1.0.0";
pub const VW_OBSERVATION_SCHEMA: &str = "vw/observation@1.0.0";
pub const VW_MEASUREMENT_SCHEMA: &str = "vw/measurement@1.0.0";
pub const VW_PROCEDURE_RUN_SCHEMA: &str = "vw/procedure-run@1.0.0";
pub const VW_COMMAND_RECEIPT_SCHEMA: &str = "vw/command-receipt@1.0.0";
pub const VW_KNOWLEDGE_PACK_SCHEMA: &str = "vw/knowledge-pack@1.0.0";

fn field(name: &str, field_type: FieldType, required: bool, description: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type,
        required,
        description: Some(description.into()),
    }
}

fn aggregate_schema(id: &str, name: &str, extra: Vec<FieldDef>, edges: Vec<EdgeType>) -> Schema {
    let mut fields = vec![
        field(
            "title",
            FieldType::String,
            true,
            "Human-readable record title.",
        ),
        field(
            "data",
            FieldType::Object,
            true,
            "Versioned typed domain object serialized as JSON.",
        ),
    ];
    fields.extend(extra);
    Schema {
        id: id.into(),
        name: name.into(),
        version: "1.0.0".into(),
        fields,
        expected_edges: edges,
        inherits: None,
    }
}

pub fn vw_schemas() -> Vec<Schema> {
    vec![
        aggregate_schema(
            VW_CONFIGURATION_SCHEMA,
            "VW Vehicle Configuration",
            vec![
                field("model_year", FieldType::Int, true, "Configured model year."),
                field(
                    "market",
                    FieldType::String,
                    true,
                    "Configured sales/emissions market.",
                ),
                field(
                    "engine_code",
                    FieldType::String,
                    true,
                    "Configured engine code.",
                ),
                field(
                    "fuel_system",
                    FieldType::String,
                    true,
                    "Configured fuel system.",
                ),
            ],
            vec![],
        ),
        aggregate_schema(
            VW_VEHICLE_SCHEMA,
            "VW Vehicle",
            vec![field(
                "configuration_id",
                FieldType::String,
                true,
                "Configuration item UUID.",
            )],
            vec![EdgeType::RelatesTo],
        ),
        aggregate_schema(
            VW_DIAGNOSTIC_SESSION_SCHEMA,
            "VW Diagnostic Session",
            vec![
                field(
                    "state",
                    FieldType::String,
                    true,
                    "Domain session lifecycle state.",
                ),
                field(
                    "revision",
                    FieldType::Int,
                    true,
                    "Optimistic domain revision.",
                ),
                field("vehicle_id", FieldType::String, true, "Vehicle item UUID."),
                field(
                    "knowledge_pack",
                    FieldType::String,
                    true,
                    "Pinned knowledge-pack id and version.",
                ),
            ],
            vec![EdgeType::OperatesOn],
        ),
        aggregate_schema(
            VW_OBSERVATION_SCHEMA,
            "VW Observation",
            vec![
                field(
                    "session_id",
                    FieldType::String,
                    true,
                    "Parent diagnostic session UUID.",
                ),
                field(
                    "component_key",
                    FieldType::String,
                    false,
                    "Observed component key.",
                ),
            ],
            vec![EdgeType::IsPartOf, EdgeType::Supersedes],
        ),
        aggregate_schema(
            VW_MEASUREMENT_SCHEMA,
            "VW Measurement",
            vec![
                field(
                    "session_id",
                    FieldType::String,
                    true,
                    "Parent diagnostic session UUID.",
                ),
                field(
                    "quantity",
                    FieldType::String,
                    true,
                    "Measured quantity name.",
                ),
                field("unit", FieldType::String, true, "Entered measurement unit."),
                field(
                    "component_key",
                    FieldType::String,
                    false,
                    "Measured component key.",
                ),
            ],
            vec![EdgeType::IsPartOf, EdgeType::DerivedFrom],
        ),
        aggregate_schema(
            VW_PROCEDURE_RUN_SCHEMA,
            "VW Procedure Run",
            vec![
                field(
                    "session_id",
                    FieldType::String,
                    true,
                    "Parent diagnostic session UUID.",
                ),
                field(
                    "procedure_id",
                    FieldType::String,
                    true,
                    "Versioned procedure domain key.",
                ),
                field(
                    "state",
                    FieldType::String,
                    true,
                    "Procedure-run lifecycle state.",
                ),
            ],
            vec![EdgeType::IsPartOf, EdgeType::DerivedFrom],
        ),
        aggregate_schema(
            VW_COMMAND_RECEIPT_SCHEMA,
            "VW Command Receipt",
            vec![
                field(
                    "command_id",
                    FieldType::String,
                    true,
                    "Caller-generated idempotency UUID.",
                ),
                field(
                    "session_id",
                    FieldType::String,
                    true,
                    "Resulting session UUID.",
                ),
            ],
            vec![EdgeType::OperatesOn],
        ),
        aggregate_schema(
            VW_KNOWLEDGE_PACK_SCHEMA,
            "VW Knowledge Pack",
            vec![
                field(
                    "pack_id",
                    FieldType::String,
                    true,
                    "Stable domain pack identifier.",
                ),
                field(
                    "pack_version",
                    FieldType::String,
                    true,
                    "Immutable pack version.",
                ),
                field(
                    "content_hash",
                    FieldType::String,
                    true,
                    "Pack manifest content hash.",
                ),
            ],
            vec![EdgeType::References],
        ),
    ]
}

pub fn register_vw_schemas(registry: &mut SchemaRegistry) {
    for schema in vw_schemas() {
        registry.register(schema).expect("VW schema registration");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_vw_schemas_register_once() {
        let mut registry = SchemaRegistry::new();
        register_vw_schemas(&mut registry);
        assert_eq!(registry.list().len(), 8);
        assert!(registry.get(VW_DIAGNOSTIC_SESSION_SCHEMA).is_some());
        assert!(registry.get(VW_COMMAND_RECEIPT_SCHEMA).is_some());
    }
}
