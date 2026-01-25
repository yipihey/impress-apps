//! NASA ADS (Astrophysics Data System) source plugin
//!
//! API docs: https://ui.adsabs.harvard.edu/help/api/
//! Rate limit: 5000 requests/day, 5 requests/second burst

use super::traits::{SourceError, SourceMetadata};
use crate::domain::{Author, Identifiers, PdfLink, PdfLinkType, SearchResult, Source};
use serde::Deserialize;

/// ADS API response wrapper
#[derive(Debug, Deserialize)]
struct ADSResponse {
    response: ADSResponseBody,
}

#[derive(Debug, Deserialize)]
struct ADSResponseBody {
    docs: Vec<ADSDocument>,
    #[serde(rename = "numFound")]
    #[allow(dead_code)]
    num_found: Option<u32>,
}

/// Custom deserializer for year field that accepts both string and integer
fn deserialize_year_option<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::{self, Visitor};
    use std::fmt;

    struct YearVisitor;

    impl<'de> Visitor<'de> for YearVisitor {
        type Value = Option<String>;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("a string, integer, or null")
        }

        fn visit_none<E>(self) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(None)
        }

        fn visit_unit<E>(self) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(None)
        }

        fn visit_some<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
        where
            D: serde::Deserializer<'de>,
        {
            deserializer.deserialize_any(YearValueVisitor).map(Some)
        }
    }

    struct YearValueVisitor;

    impl<'de> Visitor<'de> for YearValueVisitor {
        type Value = String;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("a string or integer")
        }

        fn visit_str<E>(self, v: &str) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(v.to_string())
        }

        fn visit_string<E>(self, v: String) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(v)
        }

        fn visit_i64<E>(self, v: i64) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(v.to_string())
        }

        fn visit_u64<E>(self, v: u64) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(v.to_string())
        }
    }

    deserializer.deserialize_option(YearVisitor)
}

/// Single document from ADS search results
#[derive(Debug, Deserialize)]
struct ADSDocument {
    bibcode: String,
    title: Option<Vec<String>>,
    author: Option<Vec<String>>,
    #[serde(deserialize_with = "deserialize_year_option", default)]
    year: Option<String>,
    #[serde(rename = "pub")]
    publication: Option<String>,
    #[serde(rename = "abstract")]
    abstract_text: Option<String>,
    doi: Option<Vec<String>>,
    identifier: Option<Vec<String>>,
    #[allow(dead_code)]
    doctype: Option<String>,
    esources: Option<Vec<String>>,
    citation_count: Option<i32>,
    #[serde(rename = "reference")]
    references: Option<Vec<String>>,
    property: Option<Vec<String>>,
}

/// ADS BibTeX export response
#[derive(Debug, Deserialize)]
struct ADSExportResponse {
    export: String,
}

/// Paper stub for references/citations
#[derive(uniffi::Record, Clone, Debug)]
pub struct PaperStub {
    pub id: String,
    pub title: String,
    pub authors: Vec<String>,
    pub year: Option<i32>,
    pub venue: Option<String>,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub citation_count: Option<i32>,
    pub reference_count: Option<i32>,
    pub is_open_access: bool,
    pub abstract_text: Option<String>,
}

#[cfg(feature = "native")]
use crate::http::HttpClient;

#[allow(dead_code)]
pub struct ADSSource {
    #[cfg(feature = "native")]
    client: HttpClient,
    base_url: String,
}

impl ADSSource {
    pub fn new() -> Self {
        Self {
            #[cfg(feature = "native")]
            client: HttpClient::new("imbib/1.0 (https://imbib.app)"),
            base_url: "https://api.adsabs.harvard.edu/v1".to_string(),
        }
    }

    pub fn metadata() -> SourceMetadata {
        SourceMetadata {
            id: "ads",
            name: "NASA ADS",
            description: "Astrophysics Data System for astronomy and physics",
            base_url: "https://ui.adsabs.harvard.edu",
            rate_limit_per_second: 5.0,
            supports_bibtex: true,
            supports_ris: true,
            requires_api_key: true,
        }
    }

    /// Parse ADS JSON response to SearchResults
    pub fn parse_search_response(json: &str) -> Result<Vec<SearchResult>, SourceError> {
        let response: ADSResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid ADS JSON: {}", e)))?;

        Ok(response
            .response
            .docs
            .into_iter()
            .filter_map(Self::parse_document)
            .collect())
    }

