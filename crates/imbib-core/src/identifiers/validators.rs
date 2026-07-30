//! Identifier validation — delegates to the canonical `impress_identifiers`
//! (→ `im-identifiers`) crate. Only the UniFFI surface lives here; the regexes
//! and checksum maths used to be duplicated verbatim and are now single-sourced.

pub(crate) fn is_valid_doi_internal(doi: String) -> bool {
    impress_identifiers::is_valid_doi(doi)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_doi(doi: String) -> bool {
    is_valid_doi_internal(doi)
}

pub(crate) fn is_valid_arxiv_id_internal(arxiv_id: String) -> bool {
    impress_identifiers::is_valid_arxiv_id(arxiv_id)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_arxiv_id(arxiv_id: String) -> bool {
    is_valid_arxiv_id_internal(arxiv_id)
}

pub(crate) fn is_valid_arxiv_id_format_internal(value: String) -> bool {
    impress_identifiers::is_valid_arxiv_id_format(value)
}

/// Stricter shape check for a raw BibTeX `eprint` value.
///
/// Rejects bibcodes and DOIs that some sources put there; unlike
/// [`is_valid_arxiv_id`] it does not accept a dotted subject class.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_arxiv_id_format(value: String) -> bool {
    is_valid_arxiv_id_format_internal(value)
}

pub(crate) fn is_valid_isbn_internal(isbn: String) -> bool {
    impress_identifiers::is_valid_isbn(isbn)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn is_valid_isbn(isbn: String) -> bool {
    is_valid_isbn_internal(isbn)
}

pub(crate) fn normalize_doi_internal(doi: String) -> String {
    impress_identifiers::normalize_doi(doi)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn normalize_doi(doi: String) -> String {
    normalize_doi_internal(doi)
}

pub(crate) fn normalize_arxiv_id_internal(arxiv_id: String) -> String {
    impress_identifiers::normalize_arxiv_id(arxiv_id)
}

/// Normalise an arXiv ID for indexed lookups (drop `arXiv:` prefix and version
/// suffix, lowercase).
#[cfg(feature = "native")]
#[uniffi::export]
pub fn normalize_arxiv_id(arxiv_id: String) -> String {
    normalize_arxiv_id_internal(arxiv_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_valid_dois() {
        assert!(is_valid_doi_internal("10.1038/nature12373".to_string()));
        assert!(is_valid_doi_internal("10.1126/science.1234567".to_string()));
        assert!(is_valid_doi_internal("10.1000/182".to_string()));
    }

    #[test]
    fn test_invalid_dois() {
        assert!(!is_valid_doi_internal("11.1038/nature12373".to_string())); // Wrong prefix
        assert!(!is_valid_doi_internal("10.12/test".to_string())); // Registrant too short
        assert!(!is_valid_doi_internal("nature12373".to_string())); // Missing 10.
    }

    #[test]
    fn test_valid_arxiv_ids() {
        assert!(is_valid_arxiv_id_internal("2301.12345".to_string())); // New format
        assert!(is_valid_arxiv_id_internal("1905.07890v2".to_string())); // With version
        assert!(is_valid_arxiv_id_internal("cond-mat/9901001".to_string())); // Old format
        assert!(is_valid_arxiv_id_internal("hep-th/9901001v1".to_string())); // Old with version
    }

    #[test]
    fn test_invalid_arxiv_ids() {
        assert!(!is_valid_arxiv_id_internal("12345".to_string()));
        assert!(!is_valid_arxiv_id_internal("2301.123".to_string())); // Too short
    }

    #[test]
    fn test_valid_isbns() {
        assert!(is_valid_isbn_internal("0-306-40615-2".to_string())); // ISBN-10
        assert!(is_valid_isbn_internal("978-0-321-12521-7".to_string())); // ISBN-13
        assert!(is_valid_isbn_internal("0306406152".to_string())); // Without hyphens
        assert!(is_valid_isbn_internal("9780321125217".to_string())); // Without hyphens
        assert!(is_valid_isbn_internal("080442957X".to_string())); // ISBN-10 with X
    }

    #[test]
    fn test_invalid_isbns() {
        assert!(!is_valid_isbn_internal("0-306-40615-1".to_string())); // Bad checksum
        assert!(!is_valid_isbn_internal("978-0-321-12521-8".to_string())); // Bad checksum
        assert!(!is_valid_isbn_internal("12345".to_string())); // Too short
    }

    #[test]
    fn test_normalize_doi() {
        assert_eq!(
            normalize_doi_internal("https://doi.org/10.1038/nature12373".to_string()),
            "10.1038/nature12373"
        );
        assert_eq!(
            normalize_doi_internal("doi:10.1038/nature12373".to_string()),
            "10.1038/nature12373"
        );
        assert_eq!(
            normalize_doi_internal("10.1038/nature12373.".to_string()),
            "10.1038/nature12373"
        );
    }
}
