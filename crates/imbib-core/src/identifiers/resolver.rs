//! Identifier resolution across enrichment sources
//!
//! Maps identifiers between different systems (DOI→S2, arXiv→DOI)
//! and determines which identifiers can be used with which sources.

use std::collections::HashMap;

/// Types of publication identifiers across different sources
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum IdentifierType {
    /// Digital Object Identifier
    Doi,
    /// arXiv preprint identifier
    Arxiv,
    /// PubMed identifier
    Pmid,
    /// PubMed Central identifier
    Pmcid,
    /// NASA ADS bibcode
    Bibcode,
    /// Semantic Scholar paper ID
    SemanticScholar,
    /// OpenAlex work ID
    OpenAlex,
    /// DBLP record key
    Dblp,
}

impl IdentifierType {
    /// Get all identifier types
    pub fn all() -> &'static [IdentifierType] {
        &[
            IdentifierType::Doi,
            IdentifierType::Arxiv,
            IdentifierType::Pmid,
            IdentifierType::Pmcid,
            IdentifierType::Bibcode,
            IdentifierType::SemanticScholar,
            IdentifierType::OpenAlex,
            IdentifierType::Dblp,
        ]
    }
}

/// Sources that can provide enrichment data
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum EnrichmentSource {
    /// NASA Astrophysics Data System
    Ads,
    /// Semantic Scholar
    SemanticScholar,
    /// OpenAlex
    OpenAlex,
    /// Crossref
    Crossref,
    /// arXiv
    Arxiv,
    /// PubMed
    Pubmed,
    /// DBLP
    Dblp,
}

