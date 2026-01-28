//! Author representation

use lazy_static::lazy_static;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use unicode_normalization::UnicodeNormalization;

/// Represents an author of a publication
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct Author {
    pub id: String,
    pub given_name: Option<String>,
    pub family_name: String,
    pub suffix: Option<String>,
    pub orcid: Option<String>,
    pub affiliation: Option<String>,
}

impl Author {
    /// Create a new author with just a family name
    pub fn new(family_name: String) -> Self {
        Self {
            id: uuid::Uuid::new_v4().to_string(),
            given_name: None,
            family_name,
            suffix: None,
            orcid: None,
            affiliation: None,
        }
    }

    /// Builder method to add given name
    pub fn with_given_name(mut self, given: impl Into<String>) -> Self {
        self.given_name = Some(given.into());
        self
    }

    /// Builder method to add suffix
    pub fn with_suffix(mut self, suffix: impl Into<String>) -> Self {
        self.suffix = Some(suffix.into());
        self
    }

    /// Builder method to add ORCID
    pub fn with_orcid(mut self, orcid: impl Into<String>) -> Self {
        self.orcid = Some(orcid.into());
        self
    }

    /// Format as "Family, Given" for BibTeX
    pub fn to_bibtex_format(&self) -> String {
        match &self.given_name {
            Some(given) => format!("{}, {}", self.family_name, given),
            None => self.family_name.clone(),
        }
    }

    /// Format as "Given Family" for display
    pub fn display_name(&self) -> String {
        let mut name = match &self.given_name {
            Some(given) => format!("{} {}", given, self.family_name),
            None => self.family_name.clone(),
        };
        if let Some(suffix) = &self.suffix {
            name.push_str(", ");
            name.push_str(suffix);
        }
        name
    }
}

// ===== Author parsing utilities =====

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

/// Parse a BibTeX author string into Author structs
pub fn parse_author_string(input: String) -> Vec<Author> {
    split_authors(input)
        .into_iter()
        .map(|author_str| parse_single_author(&author_str))
        .collect()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn parse_author_string_ffi(input: String) -> Vec<Author> {
    parse_author_string(input)
}

/// Parse a single author string into an Author struct
fn parse_single_author(input: &str) -> Author {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return Author::new("Unknown".to_string());
    }

    // Check for "Last, First" format
    if let Some(comma_pos) = trimmed.find(',') {
        let family = trimmed[..comma_pos].trim();
        let given = trimmed[comma_pos + 1..].trim();
        let mut author = Author::new(family.to_string());
        if !given.is_empty() {
            author.given_name = Some(given.to_string());
        }
        return author;
    }

    // "First Last" format - take last word as family name
    let parts: Vec<&str> = trimmed.split_whitespace().collect();
    if parts.len() == 1 {
        return Author::new(parts[0].to_string());
    }

    let family = parts.last().unwrap_or(&"Unknown").to_string();
    let given = parts[..parts.len() - 1].join(" ");
    let mut author = Author::new(family);
    if !given.is_empty() {
        author.given_name = Some(given);
    }
    author
}

/// Split a BibTeX author field into individual authors.
///
/// Handles " and " separators (BibTeX style) and ";" separators.
pub fn split_authors(author_field: String) -> Vec<String> {
    author_field
        .split(" and ")
        .flat_map(|s| s.split(';'))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn split_authors_ffi(author_field: String) -> Vec<String> {
    split_authors(author_field)
}

/// Extract the first author's last name from a BibTeX author field.
///
/// Handles both "Last, First" and "First Last" formats.
/// Returns "Unknown" if no author is provided.
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

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_first_author_last_name_ffi(author_field: String) -> String {
    extract_first_author_last_name(author_field)
}

/// Normalize an author name for comparison.
///
/// - Converts to lowercase
/// - Removes diacritics
/// - Removes titles (Dr., Prof., etc.)
/// - Removes suffixes (Jr., Sr., PhD, etc.)
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

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn normalize_author_name_ffi(name: String) -> String {
    normalize_author_name(name)
}

/// Extract surname from an author name.
///
/// Handles both "Last, First" and "First Last" formats.
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

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_surname_ffi(author: String) -> String {
    extract_surname(author)
}

/// Extract the first meaningful word from a title for cite key generation.
///
/// Skips common stop words and returns a capitalized word of at least 3 characters.
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

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_first_meaningful_word_ffi(title: String) -> String {
    extract_first_meaningful_word(title)
}

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
    fn test_author_new() {
        let author = Author::new("Einstein".to_string());
        assert_eq!(author.family_name, "Einstein");
        assert!(author.given_name.is_none());
    }

    #[test]
    fn test_author_with_given_name() {
        let author = Author::new("Einstein".to_string()).with_given_name("Albert");
        assert_eq!(author.family_name, "Einstein");
        assert_eq!(author.given_name, Some("Albert".to_string()));
    }

    #[test]
    fn test_to_bibtex_format() {
        let author = Author::new("Einstein".to_string()).with_given_name("Albert");
        assert_eq!(author.to_bibtex_format(), "Einstein, Albert");

        let no_given = Author::new("Einstein".to_string());
        assert_eq!(no_given.to_bibtex_format(), "Einstein");
    }

    #[test]
    fn test_display_name() {
        let author = Author::new("Einstein".to_string()).with_given_name("Albert");
        assert_eq!(author.display_name(), "Albert Einstein");

        let with_suffix = Author::new("King".to_string())
            .with_given_name("Martin Luther")
            .with_suffix("Jr.");
        assert_eq!(with_suffix.display_name(), "Martin Luther King, Jr.");
    }

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
    }
}
