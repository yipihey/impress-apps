//! Heuristic extraction of metadata (title, authors, year) from PDF text.
//!
//! Used as a fallback when no identifiers (DOI, arXiv, bibcode) are available.
//! Applies pattern matching and heuristics to extract structured metadata.

use lazy_static::lazy_static;
use regex::Regex;
use std::collections::HashSet;

/// Confidence level for heuristic extraction.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum HeuristicConfidence {
    /// No metadata could be extracted
    None,
    /// Low confidence (single field extracted)
    Low,
    /// Medium confidence (multiple fields, some validation)
    Medium,
    /// High confidence (all major fields extracted with validation)
    High,
}

/// Metadata extracted heuristically from PDF text.
#[derive(Debug, Clone, uniffi::Record)]
pub struct HeuristicExtractedFields {
    /// Title extracted from PDF (first major text block)
    pub title: Option<String>,
    /// Authors extracted from PDF
    pub authors: Vec<String>,
    /// Year extracted from PDF (4-digit pattern)
    pub year: Option<i32>,
    /// Journal name if detected
    pub journal: Option<String>,
    /// Confidence level of extraction
    pub confidence: HeuristicConfidence,
}

impl Default for HeuristicExtractedFields {
    fn default() -> Self {
        Self {
            title: None,
            authors: Vec::new(),
            year: None,
            journal: None,
            confidence: HeuristicConfidence::None,
        }
    }
}

lazy_static! {
    /// Pattern for 4-digit years (19xx, 20xx)
    static ref YEAR_REGEX: Regex = Regex::new(r"\b(19\d{2}|20\d{2})\b").unwrap();

    /// Patterns for extracting journal names
    static ref JOURNAL_PATTERNS: Vec<Regex> = vec![
        Regex::new(r"(?i)published in (.+?)(?:\.|,|$)").unwrap(),
        Regex::new(r"(?i)journal of (.+?)(?:\.|,|$)").unwrap(),
        Regex::new(r"(?i)proceedings of (.+?)(?:\.|,|$)").unwrap(),
        Regex::new(r"(?i)accepted (?:for publication )?(?:in|by) (.+?)(?:\.|,|$)").unwrap(),
    ];

    /// Stop words and patterns to skip when extracting titles
    static ref SKIP_PATTERNS: HashSet<&'static str> = {
        let mut set = HashSet::new();
        for word in &[
            "preprint", "submitted", "accepted", "published", "received",
            "journal", "volume", "issue", "pages", "vol.", "no.",
            "doi:", "arxiv:", "http", "www", "©", "copyright",
            "all rights reserved", "abstract", "introduction",
            "keywords:", "pacs:", "msc:"
        ] {
            set.insert(*word);
        }
        set
    };

    /// Non-name patterns to exclude from author detection
    static ref NON_NAME_PATTERNS: HashSet<&'static str> = {
        let mut set = HashSet::new();
        for word in &[
            "university", "institute", "department", "laboratory",
            "et al", "submitted", "accepted", "@"
        ] {
            set.insert(*word);
        }
        set
    };
}

/// Extract metadata from PDF first page text.
///
/// This is the internal implementation that can be called directly.
pub fn extract_metadata_heuristics_internal(
    first_page_text: &str,
    current_year: i32,
) -> HeuristicExtractedFields {
    let lines: Vec<&str> = first_page_text
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.is_empty())
        .collect();

    let title = extract_title(&lines);
    let authors = extract_authors(&lines);
    let year = extract_year(first_page_text, current_year);
    let journal = extract_journal(first_page_text);

    let confidence = calculate_confidence(title.as_deref(), &authors, year);

    HeuristicExtractedFields {
        title,
        authors,
        year,
        journal,
        confidence,
    }
}

/// Extract metadata from PDF first page text (UniFFI export).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_metadata_heuristics(
    first_page_text: String,
    current_year: i32,
) -> HeuristicExtractedFields {
    extract_metadata_heuristics_internal(&first_page_text, current_year)
}

