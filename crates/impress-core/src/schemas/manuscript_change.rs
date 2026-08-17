use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// The exact `items.schema_ref` of a manuscript change chunk. Versioned, and
/// the ONLY spelling — copy it, never retype it (root CLAUDE.md § schema refs).
pub const MANUSCRIPT_CHANGE_SCHEMA_REF: &str = "manuscript-change@1.0.0";

/// Schema for the `manuscript-change@1.0.0` item type (ADR-0027 D3).
///
/// One immutable chunk of Automerge changes for a manuscript body — the unit
/// the document is persisted and synchronised in. `kind = "change"` chunks
/// carry the raw bytes of the changes one commit produced; `kind =
/// "snapshot"` chunks carry a full `save()` written by compaction (D5).
/// Loading a document is set-union: every chunk for the manuscript, in any
/// order, duplicates included — Automerge de-duplicates by change hash.
///
/// The envelope `parent` is the manuscript (indexed; the load query is
/// `HasParent`); `parent_manuscript_ref` restates it in the payload for
/// readers that only see JSON. Payload-mutating operations on this kind are
/// rejected in `apply_operation()` exactly as for `manuscript-revision`.
pub fn manuscript_change_schema() -> Schema {
    Schema {
        id: MANUSCRIPT_CHANGE_SCHEMA_REF.into(),
        name: "Manuscript Change".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "parent_manuscript_ref".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("ItemId of the manuscript this chunk belongs to.".into()),
            },
            FieldDef {
                name: "kind".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "\"change\" (raw changes from one commit) or \"snapshot\" (a full \
                     document save written by compaction)."
                        .into(),
                ),
            },
            FieldDef {
                name: "heads".into(),
                field_type: FieldType::StringArray,
                required: true,
                description: Some(
                    "Hex change hashes: the document heads AFTER this chunk's changes \
                     (informational; loading never depends on it)."
                        .into(),
                ),
            },
            FieldDef {
                name: "bytes_b64".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Base64 of the Automerge bytes.".into()),
            },
            FieldDef {
                name: "byte_length".into(),
                field_type: FieldType::Int,
                required: true,
                description: Some("Decoded byte length, for storage accounting.".into()),
            },
            FieldDef {
                name: "recovers_hash".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Recovery chunks only: the body_content_hash this change folded in. \
                     A replica that sees a chunk recovering the hash it is about to \
                     recover does not mint a second one (D4)."
                        .into(),
                ),
            },
            FieldDef {
                name: "actor".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Automerge actor id (hex) of the changes, or \"genesis\"/\"recovery\" \
                     for the deterministic derived changes of D4."
                        .into(),
                ),
            },
        ],
        expected_edges: vec![],
        inherits: None,
    }
}

pub fn register_manuscript_change_schema(registry: &mut SchemaRegistry) {
    registry
        .register(manuscript_change_schema())
        .expect("manuscript-change schema registration");
}