    /// Parse single ADS document to SearchResult
    fn parse_document(doc: ADSDocument) -> Option<SearchResult> {
        let bibcode = doc.bibcode;
        let title = doc
            .title
            .and_then(|t| t.into_iter().next())
            .unwrap_or_default();

        if title.is_empty() {
            return None;
        }

        let authors: Vec<Author> = doc
            .author
            .unwrap_or_default()
            .into_iter()
            .map(|name| parse_ads_author(&name))
            .collect();

        let year = doc.year.as_ref().and_then(|y| y.parse().ok());

        let doi = doc.doi.and_then(|d| d.into_iter().next());
        let arxiv_id = extract_arxiv_id_from_identifiers(&doc.identifier);

        let pdf_links = build_pdf_links(
            &doc.esources.unwrap_or_default(),
            doi.as_deref(),
            arxiv_id.as_deref(),
            &bibcode,
        );

        Some(SearchResult {
            source_id: bibcode.clone(),
            source: Source::ADS,
            title,
            authors,
            year,
            identifiers: Identifiers {
                doi,
                arxiv_id,
                bibcode: Some(bibcode.clone()),
                ..Default::default()
            },
            abstract_text: doc.abstract_text,
            journal: doc.publication,
            volume: None,
            pages: None,
            pdf_links,
            bibtex: None,
            url: Some(format!("https://ui.adsabs.harvard.edu/abs/{}", bibcode)),
            citation_count: doc.citation_count,
        })
    }

    /// Parse references/citations response to PaperStubs
    pub fn parse_paper_stubs_response(json: &str) -> Result<Vec<PaperStub>, SourceError> {
        let response: ADSResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid ADS JSON: {}", e)))?;

        Ok(response
            .response
            .docs
            .into_iter()
            .filter_map(Self::parse_paper_stub)
            .collect())
    }

    fn parse_paper_stub(doc: ADSDocument) -> Option<PaperStub> {
        let title = doc
            .title
            .and_then(|t| t.into_iter().next())
            .unwrap_or_default();
        if title.is_empty() {
            return None;
        }

        let year = doc.year.as_ref().and_then(|y| y.parse().ok());
        let doi = doc.doi.and_then(|d| d.into_iter().next());
        let arxiv_id = extract_arxiv_id_from_identifiers(&doc.identifier);

        let properties = doc.property.unwrap_or_default();
        let is_open_access = properties
            .iter()
            .any(|p| p == "OPENACCESS" || p == "EPRINT_OPENACCESS");

        Some(PaperStub {
            id: doc.bibcode,
            title,
            authors: doc.author.unwrap_or_default(),
            year,
            venue: doc.publication,
            doi,
            arxiv_id,
            citation_count: doc.citation_count,
            reference_count: doc.references.map(|r| r.len() as i32),
            is_open_access,
            abstract_text: doc.abstract_text,
        })
    }

    /// Parse BibTeX export response
    pub fn parse_bibtex_export(json: &str) -> Result<String, SourceError> {
        let response: ADSExportResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid export response: {}", e)))?;
        Ok(response.export)
    }
}

impl Default for ADSSource {
    fn default() -> Self {
        Self::new()
    }
}

/// Parse ADS author format "Last, First M." to Author struct
fn parse_ads_author(name: &str) -> Author {
    let parts: Vec<&str> = name.splitn(2, ',').collect();
    if parts.len() == 2 {
        Author {
            id: uuid::Uuid::new_v4().to_string(),
            family_name: parts[0].trim().to_string(),
            given_name: Some(parts[1].trim().to_string()),
            suffix: None,
            orcid: None,
            affiliation: None,
        }
    } else {
        // No comma, try to extract last word as family name
        let words: Vec<&str> = name.split_whitespace().collect();
        if words.len() > 1 {
            Author {
                id: uuid::Uuid::new_v4().to_string(),
                family_name: words.last().unwrap().to_string(),
                given_name: Some(words[..words.len() - 1].join(" ")),
                suffix: None,
                orcid: None,
                affiliation: None,
            }
        } else {
            Author::new(name.to_string())
        }
    }
}

/// Extract arXiv ID from ADS identifier array
fn extract_arxiv_id_from_identifiers(identifiers: &Option<Vec<String>>) -> Option<String> {
    identifiers.as_ref()?.iter().find_map(|id| {
        if let Some(stripped) = id.strip_prefix("arXiv:") {
            Some(stripped.to_string())
        } else if id.chars().next()?.is_ascii_digit() && id.contains('.') {
            // New format: 2301.12345
            Some(id.clone())
        } else {
            None
        }
    })
}

