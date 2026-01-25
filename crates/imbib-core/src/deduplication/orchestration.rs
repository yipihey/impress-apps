//! Search result deduplication orchestration
//!
//! Groups search results from multiple sources by shared identifiers
//! or fuzzy matching, then selects primary results based on source priority.

use std::collections::{HashMap, HashSet};
use strsim::jaro_winkler;

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
    /// Whether to use fuzzy matching when no identifier match
    pub use_fuzzy_matching: bool,
    /// Source priority order (lower index = higher priority)
    pub source_priority: Vec<String>,
}

impl Default for DeduplicationConfig {
    fn default() -> Self {
        Self {
            title_threshold: 0.85,
            use_fuzzy_matching: true,
            source_priority: vec![
                "crossref".to_string(),
                "pubmed".to_string(),
                "ads".to_string(),
                "semanticscholar".to_string(),
                "openalex".to_string(),
                "arxiv".to_string(),
                "dblp".to_string(),
            ],
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
}

pub(crate) fn deduplicate_search_results_internal(
    results: Vec<DeduplicationInput>,
    config: DeduplicationConfig,
) -> Vec<DeduplicatedGroup> {
    if results.is_empty() {
        return vec![];
    }

    let mut groups: Vec<DeduplicatedGroup> = vec![];
    let mut processed: HashSet<usize> = HashSet::new();

    for i in 0..results.len() {
        if processed.contains(&i) {
            continue;
        }

        let mut group_indices: Vec<usize> = vec![i];
        let mut identifiers: HashMap<String, String> = HashMap::new();
        let mut max_confidence: f64 = 0.0;

        // Collect identifiers from first result
        collect_identifiers(&results[i], &mut identifiers);

        // Find all results that match
        for j in (i + 1)..results.len() {
            if processed.contains(&j) {
                continue;
            }

            let (is_match, confidence) = results_match(&results[i], &results[j], &config);
            if is_match {
                group_indices.push(j);
                processed.insert(j);
                collect_identifiers(&results[j], &mut identifiers);
                if confidence > max_confidence {
                    max_confidence = confidence;
                }
            }
        }

        // Sort group by source priority to find primary
        group_indices.sort_by(|&a, &b| {
            let priority_a = source_priority(&results[a].source_id, &config.source_priority);
            let priority_b = source_priority(&results[b].source_id, &config.source_priority);
            priority_a.cmp(&priority_b)
        });

        let primary_index = group_indices[0];
        let alternate_indices: Vec<u32> = group_indices
            .iter()
            .skip(1)
            .map(|&idx| idx as u32)
            .collect();

        // Set confidence to 1.0 if we have identifier matches, otherwise use max fuzzy score
        if max_confidence == 0.0 && !alternate_indices.is_empty() {
            max_confidence = 1.0; // Must have matched on identifier
        }

        groups.push(DeduplicatedGroup {
            primary_index: primary_index as u32,
            alternate_indices,
            identifiers,
            confidence: max_confidence,
        });

        processed.insert(i);
    }

    groups
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn deduplicate_search_results(
    results: Vec<DeduplicationInput>,
    config: DeduplicationConfig,
) -> Vec<DeduplicatedGroup> {
    deduplicate_search_results_internal(results, config)
}

/// Check if two results represent the same paper
fn results_match(
    a: &DeduplicationInput,
    b: &DeduplicationInput,
    config: &DeduplicationConfig,
) -> (bool, f64) {
    // Check identifier matches (highest confidence)
    if shares_identifier(a, b) {
        return (true, 1.0);
    }

    // Try fuzzy matching if enabled
    if config.use_fuzzy_matching {
        if let Some(score) = fuzzy_match_results(a, b, config.title_threshold) {
            return (true, score);
        }
    }

    (false, 0.0)
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
fn source_priority(source_id: &str, priority_list: &[String]) -> usize {
    priority_list
        .iter()
        .position(|s| s == source_id)
        .unwrap_or(usize::MAX)
}

/// Collect identifiers from a result into a map
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
}
