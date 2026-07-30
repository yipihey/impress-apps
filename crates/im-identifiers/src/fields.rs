//! Identifier extraction from BibTeX field maps and ADS URLs.
//!
//! Ported verbatim from imbib's Swift `IdentifierExtractor` (Stage 7 item 1).
//! Behaviour is pinned by `crates/imbib-core/test_fixtures/golden/identifiers_golden.json`,
//! which was captured from the Swift implementation before it was deleted —
//! including its quirks, so nothing changed underneath users' libraries at the
//! moment of the port.

use std::collections::HashMap;

use crate::validators::{is_valid_arxiv_id_format, trim_horizontal};

/// arXiv DOIs are minted as `10.48550/arXiv.<id>`.
const ARXIV_DOI_PREFIX: &str = "10.48550/arxiv.";

/// Fields consulted for an arXiv ID, in priority order.
///
/// `eprint` is the standard BibTeX spelling; `arxivid`/`arxiv` are emitted by
/// assorted exporters.
const ARXIV_FIELDS: [&str; 3] = ["eprint", "arxivid", "arxiv"];

/// Extract the arXiv ID from a BibTeX field map.
///
/// Values are validated, because several sources put a bibcode or a plain DOI
/// in `eprint`; an unvalidated read there sends enrichment to the wrong API.
pub fn arxiv_id_from_fields(fields: &HashMap<String, String>) -> Option<String> {
    for name in ARXIV_FIELDS {
        let Some(value) = fields.get(name) else {
            continue;
        };
        if value.is_empty() {
            continue;
        }

        if let Some(from_doi) = arxiv_id_from_arxiv_doi(value) {
            return Some(from_doi);
        }

        let trimmed = trim_horizontal(value);
        let has_prefix = trimmed
            .get(..6)
            .is_some_and(|p| p.eq_ignore_ascii_case("arxiv:"));
        let clean = if has_prefix { &trimmed[6..] } else { trimmed };

        if is_valid_arxiv_id_format(clean.to_string()) {
            return Some(clean.to_string());
        }
    }
    None
}

/// Unwrap `10.48550/arXiv.2401.12345` into `2401.12345`.
fn arxiv_id_from_arxiv_doi(value: &str) -> Option<String> {
    if !value
        .get(..ARXIV_DOI_PREFIX.len())
        .is_some_and(|p| p.eq_ignore_ascii_case(ARXIV_DOI_PREFIX))
    {
        return None;
    }
    let extracted = &value[ARXIV_DOI_PREFIX.len()..];
    if is_valid_arxiv_id_format(extracted.to_string()) {
        Some(extracted.to_string())
    } else {
        None
    }
}

/// Extract the DOI from a BibTeX field map.
pub fn doi_from_fields(fields: &HashMap<String, String>) -> Option<String> {
    fields.get("doi").cloned()
}

/// Extract the ADS bibcode from a BibTeX field map, falling back to `adsurl`.
pub fn bibcode_from_fields(fields: &HashMap<String, String>) -> Option<String> {
    if let Some(bibcode) = fields.get("bibcode") {
        return Some(bibcode.clone());
    }
    fields
        .get("adsurl")
        .and_then(|url| bibcode_from_ads_url(url))
}

/// Extract the PubMed ID from a BibTeX field map.
pub fn pmid_from_fields(fields: &HashMap<String, String>) -> Option<String> {
    fields.get("pmid").cloned()
}

/// Extract the PubMed Central ID from a BibTeX field map.
pub fn pmcid_from_fields(fields: &HashMap<String, String>) -> Option<String> {
    fields.get("pmcid").cloned()
}

