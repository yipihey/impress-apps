use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for tracking git-linked projects across the impress suite.
///
/// A git project represents a local clone of a repository that one or more
/// impress apps use for version control — LaTeX manuscripts in imprint, .bib
/// files in imbib, analysis scripts in implore, etc.  Metadata is stored in the
/// shared impress-core SQLite store so that any app or agent can query the sync
/// state of a project.
pub fn git_project_schema() -> Schema {
    Schema {
        id: "git-project".into(),
        name: "Git Project".into(),
        version: "1.0.0".into(),
        fields: vec![
            // --- required ---
            FieldDef {
                name: "repository_url".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Remote URL (SSH or HTTPS)".into()),
            },
            FieldDef {
                name: "local_path".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Absolute path to local clone".into()),
            },
            FieldDef {
                name: "branch".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Current branch name".into()),
            },
            // --- optional ---
            FieldDef {
                name: "project_type".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "What kind of project: manuscript, bibliography, analysis, config".into(),
                ),
            },
            FieldDef {
                name: "main_file".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Relative path to the main file (e.g. main.tex, paper.typ)".into(),
                ),
            },
            FieldDef {
                name: "last_sync_time".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("ISO 8601 timestamp of last push/pull".into()),
            },
            FieldDef {
                name: "last_commit_hash".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("HEAD SHA after last sync".into()),
            },
            FieldDef {
                name: "auto_commit".into(),
                field_type: FieldType::Bool,
                required: false,
                description: Some("Auto-commit on save".into()),
            },
            FieldDef {
                name: "auto_push".into(),
                field_type: FieldType::Bool,
                required: false,
                description: Some("Auto-push after commit".into()),
            },
            FieldDef {
                name: "sync_interval_minutes".into(),
                field_type: FieldType::Int,
                required: false,
                description: Some("Auto-fetch interval in minutes (0 = manual only)".into()),
            },
            FieldDef {
                name: "app_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Which app owns this project (imprint, imbib, implore)".into(),
                ),
            },
        ],
        expected_edges: vec![
            EdgeType::Contains,
            EdgeType::Custom("is-part-of".into()),
        ],
        inherits: None,
    }
}

/// Register the git-project schema into a registry.
pub fn register_git_project_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(git_project_schema())
        .expect("git-project schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn register_git_project_schema() {
        let mut reg = SchemaRegistry::new();
        register_git_project_schemas(&mut reg);
        let schema = reg.get("git-project");
        assert!(schema.is_some(), "git-project schema should be registered");
        let schema = schema.unwrap();
        assert_eq!(schema.version, "1.0.0");
    }

    #[test]
    fn git_project_has_required_fields() {
        let schema = git_project_schema();
        let required: Vec<&str> = schema
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        assert!(required.contains(&"repository_url"));
        assert!(required.contains(&"local_path"));
        assert!(required.contains(&"branch"));
        assert_eq!(required.len(), 3);
    }

    #[test]
    fn git_project_optional_fields() {
        let schema = git_project_schema();
        let optional_fields = [
            "project_type",
            "main_file",
            "last_sync_time",
            "last_commit_hash",
            "auto_commit",
            "auto_push",
            "sync_interval_minutes",
            "app_id",
        ];
        for name in &optional_fields {
            let field = schema.fields.iter().find(|f| f.name == *name);
            assert!(field.is_some(), "field '{}' should exist", name);
            assert!(!field.unwrap().required, "field '{}' should be optional", name);
        }
    }

    #[test]
    fn git_project_has_expected_edges() {
        let schema = git_project_schema();
        assert!(
            schema.expected_edges.contains(&EdgeType::Contains),
            "should expect Contains edges"
        );
        assert!(
            schema
                .expected_edges
                .contains(&EdgeType::Custom("is-part-of".into())),
            "should expect Custom(is-part-of) edges"
        );
    }

    #[test]
    fn git_project_schema_serde_round_trip() {
        let schema = git_project_schema();
        let json = serde_json::to_string_pretty(&schema).unwrap();
        let back: crate::schema::Schema = serde_json::from_str(&json).unwrap();
        assert_eq!(schema, back);
    }
}
