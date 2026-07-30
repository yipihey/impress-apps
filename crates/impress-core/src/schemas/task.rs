//! The task / agent-run schemas — ONE definition each, suite-wide (WP C4).
//!
//! # Why the ids carry `@1.0.0`
//!
//! These two kinds had THREE live spellings each until C4: a bare `task` /
//! `agent-run` registered here, an `impel/task` / `impel/agent-run` registered
//! by impel-core, and the versioned `task@1.0.0` / `agent-run@1.0.0` the
//! kernel actually writes and reads. The versioned pair won, on two grounds
//! that both point the same way:
//!
//! * **Scheduler continuity.** [`crate::sqlite_store::SqliteItemStore::ready_tasks`]
//!   selects `task@1.0.0`. It is the one spelling with a live queue behind it,
//!   so choosing it means no task that is scheduled today stops being
//!   scheduled — the migration only ever ADDS rows to the queue's reach, never
//!   removes any.
//! * **User-data safety.** `task@1.0.0` / `agent-run@1.0.0` is what
//!   `impel-core`'s kernel has been writing (`task_spawn::create_task_dag`,
//!   `TaskStoreApi::record_agent_run`), so it is the spelling under which the
//!   BULK of real rows already sit. The other two spellings were a registry
//!   entry nothing wrote (bare) and a Swift mirror writer (`impel/…`). Moving
//!   the many onto the few would have been the larger rewrite over live data.
//!
//! ADR-0005 §1 named the versioned refs canonical from the start and ADR-0015
//! D5 deprecated the `impel/…` mirrors; C4 is where the tree caught up.
//!
//! # Why the fields are a union
//!
//! impel-core carried a second, richer definition of both kinds. Two schema
//! definitions for one id drift (CLAUDE.md), so C4 collapsed them here and
//! `impel_core::schemas::register_impel_schemas` now delegates. The fields
//! below are the union of what the two writers actually write — the kernel's
//! `task_kind` / `assigned_to` / `attempts` / `output_schema` / `error` and the
//! Swift bridge's `source_app` / `external_id` — and nothing more. impel's
//! `due_date` and `assignee` are deliberately NOT carried over: no writer has
//! ever emitted them, and a field in a schema nobody writes is the same trap as
//! a schema nobody writes.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// The canonical task ref. Written by `impel_core::task_spawn::create_task_dag`
/// and impel's `SharedTaskBridge`; selected by `ready_tasks`.
pub const TASK_SCHEMA: &str = "task@1.0.0";

/// The canonical agent-run ref. Written by
/// `impel_core::TaskStoreApi::record_agent_run` and impel's `SharedTaskBridge`.
pub const AGENT_RUN_SCHEMA: &str = "agent-run@1.0.0";

/// Schema for task items — units of work assigned to humans or agents.
pub fn task_schema() -> Schema {
    Schema {
        id: TASK_SCHEMA.into(),
        name: "Task".into(),
        version: "1.0.0".into(),
        fields: vec![
            described(
                required_string("title"),
                "Short human-readable description of the task",
            ),
            described(
                required_string("state"),
                "Lifecycle state. Canonical (ADR-0005 §1): pending | running | \
                 done | failed | cancelled. Rows mirrored from impel's GRDB \
                 store carry the foreign vocabulary (queued | completed), which \
                 `TaskState::parse_compat` accepts at the boundary.",
            ),
            optional_string("description"),
            // The scheduler's executor dispatch key, and — since C4 — the
            // gate `ready_tasks` uses to decide a task is DISPATCHABLE.
            described(
                optional_string("task_kind"),
                "Executor dispatch key (`Scheduler::register`). A task without \
                 one is not schedulable: see `ready_tasks`.",
            ),
            optional_string("assigned_to"),
            field("attempts", FieldType::Int, false),
            field("due_at", FieldType::Int, false),
            optional_string("output_schema"),
            optional_string("error"),
            described(
                optional_string("source_app"),
                "Originating app identifier (e.g. \"impel\", \"email\", \"api\")",
            ),
            described(
                optional_string("external_id"),
                "Stable id of the AUTHORITATIVE record this row mirrors (impel's \
                 GRDB task id). Present ⇒ some other system owns this task's \
                 lifecycle.",
            ),
        ],
        expected_edges: vec![
            EdgeType::DependsOn,
            EdgeType::ProducedBy,
            EdgeType::OperatesOn,
            EdgeType::Custom("triggered-by".into()),
        ],
        inherits: None,
    }
}

/// Schema for agent-run items — records of a single AI agent execution.
pub fn agent_run_schema() -> Schema {
    Schema {
        id: AGENT_RUN_SCHEMA.into(),
        name: "Agent Run".into(),
        version: "1.0.0".into(),
        fields: vec![
            described(
                required_string("agent_id"),
                "Logical agent identifier (e.g. \"counsel\", \"librarian\")",
            ),
            described(
                required_string("model"),
                "LLM model identifier used for this run",
            ),
            described(
                required_string("prompt_hash"),
                "Truncated hash of the system prompt for provenance tracing",
            ),
            optional_string("result_summary"),
            described(
                field("token_count", FieldType::Int, false),
                "Total tokens consumed (input + output)",
            ),
            described(
                field("duration_ms", FieldType::Int, false),
                "Wall-clock duration of the run in milliseconds",
            ),
            described(
                field("tool_calls", FieldType::StringArray, false),
                "Names of tools invoked during this run, in order",
            ),
            described(
                optional_string("status"),
                "Terminal status: completed | failed | cancelled",
            ),
            described(
                optional_string("finish_reason"),
                "Why the loop terminated: completed | max_rounds_reached | error",
            ),
            described(
                field("round_number", FieldType::Int, false),
                "Which tool-use round within the containing task this run is",
            ),
        ],
        expected_edges: vec![
            EdgeType::ProducedBy,
            EdgeType::DerivedFrom,
            EdgeType::OperatesOn,
        ],
        inherits: None,
    }
}

