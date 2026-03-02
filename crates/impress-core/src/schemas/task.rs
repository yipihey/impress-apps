use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for task items — units of work assigned to humans or agents.
pub fn task_schema() -> Schema {
    Schema {
        id: "task".into(),
        name: "Task".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("title"),
            required_string("state"),
            optional_string("description"),
            optional_string("assigned_to"),
            field("due_at", FieldType::Int, false),
            optional_string("output_schema"),
            optional_string("error"),
        ],
        expected_edges: vec![
            EdgeType::DependsOn,
            EdgeType::ProducedBy,
            EdgeType::OperatesOn,
        ],
        inherits: None,
    }
}

/// Schema for agent-run items — records of a single AI agent execution.
pub fn agent_run_schema() -> Schema {
    Schema {
        id: "agent-run".into(),
        name: "Agent Run".into(),
        version: "1.0.0".into(),
        fields: vec![
            required_string("agent_id"),
            required_string("model"),
            required_string("prompt_hash"),
            optional_string("result_summary"),
            field("token_count", FieldType::Int, false),
            field("duration_ms", FieldType::Int, false),
        ],
        expected_edges: vec![
            EdgeType::ProducedBy,
            EdgeType::DerivedFrom,
        ],
        inherits: None,
    }
}

/// Register all task-related schemas into the registry.
pub fn register_task_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(task_schema())
        .expect("task schema registration");
    registry
        .register(agent_run_schema())
        .expect("agent-run schema registration");
}

fn required_string(name: &str) -> FieldDef {
    FieldDef { name: name.into(), field_type: FieldType::String, required: true, description: None }
}

fn optional_string(name: &str) -> FieldDef {
    FieldDef { name: name.into(), field_type: FieldType::String, required: false, description: None }
}

fn field(name: &str, field_type: FieldType, required: bool) -> FieldDef {
    FieldDef { name: name.into(), field_type, required, description: None }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_schemas_register() {
        let mut reg = SchemaRegistry::new();
        register_task_schemas(&mut reg);
        assert!(reg.get("task").is_some());
        assert!(reg.get("agent-run").is_some());
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
        assert!(required.contains(&"prompt_hash"), "missing required prompt_hash");
    }

    #[test]
    fn task_schema_has_expected_edges() {
        let schema = task_schema();
        assert!(schema.expected_edges.contains(&EdgeType::DependsOn));
        assert!(schema.expected_edges.contains(&EdgeType::ProducedBy));
        assert!(schema.expected_edges.contains(&EdgeType::OperatesOn));
    }

    #[test]
    fn agent_run_schema_has_expected_edges() {
        let schema = agent_run_schema();
        assert!(schema.expected_edges.contains(&EdgeType::ProducedBy));
        assert!(schema.expected_edges.contains(&EdgeType::DerivedFrom));
    }
}
