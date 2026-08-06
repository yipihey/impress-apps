//! Canonical schemas for provenance-preserving AI conversations.
//!
//! The records here deliberately separate durable research state from the
//! inference transport.  A phone can create/sync a conversation and user
//! message without being able to reach the model host; a Mac/server later
//! consumes the queued `task@1.0.0` and records the run and response.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

pub const CONVERSATION_SCHEMA: &str = "conversation@1.0.0";
pub const CONTENT_BLOB_SCHEMA: &str = "content-blob@1.0.0";
pub const TOOL_INVOCATION_SCHEMA: &str = "tool-invocation@1.0.0";
pub const AI_IMPORT_LEDGER_SCHEMA: &str = "ai-import-ledger@1.0.0";

/// A durable research conversation rendered primarily by impart.
pub fn conversation_schema() -> Schema {
    Schema {
        id: CONVERSATION_SCHEMA.into(),
        name: "Conversation".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("title"),
            required_string("state"),
            optional_string("summary"),
            optional_string("system_prompt"),
            optional_string("provider"),
            optional_string("model"),
            field("temperature", FieldType::Float, false),
            field("max_tokens", FieldType::Int, false),
            field("thinking", FieldType::Bool, false),
            field("web_access", FieldType::Bool, false),
            field("enabled_tools", FieldType::StringArray, false),
            field("last_activity_at", FieldType::DateTime, false),
        ],
        expected_edges: vec![EdgeType::Contains, EdgeType::RelatesTo],
        inherits: None,
    }
}

/// Metadata for immutable, content-addressed multimodal bytes.
///
/// The item and its provenance sync through the graph store. `storage_kind`
/// and `locator` identify the byte transport (local CAS today, CloudKit asset
/// or another user-controlled store later) without putting large base64 blobs
/// in CloudKit's size-limited `payload_json`.
pub fn content_blob_schema() -> Schema {
    Schema {
        id: CONTENT_BLOB_SCHEMA.into(),
        name: "Content Blob".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("sha256"),
            required_string("mime_type"),
            field("byte_length", FieldType::Int, true),
            required_string("storage_kind"),
            optional_string("locator"),
            optional_string("file_name"),
            optional_string("availability"),
            field("width", FieldType::Int, false),
            field("height", FieldType::Int, false),
            field("duration_ms", FieldType::Int, false),
        ],
        expected_edges: vec![
            EdgeType::DerivedFrom,
            EdgeType::Attaches,
            EdgeType::Supersedes,
        ],
        inherits: None,
    }
}

/// One auditable invocation of SciX, an Impress MCP tool, web retrieval, or
/// another capability during an AI run.
pub fn tool_invocation_schema() -> Schema {
    Schema {
        id: TOOL_INVOCATION_SCHEMA.into(),
        name: "Tool Invocation".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("tool"),
            required_string("provider"),
            required_string("state"),
            field("arguments", FieldType::Object, true),
            field("result", FieldType::Object, false),
            optional_string("result_summary"),
            optional_string("error"),
            field("started_at", FieldType::DateTime, false),
            field("finished_at", FieldType::DateTime, false),
            field("duration_ms", FieldType::Int, false),
        ],
        expected_edges: vec![
            EdgeType::OperatesOn,
            EdgeType::DerivedFrom,
            EdgeType::ProducedBy,
        ],
        inherits: None,
    }
}

/// One atomic, restart-safe import receipt for a legacy conversation.
///
/// The source content hash makes the receipt stronger than a "ran once"
/// boolean: a later import can distinguish an unchanged source row from a
/// conversation that changed after its first migration.
pub fn ai_import_ledger_schema() -> Schema {
    Schema {
        id: AI_IMPORT_LEDGER_SCHEMA.into(),
        name: "AI Import Ledger".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("source_kind"),
            required_string("source_database_id"),
            required_string("source_conversation_id"),
            field("source_revision", FieldType::Int, true),
            required_string("source_content_hash"),
            required_string("imported_conversation_id"),
            required_string("state"),
            field("imported_at", FieldType::DateTime, true),
        ],
        expected_edges: vec![EdgeType::DerivedFrom, EdgeType::RelatesTo],
        inherits: None,
    }
}

pub fn register_ai_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(conversation_schema())
        .expect("conversation@1.0.0 schema registration");
    registry
        .register(content_blob_schema())
        .expect("content-blob@1.0.0 schema registration");
    registry
        .register(tool_invocation_schema())
        .expect("tool-invocation@1.0.0 schema registration");
    registry
        .register(ai_import_ledger_schema())
        .expect("ai-import-ledger@1.0.0 schema registration");
}

fn required_string(name: &str) -> FieldDef {
    field(name, FieldType::String, true)
}

fn optional_string(name: &str) -> FieldDef {
    field(name, FieldType::String, false)
}

fn field(name: &str, field_type: FieldType, required: bool) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type,
        required,
        description: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ai_schemas_register_with_canonical_refs() {
        let mut registry = SchemaRegistry::new();
        register_ai_schemas(&mut registry);
        assert_eq!(conversation_schema().id, CONVERSATION_SCHEMA);
        assert_eq!(content_blob_schema().id, CONTENT_BLOB_SCHEMA);
        assert_eq!(tool_invocation_schema().id, TOOL_INVOCATION_SCHEMA);
        assert_eq!(registry.list().len(), 4);
    }

    #[test]
    fn blobs_are_metadata_not_inline_bytes() {
        let schema = content_blob_schema();
        let fields: Vec<&str> = schema
            .fields
            .iter()
            .map(|field| field.name.as_str())
            .collect();
        assert!(fields.contains(&"sha256"));
        assert!(fields.contains(&"storage_kind"));
        assert!(!fields.contains(&"data"));
        assert!(!fields.contains(&"base64"));
    }
}
