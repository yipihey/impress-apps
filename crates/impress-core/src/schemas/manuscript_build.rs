//! `manuscript-build@1.0.0` — one explicit build of a manuscript project
//! (ADR-0030 D8). Parent = the manuscript.
//!
//! What "the PDF for this manuscript" means: the newest `ok` build of a
//! target. What an agent reads to learn why a build failed: the structured
//! diagnostics. What a revision attaches: the outputs, as blob refs.
//!
//! Previews never write one — the editor's debounced compiles are ephemeral,
//! and a row per keystroke would be a churn incident. The daemon's hygiene
//! cycle keeps the newest `BUILD_RETENTION` per manuscript.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

pub const MANUSCRIPT_BUILD_SCHEMA_REF: &str = "manuscript-build@1.0.0";

/// How many builds `compact_builds` keeps per manuscript.
pub const BUILD_RETENTION: usize = 20;

pub const BUILD_STATUS_RUNNING: &str = "running";
pub const BUILD_STATUS_OK: &str = "ok";
pub const BUILD_STATUS_FAILED: &str = "failed";
pub const BUILD_STATUS_CANCELLED: &str = "cancelled";

pub fn manuscript_build_schema() -> Schema {
    Schema {
        id: MANUSCRIPT_BUILD_SCHEMA_REF.into(),
        name: "Manuscript Build".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "target_id".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "The target built (`main` for the implicit one — ADR-0030 D9).".into(),
                ),
            },
            FieldDef {
                name: "engine".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "typst | tectonic | pdflatex | xelatex | lualatex | latexmk | markdown.".into(),
                ),
            },
            FieldDef {
                name: "status".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("running | ok | failed | cancelled.".into()),
            },
            FieldDef {
                name: "input_stamp".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "SHA-256 over the sorted (path, content_hash) pairs of the tree plus the \
                     target — two builds of the same stamp are the same build."
                        .into(),
                ),
            },
            FieldDef {
                name: "started_ms".into(),
                field_type: FieldType::Int,
                required: true,
                description: None,
            },
            FieldDef {
                name: "finished_ms".into(),
                field_type: FieldType::Int,
                required: false,
                description: None,
            },
            FieldDef {
                name: "duration_ms".into(),
                field_type: FieldType::Int,
                required: false,
                description: None,
            },
            FieldDef {
                name: "outputs_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "`[{path, blob_ref, kind: pdf | svg | png | log | synctex | aux, size}]` \
                     — every artifact the build produced, content-addressed."
                        .into(),
                ),
            },
            FieldDef {
                name: "diagnostics_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "`[{severity, message, file, line, column}]` in tree paths, so a click \
                     lands in the right file."
                        .into(),
                ),
            },
            FieldDef {
                name: "steps_json".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "`[{path, runner, status, ms, message}]` — the figure steps that ran \
                     before the compile (D6)."
                        .into(),
                ),
            },
            FieldDef {
                name: "allow_shell".into(),
                field_type: FieldType::Bool,
                required: false,
                description: Some(
                    "Whether `shell` steps were permitted for this build — recorded, because \
                     it is the one thing a build can do that reaches outside the tree."
                        .into(),
                ),
            },
            FieldDef {
                name: "message".into(),
                field_type: FieldType::String,
                required: false,
                description: Some("One line for the human: the first error, or `ok`.".into()),
            },
        ],
        expected_edges: vec![EdgeType::IsPartOf],
        inherits: None,
    }
}

pub fn register_manuscript_build_schema(registry: &mut SchemaRegistry) {
    registry
        .register(manuscript_build_schema())
        .expect("manuscript-build schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registers_versioned_with_required_core() {
        let mut reg = SchemaRegistry::new();
        register_manuscript_build_schema(&mut reg);
        let s = reg.get(MANUSCRIPT_BUILD_SCHEMA_REF).expect("registered");
        assert_eq!(s.version, "1.0.0");
        for name in ["target_id", "engine", "status", "input_stamp", "started_ms"] {
            assert!(
                s.fields.iter().any(|f| f.name == name && f.required),
                "{name}"
            );
        }
    }
}
