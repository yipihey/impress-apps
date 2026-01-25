//! Similarity scoring for deduplication

use strsim::{jaro_winkler, normalized_levenshtein};

use super::normalization::{extract_surname, normalize_title_internal, split_authors};
use crate::bibtex::BibTeXEntry;
use crate::domain::{Author, Publication};

/// Result of a deduplication comparison
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct DeduplicationMatch {
    /// Overall similarity score (0.0 to 1.0)
    pub score: f64,
    /// Human-readable explanation of why entries match
    pub reason: String,
}

pub(crate) fn calculate_similarity_internal(
    entry1: &BibTeXEntry,
    entry2: &BibTeXEntry,
) -> DeduplicationMatch {
    let mut score: f64 = 0.0;
    let mut reasons = Vec::new();

    // Check DOI match (strongest signal)
    if let (Some(doi1), Some(doi2)) = (entry1.doi(), entry2.doi()) {
        if normalize_doi(doi1) == normalize_doi(doi2) {
            return DeduplicationMatch {
                score: 1.0,
                reason: "DOI match".to_string(),
            };
        }
    }

    // Title similarity (weighted heavily)
    if let (Some(title1), Some(title2)) = (entry1.title(), entry2.title()) {
        let title_score = title_similarity(title1, title2);
        if title_score > 0.9 {
            score += 0.5;
            reasons.push(format!("Title match ({:.0}%)", title_score * 100.0));
        } else if title_score > 0.7 {
            score += 0.3;
            reasons.push(format!("Similar title ({:.0}%)", title_score * 100.0));
        }
    }

    // Author overlap
    if let (Some(authors1), Some(authors2)) = (entry1.author(), entry2.author()) {
        if author_overlap(authors1, authors2) {
            score += 0.3;
            reasons.push("Author overlap".to_string());
        }
    }

    // Year match
    if let (Some(year1), Some(year2)) = (entry1.year(), entry2.year()) {
        if year1 == year2 {
            score += 0.1;
            reasons.push("Same year".to_string());
        } else {
            // Check if years are within 1 (could be publication vs preprint)
            if let (Ok(y1), Ok(y2)) = (year1.parse::<i32>(), year2.parse::<i32>()) {
                if (y1 - y2).abs() <= 1 {
                    score += 0.05;
                    reasons.push("Years within 1".to_string());
                }
            }
        }
    }

    // Journal match (for articles)
    if let (Some(journal1), Some(journal2)) = (entry1.journal(), entry2.journal()) {
        let journal_score = journal_similarity(journal1, journal2);
        if journal_score > 0.8 {
            score += 0.1;
            reasons.push("Same journal".to_string());
        }
    }

    // Cap at 1.0
    score = score.min(1.0);

    let reason = if reasons.is_empty() {
        "No significant similarity".to_string()
    } else {
        reasons.join("; ")
    };

    DeduplicationMatch { score, reason }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn calculate_similarity(entry1: BibTeXEntry, entry2: BibTeXEntry) -> DeduplicationMatch {
    calculate_similarity_internal(&entry1, &entry2)
}

pub(crate) fn titles_match_internal(title1: &str, title2: &str, threshold: f64) -> bool {
    let score = title_similarity(title1, title2);
    score >= threshold
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn titles_match(title1: String, title2: String, threshold: f64) -> bool {
    titles_match_internal(&title1, &title2, threshold)
}

pub(crate) fn authors_overlap_internal(authors1: &str, authors2: &str) -> bool {
    author_overlap(authors1, authors2)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn authors_overlap(authors1: String, authors2: String) -> bool {
    authors_overlap_internal(&authors1, &authors2)
}

/// Calculate title similarity using multiple metrics
fn title_similarity(title1: &str, title2: &str) -> f64 {
    let norm1 = normalize_title_internal(title1);
    let norm2 = normalize_title_internal(title2);

    if norm1.is_empty() || norm2.is_empty() {
        return 0.0;
    }

    // Use Jaro-Winkler for overall similarity
    let jw = jaro_winkler(&norm1, &norm2);

    // Use Levenshtein for exact character matching
    let lev = normalized_levenshtein(&norm1, &norm2);

    // Combine metrics (weighted average)
    jw * 0.6 + lev * 0.4
}

/// Check if author lists have meaningful overlap
fn author_overlap(authors1: &str, authors2: &str) -> bool {
    let list1 = split_authors(authors1);
    let list2 = split_authors(authors2);

    if list1.is_empty() || list2.is_empty() {
        return false;
    }

    // Extract surnames for comparison
    let surnames1: Vec<String> = list1.iter().map(|a| extract_surname(a)).collect();
    let surnames2: Vec<String> = list2.iter().map(|a| extract_surname(a)).collect();

    // Check for any matching surnames
    for s1 in &surnames1 {
        for s2 in &surnames2 {
            if s1 == s2 {
                return true;
            }
            // Fuzzy match for similar names
            if jaro_winkler(s1, s2) > 0.9 {
                return true;
            }
        }
    }

    false
}

/// Calculate journal name similarity
fn journal_similarity(journal1: &str, journal2: &str) -> f64 {
    let norm1 = normalize_journal(journal1);
    let norm2 = normalize_journal(journal2);

    if norm1.is_empty() || norm2.is_empty() {
        return 0.0;
    }

    jaro_winkler(&norm1, &norm2)
}

/// Normalize journal name for comparison
fn normalize_journal(journal: &str) -> String {
    let mut result = journal.to_lowercase();

    // Remove common abbreviation markers
    result = result.replace('.', "");
    result = result.replace(',', "");

    // Expand common abbreviations
    let expansions = [
        ("j ", "journal "),
        ("proc ", "proceedings "),
        ("trans ", "transactions "),
        ("int ", "international "),
        ("natl ", "national "),
        ("phys ", "physics "),
        ("chem ", "chemistry "),
        ("biol ", "biology "),
        ("med ", "medicine "),
        ("sci ", "science "),
        ("rev ", "review "),
        ("lett ", "letters "),
    ];

    for (abbrev, full) in expansions {
        result = result.replace(abbrev, full);
    }

    // Collapse whitespace
    result.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// Normalize DOI for comparison
fn normalize_doi(doi: &str) -> String {
    doi.to_lowercase()
        .replace("https://doi.org/", "")
        .replace("http://doi.org/", "")
        .replace("doi:", "")
}

/// Normalize arXiv ID for comparison
fn normalize_arxiv_id(id: &str) -> String {
    id.to_lowercase().replace("arxiv:", "").trim().to_string()
}

// ===== Publication-aware deduplication =====

/// A group of duplicate publications
#[derive(uniffi::Record, Clone, Debug)]
pub struct DuplicateGroup {
    pub publication_ids: Vec<String>,
    pub confidence: f64,
}

pub(crate) fn calculate_publication_similarity_internal(
    a: &Publication,
    b: &Publication,
) -> DeduplicationMatch {
    // First check identifiers (highest confidence)
    if let (Some(doi_a), Some(doi_b)) = (&a.identifiers.doi, &b.identifiers.doi) {
        if normalize_doi(doi_a) == normalize_doi(doi_b) {
            return DeduplicationMatch {
                score: 1.0,
                reason: "Matching DOI".to_string(),
            };
        }
    }

    if let (Some(arxiv_a), Some(arxiv_b)) = (&a.identifiers.arxiv_id, &b.identifiers.arxiv_id) {
        if normalize_arxiv_id(arxiv_a) == normalize_arxiv_id(arxiv_b) {
            return DeduplicationMatch {
                score: 1.0,
                reason: "Matching arXiv ID".to_string(),
            };
        }
    }

    if let (Some(bibcode_a), Some(bibcode_b)) = (&a.identifiers.bibcode, &b.identifiers.bibcode) {
        if bibcode_a == bibcode_b {
            return DeduplicationMatch {
                score: 1.0,
                reason: "Matching bibcode".to_string(),
            };
        }
    }

    // Fall back to title + author similarity
    let title_sim = pub_title_similarity(&a.title, &b.title);
    let author_sim = pub_author_similarity(&a.authors, &b.authors);
    let year_bonus = match (a.year, b.year) {
        (Some(y1), Some(y2)) => {
            if y1 == y2 {
                0.2
            } else if (y1 - y2).abs() <= 1 {
                0.1
            } else {
                0.0
            }
        }
        _ => 0.0,
    };

    let score = (title_sim * 0.5) + (author_sim * 0.3) + year_bonus;

    DeduplicationMatch {
        score,
        reason: format!(
            "Title: {:.0}%, Authors: {:.0}%",
            title_sim * 100.0,
            author_sim * 100.0
        ),
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn calculate_publication_similarity(a: &Publication, b: &Publication) -> DeduplicationMatch {
    calculate_publication_similarity_internal(a, b)
}

pub(crate) fn find_duplicates_internal(
    publications: Vec<Publication>,
    threshold: f64,
) -> Vec<DuplicateGroup> {
    let mut groups: Vec<DuplicateGroup> = Vec::new();
    let mut processed: std::collections::HashSet<usize> = std::collections::HashSet::new();

    for i in 0..publications.len() {
        if processed.contains(&i) {
            continue;
        }

        let mut group_ids = vec![publications[i].id.clone()];
        let mut max_score = threshold;

        for j in (i + 1)..publications.len() {
            if processed.contains(&j) {
                continue;
            }

            let match_result = calculate_publication_similarity(&publications[i], &publications[j]);
            if match_result.score >= threshold {
                group_ids.push(publications[j].id.clone());
                processed.insert(j);
                if match_result.score > max_score {
                    max_score = match_result.score;
                }
            }
        }

        if group_ids.len() > 1 {
            groups.push(DuplicateGroup {
                publication_ids: group_ids,
                confidence: max_score,
            });
        }

        processed.insert(i);
    }

    groups
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn find_duplicates(publications: Vec<Publication>, threshold: f64) -> Vec<DuplicateGroup> {
    find_duplicates_internal(publications, threshold)
}

/// Calculate title similarity for Publications
fn pub_title_similarity(a: &str, b: &str) -> f64 {
    title_similarity(a, b)
}

/// Calculate author similarity for Publications
fn pub_author_similarity(a: &[Author], b: &[Author]) -> f64 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }

    let names_a: Vec<String> = a
        .iter()
        .map(|auth| auth.family_name.to_lowercase())
        .collect();
    let names_b: Vec<String> = b
        .iter()
        .map(|auth| auth.family_name.to_lowercase())
        .collect();

    let matches = names_a.iter().filter(|n| names_b.contains(n)).count();
    let total = names_a.len().max(names_b.len());

    matches as f64 / total as f64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bibtex::BibTeXEntryType;

    #[test]
    fn test_doi_match() {
        let mut entry1 = BibTeXEntry::new("Test1".to_string(), BibTeXEntryType::Article);
        entry1.add_field("doi", "10.1038/nature12373");
        entry1.add_field("title", "Paper A");

        let mut entry2 = BibTeXEntry::new("Test2".to_string(), BibTeXEntryType::Article);
        entry2.add_field("doi", "10.1038/nature12373");
        entry2.add_field("title", "Different Title");

        let result = calculate_similarity(entry1, entry2);
        assert_eq!(result.score, 1.0);
        assert!(result.reason.contains("DOI"));
    }

    #[test]
    fn test_title_similarity() {
        assert!(title_similarity("Machine Learning", "Machine Learning") > 0.99);
        assert!(title_similarity("Machine Learning", "machine learning") > 0.99);
        assert!(title_similarity("The Machine Learning Book", "Machine Learning Book") > 0.9);
        assert!(title_similarity("Completely Different", "Machine Learning") < 0.5);
    }

    #[test]
    fn test_author_overlap() {
        assert!(author_overlap("John Smith", "Smith, John"));
        assert!(author_overlap("Smith, J. and Doe, J.", "John Smith"));
        assert!(!author_overlap("John Smith", "Jane Doe"));
    }

    #[test]
    fn test_similar_entries() {
        let mut entry1 = BibTeXEntry::new("Test1".to_string(), BibTeXEntryType::Article);
        entry1.add_field("title", "Deep Learning for Natural Language Processing");
        entry1.add_field("author", "John Smith and Jane Doe");
        entry1.add_field("year", "2024");

        let mut entry2 = BibTeXEntry::new("Test2".to_string(), BibTeXEntryType::Article);
        entry2.add_field("title", "Deep Learning for Natural Language Processing");
        entry2.add_field("author", "J. Smith and J. Doe");
        entry2.add_field("year", "2024");

        let result = calculate_similarity(entry1, entry2);
        assert!(result.score > 0.8);
    }

    #[test]
    fn test_journal_similarity() {
        assert!(journal_similarity("Nature", "Nature") > 0.99);
        assert!(journal_similarity("J. Phys.", "Journal of Physics") > 0.8);
        assert!(journal_similarity("Phys. Rev. Lett.", "Physical Review Letters") > 0.7);
    }
}
