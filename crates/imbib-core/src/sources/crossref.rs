//! Crossref source plugin for DOI metadata
//!
//! API docs: https://api.crossref.org/swagger-ui/index.html
//! Rate limit: Polite pool with email header, ~50 req/sec

use super::traits::{SourceError, SourceMetadata};
use crate::domain::{Author, Identifiers, PdfLink, PdfLinkType, SearchResult, Source};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
struct CrossrefResponse {
    message: CrossrefMessage,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum CrossrefMessage {
    WorkList(CrossrefWorkList),
    Work(Box<CrossrefWork>),
}

#[derive(Debug, Deserialize)]
struct CrossrefWorkList {
    items: Vec<CrossrefWork>,
}

#[derive(Debug, Deserialize)]
struct CrossrefWork {
    #[serde(rename = "DOI")]
    doi: String,
    title: Option<Vec<String>>,
    author: Option<Vec<CrossrefAuthor>>,
    #[serde(rename = "container-title")]
    container_title: Option<Vec<String>>,
    #[serde(rename = "published-print")]
    published_print: Option<CrossrefDate>,
    #[serde(rename = "published-online")]
    published_online: Option<CrossrefDate>,
    volume: Option<String>,
    page: Option<String>,
    #[serde(rename = "abstract")]
    abstract_text: Option<String>,
    link: Option<Vec<CrossrefLink>>,
    #[serde(rename = "is-referenced-by-count")]
    citation_count: Option<i32>,
    #[serde(rename = "URL")]
    url: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CrossrefAuthor {
    given: Option<String>,
    family: Option<String>,
    #[serde(rename = "ORCID")]
    orcid: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CrossrefDate {
    #[serde(rename = "date-parts")]
    date_parts: Option<Vec<Vec<i32>>>,
}

#[derive(Debug, Deserialize)]
struct CrossrefLink {
    #[serde(rename = "URL")]
    url: String,
    #[serde(rename = "content-type")]
    content_type: Option<String>,
}

pub struct CrossrefSource;

impl CrossrefSource {
    pub fn metadata() -> SourceMetadata {
        SourceMetadata {
            id: "crossref",
            name: "Crossref",
            description: "DOI registration agency with metadata for scholarly works",
            base_url: "https://api.crossref.org",
            rate_limit_per_second: 50.0,
            supports_bibtex: false,
            supports_ris: false,
            requires_api_key: false,
        }
    }

    /// Parse Crossref search response
    pub fn parse_search_response(json: &str) -> Result<Vec<SearchResult>, SourceError> {
        let response: CrossrefResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid Crossref JSON: {}", e)))?;

        match response.message {
            CrossrefMessage::WorkList(list) => Ok(list
                .items
                .into_iter()
                .filter_map(Self::parse_work)
                .collect()),
            CrossrefMessage::Work(work) => Ok(Self::parse_work(*work).into_iter().collect()),
        }
    }

    /// Parse single work response (for DOI lookup)
    pub fn parse_work_response(json: &str) -> Result<SearchResult, SourceError> {
        let response: CrossrefResponse = serde_json::from_str(json)
            .map_err(|e| SourceError::Parse(format!("Invalid Crossref JSON: {}", e)))?;

        match response.message {
            CrossrefMessage::Work(work) => Self::parse_work(*work)
                .ok_or_else(|| SourceError::Parse("Could not parse work".to_string())),
            _ => Err(SourceError::Parse("Unexpected response format".to_string())),
        }
    }

    fn parse_work(work: CrossrefWork) -> Option<SearchResult> {
        let title = work.title.and_then(|t| t.into_iter().next())?;

        let authors: Vec<Author> = work
            .author
            .unwrap_or_default()
            .into_iter()
            .filter_map(|a| {
                let family = a.family?;
                Some(Author {
                    id: uuid::Uuid::new_v4().to_string(),
                    family_name: family,
                    given_name: a.given,
                    suffix: None,
                    orcid: a
                        .orcid
                        .map(|o| o.trim_start_matches("http://orcid.org/").to_string()),
                    affiliation: None,
                })
            })
            .collect();

        let year = work
            .published_print
            .or(work.published_online)
            .and_then(|d| d.date_parts)
            .and_then(|dp| dp.first().cloned())
            .and_then(|parts| parts.first().copied());

        let journal = work.container_title.and_then(|t| t.into_iter().next());

        // Build PDF links
        let mut pdf_links = Vec::new();
        if let Some(links) = work.link {
            for link in links {
                if link.content_type.as_deref() == Some("application/pdf") {
                    pdf_links.push(PdfLink {
                        url: link.url,
                        link_type: PdfLinkType::Publisher,
                        description: Some("Publisher PDF".to_string()),
                    });
                }
            }
        }
        // Always add DOI resolver as fallback
        pdf_links.push(PdfLink {
            url: format!("https://doi.org/{}", work.doi),
            link_type: PdfLinkType::Publisher,
            description: Some("DOI Link".to_string()),
        });

        // Clean abstract (Crossref often includes XML/JATS markup)
        let abstract_text = work.abstract_text.map(|a| strip_jats_markup(&a));

        Some(SearchResult {
            source_id: work.doi.clone(),
            source: Source::Crossref,
            title,
            authors,
            year,
            identifiers: Identifiers {
                doi: Some(work.doi),
                ..Default::default()
            },
            abstract_text,
            journal,
            volume: work.volume,
            pages: work.page,
            pdf_links,
            bibtex: None,
            url: work.url,
            citation_count: work.citation_count,
        })
    }
}

/// Strip JATS XML markup from Crossref abstracts
fn strip_jats_markup(text: &str) -> String {
    // Remove <jats:p>, <jats:italic>, etc.
    let re = regex::Regex::new(r"</?jats:[^>]+>").unwrap();
    let cleaned = re.replace_all(text, "");
    cleaned.trim().to_string()
}

/// Parse Crossref search response JSON (exported for FFI)
#[uniffi::export]
pub fn parse_crossref_search_response(
    json: String,
) -> Result<Vec<SearchResult>, crate::error::FfiError> {
    CrossrefSource::parse_search_response(&json).map_err(|e| crate::error::FfiError::ParseError {
        message: format!("{:?}", e),
    })
}

/// Parse Crossref single work response JSON (exported for FFI)
#[uniffi::export]
pub fn parse_crossref_work_response(json: String) -> Result<SearchResult, crate::error::FfiError> {
    CrossrefSource::parse_work_response(&json).map_err(|e| crate::error::FfiError::ParseError {
        message: format!("{:?}", e),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE_RESPONSE: &str = r#"{
        "message": {
            "items": [{
                "DOI": "10.1234/test",
                "title": ["A Test Paper"],
                "author": [{"given": "John", "family": "Smith"}],
                "container-title": ["Test Journal"],
                "published-print": {"date-parts": [[2023, 1, 15]]},
                "is-referenced-by-count": 42
            }]
        }
    }"#;

    #[test]
    fn test_parse_search_response() {
        let results = CrossrefSource::parse_search_response(SAMPLE_RESPONSE).unwrap();
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "A Test Paper");
        assert_eq!(results[0].identifiers.doi, Some("10.1234/test".to_string()));
        assert_eq!(results[0].citation_count, Some(42));
    }

    #[test]
    fn test_strip_jats_markup() {
        let input = "<jats:p>This is <jats:italic>italic</jats:italic> text.</jats:p>";
        let result = strip_jats_markup(input);
        assert_eq!(result, "This is italic text.");
    }
}
