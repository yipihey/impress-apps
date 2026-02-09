use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::item::{ActorId, ActorKind, FlagState, ItemId, Priority, Value, Visibility};
use crate::reference::{EdgeType, TypedReference};
use crate::store::FieldMutation;

/// The type of operation being applied to a target item.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum OperationType {
    AddTag(String),
    RemoveTag(String),
    SetFlag(Option<FlagState>),
    SetRead(bool),
    SetStarred(bool),
    SetPriority(Priority),
    SetVisibility(Visibility),
    SetPayload(String, Value),
    RemovePayload(String),
    PatchPayload(BTreeMap<String, Value>),
    AddReference(TypedReference),
    RemoveReference(ItemId, EdgeType),
    SetParent(Option<ItemId>),
    Custom(String, Value),
}

impl From<FieldMutation> for OperationType {
    fn from(mutation: FieldMutation) -> Self {
        match mutation {
            FieldMutation::SetPayload(field, value) => OperationType::SetPayload(field, value),
            FieldMutation::RemovePayload(field) => OperationType::RemovePayload(field),
            FieldMutation::SetRead(v) => OperationType::SetRead(v),
            FieldMutation::SetStarred(v) => OperationType::SetStarred(v),
            FieldMutation::SetFlag(flag) => OperationType::SetFlag(flag),
            FieldMutation::AddTag(tag) => OperationType::AddTag(tag),
            FieldMutation::RemoveTag(tag) => OperationType::RemoveTag(tag),
            FieldMutation::AddReference(r) => OperationType::AddReference(r),
            FieldMutation::RemoveReference(id, edge) => OperationType::RemoveReference(id, edge),
            FieldMutation::SetParent(parent) => OperationType::SetParent(parent),
        }
    }
}

/// The intent behind an operation — why was this change made?
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OperationIntent {
    /// Routine workflow action (default)
    #[default]
    Routine,
    /// Exploratory / hypothesis-driven change
    Hypothesis,
    /// Anomaly flagged by automated system
    Anomaly,
    /// Editorial decision
    Editorial,
    /// Correcting a previous error
    Correction,
    /// Escalation requiring attention
    Escalation,
}

impl std::fmt::Display for OperationIntent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            OperationIntent::Routine => write!(f, "routine"),
            OperationIntent::Hypothesis => write!(f, "hypothesis"),
            OperationIntent::Anomaly => write!(f, "anomaly"),
            OperationIntent::Editorial => write!(f, "editorial"),
            OperationIntent::Correction => write!(f, "correction"),
            OperationIntent::Escalation => write!(f, "escalation"),
        }
    }
}

/// Specification for creating an operation item.
#[derive(Debug, Clone)]
pub struct OperationSpec {
    pub target_id: ItemId,
    pub op_type: OperationType,
    pub intent: OperationIntent,
    pub reason: Option<String>,
    pub batch_id: Option<String>,
    pub author: ActorId,
    pub author_kind: ActorKind,
}

/// The effective state of an item, either current (materialized) or
/// computed via time-travel replay.
#[derive(Debug, Clone)]
pub struct EffectiveState {
    /// The item with effective field values.
    pub tags: Vec<String>,
    pub flag: Option<FlagState>,
    pub is_read: bool,
    pub is_starred: bool,
    pub priority: Priority,
    pub visibility: Visibility,
    pub payload: BTreeMap<String, Value>,
    pub parent: Option<ItemId>,
    /// The logical clock value this state was computed at.
    pub as_of_clock: u64,
    /// The wall-clock time this state was computed at (if time-travel).
    pub as_of_time: Option<DateTime<Utc>>,
    /// Total number of operations that contributed to this state.
    pub operation_count: usize,
}

/// Specifies how to query effective state.
#[derive(Debug, Clone)]
pub enum StateAsOf {
    /// Current materialized state (fast path).
    Current,
    /// State as of a specific logical clock value.
    LogicalClock(u64),
    /// State as of a specific wall-clock time.
    Timestamp(DateTime<Utc>),
}

/// Build the operation payload (stored as the operation item's payload).
pub fn build_operation_payload(
    target_id: ItemId,
    op_type: &OperationType,
    intent: OperationIntent,
    reason: Option<&str>,
) -> BTreeMap<String, Value> {
    let mut payload = BTreeMap::new();
    payload.insert("target_id".into(), Value::String(target_id.to_string()));
    payload.insert("intent".into(), Value::String(intent.to_string()));

    if let Some(r) = reason {
        payload.insert("reason".into(), Value::String(r.to_string()));
    }

    let (op_type_str, op_data) = serialize_op_type(op_type);
    payload.insert("op_type".into(), Value::String(op_type_str));
    payload.insert("op_data".into(), op_data);

    payload
}

