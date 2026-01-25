//! Search result representation from online sources

use super::{Author, Identifiers};
use serde::{Deserialize, Serialize};

/// Online source for search results
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
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
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Enum))]
pub enum PdfLinkType {
    Direct,
    Landing,
    ArXiv,
    Publisher,
    OpenAccess,
}

/// A link to a PDF
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
pub struct PdfLink {
    pub url: String,
    pub link_type: PdfLinkType,
    pub description: Option<String>,
}

/// A search result from an online source
#[derive(Clone, Debug, Serialize, Deserialize)]
#[cfg_attr(feature = "uniffi", derive(uniffi::Record))]
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_source_as_str() {
        assert_eq!(Source::ArXiv.as_str(), "arxiv");
        assert_eq!(Source::Crossref.as_str(), "crossref");
        assert_eq!(Source::ADS.as_str(), "ads");
    }
}
