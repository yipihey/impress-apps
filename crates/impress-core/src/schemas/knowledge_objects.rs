//! Knowledge-object schemas per ADR-0012.
//!
//! A knowledge object is any item whose schema follows the field convention
//! defined in ADR-0012 D2: a `subject_ref` identifying the item the
//! knowledge is about, an optional `verdict` summarizing the author's
//! position, an optional `evidence_refs` list, and `agent_id` /
//! `agent_run_ref` fields when authored by an agent.
//!
//! There is no runtime `KnowledgeObject` trait — the category is a
//! documented convention, not a type-system concept (per ADR-0012 D1).
//! New knowledge-object schemas may be added without changing this module's
//! contract; they only need to follow the field convention.
//!
//! Two schemas are defined here, both required by the journal pipeline
//! (ADR-0011 D7):
//!
//! * `review@1.0.0` — Counsel's structured critique of a manuscript revision.
//! * `revision-note@1.0.0` — Artificer's (or a human's) revision proposal.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// Schema for the `review@1.0.0` knowledge object.
///
/// A review is a structured critique of a manuscript-revision, authored by a
/// human reviewer or by Counsel (per ADR-0013). Reviews are durable
/// (ADR-0012 D6) — they are never compacted.
pub fn review_schema() -> Schema {
    Schema {
        id: "review".into(),
        name: "Review".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "subject_ref".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "ItemId of the manuscript-revision being reviewed.".into(),
                ),
            },
            FieldDef {
                name: "verdict".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "One of: approve | approve-with-changes | request-revision | reject.".into(),
                ),
            },
            FieldDef {
                name: "body".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "The reviewer's prose critique (markdown).".into(),
                ),
            },
            FieldDef {
                name: "summary".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "One-paragraph summary of verdict and key concerns; used by episodic-memory \
                     consumers to retrieve without loading the full body."
                        .into(),
                ),
            },
            FieldDef {
                name: "sections".into(),
                field_type: FieldType::Object,
                required: false,
                description: Some(
                    "Structured per-section comments keyed by section_type \
                     (e.g. {\"intro\": \"...\", \"methods\": \"...\"}). Keys are not validated."
                        .into(),
                ),
            },
            FieldDef {
                name: "confidence".into(),
                field_type: FieldType::Float,
                required: false,
                description: Some(
                    "Reviewer's confidence in the verdict, 0.0–1.0.".into(),
                ),
            },
            FieldDef {
                name: "evidence_refs".into(),
                field_type: FieldType::StringArray,
                required: false,
                description: Some(
                    "ItemIds consulted to produce this review (prior reviews, cited works).".into(),
                ),
            },
            FieldDef {
                name: "agent_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Persona ID if agent-authored (per ADR-0013); absent for human-authored \
                     reviews."
                        .into(),
                ),
            },
            FieldDef {
                name: "agent_run_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ItemId of the agent-run@1.0.0 record for this review (for reproducibility).".into(),
                ),
            },
        ],
        expected_edges: vec![
            EdgeType::Annotates,
            EdgeType::Cites,
            EdgeType::Supersedes,
            EdgeType::ProducedBy,
        ],
        inherits: None,
    }
}

/// Schema for the `revision-note@1.0.0` knowledge object.
///
/// A revision-note explains a proposed (or accepted/rejected/deferred)
/// revision to a manuscript. Artificer produces these as structured outputs
/// containing a unified diff against the current source; humans may also
/// author them directly.
pub fn revision_note_schema() -> Schema {
    Schema {
        id: "revision-note".into(),
        name: "Revision Note".into(),
        version: "1.0.0".into(),
        fields: vec![
            FieldDef {
                name: "subject_ref".into(),
                field_type: FieldType::String,
                required: true,
                description: Some(
                    "ItemId of the manuscript-revision the note is about.".into(),
                ),
            },
            FieldDef {
                name: "verdict".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("One of: propose | accept | reject | defer.".into()),
            },
            FieldDef {
                name: "body".into(),
                field_type: FieldType::String,
                required: true,
                description: Some("Prose explanation of the revision rationale.".into()),
            },
            FieldDef {
                name: "diff".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Unified diff text against the current revision's source, or a structured \
                     patch (RFC 6902) for non-text edits."
                        .into(),
                ),
            },
            FieldDef {
                name: "target_section".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "section_type value (e.g. \"methods\") if the note is scoped to one section.".into(),
                ),
            },
            FieldDef {
                name: "review_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ItemId of the review/v1 item that motivated this note (if any).".into(),
                ),
            },
            FieldDef {
                name: "evidence_refs".into(),
                field_type: FieldType::StringArray,
                required: false,
                description: Some(
                    "ItemIds consulted (the review, the section being revised, related papers).".into(),
                ),
            },
            FieldDef {
                name: "agent_id".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "Persona ID if agent-authored; typically \"artificer\" (per ADR-0013).".into(),
                ),
            },
            FieldDef {
                name: "agent_run_ref".into(),
                field_type: FieldType::String,
                required: false,
                description: Some(
                    "ItemId of the agent-run@1.0.0 record for this note.".into(),
                ),
            },
        ],
        expected_edges: vec![
            EdgeType::Annotates,
            EdgeType::InResponseTo,
            EdgeType::Supersedes,
            EdgeType::ProducedBy,
        ],
        inherits: None,
    }
}

/// Register both knowledge-object schemas (review and revision-note).
pub fn register_knowledge_object_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(review_schema())
        .expect("review schema registration");
    registry
        .register(revision_note_schema())
        .expect("revision-note schema registration");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn knowledge_object_schemas_register() {
        let mut reg = SchemaRegistry::new();
        register_knowledge_object_schemas(&mut reg);
        assert!(reg.get("review").is_some());
        assert!(reg.get("revision-note").is_some());
    }

    #[test]
    fn review_required_fields() {
        let s = review_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        for f in &["subject_ref", "verdict", "body"] {
            assert!(required.contains(f), "review missing required field: {f}");
        }
    }

    #[test]
    fn revision_note_required_fields() {
        let s = revision_note_schema();
        let required: Vec<&str> = s
            .fields
            .iter()
            .filter(|f| f.required)
            .map(|f| f.name.as_str())
            .collect();
        for f in &["subject_ref", "verdict", "body"] {
            assert!(
                required.contains(f),
                "revision-note missing required field: {f}"
            );
        }
    }

    #[test]
    fn review_uses_annotates_edge() {
        let s = review_schema();
        assert!(s.expected_edges.contains(&EdgeType::Annotates));
        assert!(s.expected_edges.contains(&EdgeType::Supersedes));
    }

    #[test]
    fn revision_note_uses_in_response_to_edge() {
        let s = revision_note_schema();
        assert!(s.expected_edges.contains(&EdgeType::Annotates));
        assert!(s.expected_edges.contains(&EdgeType::InResponseTo));
    }

    #[test]
    fn knowledge_object_schemas_serde_round_trip() {
        for s in [review_schema(), revision_note_schema()] {
            let json = serde_json::to_string_pretty(&s).unwrap();
            let back: Schema = serde_json::from_str(&json).unwrap();
            assert_eq!(s, back);
        }
    }
}
