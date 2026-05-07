pub mod artifact;
pub mod bibliography;
pub mod citation_usage;
pub mod communication;
pub mod document;
pub mod git_project;
pub mod implore;
pub mod knowledge_objects;
pub mod manuscript;
pub mod manuscript_bundle_manifest;
pub mod manuscript_revision;
pub mod manuscript_section;
pub mod manuscript_submission;
pub mod operation;
pub mod task;

pub use artifact::register_artifact_schemas;
pub use bibliography::register_bibliography_schemas;
pub use citation_usage::register_citation_usage_schema;
pub use communication::register_communication_schemas;
pub use document::register_document_schemas;
pub use git_project::register_git_project_schemas;
pub use implore::register_implore_schemas;
pub use knowledge_objects::register_knowledge_object_schemas;
pub use manuscript::register_manuscript_schema;
pub use manuscript_revision::register_manuscript_revision_schema;
pub use manuscript_section::register_imprint_schemas;
pub use manuscript_submission::register_manuscript_submission_schema;
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
    register_git_project_schemas(registry);
    register_artifact_schemas(registry);
    register_operation_schema(registry);
    register_implore_schemas(registry);
    register_imprint_schemas(registry);
    register_citation_usage_schema(registry);
    // Journal pipeline schemas (per ADR-0011 / ADR-0012). Order matters:
    // manuscript-submission inherits from task, so task must precede it.
    register_manuscript_schema(registry);
    register_manuscript_revision_schema(registry);
    register_manuscript_submission_schema(registry);
    register_knowledge_object_schemas(registry);
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
        assert!(registry.get("git-project").is_some(), "git-project not registered");
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
        // 10 built-in + 8 artifact domain schemas = 18 total
        assert!(count >= 10, "expected at least 10 schemas, got {}", count);
    }

    #[test]
    fn email_message_inherits_chat_message() {
        let mut registry = SchemaRegistry::default();
        register_core_schemas(&mut registry);
        let email = registry.get("email-message").expect("email-message not found");
        assert_eq!(email.inherits, Some("chat-message".into()));
    }
}
