//! Deterministic merge of enrichment metadata records.
//!
//! Port of the Swift `EnrichmentData.merging(with:)` algorithm
//! (`EnrichmentTypes.swift`) plus the cross-source dedup pass that
//! `EnrichmentService.runBackgroundLoop` does implicitly when multiple
//! plugins return data for the same publication.
//!
//! Strategy: for each scalar field, the higher-priority source wins; if the
//! higher-priority source's field is missing/empty, fall back to the
//! lower-priority value. For list-valued fields (identifiers, pdf_links) we
//! union without duplicates, then sort canonically so the output is
//! deterministic given the same inputs.

use std::collections::BTreeMap;

use super::priority::{EnrichmentSourceId, SourcePriority};

/// Lightweight enrichment metadata DTO used by the merge strategy. Intentionally
/// flatter than `crate::domain::EnrichmentData` so the merge logic stays
/// independent of Publication storage shape — this is the type the future
/// `imbib-service` layer will hand to Rust as it consolidates plugin output.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PaperMetadata {
    /// Which source produced this record. Drives tie-breaking.
    pub source: Option<EnrichmentSourceId>,
    pub title: Option<String>,
    pub year: Option<i32>,
    pub authors: Vec<String>,
    pub abstract_text: Option<String>,
    pub venue: Option<String>,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub bibcode: Option<String>,
    pub pmid: Option<String>,
    pub citation_count: Option<i64>,
    pub reference_count: Option<i64>,
    pub pdf_urls: Vec<String>,
    /// Free-form extras (e.g. `s2_id`, `openalex_id`). Merged by key,
    /// higher-priority wins.
    pub extras: BTreeMap<String, String>,
}

/// Result of a merge operation. Lists which fields actually changed from
/// `base` so the caller can decide whether to persist.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MergeOutcome {
    pub merged: PaperMetadata,
    /// Names of fields whose value differs between `base` and `merged`.
    pub changed_fields: Vec<&'static str>,
}

/// Merge `incoming` into `base`. `priority` decides who wins when both have a
/// value for the same field.
///
/// Semantics:
/// - Scalar fields: higher-priority source wins. Missing/empty in higher
///   priority → fall back to other.
/// - `authors`: higher-priority source's list wins outright if non-empty.
/// - Identifier fields: higher-priority wins. Missing in winner → fall back.
/// - `pdf_urls`: union (dedup, ordering: priority-winner first, others appended).
/// - `extras`: per-key merge using same rule as scalars.
pub fn merge_metadata(
    base: PaperMetadata,
    incoming: PaperMetadata,
    priority: &SourcePriority,
) -> MergeOutcome {
    // Determine which side wins ties (rank smaller = higher priority).
    let base_rank = base
        .source
        .as_ref()
        .map(|s| priority.rank(s))
        .unwrap_or(usize::MAX);
    let incoming_rank = incoming
        .source
        .as_ref()
        .map(|s| priority.rank(s))
        .unwrap_or(usize::MAX);

    let (winner, loser) = if incoming_rank < base_rank {
        (&incoming, &base)
    } else {
        (&base, &incoming)
    };

    let merged = PaperMetadata {
        source: winner.source.clone().or_else(|| loser.source.clone()),
        title: pick_string(&winner.title, &loser.title),
        year: winner.year.or(loser.year),
        authors: pick_list(&winner.authors, &loser.authors),
        abstract_text: pick_string(&winner.abstract_text, &loser.abstract_text),
        venue: pick_string(&winner.venue, &loser.venue),
        doi: pick_string(&winner.doi, &loser.doi),
        arxiv_id: pick_string(&winner.arxiv_id, &loser.arxiv_id),
        bibcode: pick_string(&winner.bibcode, &loser.bibcode),
        pmid: pick_string(&winner.pmid, &loser.pmid),
        citation_count: winner.citation_count.or(loser.citation_count),
        reference_count: winner.reference_count.or(loser.reference_count),
        pdf_urls: merge_urls(&winner.pdf_urls, &loser.pdf_urls),
        extras: merge_extras(&winner.extras, &loser.extras),
    };

    let changed_fields = diff_fields(&base, &merged);

    MergeOutcome { merged, changed_fields }
}

/// Higher-priority wins; if missing or empty, fall back.
fn pick_string(winner: &Option<String>, loser: &Option<String>) -> Option<String> {
    match winner {
        Some(s) if !s.is_empty() => Some(s.clone()),
        _ => loser.clone(),
    }
}

fn pick_list(winner: &[String], loser: &[String]) -> Vec<String> {
    if !winner.is_empty() {
        winner.to_vec()
    } else {
        loser.to_vec()
    }
}

