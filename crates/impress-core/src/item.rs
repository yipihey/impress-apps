use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use uuid::Uuid;

use crate::reference::TypedReference;
use crate::schema::SchemaRef;

/// Globally unique item identifier (UUID v4).
pub type ItemId = Uuid;

/// Actor (human or agent) identifier.
pub type ActorId = String;

/// Dynamic value type for payload fields.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Value {
    Null,
    Bool(bool),
    Int(i64),
    Float(f64),
    String(String),
    Array(Vec<Value>),
    Object(BTreeMap<String, Value>),
}

/// Whether the item was created by a human, agent, or system.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ActorKind {
    Human,
    Agent,
    System,
}

/// Flag state — color with optional style and length.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct FlagState {
    pub color: String,
    pub style: Option<String>,
    pub length: Option<String>,
}

/// The core entity of the unified architecture.
///
/// All data across the impress suite is represented as Items.
/// Universal metadata lives on the struct directly; domain-specific
/// fields live in `payload`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub id: ItemId,
    pub schema: SchemaRef,
    pub payload: BTreeMap<String, Value>,

    // Universal metadata
    pub created: DateTime<Utc>,
    pub modified: DateTime<Utc>,
    pub author: ActorId,
    pub author_kind: ActorKind,

    // Classification
    pub tags: Vec<String>,
    pub flag: Option<FlagState>,
    pub is_read: bool,
    pub is_starred: bool,

    // Graph structure
    pub references: Vec<TypedReference>,
    pub parent: Option<ItemId>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn value_serde_round_trip() {
        let values = vec![
            Value::Null,
            Value::Bool(true),
            Value::Int(42),
            Value::Float(3.14),
            Value::String("hello".into()),
            Value::Array(vec![Value::Int(1), Value::String("two".into())]),
            Value::Object({
                let mut m = BTreeMap::new();
                m.insert("key".into(), Value::Bool(false));
                m
            }),
        ];
        for v in &values {
            let json = serde_json::to_string(v).unwrap();
            let back: Value = serde_json::from_str(&json).unwrap();
            assert_eq!(*v, back);
        }
    }

    #[test]
    fn item_serde_round_trip() {
        let item = Item {
            id: Uuid::new_v4(),
            schema: "bibliography-entry".into(),
            payload: {
                let mut m = BTreeMap::new();
                m.insert("title".into(), Value::String("A Great Paper".into()));
                m.insert("citation_count".into(), Value::Int(42));
                m
            },
            created: Utc::now(),
            modified: Utc::now(),
            author: "user@example.com".into(),
            author_kind: ActorKind::Human,
            tags: vec!["methods/sims/hydro".into()],
            flag: Some(FlagState {
                color: "red".into(),
                style: None,
                length: None,
            }),
            is_read: true,
            is_starred: false,
            references: vec![],
            parent: None,
        };
        let json = serde_json::to_string_pretty(&item).unwrap();
        let back: Item = serde_json::from_str(&json).unwrap();
        assert_eq!(item, back);
    }
}
