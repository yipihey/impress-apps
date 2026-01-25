//! Identifier extraction from text

use lazy_static::lazy_static;
use regex::Regex;
use serde::{Deserialize, Serialize};

/// Extracted identifier with position information
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct ExtractedIdentifier {
    pub identifier_type: String,
    pub value: String,
    pub start_index: u32,
    pub end_index: u32,
}

lazy_static! {
    // DOI regex: 10.XXXX/... pattern
    // DOIs start with 10. followed by registrant code and suffix
    static ref DOI_REGEX: Regex = Regex::new(
        r#"(?i)(?:doi[:\s]*)?(?:https?://(?:dx\.)?doi\.org/)?(?P<doi>10\.\d{4,}/[^\s\]}>\"',;]+)"#
    ).unwrap();

    // arXiv ID regex: supports old (cond-mat/9901001) and new (1234.56789) formats
    static ref ARXIV_REGEX: Regex = Regex::new(
        r"(?i)(?:arxiv[:\s]*)?(?:https?://arxiv\.org/abs/)?(?P<id>(?:\d{4}\.\d{4,5}(?:v\d+)?)|(?:[a-z-]+(?:\.[a-z-]+)?/\d{7}(?:v\d+)?))"
    ).unwrap();

    // ISBN regex: ISBN-10 and ISBN-13
    static ref ISBN_REGEX: Regex = Regex::new(
        r"(?i)(?:isbn[:\s-]*)?(?P<isbn>(?:97[89][- ]?)?(?:\d[- ]?){9}[\dxX])"
    ).unwrap();
}

