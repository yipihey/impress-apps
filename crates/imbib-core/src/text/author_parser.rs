//! Author name parsing and cite key generation utilities
//!
//! Provides functions for:
//! - Extracting author last names from BibTeX author fields
//! - Splitting author lists
//! - Normalizing author names
//! - Generating cite keys from bibliographic data

use lazy_static::lazy_static;
use std::collections::HashSet;
use unicode_normalization::UnicodeNormalization;

lazy_static! {
    /// Stop words to skip when extracting meaningful title words
    static ref STOP_WORDS: HashSet<&'static str> = {
        let mut set = HashSet::new();
        let words = [
            "a", "an", "the", "of", "in", "on", "at", "to", "for",
            "and", "or", "but", "with", "by", "from", "as", "is",
            "are", "was", "were", "be", "been", "being", "have",
            "has", "had", "do", "does", "did", "will", "would",
            "could", "should", "may", "might", "can", "this", "that",
        ];
        for word in words {
            set.insert(word);
        }
        set
    };
}

/// Extract the first author's last name from a BibTeX author field.
///
/// Handles both "Last, First" and "First Last" formats.
/// Returns "Unknown" if no author is provided.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_first_author_last_name(author_field: String) -> String {
    if author_field.is_empty() {
        return "Unknown".to_string();
    }

    // Split by " and " to get first author
    let first_author = author_field.split(" and ").next().unwrap_or(&author_field);

    // Handle "Last, First" format
    if first_author.contains(',') {
        let last_name = first_author.split(',').next().unwrap_or("");
        return clean_name(last_name);
    }

    // Handle "First Last" format - take last word
    let parts: Vec<&str> = first_author.split_whitespace().collect();
    if let Some(&last) = parts.last() {
        return clean_name(last);
    }

    clean_name(first_author)
}

/// Split a BibTeX author field into individual authors.
///
/// Handles " and " separators (BibTeX style) and ";" separators.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn split_authors(author_field: String) -> Vec<String> {
    author_field
        .split(" and ")
        .flat_map(|s| s.split(';'))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// Normalize an author name for comparison.
///
/// - Converts to lowercase
/// - Removes diacritics
/// - Removes titles (Dr., Prof., etc.)
/// - Removes suffixes (Jr., Sr., PhD, etc.)
#[cfg(feature = "native")]
#[uniffi::export]
pub fn normalize_author_name(name: String) -> String {
    let mut result: String = name
        // Unicode normalize (NFD to separate combining characters)
        .nfkd()
        // Keep only ASCII alphanumeric, space, and comma
        .filter(|c| c.is_ascii_alphanumeric() || c.is_ascii_whitespace() || *c == ',')
        .collect();

    // Convert to lowercase
    result = result.to_lowercase();

    // Remove titles
    let titles = [
        "dr ",
        "dr. ",
        "prof ",
        "prof. ",
        "professor ",
        "mr ",
        "mr. ",
        "mrs ",
        "mrs. ",
        "ms ",
        "ms. ",
        "sir ",
    ];
    for title in titles {
        result = result.replace(title, "");
    }

    // Remove suffixes
    let suffixes = [
        " jr", " jr.", " sr", " sr.", " ii", " iii", " iv", " phd", " md", " esq",
    ];
    for suffix in suffixes {
        if result.ends_with(suffix) {
            result = result[..result.len() - suffix.len()].to_string();
        }
    }

    // Collapse whitespace
    collapse_whitespace(&result).trim().to_string()
}

/// Extract surname from an author name.
///
/// Handles both "Last, First" and "First Last" formats.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_surname(author: String) -> String {
    let normalized = normalize_author_name(author);

    // Check for "Last, First" format
    if let Some(comma_pos) = normalized.find(',') {
        return normalized[..comma_pos].trim().to_string();
    }

    // "First Last" format - take last word
    normalized
        .split_whitespace()
        .last()
        .unwrap_or(&normalized)
        .to_string()
}

