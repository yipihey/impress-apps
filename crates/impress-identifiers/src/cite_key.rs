//! Cite key generation
//!
//! Provides functions for generating BibTeX cite keys from metadata,
//! with support for collision detection and uniquification.

use std::collections::HashSet;
use unicode_normalization::UnicodeNormalization;

/// Generate a cite key from author, year, and title
pub fn generate_cite_key(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
) -> String {
    let mut key = String::new();

    // Extract last name from author
    if let Some(ref author_str) = author {
        if let Some(last_name) = extract_last_name(author_str) {
            key.push_str(&normalize_for_key(&last_name));
        }
    }

    // Add year
    if let Some(ref year_str) = year {
        // Extract 4-digit year
        let year_digits: String = year_str
            .chars()
            .filter(|c| c.is_ascii_digit())
            .take(4)
            .collect();
        if year_digits.len() == 4 {
            key.push_str(&year_digits);
        }
    }

    // Add first significant word from title
    if let Some(ref title_str) = title {
        if let Some(word) = first_significant_word(title_str) {
            let normalized = normalize_for_key(&word);
            // Capitalize first letter
            let mut chars = normalized.chars();
            if let Some(first) = chars.next() {
                key.push(first.to_ascii_uppercase());
                key.push_str(&chars.collect::<String>());
            }
        }
    }

    // If key is empty, generate a placeholder
    if key.is_empty() {
        key = "Unknown".to_string();
    }

    key
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn generate_cite_key_ffi(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
) -> String {
    generate_cite_key(author, year, title)
}

/// Generate a unique cite key that doesn't conflict with existing keys
pub fn generate_unique_cite_key(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
    existing_keys: Vec<String>,
) -> String {
    let base = generate_cite_key(author, year, title);
    make_cite_key_unique(base, existing_keys)
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn generate_unique_cite_key_ffi(
    author: Option<String>,
    year: Option<String>,
    title: Option<String>,
    existing_keys: Vec<String>,
) -> String {
    generate_unique_cite_key(author, year, title, existing_keys)
}

/// Make a cite key unique by adding suffixes if needed
pub fn make_cite_key_unique(base: String, existing_keys: Vec<String>) -> String {
    let existing_set: HashSet<&str> = existing_keys.iter().map(|s| s.as_str()).collect();

    // If base key doesn't conflict, return it
    if !existing_set.contains(base.as_str()) {
        return base;
    }

    // Try letter suffixes: a, b, c, ...
    for suffix in 'a'..='z' {
        let candidate = format!("{}{}", base, suffix);
        if !existing_set.contains(candidate.as_str()) {
            return candidate;
        }
    }

    // Fall back to numbers: 2, 3, 4, ...
    let mut counter = 2;
    loop {
        let candidate = format!("{}{}", base, counter);
        if !existing_set.contains(candidate.as_str()) {
            return candidate;
        }
        counter += 1;

        // Safety limit (shouldn't happen in practice)
        if counter > 10000 {
            return format!(
                "{}_{}",
                base,
                uuid::Uuid::new_v4()
                    .to_string()
                    .split('-')
                    .next()
                    .unwrap_or("x")
            );
        }
    }
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn make_cite_key_unique_ffi(base: String, existing_keys: Vec<String>) -> String {
    make_cite_key_unique(base, existing_keys)
}

/// Sanitize a cite key by removing invalid characters
pub fn sanitize_cite_key(key: String) -> String {
    key.chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-' || *c == ':')
        .collect()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn sanitize_cite_key_ffi(key: String) -> String {
    sanitize_cite_key(key)
}

/// Extract last name from author string
///
/// Handles formats:
/// - "Last, First"
/// - "First Last"
/// - "First Middle Last"
fn extract_last_name(author: &str) -> Option<String> {
    // Get first author if multiple (separated by "and" or ";")
    let first_author = author
        .split(" and ")
        .next()
        .or_else(|| author.split(';').next())
        .unwrap_or(author)
        .trim();

    if first_author.is_empty() {
        return None;
    }

    // Check for "Last, First" format
    if let Some(comma_pos) = first_author.find(',') {
        return Some(first_author[..comma_pos].trim().to_string());
    }

    // "First Last" format - take last word
    first_author
        .split_whitespace()
        .last()
        .map(|s| s.to_string())
}

/// Get first significant word from title
///
/// Skips common articles and prepositions
fn first_significant_word(title: &str) -> Option<String> {
    let stopwords = [
        "a", "an", "the", "on", "in", "of", "for", "to", "and", "with", "by", "from", "as", "at",
        "is", "are", "was", "were", "be", "been", "being", "have", "has", "had", "do", "does",
        "did", "will", "would", "could", "should", "may", "might", "must", "shall", "can",
    ];

    for word in title.split_whitespace() {
        // Clean word of punctuation
        let clean: String = word.chars().filter(|c| c.is_alphanumeric()).collect();

        if clean.is_empty() {
            continue;
        }

        if !stopwords.contains(&clean.to_lowercase().as_str()) {
            return Some(clean);
        }
    }

    // If all words are stopwords, return the first word
    title
        .split_whitespace()
        .next()
        .map(|w| w.chars().filter(|c| c.is_alphanumeric()).collect())
}

/// Normalize a string for use in a cite key
///
/// - Removes diacritics
/// - Converts to ASCII
/// - Removes non-alphanumeric characters
fn normalize_for_key(s: &str) -> String {
    s.nfkd()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
        .to_lowercase()
        // Capitalize first letter
        .chars()
        .enumerate()
        .map(|(i, c)| if i == 0 { c.to_ascii_uppercase() } else { c })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_cite_key() {
        assert_eq!(
            generate_cite_key(
                Some("John Smith".to_string()),
                Some("2024".to_string()),
                Some("Machine Learning for Everyone".to_string())
            ),
            "Smith2024Machine"
        );
    }

    #[test]
    fn test_cite_key_last_first_format() {
        assert_eq!(
            generate_cite_key(
                Some("Smith, John".to_string()),
                Some("2024".to_string()),
                Some("Deep Learning".to_string())
            ),
            "Smith2024Deep"
        );
    }

    #[test]
    fn test_cite_key_with_article() {
        assert_eq!(
            generate_cite_key(
                Some("Doe, Jane".to_string()),
                Some("2023".to_string()),
                Some("The Future of AI".to_string())
            ),
            "Doe2023Future"
        );
    }

    #[test]
    fn test_cite_key_multiple_authors() {
        assert_eq!(
            generate_cite_key(
                Some("Smith, John and Doe, Jane".to_string()),
                Some("2024".to_string()),
                Some("Collaboration".to_string())
            ),
            "Smith2024Collaboration"
        );
    }

    #[test]
    fn test_extract_last_name() {
        assert_eq!(extract_last_name("John Smith"), Some("Smith".to_string()));
        assert_eq!(extract_last_name("Smith, John"), Some("Smith".to_string()));
        assert_eq!(
            extract_last_name("John van der Berg"),
            Some("Berg".to_string())
        );
    }

    #[test]
    fn test_first_significant_word() {
        assert_eq!(
            first_significant_word("The Quick Brown Fox"),
            Some("Quick".to_string())
        );
        assert_eq!(
            first_significant_word("A Study in Scarlet"),
            Some("Study".to_string())
        );
        assert_eq!(
            first_significant_word("Machine Learning"),
            Some("Machine".to_string())
        );
    }

    #[test]
    fn test_normalize_for_key() {
        assert_eq!(normalize_for_key("müller"), "Muller");
        assert_eq!(normalize_for_key("O'Brien"), "Obrien");
        assert_eq!(normalize_for_key("García-López"), "Garcialopez");
    }

    #[test]
    fn test_cite_key_with_diacritics() {
        assert_eq!(
            generate_cite_key(
                Some("François Müller".to_string()),
                Some("2024".to_string()),
                Some("Études".to_string())
            ),
            "Muller2024Etudes"
        );
    }

    #[test]
    fn test_generate_unique_no_conflict() {
        let existing = vec!["Jones2024Deep".to_string(), "Brown2023AI".to_string()];
        let result = generate_unique_cite_key(
            Some("John Smith".to_string()),
            Some("2024".to_string()),
            Some("Machine Learning".to_string()),
            existing,
        );
        assert_eq!(result, "Smith2024Machine");
    }

    #[test]
    fn test_generate_unique_with_conflict() {
        let existing = vec!["Smith2024Machine".to_string()];
        let result = generate_unique_cite_key(
            Some("John Smith".to_string()),
            Some("2024".to_string()),
            Some("Machine Learning".to_string()),
            existing,
        );
        assert_eq!(result, "Smith2024Machinea");
    }

    #[test]
    fn test_generate_unique_multiple_conflicts() {
        let existing = vec![
            "Smith2024Machine".to_string(),
            "Smith2024Machinea".to_string(),
            "Smith2024Machineb".to_string(),
        ];
        let result = generate_unique_cite_key(
            Some("John Smith".to_string()),
            Some("2024".to_string()),
            Some("Machine Learning".to_string()),
            existing,
        );
        assert_eq!(result, "Smith2024Machinec");
    }

    #[test]
    fn test_make_cite_key_unique_no_conflict() {
        let existing = vec!["Jones2024".to_string()];
        assert_eq!(
            make_cite_key_unique("Smith2024".to_string(), existing),
            "Smith2024"
        );
    }

    #[test]
    fn test_make_cite_key_unique_with_letter_suffix() {
        let existing = vec!["Smith2024".to_string()];
        assert_eq!(
            make_cite_key_unique("Smith2024".to_string(), existing),
            "Smith2024a"
        );
    }

    #[test]
    fn test_make_cite_key_unique_exhausts_letters() {
        // Create existing keys for all letters
        let mut existing: Vec<String> = vec!["Smith2024".to_string()];
        for c in 'a'..='z' {
            existing.push(format!("Smith2024{}", c));
        }

        let result = make_cite_key_unique("Smith2024".to_string(), existing);
        assert_eq!(result, "Smith20242");
    }
}
