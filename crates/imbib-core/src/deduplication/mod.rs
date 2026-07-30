//! Deduplication algorithms for detecting duplicate publications
//!
//! This module provides similarity scoring and matching functions
//! to identify potential duplicate entries.

mod normalization;
mod orchestration;
mod similarity;

#[cfg(feature = "native")]
pub use normalization::{normalize_author_export, normalize_title_export};
#[cfg(feature = "native")]
pub use orchestration::{
    dedup_source_priorities, dedup_source_priority, deduplicate_search_results,
    default_deduplication_config, fuzzy_match_results, shares_identifier,
};
pub use orchestration::{
    source_priority_rank, DeduplicatedGroup, DeduplicationConfig, DeduplicationInput,
    SourcePriorityRow, SOURCE_PRIORITY, UNRANKED_SOURCE_PRIORITY,
};
#[cfg(feature = "native")]
pub use similarity::{
    authors_overlap, calculate_publication_similarity, calculate_similarity, find_duplicates,
    titles_match,
};
pub use similarity::{DeduplicationMatch, DuplicateGroup};
