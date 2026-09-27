//! The workflow record — `impress/workflow@1.0.0` (ask-first D-R1,
//! plan-self-reflective-layer.md § Workflows; W1).
//!
//! One row per stored, reviewable action sequence: a trigger (schedule,
//! store change, job finished, message, call or manual), guards, the
//! surface's own `params`/`sources`/`steps` vocabulary (`steps` reuses
//! `impress_surface::spec::Action` — this crate never depends on that one,
//! so the fields below are declared loosely as `Object`/`String`, the same
//! way `verb_call.rs`'s `args` field is), and review metadata (D-R6).
//!
//! Until this module existed, the only writer was
//! `impress-store-service::history_service::save_macro`, which pre-declared
//! this same ref as a local constant (see that module's doc comment) because
//! W1 (this module) had not landed yet. That constant is unchanged — both
//! name the same string — but the canonical *definition*, per
//! `schema-refs.json`, is this one.

use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// The canonical spelling (schema-refs.json).
pub const WORKFLOW_SCHEMA: &str = "impress/workflow@1.0.0";

fn described(mut def: FieldDef, description: &str) -> FieldDef {
    def.description = Some(description.into());
    def
}

fn field(name: &str, field_type: FieldType, required: bool) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type,
        required,
        description: None,
    }
}

pub fn workflow_schema() -> Schema {
    Schema {
        id: WORKFLOW_SCHEMA.into(),
        name: "Workflow".into(),
        version: "1.0.0".into(),
        fields: vec![
            field("wire_version", FieldType::Int, true),
            field("name", FieldType::String, true),
            field("description", FieldType::String, false),
            described(
                field("state", FieldType::String, true),
                "enabled | disabled | proposed | broken (D-R6, plan § Workflows).",
            ),
            described(
                field("author", FieldType::Object, true),
                "`{kind, name?}` — who wrote this workflow.",
            ),
            described(
                field("trigger", FieldType::Object, true),
                "Exactly one of schedule | store | job | message | call | manual.",
            ),
            field("guards", FieldType::Object, false),
            described(
                field("params", FieldType::Object, false),
                "An array of `impress_surface::spec::ParamDecl`, stored as-is \
                 (there is no array-of-object `FieldType`; see `steps` below).",
            ),
            field("sources", FieldType::Object, false),
            described(
                field("steps", FieldType::Object, true),
                "An array of `impress_surface::spec::Action` — the surface \
                 action vocabulary, unchanged; no new action kinds for a \
                 workflow. Declared `Object` for the same reason `params` is: \
                 this crate's `FieldType` has no array-of-object variant, and \
                 the payload itself (a JSON array) is what every writer and \
                 reader actually exchanges.",
            ),
            field("review", FieldType::Object, false),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

pub fn register_workflow_schema(registry: &mut SchemaRegistry) {
    registry
        .register(workflow_schema())
        .expect("workflow schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_record_kind_registers_under_its_canonical_ref() {
        let mut reg = SchemaRegistry::new();
        register_workflow_schema(&mut reg);
        assert!(reg.get(WORKFLOW_SCHEMA).is_some());
        assert_eq!(workflow_schema().id, "impress/workflow@1.0.0");
    }
}
