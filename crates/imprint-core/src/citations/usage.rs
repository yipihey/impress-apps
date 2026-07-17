//! Cite-key usage aggregation.
//!
//! Ported from the per-section diff logic in
//! `apps/imprint/Packages/ImprintCore/Sources/ImprintCore/CitationUsageTracker.swift`.
//! The Swift side persists a `citation-usage@1.0.0` record per
//! `(section_id, cite_key)` pair into the shared imprint/imbib store. We do
//! the in-memory aggregation in Rust so a TUI, MCP tool, or CLI can compute
//! "papers cited in this manuscript" without going through the persistence
//! layer.
//!
//! ## Departures from Swift
//!
//! - The Swift `CitationUsageTracker` keeps `firstCited` timestamps and
//!   reaches into a paper-ID resolver. Those concerns belong to the
//!   persistence layer, not the extraction layer; they are deliberately
//!   omitted here.
//! - We add **first-use position** (byte offset of the earliest occurrence)
//!   and **duplicate counts** that the Swift code didn't compute. They
//!   come naturally from the index and are useful for "next citation"
//!   navigation in a TUI.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use super::extract::{CiteCommand, CiteKeyUsage};

/// Aggregated information about how a single cite key is used in a document.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CiteKeyAggregate {
    pub key: String,
    /// Byte offset of the earliest occurrence in the source.
    pub first_use_offset: usize,
    /// Number of times this key appears (raw count, not deduped).
    pub count: usize,
    /// Set of distinct citation commands that referenced this key.
    pub commands: Vec<CiteCommand>,
    /// Every occurrence in source order.
    pub usages: Vec<CiteKeyUsage>,
}

impl CiteKeyAggregate {
    /// Convenience: was this key cited more than once?
    pub fn is_duplicated(&self) -> bool {
        self.count > 1
    }
}

/// Builds a per-key aggregate over a sequence of usages. Construction is
/// linear in the input. The index is sorted by first-use position so a
/// downstream "list the cited keys in document order" matches what a reader
/// sees on the page.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct UsageIndex {
    by_key: BTreeMap<String, CiteKeyAggregate>,
}

impl UsageIndex {
    /// Empty index.
    pub fn new() -> Self {
        Self::default()
    }

    /// Build an index from an arbitrary iterator of usages. Iteration order
    /// of the input determines the order of `usages` per aggregate, so for
    /// best results pass usages already sorted by byte offset (which is
    /// what `extract_cite_keys` returns).
    pub fn from_usages<I: IntoIterator<Item = CiteKeyUsage>>(usages: I) -> Self {
        let mut idx = Self::new();
        for u in usages {
            idx.insert(u);
        }
        idx
    }

    /// Insert one usage. Idempotent w.r.t. ordering — calling with the same
    /// usage twice will double-count it (intentional: we surface duplicate
    /// counts).
    pub fn insert(&mut self, usage: CiteKeyUsage) {
        let entry = self
            .by_key
            .entry(usage.key.clone())
            .or_insert_with(|| CiteKeyAggregate {
                key: usage.key.clone(),
                first_use_offset: usage.byte_offset,
                count: 0,
                commands: Vec::new(),
                usages: Vec::new(),
            });
        if usage.byte_offset < entry.first_use_offset {
            entry.first_use_offset = usage.byte_offset;
        }
        entry.count += 1;
        if !entry.commands.contains(&usage.command) {
            entry.commands.push(usage.command);
        }
        entry.usages.push(usage);
    }

    /// Total number of distinct cite keys.
    pub fn len(&self) -> usize {
        self.by_key.len()
    }

    /// True if no usages have been seen.
    pub fn is_empty(&self) -> bool {
        self.by_key.is_empty()
    }

    /// Lookup an aggregate by key.
    pub fn get(&self, key: &str) -> Option<&CiteKeyAggregate> {
        self.by_key.get(key)
    }

    /// All aggregates, sorted alphabetically by key (matches Swift's
    /// `citeKeys.sorted()` contract for `extractedCiteKeys`).
    pub fn aggregates_alphabetical(&self) -> Vec<&CiteKeyAggregate> {
        self.by_key.values().collect()
    }

    /// All aggregates, sorted by first-use position in the document. Useful
    /// for rendering a "References" list in citation order.
    pub fn aggregates_by_first_use(&self) -> Vec<&CiteKeyAggregate> {
        let mut v: Vec<&CiteKeyAggregate> = self.by_key.values().collect();
        v.sort_by_key(|a| a.first_use_offset);
        v
    }

    /// Cite keys that appear more than once.
    pub fn duplicated_keys(&self) -> Vec<&str> {
        self.by_key
            .values()
            .filter(|a| a.is_duplicated())
            .map(|a| a.key.as_str())
            .collect()
    }

