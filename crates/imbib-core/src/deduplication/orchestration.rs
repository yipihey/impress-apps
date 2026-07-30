//! Search result deduplication orchestration
//!
//! Groups search results from multiple sources by shared identifiers (and,
//! optionally, by fuzzy title/author/year match), then selects the primary
//! result of each group by source priority.
//!
//! ## Stage 7 item 5 — one dedup, not two
//!
//! This module and Swift's `DeduplicationService` were parallel
//! implementations of the same job, and they had already drifted:
//!
//! - Swift grouped **transitively through an identifier index** (O(n)): a
//!   result joins the group its DOI *or* arXiv id *or* PMID *or* bibcode
//!   already points at, and then registers all of its own identifiers for that
//!   group. Rust compared each unprocessed result only against the group's
//!   *first* member (O(n²)), so `A(doi) — B(doi,arxiv) — C(arxiv)` produced two
//!   groups in Rust and one in Swift. The transitive form is both correct and
//!   cheaper, so it is what survives; see [`identifier_group_pass`].
//! - Swift never fuzzy-matched. `DeduplicationService.fuzzyMatch` existed, was
//!   fully written, and was **never called** — `deduplicate` only ever grouped
//!   by identifier. So [`DeduplicationConfig::default`] has fuzzy matching
//!   **off**: turning it on is a real behaviour change (it merges papers that
//!   share no identifier at all) and must be an explicit decision, not a
//!   default inherited from a function nobody called.
//! - Swift carried a numeric [`SOURCE_PRIORITY`] table (crossref 10 … dblp 70,
//!   unknown 100); Rust carried the same order as a `Vec<String>` position
//!   lookup. Both orders agree, so the table is now the single spelling and the
//!   config's `source_priority` list overrides it when non-empty.
//! - Swift short-circuited when every result came from one source (each source
//!   already dedups internally, and two genuinely distinct papers in one
//!   source's own results must not be merged). Reproduced in
//!   [`deduplicate_search_results_internal`].

use std::collections::{HashMap, HashSet};
use strsim::jaro_winkler;

/// Source priority for picking a group's primary result — **lower wins**.
///
/// Publisher metadata (Crossref) beats curated indexes (PubMed, ADS), which
/// beat aggregators, which beat preprint servers. The literal numbers (rather
/// than 0,1,2,…) leave room to slot a source in without renumbering.
pub const SOURCE_PRIORITY: [(&str, u32); 7] = [
    // Publisher source, most authoritative.
    ("crossref", 10),
    // Curated.
    ("pubmed", 20),
    ("ads", 30),
    ("semanticscholar", 40),
    ("openalex", 50),
    ("arxiv", 60),
    ("dblp", 70),
];

/// Priority assigned to a source that is not in [`SOURCE_PRIORITY`] — behind
/// every known source, but ahead of nothing, so unknown sources tie among
/// themselves and the original result order breaks the tie.
pub const UNRANKED_SOURCE_PRIORITY: u32 = 100;

/// Priority of `source_id`, or [`UNRANKED_SOURCE_PRIORITY`].
pub fn source_priority_rank(source_id: &str) -> u32 {
    SOURCE_PRIORITY
        .iter()
        .find(|(name, _)| *name == source_id)
        .map(|(_, rank)| *rank)
        .unwrap_or(UNRANKED_SOURCE_PRIORITY)
}

/// A group of deduplicated search results
#[derive(Debug, Clone, uniffi::Record)]
pub struct DeduplicatedGroup {
    /// Index of the primary result in the original list (highest priority source)
    pub primary_index: u32,
    /// Indices of alternate results (same paper from other sources)
    pub alternate_indices: Vec<u32>,
    /// Combined identifiers from all results in the group (key: type, value: id)
    pub identifiers: HashMap<String, String>,
    /// Confidence score for the grouping (1.0 = exact identifier match)
    pub confidence: f64,
}

