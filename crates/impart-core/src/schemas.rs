//! Schema definitions for impart message types.
//!
//! Registers `chat-message@1.0.0` and `email-message@1.0.0` schemas in the
//! impress-core registry so impart messages can be stored as unified items
//! alongside papers, artifacts, and other research objects.

use impress_core::reference::EdgeType;
use impress_core::registry::SchemaRegistry;
use impress_core::schema::{FieldDef, FieldType, Schema};

// MARK: - Field helpers

fn required_string(name: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type: FieldType::String,
        required: true,
        description: None,
    }
}

fn optional_string(name: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type: FieldType::String,
        required: false,
        description: None,
    }
}

fn optional_string_array(name: &str) -> FieldDef {
    FieldDef {
        name: name.into(),
        field_type: FieldType::StringArray,
        required: false,
        description: None,
    }
}

// MARK: - Schemas

/// Schema for chat/IM messages (`chat-message@1.0.0`).
///
/// Base message schema. Email inherits from this.
///
/// Required fields:
/// - `body`: Message body text (full-text-searchable)
/// - `from`: Sender identifier (name, handle, or address)
///
/// Optional fields:
/// - `channel`: Channel, room, or mailbox name (e.g., "#general", "INBOX")
/// - `thread_id`: Opaque thread identifier for grouping replies
pub fn chat_message_schema() -> Schema {
    Schema {
        id: "chat-message".into(),
        name: "Chat Message".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("body"),
            required_string("from"),
            optional_string("channel"),
            optional_string("thread_id"),
        ],
        expected_edges: vec![EdgeType::InResponseTo, EdgeType::Discusses],
        inherits: None,
    }
}

/// Schema for email messages (`email-message@1.0.0`).
///
/// Extends `chat-message@1.0.0` with email-specific fields.
///
/// Required fields (from chat-message):
/// - `body`: Message body text (full-text-searchable)
/// - `from`: Sender address
///
/// Additional required fields:
/// - `subject`: Email subject (full-text-searchable)
///
/// Optional fields (from chat-message):
/// - `channel`: Mailbox name (e.g., "INBOX")
/// - `thread_id`: JWZ thread ID
///
/// Additional optional fields:
/// - `to`: Recipient addresses (array)
/// - `cc`: CC addresses (array)
/// - `message_id`: RFC 2822 Message-ID header value
pub fn email_message_schema() -> Schema {
    Schema {
        id: "email-message".into(),
        name: "Email Message".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("subject"),
            optional_string_array("to"),
            optional_string_array("cc"),
            optional_string("message_id"),
        ],
        expected_edges: vec![EdgeType::InResponseTo, EdgeType::Discusses],
        inherits: Some("chat-message".into()),
    }
}

// MARK: - Registration

/// Register all impart schemas in a [`SchemaRegistry`].
///
/// Must be called before validating or storing any chat/email items.
/// Registers in dependency order: base schemas first.
pub fn register_impart_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(chat_message_schema())
        .expect("chat-message schema registration");
    registry
        .register(email_message_schema())
        .expect("email-message schema registration");
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_all_impart_schemas() {
        let mut reg = SchemaRegistry::new();
        register_impart_schemas(&mut reg);

        assert!(reg.get("chat-message").is_some());
        assert!(reg.get("email-message").is_some());
    }

    #[test]
    fn chat_message_has_required_fields() {
        let schema = chat_message_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"body"), "body must be required");
        assert!(required.contains(&"from"), "from must be required");
    }

    #[test]
    fn email_message_inherits_chat_message() {
        let schema = email_message_schema();
        assert_eq!(schema.inherits, Some("chat-message".into()));
    }

    #[test]
    fn email_message_has_required_subject() {
        let schema = email_message_schema();
        let has_required_subject = schema
            .fields
            .iter()
            .any(|f| f.name == "subject" && f.required);
        assert!(has_required_subject, "subject must be a required field");
    }

    #[test]
    fn email_message_has_expected_edges() {
        let schema = email_message_schema();
        assert!(schema.expected_edges.contains(&EdgeType::InResponseTo));
        assert!(schema.expected_edges.contains(&EdgeType::Discusses));
    }

    #[test]
    fn chat_message_has_expected_edges() {
        let schema = chat_message_schema();
        assert!(schema.expected_edges.contains(&EdgeType::InResponseTo));
        assert!(schema.expected_edges.contains(&EdgeType::Discusses));
    }

    #[test]
    fn to_and_cc_are_string_arrays() {
        let schema = email_message_schema();
        let to_field = schema.fields.iter().find(|f| f.name == "to").unwrap();
        let cc_field = schema.fields.iter().find(|f| f.name == "cc").unwrap();
        assert_eq!(to_field.field_type, FieldType::StringArray);
        assert_eq!(cc_field.field_type, FieldType::StringArray);
        assert!(!to_field.required);
        assert!(!cc_field.required);
    }
}
