//! Suite-scoped memory: the three things worth remembering across sessions.
//!
//! These are **knowledge objects** in the ADR-0012 D39 sense — first-person
//! artifacts an actor (human or agent) authored *about* something else, not
//! facts about external reality. D39's field convention is what they follow:
//! a subject, an evidence trail, agent attribution, and replacement by
//! `Supersedes` edge rather than in-place edit.
//!
//! Three kinds, because three different questions get asked of memory and a
//! single "note" schema answers none of them well:
//!
//! * [`MEMORY_CLAIM_SCHEMA`] — *what is true.* "The 2018 catalogue's flux
//!   column is in mJy, not Jy." A claim is the unit that gets **confirmed**
//!   (seen again, still true) and **superseded** (found to be wrong, or made
//!   more precise). Its `claim_type` says which flavour of true it is.
//! * [`MEMORY_EPISODE_SCHEMA`] — *what happened.* "Asked to recalibrate, I
//!   re-ran the fit with the 2019 zero-point and it converged in 3 minutes."
//!   An episode carries `task_kind` / `approach` / `outcome` so "how did this
//!   go last time?" is a query rather than a re-read of a transcript.
//! * [`MEMORY_INSTRUCTION_SCHEMA`] — *what to do.* "Never open the shared
//!   container from a shell." A standing instruction from the user, which is
//!   the one kind that must survive being unfashionable: an instruction is
//!   retired by supersession, never by an agent deciding it no longer applies.
//!
//! # Why `title` + `body` and not a nested envelope
//!
//! `items_fts` already indexes `title` and `body` for every record kind in the
//! suite (`sqlite_store::FTS_SELECT_EXPRS`). Naming the two prose fields
//! exactly that — flat, at the top level of the payload — means memory is
//! full-text searchable the moment the first row lands, with **zero**
//! `sqlite_store` changes and no second index to keep in step. A
//! `{title, data, body}` nesting would have been tidier to look at and
//! invisible to search.
//!
//! # The fields that are shared, and why they are shared
//!
//! All three carry `confidence`, `subject_refs`, `evidence_refs`, `agent_id`,
//! `agent_run_ref`, `confirmations`, `last_confirmed` and `no_recall`. That is
//! deliberate: the ranking, gating and recall kernel
//! ([`crate::memory_ops`]) is written once against this common shape, so
//! adding a fourth memory kind later costs a schema and nothing else. The
//! per-kind fields are the small tail that the kernel passes through
//! untouched.
//!
//! `subject_refs` and `evidence_refs` are D39's field-AND-edge pair: the field
//! is the schema-validated commitment, the edge (`RelatesTo` / `DerivedFrom`,
//! written by [`crate::memory_ops::insert_memory_item`]) is the queryable
//! graph structure. Both, always — a reader that walks the graph and a reader
//! that reads the payload must see the same relation.

use crate::reference::EdgeType;
use crate::registry::SchemaRegistry;
use crate::schema::{FieldDef, FieldType, Schema};

/// The canonical memory-claim ref. VERSIONED and namespaced under `memory/`:
/// copy this spelling, never a sibling call site (root CLAUDE.md, "Definition
/// of done — schema refs"). The store matches `schema_ref` by exact equality.
pub const MEMORY_CLAIM_SCHEMA: &str = "memory/claim@1.0.0";

/// The canonical memory-episode ref. Versioned for the same reason its
/// siblings are: the payload shape is the contract the recall kernel and every
/// downstream memory surface read, and a v2 must be able to coexist with v1
/// rows in a live store.
pub const MEMORY_EPISODE_SCHEMA: &str = "memory/episode@1.0.0";

/// The canonical memory-instruction ref.
pub const MEMORY_INSTRUCTION_SCHEMA: &str = "memory/instruction@1.0.0";

