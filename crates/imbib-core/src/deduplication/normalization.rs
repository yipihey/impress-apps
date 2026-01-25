//! Text normalization for deduplication comparison

use unicode_normalization::UnicodeNormalization;

/// Normalize a title for comparison
///
/// - Converts to lowercase
/// - Removes diacritics
/// - Removes punctuation
/// - Collapses whitespace
/// - Removes common prefixes/suffixes
pub(crate) fn normalize_title(title: &str) -> String {
    normalize_title_internal(title)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn normalize_title_export(title: String) -> String {
    normalize_title_internal(&title)
}

pub(crate) fn normalize_author(author: &str) -> String {
    normalize_author_internal(author)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn normalize_author_export(author: String) -> String {
    normalize_author_internal(&author)
}

/// Internal title normalization
pub(crate) fn normalize_title_internal(title: &str) -> String {
    let mut result: String = title
        // Unicode normalize (NFD to separate combining characters)
        .nfkd()
        // Keep only ASCII alphanumeric and space
        .filter(|c| c.is_ascii_alphanumeric() || c.is_ascii_whitespace())
        .collect();

    // Convert to lowercase
    result = result.to_lowercase();

    // Collapse whitespace
    result = collapse_whitespace(&result);

    // Remove common prefixes that don't affect matching
    let prefixes = ["a ", "an ", "the ", "on ", "re "];
    for prefix in prefixes {
        if result.starts_with(prefix) {
            result = result[prefix.len()..].to_string();
        }
    }

    result.trim().to_string()
}

/// Internal author normalization
pub(crate) fn normalize_author_internal(author: &str) -> String {
    let mut result: String = author
        // Unicode normalize
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
    result = collapse_whitespace(&result);

    result.trim().to_string()
}

/// Collapse multiple whitespace characters into a single space
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

/// Extract surname from an author name
pub(crate) fn extract_surname(author: &str) -> String {
    let normalized = normalize_author_internal(author);

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

/// Split author string into individual authors
pub(crate) fn split_authors(authors: &str) -> Vec<String> {
    authors
        .split(" and ")
        .flat_map(|s| s.split(';'))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_title() {
        assert_eq!(
            normalize_title("The Quick Brown Fox"),
            "quick brown fox"
        );
        assert_eq!(
            normalize_title("A Study in Scarlet"),
            "study in scarlet"
        );
        assert_eq!(
            normalize_title("Machine   Learning"),
            "machine learning"
        );
    }

    #[test]
    fn test_normalize_title_with_punctuation() {
        assert_eq!(normalize_title("Hello, World!"), "hello world");
        assert_eq!(normalize_title("Test: A Study"), "test a study");
    }

    #[test]
    fn test_normalize_title_with_diacritics() {
        assert_eq!(
            normalize_title("Études Françaises"),
            "etudes francaises"
        );
        assert_eq!(normalize_title("Naïve Bayes"), "naive bayes");
    }

    #[test]
    fn test_normalize_author() {
        assert_eq!(normalize_author("John Smith"), "john smith");
        assert_eq!(normalize_author("Dr. John Smith"), "john smith");
        assert_eq!(normalize_author("John Smith Jr."), "john smith");
    }

    #[test]
    fn test_normalize_author_with_diacritics() {
        assert_eq!(
            normalize_author("François Müller"),
            "francois muller"
        );
    }

    #[test]
    fn test_extract_surname() {
        assert_eq!(extract_surname("John Smith"), "smith");
        assert_eq!(extract_surname("Smith, John"), "smith");
        assert_eq!(extract_surname("Dr. John Smith Jr."), "smith");
    }

    #[test]
    fn test_split_authors() {
        assert_eq!(
            split_authors("John Smith and Jane Doe"),
            vec!["John Smith", "Jane Doe"]
        );
        assert_eq!(
            split_authors("Smith, J.; Doe, J."),
            vec!["Smith, J.", "Doe, J."]
        );
    }
}
