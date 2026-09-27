//! The scenario record — `impress/scenario@1.0.0` (docs/plan-self-reflective-layer.md
//! S1, § Scenarios; ask-first D-R1, approved).
//!
//! One row per stored scenario. The document's whole shape (`seed`, `steps`,
//! `expect_effects`, …) has one definition, in `crates/impress-scenario`
//! (ADR-0033 D3's discipline: no second, flattened copy here) — the payload
//! stores the scenario as its own JSON text, exactly as `impress/ui/surface@1.0.0`
//! stores a `SurfaceSpec`. Written by `impress-scenario-service`'s
//! `scenario-service_create`/`_update`; read by `_get`/`_list`/`_run`.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// The canonical spelling (schema-refs.json).
pub const SCENARIO_SCHEMA_REF: &str = "impress/scenario@1.0.0";

pub mod field {
    /// The scenario's stable id (`layout.saved_round_trip`) — distinct
    /// from the row's own `ItemId`, since a scenario's id survives being
    /// re-authored.
    pub const SCENARIO_ID: &str = "scenario_id";
    pub const DESCRIPTION: &str = "description";
    pub const TIER: &str = "tier";
    /// The whole `impress_scenario::Scenario`, verbatim JSON text — one
    /// definition, in `crates/impress-scenario`.
    pub const SPEC: &str = "spec";
    pub const TAGS: &str = "tags";
    pub const REVISION: &str = "revision";
}

pub fn scenario_schema() -> Schema {
    Schema {
        id: SCENARIO_SCHEMA_REF.into(),
        name: "Scenario".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: field::SCENARIO_ID.into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "The scenario's stable id (`layout.saved_round_trip`), the \
                     id the three `run_selftest` verbs and `scenario-service_run` \
                     address it by (SC-1: the catalogues keep their ids)."
                        .into(),
                ),
            },
            FieldDef {
                name: field::DESCRIPTION.into(),
                field_type: FieldType::String,
                required: true,
                description: None,
            },
            FieldDef {
                name: field::TIER.into(),
                field_type: FieldType::String,
                required: true,
                description: Some("`\"a\"` or `\"b\"`.".into()),
            },
            FieldDef {
                name: field::SPEC.into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "The whole `impress_scenario::Scenario`, as its own JSON \
                     text — one definition, in crates/impress-scenario, the \
                     same discipline `impress/ui/surface@1.0.0`'s `spec` field \
                     documents."
                        .into(),
                ),
            },
            FieldDef {
                name: field::TAGS.into(),
                field_type: FieldType::StringArray,
                required: false,
                description: None,
            },
            FieldDef {
                name: field::REVISION.into(),
                field_type: FieldType::Int,
                required: false,
                description: Some("1 on create, +1 on every update; absent reads as 1.".into()),
            },
        ],
        expected_edges: vec![EdgeType::DerivedFrom, EdgeType::RelatesTo],
        inherits: None,
    }
}

pub fn register_scenario_schema(registry: &mut SchemaRegistry) {
    registry
        .register(scenario_schema())
        .expect("scenario schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_record_kind_registers_under_its_canonical_ref() {
        let mut reg = SchemaRegistry::new();
        register_scenario_schema(&mut reg);
        assert!(reg.get(SCENARIO_SCHEMA_REF).is_some());
        assert_eq!(scenario_schema().id, "impress/scenario@1.0.0");
    }
}
