//! Identifier validation functions

use lazy_static::lazy_static;
use regex::Regex;

lazy_static! {
    // DOI validation regex
    static ref DOI_PATTERN: Regex = Regex::new(r"^10\.\d{4,}/\S+$").unwrap();

    // arXiv ID validation regex (new format: YYMM.NNNNN, old format: archive/NNNNNNN)
    static ref ARXIV_NEW_PATTERN: Regex = Regex::new(r"^\d{4}\.\d{4,5}(v\d+)?$").unwrap();
    static ref ARXIV_OLD_PATTERN: Regex = Regex::new(r"^[a-z-]+(\.[a-z-]+)?/\d{7}(v\d+)?$").unwrap();
}

pub(crate) fn is_valid_doi_internal(doi: String) -> bool {
    DOI_PATTERN.is_match(&doi)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_doi(doi: String) -> bool {
    is_valid_doi_internal(doi)
}

pub(crate) fn is_valid_arxiv_id_internal(arxiv_id: String) -> bool {
    ARXIV_NEW_PATTERN.is_match(&arxiv_id) || ARXIV_OLD_PATTERN.is_match(&arxiv_id)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_arxiv_id(arxiv_id: String) -> bool {
    is_valid_arxiv_id_internal(arxiv_id)
}

pub(crate) fn is_valid_isbn_internal(isbn: String) -> bool {
    // Normalize: remove hyphens and spaces
    let normalized: String = isbn
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == 'X' || *c == 'x')
        .collect::<String>()
        .to_uppercase();

    match normalized.len() {
        10 => validate_isbn10(&normalized),
        13 => validate_isbn13(&normalized),
        _ => false,
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_isbn(isbn: String) -> bool {
    is_valid_isbn_internal(isbn)
}

pub(crate) fn normalize_doi_internal(doi: String) -> String {
    let mut result = doi.trim().to_string();

    // Remove common prefixes
    let prefixes = [
        "https://doi.org/",
        "http://doi.org/",
        "https://dx.doi.org/",
        "http://dx.doi.org/",
        "doi:",
        "DOI:",
    ];

    for prefix in prefixes {
        if let Some(stripped) = result.strip_prefix(prefix) {
            result = stripped.to_string();
            break;
        }
    }

    // Remove trailing punctuation
    while let Some(c) = result.chars().last() {
        if c == '.' || c == ',' || c == ';' {
            result.pop();
        } else {
            break;
        }
    }

    result
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn normalize_doi(doi: String) -> String {
    normalize_doi_internal(doi)
}

/// Validate ISBN-10 checksum
fn validate_isbn10(isbn: &str) -> bool {
    if isbn.len() != 10 {
        return false;
    }

    let chars: Vec<char> = isbn.chars().collect();

    // Check that first 9 are digits and last is digit or X
    for (i, &c) in chars.iter().enumerate() {
        if i < 9 {
            if !c.is_ascii_digit() {
                return false;
            }
        } else if !c.is_ascii_digit() && c != 'X' {
            return false;
        }
    }

    // Calculate checksum
    let sum: u32 = chars
        .iter()
        .enumerate()
        .map(|(i, &c)| {
            let value = if c == 'X' {
                10
            } else {
                c.to_digit(10).unwrap()
            };
            value * (10 - i as u32)
        })
        .sum();

    sum.is_multiple_of(11)
}

/// Validate ISBN-13 checksum
fn validate_isbn13(isbn: &str) -> bool {
    if isbn.len() != 13 {
        return false;
    }

    // All characters must be digits
    if !isbn.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }

    // Calculate checksum
    let sum: u32 = isbn
        .chars()
        .enumerate()
        .map(|(i, c)| {
            let value = c.to_digit(10).unwrap();
            if i.is_multiple_of(2) {
                value
            } else {
                value * 3
            }
        })
        .sum();

    sum.is_multiple_of(10)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_valid_dois() {
        assert!(is_valid_doi("10.1038/nature12373".to_string()));
        assert!(is_valid_doi("10.1126/science.1234567".to_string()));
        assert!(is_valid_doi("10.1000/182".to_string()));
    }

    #[test]
    fn test_invalid_dois() {
        assert!(!is_valid_doi("11.1038/nature12373".to_string())); // Wrong prefix
        assert!(!is_valid_doi("10.12/test".to_string())); // Registrant too short
        assert!(!is_valid_doi("nature12373".to_string())); // Missing 10.
    }

    #[test]
    fn test_valid_arxiv_ids() {
        assert!(is_valid_arxiv_id("2301.12345".to_string())); // New format
        assert!(is_valid_arxiv_id("1905.07890v2".to_string())); // With version
        assert!(is_valid_arxiv_id("cond-mat/9901001".to_string())); // Old format
        assert!(is_valid_arxiv_id("hep-th/9901001v1".to_string())); // Old with version
    }

    #[test]
    fn test_invalid_arxiv_ids() {
        assert!(!is_valid_arxiv_id("12345".to_string()));
        assert!(!is_valid_arxiv_id("2301.123".to_string())); // Too short
    }

    #[test]
    fn test_valid_isbns() {
        assert!(is_valid_isbn("0-306-40615-2".to_string())); // ISBN-10
        assert!(is_valid_isbn("978-0-321-12521-7".to_string())); // ISBN-13
        assert!(is_valid_isbn("0306406152".to_string())); // Without hyphens
        assert!(is_valid_isbn("9780321125217".to_string())); // Without hyphens
        assert!(is_valid_isbn("080442957X".to_string())); // ISBN-10 with X
    }

    #[test]
    fn test_invalid_isbns() {
        assert!(!is_valid_isbn("0-306-40615-1".to_string())); // Bad checksum
        assert!(!is_valid_isbn("978-0-321-12521-8".to_string())); // Bad checksum
        assert!(!is_valid_isbn("12345".to_string())); // Too short
    }

    #[test]
    fn test_normalize_doi() {
        assert_eq!(
            normalize_doi("https://doi.org/10.1038/nature12373".to_string()),
            "10.1038/nature12373"
        );
        assert_eq!(
            normalize_doi("doi:10.1038/nature12373".to_string()),
            "10.1038/nature12373"
        );
        assert_eq!(
            normalize_doi("10.1038/nature12373.".to_string()),
            "10.1038/nature12373"
        );
    }
}