/// Configuration for deduplication
#[derive(Debug, Clone, uniffi::Record)]
pub struct DeduplicationConfig {
    /// Minimum title similarity threshold (0.0 - 1.0)
    pub title_threshold: f64,
    /// Whether to additionally merge groups that share no identifier but match
    /// on title + author + year. **Off by default** — see the module docs.
    pub use_fuzzy_matching: bool,
    /// Source priority order, highest priority first. Empty (the default) means
    /// "use [`SOURCE_PRIORITY`]"; a non-empty list overrides it entirely and
    /// sources missing from it rank behind every listed one.
    pub source_priority: Vec<String>,
}

impl Default for DeduplicationConfig {
    fn default() -> Self {
        Self {
            title_threshold: 0.85,
            // The shipping Swift path never fuzzy-matched. Enabling it here
            // would silently start merging papers that share no identifier.
            use_fuzzy_matching: false,
            // Empty = the SOURCE_PRIORITY table.
            source_priority: vec![],
        }
    }
}

/// A simplified search result for deduplication
/// (avoids importing the full SearchResult type)
#[derive(Debug, Clone, uniffi::Record)]
pub struct DeduplicationInput {
    /// Unique identifier for this result
    pub id: String,
    /// Source ID (e.g., "arxiv", "crossref")
    pub source_id: String,
    /// Paper title
    pub title: String,
    /// First author's last name (for fuzzy matching)
    pub first_author_last_name: Option<String>,
    /// Publication year
    pub year: Option<i32>,
    /// DOI if available
    pub doi: Option<String>,
    /// arXiv ID if available
    pub arxiv_id: Option<String>,
    /// PubMed ID if available
    pub pmid: Option<String>,
    /// ADS bibcode if available
    pub bibcode: Option<String>,
    /// Semantic Scholar id, if available. Not a grouping key (no two sources
    /// report it), but it is carried into the group's identifier map so an
    /// enrichment pass downstream can use it.
    pub semantic_scholar_id: Option<String>,
    /// OpenAlex id, if available. Carried, not matched — as above.
    pub open_alex_id: Option<String>,
}

pub(crate) fn deduplicate_search_results_internal(
    results: Vec<DeduplicationInput>,
    config: DeduplicationConfig,
) -> Vec<DeduplicatedGroup> {
    if results.is_empty() {
        return vec![];
    }

    // Single-source fast path. Each source already dedups its own results, and
    // two distinct papers within one source's answer must not be merged just
    // because their titles are close — so there is nothing to do but wrap each
    // result in its own group.
    let first_source = &results[0].source_id;
    if results.iter().all(|r| &r.source_id == first_source) {
        return results
            .iter()
            .enumerate()
            .map(|(idx, result)| {
                let mut identifiers = HashMap::new();
                collect_identifiers(result, &mut identifiers);
                DeduplicatedGroup {
                    primary_index: idx as u32,
                    alternate_indices: vec![],
                    identifiers,
                    confidence: 0.0,
                }
            })
            .collect();
    }

    let mut group_members = identifier_group_pass(&results);
    let mut confidences = vec![0.0_f64; group_members.len()];

    if config.use_fuzzy_matching {
        fuzzy_merge_pass(&results, &mut group_members, &mut confidences, &config);
    }

    group_members
        .into_iter()
        .zip(confidences)
        .map(|(members, fuzzy_confidence)| {
            let mut identifiers = HashMap::new();
            for &idx in &members {
                collect_identifiers(&results[idx], &mut identifiers);
            }

            // Primary = best source; ties broken by original position so the
            // choice never depends on sort stability.
            let mut ordered = members.clone();
            ordered.sort_by_key(|&idx| (priority_of(&results[idx].source_id, &config), idx));

            let confidence = if fuzzy_confidence > 0.0 {
                fuzzy_confidence
            } else if ordered.len() > 1 {
                // Grouped without a fuzzy score, so it was an identifier match.
                1.0
            } else {
                0.0
            };

            DeduplicatedGroup {
                primary_index: ordered[0] as u32,
                alternate_indices: ordered[1..].iter().map(|&idx| idx as u32).collect(),
                identifiers,
                confidence,
            }
        })
        .collect()
}

