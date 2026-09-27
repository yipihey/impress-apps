//! The store's view of the verb call it is running under (ADR-0036 D2,
//! plan-self-reflective-layer H-P2-2).
//!
//! The pipeline (`impress_service_core::pipeline`) sets a task-local call
//! context around every verb's handler. This module is the store's read of
//! it — [`current_call_id`] is what `apply_operation_on` stamps as
//! `batch_id` on an operation written with none — and the one writer of the
//! `core/verb-call@1.0.0` row itself, [`record_verb_call`], which the audit
//! sink in `impress-store-service` calls from its writer thread.
//!
//! The context type lives in `impress-service-core` because the pipeline
//! is on the kit's pure tier and cannot reach this crate; this crate reads
//! it the way it already reads `impress-pane-query`.

use std::collections::BTreeMap;

use chrono::Utc;
use uuid::Uuid;

pub use impress_service_core::pipeline::context::{
    current, current_call_id, note_mutation, CallContext,
};
pub use impress_service_core::pipeline::CallerIdentity;

use crate::item::{ActorKind, Item, ItemId, Priority, Value, Visibility};
use crate::schemas::verb_call::VERB_CALL_SCHEMA;
use crate::store::{ItemStore, StoreError};

/// The `ActorKind` a caller identity records as: the person is human, the
/// system is the system, and every agent, app route and provider is an
/// agent — an app's HTTP route is not the person at the keyboard.
pub fn actor_kind_of(caller: &CallerIdentity) -> ActorKind {
    match caller {
        CallerIdentity::Person => ActorKind::Human,
        CallerIdentity::System(_) => ActorKind::System,
        CallerIdentity::Agent(_) | CallerIdentity::App(_) | CallerIdentity::Provider(_) => {
            ActorKind::Agent
        }
    }
}

/// Write one `core/verb-call@1.0.0` row. `call_id` must be a UUID (the
/// pipeline's call id), so the row's id and the operations' `batch_id`
/// are one string. `payload` is the record's payload as the audit layer
/// built it (`VerbCallRecord::payload`).
pub fn record_verb_call(
    store: &dyn ItemStore,
    call_id: &str,
    caller: &CallerIdentity,
    payload: serde_json::Map<String, serde_json::Value>,
) -> Result<ItemId, StoreError> {
    let id = Uuid::parse_str(call_id)
        .map_err(|e| StoreError::Validation(format!("call id {call_id:?} is not a UUID: {e}")))?;
    let fields: BTreeMap<String, Value> =
        serde_json::from_value(serde_json::Value::Object(payload))
            .map_err(|e| StoreError::Validation(format!("verb-call payload: {e}")))?;
    let now = Utc::now();
    store.insert(Item {
        id,
        schema: VERB_CALL_SCHEMA.into(),
        payload: fields,
        created: now,
        modified: now,
        author: caller.author(),
        author_kind: actor_kind_of(caller),
        logical_clock: 0,
        origin: None,
        canonical_id: None,
        tags: vec![],
        flag: None,
        is_read: false,
        is_starred: false,
        priority: Priority::None,
        visibility: Visibility::Private,
        message_type: None,
        produced_by: None,
        version: None,
        // The call's own id: the join key its operations carry.
        batch_id: Some(call_id.to_string()),
        references: vec![],
        parent: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_person_is_human_and_everything_else_that_is_not_the_system_is_an_agent() {
        assert_eq!(actor_kind_of(&CallerIdentity::Person), ActorKind::Human);
        assert_eq!(
            actor_kind_of(&CallerIdentity::agent("mcp")),
            ActorKind::Agent
        );
        assert_eq!(
            actor_kind_of(&CallerIdentity::App("imbib".into())),
            ActorKind::Agent
        );
        assert_eq!(
            actor_kind_of(&CallerIdentity::system("d")),
            ActorKind::System
        );
    }
}
