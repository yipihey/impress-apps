//! Identifier extraction from BibTeX field maps, ADS URLs, and free-form text.
//!
//! Delegates to the canonical `impress_identifiers` (→ `im-identifiers`) crate;
//! only the UniFFI surface lives here. Ported from imbib's Swift
//! `IdentifierExtractor` — see `tests/golden_parity.rs` for the corpus that
//! pins the behaviour.

use std::collections::HashMap;

// ── Single-value text scanners ───────────────────────────────────────────────

pub(crate) fn extract_doi_from_text_internal(text: String) -> Option<String> {
    impress_identifiers::extract_doi_from_text(text)
}

/// Extract the first DOI from free-form text (e.g. text scraped from a PDF).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_doi_from_text(text: String) -> Option<String> {
    extract_doi_from_text_internal(text)
}

pub(crate) fn extract_arxiv_from_text_internal(text: String) -> Option<String> {
    impress_identifiers::extract_arxiv_from_text(text)
}

/// Extract the first arXiv ID from free-form text, normalised for lookups.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_arxiv_from_text(text: String) -> Option<String> {
    extract_arxiv_from_text_internal(text)
}

pub(crate) fn extract_bibcode_from_text_internal(text: String) -> Option<String> {
    impress_identifiers::extract_bibcode_from_text(text)
}

/// Extract the first ADS bibcode from free-form text.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_bibcode_from_text(text: String) -> Option<String> {
    extract_bibcode_from_text_internal(text)
}

pub(crate) fn extract_pmid_from_text_internal(text: String) -> Option<String> {
    impress_identifiers::extract_pmid_from_text(text)
}

/// Extract the first PubMed ID from free-form text.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_pmid_from_text(text: String) -> Option<String> {
    extract_pmid_from_text_internal(text)
}

// ── BibTeX field maps ────────────────────────────────────────────────────────

pub(crate) fn arxiv_id_from_fields_internal(fields: HashMap<String, String>) -> Option<String> {
    impress_identifiers::arxiv_id_from_fields(fields)
}

/// Extract the arXiv ID from BibTeX fields (`eprint` → `arxivid` → `arxiv`).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn arxiv_id_from_fields(fields: HashMap<String, String>) -> Option<String> {
    arxiv_id_from_fields_internal(fields)
}

pub(crate) fn doi_from_fields_internal(fields: HashMap<String, String>) -> Option<String> {
    impress_identifiers::doi_from_fields(fields)
}

/// Extract the DOI from BibTeX fields.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn doi_from_fields(fields: HashMap<String, String>) -> Option<String> {
    doi_from_fields_internal(fields)
}

pub(crate) fn bibcode_from_fields_internal(fields: HashMap<String, String>) -> Option<String> {
    impress_identifiers::bibcode_from_fields(fields)
}

/// Extract the ADS bibcode from BibTeX fields (`bibcode`, else `adsurl`).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn bibcode_from_fields(fields: HashMap<String, String>) -> Option<String> {
    bibcode_from_fields_internal(fields)
}

pub(crate) fn pmid_from_fields_internal(fields: HashMap<String, String>) -> Option<String> {
    impress_identifiers::pmid_from_fields(fields)
}

/// Extract the PubMed ID from BibTeX fields.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn pmid_from_fields(fields: HashMap<String, String>) -> Option<String> {
    pmid_from_fields_internal(fields)
}

pub(crate) fn pmcid_from_fields_internal(fields: HashMap<String, String>) -> Option<String> {
    impress_identifiers::pmcid_from_fields(fields)
}

/// Extract the PubMed Central ID from BibTeX fields.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn pmcid_from_fields(fields: HashMap<String, String>) -> Option<String> {
    pmcid_from_fields_internal(fields)
}

pub(crate) fn all_identifiers_from_fields_internal(
    fields: HashMap<String, String>,
) -> HashMap<String, String> {
    impress_identifiers::all_identifiers_from_fields(fields)
}

/// Extract every supported identifier from BibTeX fields in one FFI call.
///
/// Keys are identifier-type names: `doi`, `arxiv`, `bibcode`, `pmid`, `pmcid`.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn all_identifiers_from_fields(fields: HashMap<String, String>) -> HashMap<String, String> {
    all_identifiers_from_fields_internal(fields)
}

pub(crate) fn bibcode_from_ads_url_internal(url: String) -> Option<String> {
    impress_identifiers::bibcode_from_ads_url(url)
}

/// Extract an ADS bibcode from an ADS abstract URL.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn bibcode_from_ads_url(url: String) -> Option<String> {
    bibcode_from_ads_url_internal(url)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_scanners_delegate() {
        assert_eq!(
            extract_doi_from_text_internal("See doi:10.1038/nature12373.".to_string()),
            Some("10.1038/nature12373".to_string())
        );
        assert_eq!(
            extract_arxiv_from_text_internal("Preprint 2401.12345v2".to_string()),
            Some("2401.12345".to_string())
        );
        assert_eq!(
            extract_bibcode_from_text_internal("Bibcode 2023ApJ...123..456A here".to_string()),
            Some("2023ApJ...123..456A".to_string())
        );
        assert_eq!(
            extract_pmid_from_text_internal("PMID: 12345678".to_string()),
            Some("12345678".to_string())
        );
    }

    #[test]
    fn field_extraction_delegates() {
        let fields: HashMap<String, String> = [
            ("eprint".to_string(), "arXiv:2401.12345".to_string()),
            ("doi".to_string(), "10.1038/nature12373".to_string()),
        ]
        .into_iter()
        .collect();

        assert_eq!(
            arxiv_id_from_fields_internal(fields.clone()),
            Some("2401.12345".to_string())
        );
        assert_eq!(all_identifiers_from_fields_internal(fields).len(), 2);
    }
}