/// Build PDF links from ADS esources field
///
/// Priority:
/// 1. Direct arXiv PDF for preprints
/// 2. DOI resolver for publisher
/// 3. ADS scans for historical papers
///
/// Note: We avoid ADS link_gateway URLs as they're unreliable
pub fn build_pdf_links(
    esources: &[String],
    doi: Option<&str>,
    arxiv_id: Option<&str>,
    bibcode: &str,
) -> Vec<PdfLink> {
    let mut links = Vec::new();
    let mut has_preprint = false;
    let mut has_publisher = false;

    for esource in esources {
        let upper = esource.to_uppercase();

        if upper == "EPRINT_PDF" {
            if let Some(arxiv) = arxiv_id {
                links.push(PdfLink {
                    url: format!("https://arxiv.org/pdf/{}.pdf", arxiv),
                    link_type: PdfLinkType::ArXiv,
                    description: Some("arXiv PDF".to_string()),
                });
                has_preprint = true;
            }
        } else if upper == "PUB_PDF" || upper == "PUB_HTML" {
            if let Some(d) = doi {
                if !d.is_empty() {
                    links.push(PdfLink {
                        url: format!("https://doi.org/{}", d),
                        link_type: PdfLinkType::Publisher,
                        description: Some("Publisher".to_string()),
                    });
                    has_publisher = true;
                }
            }
        } else if upper == "ADS_PDF" || upper == "ADS_SCAN" {
            links.push(PdfLink {
                url: format!("https://articles.adsabs.harvard.edu/pdf/{}", bibcode),
                link_type: PdfLinkType::Direct,
                description: Some("ADS Scan".to_string()),
            });
        }
    }

    // Add fallback links if not already present
    if !has_preprint {
        if let Some(arxiv) = arxiv_id {
            links.push(PdfLink {
                url: format!("https://arxiv.org/pdf/{}.pdf", arxiv),
                link_type: PdfLinkType::ArXiv,
                description: Some("arXiv PDF".to_string()),
            });
        }
    }

    if !has_publisher {
        if let Some(d) = doi {
            if !d.is_empty() {
                links.push(PdfLink {
                    url: format!("https://doi.org/{}", d),
                    link_type: PdfLinkType::Publisher,
                    description: Some("Publisher".to_string()),
                });
            }
        }
    }

    links
}

/// Parse ADS search response JSON (exported for FFI)
#[uniffi::export]
pub fn parse_ads_search_response(
    json: String,
) -> Result<Vec<SearchResult>, crate::error::FfiError> {
    ADSSource::parse_search_response(&json).map_err(|e| crate::error::FfiError::ParseError {
        message: format!("{:?}", e),
    })
}

/// Parse ADS paper stubs response JSON (exported for FFI)
#[uniffi::export]
pub fn parse_ads_paper_stubs_response(
    json: String,
) -> Result<Vec<PaperStub>, crate::error::FfiError> {
    ADSSource::parse_paper_stubs_response(&json).map_err(|e| crate::error::FfiError::ParseError {
        message: format!("{:?}", e),
    })
}

/// Parse ADS BibTeX export response JSON (exported for FFI)
#[uniffi::export]
pub fn parse_ads_bibtex_export(json: String) -> Result<String, crate::error::FfiError> {
    ADSSource::parse_bibtex_export(&json).map_err(|e| crate::error::FfiError::ParseError {
        message: format!("{:?}", e),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_RESPONSE: &str = r#"{
        "response": {
            "docs": [{
                "bibcode": "2023ApJ...123..456A",
                "title": ["A Great Paper About Stars"],
                "author": ["Author, First", "Researcher, Second"],
                "year": "2023",
                "pub": "The Astrophysical Journal",
                "doi": ["10.3847/1234-5678"],
                "identifier": ["arXiv:2301.12345"],
                "esources": ["EPRINT_PDF", "PUB_PDF"]
            }],
            "numFound": 1
        }
    }"#;

    #[test]
    fn test_parse_search_response() {
        let results = ADSSource::parse_search_response(SAMPLE_RESPONSE).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "A Great Paper About Stars");
        assert_eq!(results[0].authors.len(), 2);
        assert_eq!(results[0].year, Some(2023));
    }

    #[test]
    fn test_build_pdf_links() {
        let esources = vec!["EPRINT_PDF".to_string(), "PUB_PDF".to_string()];
        let links = build_pdf_links(
            &esources,
            Some("10.1234/test"),
            Some("2301.12345"),
            "2023ApJ...",
        );

        assert!(links.iter().any(|l| l.url.contains("arxiv.org")));
        assert!(links.iter().any(|l| l.url.contains("doi.org")));
    }

    #[test]
    fn test_parse_ads_author() {
        let author = parse_ads_author("Einstein, Albert");
        assert_eq!(author.family_name, "Einstein");
        assert_eq!(author.given_name, Some("Albert".to_string()));
    }

    #[test]
    fn test_extract_arxiv_id() {
        let ids = Some(vec!["arXiv:2301.12345".to_string()]);
        assert_eq!(
            extract_arxiv_id_from_identifiers(&ids),
            Some("2301.12345".to_string())
        );

        let ids2 = Some(vec!["2301.12345".to_string()]);
        assert_eq!(
            extract_arxiv_id_from_identifiers(&ids2),
            Some("2301.12345".to_string())
        );
    }

    #[test]
    fn test_parse_search_response_with_year_as_int() {
        // ADS API can return year as integer instead of string
        let json = r#"{
            "response": {
                "docs": [{
                    "bibcode": "2024ApJ...999..001B",
                    "title": ["Paper with Integer Year"],
                    "author": ["Author, Test"],
                    "year": 2024,
                    "pub": "The Astrophysical Journal"
                }],
                "numFound": 1
            }
        }"#;

        let results = ADSSource::parse_search_response(json).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "Paper with Integer Year");
        assert_eq!(results[0].year, Some(2024));
    }
}