/// Group results transitively through an identifier index — the ported Swift
/// algorithm, one pass over the results.
///
/// A result joins the group already claimed by its normalized DOI, else its
/// normalized arXiv id, else its PMID, else its bibcode (that precedence is
/// Swift's and is observable: when a result's DOI and arXiv id point at
/// *different* existing groups, it joins the DOI's group and re-points its arXiv
/// id there — the two groups are not merged with each other).
///
/// Returns each group's member indices in first-seen order.
fn identifier_group_pass(results: &[DeduplicationInput]) -> Vec<Vec<usize>> {
    let mut groups: Vec<Vec<usize>> = vec![];
    let mut by_doi: HashMap<String, usize> = HashMap::new();
    let mut by_arxiv: HashMap<String, usize> = HashMap::new();
    let mut by_pmid: HashMap<String, usize> = HashMap::new();
    let mut by_bibcode: HashMap<String, usize> = HashMap::new();

    for (idx, result) in results.iter().enumerate() {
        let doi_key = result.doi.as_deref().map(normalize_doi);
        let arxiv_key = result.arxiv_id.as_deref().map(normalize_arxiv);

        let target = doi_key
            .as_ref()
            .and_then(|k| by_doi.get(k))
            .or_else(|| arxiv_key.as_ref().and_then(|k| by_arxiv.get(k)))
            .or_else(|| result.pmid.as_ref().and_then(|k| by_pmid.get(k)))
            .or_else(|| result.bibcode.as_ref().and_then(|k| by_bibcode.get(k)))
            .copied();

        let group_idx = match target {
            Some(existing) => {
                groups[existing].push(idx);
                existing
            }
            None => {
                groups.push(vec![idx]);
                groups.len() - 1
            }
        };

        if let Some(key) = doi_key {
            by_doi.insert(key, group_idx);
        }
        if let Some(key) = arxiv_key {
            by_arxiv.insert(key, group_idx);
        }
        if let Some(key) = result.pmid.clone() {
            by_pmid.insert(key, group_idx);
        }
        if let Some(key) = result.bibcode.clone() {
            by_bibcode.insert(key, group_idx);
        }
    }

    groups
}

/// Second pass: merge groups whose *primary-order-first* members fuzzy match.
///
/// Off unless `use_fuzzy_matching` is set. Compares only across groups (within
/// a group the identifier pass already decided), lowest group index absorbing
/// the higher, so the result order stays first-seen.
fn fuzzy_merge_pass(
    results: &[DeduplicationInput],
    groups: &mut Vec<Vec<usize>>,
    confidences: &mut Vec<f64>,
    config: &DeduplicationConfig,
) {
    let mut merged_into: Vec<Option<usize>> = vec![None; groups.len()];

    for a in 0..groups.len() {
        if merged_into[a].is_some() {
            continue;
        }
        for b in (a + 1)..groups.len() {
            if merged_into[b].is_some() {
                continue;
            }
            // A representative comparison is enough: the members of a group
            // are already asserted to be the same paper.
            let Some(score) = fuzzy_match_results_internal(
                &results[groups[a][0]],
                &results[groups[b][0]],
                config.title_threshold,
            ) else {
                continue;
            };
            merged_into[b] = Some(a);
            if score > confidences[a] {
                confidences[a] = score;
            }
        }
    }

    // Apply the merges, then drop the absorbed groups.
    for b in (0..groups.len()).rev() {
        if let Some(a) = merged_into[b] {
            let absorbed = std::mem::take(&mut groups[b]);
            groups[a].extend(absorbed);
            groups.remove(b);
            confidences.remove(b);
        }
    }
    for members in groups.iter_mut() {
        members.sort_unstable();
    }
}

/// Priority of a source under `config`: the config's explicit order when it has
/// one, otherwise the [`SOURCE_PRIORITY`] table.
fn priority_of(source_id: &str, config: &DeduplicationConfig) -> u32 {
    if config.source_priority.is_empty() {
        return source_priority_rank(source_id);
    }
    config
        .source_priority
        .iter()
        .position(|s| s == source_id)
        .map(|pos| pos as u32)
        .unwrap_or(u32::MAX)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn deduplicate_search_results(
    results: Vec<DeduplicationInput>,
    config: DeduplicationConfig,
) -> Vec<DeduplicatedGroup> {
    deduplicate_search_results_internal(results, config)
}

/// One row of the [`SOURCE_PRIORITY`] table, for callers that want to display
/// or assert it rather than re-declare it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SourcePriorityRow {
    /// Source id as `SearchResult.sourceID` spells it.
    pub source_id: String,
    /// Lower wins.
    pub priority: u32,
}