/// Extract the first meaningful word from a title for cite key generation.
///
/// Skips common stop words and returns a capitalized word of at least 3 characters.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_first_meaningful_word(title: String) -> String {
    if title.is_empty() {
        return String::new();
    }

    // Remove braces
    let cleaned = title.replace(['{', '}'], "");

    // Split into words and find first non-stop word
    for word in cleaned.split_whitespace() {
        // Remove punctuation from word
        let word: String = word.chars().filter(|c| c.is_alphanumeric()).collect();

        if word.len() >= 3 && !STOP_WORDS.contains(word.to_lowercase().as_str()) {
            // Normalize diacritics
            let normalized: String = word.nfkd().filter(|c| c.is_ascii_alphanumeric()).collect();

            // Capitalize first letter
            if let Some(first) = normalized.chars().next() {
                let rest: String = normalized.chars().skip(1).collect();
                return first.to_uppercase().to_string() + &rest.to_lowercase();
            }
        }
    }

    String::new()
}

// Note: sanitize_cite_key is defined in identifiers/cite_key.rs
// Use crate::identifiers::sanitize_cite_key if needed here

/// Clean a name by removing braces, normalizing diacritics, and capitalizing.
fn clean_name(name: &str) -> String {
    // Remove braces and trim
    let cleaned = name.trim().replace(['{', '}'], "");

    // Normalize diacritics
    let normalized: String = cleaned
        .nfkd()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect();

    // Capitalize first letter
    if let Some(first) = normalized.chars().next() {
        let rest: String = normalized.chars().skip(1).collect();
        first.to_uppercase().to_string() + &rest.to_lowercase()
    } else {
        normalized
    }
}

/// Collapse multiple whitespace characters into a single space.
fn collapse_whitespace(s: &str) -> String {
    let mut result = String::with_capacity(s.len());
    let mut prev_was_space = false;

    for c in s.chars() {
        if c.is_ascii_whitespace() {
            if !prev_was_space {
                result.push(' ');
                prev_was_space = true;
            }
        } else {
            result.push(c);
            prev_was_space = false;
        }
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_first_author_last_name() {
        assert_eq!(
            extract_first_author_last_name("Smith, John".to_string()),
            "Smith"
        );
        assert_eq!(
            extract_first_author_last_name("John Smith".to_string()),
            "Smith"
        );
        assert_eq!(
            extract_first_author_last_name("Smith, John and Doe, Jane".to_string()),
            "Smith"
        );
        assert_eq!(extract_first_author_last_name("".to_string()), "Unknown");
    }

    #[test]
    fn test_extract_first_author_with_diacritics() {
        assert_eq!(
            extract_first_author_last_name("Müller, Hans".to_string()),
            "Muller"
        );
        assert_eq!(
            extract_first_author_last_name("José García".to_string()),
            "Garcia"
        );
    }

    #[test]
    fn test_split_authors() {
        assert_eq!(
            split_authors("Smith, John and Doe, Jane".to_string()),
            vec!["Smith, John", "Doe, Jane"]
        );
        assert_eq!(
            split_authors("Smith, J.; Doe, J.".to_string()),
            vec!["Smith, J.", "Doe, J."]
        );
    }

    #[test]
    fn test_normalize_author_name() {
        assert_eq!(
            normalize_author_name("Dr. John Smith Jr.".to_string()),
            "john smith"
        );
        assert_eq!(
            normalize_author_name("François Müller".to_string()),
            "francois muller"
        );
    }

    #[test]
    fn test_extract_surname() {
        assert_eq!(extract_surname("John Smith".to_string()), "smith");
        assert_eq!(extract_surname("Smith, John".to_string()), "smith");
    }

    #[test]
    fn test_extract_first_meaningful_word() {
        assert_eq!(
            extract_first_meaningful_word("The Machine Learning Approach".to_string()),
            "Machine"
        );
        assert_eq!(
            extract_first_meaningful_word("A Study in Scarlet".to_string()),
            "Study"
        );
        assert_eq!(
            extract_first_meaningful_word("On the Origin of Species".to_string()),
            "Origin"
        );
    }

    // Note: sanitize_cite_key tests are in identifiers/cite_key.rs
}
