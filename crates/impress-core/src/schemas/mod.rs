pub mod ai;
pub mod artifact;
pub mod bibliography;
pub mod citation_usage;
pub mod collection;
pub mod communication;
pub mod document;
pub mod git_project;
pub mod implore;
pub mod knowledge_objects;
pub mod manuscript;
pub mod manuscript_bundle_manifest;
pub mod manuscript_collection;
pub mod manuscript_revision;
pub mod manuscript_section;
pub mod manuscript_submission;
pub mod plot_spec;
pub mod source;
pub mod task;
pub mod throughline;
pub mod veusz_plot;
pub mod watched_folder;

pub use ai::{
    register_ai_schemas, AI_IMPORT_LEDGER_SCHEMA, CONTENT_BLOB_SCHEMA, CONVERSATION_SCHEMA,
    TOOL_INVOCATION_SCHEMA,
};
pub use artifact::register_artifact_schemas;
pub use bibliography::register_bibliography_schemas;
pub use citation_usage::register_citation_usage_schema;
pub use collection::register_collection_schema;
pub use communication::register_communication_schemas;
pub use document::register_document_schemas;
pub use git_project::register_git_project_schemas;
pub use implore::register_implore_schemas;
pub use knowledge_objects::register_knowledge_object_schemas;
pub use manuscript::register_manuscript_schema;
pub use manuscript_collection::register_manuscript_collection_schema;
pub use manuscript_revision::register_manuscript_revision_schema;
pub use manuscript_section::register_imprint_schemas;
pub use manuscript_submission::register_manuscript_submission_schema;
pub use plot_spec::register_plot_spec_schema;
pub use source::{
    register_source_schemas, CONTENT_CHUNK_SCHEMA, EXTRACTION_RUN_SCHEMA, FIGURE_REGION_SCHEMA,
    SOURCE_CITATION_SCHEMA,
};
pub use task::{
    register_task_schemas, register_task_schemas_if_absent, AGENT_RUN_SCHEMA, TASK_SCHEMA,
};
pub use throughline::register_throughline_schema;
pub use veusz_plot::register_veusz_plot_schema;
pub use watched_folder::{
    register_watched_folder_schemas, FILE_STATES, FILE_STATE_MISSING, FILE_STATE_PRESENT,
    VOLUME_STATES, VOLUME_STATE_INDEXED, VOLUME_STATE_SCAN_ON_DEMAND, VOLUME_STATE_UNAVAILABLE,
    VOLUME_STATE_UNINDEXED, WATCHED_FILE_SCHEMA, WATCHED_FOLDER_SCHEMA,
};

/// Register all canonical impress-core schemas into the registry.
///
/// This must be called first at app startup, before any domain-specific schema
/// registrations. The order within this function follows the dependency graph:
/// base schemas before derived schemas (e.g., chat-message before email-message).
pub fn register_core_schemas(registry: &mut crate::registry::SchemaRegistry) {
    register_ai_schemas(registry);
    register_bibliography_schemas(registry);
    register_communication_schemas(registry);
    register_task_schemas(registry);
    register_document_schemas(registry);
    register_git_project_schemas(registry);
    register_artifact_schemas(registry);
    // NO operation schema here. `sqlite_store` writes the operation journal as
    // `core/operation`, whose ONE definition lives in imbib-core
    // (`unified::schemas::core_operation_schema`). This function used to
    // register a SECOND, differently-shaped `impress/operation` that nothing
    // has ever written or read — retired in WP C4 along with its
    // `registeredButUnwritten` manifest entry. See schema-refs.json's note on
    // `core/operation`.
    register_implore_schemas(registry);
    register_imprint_schemas(registry);
    register_citation_usage_schema(registry);
    // Journal pipeline schemas (per ADR-0011 / ADR-0012). Order matters:
    // manuscript-submission inherits from task, so task must precede it.
    register_manuscript_schema(registry);
    register_manuscript_revision_schema(registry);
    register_manuscript_submission_schema(registry);
    register_manuscript_collection_schema(registry);
    // Generic collection kernel (ADR-0022 D1): one schema for every record
    // kind, `kind_scope: "any"` for mixed collections.
    register_collection_schema(registry);
    register_veusz_plot_schema(registry);
    register_plot_spec_schema(registry);
    register_source_schemas(registry);
    register_knowledge_object_schemas(registry);
    // Throughline (ADR-0016): narrative companion documents. Depends on
    // nothing; registered after manuscript for reading order only.
    register_throughline_schema(registry);
    // Watched folders and their discovered files (ADR-0023 D2/D4). Depends on
    // nothing — the record kinds a folder ingests are named by `kind_scope`,
    // not by an inherits edge.
    register_watched_folder_schemas(registry);
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
        assert!(
            registry.get("bibliography-entry").is_some(),
            "bibliography-entry not registered"
        );
        assert!(
            registry.get("chat-message").is_some(),
            "chat-message not registered"
        );
        assert!(
            registry.get("email-message").is_some(),
            "email-message not registered"
        );
        // VERSIONED (WP C4): the ids are the refs the kernel writes and
        // `ready_tasks` selects. `registry.get("task")` is now correctly None.
        assert!(registry.get(TASK_SCHEMA).is_some(), "task not registered");
        assert!(
            registry.get(AGENT_RUN_SCHEMA).is_some(),
            "agent-run not registered"
        );
        assert!(
            registry.get("task").is_none() && registry.get("agent-run").is_none(),
            "the bare spellings are retired — nothing writes them"
        );
        assert!(
            registry.get("annotation").is_some(),
            "annotation not registered"
        );
        assert!(
            registry.get("git-project").is_some(),
            "git-project not registered"
        );
        assert!(
            registry.get("manuscript-section").is_some(),
            "manuscript-section not registered"
        );
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
        let email = registry
            .get("email-message")
            .expect("email-message not found");
        assert_eq!(email.inherits, Some("chat-message".into()));
    }
}