pub(crate) fn dedup_source_priorities_internal() -> Vec<SourcePriorityRow> {
    SOURCE_PRIORITY
        .iter()
        .map(|(source_id, priority)| SourcePriorityRow {
            source_id: source_id.to_string(),
            priority: *priority,
        })
        .collect()
}

/// The source-priority table, highest priority first. Sources absent from it
/// rank at [`UNRANKED_SOURCE_PRIORITY`].
#[cfg(feature = "native")]
#[uniffi::export]
pub fn dedup_source_priorities() -> Vec<SourcePriorityRow> {
    dedup_source_priorities_internal()
}

/// Priority of a single source id, including the unranked fallback.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn dedup_source_priority(source_id: String) -> u32 {
    source_priority_rank(&source_id)
}

pub(crate) fn shares_identifier_internal(a: &DeduplicationInput, b: &DeduplicationInput) -> bool {
    // Check DOI
    if let (Some(doi_a), Some(doi_b)) = (&a.doi, &b.doi) {
        if normalize_doi(doi_a) == normalize_doi(doi_b) {
            return true;
        }
    }

    // Check arXiv ID
    if let (Some(arxiv_a), Some(arxiv_b)) = (&a.arxiv_id, &b.arxiv_id) {
        if normalize_arxiv(arxiv_a) == normalize_arxiv(arxiv_b) {
            return true;
        }
    }

    // Check PMID
    if let (Some(pmid_a), Some(pmid_b)) = (&a.pmid, &b.pmid) {
        if pmid_a == pmid_b {
            return true;
        }
    }

    // Check bibcode
    if let (Some(bibcode_a), Some(bibcode_b)) = (&a.bibcode, &b.bibcode) {
        if bibcode_a == bibcode_b {
            return true;
        }
    }

    false
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn shares_identifier(a: &DeduplicationInput, b: &DeduplicationInput) -> bool {
    shares_identifier_internal(a, b)
}

pub(crate) fn fuzzy_match_results_internal(
    a: &DeduplicationInput,
    b: &DeduplicationInput,
    title_threshold: f64,
) -> Option<f64> {
    // Compare normalized titles
    let title_a = normalize_title(&a.title);
    let title_b = normalize_title(&b.title);

    let title_similarity = title_jaccard_similarity(&title_a, &title_b);
    if title_similarity < title_threshold {
        return None;
    }

    // Check year if available (must be within 1 year)
    if let (Some(year_a), Some(year_b)) = (a.year, b.year) {
        if (year_a - year_b).abs() > 1 {
            return None;
        }
    }

    // Check first author if available
    if let (Some(author_a), Some(author_b)) = (&a.first_author_last_name, &b.first_author_last_name)
    {
        if author_a.to_lowercase() != author_b.to_lowercase() {
            // Allow fuzzy author match
            if jaro_winkler(&author_a.to_lowercase(), &author_b.to_lowercase()) < 0.85 {
                return None;
            }
        }
    }

    Some(title_similarity)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn fuzzy_match_results(
    a: &DeduplicationInput,
    b: &DeduplicationInput,
    title_threshold: f64,
) -> Option<f64> {
    fuzzy_match_results_internal(a, b, title_threshold)
}

/// Normalize title for comparison
fn normalize_title(title: &str) -> String {
    title
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || c.is_whitespace())
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Calculate Jaccard similarity on words
fn title_jaccard_similarity(a: &str, b: &str) -> f64 {
    let words_a: HashSet<&str> = a.split_whitespace().collect();
    let words_b: HashSet<&str> = b.split_whitespace().collect();

    let intersection = words_a.intersection(&words_b).count();
    let union = words_a.union(&words_b).count();

    if union == 0 {
        return 0.0;
    }

    intersection as f64 / union as f64
}

/// Normalize DOI for comparison
fn normalize_doi(doi: &str) -> String {
    doi.to_lowercase()
        .replace("https://doi.org/", "")
        .replace("http://doi.org/", "")
        .replace("doi:", "")
        .trim()
        .to_string()
}

/// Normalize arXiv ID for comparison (remove version suffix)
fn normalize_arxiv(arxiv: &str) -> String {
    // Remove arxiv: prefix and version suffix
    let cleaned = arxiv
        .to_lowercase()
        .replace("arxiv:", "")
        .trim()
        .to_string();

    // Remove version suffix like "v1", "v2"
    if let Some(pos) = cleaned.rfind('v') {
        if cleaned[pos + 1..].chars().all(|c| c.is_ascii_digit()) {
            return cleaned[..pos].to_string();
        }
    }

    cleaned
}

/// Get source priority (lower = higher priority)
/// Collect identifiers from a result into a map.
///
/// Keys are `IdentifierType` raw values on the Swift side — spelling them
/// differently would make the group's identifier map unreadable to the caller
/// that builds `DeduplicatedResult.identifiers` from it.
fn collect_identifiers(result: &DeduplicationInput, identifiers: &mut HashMap<String, String>) {
    if let Some(doi) = &result.doi {
        identifiers.insert("doi".to_string(), doi.clone());
    }
    if let Some(arxiv) = &result.arxiv_id {
        identifiers.insert("arxiv".to_string(), arxiv.clone());
    }
    if let Some(pmid) = &result.pmid {
        identifiers.insert("pmid".to_string(), pmid.clone());
    }
    if let Some(bibcode) = &result.bibcode {
        identifiers.insert("bibcode".to_string(), bibcode.clone());
    }
    if let Some(id) = &result.semantic_scholar_id {
        identifiers.insert("semanticScholar".to_string(), id.clone());
    }
    if let Some(id) = &result.open_alex_id {
        identifiers.insert("openAlex".to_string(), id.clone());
    }
}

pub(crate) fn default_deduplication_config_internal() -> DeduplicationConfig {
    DeduplicationConfig::default()
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn default_deduplication_config() -> DeduplicationConfig {
    default_deduplication_config_internal()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_input(
        id: &str,
        source: &str,
        title: &str,
        doi: Option<&str>,
        arxiv: Option<&str>,
    ) -> DeduplicationInput {
        DeduplicationInput {
            id: id.to_string(),
            source_id: source.to_string(),
            title: title.to_string(),
            first_author_last_name: Some("Smith".to_string()),
            year: Some(2024),
            doi: doi.map(|s| s.to_string()),
            arxiv_id: arxiv.map(|s| s.to_string()),
            pmid: None,
            bibcode: None,
            semantic_scholar_id: None,
            open_alex_id: None,
        }
    }

    #[test]
    fn test_shares_identifier_doi() {
        let a = make_input("1", "crossref", "Test", Some("10.1234/test"), None);
        let b = make_input("2", "arxiv", "Test", Some("10.1234/test"), None);
        assert!(shares_identifier(&a, &b));
    }

    #[test]
    fn test_shares_identifier_doi_normalized() {
        let a = make_input("1", "crossref", "Test", Some("10.1234/TEST"), None);
        let b = make_input(
            "2",
            "arxiv",
            "Test",
            Some("https://doi.org/10.1234/test"),
            None,
        );
        assert!(shares_identifier(&a, &b));
    }

    #[test]
    fn test_shares_identifier_arxiv() {
        let a = make_input("1", "arxiv", "Test", None, Some("2301.12345"));
        let b = make_input("2", "s2", "Test", None, Some("2301.12345v2"));
        assert!(shares_identifier(&a, &b));
    }

    #[test]
    fn test_no_shared_identifier() {
        let a = make_input("1", "crossref", "Test A", Some("10.1234/a"), None);
        let b = make_input("2", "crossref", "Test B", Some("10.1234/b"), None);
        assert!(!shares_identifier(&a, &b));
    }

    #[test]
    fn test_fuzzy_match_same_title() {
        let a = make_input("1", "crossref", "Machine Learning for Everyone", None, None);
        let b = make_input("2", "arxiv", "Machine Learning for Everyone", None, None);

        let result = fuzzy_match_results(&a, &b, 0.85);
        assert!(result.is_some());
        assert!(result.unwrap() > 0.9);
    }

    #[test]
    fn test_fuzzy_match_similar_title() {
        let mut a = make_input("1", "crossref", "The Machine Learning Book", None, None);
        a.first_author_last_name = Some("Jones".to_string());

        let mut b = make_input("2", "arxiv", "Machine Learning Book", None, None);
        b.first_author_last_name = Some("Jones".to_string());

        let result = fuzzy_match_results(&a, &b, 0.75);
        assert!(result.is_some());
    }

    #[test]
    fn test_fuzzy_match_different_year() {
        let mut a = make_input("1", "crossref", "Machine Learning", None, None);
        a.year = Some(2024);

        let mut b = make_input("2", "arxiv", "Machine Learning", None, None);
        b.year = Some(2020);

        // Should not match due to year difference
        let result = fuzzy_match_results(&a, &b, 0.85);
        assert!(result.is_none());
    }

    #[test]
    fn test_deduplicate_by_doi() {
        let results = vec![
            make_input("1", "arxiv", "Paper Title", Some("10.1234/test"), None),
            make_input("2", "crossref", "Paper Title", Some("10.1234/test"), None),
            make_input("3", "ads", "Different Paper", Some("10.5678/other"), None),
        ];

        let config = DeduplicationConfig::default();
        let groups = deduplicate_search_results(results, config);

        assert_eq!(groups.len(), 2);

        // First group should have crossref as primary (higher priority than arxiv)
        let group1 = &groups[0];
        assert_eq!(group1.primary_index, 1); // crossref
        assert_eq!(group1.alternate_indices, vec![0]); // arxiv

        // Second group is standalone
        let group2 = &groups[1];
        assert_eq!(group2.primary_index, 2);
        assert!(group2.alternate_indices.is_empty());
    }

    #[test]
    fn test_deduplicate_collects_identifiers() {
        let mut results = vec![
            make_input("1", "arxiv", "Paper Title", None, Some("2301.12345")),
            make_input(
                "2",
                "crossref",
                "Paper Title",
                Some("10.1234/test"),
                Some("2301.12345"),
            ),
        ];
        results[0].doi = None;

        let config = DeduplicationConfig::default();
        let groups = deduplicate_search_results(results, config);

        assert_eq!(groups.len(), 1);
        let group = &groups[0];

        // Should have both doi and arxiv
        assert!(group.identifiers.contains_key("doi"));
        assert!(group.identifiers.contains_key("arxiv"));
    }

    #[test]
    fn test_normalize_arxiv() {
        assert_eq!(normalize_arxiv("2301.12345"), "2301.12345");
        assert_eq!(normalize_arxiv("2301.12345v1"), "2301.12345");
        assert_eq!(normalize_arxiv("2301.12345v2"), "2301.12345");
        assert_eq!(normalize_arxiv("arxiv:2301.12345"), "2301.12345");
    }

    // ── Stage 7 item 5: the ported Swift algorithm ───────────────────────────

    #[test]
    fn identifier_grouping_is_transitive() {
        // A shares a DOI with B; B shares an arXiv id with C. Swift's
        // identifier index put all three in one group; the old pairwise Rust
        // pass produced two, because it only ever compared against A.
        let mut a = make_input("a", "crossref", "Paper", Some("10.1/x"), None);
        a.first_author_last_name = None;
        let b = make_input("b", "ads", "Paper", Some("10.1/x"), Some("2301.00001"));
        let c = make_input("c", "arxiv", "Paper", None, Some("2301.00001"));

        let groups =
            deduplicate_search_results_internal(vec![a, b, c], DeduplicationConfig::default());
        assert_eq!(groups.len(), 1);
        assert_eq!(
            groups[0].primary_index, 0,
            "crossref outranks ads and arxiv"
        );
        assert_eq!(groups[0].alternate_indices, vec![1, 2]);
        assert_eq!(groups[0].confidence, 1.0);
    }

    #[test]
    fn a_split_identifier_result_joins_the_doi_group_only() {
        // The DOI-before-arXiv precedence is observable: `c` could join either
        // group, and it must join the DOI one without merging the two.
        let a = make_input("a", "crossref", "One", Some("10.1/x"), None);
        let b = make_input("b", "arxiv", "Two", None, Some("2301.00002"));
        let c = make_input("c", "ads", "One", Some("10.1/x"), Some("2301.00002"));

        let groups =
            deduplicate_search_results_internal(vec![a, b, c], DeduplicationConfig::default());
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].alternate_indices, vec![2]);
        assert!(groups[1].alternate_indices.is_empty());
    }

    #[test]
    fn a_single_source_result_set_is_never_grouped() {
        // Two identical rows from one source stay separate — the source already
        // deduped, so identical-looking rows are the source's own answer.
        let a = make_input("a", "arxiv", "Same Paper", Some("10.1/x"), None);
        let b = make_input("b", "arxiv", "Same Paper", Some("10.1/x"), None);
        let groups =
            deduplicate_search_results_internal(vec![a, b], DeduplicationConfig::default());
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0].confidence, 0.0);
        assert_eq!(groups[0].identifiers.get("doi").unwrap(), "10.1/x");
    }

    #[test]
    fn fuzzy_matching_is_off_unless_asked_for() {
        // No shared identifier, identical title/author/year.
        let a = make_input("a", "crossref", "Machine Learning for Everyone", None, None);
        let b = make_input("b", "arxiv", "Machine Learning for Everyone", None, None);

        let default_groups = deduplicate_search_results_internal(
            vec![a.clone(), b.clone()],
            DeduplicationConfig::default(),
        );
        assert_eq!(default_groups.len(), 2, "default must not fuzzy-merge");

        let fuzzy_groups = deduplicate_search_results_internal(
            vec![a, b],
            DeduplicationConfig {
                use_fuzzy_matching: true,
                ..DeduplicationConfig::default()
            },
        );
        assert_eq!(fuzzy_groups.len(), 1);
        assert_eq!(fuzzy_groups[0].primary_index, 0);
        assert!(fuzzy_groups[0].confidence > 0.9);
    }

    #[test]
    fn source_priority_table_matches_the_swift_literals() {
        assert_eq!(source_priority_rank("crossref"), 10);
        assert_eq!(source_priority_rank("pubmed"), 20);
        assert_eq!(source_priority_rank("ads"), 30);
        assert_eq!(source_priority_rank("semanticscholar"), 40);
        assert_eq!(source_priority_rank("openalex"), 50);
        assert_eq!(source_priority_rank("arxiv"), 60);
        assert_eq!(source_priority_rank("dblp"), 70);
        assert_eq!(source_priority_rank("europepmc"), UNRANKED_SOURCE_PRIORITY);
        assert_eq!(dedup_source_priorities_internal().len(), 7);
    }

    #[test]
    fn unknown_sources_tie_break_on_original_position() {
        let a = make_input("a", "zzz", "Paper", Some("10.1/x"), None);
        let b = make_input("b", "yyy", "Paper", Some("10.1/x"), None);
        let groups =
            deduplicate_search_results_internal(vec![a, b], DeduplicationConfig::default());
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].primary_index, 0);
    }

    #[test]
    fn an_explicit_priority_list_overrides_the_table() {
        let a = make_input("a", "crossref", "Paper", Some("10.1/x"), None);
        let b = make_input("b", "arxiv", "Paper", Some("10.1/x"), None);
        let groups = deduplicate_search_results_internal(
            vec![a, b],
            DeduplicationConfig {
                source_priority: vec!["arxiv".into(), "crossref".into()],
                ..DeduplicationConfig::default()
            },
        );
        assert_eq!(groups[0].primary_index, 1, "arxiv was listed first");
    }

    #[test]
    fn carried_identifiers_include_aggregator_ids() {
        let mut a = make_input("a", "crossref", "Paper", Some("10.1/x"), None);
        a.semantic_scholar_id = Some("s2:123".into());
        let mut b = make_input("b", "openalex", "Paper", Some("10.1/x"), None);
        b.open_alex_id = Some("W123".into());

        let groups =
            deduplicate_search_results_internal(vec![a, b], DeduplicationConfig::default());
        assert_eq!(groups.len(), 1);
        assert_eq!(
            groups[0].identifiers.get("semanticScholar").unwrap(),
            "s2:123"
        );
        assert_eq!(groups[0].identifiers.get("openAlex").unwrap(), "W123");
    }
}
