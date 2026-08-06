//! Impart's registration entry point for the canonical communication schemas.
//!
//! Definitions live in `impress-core`. Keeping a second copy here previously
//! let the required fields and expected edges drift even though both crates
//! claimed to register the same `chat-message` and `email-message` refs.

use impress_core::registry::SchemaRegistry;

pub use impress_core::schemas::communication::{chat_message_schema, email_message_schema};

/// Register the two message schemas impart reads and writes.
///
/// This deliberately registers only the two impart-owned views, rather than
/// all communication schemas, so the manifest remains an exact description of
/// this entry point.
pub fn register_impart_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(chat_message_schema())
        .expect("chat-message schema registration");
    registry
        .register(email_message_schema())
        .expect("email-message schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;
    use impress_core::reference::EdgeType;

    #[test]
    fn registers_only_the_canonical_pair() {
        let mut registry = SchemaRegistry::new();
        register_impart_schemas(&mut registry);
        assert!(registry.get("chat-message").is_some());
        assert!(registry.get("email-message").is_some());
        assert_eq!(registry.list().len(), 2);
    }

    #[test]
    fn email_inherits_the_same_chat_definition() {
        let email = email_message_schema();
        assert_eq!(email.inherits, Some("chat-message".into()));
        assert!(email.expected_edges.contains(&EdgeType::Discusses));
    }

    #[test]
    fn chat_supports_ai_and_human_messages() {
        let chat = chat_message_schema();
        let fields: Vec<&str> = chat
            .fields
            .iter()
            .map(|field| field.name.as_str())
            .collect();
        for expected in ["body", "from", "role", "status", "model", "reasoning"] {
            assert!(fields.contains(&expected), "missing {expected}");
        }
    }
}
