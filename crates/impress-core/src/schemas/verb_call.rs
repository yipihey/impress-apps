//! The verb call record — `core/verb-call@1.0.0` (ADR-0036 D2,
//! plan-self-reflective-layer D-R1/D-R2; written by the pipeline's audit
//! layer, plan-verb-pipeline P2).
//!
//! One row per non-read-only verb call on every path: the verb, the caller
//! the pipeline established (never an argument), the trace and parent ids, a
//! privacy-filtered argument summary, the outcome and the duration. The
//! row's id is the call id, and every `core/operation` row the verb wrote
//! carries it as `batch_id` — so "why did this item change" is
//! `ops_for(item) → batch_id → this row`, over the two indexes that already
//! exist (`idx_items_op_target`, `idx_items_batch`).
//!
//! Not an operation (D-R2): an operation row needs one `op_target_id`, and
//! a call has zero or many. Compactable, never synced.

use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// The canonical spelling (schema-refs.json).
pub const VERB_CALL_SCHEMA: &str = "core/verb-call@1.0.0";

/// The payload's field names, as the audit layer writes them.
pub mod field {
    pub const VERB: &str = "verb";
    pub const SINCE: &str = "since";
    pub const CALLER: &str = "caller";
    pub const TRACE_ID: &str = "trace_id";
    pub const PARENT_CALL: &str = "parent_call";
    pub const ARGS: &str = "args";
    pub const INSERTED_IDS: &str = "inserted_ids";
    pub const DELETED_IDS: &str = "deleted_ids";
    pub const OK: &str = "ok";
    pub const CODE: &str = "code";
    pub const MESSAGE_LEN: &str = "message_len";
    pub const STARTED_AT: &str = "started_at";
    pub const DURATION_MS: &str = "duration_ms";
    pub const ARG_BYTES: &str = "arg_bytes";
    pub const RESULT_BYTES: &str = "result_bytes";
    pub const WIRE_VERSION: &str = "wire_version";
}

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

pub fn verb_call_schema() -> Schema {
    Schema {
        id: VERB_CALL_SCHEMA.into(),
        name: "Verb Call".into(),
        version: "1.0.0".into(),
        fields: vec![
            described(
                field(field::VERB, FieldType::String, true),
                "The qualified verb name (`imbib-tags-service_add-tag`).",
            ),
            described(
                field(field::SINCE, FieldType::String, true),
                "The descriptor's `since` version at the time of the call.",
            ),
            described(
                field(field::CALLER, FieldType::Object, true),
                "`{kind, name?}`: the caller identity the pipeline established \
                 from the transport — never from an argument.",
            ),
            described(
                field(field::TRACE_ID, FieldType::String, true),
                "The trace this call belongs to; a fresh call's own id.",
            ),
            described(
                field(field::PARENT_CALL, FieldType::String, false),
                "The call this one ran inside (a surface's `call` effect).",
            ),
            described(
                field(field::ARGS, FieldType::Object, true),
                "The privacy-filtered argument summary: ids and short scalars \
                 by value, long strings as length + hash, objects as their keys.",
            ),
            described(
                field(field::INSERTED_IDS, FieldType::StringArray, false),
                "Deduplicated ids of items created during this call.",
            ),
            described(
                field(field::DELETED_IDS, FieldType::StringArray, false),
                "Deduplicated ids of items deleted during this call.",
            ),
            described(field(field::OK, FieldType::Bool, true), "The outcome."),
            described(
                field(field::CODE, FieldType::String, false),
                "The refusal code when `ok` is false.",
            ),
            field(field::MESSAGE_LEN, FieldType::Int, true),
            described(
                field(field::STARTED_AT, FieldType::String, true),
                "RFC 3339.",
            ),
            field(field::DURATION_MS, FieldType::Int, true),
            field(field::ARG_BYTES, FieldType::Int, true),
            field(field::RESULT_BYTES, FieldType::Int, true),
            field(field::WIRE_VERSION, FieldType::Int, true),
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

pub fn register_verb_call_schema(registry: &mut SchemaRegistry) {
    registry
        .register(verb_call_schema())
        .expect("verb-call schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_record_kind_registers_under_its_canonical_ref() {
        let mut reg = SchemaRegistry::new();
        register_verb_call_schema(&mut reg);
        assert!(reg.get(&VERB_CALL_SCHEMA).is_some());
        assert_eq!(verb_call_schema().id, VERB_CALL_SCHEMA);
    }
}