/// Extract every supported identifier from a BibTeX field map at once.
///
/// Keys are the identifier-type names (`doi`, `arxiv`, `bibcode`, `pmid`,
/// `pmcid`) — the same spellings the Swift `IdentifierType` enum used.
pub fn all_identifiers_from_fields(fields: &HashMap<String, String>) -> HashMap<String, String> {
    let mut result = HashMap::new();
    if let Some(value) = arxiv_id_from_fields(fields) {
        result.insert("arxiv".to_string(), value);
    }
    if let Some(value) = doi_from_fields(fields) {
        result.insert("doi".to_string(), value);
    }
    if let Some(value) = bibcode_from_fields(fields) {
        result.insert("bibcode".to_string(), value);
    }
    if let Some(value) = pmid_from_fields(fields) {
        result.insert("pmid".to_string(), value);
    }
    if let Some(value) = pmcid_from_fields(fields) {
        result.insert("pmcid".to_string(), value);
    }
    result
}

/// Extract an ADS bibcode from an ADS abstract URL.
///
/// The host is checked before the path so a `.../abs/...` URL on any other site
/// does not masquerade as an ADS record.
pub fn bibcode_from_ads_url(url: &str) -> Option<String> {
    let parsed = url::Url::parse(url).ok()?;
    if !parsed.host_str()?.contains("adsabs") {
        return None;
    }
    let segments: Vec<&str> = parsed.path_segments()?.collect();
    let index = segments.iter().position(|s| *s == "abs")?;
    let bibcode = segments.get(index + 1)?;
    if bibcode.is_empty() {
        return None;
    }
    Some(bibcode.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn arxiv_field_priority() {
        assert_eq!(
            arxiv_id_from_fields(&map(&[("eprint", "2401.12345"), ("arxiv", "1905.07890")])),
            Some("2401.12345".to_string())
        );
        // eprint is skipped when empty, and when it holds something that is not
        // an arXiv ID at all.
        assert_eq!(
            arxiv_id_from_fields(&map(&[("eprint", ""), ("arxivid", "2401.12345")])),
            Some("2401.12345".to_string())
        );
        assert_eq!(
            arxiv_id_from_fields(&map(&[("eprint", "2024A&A...686A.276A")])),
            None
        );
    }

    #[test]
    fn arxiv_prefix_and_doi_forms() {
        assert_eq!(
            arxiv_id_from_fields(&map(&[("eprint", "arXiv:2401.12345")])),
            Some("2401.12345".to_string())
        );
        assert_eq!(
            arxiv_id_from_fields(&map(&[("eprint", "10.48550/arXiv.2401.12345")])),
            Some("2401.12345".to_string())
        );
        assert_eq!(
            arxiv_id_from_fields(&map(&[("eprint", "10.48550/arXiv.not-an-id")])),
            None
        );
    }

    #[test]
    fn bibcode_prefers_field_then_url() {
        assert_eq!(
            bibcode_from_fields(&map(&[("bibcode", "2023ApJ...123..456A")])),
            Some("2023ApJ...123..456A".to_string())
        );
        assert_eq!(
            bibcode_from_fields(&map(&[(
                "adsurl",
                "https://ui.adsabs.harvard.edu/abs/2023ApJ...123..456A/abstract"
            )])),
            Some("2023ApJ...123..456A".to_string())
        );
    }

    #[test]
    fn ads_url_host_is_checked() {
        assert_eq!(
            bibcode_from_ads_url("https://example.org/abs/2023ApJ...123..456A"),
            None
        );
        assert_eq!(
            bibcode_from_ads_url("https://ui.adsabs.harvard.edu/abs/"),
            None
        );
        assert_eq!(bibcode_from_ads_url("not a url"), None);
    }

    #[test]
    fn all_identifiers_collects_every_kind() {
        let all = all_identifiers_from_fields(&map(&[
            ("doi", "10.1038/nature12373"),
            ("eprint", "2401.12345"),
            ("bibcode", "2023ApJ...123..456A"),
            ("pmid", "12345678"),
            ("pmcid", "PMC1234567"),
        ]));
        assert_eq!(all.len(), 5);
        assert_eq!(all.get("arxiv").map(String::as_str), Some("2401.12345"));
    }
}
