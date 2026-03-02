use impress_core::reference::EdgeType;
use impress_core::registry::SchemaRegistry;
use impress_core::schema::{FieldDef, FieldType, Schema};

// MARK: - Task Schema

/// Schema for tasks (user-facing work items submitted to the counsel engine).
///
/// A task captures a unit of AI-assisted work: its title, lifecycle state,
/// originating app, and a stable external ID for deduplication. Tasks are
/// linked to agent-runs via `DependsOn` edges and to source items (e.g.
/// emails, publications) via `Custom("triggered-by")` edges.
pub fn task_schema() -> Schema {
    Schema {
        id: "impel/task".into(),
        name: "Task".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "title".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Short human-readable description of the task".into()),
            },
            FieldDef {
                name: "state".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Lifecycle state: queued | running | completed | failed | cancelled".into(),
                ),
            },
            FieldDef {
                name: "description".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Full query text sent to the counsel agent".into()),
            },
            FieldDef {
                name: "due_date".into(),
                field_type: FieldType::DateTime,
                required: false,
                description: Some("ISO 8601 deadline, if any".into()),
            },
            FieldDef {
                name: "assignee".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Agent or persona responsible for executing the task".into()),
            },
            FieldDef {
                name: "source_app".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Originating app identifier (e.g. \"impel\", \"email\", \"api\")".into(),
                ),
            },
            FieldDef {
                name: "external_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Stable GRDB task ID for deduplication across stores".into(),
                ),
            },
        ],
        expected_edges: vec![
            EdgeType::DependsOn,
            EdgeType::Custom("triggered-by".into()),
        ],
        inherits: None,
    }
}

// MARK: - Agent Run Schema

/// Schema for AI agent execution runs (one record per `NativeAgentLoop` invocation).
///
/// Each agent run records provenance metadata: which model was used, how many
/// tokens were consumed, how long it took, which tools were called, and what
/// round of the loop this was. Runs are linked back to their parent task via an
/// `OperatesOn` edge so every LLM call is traceable from any sibling app.
pub fn agent_run_schema() -> Schema {
    Schema {
        id: "impel/agent-run".into(),
        name: "Agent Run".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "agent_id".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Logical agent identifier (e.g. \"counsel\", \"librarian\")".into(),
                ),
            },
            FieldDef {
                name: "model".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("LLM model identifier used for this run".into()),
            },
            FieldDef {
                name: "prompt_hash".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "Truncated hash of the system prompt for provenance tracing".into(),
                ),
            },
            FieldDef {
                name: "token_count".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some("Total tokens consumed (input + output)".into()),
            },
            FieldDef {
                name: "duration_ms".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some("Wall-clock duration of the run in milliseconds".into()),
            },
            FieldDef {
                name: "tool_calls".into(),
                field_type: FieldType::StringArray,
                required: false,
                description: Some(
                    "Names of tools invoked during this run, in order".into(),
                ),
            },
            FieldDef {
                name: "status".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("Terminal status: completed | failed | cancelled".into()),
            },
            FieldDef {
                name: "finish_reason".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Why the loop terminated: completed | max_rounds_reached | error".into(),
                ),
            },
            FieldDef {
                name: "round_number".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some(
                    "Which tool-use round within the containing task this run corresponds to"
                        .into(),
                ),
            },
        ],
        expected_edges: vec![EdgeType::ProducedBy, EdgeType::OperatesOn],
        inherits: None,
    }
}

// MARK: - Registration

/// Register all impel schemas in a [`SchemaRegistry`].
///
/// Call this once at application startup before writing any items to the
/// shared impress-core store.
pub fn register_impel_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(task_schema())
        .expect("impel/task schema registration");
    registry
        .register(agent_run_schema())
        .expect("impel/agent-run schema registration");
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_all_impel_schemas() {
        let mut reg = SchemaRegistry::new();
        register_impel_schemas(&mut reg);
        assert!(reg.get("impel/task").is_some());
        assert!(reg.get("impel/agent-run").is_some());
    }

    #[test]
    fn task_schema_has_required_fields() {
        let schema = task_schema();
        let required: Vec<_> = schema.fields.iter().filter(|f| f.required).collect();
        let required_names: Vec<_> = required.iter().map(|f| f.name.as_str()).collect();
        assert!(required_names.contains(&"title"), "task schema missing required 'title'");
        assert!(required_names.contains(&"state"), "task schema missing required 'state'");
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
        let schema = task_schema();
        assert!(schema.expected_edges.contains(&EdgeType::DependsOn));
        assert!(schema
            .expected_edges
            .contains(&EdgeType::Custom("triggered-by".into())));
    }

    #[test]
    fn agent_run_schema_has_expected_edges() {
        let schema = agent_run_schema();
        assert!(schema.expected_edges.contains(&EdgeType::ProducedBy));
        assert!(schema.expected_edges.contains(&EdgeType::OperatesOn));
    }

    #[test]
    fn schema_ids_are_namespaced() {
        assert!(task_schema().id.starts_with("impel/"));
        assert!(agent_run_schema().id.starts_with("impel/"));
    }
}