// ── Vocabularies ─────────────────────────────────────────────────────────────
//
// `claim_type` is a FREE vocabulary (ADR-0012 D39 rule 2: the field name is
// reserved, the values are per-schema). These constants exist so the writers
// in this repo agree with each other, not to close the set — a claim carrying
// a `claim_type` that is not listed here is legal and is stored verbatim.

/// A claim about the world: "the flux column is in mJy".
pub const CLAIM_TYPE_FACT: &str = "fact";

/// A claim about what the user wants: "prefers Typst over LaTeX".
pub const CLAIM_TYPE_PREFERENCE: &str = "preference";

/// A claim about how something is done: "the zero-point is applied before the
/// aperture correction".
pub const CLAIM_TYPE_METHOD: &str = "method";

/// A claim recording a settled choice: "we ship arm64-only debug frameworks".
pub const CLAIM_TYPE_DECISION: &str = "decision";

/// A claim recording an outcome: "the 400-seed convergence suite passes".
pub const CLAIM_TYPE_RESULT: &str = "result";

/// The claim types this repo's writers use. NOT a closed set — see above.
pub const CLAIM_TYPES: [&str; 5] = [
    CLAIM_TYPE_FACT,
    CLAIM_TYPE_PREFERENCE,
    CLAIM_TYPE_METHOD,
    CLAIM_TYPE_DECISION,
    CLAIM_TYPE_RESULT,
];

// ── Schemas ──────────────────────────────────────────────────────────────────

/// The fields every memory kind carries, in the order they are declared on all
/// three schemas.
///
/// Factored out rather than repeated so the three cannot drift: the kernel
/// reads `confirmations` and `no_recall` off any memory row without asking
/// which kind it is, and a field that existed on two of the three would make
/// that a lie for the third.
fn shared_memory_fields() -> Vec<FieldDef> {
    vec![
        described(
            required_string("title"),
            "Short label — one line, the thing a list row shows. REQUIRED, and \
             REQUIRED to be short: this is half of what `items_fts` indexes \
             (the other half is `body`), so a title that restates the body \
             makes every memory match every query.",
        ),
        described(
            required_string("body"),
            "The memory itself, as prose. REQUIRED — a memory with no body is \
             a label, and a label cannot be confirmed, superseded or acted on. \
             Indexed by `items_fts` through the shared `body` column, which is \
             why the field is spelled exactly `body` and lives at the top \
             level of the payload rather than inside a nested envelope.",
        ),
        described(
            field("confidence", FieldType::Float, false),
            "0.0–1.0 — how sure the author is. Normative: recall ranking \
             weights it, and a consumer may suppress low-confidence memories \
             rather than surfacing a guess as a fact. Absent means \
             \"unstated\", which is NOT the same as zero and is not scored as \
             zero.",
        ),
        described(
            field("subject_refs", FieldType::StringArray, false),
            "Lowercase UUIDs of the items this memory is ABOUT (ADR-0012 D39 \
             rule 1). Mirrored as `RelatesTo` edges by \
             `memory_ops::insert_memory_item` — the field is the \
             schema-validated commitment, the edge is the queryable graph \
             structure, and both are written together so a graph walk and a \
             payload read never disagree.",
        ),
        described(
            field("evidence_refs", FieldType::StringArray, false),
            "Lowercase UUIDs of the items this memory was DERIVED FROM \
             (ADR-0012 D39 rule 3) — the transcript, the paper, the run that \
             produced it. Mirrored as `DerivedFrom` edges. Evidence is for \
             REPRODUCIBILITY, not citation: it is what lets a reader re-derive \
             the memory and check it for drift.",
        ),
        described(
            optional_string("agent_id"),
            "Persona id when an agent authored this (ADR-0013 D29: \
             \"counsel\", \"artificer\", …). Absent for human-authored \
             memories. The envelope's `author` / `author_kind` remain the \
             authority on WHO wrote the row; this names WHICH persona.",
        ),
        described(
            optional_string("agent_run_ref"),
            "Lowercase UUID of the `agent-run@1.0.0` row that produced this \
             memory. Mirrored as a `ProducedBy` edge. Absent for \
             human-authored memories.",
        ),
        described(
            field("confirmations", FieldType::Int, false),
            "How many times this memory has been independently re-observed \
             (`memory_ops::confirm`). THE alternative to writing a near-\
             duplicate row: a memory seen again is the same memory with more \
             evidence behind it, and the count is what recall ranking rewards. \
             Absent is read as 0.",
        ),
        described(
            field("last_confirmed", FieldType::DateTime, false),
            "ISO-8601 time of the most recent confirmation. Absent means never \
             confirmed since it was written — which a surface must distinguish \
             from \"confirmed long ago\", because only one of those is stale.",
        ),
        described(
            field("no_recall", FieldType::Bool, false),
            "True withholds this row from `memory_ops::recall` and \
             `memory_ops::brief` WITHOUT deleting it. The retraction verb for \
             a memory that turned out to be private, wrong in a way no \
             supersession expresses, or simply unwanted — deleting would \
             destroy the evidence edges that explain how it got written. \
             Absent is read as false.",
        ),
    ]
}