/// Register all task-related schemas into the registry.
///
/// This is the ONLY registration of these two ids in the workspace;
/// `impel_core::schemas::register_impel_schemas` delegates here.
pub fn register_task_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(task_schema())
        .expect("task@1.0.0 schema registration");
    registry
        .register(agent_run_schema())
        .expect("agent-run@1.0.0 schema registration");
}

/// Register the pair only if it is absent, so `register_core_schemas` and
/// `register_impel_schemas` can both run against one registry in either order
/// without the duplicate-id error. Two entry points registering ONE definition
/// is fine; the thing C4 removed was two definitions.
pub fn register_task_schemas_if_absent(registry: &mut SchemaRegistry) {
    if registry.get(TASK_SCHEMA).is_none() && registry.get(AGENT_RUN_SCHEMA).is_none() {
        register_task_schemas(registry);
    }
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

fn described(mut def: FieldDef, description: &str) -> FieldDef {
    def.description = Some(description.into());
    def
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_schemas_register() {
        let mut reg = SchemaRegistry::new();
        register_task_schemas(&mut reg);
        assert!(reg.get(TASK_SCHEMA).is_some());
        assert!(reg.get(AGENT_RUN_SCHEMA).is_some());
    }

    /// The ids ARE the refs writers emit — the whole point of C4. A rename
    /// here without a manifest edit is caught by
    /// `tests/schema_ref_manifest.rs`; a rename that forgets the constants is
    /// caught right here.
    #[test]
    fn ids_are_the_canonical_versioned_refs() {
        assert_eq!(task_schema().id, "task@1.0.0");
        assert_eq!(agent_run_schema().id, "agent-run@1.0.0");
        assert_eq!(TASK_SCHEMA, task_schema().id);
        assert_eq!(AGENT_RUN_SCHEMA, agent_run_schema().id);
    }

    #[test]
    fn task_schema_required_fields() {
        let schema = task_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"title"), "missing required title");
        assert!(required.contains(&"state"), "missing required state");
        assert_eq!(
            required.len(),
            2,
            "only title/state are required — a mirrored row from impel's bridge \
             writes exactly those two plus optionals, and must validate"
        );
    }

    /// Both writers' payload keys must be declared, or `validate` reports a
    /// real row as carrying unknown fields.
    #[test]
    fn task_schema_covers_both_writers_payloads() {
        let schema = task_schema();
        let names: Vec<&str> = schema.fields.iter().map(|f| f.name.as_str()).collect();
        // impel-core kernel (task_spawn::create_task_dag + Scheduler).
        for key in [
            "title",
            "task_kind",
            "state",
            "description",
            "output_schema",
            "assigned_to",
            "attempts",
            "error",
        ] {
            assert!(names.contains(&key), "kernel writes {key:?}");
        }
        // impel Swift SharedTaskBridge.
        for key in ["title", "state", "description", "source_app", "external_id"] {
            assert!(names.contains(&key), "SharedTaskBridge writes {key:?}");
        }
    }

    #[test]
    fn agent_run_schema_required_fields() {
        let schema = agent_run_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"agent_id"), "missing required agent_id");
        assert!(required.contains(&"model"), "missing required model");
        assert!(
            required.contains(&"prompt_hash"),
            "missing required prompt_hash"
        );
    }

    /// The bridge's run payload (`round_number`, `tool_calls`, `status`,
    /// `finish_reason`) and the kernel's (`result_summary`, `token_count`,
    /// `duration_ms`) are both declared — this is the impel-core union folded
    /// in when its duplicate definition was deleted.
    #[test]
    fn agent_run_schema_covers_both_writers_payloads() {
        let schema = agent_run_schema();
        let names: Vec<&str> = schema.fields.iter().map(|f| f.name.as_str()).collect();
        for key in [
            "agent_id",
            "model",
            "prompt_hash",
            "result_summary",
            "token_count",
            "duration_ms",
            "tool_calls",
            "status",
            "finish_reason",
            "round_number",
        ] {
            assert!(names.contains(&key), "a writer emits {key:?}");
        }
    }

    #[test]
    fn task_schema_has_expected_edges() {
        let schema = task_schema();
        assert!(schema.expected_edges.contains(&EdgeType::DependsOn));
        assert!(schema.expected_edges.contains(&EdgeType::ProducedBy));
        assert!(schema.expected_edges.contains(&EdgeType::OperatesOn));
        // Carried over from impel-core's definition: spawn rules link the
        // triggering item this way.
        assert!(schema
            .expected_edges
            .contains(&EdgeType::Custom("triggered-by".into())));
    }

    #[test]
    fn agent_run_schema_has_expected_edges() {
        let schema = agent_run_schema();
        assert!(schema.expected_edges.contains(&EdgeType::ProducedBy));
        assert!(schema.expected_edges.contains(&EdgeType::DerivedFrom));
        // impel-core's definition also expected OperatesOn (task ← run).
        assert!(schema.expected_edges.contains(&EdgeType::OperatesOn));
    }

    #[test]
    fn registering_twice_via_the_absent_guard_is_a_no_op() {
        let mut reg = SchemaRegistry::new();
        register_task_schemas(&mut reg);
        let before = reg.list().len();
        // This is `register_impel_schemas` running after
        // `register_core_schemas` — it must not panic.
        register_task_schemas_if_absent(&mut reg);
        assert_eq!(reg.list().len(), before);
    }
}
