use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for chat messages — the base conversational type.
pub fn chat_message_schema() -> Schema {
    Schema {
        id: "chat-message".into(),
        name: "Chat Message".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("body"),
            optional_string("subject"),
            optional_string("format"),
        ],
        expected_edges: vec![EdgeType::InResponseTo, EdgeType::Attaches],
        inherits: None,
    }
}

/// Schema for email messages — extends chat-message with email envelope fields.
pub fn email_message_schema() -> Schema {
    Schema {
        id: "email-message".into(),
        name: "Email Message".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("subject"),
            required_string("body"),
            required_string("from"),
            field("to", FieldType::StringArray, false),
            field("cc", FieldType::StringArray, false),
            optional_string("message_id"),
            optional_string("thread_id"),
        ],
        expected_edges: vec![EdgeType::InResponseTo, EdgeType::Discusses],
        inherits: Some("chat-message".into()),
    }
}

/// Schema for a mail account (Stage 0 of the GUI unification — impart's
/// account/folder/message hierarchy moves into the item store as a parent
/// chain: message.parent = folder, folder.parent = account).
pub fn mail_account_schema() -> Schema {
    Schema {
        id: "mail-account".into(),
        name: "Mail Account".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("name"),
            optional_string("address"),
            optional_string("provider"),
            field("sort_order", FieldType::Int, false),
        ],
        expected_edges: vec![EdgeType::Contains],
        inherits: None,
    }
}

/// Schema for a mail folder. Hierarchy lives on the item envelope (`parent` =
/// owning account, or another folder for nesting); `role` marks the
/// well-known folders (inbox | sent | drafts | trash | archive | spam).
pub fn mail_folder_schema() -> Schema {
    Schema {
        id: "mail-folder".into(),
        name: "Mail Folder".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("name"),
            optional_string("role"),
            optional_string("remote_path"),
            field("sort_order", FieldType::Int, false),
        ],
        expected_edges: vec![EdgeType::Contains],
        inherits: None,
    }
}

/// Register all communication schemas into the registry.
///
/// `chat-message` must be registered before `email-message` because the latter
/// inherits from the former. The registry resolves the parent by ID at validation
/// time, but registering in dependency order is conventional.
pub fn register_communication_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(chat_message_schema())
        .expect("chat-message schema registration");
    registry
        .register(email_message_schema())
        .expect("email-message schema registration");
    registry
        .register(mail_account_schema())
        .expect("mail-account schema registration");
    registry
        .register(mail_folder_schema())
        .expect("mail-folder schema registration");
}

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
    fn communication_schemas_register() {
        let mut reg = SchemaRegistry::new();
        register_communication_schemas(&mut reg);
        assert!(reg.get("chat-message").is_some());
        assert!(reg.get("email-message").is_some());
    }

    #[test]
    fn chat_message_required_body() {
        let schema = chat_message_schema();
        let body_field = schema.fields.iter().find(|f| f.name == "body");
        assert!(body_field.is_some(), "chat-message missing body field");
        assert!(body_field.unwrap().required, "body should be required");
    }

    #[test]
    fn email_message_inherits_chat_message() {
        let schema = email_message_schema();
        assert_eq!(schema.inherits, Some("chat-message".into()));
    }

    #[test]
    fn email_message_required_fields() {
        let schema = email_message_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"subject"), "missing required subject");
        assert!(required.contains(&"body"), "missing required body");
        assert!(required.contains(&"from"), "missing required from");
    }

    #[test]
    fn email_message_has_expected_edges() {
        let schema = email_message_schema();
        assert!(schema.expected_edges.contains(&EdgeType::InResponseTo));
        assert!(schema.expected_edges.contains(&EdgeType::Discusses));
    }
}