/// Batch extract metadata from multiple PDF pages.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_metadata_heuristics_batch(
    first_page_texts: Vec<String>,
    current_year: i32,
) -> Vec<HeuristicExtractedFields> {
    first_page_texts
        .iter()
        .map(|text| extract_metadata_heuristics_internal(text, current_year))
        .collect()
}

// MARK: - Title Extraction

/// Extract title from PDF text lines.
fn extract_title(lines: &[&str]) -> Option<String> {
    let mut candidate_lines: Vec<&str> = Vec::new();
    let mut found_author_like_line = false;

    for line in lines.iter().take(25) {
        let lowercased = line.to_lowercase();

        // Skip if matches header patterns
        if SKIP_PATTERNS.iter().any(|p| lowercased.contains(p)) {
            continue;
        }

        // Skip very short lines
        if line.len() < 10 {
            continue;
        }

        // Skip lines that look like affiliations
        if lowercased.contains('@')
            || lowercased.contains("university")
            || lowercased.contains("institute")
            || lowercased.contains("department")
            || lowercased.contains("laboratory")
        {
            continue;
        }

        // Check if line looks like authors
        if looks_like_author_line(line) {
            found_author_like_line = true;
            continue;
        }

        // Stop if we've passed author-like content
        if found_author_like_line {
            break;
        }

        candidate_lines.push(line);

        if candidate_lines.len() >= 3 {
            break;
        }
    }

    if candidate_lines.is_empty() {
        return None;
    }

    if candidate_lines.len() >= 2 {
        let combined = candidate_lines.join(" ");
        if combined.len() <= 300 {
            return Some(clean_title(&combined));
        }
    }

    Some(clean_title(candidate_lines[0]))
}

/// Check if a line looks like it contains author names.
fn looks_like_author_line(line: &str) -> bool {
    // Contains " and " between words (case-insensitive check)
    let lowercased = line.to_lowercase();
    if lowercased.contains(" and ") {
        // Split original line (not lowercased) to preserve case for capitalization check
        let parts: Vec<&str> = line.split([' ']).collect();
        let and_indices: Vec<_> = parts
            .iter()
            .enumerate()
            .filter(|(_, p)| p.to_lowercase() == "and")
            .map(|(i, _)| i)
            .collect();

        if !and_indices.is_empty() {
            // Check if there are capitalized words on both sides of "and"
            for &idx in &and_indices {
                let before: String = parts[..idx].join(" ");
                let after: String = parts[idx + 1..].join(" ");
                if has_capitalized_words(&before) && has_capitalized_words(&after) {
                    return true;
                }
            }
        }
    }

    // Multiple comma-separated names
    let comma_parts: Vec<&str> = line.split(',').collect();
    if comma_parts.len() >= 2 {
        let name_like_parts: Vec<_> = comma_parts
            .iter()
            .filter(|part| {
                let trimmed = part.trim();
                trimmed.len() > 2 && has_capitalized_word(trimmed)
            })
            .collect();
        if name_like_parts.len() >= 2 {
            return true;
        }
    }

    // Superscript/footnote markers common in author lists
    if (line.contains('*') || line.contains('†') || line.contains('‡'))
        && has_capitalized_words(line)
    {
        return true;
    }

    false
}

/// Check if string has at least one capitalized word.
fn has_capitalized_word(text: &str) -> bool {
    text.split_whitespace().any(|word| {
        if let Some(first) = word.chars().next() {
            first.is_uppercase() && word.len() > 1
        } else {
            false
        }
    })
}

/// Check if string has at least two capitalized words (name-like pattern).
fn has_capitalized_words(text: &str) -> bool {
    let words: Vec<&str> = text.split_whitespace().collect();
    let capitalized_count = words
        .iter()
        .filter(|word| {
            if let Some(first) = word.chars().next() {
                first.is_uppercase() && word.len() > 1
            } else {
                false
            }
        })
        .count();
    capitalized_count >= 2
}