pub(crate) fn identifier_url_prefix_internal(id_type: IdentifierType) -> Option<String> {
    match id_type {
        IdentifierType::Doi => Some("https://doi.org/".to_string()),
        IdentifierType::Arxiv => Some("https://arxiv.org/abs/".to_string()),
        IdentifierType::Pmid => Some("https://pubmed.ncbi.nlm.nih.gov/".to_string()),
        IdentifierType::Pmcid => Some("https://www.ncbi.nlm.nih.gov/pmc/articles/".to_string()),
        IdentifierType::Bibcode => Some("https://ui.adsabs.harvard.edu/abs/".to_string()),
        IdentifierType::SemanticScholar => {
            Some("https://www.semanticscholar.org/paper/".to_string())
        }
        IdentifierType::OpenAlex => Some("https://openalex.org/works/".to_string()),
        IdentifierType::Dblp => Some("https://dblp.org/rec/".to_string()),
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn identifier_url_prefix(id_type: IdentifierType) -> Option<String> {
    identifier_url_prefix_internal(id_type)
}

pub(crate) fn identifier_url_internal(id_type: IdentifierType, value: String) -> Option<String> {
    identifier_url_prefix(id_type).map(|prefix| format!("{}{}", prefix, value))
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn identifier_url(id_type: IdentifierType, value: String) -> Option<String> {
    identifier_url_internal(id_type, value)
}

pub(crate) fn identifier_display_name_internal(id_type: IdentifierType) -> String {
    match id_type {
        IdentifierType::Doi => "DOI".to_string(),
        IdentifierType::Arxiv => "arXiv".to_string(),
        IdentifierType::Pmid => "PubMed".to_string(),
        IdentifierType::Pmcid => "PMC".to_string(),
        IdentifierType::Bibcode => "ADS Bibcode".to_string(),
        IdentifierType::SemanticScholar => "Semantic Scholar".to_string(),
        IdentifierType::OpenAlex => "OpenAlex".to_string(),
        IdentifierType::Dblp => "DBLP".to_string(),
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn identifier_display_name(id_type: IdentifierType) -> String {
    identifier_display_name_internal(id_type)
}

pub(crate) fn enrichment_source_display_name_internal(source: EnrichmentSource) -> String {
    match source {
        EnrichmentSource::Ads => "NASA ADS".to_string(),
        EnrichmentSource::SemanticScholar => "Semantic Scholar".to_string(),
        EnrichmentSource::OpenAlex => "OpenAlex".to_string(),
        EnrichmentSource::Crossref => "Crossref".to_string(),
        EnrichmentSource::Arxiv => "arXiv".to_string(),
        EnrichmentSource::Pubmed => "PubMed".to_string(),
        EnrichmentSource::Dblp => "DBLP".to_string(),
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn enrichment_source_display_name(source: EnrichmentSource) -> String {
    enrichment_source_display_name_internal(source)
}

pub(crate) fn can_resolve_to_source_internal(
    identifiers: HashMap<String, String>,
    source: EnrichmentSource,
) -> bool {
    match source {
        EnrichmentSource::Ads => {
            // ADS accepts bibcode, DOI, or arXiv
            identifiers.contains_key("bibcode")
                || identifiers.contains_key("doi")
                || identifiers.contains_key("arxiv")
        }
        EnrichmentSource::SemanticScholar => {
            // S2 accepts DOI, arXiv, PubMed, or its own ID
            identifiers.contains_key("doi")
                || identifiers.contains_key("arxiv")
                || identifiers.contains_key("pmid")
                || identifiers.contains_key("semanticscholar")
        }
        EnrichmentSource::OpenAlex => {
            // OpenAlex accepts DOI or its own ID
            identifiers.contains_key("doi") || identifiers.contains_key("openalex")
        }
        EnrichmentSource::Crossref => {
            // Crossref only accepts DOI
            identifiers.contains_key("doi")
        }
        EnrichmentSource::Arxiv => {
            // arXiv accepts arXiv ID
            identifiers.contains_key("arxiv")
        }
        EnrichmentSource::Pubmed => {
            // PubMed accepts PMID, PMCID, or DOI
            identifiers.contains_key("pmid")
                || identifiers.contains_key("pmcid")
                || identifiers.contains_key("doi")
        }
        EnrichmentSource::Dblp => {
            // DBLP accepts its own ID or DOI
            identifiers.contains_key("dblp") || identifiers.contains_key("doi")
        }
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn can_resolve_to_source(
    identifiers: HashMap<String, String>,
    source: EnrichmentSource,
) -> bool {
    can_resolve_to_source_internal(identifiers, source)
}

/// Preferred identifier result containing type and value
#[derive(Debug, Clone, uniffi::Record)]
pub struct PreferredIdentifier {
    /// The identifier type (as string, e.g., "doi", "arxiv")
    pub id_type: String,
    /// The identifier value
    pub value: String,
}

pub(crate) fn preferred_identifier_for_source_internal(
    identifiers: HashMap<String, String>,
    source: EnrichmentSource,
) -> Option<PreferredIdentifier> {
    let priority_order: &[&str] = match source {
        EnrichmentSource::Ads => {
            // ADS prefers bibcode, then DOI, then arXiv
            &["bibcode", "doi", "arxiv"]
        }
        EnrichmentSource::SemanticScholar => {
            // S2 prefers its own ID, then DOI, arXiv, PMID
            &["semanticscholar", "doi", "arxiv", "pmid"]
        }
        EnrichmentSource::OpenAlex => {
            // OpenAlex prefers its own ID, then DOI
            &["openalex", "doi"]
        }
        EnrichmentSource::Crossref => {
            // Crossref only uses DOI
            &["doi"]
        }
        EnrichmentSource::Arxiv => {
            // arXiv only uses arXiv ID
            &["arxiv"]
        }
        EnrichmentSource::Pubmed => {
            // PubMed prefers PMID, then PMCID, then DOI
            &["pmid", "pmcid", "doi"]
        }
        EnrichmentSource::Dblp => {
            // DBLP prefers its own ID, then DOI
            &["dblp", "doi"]
        }
    };

    for &id_type in priority_order {
        if let Some(value) = identifiers.get(id_type) {
            return Some(PreferredIdentifier {
                id_type: id_type.to_string(),
                value: value.clone(),
            });
        }
    }

    None
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn preferred_identifier_for_source(
    identifiers: HashMap<String, String>,
    source: EnrichmentSource,
) -> Option<PreferredIdentifier> {
    preferred_identifier_for_source_internal(identifiers, source)
}

pub(crate) fn resolve_doi_to_semantic_scholar_internal(doi: String) -> String {
    format!("DOI:{}", doi)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn resolve_doi_to_semantic_scholar(doi: String) -> String {
    resolve_doi_to_semantic_scholar_internal(doi)
}

pub(crate) fn resolve_arxiv_to_semantic_scholar_internal(arxiv_id: String) -> String {
    format!("ARXIV:{}", arxiv_id)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn resolve_arxiv_to_semantic_scholar(arxiv_id: String) -> String {
    resolve_arxiv_to_semantic_scholar_internal(arxiv_id)
}

pub(crate) fn resolve_pmid_to_semantic_scholar_internal(pmid: String) -> String {
    format!("PMID:{}", pmid)
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn resolve_pmid_to_semantic_scholar(pmid: String) -> String {
    resolve_pmid_to_semantic_scholar_internal(pmid)
}

pub(crate) fn supported_identifiers_for_source_internal(source: EnrichmentSource) -> Vec<String> {
    match source {
        EnrichmentSource::Ads => vec![
            "bibcode".to_string(),
            "doi".to_string(),
            "arxiv".to_string(),
        ],
        EnrichmentSource::SemanticScholar => vec![
            "semanticscholar".to_string(),
            "doi".to_string(),
            "arxiv".to_string(),
            "pmid".to_string(),
        ],
        EnrichmentSource::OpenAlex => vec!["openalex".to_string(), "doi".to_string()],
        EnrichmentSource::Crossref => vec!["doi".to_string()],
        EnrichmentSource::Arxiv => vec!["arxiv".to_string()],
        EnrichmentSource::Pubmed => {
            vec!["pmid".to_string(), "pmcid".to_string(), "doi".to_string()]
        }
        EnrichmentSource::Dblp => vec!["dblp".to_string(), "doi".to_string()],
    }
}

#[cfg(feature = "native")]
#[uniffi::export]
pub fn supported_identifiers_for_source(source: EnrichmentSource) -> Vec<String> {
    supported_identifiers_for_source_internal(source)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_identifier_url_prefix() {
        assert_eq!(
            identifier_url_prefix(IdentifierType::Doi),
            Some("https://doi.org/".to_string())
        );
        assert_eq!(
            identifier_url_prefix(IdentifierType::Arxiv),
            Some("https://arxiv.org/abs/".to_string())
        );
        assert_eq!(
            identifier_url_prefix(IdentifierType::Bibcode),
            Some("https://ui.adsabs.harvard.edu/abs/".to_string())
        );
    }

    #[test]
    fn test_identifier_url() {
        assert_eq!(
            identifier_url(IdentifierType::Doi, "10.1234/test".to_string()),
            Some("https://doi.org/10.1234/test".to_string())
        );
        assert_eq!(
            identifier_url(IdentifierType::Arxiv, "2301.12345".to_string()),
            Some("https://arxiv.org/abs/2301.12345".to_string())
        );
    }

    #[test]
    fn test_can_resolve_to_ads() {
        let mut ids = HashMap::new();
        ids.insert("bibcode".to_string(), "2020ApJ...123...45A".to_string());
        assert!(can_resolve_to_source(ids.clone(), EnrichmentSource::Ads));

        ids.clear();
        ids.insert("doi".to_string(), "10.1234/test".to_string());
        assert!(can_resolve_to_source(ids.clone(), EnrichmentSource::Ads));

        ids.clear();
        ids.insert("arxiv".to_string(), "2301.12345".to_string());
        assert!(can_resolve_to_source(ids.clone(), EnrichmentSource::Ads));

        ids.clear();
        ids.insert("semanticscholar".to_string(), "abc123".to_string());
        assert!(!can_resolve_to_source(ids, EnrichmentSource::Ads));
    }

    #[test]
    fn test_can_resolve_to_semantic_scholar() {
        let mut ids = HashMap::new();
        ids.insert("doi".to_string(), "10.1234/test".to_string());
        assert!(can_resolve_to_source(
            ids.clone(),
            EnrichmentSource::SemanticScholar
        ));

        ids.clear();
        ids.insert("arxiv".to_string(), "2301.12345".to_string());
        assert!(can_resolve_to_source(
            ids.clone(),
            EnrichmentSource::SemanticScholar
        ));

        ids.clear();
        ids.insert("pmid".to_string(), "12345678".to_string());
        assert!(can_resolve_to_source(
            ids,
            EnrichmentSource::SemanticScholar
        ));
    }

    #[test]
    fn test_preferred_identifier_for_ads() {
        // Bibcode is most preferred
        let mut ids = HashMap::new();
        ids.insert("bibcode".to_string(), "2020ApJ...123...45A".to_string());
        ids.insert("doi".to_string(), "10.1234/test".to_string());

        let result = preferred_identifier_for_source(ids, EnrichmentSource::Ads);
        assert!(result.is_some());
        assert_eq!(result.unwrap().id_type, "bibcode");

        // DOI is second choice
        let mut ids = HashMap::new();
        ids.insert("doi".to_string(), "10.1234/test".to_string());
        ids.insert("arxiv".to_string(), "2301.12345".to_string());

        let result = preferred_identifier_for_source(ids, EnrichmentSource::Ads);
        assert!(result.is_some());
        assert_eq!(result.unwrap().id_type, "doi");

        // arXiv is third choice
        let mut ids = HashMap::new();
        ids.insert("arxiv".to_string(), "2301.12345".to_string());

        let result = preferred_identifier_for_source(ids, EnrichmentSource::Ads);
        assert!(result.is_some());
        assert_eq!(result.unwrap().id_type, "arxiv");
    }

    #[test]
    fn test_preferred_identifier_none() {
        let ids = HashMap::new();
        let result = preferred_identifier_for_source(ids, EnrichmentSource::Ads);
        assert!(result.is_none());
    }

    #[test]
    fn test_resolve_to_semantic_scholar() {
        assert_eq!(
            resolve_doi_to_semantic_scholar("10.1234/test".to_string()),
            "DOI:10.1234/test"
        );
        assert_eq!(
            resolve_arxiv_to_semantic_scholar("2301.12345".to_string()),
            "ARXIV:2301.12345"
        );
        assert_eq!(
            resolve_pmid_to_semantic_scholar("12345678".to_string()),
            "PMID:12345678"
        );
    }

    #[test]
    fn test_supported_identifiers() {
        let ads_ids = supported_identifiers_for_source(EnrichmentSource::Ads);
        assert!(ads_ids.contains(&"bibcode".to_string()));
        assert!(ads_ids.contains(&"doi".to_string()));
        assert!(ads_ids.contains(&"arxiv".to_string()));

        let crossref_ids = supported_identifiers_for_source(EnrichmentSource::Crossref);
        assert_eq!(crossref_ids.len(), 1);
        assert!(crossref_ids.contains(&"doi".to_string()));
    }
}
