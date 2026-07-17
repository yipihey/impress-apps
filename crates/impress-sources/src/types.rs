//! Common DTOs shared across source plugins.
//!
//! Where the shape matches an existing impress-domain type we re-export it
//! (Author). Source-specific result types are kept narrower than the
//! persistence-layer `Publication` model so that translating a `PaperMetadata`
//! into a stored publication remains an explicit step.

use serde::{Deserialize, Serialize};

// Re-export the canonical Author so the rest of the workspace converges on
// a single representation. Source plugins fill out family/given/orcid from
// raw API responses.
pub use impress_domain::Author;

/// Free-text search input plus optional structured filters.
///
/// `fielded` lets callers pass `("title", "...")`, `("author", "...")` etc.
/// without each source having to re-parse its own DSL. Sources interpret
/// the field names they recognize and ignore the rest.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct SearchQuery {
    /// Raw free-text query as the user typed it.
    pub raw: String,
    /// Structured field filters; sources may map field names to their own API
    /// (e.g. `title` → `ti:` for arXiv).
    pub fielded: Vec<(String, String)>,
    /// Maximum number of results to return. Sources clamp to their per-API
    /// maximum.
    pub limit: u32,
    /// Offset / starting index for pagination. Sources may use this directly
    /// (Crossref offset, OpenAlex page) or ignore it.
    pub offset: u32,
    /// Optional year range; `(Some(2018), None)` = "from 2018 onwards".
    pub year_range: Option<(Option<i32>, Option<i32>)>,
}

impl SearchQuery {
    /// Build a query from just free text. Defaults `limit` to 50.
    pub fn new(raw: impl Into<String>) -> Self {
        Self {
            raw: raw.into(),
            fielded: Vec::new(),
            limit: 50,
            offset: 0,
            year_range: None,
        }
    }

    pub fn with_limit(mut self, limit: u32) -> Self {
        self.limit = limit;
        self
    }

    pub fn with_field(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.fielded.push((key.into(), value.into()));
        self
    }
}

/// A page of search results plus pagination metadata.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SearchResult {
    /// Stable identifier of the source plugin that produced this page
    /// (e.g. `"arxiv"`, `"crossref"`, `"ads"`, `"openalex"`).
    pub source: String,
    pub items: Vec<PaperMetadata>,
    /// Estimated total hits across all pages, when the API reports it.
    pub total_estimated: Option<u64>,
    /// Source-specific cursor or token for the next page (when supported).
    pub next_cursor: Option<String>,
}

/// Per-paper metadata returned by a source.
///
/// `raw_json` preserves the original API response (or a structured
/// approximation when the source is XML) so downstream layers can extract
/// fields that aren't part of the unified model without re-fetching.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PaperMetadata {
    /// Source-specific primary identifier (arXiv id, DOI, OpenAlex id,
    /// PubMed PMID, ADS bibcode, ...).
    pub source_id: String,
    pub doi: Option<String>,
    pub arxiv_id: Option<String>,
    pub title: String,
    pub authors: Vec<Author>,
    pub abstract_text: Option<String>,
    pub year: Option<i32>,
    pub venue: Option<String>,
    pub pdf_url: Option<String>,
    /// Original response object preserved for round-trip fidelity. For XML
    /// sources we serialize a structured approximation rather than the raw
    /// bytes.
    #[serde(default)]
    pub raw_json: serde_json::Value,
}

impl PaperMetadata {
    /// Empty stub used by parsers when only the source_id is known.
    pub fn with_source_id(source_id: impl Into<String>) -> Self {
        Self {
            source_id: source_id.into(),
            doi: None,
            arxiv_id: None,
            title: String::new(),
            authors: Vec::new(),
            abstract_text: None,
            year: None,
            venue: None,
            pdf_url: None,
            raw_json: serde_json::Value::Null,
        }
    }
}

/// Helper for parsers: build a `PaperMetadata` from a (family, given) pair
/// without involving the full impress-domain Author builder API.
pub fn author_from_names(family: impl Into<String>, given: Option<String>) -> Author {
    let mut a = Author::new(family.into());
    if let Some(g) = given {
        a.given_name = Some(g);
    }
    a
}
