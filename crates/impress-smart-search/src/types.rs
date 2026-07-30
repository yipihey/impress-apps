//! Value types mirroring `SmartSearchTypes.swift`.

use serde::{Deserialize, Serialize};

/// A bare paper identifier recognizable without database access.
/// Mirrors Swift `PaperIdentifierLite`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", content = "value", rename_all = "lowercase")]
pub enum PaperIdentifier {
    Doi(String),
    Arxiv(String),
    Bibcode(String),
    Pmid(String),
}

impl PaperIdentifier {
    pub fn value(&self) -> &str {
        match self {
            PaperIdentifier::Doi(v)
            | PaperIdentifier::Arxiv(v)
            | PaperIdentifier::Bibcode(v)
            | PaperIdentifier::Pmid(v) => v,
        }
    }

    /// Swift `typeName`.
    pub fn type_name(&self) -> &'static str {
        match self {
            PaperIdentifier::Doi(_) => "doi",
            PaperIdentifier::Arxiv(_) => "arxiv",
            PaperIdentifier::Bibcode(_) => "bibcode",
            PaperIdentifier::Pmid(_) => "pmid",
        }
    }
}

/// Where the classifier decided the input should go. Mirrors `SearchIntent`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum SearchIntent {
    Identifier(PaperIdentifier),
    Fielded {
        query: String,
    },
    Reference {
        blocks: Vec<String>,
    },
    FreeText {
        query: String,
    },
    /// Carries the Foundation-equivalent `absoluteString` plus the host, which
    /// is all `SearchIntent.label` needs.
    Url {
        url: String,
        host: String,
    },
}

impl SearchIntent {
    /// Swift `kindRawValue`.
    pub fn kind_raw_value(&self) -> &'static str {
        match self {
            SearchIntent::Identifier(_) => "identifier",
            SearchIntent::Fielded { .. } => "fielded",
            SearchIntent::Reference { .. } => "reference",
            SearchIntent::FreeText { .. } => "freeText",
            SearchIntent::Url { .. } => "url",
        }
    }

    /// Swift `label` — the string the Cmd+S overlay shows.
    pub fn label(&self) -> String {
        match self {
            SearchIntent::Identifier(id) => match id {
                PaperIdentifier::Doi(_) => "DOI".to_string(),
                PaperIdentifier::Arxiv(_) => "arXiv".to_string(),
                PaperIdentifier::Bibcode(_) => "Bibcode".to_string(),
                PaperIdentifier::Pmid(_) => "PMID".to_string(),
            },
            SearchIntent::Fielded { .. } => "Fielded query".to_string(),
            SearchIntent::Reference { blocks } => {
                if blocks.len() == 1 {
                    "Reference".to_string()
                } else {
                    format!("References ({})", blocks.len())
                }
            }
            SearchIntent::FreeText { .. } => "Free-text search".to_string(),
            // Swift: `"URL · \(u.host ?? "page")"`. A parsed http(s) URL always
            // has a host, so the "page" fallback is unreachable here.
            SearchIntent::Url { host, .. } => {
                format!("URL · {}", if host.is_empty() { "page" } else { host })
            }
        }
    }
}

/// Structured citation fields. Mirrors `CitationInputLite`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct CitationInput {
    pub authors: Vec<String>,
    pub title: Option<String>,
    pub year: Option<i64>,
    pub journal: Option<String>,
    pub volume: Option<String>,
    pub pages: Option<String>,
    pub doi: Option<String>,
    pub arxiv: Option<String>,
    pub bibcode: Option<String>,
    pub free_text: Option<String>,
}

impl CitationInput {
    pub fn has_identifier(&self) -> bool {
        !self.doi.as_deref().unwrap_or("").is_empty()
            || !self.arxiv.as_deref().unwrap_or("").is_empty()
            || !self.bibcode.as_deref().unwrap_or("").is_empty()
    }
}

/// Pre-validation LLM output. Mirrors `ParsedReference`.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ParsedReference {
    pub authors: Vec<String>,
    pub title: String,
    pub year: i64,
    pub journal: String,
    pub volume: String,
    pub pages: String,
    pub doi: String,
    pub arxiv: String,
    pub bibcode: String,
    pub confidence: f64,
}

/// Which tier produced a rewritten query. Mirrors `QueryRewriteResult.Source`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RewriteSource {
    AppleIntelligence,
    Cloud,
    Degenerate,
}

impl RewriteSource {
    pub fn raw_value(&self) -> &'static str {
        match self {
            RewriteSource::AppleIntelligence => "appleIntelligence",
            RewriteSource::Cloud => "cloud",
            RewriteSource::Degenerate => "degenerate",
        }
    }
}

/// Mirrors `QueryRewriteResult`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct QueryRewriteResult {
    pub query: String,
    pub interpretation: String,
    pub confidence: f64,
    pub source: RewriteSource,
}

/// Structured search fields extracted from free text. The Rust mirror of the
/// Swift `QueryParts` / on-device `@Generable ADSQueryParts` shape — the model
/// emits these and [`crate::rewriter::build_query`] turns them into ADS syntax.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct QueryParts {
    pub authors: Vec<String>,
    pub bibstem: String,
    pub topic_words: Vec<String>,
    pub year_from: i64,
    pub year_to: i64,
    pub refereed_only: bool,
    pub interpretation: String,
    pub confidence: f64,
}

/// Identifiers scraped from a fetched page. Mirrors `URLExtractionResult`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UrlExtractionResult {
    pub url: String,
    pub page_title: Option<String>,
    pub identifiers: Vec<PaperIdentifier>,
    pub reason: Option<String>,
}

/// Result of the ADS query normalizer. Mirrors `ADSQueryNormalizer.Result`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct NormalizationResult {
    pub corrected_query: String,
    pub corrections: Vec<String>,
}

impl NormalizationResult {
    pub fn was_modified(&self) -> bool {
        !self.corrections.is_empty()
    }
}
