//! Identifier extraction from text

use lazy_static::lazy_static;
use regex::Regex;
use serde::{Deserialize, Serialize};

/// Extracted identifier with position information
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
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

    // ── Single-value scanners (ported from Swift `IdentifierExtractor`) ──
    //
    // These differ from the `extract_*` family above: they return the *first*
    // hit and post-process it the way the imbib PDF/metadata scanners always
    // have. Behaviour is pinned by the golden corpus.

    // Stops at whitespace and the punctuation that usually closes a citation,
    // and refuses to end on a '.' so a sentence-final period is not swallowed.
    static ref FIRST_DOI_REGEX: Regex = Regex::new(
        r#"(?i)(?:doi[:\s]*)?(?:https?://(?:dx\.)?doi\.org/)?10\.\d{4,}/[^\s,;"\]>)]+[^\s,;"\]>).]"#
    ).unwrap();

    static ref FIRST_ARXIV_NEW_REGEX: Regex =
        Regex::new(r"(?i)(?:arXiv:)?(\d{4}\.\d{4,5}(?:v\d+)?)").unwrap();
    static ref FIRST_ARXIV_OLD_REGEX: Regex =
        Regex::new(r"(?i)(?:arXiv:)?([a-z-]+/\d{7}(?:v\d+)?)").unwrap();

    // Bibcodes are exactly 19 characters: YYYYJJJJJVVVVMPPPPA.
    static ref FIRST_BIBCODE_REGEX: Regex =
        Regex::new(r"\b((?:19|20)\d{2}[A-Za-z&.]{5}[.\d]{4}[A-Za-z.][.\d]{4}[A-Za-z.])\b").unwrap();

    static ref FIRST_PMID_REGEX: Regex =
        Regex::new(r"(?i)(?:PMID|PubMed(?:\s*ID)?)[:\s]+(\d{6,9})").unwrap();
    static ref FIRST_PMID_URL_REGEX: Regex =
        Regex::new(r"(?i)pubmed\.ncbi\.nlm\.nih\.gov/(\d{6,9})").unwrap();
}

/// Extract the first DOI from free-form text (e.g. text scraped out of a PDF).
///
/// Unlike [`extract_dois`] this strips a `doi:` / `doi.org/` prefix and trailing
/// sentence punctuation from the hit.
pub fn extract_doi_from_text(text: String) -> Option<String> {
    let matched = FIRST_DOI_REGEX.find(&text)?;
    let mut doi = matched.as_str().to_string();

    let lowered = doi.to_lowercase();
    if lowered.starts_with("doi:") || lowered.starts_with("doi ") {
        doi = doi[4..].trim().to_string();
    } else if lowered.starts_with("doi")
        && doi.len() > 3
        && doi[3..].chars().next().is_some_and(char::is_whitespace)
    {
        doi = doi[3..].trim().to_string();
    }

    if let Some(position) = doi.to_lowercase().find("doi.org/") {
        doi = doi[position + "doi.org/".len()..].to_string();
    }

    while matches!(doi.chars().last(), Some('.') | Some(',') | Some(';')) {
        doi.pop();
    }

    if doi.is_empty() {
        None
    } else {
        Some(doi)
    }
}

/// Extract the first arXiv ID from free-form text, normalised for lookups.
///
/// The new (`2401.12345`) format is tried before the old (`astro-ph/0612345`)
/// one because it is far more common in modern PDFs.
pub fn extract_arxiv_from_text(text: String) -> Option<String> {
    for regex in [&*FIRST_ARXIV_NEW_REGEX, &*FIRST_ARXIV_OLD_REGEX] {
        if let Some(captures) = regex.captures(&text) {
            if let Some(id) = captures.get(1) {
                return Some(crate::validators::normalize_arxiv_id(
                    id.as_str().to_string(),
                ));
            }
        }
    }
    None
}

/// Extract the first ADS bibcode from free-form text.
pub fn extract_bibcode_from_text(text: String) -> Option<String> {
    let captures = FIRST_BIBCODE_REGEX.captures(&text)?;
    let bibcode = captures.get(1)?.as_str();
    if bibcode.chars().count() == 19 {
        Some(bibcode.to_string())
    } else {
        None
    }
}

/// Extract the first PubMed ID from free-form text, including PubMed URLs.
pub fn extract_pmid_from_text(text: String) -> Option<String> {
    for regex in [&*FIRST_PMID_REGEX, &*FIRST_PMID_URL_REGEX] {
        if let Some(captures) = regex.captures(&text) {
            if let Some(pmid) = captures.get(1) {
                return Some(pmid.as_str().to_string());
            }
        }
    }
    None
}

/// Extract DOIs from text
pub fn extract_dois(text: String) -> Vec<String> {
    DOI_REGEX
        .captures_iter(&text)
        .filter_map(|cap| cap.name("doi"))
        .map(|m| clean_doi(m.as_str()))
        .collect()
}

/// Extract arXiv IDs from text
pub fn extract_arxiv_ids(text: String) -> Vec<String> {
    ARXIV_REGEX
        .captures_iter(&text)
        .filter_map(|cap| cap.name("id"))
        .map(|m| m.as_str().to_string())
        .collect()
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