/// Serialize an OperationType to (type_name, data_value) for storage.
fn serialize_op_type(op: &OperationType) -> (String, Value) {
    match op {
        OperationType::AddTag(tag) => ("add_tag".into(), Value::String(tag.clone())),
        OperationType::RemoveTag(tag) => ("remove_tag".into(), Value::String(tag.clone())),
        OperationType::SetFlag(flag) => {
            let val = match flag {
                Some(f) => {
                    let mut m = BTreeMap::new();
                    m.insert("color".into(), Value::String(f.color.clone()));
                    if let Some(s) = &f.style {
                        m.insert("style".into(), Value::String(s.clone()));
                    }
                    if let Some(l) = &f.length {
                        m.insert("length".into(), Value::String(l.clone()));
                    }
                    Value::Object(m)
                }
                None => Value::Null,
            };
            ("set_flag".into(), val)
        }
        OperationType::SetRead(v) => ("set_read".into(), Value::Bool(*v)),
        OperationType::SetStarred(v) => ("set_starred".into(), Value::Bool(*v)),
        OperationType::SetPriority(p) => ("set_priority".into(), Value::String(p.to_string())),
        OperationType::SetVisibility(v) => {
            ("set_visibility".into(), Value::String(v.to_string()))
        }
        OperationType::SetPayload(field, val) => {
            let mut m = BTreeMap::new();
            m.insert("field".into(), Value::String(field.clone()));
            m.insert("value".into(), val.clone());
            ("set_payload".into(), Value::Object(m))
        }
        OperationType::RemovePayload(field) => {
            ("remove_payload".into(), Value::String(field.clone()))
        }
        OperationType::PatchPayload(fields) => {
            let m: BTreeMap<String, Value> = fields.clone();
            ("patch_payload".into(), Value::Object(m))
        }
        OperationType::AddReference(r) => {
            let mut m = BTreeMap::new();
            m.insert("target".into(), Value::String(r.target.to_string()));
            m.insert(
                "edge_type".into(),
                Value::String(serde_json::to_string(&r.edge_type).unwrap_or_default()),
            );
            if let Some(meta) = &r.metadata {
                let meta_val = serde_json::to_string(meta)
                    .map(Value::String)
                    .unwrap_or(Value::Null);
                m.insert("metadata".into(), meta_val);
            }
            ("add_reference".into(), Value::Object(m))
        }
        OperationType::RemoveReference(target, edge) => {
            let mut m = BTreeMap::new();
            m.insert("target".into(), Value::String(target.to_string()));
            m.insert(
                "edge_type".into(),
                Value::String(serde_json::to_string(edge).unwrap_or_default()),
            );
            ("remove_reference".into(), Value::Object(m))
        }
        OperationType::SetParent(parent) => {
            let val = match parent {
                Some(id) => Value::String(id.to_string()),
                None => Value::Null,
            };
            ("set_parent".into(), val)
        }
        OperationType::Custom(name, data) => (format!("custom:{}", name), data.clone()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn field_mutation_to_operation_type() {
        let mutations = vec![
            (FieldMutation::SetRead(true), "SetRead"),
            (FieldMutation::SetStarred(false), "SetStarred"),
            (FieldMutation::AddTag("test".into()), "AddTag"),
            (FieldMutation::RemoveTag("test".into()), "RemoveTag"),
            (FieldMutation::SetFlag(None), "SetFlag"),
            (
                FieldMutation::SetPayload("title".into(), Value::String("t".into())),
                "SetPayload",
            ),
            (FieldMutation::RemovePayload("field".into()), "RemovePayload"),
            (FieldMutation::SetParent(None), "SetParent"),
        ];

        for (mutation, expected_name) in mutations {
            let op: OperationType = mutation.into();
            let name = format!("{:?}", op);
            assert!(
                name.starts_with(expected_name),
                "expected {} to start with {}",
                name,
                expected_name
            );
        }
    }

    #[test]
    fn operation_intent_display() {
        assert_eq!(OperationIntent::Routine.to_string(), "routine");
        assert_eq!(OperationIntent::Escalation.to_string(), "escalation");
    }

    #[test]
    fn build_operation_payload_round_trip() {
        let target = Uuid::new_v4();
        let payload = build_operation_payload(
            target,
            &OperationType::AddTag("methods/sims".into()),
            OperationIntent::Routine,
            Some("testing"),
        );
        assert_eq!(
            payload.get("target_id"),
            Some(&Value::String(target.to_string()))
        );
        assert_eq!(
            payload.get("op_type"),
            Some(&Value::String("add_tag".into()))
        );
        assert_eq!(
            payload.get("op_data"),
            Some(&Value::String("methods/sims".into()))
        );
        assert_eq!(
            payload.get("intent"),
            Some(&Value::String("routine".into()))
        );
        assert_eq!(
            payload.get("reason"),
            Some(&Value::String("testing".into()))
        );
    }

    #[test]
    fn operation_intent_serde() {
        for intent in [
            OperationIntent::Routine,
            OperationIntent::Hypothesis,
            OperationIntent::Anomaly,
            OperationIntent::Editorial,
            OperationIntent::Correction,
            OperationIntent::Escalation,
        ] {
            let json = serde_json::to_string(&intent).unwrap();
            let back: OperationIntent = serde_json::from_str(&json).unwrap();
            assert_eq!(intent, back);
        }
    }

    #[test]
    fn operation_type_serde() {
        let ops = vec![
            OperationType::AddTag("test".into()),
            OperationType::RemoveTag("test".into()),
            OperationType::SetRead(true),
            OperationType::SetStarred(false),
            OperationType::SetPriority(Priority::High),
            OperationType::SetVisibility(Visibility::Public),
            OperationType::SetFlag(Some(FlagState {
                color: "red".into(),
                style: None,
                length: None,
            })),
            OperationType::SetPayload("title".into(), Value::String("Test".into())),
            OperationType::RemovePayload("old".into()),
            OperationType::SetParent(Some(Uuid::new_v4())),
            OperationType::Custom("my-op".into(), Value::Int(42)),
        ];
        for op in &ops {
            let json = serde_json::to_string(op).unwrap();
            let back: OperationType = serde_json::from_str(&json).unwrap();
            assert_eq!(*op, back);
        }
    }
}
