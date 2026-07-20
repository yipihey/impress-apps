use crate::item::{Item, Value};
use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for the `throughline@1.0.0` item type (ADR-0016).
///
/// A throughline is a short, curated narrative companion to a manuscript —
/// authored content (a peer of `manuscript`), not a knowledge object. Each
/// paragraph in the throughline source carries a stable `<tl-*>` label and is
/// anchored to manuscript sections via the anchor map (the sync ledger).
///
/// Source of truth is the pair of sidecar files inside the `.imprint` package
/// (`throughline.typ` + `throughline.anchors.json`, ADR-0016 D2); this item is
/// the store mirror. The optional `body_content` / `anchor_map_json` fields
/// follow the manuscript unified-store pivot so store-resident manuscripts can
/// carry their throughline wholly in-store — the ledger-update discipline
/// (accept path is the only writer, ADR-0016 D6) applies identically.
///
/// The throughline links to its manuscript via a `Custom("narrates")` edge
/// (no new core `EdgeType` variant, per ADR-0016 D3).
pub fn throughline_schema() -> Schema {
    Schema {
        id: "throughline".into(),
        name: "Throughline".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "title".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Display title of the narrative; defaults to the manuscript title.".into(),
                ),
            },
            FieldDef {
                name: "document_ref".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "UUID string of the manuscript/document this throughline narrates. \
                     Mirrored as a Custom(\"narrates\") edge."
                        .into(),
                ),
            },
            FieldDef {
                name: "paragraph_count".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some("Number of labeled paragraphs at last mirror update.".into()),
            },
            FieldDef {
                name: "content_hash".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "SHA-256 hex of the throughline source at last mirror update. Drift \
                     detection only — never a substitute for the per-anchor ledger hashes."
                        .into(),
                ),
            },
            FieldDef {
                name: "anchor_map_hash".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "SHA-256 hex of the serialized anchor map at last mirror update.".into(),
                ),
            },
            FieldDef {
                name: "body_content".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "UTF-8 Typst source of the narrative (unified-store pivot parity with \
                     `manuscript.body_content`). Absent when the sidecar file is the only \
                     copy; the sidecar remains authoritative when both exist (ADR-0016 D2)."
                        .into(),
                ),
            },
            FieldDef {
                name: "anchor_map_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "JSON-serialized anchor map (sync ledger). Written ONLY by the \
                     accept path of a sync proposal or by throughline creation \
                     (ADR-0016 D6). Same store-pivot parity note as `body_content`."
                        .into(),
                ),
            },
            // FAIR attribution (ADR-0014 D54 parity with manuscript/artifact).
            FieldDef {
                name: "orcid".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Author ORCID (FAIR attribution).".into()),
            },
            FieldDef {
                name: "affiliation".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Author affiliation (FAIR attribution).".into()),
            },
            FieldDef {
                name: "funder".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Funding source (FAIR attribution).".into()),
            },
            FieldDef {
                name: "license".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("License identifier (FAIR attribution).".into()),
            },
            FieldDef {
                name: "embargo_until".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("ISO 8601 embargo expiration (informational only).".into()),
            },
        ],
        expected_edges: vec![EdgeType::RelatesTo, EdgeType::Supersedes],
        inherits: None,
    }
}

/// The edge type linking a throughline to the manuscript it narrates.
///
/// Kept as `Custom` per ADR-0016 D3; promote to a core variant only if
/// downstream renderers make it hot (ADR-0016 OQ3).
pub fn narrates_edge() -> EdgeType {
    EdgeType::Custom("narrates".into())
}

/// Register the `throughline@1.0.0` schema.
pub fn register_throughline_schema(registry: &mut SchemaRegistry) {
    registry
        .register(throughline_schema())
        .expect("throughline schema registration");
}

// ---------------------------------------------------------------------------
// Typed accessors (ADR-0004: raw payload access is an anti-pattern).
// ---------------------------------------------------------------------------

fn payload_str<'a>(item: &'a Item, key: &str) -> Option<&'a str> {
    match item.payload.get(key) {
        Some(Value::String(s)) => Some(s.as_str()),
        _ => None,
    }
}

