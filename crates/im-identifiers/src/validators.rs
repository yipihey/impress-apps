//! Identifier validation functions

use lazy_static::lazy_static;
use regex::Regex;

lazy_static! {
    // DOI validation regex
    static ref DOI_PATTERN: Regex = Regex::new(r"^10\.\d{4,}/\S+$").unwrap();

    // arXiv ID validation regex (new format: YYMM.NNNNN, old format: archive/NNNNNNN)
    static ref ARXIV_NEW_PATTERN: Regex = Regex::new(r"^\d{4}\.\d{4,5}(v\d+)?$").unwrap();
    static ref ARXIV_OLD_PATTERN: Regex = Regex::new(r"^[a-z-]+(\.[a-z-]+)?/\d{7}(v\d+)?$").unwrap();

    // Stricter arXiv shape check used when deciding whether a BibTeX `eprint`
    // value really is an arXiv ID. Unlike `is_valid_arxiv_id` it rejects the
    // dotted subject class (`math.CO/0309136`) but accepts the old format in
    // any case (`ASTRO-PH/0612345`).
    static ref ARXIV_FORMAT_NEW: Regex = Regex::new(r"^\d{4}\.\d{4,5}(v\d+)?$").unwrap();
    static ref ARXIV_FORMAT_OLD: Regex = Regex::new(r"(?i)^[a-z-]+/\d{7}(v\d+)?$").unwrap();
}

/// Trim spaces and tabs but keep line breaks.
///
/// Mirrors Swift's `trimmingCharacters(in: .whitespaces)`, which — unlike
/// `.whitespacesAndNewlines` — leaves `\n` alone.
pub fn trim_horizontal(value: &str) -> &str {
    value.trim_matches(|c: char| c.is_whitespace() && c != '\n' && c != '\r')
}

/// Check whether a string has the shape of an arXiv ID.
///
/// Used to reject bibcodes and DOIs that some sources dump into the BibTeX
/// `eprint` field.
pub fn is_valid_arxiv_id_format(value: String) -> bool {
    let trimmed = trim_horizontal(&value);
    if trimmed.is_empty() {
        return false;
    }
    ARXIV_FORMAT_NEW.is_match(trimmed) || ARXIV_FORMAT_OLD.is_match(trimmed)
}

/// Normalise an arXiv ID for indexed lookups.
///
/// Strips an `arXiv:` prefix and a trailing version suffix, then lowercases —
/// so `arXiv:2401.12345v2` and `2401.12345` collapse to the same key.
pub fn normalize_arxiv_id(arxiv_id: String) -> String {
    let mut id = trim_horizontal(&arxiv_id).to_string();

    if id
        .get(..6)
        .is_some_and(|p| p.eq_ignore_ascii_case("arxiv:"))
    {
        id = id[6..].to_string();
    }

    if let Some(v_index) = id.rfind('v') {
        let suffix = &id[v_index + 1..];
        if !suffix.is_empty() && suffix.chars().all(|c| c.is_ascii_digit()) {
            id.truncate(v_index);
        }
    }

    id.to_lowercase()
}

/// Validate a DOI
pub fn is_valid_doi(doi: String) -> bool {
    DOI_PATTERN.is_match(&doi)
}

/// Validate an arXiv ID
pub fn is_valid_arxiv_id(arxiv_id: String) -> bool {
    ARXIV_NEW_PATTERN.is_match(&arxiv_id) || ARXIV_OLD_PATTERN.is_match(&arxiv_id)
}

/// Validate an ISBN (both ISBN-10 and ISBN-13)
pub fn is_valid_isbn(isbn: String) -> bool {
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

/// Normalize a DOI by removing common prefixes and trailing punctuation
pub fn normalize_doi(doi: String) -> String {
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

    sum % 11 == 0
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
            if i % 2 == 0 {
                value
            } else {
                value * 3
            }
        })
        .sum();

    sum % 10 == 0
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
    fn test_is_valid_arxiv_id_format() {
        assert!(is_valid_arxiv_id_format("2401.12345".into()));
        assert!(is_valid_arxiv_id_format("2401.12345v2".into()));
        assert!(is_valid_arxiv_id_format("  2401.12345  ".into()));
        assert!(is_valid_arxiv_id_format("astro-ph/0612345".into()));
        assert!(is_valid_arxiv_id_format("ASTRO-PH/0612345".into()));
        // Prefixed and dotted-subject forms are *not* accepted here — this is
        // the shape check for a raw `eprint` value.
        assert!(!is_valid_arxiv_id_format("arXiv:2401.12345".into()));
        assert!(!is_valid_arxiv_id_format("math.CO/0309136".into()));
        assert!(!is_valid_arxiv_id_format("2024A&A...686A.276A".into()));
        assert!(!is_valid_arxiv_id_format("".into()));
    }

    #[test]
    fn test_normalize_arxiv_id() {
        assert_eq!(normalize_arxiv_id("2401.12345v2".into()), "2401.12345");
        assert_eq!(
            normalize_arxiv_id("arXiv:2401.12345v3".into()),
            "2401.12345"
        );
        assert_eq!(normalize_arxiv_id("ARXIV:2401.12345".into()), "2401.12345");
        assert_eq!(
            normalize_arxiv_id("ASTRO-PH/0612345".into()),
            "astro-ph/0612345"
        );
        assert_eq!(
            normalize_arxiv_id("hep-th/9901001v1".into()),
            "hep-th/9901001"
        );
        assert_eq!(normalize_arxiv_id("v2".into()), "");
        assert_eq!(normalize_arxiv_id("2401.12345vv2".into()), "2401.12345v");
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
