//! Identifier extraction from text — delegates to the canonical
//! `impress_identifiers` (→ `im-identifiers`) crate.
//!
//! Local type definitions are kept for UniFFI compatibility; all extraction
//! logic lives in `im-identifiers`. This used to be a verbatim copy of that
//! crate's regexes, which is exactly the "two definitions of the same
//! capability" shape CLAUDE.md warns about — the copy is gone.

/// Extracted identifier with position information
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ExtractedIdentifier {
    pub identifier_type: String,
    pub value: String,
    pub start_index: u32,
    pub end_index: u32,
}

impl From<impress_identifiers::ExtractedIdentifier> for ExtractedIdentifier {
    fn from(value: impress_identifiers::ExtractedIdentifier) -> Self {
        Self {
            identifier_type: value.identifier_type,
            value: value.value,
            start_index: value.start_index,
            end_index: value.end_index,
        }
    }
}

pub(crate) fn extract_dois_internal(text: String) -> Vec<String> {
    impress_identifiers::extract_dois(text)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_dois(text: String) -> Vec<String> {
    extract_dois_internal(text)
}

pub(crate) fn extract_arxiv_ids_internal(text: String) -> Vec<String> {
    impress_identifiers::extract_arxiv_ids(text)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_arxiv_ids(text: String) -> Vec<String> {
    extract_arxiv_ids_internal(text)
}

pub(crate) fn extract_isbns_internal(text: String) -> Vec<String> {
    impress_identifiers::extract_isbns(text)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_isbns(text: String) -> Vec<String> {
    extract_isbns_internal(text)
}

pub(crate) fn extract_all_internal(text: String) -> Vec<ExtractedIdentifier> {
    impress_identifiers::extract_all(text)
        .into_iter()
        .map(Into::into)
        .collect()
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_all(text: String) -> Vec<ExtractedIdentifier> {
    extract_all_internal(text)
}

/// Result of batch identifier extraction for a single text
#[derive(Debug, Clone, uniffi::Record)]
pub struct ExtractedIdentifiers {
    /// DOIs found in the text
    pub dois: Vec<String>,
    /// arXiv IDs found in the text
    pub arxiv_ids: Vec<String>,
    /// ISBNs found in the text
    pub isbns: Vec<String>,
    /// All identifiers with position information
    pub all: Vec<ExtractedIdentifier>,
}

pub(crate) fn extract_all_identifiers_internal(text: &str) -> ExtractedIdentifiers {
    ExtractedIdentifiers {
        dois: extract_dois_internal(text.to_string()),
        arxiv_ids: extract_arxiv_ids_internal(text.to_string()),
        isbns: extract_isbns_internal(text.to_string()),
        all: extract_all_internal(text.to_string()),
    }
}

/// Extract all identifiers from a single text (convenience function).
///
/// Returns a struct with DOIs, arXiv IDs, ISBNs, and all identifiers.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_identifiers(text: String) -> ExtractedIdentifiers {
    extract_all_identifiers_internal(&text)
}

/// Extract all identifiers from multiple texts in a single FFI call.
///
/// This batch API reduces FFI overhead when processing multiple documents
/// (e.g., extracting identifiers from PDF text during bulk import).
///
/// Returns a vector of ExtractedIdentifiers, one per input text.
#[cfg(feature = "native")]
#[uniffi::export]
pub fn extract_all_identifiers_batch(texts: Vec<String>) -> Vec<ExtractedIdentifiers> {
    texts
        .iter()
        .map(|text| extract_all_identifiers_internal(text))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_dois() {
        let text = "Check out this paper: 10.1038/nature12373 and also doi:10.1126/science.1234567";
        let dois = extract_dois_internal(text.to_string());
        assert_eq!(dois.len(), 2);
        assert!(dois.contains(&"10.1038/nature12373".to_string()));
        assert!(dois.contains(&"10.1126/science.1234567".to_string()));
    }

    #[test]
    fn test_extract_dois_with_url() {
        let text = "See https://doi.org/10.1038/nature12373 for details";
        let dois = extract_dois_internal(text.to_string());
        assert_eq!(dois, vec!["10.1038/nature12373"]);
    }

    #[test]
    fn test_extract_arxiv_ids() {
        let text = "New paper: arXiv:2301.12345 and also 1905.07890v2";
        let ids = extract_arxiv_ids_internal(text.to_string());
        assert_eq!(ids.len(), 2);
        assert!(ids.contains(&"2301.12345".to_string()));
        assert!(ids.contains(&"1905.07890v2".to_string()));
    }

    #[test]
    fn test_extract_arxiv_old_format() {
        let text = "Classic paper: cond-mat/9901001";
        let ids = extract_arxiv_ids_internal(text.to_string());
        assert_eq!(ids, vec!["cond-mat/9901001"]);
    }

    #[test]
    fn test_extract_isbns() {
        let text = "ISBN: 978-0-321-12521-7 and also 0-306-40615-2";
        let isbns = extract_isbns_internal(text.to_string());
        assert_eq!(isbns.len(), 2);
        assert!(isbns.contains(&"9780321125217".to_string()));
        assert!(isbns.contains(&"0306406152".to_string()));
    }

    #[test]
    fn test_extract_all() {
        let text = "DOI: 10.1038/nature12373, arXiv: 2301.12345";
        let ids = extract_all_internal(text.to_string());
        assert_eq!(ids.len(), 2);
        assert_eq!(ids[0].identifier_type, "doi");
        assert_eq!(ids[1].identifier_type, "arxiv");
    }

    #[test]
    fn test_extract_identifiers() {
        let text = "DOI: 10.1038/nature12373, arXiv: 2301.12345, ISBN: 978-0-321-12521-7";
        let result = extract_all_identifiers_internal(text);
        assert_eq!(result.dois.len(), 1);
        assert_eq!(result.arxiv_ids.len(), 1);
        assert_eq!(result.isbns.len(), 1);
        assert_eq!(result.all.len(), 3);
    }

    #[test]
    fn test_extract_all_identifiers_batch() {
        let texts = [
            "Paper 1: 10.1038/nature12373",
            "Paper 2: arXiv:2301.12345",
            "Paper 3: ISBN 978-0-321-12521-7",
        ];
        let results: Vec<_> = texts
            .iter()
            .map(|t| extract_all_identifiers_internal(t))
            .collect();
        assert_eq!(results.len(), 3);
        assert_eq!(results[0].dois.len(), 1);
        assert_eq!(results[1].arxiv_ids.len(), 1);
        assert_eq!(results[2].isbns.len(), 1);
    }
}