/// Union (winner first, then loser entries not already present). Preserves
/// order from the winner and is therefore deterministic.
fn merge_urls(winner: &[String], loser: &[String]) -> Vec<String> {
    let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
    let mut out = Vec::with_capacity(winner.len() + loser.len());
    for url in winner {
        if seen.insert(url.as_str()) {
            out.push(url.clone());
        }
    }
    for url in loser {
        if seen.insert(url.as_str()) {
            out.push(url.clone());
        }
    }
    out
}

fn merge_extras(
    winner: &BTreeMap<String, String>,
    loser: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut out = loser.clone();
    for (k, v) in winner {
        if !v.is_empty() {
            out.insert(k.clone(), v.clone());
        } else if !out.contains_key(k) {
            out.insert(k.clone(), v.clone());
        }
    }
    out
}

fn diff_fields(base: &PaperMetadata, merged: &PaperMetadata) -> Vec<&'static str> {
    let mut changed = Vec::new();
    if base.title != merged.title {
        changed.push("title");
    }
    if base.year != merged.year {
        changed.push("year");
    }
    if base.authors != merged.authors {
        changed.push("authors");
    }
    if base.abstract_text != merged.abstract_text {
        changed.push("abstract_text");
    }
    if base.venue != merged.venue {
        changed.push("venue");
    }
    if base.doi != merged.doi {
        changed.push("doi");
    }
    if base.arxiv_id != merged.arxiv_id {
        changed.push("arxiv_id");
    }
    if base.bibcode != merged.bibcode {
        changed.push("bibcode");
    }
    if base.pmid != merged.pmid {
        changed.push("pmid");
    }
    if base.citation_count != merged.citation_count {
        changed.push("citation_count");
    }
    if base.reference_count != merged.reference_count {
        changed.push("reference_count");
    }
    if base.pdf_urls != merged.pdf_urls {
        changed.push("pdf_urls");
    }
    if base.extras != merged.extras {
        changed.push("extras");
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ads_record() -> PaperMetadata {
        PaperMetadata {
            source: Some("ads".into()),
            title: Some("ADS Title".to_string()),
            year: Some(2024),
            authors: vec!["Smith, J.".to_string()],
            abstract_text: Some("ADS abstract".to_string()),
            venue: Some("ApJ".to_string()),
            bibcode: Some("2024ApJ...".to_string()),
            citation_count: Some(42),
            ..Default::default()
        }
    }

    fn crossref_record() -> PaperMetadata {
        PaperMetadata {
            source: Some("crossref".into()),
            title: Some("Crossref Title".to_string()),
            year: Some(2024),
            doi: Some("10.1234/foo".to_string()),
            citation_count: Some(40),
            ..Default::default()
        }
    }

    #[test]
    fn higher_priority_wins_scalar_conflict() {
        let p = SourcePriority::default();
        // Crossref → ADS: ADS has higher priority and a title; ADS wins.
        let outcome = merge_metadata(crossref_record(), ads_record(), &p);
        assert_eq!(outcome.merged.title.as_deref(), Some("ADS Title"));
        assert_eq!(outcome.merged.citation_count, Some(42));
        // Crossref-only field (DOI) survives.
        assert_eq!(outcome.merged.doi.as_deref(), Some("10.1234/foo"));
    }

    #[test]
    fn higher_priority_with_missing_field_falls_back() {
        let p = SourcePriority::default();
        let mut ads = ads_record();
        ads.doi = None; // ADS record lacks DOI
        let outcome = merge_metadata(crossref_record(), ads, &p);
        // DOI comes from Crossref since ADS lacks one.
        assert_eq!(outcome.merged.doi.as_deref(), Some("10.1234/foo"));
    }

    #[test]
    fn empty_string_in_winner_treated_as_missing() {
        let p = SourcePriority::default();
        let mut ads = ads_record();
        ads.venue = Some(String::new()); // empty → not a real value
        let mut crossref = crossref_record();
        crossref.venue = Some("Other Venue".to_string());
        let outcome = merge_metadata(crossref, ads, &p);
        assert_eq!(outcome.merged.venue.as_deref(), Some("Other Venue"));
    }

    #[test]
    fn pdf_urls_union_dedup_winner_first() {
        let p = SourcePriority::default();
        let mut ads = ads_record();
        ads.pdf_urls = vec!["https://ads/paper.pdf".to_string(), "https://shared/p.pdf".to_string()];
        let mut crossref = crossref_record();
        crossref.pdf_urls = vec!["https://shared/p.pdf".to_string(), "https://crossref/p.pdf".to_string()];
        let outcome = merge_metadata(crossref, ads, &p);
        // Winner = ADS → ADS URLs first, then Crossref-only URL appended.
        assert_eq!(
            outcome.merged.pdf_urls,
            vec![
                "https://ads/paper.pdf".to_string(),
                "https://shared/p.pdf".to_string(),
                "https://crossref/p.pdf".to_string(),
            ]
        );
    }

    #[test]
    fn unknown_source_loses_to_known() {
        let p = SourcePriority::default();
        let unknown = PaperMetadata {
            source: Some("mystery".into()),
            title: Some("Unknown Title".to_string()),
            ..Default::default()
        };
        let outcome = merge_metadata(unknown, ads_record(), &p);
        assert_eq!(outcome.merged.title.as_deref(), Some("ADS Title"));
    }

    #[test]
    fn both_unknown_sources_tie_to_base() {
        // When neither has a known source, both rank usize::MAX → base wins
        // because we only swap on strictly-lower rank.
        let p = SourcePriority::default();
        let a = PaperMetadata {
            source: Some("mystery_a".into()),
            title: Some("A".to_string()),
            ..Default::default()
        };
        let b = PaperMetadata {
            source: Some("mystery_b".into()),
            title: Some("B".to_string()),
            ..Default::default()
        };
        let outcome = merge_metadata(a, b, &p);
        assert_eq!(outcome.merged.title.as_deref(), Some("A"));
    }

    #[test]
    fn changed_fields_reflect_diff_from_base() {
        let p = SourcePriority::default();
        let base = crossref_record();
        let incoming = ads_record();
        let outcome = merge_metadata(base.clone(), incoming, &p);
        // Title and venue should change; year stays at 2024.
        assert!(outcome.changed_fields.contains(&"title"));
        assert!(outcome.changed_fields.contains(&"venue"));
        assert!(!outcome.changed_fields.contains(&"year"));
    }

    #[test]
    fn identical_records_produce_no_changes() {
        let p = SourcePriority::default();
        let record = ads_record();
        let outcome = merge_metadata(record.clone(), record, &p);
        assert!(outcome.changed_fields.is_empty());
    }

    #[test]
    fn extras_merge_higher_priority_wins() {
        let p = SourcePriority::default();
        let mut ads = ads_record();
        ads.extras.insert("ads_uid".to_string(), "ADS-1".to_string());
        ads.extras.insert("shared".to_string(), "from-ads".to_string());

        let mut crossref = crossref_record();
        crossref.extras.insert("crossref_member".to_string(), "297".to_string());
        crossref.extras.insert("shared".to_string(), "from-crossref".to_string());

        let outcome = merge_metadata(crossref, ads, &p);
        assert_eq!(outcome.merged.extras.get("ads_uid"), Some(&"ADS-1".to_string()));
        assert_eq!(outcome.merged.extras.get("crossref_member"), Some(&"297".to_string()));
        // Shared key resolved in favor of ADS.
        assert_eq!(outcome.merged.extras.get("shared"), Some(&"from-ads".to_string()));
    }

    #[test]
    fn authors_winner_list_replaces_loser() {
        let p = SourcePriority::default();
        let mut ads = ads_record();
        ads.authors = vec!["Smith, J.".to_string(), "Doe, J.".to_string()];
        let mut crossref = crossref_record();
        crossref.authors = vec!["Roe, R.".to_string()];
        let outcome = merge_metadata(crossref, ads, &p);
        // ADS wins outright.
        assert_eq!(outcome.merged.authors, vec!["Smith, J.".to_string(), "Doe, J.".to_string()]);
    }

    #[test]
    fn authors_falls_back_when_winner_empty() {
        let p = SourcePriority::default();
        let mut ads = ads_record();
        ads.authors.clear();
        let mut crossref = crossref_record();
        crossref.authors = vec!["Roe, R.".to_string()];
        let outcome = merge_metadata(crossref, ads, &p);
        assert_eq!(outcome.merged.authors, vec!["Roe, R.".to_string()]);
    }

    #[test]
    fn no_source_treated_as_unknown_priority() {
        let p = SourcePriority::default();
        let ads = ads_record();
        let unsourced = PaperMetadata {
            source: None,
            title: Some("Other".to_string()),
            ..Default::default()
        };
        let outcome = merge_metadata(unsourced, ads.clone(), &p);
        // ADS is known → wins.
        assert_eq!(outcome.merged.title.as_deref(), Some("ADS Title"));
        // Source propagated to result.
        assert_eq!(outcome.merged.source.as_ref().map(|s| s.as_str()), Some("ads"));
    }
}