/// Clean up extracted title.
fn clean_title(title: &str) -> String {
    let mut result = title
        .replace('\n', " ")
        .replace("  ", " ")
        .trim()
        .to_string();

    // Remove trailing punctuation
    while result.ends_with('.') || result.ends_with(',') || result.ends_with(';') {
        result.pop();
    }

    result
}

// MARK: - Author Extraction

/// Extract author names from PDF text lines.
fn extract_authors(lines: &[&str]) -> Vec<String> {
    let mut authors: Vec<String> = Vec::new();

    for line in lines.iter().take(30) {
        if looks_like_author_line(line) {
            let extracted = extract_names_from_line(line);
            authors.extend(extracted);
        }
    }

    // Deduplicate while preserving order
    let mut seen: HashSet<String> = HashSet::new();
    authors
        .into_iter()
        .filter(|name| {
            let normalized = name.to_lowercase();
            if seen.contains(&normalized) {
                false
            } else {
                seen.insert(normalized);
                true
            }
        })
        .collect()
}

/// Extract individual names from an author line.
fn extract_names_from_line(line: &str) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();

    // Clean the line of affiliation markers
    let cleaned: String = line
        .chars()
        .filter(|c| {
            !matches!(
                c,
                '*' | '†'
                    | '‡'
                    | '§'
                    | '¹'
                    | '²'
                    | '³'
                    | '⁴'
                    | '⁵'
                    | '⁶'
                    | '⁷'
                    | '⁸'
                    | '⁹'
                    | '⁰'
            )
        })
        .collect();

    // Split by " and " first
    let and_parts: Vec<&str> = cleaned.split(" and ").collect();

    for part in and_parts {
        // Then split by commas
        let comma_parts: Vec<&str> = part.split(',').collect();

        for comma_part in comma_parts {
            let trimmed = comma_part.trim();

            if is_valid_name(trimmed) {
                names.push(format_author_name(trimmed));
            }
        }
    }

    names
}

/// Check if a string looks like a valid author name.
fn is_valid_name(name: &str) -> bool {
    let trimmed = name.trim();

    // Should have reasonable length
    if trimmed.len() < 3 || trimmed.len() > 100 {
        return false;
    }

    // Should have at least 2 words
    let words: Vec<&str> = trimmed
        .split_whitespace()
        .filter(|w| !w.is_empty())
        .collect();
    if words.len() < 2 {
        return false;
    }

    // First word should be capitalized
    if let Some(first_word) = words.first() {
        if let Some(first_char) = first_word.chars().next() {
            if !first_char.is_uppercase() {
                return false;
            }
        }
    }

    // Shouldn't contain obvious non-name patterns
    let lowercased = trimmed.to_lowercase();
    if NON_NAME_PATTERNS.iter().any(|p| lowercased.contains(p)) {
        return false;
    }

    true
}

/// Format author name to "LastName, FirstName" format.
fn format_author_name(name: &str) -> String {
    let parts: Vec<&str> = name.split_whitespace().filter(|w| !w.is_empty()).collect();

    if parts.len() < 2 {
        return name.to_string();
    }

    // If already in "LastName, FirstName" format, return as-is
    if name.contains(',') {
        return name.trim().to_string();
    }

    // Convert "FirstName LastName" to "LastName, FirstName"
    let last_name = parts.last().unwrap();
    let first_names = parts[..parts.len() - 1].join(" ");

    format!("{}, {}", last_name, first_names)
}

// MARK: - Year Extraction

/// Extract publication year from text.
fn extract_year(text: &str, current_year: i32) -> Option<i32> {
    let min_year = 1900;
    let max_year = current_year + 1;

    let mut candidates: Vec<i32> = Vec::new();

    for cap in YEAR_REGEX.captures_iter(text) {
        if let Some(m) = cap.get(1) {
            if let Ok(year) = m.as_str().parse::<i32>() {
                if year >= min_year && year <= max_year {
                    candidates.push(year);
                }
            }
        }
    }

    // Return the most recent reasonable year
    candidates.into_iter().max()
}