/// Extract DOIs from text
pub fn extract_dois(text: String) -> Vec<String> {
    DOI_REGEX
        .captures_iter(&text)
        .filter_map(|cap| cap.name("doi"))
        .map(|m| clean_doi(m.as_str()))
        .collect()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_dois_ffi(text: String) -> Vec<String> {
    extract_dois(text)
}

/// Extract arXiv IDs from text
pub fn extract_arxiv_ids(text: String) -> Vec<String> {
    ARXIV_REGEX
        .captures_iter(&text)
        .filter_map(|cap| cap.name("id"))
        .map(|m| m.as_str().to_string())
        .collect()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_arxiv_ids_ffi(text: String) -> Vec<String> {
    extract_arxiv_ids(text)
}

/// Extract ISBNs from text
pub fn extract_isbns(text: String) -> Vec<String> {
    ISBN_REGEX
        .captures_iter(&text)
        .filter_map(|cap| cap.name("isbn"))
        .map(|m| normalize_isbn(m.as_str()))
        .filter(|isbn| is_valid_isbn_checksum(isbn))
        .collect()
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_isbns_ffi(text: String) -> Vec<String> {
    extract_isbns(text)
}

/// Extract all identifiers from text
pub fn extract_all(text: String) -> Vec<ExtractedIdentifier> {
    let mut results = Vec::new();

    // Extract DOIs
    for cap in DOI_REGEX.captures_iter(&text) {
        if let Some(m) = cap.name("doi") {
            results.push(ExtractedIdentifier {
                identifier_type: "doi".to_string(),
                value: clean_doi(m.as_str()),
                start_index: m.start() as u32,
                end_index: m.end() as u32,
            });
        }
    }

    // Extract arXiv IDs
    for cap in ARXIV_REGEX.captures_iter(&text) {
        if let Some(m) = cap.name("id") {
            results.push(ExtractedIdentifier {
                identifier_type: "arxiv".to_string(),
                value: m.as_str().to_string(),
                start_index: m.start() as u32,
                end_index: m.end() as u32,
            });
        }
    }

    // Extract ISBNs
    for cap in ISBN_REGEX.captures_iter(&text) {
        if let Some(m) = cap.name("isbn") {
            let isbn = normalize_isbn(m.as_str());
            if is_valid_isbn_checksum(&isbn) {
                results.push(ExtractedIdentifier {
                    identifier_type: "isbn".to_string(),
                    value: isbn,
                    start_index: m.start() as u32,
                    end_index: m.end() as u32,
                });
            }
        }
    }

    // Sort by position
    results.sort_by_key(|r| r.start_index);
    results
}

#[cfg(feature = "uniffi")]
#[uniffi::export]
pub fn extract_all_ffi(text: String) -> Vec<ExtractedIdentifier> {
    extract_all(text)
}

/// Clean a DOI by removing trailing punctuation
fn clean_doi(doi: &str) -> String {
    let mut s = doi.to_string();
    // Remove trailing punctuation that might have been captured
    while let Some(c) = s.chars().last() {
        if c == '.' || c == ',' || c == ';' || c == ')' || c == ']' {
            s.pop();
        } else {
            break;
        }
    }
    s
}

/// Normalize ISBN by removing hyphens and spaces
fn normalize_isbn(isbn: &str) -> String {
    isbn.chars()
        .filter(|c| c.is_ascii_digit() || *c == 'X' || *c == 'x')
        .collect::<String>()
        .to_uppercase()
}

/// Validate ISBN checksum
fn is_valid_isbn_checksum(isbn: &str) -> bool {
    let digits: Vec<char> = isbn.chars().collect();

    match digits.len() {
        10 => {
            // ISBN-10 checksum
            let sum: u32 = digits
                .iter()
                .enumerate()
                .map(|(i, &c)| {
                    let value = if c == 'X' {
                        10
                    } else {
                        c.to_digit(10).unwrap_or(0)
                    };
                    value * (10 - i as u32)
                })
                .sum();
            sum % 11 == 0
        }
        13 => {
            // ISBN-13 checksum
            let sum: u32 = digits
                .iter()
                .enumerate()
                .map(|(i, &c)| {
                    let value = c.to_digit(10).unwrap_or(0);
                    if i % 2 == 0 {
                        value
                    } else {
                        value * 3
                    }
                })
                .sum();
            sum % 10 == 0
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_dois() {
        let text = "Check out this paper: 10.1038/nature12373 and also doi:10.1126/science.1234567";
        let dois = extract_dois(text.to_string());
        assert_eq!(dois.len(), 2);
        assert!(dois.contains(&"10.1038/nature12373".to_string()));
        assert!(dois.contains(&"10.1126/science.1234567".to_string()));
    }

    #[test]
    fn test_extract_dois_with_url() {
        let text = "See https://doi.org/10.1038/nature12373 for details";
        let dois = extract_dois(text.to_string());
        assert_eq!(dois, vec!["10.1038/nature12373"]);
    }

    #[test]
    fn test_extract_arxiv_ids() {
        let text = "New paper: arXiv:2301.12345 and also 1905.07890v2";
        let ids = extract_arxiv_ids(text.to_string());
        assert_eq!(ids.len(), 2);
        assert!(ids.contains(&"2301.12345".to_string()));
        assert!(ids.contains(&"1905.07890v2".to_string()));
    }

    #[test]
    fn test_extract_arxiv_old_format() {
        let text = "Classic paper: cond-mat/9901001";
        let ids = extract_arxiv_ids(text.to_string());
        assert_eq!(ids, vec!["cond-mat/9901001"]);
    }

    #[test]
    fn test_extract_isbns() {
        let text = "ISBN: 978-0-321-12521-7 and also 0-306-40615-2";
        let isbns = extract_isbns(text.to_string());
        assert_eq!(isbns.len(), 2);
        assert!(isbns.contains(&"9780321125217".to_string()));
        assert!(isbns.contains(&"0306406152".to_string()));
    }

    #[test]
    fn test_extract_all() {
        let text = "DOI: 10.1038/nature12373, arXiv: 2301.12345";
        let ids = extract_all(text.to_string());
        assert_eq!(ids.len(), 2);
        assert_eq!(ids[0].identifier_type, "doi");
        assert_eq!(ids[1].identifier_type, "arxiv");
    }

    #[test]
    fn test_clean_doi() {
        assert_eq!(clean_doi("10.1038/nature12373."), "10.1038/nature12373");
        assert_eq!(clean_doi("10.1038/nature12373),"), "10.1038/nature12373");
    }

    #[test]
    fn test_isbn_checksum() {
        assert!(is_valid_isbn_checksum("0306406152")); // ISBN-10
        assert!(is_valid_isbn_checksum("9780321125217")); // ISBN-13
        assert!(!is_valid_isbn_checksum("0306406151")); // Invalid
    }
}
