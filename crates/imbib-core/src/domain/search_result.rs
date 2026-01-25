//! Search result representation from online sources

use super::{Author, Identifiers};
use serde::{Deserialize, Serialize};

/// Online source for search results
#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum Source {
    ArXiv,
    Crossref,
    ADS,
    PubMed,
    OpenAlex,
    DBLP,
    SemanticScholar,
    SciX,
    Local,
    Manual,
}

impl Source {
    /// Get string representation
    pub fn as_str(&self) -> &'static str {
        match self {
            Source::ArXiv => "arxiv",
            Source::Crossref => "crossref",
            Source::ADS => "ads",
            Source::PubMed => "pubmed",
            Source::OpenAlex => "openalex",
            Source::DBLP => "dblp",
            Source::SemanticScholar => "semanticscholar",
            Source::SciX => "scix",
            Source::Local => "local",
            Source::Manual => "manual",
        }
    }
}

/// Type of PDF link
#[derive(uniffi::Enum, Clone, Debug, Serialize, Deserialize, PartialEq)]
pub enum PdfLinkType {
    Direct,
    Landing,
    ArXiv,
    Publisher,
    OpenAccess,
}

/// A link to a PDF
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct PdfLink {
    pub url: String,
    pub link_type: PdfLinkType,
    pub description: Option<String>,
}

/// A search result from an online source
#[derive(uniffi::Record, Clone, Debug, Serialize, Deserialize)]
pub struct SearchResult {
    pub source_id: String,
    pub source: Source,
    pub title: String,
    pub authors: Vec<Author>,
    pub year: Option<i32>,
    pub identifiers: Identifiers,
    pub abstract_text: Option<String>,
    pub journal: Option<String>,
    pub volume: Option<String>,
    pub pages: Option<String>,
    pub pdf_links: Vec<PdfLink>,
    pub bibtex: Option<String>,
    pub url: Option<String>,
    pub citation_count: Option<i32>,
}

impl SearchResult {
    /// Generate a cite key for this search result
    pub fn generate_cite_key(&self) -> String {
        let author = self
            .authors
            .first()
            .map(|a| a.family_name.clone())
            .unwrap_or_else(|| "Unknown".to_string());
        let year = self.year.map(|y| y.to_string()).unwrap_or_default();
        let title_word = self
            .title
            .split_whitespace()
            .find(|w| w.len() > 3)
            .unwrap_or("paper")
            .to_string();

        crate::identifiers::generate_cite_key(
            Some(author),
            if year.is_empty() { None } else { Some(year) },
            Some(title_word),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_source_as_str() {
        assert_eq!(Source::ArXiv.as_str(), "arxiv");
        assert_eq!(Source::Crossref.as_str(), "crossref");
        assert_eq!(Source::ADS.as_str(), "ads");
    }

    #[test]
    fn test_search_result_generate_cite_key() {
        let result = SearchResult {
            source_id: "2024.12345".to_string(),
            source: Source::ArXiv,
            title: "A Great Paper About Something".to_string(),
            authors: vec![Author::new("Einstein".to_string()).with_given_name("Albert")],
            year: Some(2024),
            identifiers: Identifiers::default(),
            abstract_text: None,
            journal: None,
            volume: None,
            pages: None,
            pdf_links: vec![],
            bibtex: None,
            url: None,
            citation_count: None,
        };

        let key = result.generate_cite_key();
        assert!(key.contains("Einstein"));
        assert!(key.contains("2024"));
    }
}