/// Schema for the `memory/claim@1.0.0` item type.
pub fn memory_claim_schema() -> Schema {
    let mut fields = shared_memory_fields();
    fields.push(described(
        optional_string("claim_type"),
        "What flavour of claim this is: \"fact\" | \"preference\" | \
         \"method\" | \"decision\" | \"result\" are the values this repo's \
         writers use (`CLAIM_TYPES`), but the vocabulary is FREE per ADR-0012 \
         D39 — an unlisted value is legal and is stored verbatim. Load-bearing \
         in one place: the dedup gate refuses to merge two claims whose \
         `claim_type`s disagree, because \"the user prefers X\" and \"X is \
         true\" are different memories however similar their prose.",
    ));
    Schema {
        id: MEMORY_CLAIM_SCHEMA.into(),
        name: "Memory Claim".into(),
        version: "1.0.0".into(),
        fields,
        expected_edges: memory_edges(),
        inherits: None,
    }
}

/// Schema for the `memory/episode@1.0.0` item type.
pub fn memory_episode_schema() -> Schema {
    let mut fields = shared_memory_fields();
    fields.extend([
        described(
            optional_string("task_kind"),
            "The kind of work this episode is about, spelled to match the \
             scheduler's dispatch key (`task@1.0.0`'s `task_kind`) where one \
             applies. This is the retrieval handle for \"how did this kind of \
             task go last time?\", which is the whole reason episodes are a \
             separate kind from claims.",
        ),
        described(
            optional_string("approach"),
            "What was actually tried, in a sentence. Distinct from `body`, \
             which is the narrative: this is the part a future run compares \
             against its own plan before repeating a dead end.",
        ),
        described(
            optional_string("outcome"),
            "How it ended. Free text rather than a closed success/failure \
             vocabulary, because the useful episodes are the partial ones \
             (\"converged, but only after pinning the seed\").",
        ),
        described(
            field("quality", FieldType::Float, false),
            "0.0–1.0 — how well it went, as judged by the author. Separate \
             from `confidence`, which is about how sure the author is that the \
             episode is described correctly. A confidently-recorded failure is \
             high confidence and low quality.",
        ),
    ]);
    Schema {
        id: MEMORY_EPISODE_SCHEMA.into(),
        name: "Memory Episode".into(),
        version: "1.0.0".into(),
        fields,
        expected_edges: memory_edges(),
        inherits: None,
    }
}

