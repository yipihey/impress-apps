use serde::{Deserialize, Serialize};

use crate::item::{Item, ItemId};
use crate::store::FieldMutation;

/// Events emitted by the item store when items change.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum ItemEvent {
    Created(Box<Item>),
    Updated {
        id: ItemId,
        mutations: Vec<FieldMutation>,
    },
    Deleted(ItemId),
    OperationApplied {
        operation_id: ItemId,
        target_id: ItemId,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn event_serde_round_trip() {
        let events = vec![
            ItemEvent::Deleted(Uuid::new_v4()),
            ItemEvent::Updated {
                id: Uuid::new_v4(),
                mutations: vec![FieldMutation::SetRead(true)],
            },
            ItemEvent::OperationApplied {
                operation_id: Uuid::new_v4(),
                target_id: Uuid::new_v4(),
            },
        ];
        for e in &events {
            let json = serde_json::to_string(e).unwrap();
            let back: ItemEvent = serde_json::from_str(&json).unwrap();
            assert_eq!(*e, back);
        }
    }
}