    /// Total number of usages (sum of all counts).
    pub fn total_usages(&self) -> usize {
        self.by_key.values().map(|a| a.count).sum()
    }

    /// Compute the **diff** between two index snapshots. Returned tuple is
    /// `(added, removed, retained)` cite keys. The Swift tracker uses this
    /// to drive upsert/delete writes against the shared store; we keep the
    /// shape so the Service trait layer can wire it up.
    pub fn diff(prev: &UsageIndex, next: &UsageIndex) -> UsageDiff {
        let prev_keys: std::collections::BTreeSet<&str> =
            prev.by_key.keys().map(|s| s.as_str()).collect();
        let next_keys: std::collections::BTreeSet<&str> =
            next.by_key.keys().map(|s| s.as_str()).collect();

        let added: Vec<String> = next_keys
            .difference(&prev_keys)
            .map(|s| s.to_string())
            .collect();
        let removed: Vec<String> = prev_keys
            .difference(&next_keys)
            .map(|s| s.to_string())
            .collect();
        let retained: Vec<String> = prev_keys
            .intersection(&next_keys)
            .map(|s| s.to_string())
            .collect();

        UsageDiff {
            added,
            removed,
            retained,
        }
    }
}

/// Cite-key diff between two index snapshots.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageDiff {
    pub added: Vec<String>,
    pub removed: Vec<String>,
    pub retained: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::super::extract::{extract_cite_keys, CitationSyntax};
    use super::*;

    #[test]
    fn empty_index() {
        let idx = UsageIndex::new();
        assert!(idx.is_empty());
        assert_eq!(idx.len(), 0);
        assert!(idx.duplicated_keys().is_empty());
    }

    #[test]
    fn aggregates_alphabetical_order() {
        let src = "@b @a @c";
        let idx = UsageIndex::from_usages(extract_cite_keys(src, CitationSyntax::Typst));
        let keys: Vec<&str> = idx
            .aggregates_alphabetical()
            .iter()
            .map(|a| a.key.as_str())
            .collect();
        assert_eq!(keys, vec!["a", "b", "c"]);
    }

    #[test]
    fn aggregates_by_first_use_match_source_order() {
        let src = "@b @a @c @a"; // first-use: b@0..., a@..., c@...
        let idx = UsageIndex::from_usages(extract_cite_keys(src, CitationSyntax::Typst));
        let keys: Vec<&str> = idx
            .aggregates_by_first_use()
            .iter()
            .map(|a| a.key.as_str())
            .collect();
        assert_eq!(keys, vec!["b", "a", "c"]);
    }

    #[test]
    fn duplicates_are_counted() {
        let src = r"\cite{a,b,a,b,a}";
        let idx = UsageIndex::from_usages(extract_cite_keys(src, CitationSyntax::Latex));
        assert_eq!(idx.get("a").unwrap().count, 3);
        assert_eq!(idx.get("b").unwrap().count, 2);
        let mut dups = idx.duplicated_keys();
        dups.sort();
        assert_eq!(dups, vec!["a", "b"]);
        assert_eq!(idx.total_usages(), 5);
    }

    #[test]
    fn commands_list_is_distinct() {
        let src = r"\cite{a} \citep{a} \citet{a} \cite{a}";
        let idx = UsageIndex::from_usages(extract_cite_keys(src, CitationSyntax::Latex));
        let agg = idx.get("a").unwrap();
        assert_eq!(agg.count, 4);
        // Should contain Cite, Citep, Citet but no duplicates.
        assert_eq!(agg.commands.len(), 3);
        assert!(agg.commands.contains(&CiteCommand::Cite));
        assert!(agg.commands.contains(&CiteCommand::Citep));
        assert!(agg.commands.contains(&CiteCommand::Citet));
    }

    #[test]
    fn diff_added_removed_retained() {
        let a = UsageIndex::from_usages(extract_cite_keys("@a @b", CitationSyntax::Typst));
        let b = UsageIndex::from_usages(extract_cite_keys("@b @c", CitationSyntax::Typst));
        let d = UsageIndex::diff(&a, &b);
        assert_eq!(d.added, vec!["c".to_string()]);
        assert_eq!(d.removed, vec!["a".to_string()]);
        assert_eq!(d.retained, vec!["b".to_string()]);
    }

    #[test]
    fn first_use_offset_is_minimum() {
        // Note: `X@a` would be rejected (alpha char before `@` is part of
        // the word-boundary guard), so we use spaces.
        let src = " @a  @a";
        let idx = UsageIndex::from_usages(extract_cite_keys(src, CitationSyntax::Typst));
        let agg = idx.get("a").unwrap();
        // First `@a` starts at index 1 (a follows `@` at byte 1).
        // The key itself starts at offset 2 (the `a` after `@`).
        assert_eq!(agg.first_use_offset, 2);
    }
}