// MARK: - Journal Extraction

/// Extract journal name from text (if present).
fn extract_journal(text: &str) -> Option<String> {
    for pattern in JOURNAL_PATTERNS.iter() {
        if let Some(caps) = pattern.captures(text) {
            if let Some(m) = caps.get(1) {
                let journal = m.as_str().trim();
                if journal.len() >= 5 && journal.len() <= 200 {
                    return Some(journal.to_string());
                }
            }
        }
    }
    None
}

// MARK: - Confidence Calculation

/// Calculate confidence based on what was extracted.
fn calculate_confidence(
    title: Option<&str>,
    authors: &[String],
    year: Option<i32>,
) -> HeuristicConfidence {
    let mut score = 0;

    // Title contributes most
    if let Some(t) = title {
        if t.len() >= 20 {
            score += 2;
        } else {
            score += 1;
        }
    }

    // Authors
    if authors.len() >= 2 {
        score += 2;
    } else if !authors.is_empty() {
        score += 1;
    }

    // Year
    if year.is_some() {
        score += 1;
    }

    match score {
        0 => HeuristicConfidence::None,
        1..=2 => HeuristicConfidence::Low,
        3..=4 => HeuristicConfidence::Medium,
        _ => HeuristicConfidence::High,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_title_simple() {
        let lines = vec![
            "Machine Learning for Natural Language Processing",
            "John Smith and Jane Doe",
            "University of Example",
        ];
        let title = extract_title(&lines);
        assert!(title.is_some());
        assert!(title.unwrap().contains("Machine Learning"));
    }

    #[test]
    fn test_looks_like_author_line() {
        assert!(looks_like_author_line("John Smith and Jane Doe"));
        // Comma-separated list with initials - this passes via comma check
        assert!(looks_like_author_line(
            "Smith, John, Doe, Jane, Brown, Kate"
        ));
        assert!(looks_like_author_line("John Smith*, Jane Doe†"));
        assert!(!looks_like_author_line(
            "This is a title about machine learning"
        ));
    }

    #[test]
    fn test_extract_year() {
        let text = "Published in 2024. Copyright 2023.";
        let year = extract_year(text, 2026);
        assert_eq!(year, Some(2024));
    }

    #[test]
    fn test_extract_year_out_of_range() {
        let text = "Reference to 1850 and 3000 not valid.";
        let year = extract_year(text, 2026);
        assert!(year.is_none());
    }

    #[test]
    fn test_format_author_name() {
        assert_eq!(format_author_name("John Smith"), "Smith, John");
        assert_eq!(format_author_name("John A. Smith"), "Smith, John A.");
        assert_eq!(format_author_name("Smith, John"), "Smith, John");
    }

    #[test]
    fn test_full_extraction() {
        let text = r#"
Machine Learning for Natural Language Processing:
A Comprehensive Survey

John Smith and Jane Doe

Department of Computer Science, University of Example

Published in Nature Machine Intelligence, 2024

Abstract
This paper presents...
"#;

        let result = extract_metadata_heuristics_internal(text, 2026);

        assert!(result.title.is_some());
        assert!(!result.authors.is_empty());
        assert_eq!(result.year, Some(2024));
        assert!(
            result.confidence == HeuristicConfidence::High
                || result.confidence == HeuristicConfidence::Medium
        );
    }

    #[test]
    fn test_batch_extraction() {
        let texts = vec![
            "Paper Title 1\nAuthor A and Author B\n2024".to_string(),
            "Paper Title 2\nAuthor C, Author D\n2023".to_string(),
        ];

        let results = extract_metadata_heuristics_batch(texts, 2026);
        assert_eq!(results.len(), 2);
    }
}
