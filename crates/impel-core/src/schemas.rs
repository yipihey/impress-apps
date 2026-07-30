//! impel's schema registration — a DELEGATION since WP C4.
//!
//! This module used to define `impel/task` and `impel/agent-run`: a second,
//! richer definition of the two kinds impress-core already had (as bare `task`
//! / `agent-run`), while impel's own kernel wrote a third spelling,
//! `task@1.0.0` / `agent-run@1.0.0`. Three spellings and two field lists for
//! one kind is the drift CLAUDE.md warns about, and it had already produced
//! silent bugs in both directions:
//!
//! * `sqlite_store::ready_tasks` selects `task@1.0.0`, so tasks written by
//!   impel's Swift `SharedTaskBridge` as `impel/task` were invisible to the
//!   scheduler…
//! * …and `ImpelStoreAdapter` (impel's OWN GUI read path) queries
//!   `task@1.0.0`, so impel's window never showed them either.
//! * `SchemaRegistry::validate` could not validate a single kernel-written
//!   task, because no registry held the id the kernel writes.
//!
//! C4 converged on the versioned refs (see
//! `impress_core::schemas::task` for the decision and its rationale) and
//! collapsed the field lists into the union, so there is now exactly ONE
//! definition of each kind, in impress-core, next to the `ready_tasks` query
//! that consumes it. impel keeps this entry point because callers depend on it
//! and because "impel registers the schemas impel writes" is the honest
//! statement — it just no longer keeps a private copy of them.

use impress_core::registry::SchemaRegistry;
use impress_core::schema::Schema;
use impress_core::schemas::task;

/// The task schema impel writes — impress-core's, not a copy.
pub fn task_schema() -> Schema {
    task::task_schema()
}

/// The agent-run schema impel writes — impress-core's, not a copy.
pub fn agent_run_schema() -> Schema {
    task::agent_run_schema()
}

/// Register the schemas impel writes into a [`SchemaRegistry`].
///
/// Call this once at application startup before writing any items to the
/// shared impress-core store. Tolerant of a registry that already has them
/// (`register_core_schemas` registers the same two ids from the same
/// definition), so the two entry points compose in either order.
pub fn register_impel_schemas(registry: &mut SchemaRegistry) {
    task::register_task_schemas_if_absent(registry);
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use crate::task_store::{AGENT_RUN_SCHEMA, TASK_SCHEMA};

    #[test]
    fn register_all_impel_schemas() {
        let mut reg = SchemaRegistry::new();
        register_impel_schemas(&mut reg);
        assert!(reg.get(TASK_SCHEMA).is_some());
        assert!(reg.get(AGENT_RUN_SCHEMA).is_some());
    }

    /// The registry ids ARE the refs the kernel writes. This equality is the
    /// whole point of C4: before it, the registry said `impel/task` and the
    /// kernel wrote `task@1.0.0`, so `validate()` was a no-op for every task
    /// impel ever created.
    #[test]
    fn registered_ids_are_exactly_what_the_kernel_writes() {
        assert_eq!(task_schema().id, TASK_SCHEMA);
        assert_eq!(agent_run_schema().id, AGENT_RUN_SCHEMA);
    }

    /// The `impel/…` mirrors are gone (ADR-0015 D5's deprecation, executed).
    #[test]
    fn the_namespaced_mirrors_are_retired() {
        let mut reg = SchemaRegistry::new();
        register_impel_schemas(&mut reg);
        assert!(reg.get("impel/task").is_none());
        assert!(reg.get("impel/agent-run").is_none());
    }

    #[test]
    fn registering_after_core_schemas_does_not_panic() {
        let mut reg = SchemaRegistry::new();
        impress_core::schemas::register_core_schemas(&mut reg);
        register_impel_schemas(&mut reg);
        assert!(reg.get(TASK_SCHEMA).is_some());
    }

    #[test]
    fn task_schema_has_required_fields() {
        let schema = task_schema();
        let required: Vec<_> = schema.fields.iter().filter(|f| f.required).collect();
        let required_names: Vec<_> = required.iter().map(|f| f.name.as_str()).collect();
        assert!(
            required_names.contains(&"title"),
            "task schema missing required 'title'"
        );
        assert!(
            required_names.contains(&"state"),
            "task schema missing required 'state'"
        );
    }

    /// The fields impel used to declare privately survived the collapse — this
    /// is what stops the merge from being a silent field amputation.
    #[test]
    fn impels_own_payload_fields_survived_the_collapse() {
        let names: Vec<String> = task_schema()
            .fields
            .iter()
            .map(|f| f.name.clone())
            .collect();
        for key in ["source_app", "external_id", "description"] {
            assert!(names.iter().any(|n| n == key), "task lost {key:?}");
        }
        let run_names: Vec<String> = agent_run_schema()
            .fields
            .iter()
            .map(|f| f.name.clone())
            .collect();
        for key in ["tool_calls", "status", "finish_reason", "round_number"] {
            assert!(run_names.iter().any(|n| n == key), "agent-run lost {key:?}");
        }
    }

    #[test]
    fn agent_run_schema_has_required_fields() {
        let schema = agent_run_schema();
        let required: Vec<_> = schema.fields.iter().filter(|f| f.required).collect();
        let required_names: Vec<_> = required.iter().map(|f| f.name.as_str()).collect();
        assert!(
            required_names.contains(&"agent_id"),
            "agent-run schema missing required 'agent_id'"
        );
        assert!(
            required_names.contains(&"model"),
            "agent-run schema missing required 'model'"
        );
        assert!(
            required_names.contains(&"prompt_hash"),
            "agent-run schema missing required 'prompt_hash'"
        );
    }

    #[test]
    fn task_schema_has_expected_edges() {
        use impress_core::reference::EdgeType;
        let schema = task_schema();
        assert!(schema.expected_edges.contains(&EdgeType::DependsOn));
        assert!(schema
            .expected_edges
            .contains(&EdgeType::Custom("triggered-by".into())));
    }

    #[test]
    fn agent_run_schema_has_expected_edges() {
        use impress_core::reference::EdgeType;
        let schema = agent_run_schema();
        assert!(schema.expected_edges.contains(&EdgeType::ProducedBy));
        assert!(schema.expected_edges.contains(&EdgeType::OperatesOn));
    }
}
