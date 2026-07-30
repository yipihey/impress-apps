//! ADR-0005 §9 reference implementation (ADR-0015 D6).
//!
//! The imbib enrichment pipeline, expressed as impel `TaskExecutor`s over
//! the impress-core item graph:
//!
//! - [`MetadataResolveExecutor`] — composes `impress-sources` clients with
//!   `imbib-core`'s merge/priority strategy; persists only
//!   `changed_fields` as attributed `SetPayload` operations.
//! - [`KeywordTagExecutor`] — classification behind the [`Classifier`]
//!   trait; low-confidence results open an `AwaitHumanResponse` review
//!   checkpoint instead of silently skipping.
//! - [`EnrichmentSpawnRule`] — reacts to new `imbib/bibliography-entry`
//!   items with the task DAG.
//!
//! ADR-0005's verdict standard applies: this crate's integration test is
//! the architecture-validation gate for the task kernel.

pub mod classify;
pub mod classify_llm;
pub mod keyword_tag;
pub mod metadata_resolve;
pub mod spawn;

pub use classify::{Classification, Classifier, HeuristicClassifier};
pub use classify_llm::LlmClassifier;
pub use keyword_tag::KeywordTagExecutor;
pub use metadata_resolve::MetadataResolveExecutor;
pub use spawn::EnrichmentSpawnRule;

/// Schema of the items that trigger enrichment.
///
/// This MUST be the ref imbib actually writes — `imbib-core`'s
/// `unified::conversion::publication_to_item` emits `imbib/bibliography-entry`,
/// and the store matches `items.schema_ref` by EXACT EQUALITY. Until
/// 2026-07-29 this constant read `bibliography-entry@1.0.0`, a spelling
/// nothing has ever written, so `EnrichmentSpawnRule::trigger_schema` matched
/// zero rows and the entire enrichment pipeline never spawned a single task —
/// silently, with no error and no log line, looking exactly like "no new
/// papers yet". `enrichment_trigger_matches_the_ref_imbib_actually_writes`
/// in tests/enrichment_pipeline.rs pins this against imbib's real writer;
/// see schema-refs.json for the canonical spelling of every ref.
pub const BIBLIOGRAPHY_ENTRY_SCHEMA: &str = "imbib/bibliography-entry";

/// Task kinds (dispatch keys) of the pipeline.
pub const KIND_METADATA_RESOLVE: &str = "metadata-resolve";
pub const KIND_KEYWORD_TAG: &str = "keyword-tag";