/// Display title of the throughline.
pub fn title(item: &Item) -> Option<&str> {
    payload_str(item, "title")
}

/// UUID string of the manuscript/document this throughline narrates.
pub fn document_ref(item: &Item) -> Option<&str> {
    payload_str(item, "document_ref")
}

/// SHA-256 hex of the throughline source at last mirror update.
pub fn content_hash(item: &Item) -> Option<&str> {
    payload_str(item, "content_hash")
}

/// SHA-256 hex of the serialized anchor map at last mirror update.
pub fn anchor_map_hash(item: &Item) -> Option<&str> {
    payload_str(item, "anchor_map_hash")
}

/// In-store Typst source (unified-store pivot parity), if present.
pub fn body_content(item: &Item) -> Option<&str> {
    payload_str(item, "body_content")
}

/// In-store serialized anchor map (sync ledger), if present.
pub fn anchor_map_json(item: &Item) -> Option<&str> {
    payload_str(item, "anchor_map_json")
}

/// Number of labeled paragraphs at last mirror update.
pub fn paragraph_count(item: &Item) -> Option<i64> {
    match item.payload.get("paragraph_count") {
        Some(Value::Int(n)) => Some(*n),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn throughline_schema_registers() {
        let mut reg = SchemaRegistry::new();
        register_throughline_schema(&mut reg);
        assert!(reg.get("throughline").is_some());
    }

    #[test]
    fn throughline_schema_required_fields() {
        let s = throughline_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert_eq!(required, vec!["title", "document_ref"]);
    }

    #[test]
    fn throughline_schema_expected_edges() {
        let s = throughline_schema();
        assert!(s.expected_edges.contains(&EdgeType::RelatesTo));
        assert!(s.expected_edges.contains(&EdgeType::Supersedes));
    }

    #[test]
    fn throughline_schema_serde_round_trip() {
        let s = throughline_schema();
        let json = serde_json::to_string_pretty(&s).unwrap();
        let back: Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(s, back);
    }

    #[test]
    fn narrates_edge_is_custom() {
        assert_eq!(narrates_edge(), EdgeType::Custom("narrates".into()));
    }

    #[test]
    fn typed_accessors_round_trip() {
        let mut payload = BTreeMap::new();
        payload.insert("title".to_string(), Value::String("Story".into()));
        payload.insert(
            "document_ref".to_string(),
            Value::String("6e2a0000-0000-0000-0000-000000000000".into()),
        );
        payload.insert("paragraph_count".to_string(), Value::Int(4));
        payload.insert("content_hash".to_string(), Value::String("sha256:abc".into()));
        let now = chrono::Utc::now();
        let item = Item {
            id: uuid::Uuid::new_v4(),
            schema: "throughline".into(),
            payload,
            created: now,
            modified: now,
            author: "human:tom@mac".into(),
            author_kind: crate::item::ActorKind::Human,
            logical_clock: 0,
            origin: None,
            canonical_id: None,
            tags: vec![],
            flag: None,
            is_read: false,
            is_starred: false,
            priority: Default::default(),
            visibility: Default::default(),
            message_type: None,
            produced_by: None,
            version: None,
            batch_id: None,
            references: vec![],
            parent: None,
        };
        assert_eq!(title(&item), Some("Story"));
        assert_eq!(
            document_ref(&item),
            Some("6e2a0000-0000-0000-0000-000000000000")
        );
        assert_eq!(paragraph_count(&item), Some(4));
        assert_eq!(content_hash(&item), Some("sha256:abc"));
        assert_eq!(body_content(&item), None);
    }

    #[test]
    fn store_pivot_fields_present_and_optional() {
        let s = throughline_schema();
        for name in ["body_content", "anchor_map_json"] {
            let field = s.fields.iter().find(|f| f.name == name);
            assert!(field.is_some(), "store-pivot field '{}' should exist", name);
            assert!(
                !field.unwrap().required,
                "store-pivot field '{}' must be optional (sidecar-only throughlines validate)",
                name
            );
        }
    }
}
