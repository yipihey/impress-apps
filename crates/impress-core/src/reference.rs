use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

use crate::item::{ItemId, Value};

/// A typed, directed edge between two items in the graph.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TypedReference {
    pub target: ItemId,
    pub edge_type: EdgeType,
    pub metadata: Option<BTreeMap<String, Value>>,
}

/// Edge type taxonomy.
///
/// Common types are enum variants; domain-specific types use `Custom`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum EdgeType {
    // Academic
    Cites,
    References,

    // Communication
    InResponseTo,
    Discusses,

    // Containment & Attachment
    Contains,
    Attaches,

    // Provenance
    ProducedBy,
    DerivedFrom,
    Supersedes,

    // Annotation
    Annotates,

    // Visualization
    Visualizes,

    // General
    RelatesTo,

    // Workflow
    DependsOn,

    // Operations
    OperatesOn,

    // Extensible
    Custom(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[test]
    fn typed_reference_serde_round_trip() {
        let refs = vec![
            TypedReference {
                target: Uuid::new_v4(),
                edge_type: EdgeType::Cites,
                metadata: None,
            },
            TypedReference {
                target: Uuid::new_v4(),
                edge_type: EdgeType::Custom("co-authored-with".into()),
                metadata: Some({
                    let mut m = BTreeMap::new();
                    m.insert("role".into(), Value::String("corresponding".into()));
                    m
                }),
            },
        ];
        for r in &refs {
            let json = serde_json::to_string(r).unwrap();
            let back: TypedReference = serde_json::from_str(&json).unwrap();
            assert_eq!(*r, back);
        }
    }

    #[test]
    fn edge_type_serde_variants() {
        let variants = vec![
            EdgeType::Cites,
            EdgeType::References,
            EdgeType::InResponseTo,
            EdgeType::Discusses,
            EdgeType::Contains,
            EdgeType::Attaches,
            EdgeType::ProducedBy,
            EdgeType::DerivedFrom,
            EdgeType::Supersedes,
            EdgeType::Annotates,
            EdgeType::Visualizes,
            EdgeType::RelatesTo,
            EdgeType::DependsOn,
            EdgeType::OperatesOn,
            EdgeType::Custom("my-edge".into()),
        ];
        for v in &variants {
            let json = serde_json::to_string(v).unwrap();
            let back: EdgeType = serde_json::from_str(&json).unwrap();
            assert_eq!(*v, back);
        }
    }
}
