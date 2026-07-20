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
//! - [`EnrichmentSpawnRule`] — reacts to new `bibliography-entry@1.0.0`
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
pub const BIBLIOGRAPHY_ENTRY_SCHEMA: &str = "bibliography-entry@1.0.0";

/// Task kinds (dispatch keys) of the pipeline.
pub const KIND_METADATA_RESOLVE: &str = "metadata-resolve";
pub const KIND_KEYWORD_TAG: &str = "keyword-tag";
