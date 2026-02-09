use serde::{Deserialize, Serialize};

use crate::item::{ItemId, Value};
use crate::reference::EdgeType;
use crate::schema::SchemaRef;

/// A query against the item store.
///
/// Maps to imbib's `PublicationSource` + `LibrarySortOrder` + search/filter:
/// - `.library(id)` → `ItemQuery { predicates: [HasParent(id)] }`
/// - `.flagged(color)` → `ItemQuery { predicates: [HasFlag(Some(color))] }`
/// - `.smartSearch(q)` → `ItemQuery { predicates: [Contains("title", q)] }`
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ItemQuery {
    pub schema: Option<SchemaRef>,
    pub predicates: Vec<Predicate>,
    pub sort: Vec<SortDescriptor>,
    pub limit: Option<usize>,
    pub offset: Option<usize>,
}

/// Filter predicate for item queries.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub enum Predicate {
    // Field comparisons
    Eq(String, Value),
    Neq(String, Value),
    Gt(String, Value),
    Lt(String, Value),
    Gte(String, Value),
    Lte(String, Value),
    Contains(String, String),
    In(String, Vec<Value>),

    // Classification
    HasTag(String),
    HasFlag(Option<String>),
    IsRead(bool),
    IsStarred(bool),

    // Graph
    HasParent(ItemId),
    HasReference(EdgeType, ItemId),
    ReferencedBy(EdgeType, ItemId),

    // Logical
    And(Vec<Predicate>),
    Or(Vec<Predicate>),
    Not(Box<Predicate>),
}

/// Sort descriptor for query results.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SortDescriptor {
    /// Field path, e.g. "created", "modified", "payload.title".
    pub field: String,
    pub ascending: bool,
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn default_query_is_empty() {
        let q = ItemQuery::default();
        assert!(q.schema.is_none());
        assert!(q.predicates.is_empty());
        assert!(q.sort.is_empty());
        assert!(q.limit.is_none());
        assert!(q.offset.is_none());
    }

    #[test]
    fn query_serde_round_trip() {
        let q = ItemQuery {
            schema: Some("bibliography-entry".into()),
            predicates: vec![
                Predicate::HasParent(Uuid::new_v4()),
                Predicate::IsStarred(true),
                Predicate::Or(vec![
                    Predicate::Contains("title".into(), "dark matter".into()),
                    Predicate::Contains("abstract".into(), "dark matter".into()),
                ]),
            ],
            sort: vec![SortDescriptor {
                field: "created".into(),
                ascending: false,
            }],
            limit: Some(50),
            offset: Some(0),
        };
        let json = serde_json::to_string_pretty(&q).unwrap();
        let back: ItemQuery = serde_json::from_str(&json).unwrap();
        assert_eq!(q, back);
    }

    #[test]
    fn nested_predicate_serde() {
        let pred = Predicate::And(vec![
            Predicate::Not(Box::new(Predicate::IsRead(true))),
            Predicate::HasFlag(Some("red".into())),
            Predicate::Or(vec![
                Predicate::HasTag("methods/sims".into()),
                Predicate::HasTag("methods/obs".into()),
            ]),
        ]);
        let json = serde_json::to_string(&pred).unwrap();
        let back: Predicate = serde_json::from_str(&json).unwrap();
        assert_eq!(pred, back);
    }
}
