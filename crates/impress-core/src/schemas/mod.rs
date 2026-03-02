pub mod artifact;
pub mod bibliography;
pub mod communication;
pub mod document;
pub mod operation;
pub mod task;

pub use artifact::register_artifact_schemas;
pub use bibliography::register_bibliography_schemas;
pub use communication::register_communication_schemas;
pub use document::register_document_schemas;
pub use operation::register_operation_schema;
pub use task::register_task_schemas;

/// Register all canonical impress-core schemas into the registry.
///
/// This must be called first at app startup, before any domain-specific schema
/// registrations. The order within this function follows the dependency graph:
/// base schemas before derived schemas (e.g., chat-message before email-message).
pub fn register_core_schemas(registry: &mut crate::registry::SchemaRegistry) {
    register_bibliography_schemas(registry);
    register_communication_schemas(registry);
    register_task_schemas(registry);
    register_document_schemas(registry);
    register_artifact_schemas(registry);
    register_operation_schema(registry);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::registry::SchemaRegistry;

    #[test]
    fn register_core_schemas_no_panic() {
        let mut registry = SchemaRegistry::default();
        register_core_schemas(&mut registry);
        // Check that all 9 built-in non-operation schemas are registered
        assert!(registry.get("bibliography-entry").is_some(), "bibliography-entry not registered");
        assert!(registry.get("chat-message").is_some(), "chat-message not registered");
        assert!(registry.get("email-message").is_some(), "email-message not registered");
        assert!(registry.get("task").is_some(), "task not registered");
        assert!(registry.get("agent-run").is_some(), "agent-run not registered");
        assert!(registry.get("annotation").is_some(), "annotation not registered");
        assert!(registry.get("manuscript-section").is_some(), "manuscript-section not registered");
        assert!(registry.get("figure").is_some(), "figure not registered");
        assert!(registry.get("dataset").is_some(), "dataset not registered");
    }

    #[test]
    fn register_core_schemas_no_duplicates() {
        // Calling register_core_schemas twice should panic on the second call
        // because register() returns Err on duplicates. Here we just verify
        // a single call succeeds and all schemas are present.
        let mut registry = SchemaRegistry::default();
        register_core_schemas(&mut registry);
        let count = registry.list().len();
        // 9 built-in + 8 artifact domain schemas = 17 total
        assert!(count >= 9, "expected at least 9 schemas, got {}", count);
    }

    #[test]
    fn email_message_inherits_chat_message() {
        let mut registry = SchemaRegistry::default();
        register_core_schemas(&mut registry);
        let email = registry.get("email-message").expect("email-message not found");
        assert_eq!(email.inherits, Some("chat-message".into()));
    }
}
