//! Enrichment strategy — pure-logic decisions extracted from Swift
//! `EnrichmentService.swift`.
//!
//! Three submodules:
//!   - [`merge`] — deterministic field-by-field merge of metadata records
//!     from multiple sources, governed by a `SourcePriority`.
//!   - [`retry`] — `RetryPolicy` with `next_delay` decisions. Does NOT spawn
//!     tasks; the caller decides whether to actually sleep.
//!   - [`priority`] — `SourcePriority` and the default ADS > Crossref >
//!     arXiv > OpenAlex > PubMed > Semantic Scholar > DBLP order, mirroring
//!     `EnrichmentSettings.default` in `EnrichmentTypes.swift:402` plus the
//!     informal preference ordering documented in the Swift plugin shims.
//!
//! The async orchestration loop (queue dequeue → call plugin → write result)
//! stays in Swift for now per the migration plan; only the *strategy* (what to
//! merge, when to retry, which source wins ties) lives here.

pub mod merge;
pub mod priority;
pub mod retry;

pub use merge::{merge_metadata, MergeOutcome, PaperMetadata};
pub use priority::{EnrichmentSourceId, SourcePriority};
pub use retry::{RetryDecision, RetryPolicy};