/// Schema for the `memory/instruction@1.0.0` item type.
pub fn memory_instruction_schema() -> Schema {
    let mut fields = shared_memory_fields();
    fields.extend([
        described(
            optional_string("rule"),
            "The imperative form, when the author wants one distinct from the \
             prose. ABSENT MEANS `body` IS THE RULE — this field is an \
             optional sharpening, never a second source of truth, so a reader \
             takes `rule` when present and `body` otherwise and never has to \
             reconcile two versions of one instruction.",
        ),
        described(
            field("applies_to", FieldType::StringArray, false),
            "Free-text scopes this instruction is limited to — app names, \
             record kinds, task kinds, project paths. Absent means it applies \
             everywhere, which is the common case and therefore the default \
             rather than a value anyone has to write down.",
        ),
    ]);
    Schema {
        id: MEMORY_INSTRUCTION_SCHEMA.into(),
        name: "Memory Instruction".into(),
        version: "1.0.0".into(),
        fields,
        expected_edges: memory_edges(),
        inherits: None,
    }
}

/// The three edges every memory kind declares.
///
/// `RelatesTo` mirrors `subject_refs`, `DerivedFrom` mirrors `evidence_refs`,
/// and `Supersedes` is ADR-0012 D39 rule 5's replacement mechanism: a
/// correction is a NEW row pointing at the old one, so the superseded memory
/// stays in the graph for audit and time-travel instead of being edited away.
///
/// `ProducedBy` (the mirror of `agent_run_ref`) is deliberately NOT declared:
/// it is provenance shared with every agent-written record kind in the suite,
/// not a memory-specific relation, and `expected_edges` is the list a memory
/// surface renders.
fn memory_edges() -> Vec<EdgeType> {
    vec![
        EdgeType::RelatesTo,
        EdgeType::DerivedFrom,
        EdgeType::Supersedes,
    ]
}

