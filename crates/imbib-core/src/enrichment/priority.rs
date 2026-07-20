//! Source priority for enrichment merge tie-breaking.
//!
//! Mirrors `EnrichmentSource` (`EnrichmentTypes.swift`) plus the broader set
//! of sources used by `BuiltIn/*` plugins. The default ordering is:
//!
//! ```text
//! ADS > Crossref > arXiv > OpenAlex > PubMed > Semantic Scholar > DBLP > WoS > Unknown
//! ```
//!
//! Rationale (from the Swift code and accompanying docs):
//! - ADS is canonical for astronomy/physics and has the richest field coverage.
//! - Crossref provides authoritative DOI metadata.
//! - arXiv is the source of truth for preprint identifiers.
//! - OpenAlex aggregates across many providers.
//! - PubMed dominates biomedical metadata.
//! - Semantic Scholar / DBLP / WoS round out CS and bibliometric coverage.
//!
//! The default order is configurable per-user in the Swift settings (`EnrichmentSettings.sourcePriority`).

use std::collections::HashMap;

/// Stable string IDs for the enrichment sources we know about. New sources
/// can be added without breaking serialization.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct EnrichmentSourceId(pub String);

impl EnrichmentSourceId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into().to_lowercase())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl From<&str> for EnrichmentSourceId {
    fn from(s: &str) -> Self {
        Self::new(s)
    }
}

impl From<String> for EnrichmentSourceId {
    fn from(s: String) -> Self {
        Self::new(s)
    }
}

/// Ordered priority list. Earlier sources win field-level conflicts.
///
/// `SourcePriority::default()` returns the canonical
/// `ADS > Crossref > arXiv > OpenAlex > PubMed > Semantic Scholar > DBLP > WoS`
/// ordering.
#[derive(Debug, Clone)]
pub struct SourcePriority {
    /// Ordered list; index 0 is highest priority.
    order: Vec<EnrichmentSourceId>,
    /// Cache: source id → rank (0 = highest). Recomputed on construction.
    rank_cache: HashMap<EnrichmentSourceId, usize>,
}

impl SourcePriority {
    /// Build a priority list. Duplicates in `order` are kept (first
    /// occurrence wins). Unknown sources passed to `rank()` get
    /// `usize::MAX`.
    pub fn new(order: Vec<EnrichmentSourceId>) -> Self {
        let mut rank_cache = HashMap::with_capacity(order.len());
        for (i, src) in order.iter().enumerate() {
            // Only record the *first* index for each source.
            rank_cache.entry(src.clone()).or_insert(i);
        }
        Self { order, rank_cache }
    }

    /// Rank of a source (0 = highest). Returns `usize::MAX` for unknowns,
    /// so they always lose tie-breaks to any known source.
    pub fn rank(&self, source: &EnrichmentSourceId) -> usize {
        self.rank_cache.get(source).copied().unwrap_or(usize::MAX)
    }

    /// True if `a` has strictly higher priority than `b`.
    pub fn outranks(&self, a: &EnrichmentSourceId, b: &EnrichmentSourceId) -> bool {
        self.rank(a) < self.rank(b)
    }

    /// Read-only access to the ordered list.
    pub fn ordered(&self) -> &[EnrichmentSourceId] {
        &self.order
    }
}

impl Default for SourcePriority {
    fn default() -> Self {
        Self::new(vec![
            EnrichmentSourceId::new("ads"),
            EnrichmentSourceId::new("crossref"),
            EnrichmentSourceId::new("arxiv"),
            EnrichmentSourceId::new("openalex"),
            EnrichmentSourceId::new("pubmed"),
            EnrichmentSourceId::new("semanticscholar"),
            EnrichmentSourceId::new("dblp"),
            EnrichmentSourceId::new("wos"),
        ])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_order_matches_swift() {
        let p = SourcePriority::default();
        assert_eq!(p.rank(&"ads".into()), 0);
        assert_eq!(p.rank(&"crossref".into()), 1);
        assert_eq!(p.rank(&"arxiv".into()), 2);
        assert_eq!(p.rank(&"openalex".into()), 3);
        assert_eq!(p.rank(&"pubmed".into()), 4);
        assert_eq!(p.rank(&"semanticscholar".into()), 5);
        assert_eq!(p.rank(&"dblp".into()), 6);
        assert_eq!(p.rank(&"wos".into()), 7);
    }

    #[test]
    fn case_insensitive() {
        let p = SourcePriority::default();
        assert_eq!(p.rank(&"ADS".into()), 0);
        assert_eq!(p.rank(&"Crossref".into()), 1);
    }

    #[test]
    fn unknown_source_is_lowest() {
        let p = SourcePriority::default();
        assert_eq!(p.rank(&"mystery".into()), usize::MAX);
        assert!(!p.outranks(&"mystery".into(), &"ads".into()));
        assert!(p.outranks(&"ads".into(), &"mystery".into()));
    }

    #[test]
    fn outranks_strict() {
        let p = SourcePriority::default();
        assert!(p.outranks(&"ads".into(), &"crossref".into()));
        assert!(!p.outranks(&"crossref".into(), &"ads".into()));
        // Same source = not a strict outrank.
        assert!(!p.outranks(&"ads".into(), &"ads".into()));
    }

    #[test]
    fn custom_order_overrides_default() {
        let p = SourcePriority::new(vec!["openalex".into(), "ads".into()]);
        assert!(p.outranks(&"openalex".into(), &"ads".into()));
        assert_eq!(p.rank(&"crossref".into()), usize::MAX);
    }

    #[test]
    fn duplicates_in_order_keep_first_index() {
        let p = SourcePriority::new(vec!["ads".into(), "crossref".into(), "ads".into()]);
        // ADS keeps rank 0 (first occurrence), Crossref at 1.
        assert_eq!(p.rank(&"ads".into()), 0);
        assert_eq!(p.rank(&"crossref".into()), 1);
    }
}
