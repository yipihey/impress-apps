//! Scientific publication identifiers

use serde::{Deserialize, Serialize};

/// Collection of publication identifiers
#[derive(uniffi::Record, Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Identifiers {
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub pmid: Option<String>,
    pub pmcid: Option<String>,
    pub bibcode: Option<String>,
    pub isbn: Option<String>,
    pub issn: Option<String>,
    pub orcid: Option<String>,
}

impl Identifiers {
    /// Check if all identifiers are empty
    pub fn is_empty(&self) -> bool {
        self.doi.is_none()
            && self.arxiv_id.is_none()
            && self.pmid.is_none()
            && self.pmcid.is_none()
            && self.bibcode.is_none()
            && self.isbn.is_none()
            && self.issn.is_none()
    }

    /// Returns the best identifier for deduplication (priority order)
    pub fn primary(&self) -> Option<(&'static str, &str)> {
        if let Some(ref doi) = self.doi {
            return Some(("doi", doi));
        }
        if let Some(ref arxiv) = self.arxiv_id {
            return Some(("arxiv", arxiv));
        }
        if let Some(ref bibcode) = self.bibcode {
            return Some(("bibcode", bibcode));
        }
        if let Some(ref pmid) = self.pmid {
            return Some(("pmid", pmid));
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_identifiers_is_empty() {
        let empty = Identifiers::default();
        assert!(empty.is_empty());

        let with_doi = Identifiers {
            doi: Some("10.1234/test".to_string()),
            ..Default::default()
        };
        assert!(!with_doi.is_empty());
    }

    #[test]
    fn test_identifiers_primary() {
        let with_doi = Identifiers {
            doi: Some("10.1234/test".to_string()),
            arxiv_id: Some("2024.12345".to_string()),
            ..Default::default()
        };
        assert_eq!(with_doi.primary(), Some(("doi", "10.1234/test")));

        let arxiv_only = Identifiers {
            arxiv_id: Some("2024.12345".to_string()),
            ..Default::default()
        };
        assert_eq!(arxiv_only.primary(), Some(("arxiv", "2024.12345")));
    }
}