/// Register the three memory schemas.
pub fn register_memory_schemas(registry: &mut SchemaRegistry) {
    registry
        .register(memory_claim_schema())
        .expect("memory/claim@1.0.0 schema registration");
    registry
        .register(memory_episode_schema())
        .expect("memory/episode@1.0.0 schema registration");
    registry
        .register(memory_instruction_schema())
        .expect("memory/instruction@1.0.0 schema registration");
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

    fn all() -> [Schema; 3] {
        [
            memory_claim_schema(),
            memory_episode_schema(),
            memory_instruction_schema(),
        ]
    }

    #[test]
    fn all_three_schemas_register() {
        let mut reg = SchemaRegistry::new();
        register_memory_schemas(&mut reg);
        assert!(reg.get(MEMORY_CLAIM_SCHEMA).is_some());
        assert!(reg.get(MEMORY_EPISODE_SCHEMA).is_some());
        assert!(reg.get(MEMORY_INSTRUCTION_SCHEMA).is_some());
    }

    /// The ids ARE the refs writers emit. A rename here without a
    /// `schema-refs.json` edit is caught by `tests/schema_ref_manifest.rs`; a
    /// rename that forgets the constants is caught right here.
    #[test]
    fn ids_are_the_canonical_versioned_refs() {
        assert_eq!(memory_claim_schema().id, "memory/claim@1.0.0");
        assert_eq!(memory_episode_schema().id, "memory/episode@1.0.0");
        assert_eq!(memory_instruction_schema().id, "memory/instruction@1.0.0");
        assert_eq!(MEMORY_CLAIM_SCHEMA, memory_claim_schema().id);
        assert_eq!(MEMORY_EPISODE_SCHEMA, memory_episode_schema().id);
        assert_eq!(MEMORY_INSTRUCTION_SCHEMA, memory_instruction_schema().id);
    }

    /// `title` and `body` are the two `items_fts` columns a memory row lands
    /// in. Making either optional — or spelling `body` as `text`, `content` or
    /// `prose` — would make memory silently unsearchable, with no error and no
    /// index to notice the omission.
    #[test]
    fn every_kind_requires_the_two_fts_indexed_fields() {
        for s in all() {
            let required: Vec<&str> = s
                .fields
                .iter()
                .filter(|f| f.required)
                .map(|f| f.name.as_str())
                .collect();
            assert_eq!(
                required,
                vec!["title", "body"],
                "{}: title+body are what items_fts indexes",
                s.id
            );
        }
    }

    /// The kernel reads these off any memory row without asking which kind it
    /// is. A field that existed on two of the three would make that a lie.
    #[test]
    fn the_shared_field_set_is_identical_across_the_three_kinds() {
        for s in all() {
            let names: Vec<&str> = s.fields.iter().map(|f| f.name.as_str()).collect();
            for shared in [
                "title",
                "body",
                "confidence",
                "subject_refs",
                "evidence_refs",
                "agent_id",
                "agent_run_ref",
                "confirmations",
                "last_confirmed",
                "no_recall",
            ] {
                assert!(names.contains(&shared), "{} is missing {shared:?}", s.id);
            }
        }
    }

    #[test]
    fn per_kind_fields_live_only_on_their_own_kind() {
        let claim: Vec<String> = memory_claim_schema()
            .fields
            .iter()
            .map(|f| f.name.clone())
            .collect();
        let episode: Vec<String> = memory_episode_schema()
            .fields
            .iter()
            .map(|f| f.name.clone())
            .collect();
        let instruction: Vec<String> = memory_instruction_schema()
            .fields
            .iter()
            .map(|f| f.name.clone())
            .collect();

        assert!(claim.iter().any(|f| f == "claim_type"));
        assert!(!episode.iter().any(|f| f == "claim_type"));
        assert!(!instruction.iter().any(|f| f == "claim_type"));

        for f in ["task_kind", "approach", "outcome", "quality"] {
            assert!(episode.iter().any(|n| n == f), "episode is missing {f:?}");
            assert!(!claim.iter().any(|n| n == f), "claim must not carry {f:?}");
        }

        for f in ["rule", "applies_to"] {
            assert!(
                instruction.iter().any(|n| n == f),
                "instruction is missing {f:?}"
            );
            assert!(!claim.iter().any(|n| n == f), "claim must not carry {f:?}");
        }
    }

    /// ADR-0012 D39 rule 5: replacement is an edge, never an in-place edit. If
    /// `Supersedes` ever leaves this list, the correction path has quietly
    /// become "overwrite the old memory", and the audit trail with it.
    #[test]
    fn every_kind_declares_the_three_memory_edges() {
        for s in all() {
            assert_eq!(
                s.expected_edges,
                vec![
                    EdgeType::RelatesTo,
                    EdgeType::DerivedFrom,
                    EdgeType::Supersedes
                ],
                "{}",
                s.id
            );
        }
    }

    /// `subject_refs` / `evidence_refs` are ARRAYS, not single ids: one memory
    /// routinely covers several papers and is derived from several runs, and a
    /// scalar field would force the writer to pick one and drop the rest.
    #[test]
    fn the_ref_fields_are_optional_string_arrays() {
        for s in all() {
            for name in ["subject_refs", "evidence_refs"] {
                let f = s
                    .fields
                    .iter()
                    .find(|f| f.name == name)
                    .unwrap_or_else(|| panic!("{}: no {name} field", s.id));
                assert_eq!(f.field_type, FieldType::StringArray, "{}.{name}", s.id);
                assert!(!f.required, "{}.{name} must be optional", s.id);
            }
        }
    }

    #[test]
    fn claim_type_vocabulary_is_the_five_documented_values() {
        assert_eq!(
            CLAIM_TYPES,
            ["fact", "preference", "method", "decision", "result"]
        );
    }

    #[test]
    fn every_field_is_documented() {
        for s in all() {
            for f in &s.fields {
                assert!(
                    f.description
                        .as_deref()
                        .is_some_and(|d| !d.trim().is_empty()),
                    "{}.{} has no description",
                    s.id,
                    f.name
                );
            }
        }
    }

    #[test]
    fn schemas_serde_round_trip() {
        for s in all() {
            let json = serde_json::to_string_pretty(&s).unwrap();
            let back: Schema = serde_json::from_str(&json).unwrap();
            assert_eq!(s, back);
        }
    }
}
